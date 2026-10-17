#!/bin/bash

# Docker Build Script
# Builds a Docker container image with support for multi-stage builds,
# OCI-compliant labels, buildx cross-platform builds, and multiple tags.

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
    IMAGE=$(printf '%s' "${PARAM_IMAGE}" | circleci env subst)
    TAGS=$(printf '%s' "${PARAM_TAGS}" | circleci env subst)
    DOCKERFILE=$(printf '%s' "${PARAM_DOCKERFILE}" | circleci env subst)
    BUILD_CONTEXT=$(printf '%s' "${PARAM_BUILD_CONTEXT}" | circleci env subst)
    TARGET=$(printf '%s' "${PARAM_TARGET}" | circleci env subst)
    BUILD_ARGS=$(printf '%s' "${PARAM_BUILD_ARGS}" | circleci env subst)
    EXTRA_ARGS=$(printf '%s' "${PARAM_EXTRA_ARGS}" | circleci env subst)
    IMAGE_VERSION=$(printf '%s' "${PARAM_IMAGE_VERSION}" | circleci env subst)
    PLATFORM=$(printf '%s' "${PARAM_PLATFORM}" | circleci env subst)
    BUILDX_BUILDER=$(printf '%s' "${PARAM_BUILDX_BUILDER}" | circleci env subst)
else
    IMAGE="${PARAM_IMAGE}"
    TAGS="${PARAM_TAGS}"
    DOCKERFILE="${PARAM_DOCKERFILE}"
    BUILD_CONTEXT="${PARAM_BUILD_CONTEXT}"
    TARGET="${PARAM_TARGET}"
    BUILD_ARGS="${PARAM_BUILD_ARGS}"
    EXTRA_ARGS="${PARAM_EXTRA_ARGS}"
    IMAGE_VERSION="${PARAM_IMAGE_VERSION}"
    PLATFORM="${PARAM_PLATFORM}"
    BUILDX_BUILDER="${PARAM_BUILDX_BUILDER}"
fi

OCI_LABELS="${PARAM_OCI_LABELS:-true}"
PULL="${PARAM_PULL:-false}"

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
echo "  Build context: ${BUILD_CONTEXT}"
if [ -n "${TARGET}" ]; then
    echo "  Target stage: ${TARGET}"
fi
if [ -n "${PLATFORM}" ]; then
    echo "  Platform: ${PLATFORM}"
fi

# Check that the Dockerfile exists where docker build -f looks for it: a
# relative path is resolved against the working directory, not the context.
if [ ! -f "${DOCKERFILE}" ]; then
    echo "ERROR: Dockerfile not found at ${DOCKERFILE} (working directory: $(pwd))"
    if [ -f "${BUILD_CONTEXT}/${DOCKERFILE}" ]; then
        echo "  ${BUILD_CONTEXT}/${DOCKERFILE} exists, but docker build resolves a relative"
        echo "  dockerfile against the working directory, not build_context."
        echo "  Set dockerfile to ${BUILD_CONTEXT}/${DOCKERFILE} to use it."
    fi
    exit 1
fi

# Build the docker command
BUILD_CMD=("docker")

# Use buildx when a target platform is given
if [ -n "${PLATFORM}" ]; then
    BUILD_CMD+=("buildx" "build")
    BUILD_CMD+=("--platform" "${PLATFORM}")
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
if [ "${PULL}" = "true" ] || [ "${PULL}" = "1" ]; then
    BUILD_CMD+=("--pull")
fi

# Enable BuildKit
export DOCKER_BUILDKIT=1

# Add OCI label build args
if [ "${OCI_LABELS}" = "true" ] || [ "${OCI_LABELS}" = "1" ]; then
    OCI_CREATED=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    OCI_REVISION="${CIRCLE_SHA1:-$(git rev-parse HEAD 2>/dev/null || echo 'unknown')}"

    # Determine version: image_version > CIRCLE_TAG > "dev"
    if [ -n "${IMAGE_VERSION}" ]; then
        OCI_VERSION="${IMAGE_VERSION}"
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

# Add user-provided build args: KEY=VALUE pairs separated by spaces, tabs or
# newlines. read splits without glob expansion; it returns non-zero at the
# end of its input, which is expected here.
BUILD_ARG_ARRAY=()
IFS=$' \t\n' read -r -d '' -a BUILD_ARG_ARRAY <<< "${BUILD_ARGS}" || true
for arg in "${BUILD_ARG_ARRAY[@]}"; do
    BUILD_CMD+=("--build-arg" "${arg}")
done

# Add extra args (split on spaces, respecting quotes)
if [ -n "${EXTRA_ARGS}" ]; then
    eval "BUILD_CMD+=(${EXTRA_ARGS})"
fi

# Add build context as last argument
BUILD_CMD+=("${BUILD_CONTEXT}")

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
