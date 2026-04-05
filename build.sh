#!/bin/bash
# =============================================================================
# build.sh — Build, Package, and optionally Push & Test
#
# Usage:
#   ./build.sh                    # Build image + package customer delivery
#   ./build.sh --push <region>    # Build + push to ECR + deploy + test
#
# Run from the repo root (where this script lives).
# =============================================================================
set -euo pipefail

REGION="${2:-eu-central-1}"
MODE="${1:---build}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="vvc-byoc-pod-injector"
IMAGE_TAG="v1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"; }

echo ""
echo "============================================================"
echo "  VVC BYOC Pod Injector — Build"
echo "  Project: ${PROJECT_DIR}"
echo "  Mode:    ${MODE}"
echo "============================================================"
echo ""

# ─── Preflight ────────────────────────────────────────────────────────
[ -f "${PROJECT_DIR}/development/webhook-server/Dockerfile" ] || err "development/webhook-server/Dockerfile not found. Run from repo root."
[ -f "${PROJECT_DIR}/development/webhook-server/main.go" ] || err "development/webhook-server/main.go not found."
command -v docker >/dev/null || err "Docker not installed."
docker info >/dev/null 2>&1 || err "Docker not running."

# ─── Step 1: Build Docker image ──────────────────────────────────────
step "STEP 1/3 — Building Docker Image"

cd "${PROJECT_DIR}/development/webhook-server"
BUILD_PLATFORM=""
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  BUILD_PLATFORM="--platform linux/amd64"
  info "Apple Silicon — cross-compiling for amd64"
fi
docker build ${BUILD_PLATFORM} -t "${IMAGE_NAME}:${IMAGE_TAG}" .
log "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"

# ─── Step 2: Export tarball ──────────────────────────────────────────
step "STEP 2/3 — Exporting Tarball"

TARBALL="${PROJECT_DIR}/distribution/${IMAGE_NAME}-${IMAGE_TAG}.tar"
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "${TARBALL}"
log "Tarball: $(du -h "${TARBALL}" | cut -f1) → distribution/${IMAGE_NAME}-${IMAGE_TAG}.tar"

# ─── Step 3: Package customer delivery ───────────────────────────────
step "STEP 3/3 — Packaging Customer Delivery"

cd "${PROJECT_DIR}"
rm -f customer-delivery.zip
zip -j customer-delivery.zip distribution/*
log "customer-delivery.zip created ($(du -h customer-delivery.zip | cut -f1))"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Build Complete!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo "  Docker image:        ${IMAGE_NAME}:${IMAGE_TAG}"
echo "  Tarball:             distribution/${IMAGE_NAME}-${IMAGE_TAG}.tar"
echo "  Customer delivery:   customer-delivery.zip"
echo ""
echo "  To test locally:"
echo "    mkdir test && cd test"
echo "    cp ../distribution/* ."
echo "    ./push-image.sh ${REGION}"
echo "    ./vvc-byoc-pod-injector.sh deploy \\"
echo "      --webhook-image <URI_FROM_PUSH> \\"
echo "      --config injection-config.yaml \\"
echo "      --secrets secrets.yaml"
echo ""

# ─── Optional: Push + Deploy + Test ──────────────────────────────────
if [[ "${MODE}" == "--push" ]]; then
  step "BONUS — Push to ECR + Deploy + Test"

  command -v aws >/dev/null || err "AWS CLI not installed."
  command -v kubectl >/dev/null || err "kubectl not installed."

  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || err "AWS credentials not configured."
  FULL_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${IMAGE_TAG}"

  info "Pushing to ${FULL_IMAGE}..."

  SKIP_PUSH=""
  EXISTING=$(aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${REGION}" 2>/dev/null || echo "")
  if [[ -n "$EXISTING" ]]; then
    warn "ECR repo exists"
    echo "  1) Replace   2) Overwrite   3) Keep"
    read -p "  Choose (1/2/3): " ECR_CHOICE
    case "$ECR_CHOICE" in
      1) aws ecr delete-repository --repository-name "${IMAGE_NAME}" --region "${REGION}" --force >/dev/null ;;
      2) ;;
      3) log "Keeping existing"; SKIP_PUSH=true ;;
      *) err "Invalid" ;;
    esac
  fi

  if [[ "${SKIP_PUSH}" != "true" ]]; then
    aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${REGION}" >/dev/null 2>&1 || \
      aws ecr create-repository --repository-name "${IMAGE_NAME}" --region "${REGION}" >/dev/null
    aws ecr get-login-password --region "${REGION}" | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
    docker tag "${IMAGE_NAME}:${IMAGE_TAG}" "${FULL_IMAGE}"
    docker push "${FULL_IMAGE}"
    log "Pushed: ${FULL_IMAGE}"
  fi

  mkdir -p "${PROJECT_DIR}/test"
  cp "${PROJECT_DIR}/distribution/"* "${PROJECT_DIR}/test/" 2>/dev/null || true
  chmod +x "${PROJECT_DIR}/test/vvc-byoc-pod-injector.sh" "${PROJECT_DIR}/test/push-image.sh" 2>/dev/null || true
  cd "${PROJECT_DIR}/test"
  ./vvc-byoc-pod-injector.sh deploy \
    --webhook-image "${FULL_IMAGE}" \
    --config injection-config.yaml \
    --secrets secrets.yaml
fi
