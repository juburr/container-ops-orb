#!/bin/bash

# Docker Push Script
# Pushes Docker image tags to a container registry.

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
    TAGS=$(printf '%s' "${PARAM_TAGS}" | circleci env subst)
else
    IMAGE="${PARAM_IMAGE}"
    TAGS="${PARAM_TAGS}"
fi

# Validate required parameters
if [ -z "${IMAGE}" ]; then
    echo "ERROR: image parameter is required." >&2
    exit 1
fi

if [ -z "${TAGS}" ]; then
    echo "ERROR: tags parameter is required." >&2
    exit 1
fi

echo "Pushing image to registry..."
echo "  Image: ${IMAGE}"
echo "  Tags: ${TAGS}"
echo ""

# Parse tags and push each one
PUSH_COUNT=0
FIRST_PUSHED=""
IFS=' ' read -ra TAG_ARRAY <<< "${TAGS}"
# Empty when the first line of tags is blank or only spaces. Bash before 4.4
# treats an empty array as unset under set -u, so expand it only when set.
for TAG in ${TAG_ARRAY[@]+"${TAG_ARRAY[@]}"}; do
    # Skip empty tags
    if [ -z "${TAG}" ]; then
        continue
    fi

    FULL_IMAGE="${IMAGE}:${TAG}"
    echo "Pushing: ${FULL_IMAGE}"
    docker push "${FULL_IMAGE}"
    PUSH_COUNT=$((PUSH_COUNT + 1))

    # Track first pushed tag
    if [ -z "${FIRST_PUSHED}" ]; then
        FIRST_PUSHED="${TAG}"
    fi

    echo ""
done

echo "Successfully pushed ${PUSH_COUNT} tag(s) to registry."

# Export pushed image info to BASH_ENV for subsequent steps
{
    printf 'export %s=%q\n' PUSHED_IMAGE "${IMAGE}"
    printf 'export %s=%q\n' PUSHED_IMAGE_TAG "${FIRST_PUSHED}"
    printf 'export %s=%q\n' PUSHED_IMAGE_FULL "${IMAGE}:${FIRST_PUSHED}"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
