#!/bin/bash

# Docker Login Script
# Authenticates with a container registry using Docker CLI.

set -euo pipefail
set +o history
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

# Get credentials from environment variables (indirection)
USERNAME="${!PARAM_USERNAME:-}"
PASSWORD="${!PARAM_PASSWORD:-}"

# Validate inputs
if [ -z "${REGISTRY}" ]; then
    echo "ERROR: Registry parameter is required."
    exit 1
fi

if [ -z "${USERNAME}" ]; then
    echo "ERROR: Username environment variable '${PARAM_USERNAME}' is not set or empty."
    exit 1
fi

if [ -z "${PASSWORD}" ]; then
    echo "ERROR: Password environment variable '${PARAM_PASSWORD}' is not set or empty."
    exit 1
fi

echo "Logging in to registry: ${REGISTRY}"

# Login using stdin for password (secure - avoids showing in process list)
echo "${PASSWORD}" | docker login "${REGISTRY}" -u "${USERNAME}" --password-stdin

# Cleanup sensitive variables
unset PASSWORD
unset PARAM_PASSWORD

echo "Successfully logged in to ${REGISTRY}"
