#!/bin/bash

# Prepare Scan Configuration Script
# Determines the scan target and output file based on image source and parameters.

set -euo pipefail
IFS=$'\n\t'

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
    TAG=$(printf '%s' "${PARAM_TAG}" | circleci env subst)
    IMAGE_SOURCE=$(printf '%s' "${PARAM_IMAGE_SOURCE}" | circleci env subst)
    ARCHIVE_DIR=$(printf '%s' "${PARAM_ARCHIVE_DIR}" | circleci env subst)
    REGISTRY=$(printf '%s' "${PARAM_REGISTRY}" | circleci env subst)
    REGISTRY_NAMESPACE=$(printf '%s' "${PARAM_REGISTRY_NAMESPACE}" | circleci env subst)
    OUTPUT_DIR=$(printf '%s' "${PARAM_OUTPUT_DIR}" | circleci env subst)
    OUTPUT_FORMAT=$(printf '%s' "${PARAM_OUTPUT_FORMAT}" | circleci env subst)
else
    IMAGE="${PARAM_IMAGE}"
    TAG="${PARAM_TAG}"
    IMAGE_SOURCE="${PARAM_IMAGE_SOURCE}"
    ARCHIVE_DIR="${PARAM_ARCHIVE_DIR}"
    REGISTRY="${PARAM_REGISTRY}"
    REGISTRY_NAMESPACE="${PARAM_REGISTRY_NAMESPACE}"
    OUTPUT_DIR="${PARAM_OUTPUT_DIR}"
    OUTPUT_FORMAT="${PARAM_OUTPUT_FORMAT}"
fi

# Expand ~ to home directory
ARCHIVE_DIR="${ARCHIVE_DIR/#\~/$HOME}"

echo "Preparing scan configuration..."
echo "  Image: ${IMAGE}"
echo "  Tag: ${TAG}"
echo "  Image Source: ${IMAGE_SOURCE}"
echo "  Archive Directory: ${ARCHIVE_DIR}"
echo "  Registry: ${REGISTRY:-<not set>}"
echo "  Registry Namespace: ${REGISTRY_NAMESPACE:-<not set>}"
echo "  Output Directory: ${OUTPUT_DIR}"
echo "  Output Format: ${OUTPUT_FORMAT}"
echo ""

# Determine scan target based on image source
SCAN_TARGET=""
case "${IMAGE_SOURCE}" in
    "local")
        # Scan local docker image (loaded from archive)
        SCAN_TARGET="${IMAGE}:${TAG}"
        echo "Scan mode: Local Docker image"
        ;;
    "registry")
        # Scan image directly from registry
        if [ -n "${REGISTRY}" ] && [ -n "${REGISTRY_NAMESPACE}" ]; then
            SCAN_TARGET="${REGISTRY}/${REGISTRY_NAMESPACE}/${IMAGE}:${TAG}"
        elif [ -n "${REGISTRY}" ]; then
            SCAN_TARGET="${REGISTRY}/${IMAGE}:${TAG}"
        else
            # Assume IMAGE contains full path
            SCAN_TARGET="${IMAGE}"
        fi
        echo "Scan mode: Registry image"
        ;;
    "archive")
        # Scan tar archive directly using docker-archive: scheme
        SAFE_NAME=$(echo "${IMAGE}" | tr '/' '-')
        ARCHIVE_FILE="${ARCHIVE_DIR}/${SAFE_NAME}-img.tar"
        SCAN_TARGET="docker-archive:${ARCHIVE_FILE}"
        echo "Scan mode: Archive file"
        echo "  Archive file: ${ARCHIVE_FILE}"
        ;;
    *)
        echo "ERROR: Invalid image_source: ${IMAGE_SOURCE}"
        echo "Valid options: local, registry, archive"
        exit 1
        ;;
esac

echo "  Scan target: ${SCAN_TARGET}"

# Generate sanitized output filename
# Replace / and : with __ to create filesystem-safe names
SANITIZED_NAME="${SCAN_TARGET}"
SANITIZED_NAME="${SANITIZED_NAME//\//__}"
SANITIZED_NAME="${SANITIZED_NAME//:/__}"

# Determine file extension based on format
case "${OUTPUT_FORMAT}" in
    "json")
        FILE_EXT="json"
        ;;
    "sarif")
        FILE_EXT="sarif"
        ;;
    "table")
        FILE_EXT="txt"
        ;;
    "cyclonedx")
        FILE_EXT="cdx.xml"
        ;;
    "cyclonedx-json")
        FILE_EXT="cdx.json"
        ;;
    *)
        FILE_EXT="${OUTPUT_FORMAT}"
        ;;
esac

SCAN_OUTPUT_FILE="${OUTPUT_DIR}/${SANITIZED_NAME}.grype.${FILE_EXT}"

echo "  Output file: ${SCAN_OUTPUT_FILE}"
echo ""

# Export variables for subsequent steps
{
    echo "export SCAN_TARGET='${SCAN_TARGET}'"
    echo "export SCAN_OUTPUT_FILE='${SCAN_OUTPUT_FILE}'"
    echo "export SANITIZED_IMAGE_NAME='${SANITIZED_NAME}'"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true

echo "Scan configuration complete."
