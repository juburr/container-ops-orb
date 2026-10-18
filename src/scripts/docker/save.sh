#!/bin/bash

# Docker Save Script
# Saves a Docker image to a tar file using docker save.

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
    TAG=$(printf '%s' "${PARAM_TAG}" | circleci env subst)
    ARCHIVE_DIR=$(printf '%s' "${PARAM_ARCHIVE_DIR}" | circleci env subst)
else
    IMAGE="${PARAM_IMAGE}"
    TAG="${PARAM_TAG}"
    ARCHIVE_DIR="${PARAM_ARCHIVE_DIR}"
fi

# workspace_root is not substituted: it is compared with the root of the
# persist_to_workspace step, where CircleCI expands only a leading ~.
PERSIST_TO_WORKSPACE="${PARAM_PERSIST_TO_WORKSPACE:-false}"
WORKSPACE_ROOT="${PARAM_WORKSPACE_ROOT:-}"

# Use BUILT_IMAGE_TAG from environment if tag not specified
if [ -z "${TAG}" ]; then
    TAG="${BUILT_IMAGE_TAG:-latest}"
fi

FULL_IMAGE="${IMAGE}:${TAG}"

# Expand ~ to home directory
ARCHIVE_DIR="${ARCHIVE_DIR/#\~/$HOME}"
WORKSPACE_ROOT="${WORKSPACE_ROOT/#\~/$HOME}"

# Create output directory
mkdir -p "${ARCHIVE_DIR}"

# The persist_to_workspace step that follows persists the fixed path "images"
# under workspace_root (paths are relative to root and fixed when the config is
# compiled), so with persistence on, the archive must be saved there.
if [ "${PERSIST_TO_WORKSPACE}" = "true" ] || [ "${PERSIST_TO_WORKSPACE}" = "1" ]; then
    ARCHIVE_DIR_REAL=$(CDPATH='' cd -P -- "${ARCHIVE_DIR}" && pwd -P)
    if WORKSPACE_ROOT_REAL=$(CDPATH='' cd -P -- "${WORKSPACE_ROOT:-.}" 2> /dev/null && pwd -P); then
        PERSISTED_DIR="${WORKSPACE_ROOT_REAL%/}/images"
    else
        PERSISTED_DIR="${WORKSPACE_ROOT}/images"
    fi
    if [ "${ARCHIVE_DIR_REAL}" != "${PERSISTED_DIR}" ]; then
        echo "ERROR: persist_to_workspace is true, but archive_dir is not <workspace_root>/images." >&2
        echo "  archive_dir:    ${ARCHIVE_DIR} (resolves to ${ARCHIVE_DIR_REAL})" >&2
        echo "  workspace_root: ${WORKSPACE_ROOT}" >&2
        echo "  persisted:      ${PERSISTED_DIR}" >&2
        echo "The workspace step persists only the directory 'images' under workspace_root." >&2
        echo "Set archive_dir to <workspace_root>/images, or set persist_to_workspace to" >&2
        echo "false and persist the archive with your own persist_to_workspace step." >&2
        exit 1
    fi
fi

# Generate safe filename (replace / with -)
SAFE_NAME=$(echo "${IMAGE}" | tr '/' '-')
ARCHIVE_FILE="${ARCHIVE_DIR}/${SAFE_NAME}-img.tar"

echo "Saving image: ${FULL_IMAGE}"
echo "  Output: ${ARCHIVE_FILE}"

# Verify image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: Image '${FULL_IMAGE}' not found." >&2
    exit 1
fi

# Save image to tar
docker save -o "${ARCHIVE_FILE}" "${FULL_IMAGE}"

# Verify archive was created
if [ ! -f "${ARCHIVE_FILE}" ]; then
    echo "ERROR: Archive file was not created." >&2
    exit 1
fi

# Display archive info
ARCHIVE_SIZE=$(du -h "${ARCHIVE_FILE}" | cut -f1)
echo ""
echo "Successfully saved:"
echo "  Image: ${FULL_IMAGE}"
echo "  File: ${ARCHIVE_FILE}"
echo "  Size: ${ARCHIVE_SIZE}"

# Export path for subsequent steps
printf 'export %s=%q\n' ARCHIVED_IMAGE_PATH "${ARCHIVE_FILE}" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
printf 'export %s=%q\n' ARCHIVED_IMAGE_NAME "${SAFE_NAME}" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
