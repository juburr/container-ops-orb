#!/bin/bash

# Docker Load Script
# Loads a Docker image from a tar archive using docker load.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "ERROR: Command 'docker' is required but not installed." >&2
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
    ARCHIVE_DIR=$(printf '%s' "${PARAM_ARCHIVE_DIR}" | circleci env subst)
else
    IMAGE="${PARAM_IMAGE}"
    ARCHIVE_DIR="${PARAM_ARCHIVE_DIR}"
fi

# Expand ~ to home directory
ARCHIVE_DIR="${ARCHIVE_DIR/#\~/$HOME}"

# Generate safe filename (same logic as docker_save: / and : become -)
SAFE_NAME=$(echo "${IMAGE}" | tr '/:' '--')
ARCHIVE_FILE="${ARCHIVE_DIR}/${SAFE_NAME}-img.tar"

echo "Loading image from archive..."
echo "  Archive: ${ARCHIVE_FILE}"

# Check if archive exists
if [ ! -f "${ARCHIVE_FILE}" ]; then
    echo "ERROR: Archive file not found: ${ARCHIVE_FILE}" >&2
    echo "" >&2
    echo "Available files in ${ARCHIVE_DIR}:" >&2
    { ls -la "${ARCHIVE_DIR}" 2>/dev/null || echo "  (directory does not exist)"; } >&2
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
    printf 'export %s=%q\n' LOADED_IMAGE "${LOADED_IMAGE}" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
fi
