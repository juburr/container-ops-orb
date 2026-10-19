#!/bin/bash

# Resolve Pushed Digest Script
# Finds the digest the registry stored when this job pushed SOURCE_IMAGE to
# REPOSITORY, from the digests Docker recorded for that image, and exports it
# for later steps. Docker records the digest on push, so the result does not
# depend on where any tag points in the registry now.

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
    REPOSITORY=$(printf '%s' "${PARAM_REPOSITORY}" | circleci env subst)
else
    SOURCE_IMAGE="${PARAM_SOURCE_IMAGE}"
    REPOSITORY="${PARAM_REPOSITORY}"
fi

# Validate required parameters
if [ -z "${SOURCE_IMAGE}" ]; then
    echo "ERROR: source_image parameter is required." >&2
    exit 1
fi

if [ -z "${REPOSITORY}" ]; then
    echo "ERROR: repository parameter is required." >&2
    exit 1
fi

# Docker reports Docker Hub repositories by their short names (myorg/app or
# app), so compare names in docker.io/myorg/app form.
normalize_repository() {
    local repo="$1"
    local first="${repo%%/*}"

    if [[ "${repo}" != */* ]] || [[ "${first}" != *.* && "${first}" != *:* && "${first}" != "localhost" ]]; then
        repo="docker.io/${repo}"
    fi
    if [[ "${repo}" == index.docker.io/* ]]; then
        repo="docker.io/${repo#index.docker.io/}"
    fi
    if [[ "${repo}" == docker.io/* && "${repo#docker.io/}" != */* ]]; then
        repo="docker.io/library/${repo#docker.io/}"
    fi
    printf '%s\n' "${repo}"
}

echo "Resolving the pushed digest..."
echo "  Source image: ${SOURCE_IMAGE}"
echo "  Repository: ${REPOSITORY}"

if ! ENTRIES=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${SOURCE_IMAGE}"); then
    echo "ERROR: docker image inspect failed for '${SOURCE_IMAGE}'." >&2
    exit 1
fi

# RepoDigests lists one repository@digest entry per repository the image was
# pushed to or pulled from, in no particular order.
WANTED=$(normalize_repository "${REPOSITORY}")
DIGEST=""
while IFS= read -r ENTRY; do
    [ -z "${ENTRY}" ] && continue
    if [ "$(normalize_repository "${ENTRY%@*}")" != "${WANTED}" ]; then
        continue
    fi
    if [ -n "${DIGEST}" ] && [ "${DIGEST}" != "${ENTRY##*@}" ]; then
        echo "ERROR: Docker recorded more than one digest for ${REPOSITORY}: ${DIGEST} and ${ENTRY##*@}." >&2
        echo "The image was pushed to that repository more than once with different manifests." >&2
        exit 1
    fi
    DIGEST="${ENTRY##*@}"
done <<< "${ENTRIES}"

if [ -z "${DIGEST}" ]; then
    echo "ERROR: Docker has no digest recorded for ${REPOSITORY}." >&2
    echo "  RepoDigests of ${SOURCE_IMAGE}: $(printf '%s' "${ENTRIES}" | tr '\n' ' ')" >&2
    echo "Docker records a digest when it pushes the image, so check that the push to ${REPOSITORY} succeeded." >&2
    exit 1
fi

if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "ERROR: '${DIGEST}' recorded for ${REPOSITORY} is not a sha256 digest." >&2
    exit 1
fi

echo "  Digest: ${DIGEST}"
echo "  Reference: ${REPOSITORY}@${DIGEST}"

# Export the digest for subsequent steps
{
    printf 'export %s=%q\n' PUBLISHED_IMAGE_DIGEST "${DIGEST}"
    printf 'export %s=%q\n' PUBLISHED_IMAGE_DIGEST_REF "${REPOSITORY}@${DIGEST}"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true
