#!/bin/bash
# =============================================================================
# push-image.sh — Load and push the webhook image to your ECR
#
# Usage: ./push-image.sh [region]
#   Default region: ap-south-1
#
# If an ECR repo already exists, prompts whether to replace or keep.
# Prerequisites: Docker running, AWS CLI configured
# =============================================================================
set -euo pipefail

REGION="${1:-ap-south-1}"
IMAGE_TAR="vvc-byoc-pod-injector-v1.tar"
REPO_NAME="vvc-byoc-pod-injector"
TAG="v1"

echo ""
echo "============================================================"
echo "  VVC BYOC Pod Injector — Push Image to ECR"
echo "============================================================"
echo ""

# Checks
command -v docker >/dev/null || { echo "ERROR: Docker not installed."; exit 1; }
command -v aws >/dev/null || { echo "ERROR: AWS CLI not installed."; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker not running. Start Docker Desktop."; exit 1; }
[ -f "$IMAGE_TAR" ] || { echo "ERROR: ${IMAGE_TAR} not found in current directory."; echo "Place the tar file in the same folder as this script."; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || { echo "ERROR: AWS credentials not configured or expired."; exit 1; }
FULL_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}:${TAG}"

echo "  Account:  ${ACCOUNT_ID}"
echo "  Region:   ${REGION}"
echo "  Image:    ${IMAGE_TAR}"
echo "  Target:   ${FULL_IMAGE}"
echo ""

# Check if ECR repo already exists
EXISTING_REPO=$(aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" 2>/dev/null || echo "")

if [[ -n "$EXISTING_REPO" ]]; then
  # Get existing image details
  EXISTING_TAGS=$(aws ecr list-images --repository-name "${REPO_NAME}" --region "${REGION}" --query 'imageIds[*].imageTag' --output text 2>/dev/null || echo "(none)")
  EXISTING_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

  echo "  ⚠️  ECR repository '${REPO_NAME}' already exists!"
  echo "  URI:  ${EXISTING_URI}"
  echo "  Tags: ${EXISTING_TAGS}"
  echo ""
  echo "  Options:"
  echo "    1) Replace — delete existing repo and push fresh image"
  echo "    2) Overwrite — push new image tag to existing repo"
  echo "    3) Keep — skip push, use existing image as-is"
  echo ""
  read -p "  Choose (1/2/3): " CHOICE

  case "$CHOICE" in
    1)
      echo ""
      echo "  Deleting existing repo..."
      aws ecr delete-repository --repository-name "${REPO_NAME}" --region "${REGION}" --force >/dev/null
      echo "  Deleted. Creating fresh..."
      ;;
    2)
      echo ""
      echo "  Will push to existing repo..."
      ;;
    3)
      echo ""
      echo "============================================================"
      echo "  Keeping existing image."
      echo "============================================================"
      echo ""
      echo "  Image URI: ${FULL_IMAGE}"
      echo ""
      echo "  Run:"
      echo "    ./vvc-byoc-pod-injector.sh deploy \\"
      echo "      --webhook-image ${FULL_IMAGE} \\"
      echo "      --config injection-config.yaml \\"
      echo "      --secrets secrets.yaml"
      echo ""
      exit 0
      ;;
    *)
      echo "  Invalid choice. Exiting."
      exit 1
      ;;
  esac
fi

# Load
echo ""
echo "[1/4] Loading image into Docker..."
docker load -i "${IMAGE_TAR}"

# Create repo (if it was deleted or doesn't exist)
echo "[2/4] Creating ECR repository..."
aws ecr describe-repositories --repository-names "${REPO_NAME}" --region "${REGION}" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "${REPO_NAME}" --region "${REGION}" >/dev/null
echo "  Repository: ${REPO_NAME}"

# Login
echo "[3/4] Logging into ECR..."
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null

# Tag and push
echo "[4/4] Pushing image..."
docker tag "${REPO_NAME}:${TAG}" "${FULL_IMAGE}"
docker push "${FULL_IMAGE}"

echo ""
echo "============================================================"
echo "  Image pushed successfully!"
echo "============================================================"
echo ""
echo "  Image URI: ${FULL_IMAGE}"
echo ""
echo "  Next step — edit secrets.yaml with your passwords and JKS files, then run:"
echo ""
echo "    ./vvc-byoc-pod-injector.sh deploy \\"
echo "      --webhook-image ${FULL_IMAGE} \\"
echo "      --config injection-config.yaml \\"
echo "      --secrets secrets.yaml"
echo ""
