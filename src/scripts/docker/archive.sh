#!/bin/bash

# Docker Archive Script
# Archives a Docker image to a tar file using docker save.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "FATAL: Command 'docker' is required but not installed."
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGE=$(circleci env subst "${PARAM_IMAGE}")
    TAG=$(circleci env subst "${PARAM_TAG}")
    OUTPUT_PATH=$(circleci env subst "${PARAM_OUTPUT_PATH}")
else
    IMAGE="${PARAM_IMAGE}"
    TAG="${PARAM_TAG}"
    OUTPUT_PATH="${PARAM_OUTPUT_PATH}"
fi

# Use BUILT_IMAGE_TAG from environment if tag not specified
if [ -z "${TAG}" ]; then
    TAG="${BUILT_IMAGE_TAG:-latest}"
fi

FULL_IMAGE="${IMAGE}:${TAG}"

# Expand ~ to home directory
OUTPUT_PATH="${OUTPUT_PATH/#\~/$HOME}"

# Create output directory
mkdir -p "${OUTPUT_PATH}"

# Generate safe filename (replace / with -)
SAFE_NAME=$(echo "${IMAGE}" | tr '/' '-')
ARCHIVE_FILE="${OUTPUT_PATH}/${SAFE_NAME}-img.tar"

echo "Archiving image: ${FULL_IMAGE}"
echo "  Output: ${ARCHIVE_FILE}"

# Verify image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: Image '${FULL_IMAGE}' not found."
    exit 1
fi

# Save image to tar
docker save -o "${ARCHIVE_FILE}" "${FULL_IMAGE}"

# Verify archive was created
if [ ! -f "${ARCHIVE_FILE}" ]; then
    echo "ERROR: Archive file was not created."
    exit 1
fi

# Display archive info
ARCHIVE_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
echo ""
echo "Successfully archived:"
echo "  Image: ${FULL_IMAGE}"
echo "  File: ${ARCHIVE_FILE}"
echo "  Size: ${ARCHIVE_SIZE}"

# Export path for subsequent steps
echo "export ARCHIVED_IMAGE_PATH='${ARCHIVE_FILE}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
echo "export ARCHIVED_IMAGE_NAME='${SAFE_NAME}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
