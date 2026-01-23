#!/bin/bash

# Display Scan Results Script
# Outputs vulnerability scan results to the job logs.

set -euo pipefail

echo "=== Vulnerability Scan Results ==="
cat "${SCAN_OUTPUT_FILE}"
