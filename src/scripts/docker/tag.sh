#!/bin/bash

# Docker Tag Script
# Tags a local Docker image with multiple tags for a target registry.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "FATAL: Command 'docker' is required but not installed."
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    SOURCE_IMAGE=$(circleci env subst "${PARAM_SOURCE_IMAGE}")
    TARGET_IMAGE=$(circleci env subst "${PARAM_TARGET_IMAGE}")
    TAGS=$(circleci env subst "${PARAM_TAGS}")
else
    SOURCE_IMAGE="${PARAM_SOURCE_IMAGE}"
    TARGET_IMAGE="${PARAM_TARGET_IMAGE}"
    TAGS="${PARAM_TAGS}"
fi

# Validate required parameters
if [ -z "${SOURCE_IMAGE}" ]; then
    echo "ERROR: source_image parameter is required."
    exit 1
fi

if [ -z "${TARGET_IMAGE}" ]; then
    echo "ERROR: target_image parameter is required."
    exit 1
fi

if [ -z "${TAGS}" ]; then
    echo "ERROR: tags parameter is required."
    exit 1
fi

echo "Tagging image for registry..."
echo "  Source: ${SOURCE_IMAGE}"
echo "  Target: ${TARGET_IMAGE}"
echo "  Tags: ${TAGS}"
echo ""

# Verify source image exists
if ! docker image inspect "${SOURCE_IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: Source image not found: ${SOURCE_IMAGE}"
    echo ""
    echo "Available images:"
    docker images --format "  {{.Repository}}:{{.Tag}}"
    exit 1
fi

# Parse tags and apply each one
FIRST_TAG=""
IFS=' ' read -ra TAG_ARRAY <<< "${TAGS}"
for TAG in "${TAG_ARRAY[@]}"; do
    # Skip empty tags
    if [ -z "${TAG}" ]; then
        continue
    fi

    FULL_TARGET="${TARGET_IMAGE}:${TAG}"
    echo "Tagging: ${FULL_TARGET}"
    docker tag "${SOURCE_IMAGE}" "${FULL_TARGET}"

    # Track first tag for environment export
    if [ -z "${FIRST_TAG}" ]; then
        FIRST_TAG="${TAG}"
    fi
done

echo ""
echo "Successfully tagged image with ${#TAG_ARRAY[@]} tag(s)."

# Export tagged image info to BASH_ENV for subsequent steps
{
    echo "export TAGGED_IMAGE='${TARGET_IMAGE}'"
    echo "export TAGGED_IMAGE_TAG='${FIRST_TAG}'"
    echo "export TAGGED_IMAGE_FULL='${TARGET_IMAGE}:${FIRST_TAG}'"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
