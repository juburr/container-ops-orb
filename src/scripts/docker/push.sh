#!/bin/bash

# Docker Push Script
# Pushes Docker image tags to a container registry.

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
    TAGS=$(circleci env subst "${PARAM_TAGS}")
else
    IMAGE="${PARAM_IMAGE}"
    TAGS="${PARAM_TAGS}"
fi

# Validate required parameters
if [ -z "${IMAGE}" ]; then
    echo "ERROR: image parameter is required."
    exit 1
fi

if [ -z "${TAGS}" ]; then
    echo "ERROR: tags parameter is required."
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
for TAG in "${TAG_ARRAY[@]}"; do
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
    echo "export PUSHED_IMAGE='${IMAGE}'"
    echo "export PUSHED_IMAGE_TAG='${FIRST_PUSHED}'"
    echo "export PUSHED_IMAGE_FULL='${IMAGE}:${FIRST_PUSHED}'"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
