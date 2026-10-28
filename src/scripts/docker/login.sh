#!/bin/bash

# Docker Login Script
# Authenticates with a container registry using Docker CLI.

set -euo pipefail
# SHELLOPTS or a set -x in $BASH_ENV can turn on xtrace, which would print the password.
set +o xtrace
IFS=$'\n\t'

# Check for required commands
if ! command -v docker > /dev/null; then
    echo "ERROR: Command 'docker' is required but not installed." >&2
    exit 1
fi

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    REGISTRY=$(printf '%s' "${PARAM_REGISTRY}" | circleci env subst)
else
    REGISTRY="${PARAM_REGISTRY}"
fi

# Fails unless parameter $1's value, $2, is an environment variable name.
# CircleCI checks env_var_name parameters before the step runs; the GitHub
# Action passes any string. The value isn't printed, in case a secret was
# passed instead of a name.
require_var_name() {
    if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: The $1 parameter must be the name of an environment variable." >&2
        exit 1
    fi
}
require_var_name username "${PARAM_USERNAME}"
require_var_name password "${PARAM_PASSWORD}"

# Get credentials from environment variables (indirection)
USERNAME="${!PARAM_USERNAME:-}"
PASSWORD="${!PARAM_PASSWORD:-}"

# Validate inputs
if [ -z "${REGISTRY}" ]; then
    echo "ERROR: Registry parameter is required." >&2
    exit 1
fi

if [ -z "${USERNAME}" ]; then
    echo "ERROR: Username environment variable '${PARAM_USERNAME}' is not set or empty." >&2
    exit 1
fi

if [ -z "${PASSWORD}" ]; then
    echo "ERROR: Password environment variable '${PARAM_PASSWORD}' is not set or empty." >&2
    exit 1
fi

echo "Logging in to registry: ${REGISTRY}"

# Login using stdin for password (secure - avoids showing in process list).
# printf, unlike echo, does not take a password such as -n or -e as an option.
printf '%s\n' "${PASSWORD}" | docker login "${REGISTRY}" -u "${USERNAME}" --password-stdin

# Cleanup sensitive variables
unset PASSWORD
unset PARAM_PASSWORD

echo "Successfully logged in to ${REGISTRY}"
