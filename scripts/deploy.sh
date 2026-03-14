#!/bin/bash
set -e
# TW3K Cloud Gaming -- Full Deployment Script
# Usage: ./deploy.sh <dockerhub-username>

DOCKER_USER="${1:?Usage: ./deploy.sh <dockerhub-username>}"
IMAGE_NAME="${DOCKER_USER}/tw3k-cloud-gaming:latest"
PROJECT_DIR="tw3k-cloud-gaming"

echo "============================================="
echo "TW3K Cloud Gaming -- Deployment Builder"
echo "Image: ${IMAGE_NAME}"
echo "============================================="

mkdir -p "${PROJECT_DIR}"
cd "${PROJECT_DIR}"

echo "Building Docker image..."
docker build -t "${IMAGE_NAME}" .

echo "Pushing to Docker Hub..."
docker push "${IMAGE_NAME}"

echo "============================================="
echo "Done! Image: ${IMAGE_NAME}"
echo "============================================="
