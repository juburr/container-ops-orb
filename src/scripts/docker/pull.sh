#!/bin/bash

# Docker Pull Script
# Pulls one or more container images from a registry.
# Pull failures are treated as warnings since images may exist locally.
# The images parameter is split on whitespace (spaces, tabs or newlines).

set -uo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "FATAL: Command 'docker' is required but not installed."
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGES=$(printf '%s' "${PARAM_IMAGES}" | circleci env subst)
else
    IMAGES="${PARAM_IMAGES}"
fi

# Split on whitespace without glob expansion. read returns non-zero at the
# end of its input, which is expected here.
IMAGE_ARRAY=()
IFS=$' \t\n' read -r -d '' -a IMAGE_ARRAY <<< "${IMAGES}" || true

if [ ${#IMAGE_ARRAY[@]} -eq 0 ]; then
    echo "No images specified to pull. Skipping."
    exit 0
fi

echo "Pulling base images..."
echo ""

# Track results
PULL_SUCCESS=0
PULL_FAILED=0

# Pull each image
for image in "${IMAGE_ARRAY[@]}"; do
    echo "Pulling: ${image}"
    if docker pull "${image}"; then
        echo "  Success: ${image}"
        ((PULL_SUCCESS++))
    else
        echo "  WARNING: Failed to pull ${image}"
        echo "  This may be expected if the image only exists locally."
        ((PULL_FAILED++))
    fi
    echo ""
done

echo "Pull summary:"
echo "  Successful: ${PULL_SUCCESS}"
echo "  Warnings: ${PULL_FAILED}"
echo ""

# Always succeed - failed pulls may be expected for local-only images
exit 0
