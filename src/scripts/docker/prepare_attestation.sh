#!/bin/bash

# Prepare Attestation Script
# Determines the SBOM file path and predicate type for cosign attestation.

set -euo pipefail
IFS=$'\n\t'

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    IMAGE=$(circleci env subst "${PARAM_IMAGE}")
    SBOM_FORMAT=$(circleci env subst "${PARAM_SBOM_FORMAT}")
else
    IMAGE="${PARAM_IMAGE}"
    SBOM_FORMAT="${PARAM_SBOM_FORMAT}"
fi

echo "Preparing SBOM attestation..."
echo "  Image: ${IMAGE}"
echo "  SBOM Format: ${SBOM_FORMAT}"

# Determine SBOM file path based on format
SBOM_FILE=""
PREDICATE_TYPE=""

if [ "${SBOM_FORMAT}" = "spdx-json" ]; then
    SBOM_FILE=$(find sboms -maxdepth 1 -name "*.spdx.json" -type f 2>/dev/null | head -1) || true
    PREDICATE_TYPE="spdxjson"
else
    SBOM_FILE=$(find sboms -maxdepth 1 -name "*.cdx.json" -type f 2>/dev/null | head -1) || true
    PREDICATE_TYPE="cyclonedx"
fi

if [ -z "${SBOM_FILE}" ]; then
    echo "ERROR: No SBOM file found in sboms/ directory"
    echo ""
    echo "Available files in sboms/:"
    ls -la sboms/ 2>/dev/null || echo "  (directory does not exist)"
    exit 1
fi

echo "  SBOM File: ${SBOM_FILE}"
echo "  Predicate Type: ${PREDICATE_TYPE}"

# Export for subsequent cosign/attest command
{
    echo "export SBOM_FILE='${SBOM_FILE}'"
    echo "export PREDICATE_TYPE='${PREDICATE_TYPE}'"
} >> "${BASH_ENV:-/dev/null}" 2>/dev/null || true

echo ""
echo "Attestation preparation complete."
