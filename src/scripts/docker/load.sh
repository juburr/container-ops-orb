#!/bin/bash

# Docker Load Script
# Loads a Docker image from a tar archive using docker load.

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
    ARCHIVE_PATH=$(circleci env subst "${PARAM_ARCHIVE_PATH}")
else
    IMAGE="${PARAM_IMAGE}"
    ARCHIVE_PATH="${PARAM_ARCHIVE_PATH}"
fi

# Expand ~ to home directory
ARCHIVE_PATH="${ARCHIVE_PATH/#\~/$HOME}"

# Generate safe filename (same logic as archive)
SAFE_NAME=$(echo "${IMAGE}" | tr '/' '-')
ARCHIVE_FILE="${ARCHIVE_PATH}/${SAFE_NAME}-img.tar"

echo "Loading image from archive..."
echo "  Archive: ${ARCHIVE_FILE}"

# Check if archive exists
if [ ! -f "${ARCHIVE_FILE}" ]; then
    echo "ERROR: Archive file not found: ${ARCHIVE_FILE}"
    echo ""
    echo "Available files in ${ARCHIVE_PATH}:"
    ls -la "${ARCHIVE_PATH}" 2>/dev/null || echo "  (directory does not exist)"
    exit 1
fi

# Load image from tar
LOAD_OUTPUT=$(docker load -i "${ARCHIVE_FILE}")
echo "${LOAD_OUTPUT}"

# Extract loaded image reference from output
# Output format: "Loaded image: image:tag" or "Loaded image ID: sha256:..."
LOADED_IMAGE=$(echo "${LOAD_OUTPUT}" | grep -oP '(?<=Loaded image: ).*' || echo "")

echo ""
echo "Successfully loaded image from archive."
if [ -n "${LOADED_IMAGE}" ]; then
    echo "  Image: ${LOADED_IMAGE}"
    echo "export LOADED_IMAGE='${LOADED_IMAGE}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
fi
