#!/bin/bash

# Docker Tag Script
# Tags a local Docker image with multiple tags for a target registry.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "ERROR: Command 'docker' is required but not installed." >&2
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    SOURCE_IMAGE=$(printf '%s' "${PARAM_SOURCE_IMAGE}" | circleci env subst)
    TARGET_IMAGE=$(printf '%s' "${PARAM_TARGET_IMAGE}" | circleci env subst)
    TAGS=$(printf '%s' "${PARAM_TAGS}" | circleci env subst)
else
    SOURCE_IMAGE="${PARAM_SOURCE_IMAGE}"
    TARGET_IMAGE="${PARAM_TARGET_IMAGE}"
    TAGS="${PARAM_TAGS}"
fi

# Validate required parameters
if [ -z "${SOURCE_IMAGE}" ]; then
    echo "ERROR: source_image parameter is required." >&2
    exit 1
fi

if [ -z "${TARGET_IMAGE}" ]; then
    echo "ERROR: target_image parameter is required." >&2
    exit 1
fi

if [ -z "${TAGS}" ]; then
    echo "ERROR: tags parameter is required." >&2
    exit 1
fi

echo "Tagging image for registry..."
echo "  Source: ${SOURCE_IMAGE}"
echo "  Target: ${TARGET_IMAGE}"
echo "  Tags: ${TAGS}"
echo ""

# Verify source image exists
if ! docker image inspect "${SOURCE_IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: Source image not found: ${SOURCE_IMAGE}" >&2
    echo "" >&2
    echo "Available images:" >&2
    docker images --format "  {{.Repository}}:{{.Tag}}" >&2
    exit 1
fi

# Parse tags and apply each one
FIRST_TAG=""
IFS=' ' read -ra TAG_ARRAY <<< "${TAGS}"
# Empty when the first line of tags is blank or only spaces. Bash before 4.4
# treats an empty array as unset under set -u, so expand it only when set.
for TAG in ${TAG_ARRAY[@]+"${TAG_ARRAY[@]}"}; do
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
    printf 'export %s=%q\n' TAGGED_IMAGE "${TARGET_IMAGE}"
    printf 'export %s=%q\n' TAGGED_IMAGE_TAG "${FIRST_TAG}"
    printf 'export %s=%q\n' TAGGED_IMAGE_FULL "${TARGET_IMAGE}:${FIRST_TAG}"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
