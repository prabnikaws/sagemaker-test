#!/bin/bash
# Build the custom SageMaker JupyterLab image and push to ECR.
#
# Prerequisites:
#   - Docker installed and running
#   - AWS CLI configured with credentials that can push to ECR
#   - Permissions: ecr:CreateRepository, ecr:GetAuthorizationToken,
#     ecr:BatchCheckLayerAvailability, ecr:PutImage, ecr:InitiateLayerUpload,
#     ecr:UploadLayerPart, ecr:CompleteLayerUpload
#
# Usage:
#   ./build-and-push.sh                    # Uses defaults (us-west-2)
#   REGION=eu-central-1 ./build-and-push.sh  # Override region
set -e

# Configuration — change these as needed
REGION="${REGION:-us-west-2}"
IMAGE_NAME="${IMAGE_NAME:-sagemaker-jupyterlab-precommit}"
TAG="${TAG:-latest}"

# Derived values
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${IMAGE_NAME}"

echo "Building image: ${IMAGE_NAME}:${TAG}"
echo "Target ECR:     ${ECR_URI}:${TAG}"
echo "Region:         ${REGION}"
echo ""

# Build
docker build -t "${IMAGE_NAME}:${TAG}" .

# Create ECR repo (ignore error if it already exists)
aws ecr create-repository \
  --repository-name "${IMAGE_NAME}" \
  --region "${REGION}" 2>/dev/null || true

# Login to ECR
aws ecr get-login-password --region "${REGION}" | \
  docker login --username AWS \
  --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# Tag and push
docker tag "${IMAGE_NAME}:${TAG}" "${ECR_URI}:${TAG}"
docker push "${ECR_URI}:${TAG}"

echo ""
echo "Done. Image pushed to: ${ECR_URI}:${TAG}"
echo ""
echo "Next steps:"
echo "  1. Find your SageMaker AI domain ID (see the pre-commit hooks doc)"
echo "  2. Attach the image to the domain using the CLI commands below:"
echo ""
echo "  aws sagemaker create-image \\"
echo "    --image-name ${IMAGE_NAME} \\"
echo "    --role-arn <execution-role-arn> \\"
echo "    --region ${REGION}"
echo ""
echo "  aws sagemaker create-image-version \\"
echo "    --image-name ${IMAGE_NAME} \\"
echo "    --base-image ${ECR_URI}:${TAG} \\"
echo "    --region ${REGION}"
echo ""
echo "  aws sagemaker create-app-image-config \\"
echo "    --app-image-config-name ${IMAGE_NAME}-config \\"
echo "    --jupyter-lab-app-image-config '{}' \\"
echo "    --region ${REGION}"
echo ""
echo "  aws sagemaker update-domain \\"
echo "    --domain-id <domain-id> \\"
echo "    --default-user-settings '{\"JupyterLabAppSettings\":{\"CustomImages\":[{\"ImageName\":\"${IMAGE_NAME}\",\"AppImageConfigName\":\"${IMAGE_NAME}-config\"}]}}' \\"
echo "    --region ${REGION}"
