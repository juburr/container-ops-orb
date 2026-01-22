#!/bin/bash

# Docker Logout Script
# Logs out from a container registry and cleans up stored credentials.

set -euo pipefail
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "FATAL: Command 'docker' is required but not installed."
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    REGISTRY=$(circleci env subst "${PARAM_REGISTRY}")
else
    REGISTRY="${PARAM_REGISTRY}"
fi

# Validate inputs
if [ -z "${REGISTRY}" ]; then
    echo "ERROR: Registry parameter is required."
    exit 1
fi

echo "Logging out from registry: ${REGISTRY}"

docker logout "${REGISTRY}"

echo "Successfully logged out from ${REGISTRY}"
