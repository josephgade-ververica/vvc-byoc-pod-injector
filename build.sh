#!/bin/bash
# =============================================================================
# build.sh — Build, Push, and Test the VVC BYOC Pod Injector
#
# Place this script in your project folder alongside a Claude/ folder
# containing development.zip and distribution.zip.
#
# Usage:
#   ./build.sh [region]
#   Default region: eu-central-1
#
# What it does:
#   1. Unzips development/ and distribution/ from Claude/
#   2. Builds the Docker image
#   3. Exports tarball into distribution/
#   4. Creates customer-delivery.zip
#   5. Creates test/ folder
#   6. Pushes image to ECR
#   7. Deploys and tests end-to-end
# =============================================================================
set -euo pipefail

REGION="${1:-eu-central-1}"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${PROJECT_DIR}/Claude"
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
echo "  VVC BYOC Pod Injector — Full Build & Test"
echo "  Project: ${PROJECT_DIR}"
echo "  Region:  ${REGION}"
echo "============================================================"
echo ""

# ─── Preflight ────────────────────────────────────────────────────────
[ -d "${CLAUDE_DIR}" ] || err "Claude/ folder not found. Place development.zip and distribution.zip in ${CLAUDE_DIR}/"
[ -f "${CLAUDE_DIR}/development.zip" ] || err "Claude/development.zip not found."
[ -f "${CLAUDE_DIR}/distribution.zip" ] || err "Claude/distribution.zip not found."
command -v docker >/dev/null || err "Docker not installed."
docker info >/dev/null 2>&1 || err "Docker not running."
command -v kubectl >/dev/null || err "kubectl not installed."
command -v aws >/dev/null || err "AWS CLI not installed."
command -v unzip >/dev/null || err "unzip not installed."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || err "AWS credentials not configured."
FULL_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}:${IMAGE_TAG}"

log "AWS Account: ${AWS_ACCOUNT_ID}"
log "Target image: ${FULL_IMAGE}"

# ─── Step 1: Unzip ────────────────────────────────────────────────────
step "STEP 1/7 — Extracting Source"

if [ -d "${PROJECT_DIR}/development" ]; then
  info "development/ exists — skipping"
else
  mkdir -p "${PROJECT_DIR}/development"
  cd "${PROJECT_DIR}/development" && unzip -o "${CLAUDE_DIR}/development.zip"
  log "Development extracted"
fi

if [ -d "${PROJECT_DIR}/distribution" ]; then
  info "distribution/ exists — skipping"
else
  mkdir -p "${PROJECT_DIR}/distribution"
  cd "${PROJECT_DIR}/distribution" && unzip -o "${CLAUDE_DIR}/distribution.zip"
  log "Distribution extracted"
fi

# ─── Step 2: Build Docker image ──────────────────────────────────────
step "STEP 2/7 — Building Docker Image"

cd "${PROJECT_DIR}/development/webhook-server"
BUILD_PLATFORM=""
if [[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]]; then
  BUILD_PLATFORM="--platform linux/amd64"
  info "Apple Silicon — cross-compiling for amd64"
fi
docker build ${BUILD_PLATFORM} -t "${IMAGE_NAME}:${IMAGE_TAG}" .
log "Image built"

# ─── Step 3: Export tarball ──────────────────────────────────────────
step "STEP 3/7 — Exporting Tarball"

TARBALL="${PROJECT_DIR}/distribution/${IMAGE_NAME}-${IMAGE_TAG}.tar"
docker save "${IMAGE_NAME}:${IMAGE_TAG}" -o "${TARBALL}"
log "Tarball: $(du -h "${TARBALL}" | cut -f1)"

# ─── Step 4: Package customer delivery ───────────────────────────────
step "STEP 4/7 — Packaging Customer Delivery"

cd "${PROJECT_DIR}"
rm -f customer-delivery.zip
zip -j customer-delivery.zip distribution/*
log "customer-delivery.zip created ($(du -h customer-delivery.zip | cut -f1))"

# ─── Step 5: Create test folder ─────────────────────────────────────
step "STEP 5/7 — Creating Test Folder"

rm -rf "${PROJECT_DIR}/test"
mkdir -p "${PROJECT_DIR}/test"
cp "${PROJECT_DIR}/distribution/"* "${PROJECT_DIR}/test/"
chmod +x "${PROJECT_DIR}/test/push-image.sh" "${PROJECT_DIR}/test/vvc-byoc-pod-injector.sh"
log "Test folder ready"

# ─── Step 6: Push to ECR ────────────────────────────────────────────
step "STEP 6/7 — Pushing Image to ECR"

cd "${PROJECT_DIR}/test"

EXISTING_REPO=$(aws ecr describe-repositories --repository-names "${IMAGE_NAME}" --region "${REGION}" 2>/dev/null || echo "")
SKIP_PUSH=""
if [[ -n "$EXISTING_REPO" ]]; then
  EXISTING_TAGS=$(aws ecr list-images --repository-name "${IMAGE_NAME}" --region "${REGION}" --query 'imageIds[*].imageTag' --output text 2>/dev/null || echo "(none)")
  warn "ECR repo already exists (tags: ${EXISTING_TAGS})"
  echo ""
  echo "  1) Replace — delete and push fresh"
  echo "  2) Overwrite — push on top"
  echo "  3) Keep — use existing"
  echo ""
  read -p "  Choose (1/2/3): " ECR_CHOICE
  case "$ECR_CHOICE" in
    1) aws ecr delete-repository --repository-name "${IMAGE_NAME}" --region "${REGION}" --force >/dev/null; log "Deleted" ;;
    2) info "Pushing to existing repo..." ;;
    3) log "Keeping existing image"; SKIP_PUSH=true ;;
    *) err "Invalid choice" ;;
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

# ─── Step 7: Deploy and test ────────────────────────────────────────
step "STEP 7/7 — Deploy & End-to-End Test"

cd "${PROJECT_DIR}/test"
./vvc-byoc-pod-injector.sh deploy \
  --webhook-image "${FULL_IMAGE}" \
  --config injection-config.yaml \
  --secrets secrets.yaml

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}  Build & Test Complete!${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo ""
echo "  ${PROJECT_DIR}/"
echo "  ├── Claude/                (source zips)"
echo "  ├── development/           (internal — source code)"
echo "  ├── distribution/          (customer files + tarball)"
echo "  ├── test/                  (tested and working)"
echo "  └── customer-delivery.zip  (send to customer)"
echo ""
echo "  Customer runs:"
echo "    unzip customer-delivery.zip"
echo "    ./push-image.sh <region>"
echo "    ./vvc-byoc-pod-injector.sh deploy \\"
echo "      --webhook-image <URI> \\"
echo "      --config injection-config.yaml \\"
echo "      --secrets secrets.yaml"
echo ""
