#!/bin/bash

# Docker Inspect Script
# Inspects a Docker image and displays its metadata.

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
    TAG=$(circleci env subst "${PARAM_TAG}")
else
    IMAGE="${PARAM_IMAGE}"
    TAG="${PARAM_TAG}"
fi

# Use BUILT_IMAGE_TAG from environment if tag not specified
if [ -z "${TAG}" ]; then
    TAG="${BUILT_IMAGE_TAG:-latest}"
fi

FULL_IMAGE="${IMAGE}:${TAG}"

echo "Inspecting image: ${FULL_IMAGE}"
echo ""

# Check if image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "ERROR: Image '${FULL_IMAGE}' not found."
    exit 1
fi

# Display image info
echo "=== Image Summary ==="
docker image inspect "${FULL_IMAGE}" --format '
Image ID: {{.Id}}
Created: {{.Created}}
Size: {{.Size}} bytes
Architecture: {{.Architecture}}
OS: {{.Os}}
'

echo ""
echo "=== Labels ==="
docker image inspect "${FULL_IMAGE}" --format '{{range $k, $v := .Config.Labels}}{{$k}}: {{$v}}
{{end}}'

echo ""
echo "=== Environment Variables ==="
docker image inspect "${FULL_IMAGE}" --format '{{range .Config.Env}}{{.}}
{{end}}'

echo ""
echo "=== Exposed Ports ==="
docker image inspect "${FULL_IMAGE}" --format '{{range $port, $_ := .Config.ExposedPorts}}{{$port}}
{{end}}'

echo ""
echo "=== Entrypoint ==="
docker image inspect "${FULL_IMAGE}" --format '{{.Config.Entrypoint}}'

echo ""
echo "=== Command ==="
docker image inspect "${FULL_IMAGE}" --format '{{.Config.Cmd}}'

echo ""
echo "=== Full JSON (truncated) ==="
docker image inspect "${FULL_IMAGE}" | head -100
echo "..."
echo "(Output truncated for readability)"
