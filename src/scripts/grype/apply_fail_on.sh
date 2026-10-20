#!/bin/bash

# Apply fail_on Script
# Fails the job when the scan's JSON report has a vulnerability at or above
# fail_on. The scan itself runs with fail_on never, so the report is printed
# and stored before this step decides. The rule is Grype's own --fail-on:
# matches Grype did not ignore, ranked negligible < low < medium < high <
# critical, with an unknown severity below negligible.

set -euo pipefail
IFS=$'\n\t'

# Parse parameters with circleci env subst support
if command -v circleci &> /dev/null; then
    FAIL_ON=$(printf '%s' "${PARAM_FAIL_ON}" | circleci env subst)
else
    FAIL_ON="${PARAM_FAIL_ON}"
fi

case "${FAIL_ON}" in
    never)
        echo "fail_on is never: vulnerabilities are reported without failing the job."
        exit 0
        ;;
    negligible | low | medium | high | critical) ;;
    *)
        echo "ERROR: fail_on must be critical, high, medium, low, negligible, or never; got '${FAIL_ON}'." >&2
        exit 1
        ;;
esac

if ! command -v jq > /dev/null; then
    echo "ERROR: Command 'jq' is required to apply fail_on but not installed." >&2
    exit 1
fi

# Written by prepare_scan.sh.
GATE_FILE="${SCAN_GATE_FILE:-}"
if [ -z "${GATE_FILE}" ] || [ ! -f "${GATE_FILE}" ]; then
    echo "ERROR: The JSON report for fail_on was not found: '${GATE_FILE}'." >&2
    exit 1
fi

echo "Applying fail_on=${FAIL_ON} to ${GATE_FILE}..."

# One line per match at or above fail_on. An unreadable report, or one
# without a matches list, fails the step rather than passing it.
if ! FINDINGS=$(jq -r --arg fail_on "${FAIL_ON}" '
    {"negligible": 1, "low": 2, "medium": 3, "high": 4, "critical": 5} as $rank
    | if (.matches | type) != "array" then error("the report has no matches list") else . end
    | .matches[]
    | select(($rank[(.vulnerability.severity // "") | ascii_downcase] // 0) >= $rank[$fail_on])
    | "\(.vulnerability.id) (\(.vulnerability.severity)) in \(.artifact.name) \(.artifact.version)"
    ' "${GATE_FILE}"); then
    echo "ERROR: Could not read the vulnerability matches in ${GATE_FILE}." >&2
    exit 1
fi

if [ -z "${FINDINGS}" ]; then
    echo "No vulnerabilities at or above ${FAIL_ON}."
    exit 0
fi

COUNT=0
echo "Vulnerabilities at or above ${FAIL_ON}:"
while IFS= read -r FINDING; do
    echo "  - ${FINDING}"
    COUNT=$((COUNT + 1))
done <<< "${FINDINGS}"

echo "ERROR: fail_on=${FAIL_ON} and ${COUNT} vulnerability match(es) at or above ${FAIL_ON}; failing the job." >&2
exit 1
