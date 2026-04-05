#!/bin/bash
##############################################################################
# vvc-byoc-pod-injector.sh — Generic Pod Injector for Ververica Cloud BYOC
#
# COMMANDS:
#   deploy    Full deployment (build image, deploy webhook, add first namespace)
#   add       Add a namespace (label + create secrets from config)
#   remove    Remove a namespace
#   list      List managed namespaces
#   status    Show webhook health
#   destroy   Remove everything
#   help      Show usage
#
# CONFIG-DRIVEN: All injection behavior defined in YAML files:
#   --config <injection-config.yaml>  What to inject (env vars, volumes, etc.)
#   --secrets <secrets.yaml>          What credentials/files to create
#
# See templates/ for annotated examples.
##############################################################################
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
#  Constants
# ═══════════════════════════════════════════════════════════════════════════
APP_NAME="vvc-byoc-pod-injector"
NAMESPACE_LABEL="${APP_NAME}"
NAMESPACE_LABEL_VALUE="enabled"
WEBHOOK_NAMESPACE="${WEBHOOK_NAMESPACE:-kube-system}"
WEBHOOK_REPLICAS="${WEBHOOK_REPLICAS:-2}"
ECR_REPO_NAME="${ECR_REPO_NAME:-${APP_NAME}}"
ANNOTATION_KEY="${APP_NAME}.ververica.com/injected"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${BLUE}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"; }

LOG_DIR="${LOG_DIR:-${HOME}/ververica-logs}"; mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${APP_NAME}-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-help}"; shift || true

# Defaults
CLOUD="${CLOUD:-auto}"; REGION="${REGION:-}"; NAMESPACE="${NAMESPACE:-}"
WEBHOOK_IMAGE="${WEBHOOK_IMAGE:-}"; IMAGE_TAG="${IMAGE_TAG:-v1}"
CONFIG_FILE="${CONFIG_FILE:-}"; SECRETS_FILE="${SECRETS_FILE:-}"
WEBHOOK_SRC_DIR="${WEBHOOK_SRC_DIR:-${SCRIPT_DIR}/webhook-server}"
ECR_AVAILABLE=true; REGISTRY_FALLBACK=false

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --cloud) CLOUD="$2"; shift 2;; --region) REGION="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;; --webhook-image) WEBHOOK_IMAGE="$2"; shift 2;;
    --image-tag) IMAGE_TAG="$2"; shift 2;; --config) CONFIG_FILE="$2"; shift 2;;
    --secrets) SECRETS_FILE="$2"; shift 2;; --webhook-src) WEBHOOK_SRC_DIR="$2"; shift 2;;
    *) err "Unknown option: $1. Use '$0 help'." ;;
  esac
done

# ═══════════════════════════════════════════════════════════════════════════
#  Shared functions
# ═══════════════════════════════════════════════════════════════════════════

detect_cloud() {
  if [[ "$CLOUD" == "auto" ]]; then
    local np=$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || echo "")
    if echo "$np" | grep -qi "aws"; then CLOUD="aws"
    elif echo "$np" | grep -qi "azure"; then CLOUD="azure"
    else CLOUD="custom"; fi
    log "Detected cloud: ${CLOUD}"
  fi
}

detect_region() {
  if [[ -z "$REGION" ]]; then
    REGION=$(kubectl get nodes -o jsonpath='{.items[0].metadata.labels.topology\.kubernetes\.io/region}' 2>/dev/null || echo "")
    [[ -z "$REGION" ]] && REGION=$(aws configure get region 2>/dev/null || echo "")
    [[ -z "$REGION" ]] && err "Cannot detect region. Use --region."
    log "Detected region: ${REGION}"
  fi
}

get_managed_namespaces() {
  kubectl get namespaces -l "${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

# Parse secrets.yaml and create K8s secrets in a namespace
create_secrets_from_yaml() {
  local ns="$1" secrets_file="$2"
  [[ ! -f "$secrets_file" ]] && err "Secrets file not found: ${secrets_file}"

  info "Creating secrets in ${ns} from ${secrets_file}..."

  # Parse YAML with a portable approach (python or yq)
  local parser=""
  if command -v python3 >/dev/null 2>&1; then parser="python3"
  elif command -v python >/dev/null 2>&1; then parser="python"
  else err "python3 required to parse secrets.yaml"; fi

  # Extract secret names and create each one
  $parser -c "
import yaml, sys, subprocess, os

with open('${secrets_file}') as f:
    data = yaml.safe_load(f)

ns = '${ns}'
for secret_name, spec in data.get('secrets', {}).items():
    cmd = ['kubectl', 'create', 'secret', 'generic', secret_name, '--namespace', ns]

    # Literal key-value pairs
    for k, v in spec.get('literals', {}).items():
        cmd.extend(['--from-literal', f'{k}={v}'])

    # File entries
    for entry in spec.get('files', []):
        key = entry['key']
        path = entry['path']
        # Resolve relative paths from secrets.yaml location
        if not os.path.isabs(path):
            path = os.path.join(os.path.dirname(os.path.abspath('${secrets_file}')), path)
        if not os.path.exists(path):
            print(f'  WARNING: File not found: {path} (for {secret_name}/{key})', file=sys.stderr)
            continue
        cmd.extend(['--from-file', f'{key}={path}'])

    cmd.extend(['--dry-run=client', '-o', 'yaml'])

    # Pipe to kubectl apply
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f'  ERROR creating {secret_name}: {result.stderr}', file=sys.stderr)
        continue

    apply = subprocess.run(['kubectl', 'apply', '-f', '-'], input=result.stdout, capture_output=True, text=True)
    if apply.returncode == 0:
        print(f'  [ok] {secret_name}')
    else:
        print(f'  ERROR applying {secret_name}: {apply.stderr}', file=sys.stderr)
" || err "Failed to create secrets"
}

verify_namespace() {
  local ns="$1" tp="${APP_NAME}-verify-$$"
  info "Verifying injection in ${ns}..."
  kubectl delete pod "$tp" -n "$ns" --ignore-not-found >/dev/null 2>&1; sleep 2

  # Read target labels from config to apply to test pod
  local label_args="app=injector-verify"
  if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    local extra_labels
    extra_labels=$(python3 -c "
import yaml
with open('${CONFIG_FILE}') as f:
    cfg = yaml.safe_load(f)
labels = cfg.get('targeting', {}).get('labels', {})
print(','.join(f'{k}={v}' for k, v in labels.items()))
" 2>/dev/null || echo "system=ververica-platform")
    label_args="${label_args},${extra_labels}"
  else
    label_args="${label_args},system=ververica-platform"
  fi

  cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${tp}
  namespace: ${ns}
  labels: {$(echo "$label_args" | sed 's/,/,\n    /g; s/=/: /g')}
spec:
  containers:
    - name: test
      image: busybox:1.36
      command: ["sh","-c","sleep 120"]
      resources: { requests: { cpu: 100m, memory: 64Mi }, limits: { cpu: 100m, memory: 64Mi } }
  restartPolicy: Never
EOF
  kubectl wait --for=condition=Ready pod/"$tp" -n "$ns" --timeout=60s >/dev/null 2>&1 || true

  # Count injected env vars and volumes
  local env_count vol_count
  env_count=$(kubectl get pod "$tp" -n "$ns" -o jsonpath='{range .spec.containers[0].env[*]}{.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')
  vol_count=$(kubectl get pod "$tp" -n "$ns" -o jsonpath='{range .spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | wc -l | tr -d ' ')

  # Show what was injected
  echo ""
  info "Injected env vars:"
  kubectl get pod "$tp" -n "$ns" \
    -o jsonpath='{range .spec.containers[0].env[*]}  {.name} <- {.valueFrom.secretKeyRef.name}/{.valueFrom.secretKeyRef.key}{"\n"}{end}' 2>/dev/null || true
  echo ""
  info "Injected volume mounts:"
  kubectl get pod "$tp" -n "$ns" \
    -o jsonpath='{range .spec.containers[0].volumeMounts[*]}  {.name} -> {.mountPath}{"\n"}{end}' 2>/dev/null || true
  echo ""

  kubectl delete pod "$tp" -n "$ns" --ignore-not-found >/dev/null 2>&1

  if [[ "$env_count" -gt 1 || "$vol_count" -gt 1 ]]; then
    log "Injection verified in ${ns}"
  else
    warn "Injection may not be working in ${ns} — check config and webhook logs"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: help
# ═══════════════════════════════════════════════════════════════════════════
cmd_help() {
  cat <<EOF

${BOLD}VVC BYOC Pod Injector${NC} — Config-driven secret/file injection for Ververica Cloud BYOC

${BOLD}COMMANDS:${NC}
  deploy    Full first-time deployment
  add       Add a namespace to the injector
  remove    Remove a namespace
  list      List managed namespaces
  status    Show health and config
  destroy   Remove everything
  help      Show this help

${BOLD}DEPLOY:${NC}
  $0 deploy \\
    --config templates/injection-config.yaml \\
    --secrets secrets.yaml \\
    --region ap-south-1

${BOLD}ADD NAMESPACE:${NC}
  $0 add \\
    --config templates/injection-config.yaml \\
    --secrets secrets.yaml \\
    --namespace <flink-namespace>

${BOLD}OPTIONS:${NC}
  --config FILE         Injection config YAML (what to inject)
  --secrets FILE        Secrets YAML (credentials and file paths)
  --namespace NS        Flink namespace (auto-discovered on deploy)
  --cloud TYPE          aws|azure|custom (default: auto)
  --region REGION       Cloud region (default: auto)
  --webhook-image IMG   Pre-built image (skip build/push)
  --image-tag TAG       Image tag (default: v1)
  --webhook-src DIR     Webhook source code (default: ./webhook-server)

EOF
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: deploy
# ═══════════════════════════════════════════════════════════════════════════
cmd_deploy() {
  echo -e "\n${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  VVC BYOC Pod Injector — Full Deployment${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}\n"

  # ─── Preflight ────────────────────────────────────────────────────────
  step "PREFLIGHT — Checking Prerequisites"
  local PREFLIGHT_PASS=true PREFLIGHT_WARNS=0

  # Tools
  for tool in kubectl openssl python3; do
    if command -v "$tool" >/dev/null 2>&1; then log "  ${tool} — found"
    else echo -e "  ${RED}[✗]${NC} ${tool} — NOT FOUND"; PREFLIGHT_PASS=false; fi
  done
  if [[ -z "$WEBHOOK_IMAGE" ]]; then
    if command -v docker >/dev/null 2>&1; then
      if docker info >/dev/null 2>&1; then log "  docker — running"
      else echo -e "  ${RED}[✗]${NC} docker — not running"; PREFLIGHT_PASS=false; fi
    else echo -e "  ${RED}[✗]${NC} docker — not found (use --webhook-image to skip)"; PREFLIGHT_PASS=false; fi
  fi

  # Cluster
  kubectl cluster-info >/dev/null 2>&1 && log "  Cluster — reachable" || { echo -e "  ${RED}[✗]${NC} Cluster — unreachable"; PREFLIGHT_PASS=false; }
  detect_cloud; detect_region

  # K8s RBAC
  info "Checking K8s RBAC..."
  for check in "create deployments -n ${WEBHOOK_NAMESPACE}" "create services -n ${WEBHOOK_NAMESPACE}" "create secrets -n ${WEBHOOK_NAMESPACE}" "create mutatingwebhookconfigurations" "update namespaces"; do
    local action=$(echo "$check" | awk '{print $1}') resource=$(echo "$check" | awk '{print $2}') ns_flag=$(echo "$check" | awk '{print $3" "$4}')
    if kubectl auth can-i $check >/dev/null 2>&1; then log "  ${action} ${resource} — allowed"
    else echo -e "  ${RED}[✗]${NC} ${action} ${resource} — DENIED"; PREFLIGHT_PASS=false; fi
  done

  # Cloud registry
  if [[ "$CLOUD" == "aws" && -z "$WEBHOOK_IMAGE" ]]; then
    info "Checking AWS..."
    local aws_id=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "FAILED")
    if [[ "$aws_id" == "FAILED" ]]; then echo -e "  ${RED}[✗]${NC} AWS credentials — invalid"; PREFLIGHT_PASS=false
    else log "  AWS identity — ${aws_id}"; fi
    local ecr_auth=$(aws ecr get-authorization-token --region "${REGION}" 2>&1 || true)
    if echo "$ecr_auth" | grep -qi "authorizationData"; then log "  ECR — allowed"; ECR_AVAILABLE=true
    else warn "  ECR — denied (will use fallback)"; ECR_AVAILABLE=false; ((PREFLIGHT_WARNS++)); fi
  fi

  # Config files
  info "Checking config files..."
  [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]] && log "  Config — ${CONFIG_FILE}" || { echo -e "  ${RED}[✗]${NC} --config required"; PREFLIGHT_PASS=false; }
  [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]] && log "  Secrets — ${SECRETS_FILE}" || { warn "  Secrets file not provided (create K8s secrets manually)"; ((PREFLIGHT_WARNS++)); }
  [[ -z "$WEBHOOK_IMAGE" && -f "${WEBHOOK_SRC_DIR}/Dockerfile" ]] && log "  Dockerfile — found" || [[ -n "$WEBHOOK_IMAGE" ]] || { echo -e "  ${RED}[✗]${NC} Dockerfile not found"; PREFLIGHT_PASS=false; }

  # Existing install
  if kubectl get deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" >/dev/null 2>&1; then
    warn "  Existing installation found — will upgrade"
  fi

  echo ""
  if [[ "$PREFLIGHT_PASS" == false ]]; then
    echo -e "${RED}${BOLD}  PREFLIGHT FAILED — fix issues above${NC}\n"; exit 1
  elif [[ "$PREFLIGHT_WARNS" -gt 0 ]]; then echo -e "${YELLOW}${BOLD}  Preflight passed with ${PREFLIGHT_WARNS} warning(s)${NC}"
  else echo -e "${GREEN}${BOLD}  All checks passed!${NC}"; fi

  # ─── Existing installation check ──────────────────────────────────────
  local EXISTING_DEPLOY=$(kubectl get deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --no-headers 2>/dev/null || echo "")
  local EXISTING_NAMESPACES=$(get_managed_namespaces)

  if [[ -n "$EXISTING_DEPLOY" || -n "$EXISTING_NAMESPACES" ]]; then
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠️  Existing installation detected!${NC}"
    echo ""
    if [[ -n "$EXISTING_DEPLOY" ]]; then
      echo "  Webhook deployment:"
      echo "    $(echo "$EXISTING_DEPLOY" | awk '{print "  "$0}')"
    fi
    if [[ -n "$EXISTING_NAMESPACES" ]]; then
      echo "  Managed namespaces:"
      echo "$EXISTING_NAMESPACES" | while read ns; do echo "    - ${ns}"; done
    fi
    echo ""
    echo "  Options:"
    echo "    1) Overwrite — destroy existing and deploy fresh"
    echo "    2) Upgrade — update webhook image and config in-place"
    echo "    3) Cancel — exit without changes"
    echo ""
    read -p "  Choose (1/2/3): " DEPLOY_CHOICE

    case "$DEPLOY_CHOICE" in
      1)
        echo ""
        info "Destroying existing installation..."
        # Remove labels and secrets from managed namespaces
        if [[ -n "$EXISTING_NAMESPACES" ]]; then
          echo "$EXISTING_NAMESPACES" | while read ns; do
            kubectl label namespace "$ns" "${NAMESPACE_LABEL}-" 2>/dev/null || true
            if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
              python3 -c "
import yaml
with open('${SECRETS_FILE}') as f:
    data = yaml.safe_load(f)
for name in data.get('secrets', {}).keys():
    print(name)
" 2>/dev/null | while read sn; do kubectl delete secret "$sn" -n "$ns" --ignore-not-found 2>/dev/null; done
            fi
          done
        fi
        kubectl delete mutatingwebhookconfiguration "${APP_NAME}" --ignore-not-found 2>/dev/null
        kubectl delete deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found 2>/dev/null
        kubectl delete service "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found 2>/dev/null
        kubectl delete secret "${APP_NAME}-tls" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found 2>/dev/null
        kubectl delete configmap "${APP_NAME}-config" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found 2>/dev/null
        log "Existing installation destroyed"
        ;;
      2)
        info "Will upgrade in-place..."
        ;;
      3)
        echo ""
        info "Cancelled. No changes made."
        exit 0
        ;;
      *)
        err "Invalid choice."
        ;;
    esac
  fi

  # ─── Step 1: Namespace ────────────────────────────────────────────────
  step "STEP 1/6 — Discovering Flink Namespace"
  if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE=$(kubectl get pods --all-namespaces -l system=ververica-platform --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    [[ -z "$NAMESPACE" ]] && err "No Flink pods found. Deploy a job first or use --namespace."
    log "Auto-discovered: ${NAMESPACE}"
  else log "Using: ${NAMESPACE}"; fi
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || err "Namespace ${NAMESPACE} not found"

  # ─── Step 2: Build image ──────────────────────────────────────────────
  step "STEP 2/6 — Building Webhook Image"
  local IMAGE_PROVIDED=false
  if [[ -n "$WEBHOOK_IMAGE" ]]; then log "Using provided: ${WEBHOOK_IMAGE}"; IMAGE_PROVIDED=true
  else
    local bp=""; [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && bp="--platform linux/amd64" && info "Cross-compiling for amd64"
    if [[ "$CLOUD" == "aws" && "$ECR_AVAILABLE" == "true" ]]; then
      AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      WEBHOOK_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"
    elif [[ "$CLOUD" == "azure" ]]; then
      local acr=$(az acr list --query '[0].loginServer' --output tsv 2>/dev/null || echo "")
      [[ -n "$acr" ]] || err "No ACR found"
      WEBHOOK_IMAGE="${acr}/${ECR_REPO_NAME}:${IMAGE_TAG}"
    else
      WEBHOOK_IMAGE="${APP_NAME}:${IMAGE_TAG}"; REGISTRY_FALLBACK=true
    fi
    info "Building: ${WEBHOOK_IMAGE}"
    docker build ${bp} -t "${WEBHOOK_IMAGE}" "${WEBHOOK_SRC_DIR}"
    log "Image built"
  fi

  # ─── Step 3: Push ─────────────────────────────────────────────────────
  step "STEP 3/6 — Pushing Image"
  if [[ "${IMAGE_PROVIDED}" == "true" ]]; then
    log "Image pre-provided — skipping push"
  elif [[ "${REGISTRY_FALLBACK}" == "true" ]]; then
    info "No registry — loading image directly into cluster nodes..."
    local img_tar="/tmp/${APP_NAME}-image.tar"
    docker save "${WEBHOOK_IMAGE}" -o "${img_tar}"
    log "Image saved: $(du -h "${img_tar}" | cut -f1)"
    # Create loader DaemonSet
    kubectl create namespace ${APP_NAME}-loader --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    cat <<EOFLDS | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata: { name: img-loader, namespace: ${APP_NAME}-loader }
spec:
  selector: { matchLabels: { app: img-loader } }
  template:
    metadata: { labels: { app: img-loader } }
    spec:
      hostPID: true
      containers:
        - name: loader
          image: alpine:3.19
          command: ["sh","-c","sleep 3600"]
          securityContext: { privileged: true }
          volumeMounts:
            - { name: cri, mountPath: /run/containerd/containerd.sock }
            - { name: data, mountPath: /data }
      volumes:
        - { name: cri, hostPath: { path: /run/containerd/containerd.sock } }
        - { name: data, emptyDir: {} }
EOFLDS
    kubectl rollout status daemonset/img-loader -n ${APP_NAME}-loader --timeout=120s 2>/dev/null || true
    local loaded=0
    for pod in $(kubectl get pods -n ${APP_NAME}-loader -l app=img-loader -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}'); do
      kubectl cp "${img_tar}" "${APP_NAME}-loader/${pod}:/data/image.tar" 2>/dev/null
      kubectl exec -n ${APP_NAME}-loader "${pod}" -- sh -c "ctr -a /run/containerd/containerd.sock -n k8s.io images import /data/image.tar" 2>/dev/null && ((loaded++)) || true
    done
    kubectl delete namespace ${APP_NAME}-loader --ignore-not-found 2>/dev/null &
    rm -f "${img_tar}"
    log "Image loaded on ${loaded} node(s)"
  else
    case "$CLOUD" in
      aws) aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" --region "${REGION}" >/dev/null 2>&1 || \
             { info "Creating ECR repo..."; aws ecr create-repository --repository-name "${ECR_REPO_NAME}" --region "${REGION}" >/dev/null; }
           aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
           docker push "${WEBHOOK_IMAGE}"; log "Pushed to ECR" ;;
      azure) az acr login --name "$(az acr list --query '[0].name' --output tsv)" 2>/dev/null
             docker push "${WEBHOOK_IMAGE}"; log "Pushed to ACR" ;;
      *) log "Using provided image" ;;
    esac
  fi
  local PULL_POLICY="IfNotPresent"; [[ "${REGISTRY_FALLBACK}" == "true" ]] && PULL_POLICY="Never"

  # ─── Step 4: Deploy webhook ───────────────────────────────────────────
  step "STEP 4/6 — Deploying Webhook"
  local FQDN="${APP_NAME}.${WEBHOOK_NAMESPACE}.svc"
  local TD=$(mktemp -d); trap "rm -rf ${TD}" EXIT

  # TLS
  openssl req -x509 -newkey rsa:2048 -keyout "${TD}/ca.key" -out "${TD}/ca.crt" -days 3650 -nodes -subj "/CN=${APP_NAME}-ca" 2>/dev/null
  cat > "${TD}/s.conf" <<EOFCRT
[req]
req_extensions=v3
distinguished_name=dn
[dn]
[v3]
basicConstraints=CA:FALSE
keyUsage=nonRepudiation,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt
[alt]
DNS.1=${APP_NAME}
DNS.2=${APP_NAME}.${WEBHOOK_NAMESPACE}
DNS.3=${FQDN}
DNS.4=${FQDN}.cluster.local
EOFCRT
  openssl req -newkey rsa:2048 -keyout "${TD}/s.key" -out "${TD}/s.csr" -nodes -subj "/CN=${FQDN}" -config "${TD}/s.conf" 2>/dev/null
  openssl x509 -req -in "${TD}/s.csr" -CA "${TD}/ca.crt" -CAkey "${TD}/ca.key" -CAcreateserial -out "${TD}/s.crt" -days 3650 -extensions v3 -extfile "${TD}/s.conf" 2>/dev/null
  local CAB=$(base64 < "${TD}/ca.crt" | tr -d '\n')
  kubectl create secret tls "${APP_NAME}-tls" --namespace "${WEBHOOK_NAMESPACE}" \
    --cert="${TD}/s.crt" --key="${TD}/s.key" --dry-run=client -o yaml | kubectl apply -f -

  # ConfigMap from injection config
  info "Creating injection ConfigMap..."
  kubectl create configmap "${APP_NAME}-config" --namespace "${WEBHOOK_NAMESPACE}" \
    --from-file=injection-config.yaml="${CONFIG_FILE}" \
    --dry-run=client -o yaml | kubectl apply -f -
  log "ConfigMap created from ${CONFIG_FILE}"

  # Deployment + Service
  info "Deploying webhook (${WEBHOOK_REPLICAS} replicas)..."
  cat <<EOFD | kubectl apply -f -
---
apiVersion: v1
kind: Service
metadata: { name: ${APP_NAME}, namespace: ${WEBHOOK_NAMESPACE}, labels: { app: ${APP_NAME} } }
spec: { selector: { app: ${APP_NAME} }, ports: [{ port: 443, targetPort: 8443 }] }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: ${APP_NAME}, namespace: ${WEBHOOK_NAMESPACE}, labels: { app: ${APP_NAME} } }
spec:
  replicas: ${WEBHOOK_REPLICAS}
  selector: { matchLabels: { app: ${APP_NAME} } }
  template:
    metadata: { labels: { app: ${APP_NAME} } }
    spec:
      containers:
        - name: webhook
          image: ${WEBHOOK_IMAGE}
          imagePullPolicy: ${PULL_POLICY}
          ports: [{ containerPort: 8443 }]
          env:
            - { name: CONFIG_PATH, value: "/config/injection-config.yaml" }
          volumeMounts:
            - { name: tls, mountPath: /tls, readOnly: true }
            - { name: config, mountPath: /config, readOnly: true }
          readinessProbe: { httpGet: { path: /healthz, port: 8443, scheme: HTTPS }, initialDelaySeconds: 5, periodSeconds: 10 }
          livenessProbe: { httpGet: { path: /healthz, port: 8443, scheme: HTTPS }, initialDelaySeconds: 5, periodSeconds: 20 }
          resources: { requests: { cpu: 50m, memory: 64Mi }, limits: { cpu: 200m, memory: 128Mi } }
      volumes:
        - { name: tls, secret: { secretName: "${APP_NAME}-tls" } }
        - { name: config, configMap: { name: "${APP_NAME}-config" } }
EOFD
  kubectl rollout status deployment/${APP_NAME} -n ${WEBHOOK_NAMESPACE} --timeout=180s || err "Deployment failed"
  log "Webhook running"

  # MutatingWebhookConfiguration
  cat <<EOFWH | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata: { name: ${APP_NAME}, labels: { app: ${APP_NAME} } }
webhooks:
  - name: ${APP_NAME}.ververica.com
    admissionReviewVersions: ["v1"]
    sideEffects: None
    reinvocationPolicy: IfNeeded
    failurePolicy: Fail
    clientConfig: { service: { name: ${APP_NAME}, namespace: ${WEBHOOK_NAMESPACE}, path: /mutate, port: 443 }, caBundle: ${CAB} }
    rules: [{ operations: ["CREATE"], apiGroups: [""], apiVersions: ["v1"], resources: ["pods"] }]
    namespaceSelector: { matchLabels: { ${NAMESPACE_LABEL}: "${NAMESPACE_LABEL_VALUE}" } }
EOFWH
  log "Webhook registered (selector: ${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE})"

  # ─── Step 5: Add first namespace ──────────────────────────────────────
  step "STEP 5/6 — Adding Namespace: ${NAMESPACE}"
  kubectl label namespace "$NAMESPACE" "${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE}" --overwrite
  log "Labeled: ${NAMESPACE}"
  if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
    create_secrets_from_yaml "$NAMESPACE" "$SECRETS_FILE"
  else
    warn "No --secrets file — create K8s secrets manually in ${NAMESPACE}"
  fi

  # ─── Step 6: Verify ──────────────────────────────────────────────────
  step "STEP 6/6 — Verification"
  verify_namespace "$NAMESPACE"

  # Summary
  echo -e "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}${BOLD}  Deployment Complete!${NC}"
  echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}\n"
  echo "  Cloud:     ${CLOUD} (${REGION})"
  echo "  Webhook:   ${WEBHOOK_NAMESPACE}/${APP_NAME}"
  echo "  Image:     ${WEBHOOK_IMAGE}"
  echo "  Config:    ${CONFIG_FILE}"
  echo "  Selector:  ${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE}"
  echo ""
  echo "  Managed namespaces:"
  get_managed_namespaces | while read ns; do echo "    - ${ns}"; done
  echo ""
  echo "  Add workspace:    $0 add --config ${CONFIG_FILE} --secrets <secrets.yaml> --namespace <ns>"
  echo "  Remove workspace: $0 remove --namespace <ns>"
  echo "  Status:           $0 status"
  echo "  Destroy:          $0 destroy"
  echo "  Log:              ${LOG_FILE}"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: add
# ═══════════════════════════════════════════════════════════════════════════
cmd_add() {
  echo -e "\n${BOLD}  VVC BYOC Pod Injector — Add Namespace${NC}\n"
  kubectl get deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" >/dev/null 2>&1 || err "Not deployed. Run '$0 deploy' first."
  [[ -z "$NAMESPACE" ]] && err "--namespace required"
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || err "Namespace ${NAMESPACE} not found"

  # Check if namespace is already managed
  local current_label=$(kubectl get namespace "$NAMESPACE" -o jsonpath="{.metadata.labels.${NAMESPACE_LABEL}}" 2>/dev/null || echo "")
  if [[ "$current_label" == "$NAMESPACE_LABEL_VALUE" ]]; then
    echo -e "  ${YELLOW}⚠️  Namespace ${NAMESPACE} is already managed by the injector.${NC}"
    echo ""
    echo "  Options:"
    echo "    1) Overwrite — recreate secrets with current values"
    echo "    2) Cancel — keep existing setup"
    echo ""
    read -p "  Choose (1/2): " ADD_CHOICE
    case "$ADD_CHOICE" in
      1) info "Overwriting secrets in ${NAMESPACE}..." ;;
      2) info "Cancelled. No changes made."; exit 0 ;;
      *) err "Invalid choice." ;;
    esac
  fi

  # Permission check
  info "Checking permissions..."
  kubectl auth can-i create secrets -n "${NAMESPACE}" >/dev/null 2>&1 || err "Cannot create secrets in ${NAMESPACE}"
  kubectl auth can-i update namespaces >/dev/null 2>&1 || err "Cannot label namespaces"

  kubectl label namespace "$NAMESPACE" "${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE}" --overwrite
  log "Labeled: ${NAMESPACE}"

  if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
    create_secrets_from_yaml "$NAMESPACE" "$SECRETS_FILE"
  else
    warn "No --secrets file — create K8s secrets manually in ${NAMESPACE}"
  fi

  # Update config if provided (in case it changed)
  if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    kubectl create configmap "${APP_NAME}-config" --namespace "${WEBHOOK_NAMESPACE}" \
      --from-file=injection-config.yaml="${CONFIG_FILE}" \
      --dry-run=client -o yaml | kubectl apply -f -
    # Restart webhook to pick up new config
    kubectl rollout restart deployment/${APP_NAME} -n ${WEBHOOK_NAMESPACE} >/dev/null 2>&1
    kubectl rollout status deployment/${APP_NAME} -n ${WEBHOOK_NAMESPACE} --timeout=60s >/dev/null 2>&1
    log "Config updated"
  fi

  verify_namespace "$NAMESPACE"
  echo ""
  echo "  Managed namespaces:"
  get_managed_namespaces | while read ns; do echo "    - ${ns}"; done
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: remove
# ═══════════════════════════════════════════════════════════════════════════
cmd_remove() {
  [[ -z "$NAMESPACE" ]] && err "--namespace required"
  echo -e "\n  Removing: ${NAMESPACE}\n"
  kubectl label namespace "$NAMESPACE" "${NAMESPACE_LABEL}-" 2>/dev/null || true
  log "Label removed"

  # Delete all secrets that were created by this tool
  if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
    local secret_names
    secret_names=$(python3 -c "
import yaml
with open('${SECRETS_FILE}') as f:
    data = yaml.safe_load(f)
for name in data.get('secrets', {}).keys():
    print(name)
" 2>/dev/null || echo "")
    for sn in $secret_names; do
      kubectl delete secret "$sn" -n "$NAMESPACE" --ignore-not-found
    done
  else
    info "No --secrets file provided — delete secrets manually if needed"
  fi
  log "Namespace ${NAMESPACE} removed"
  echo ""
  echo "  Remaining namespaces:"
  get_managed_namespaces | while read ns; do echo "    - ${ns}"; done
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: list
# ═══════════════════════════════════════════════════════════════════════════
cmd_list() {
  echo -e "\n  Managed namespaces (${NAMESPACE_LABEL}=${NAMESPACE_LABEL_VALUE}):\n"
  local nss=$(get_managed_namespaces)
  if [[ -z "$nss" ]]; then echo "    (none)"
  else echo "$nss" | while read ns; do
    local pc=$(kubectl get pods -n "$ns" -l system=ververica-platform --no-headers 2>/dev/null | wc -l | tr -d ' ')
    local sc=$(kubectl get secrets -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    echo "    ${ns}  (${sc} secrets, ${pc} Flink pods)"
  done; fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: status
# ═══════════════════════════════════════════════════════════════════════════
cmd_status() {
  echo -e "\n${BOLD}  VVC BYOC Pod Injector — Status${NC}\n"
  echo -e "${BOLD}Webhook:${NC}"
  kubectl get deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --no-headers 2>/dev/null || echo "  NOT DEPLOYED"
  echo -e "\n${BOLD}Pods:${NC}"
  kubectl get pods -n "${WEBHOOK_NAMESPACE}" -l app="${APP_NAME}" --no-headers 2>/dev/null || echo "  (none)"
  echo -e "\n${BOLD}Active Config:${NC}"
  # Fetch live config from webhook
  local wp=$(kubectl get pods -n "${WEBHOOK_NAMESPACE}" -l app="${APP_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$wp" ]]; then
    kubectl exec -n "${WEBHOOK_NAMESPACE}" "$wp" -- wget -qO- https://localhost:8443/config --no-check-certificate 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (could not fetch)"
  fi
  cmd_list
  echo -e "${BOLD}Recent logs:${NC}"
  [[ -n "$wp" ]] && kubectl logs "$wp" -n "${WEBHOOK_NAMESPACE}" --tail=15 2>/dev/null || echo "  (no logs)"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  COMMAND: destroy
# ═══════════════════════════════════════════════════════════════════════════
cmd_destroy() {
  echo -e "\n${BOLD}  VVC BYOC Pod Injector — Destroy${NC}\n"
  get_managed_namespaces | while read ns; do
    info "Cleaning: ${ns}"
    kubectl label namespace "$ns" "${NAMESPACE_LABEL}-" 2>/dev/null || true
    # Try to delete known secrets
    if [[ -n "$SECRETS_FILE" && -f "$SECRETS_FILE" ]]; then
      python3 -c "
import yaml
with open('${SECRETS_FILE}') as f:
    data = yaml.safe_load(f)
for name in data.get('secrets', {}).keys():
    print(name)
" 2>/dev/null | while read sn; do kubectl delete secret "$sn" -n "$ns" --ignore-not-found 2>/dev/null; done
    fi
  done
  kubectl delete mutatingwebhookconfiguration "${APP_NAME}" --ignore-not-found
  kubectl delete deployment "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found
  kubectl delete service "${APP_NAME}" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found
  kubectl delete secret "${APP_NAME}-tls" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found
  kubectl delete configmap "${APP_NAME}-config" -n "${WEBHOOK_NAMESPACE}" --ignore-not-found
  log "Destroyed"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════
#  Dispatch
# ═══════════════════════════════════════════════════════════════════════════
case "$COMMAND" in
  deploy) cmd_deploy;; add) cmd_add;; remove) cmd_remove;;
  list) cmd_list;; status) cmd_status;; destroy) cmd_destroy;;
  help|-h|--help) cmd_help;; *) err "Unknown: ${COMMAND}. Use '$0 help'." ;;
esac
