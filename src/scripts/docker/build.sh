#!/bin/bash

# Docker Build Script
# Builds a Docker container image with support for multi-stage builds,
# OCI-compliant labels, buildx multi-platform builds, and multiple tags.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
REQUIRED_COMMANDS=("docker")
for CMD in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "$CMD" > /dev/null; then
        echo "FATAL: Command '$CMD' is required but not installed."
        exit 1
    fi
done

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGE=$(circleci env subst "${PARAM_IMAGE}")
    TAGS=$(circleci env subst "${PARAM_TAGS}")
    DOCKERFILE=$(circleci env subst "${PARAM_DOCKERFILE}")
    CONTEXT=$(circleci env subst "${PARAM_CONTEXT}")
    TARGET=$(circleci env subst "${PARAM_TARGET}")
    BUILD_ARGS=$(circleci env subst "${PARAM_BUILD_ARGS}")
    EXTRA_DOCKER_ARGS=$(circleci env subst "${PARAM_EXTRA_DOCKER_ARGS}")
    VERSION=$(circleci env subst "${PARAM_VERSION}")
    PLATFORMS=$(circleci env subst "${PARAM_PLATFORMS}")
    BUILDX_BUILDER=$(circleci env subst "${PARAM_BUILDX_BUILDER}")
else
    IMAGE="${PARAM_IMAGE}"
    TAGS="${PARAM_TAGS}"
    DOCKERFILE="${PARAM_DOCKERFILE}"
    CONTEXT="${PARAM_CONTEXT}"
    TARGET="${PARAM_TARGET}"
    BUILD_ARGS="${PARAM_BUILD_ARGS}"
    EXTRA_DOCKER_ARGS="${PARAM_EXTRA_DOCKER_ARGS}"
    VERSION="${PARAM_VERSION}"
    PLATFORMS="${PARAM_PLATFORMS}"
    BUILDX_BUILDER="${PARAM_BUILDX_BUILDER}"
fi

OCI_LABELS="${PARAM_OCI_LABELS:-true}"
USE_PULL_FLAG="${PARAM_USE_PULL_FLAG:-false}"

# Validate required parameters
if [ -z "${IMAGE}" ]; then
    echo "ERROR: image parameter is required."
    exit 1
fi

# Convert tags string to array (temporarily reset IFS for space-splitting)
IFS=' ' read -ra TAG_ARRAY <<< "${TAGS}"

if [ ${#TAG_ARRAY[@]} -eq 0 ]; then
    echo "ERROR: At least one tag is required."
    exit 1
fi

# Display build info
echo "Building image: ${IMAGE}"
echo "  Tags: ${TAGS}"
echo "  Dockerfile: ${DOCKERFILE}"
echo "  Context: ${CONTEXT}"
if [ -n "${TARGET}" ]; then
    echo "  Target stage: ${TARGET}"
fi
if [ -n "${PLATFORMS}" ]; then
    echo "  Platforms: ${PLATFORMS}"
fi

# Check if Dockerfile exists
if [ ! -f "${CONTEXT}/${DOCKERFILE}" ] && [ ! -f "${DOCKERFILE}" ]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE}"
    exit 1
fi

# Build the docker command
BUILD_CMD=("docker")

# Use buildx for multi-platform builds
if [ -n "${PLATFORMS}" ]; then
    BUILD_CMD+=("buildx" "build")
    BUILD_CMD+=("--platform" "${PLATFORMS}")
    if [ -n "${BUILDX_BUILDER}" ]; then
        BUILD_CMD+=("--builder" "${BUILDX_BUILDER}")
    fi
    # For buildx, we need --load to make the image available locally
    # Note: --load only works for single-platform builds
    BUILD_CMD+=("--load")
else
    BUILD_CMD+=("build")
fi

# Add Dockerfile path
BUILD_CMD+=("-f" "${DOCKERFILE}")

# Add all tags
for tag in "${TAG_ARRAY[@]}"; do
    BUILD_CMD+=("-t" "${IMAGE}:${tag}")
done

# Add target if specified
if [ -n "${TARGET}" ]; then
    BUILD_CMD+=("--target" "${TARGET}")
fi

# Add --pull flag if requested
if [ "${USE_PULL_FLAG}" = "true" ] || [ "${USE_PULL_FLAG}" = "1" ]; then
    BUILD_CMD+=("--pull")
fi

# Enable BuildKit
export DOCKER_BUILDKIT=1

# Add OCI label build args
if [ "${OCI_LABELS}" = "true" ] || [ "${OCI_LABELS}" = "1" ]; then
    OCI_CREATED=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    OCI_REVISION="${CIRCLE_SHA1:-$(git rev-parse HEAD 2>/dev/null || echo 'unknown')}"

    # Determine version: parameter > CIRCLE_TAG > "dev"
    if [ -n "${VERSION}" ]; then
        OCI_VERSION="${VERSION}"
    elif [ -n "${CIRCLE_TAG:-}" ]; then
        OCI_VERSION="${CIRCLE_TAG}"
    else
        OCI_VERSION="dev"
    fi

    OCI_SOURCE="${CIRCLE_REPOSITORY_URL:-}"

    BUILD_CMD+=("--build-arg" "OCI_CREATED=${OCI_CREATED}")
    BUILD_CMD+=("--build-arg" "OCI_REVISION=${OCI_REVISION}")
    BUILD_CMD+=("--build-arg" "OCI_VERSION=${OCI_VERSION}")

    if [ -n "${OCI_SOURCE}" ]; then
        BUILD_CMD+=("--build-arg" "OCI_SOURCE=${OCI_SOURCE}")
    fi

    echo ""
    echo "OCI Labels:"
    echo "  Created: ${OCI_CREATED}"
    echo "  Revision: ${OCI_REVISION}"
    echo "  Version: ${OCI_VERSION}"
    if [ -n "${OCI_SOURCE}" ]; then
        echo "  Source: ${OCI_SOURCE}"
    fi
fi

# Add user-provided build args
if [ -n "${BUILD_ARGS}" ]; then
    for arg in ${BUILD_ARGS}; do
        BUILD_CMD+=("--build-arg" "${arg}")
    done
fi

# Add extra docker args (split on spaces, respecting quotes)
if [ -n "${EXTRA_DOCKER_ARGS}" ]; then
    eval "BUILD_CMD+=(${EXTRA_DOCKER_ARGS})"
fi

# Add context as last argument
BUILD_CMD+=("${CONTEXT}")

# Execute build
echo ""
echo "Executing: ${BUILD_CMD[*]}"
echo ""

"${BUILD_CMD[@]}"

echo ""
echo "Successfully built image with tags:"
for tag in "${TAG_ARRAY[@]}"; do
    echo "  - ${IMAGE}:${tag}"
done

# Export the primary tag (first in list) for subsequent steps
PRIMARY_TAG="${TAG_ARRAY[0]}"
echo "export BUILT_IMAGE='${IMAGE}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
echo "export BUILT_IMAGE_TAG='${PRIMARY_TAG}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
echo "export BUILT_IMAGE_FULL='${IMAGE}:${PRIMARY_TAG}'" >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
