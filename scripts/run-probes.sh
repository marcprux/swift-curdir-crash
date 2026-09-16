#!/bin/bash
# Runs every probe scenario in its own process, so that a crash in one scenario
# cannot hide the outcome of the others, and prints a table of the results.
#
#   usage: scripts/run-probes.sh <path-to-curdir-probe>
#
# Exits 0 even when scenarios crash: the point is to collect a full matrix of
# results for comparison. Set FAIL_ON_CRASH=1 to turn a crash into a failure.

set -uo pipefail

BIN=${1:?usage: run-probes.sh <path-to-curdir-probe>}
FAIL_ON_CRASH=${FAIL_ON_CRASH:-0}
LABEL=${LABEL:-$(basename "${BIN}")}

if [[ ! -x "${BIN}" ]]; then
    echo "error: ${BIN} is not an executable" >&2
    exit 1
fi

# Ask the binary itself which scenarios it knows about, so the list cannot drift
# out of step with the source.
SCENARIOS=()
while IFS= read -r line; do
    [[ -n "${line}" ]] && SCENARIOS+=("${line}")
done < <("${BIN}" --list)
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    echo "error: ${BIN} --list produced no scenarios" >&2
    exit 1
fi

echo "probe binary: ${BIN}"
file "${BIN}" || true
echo

crashes=0
rows=()

for scenario in "${SCENARIOS[@]}"; do
    output=$("${BIN}" "${scenario}" 2>&1)
    status=$?

    if [[ ${status} -eq 0 ]]; then
        verdict="ok"
    elif [[ ${status} -gt 128 ]]; then
        # A process killed by a signal reports 128+N through the shell; 139 is SIGSEGV.
        verdict="CRASH (signal $((status - 128)))"
        crashes=$((crashes + 1))
    else
        verdict="failed (exit ${status})"
    fi

    printf '=== %-18s %s\n' "${scenario}" "${verdict}"
    printf '%s\n\n' "${output}" | sed 's/^/    /'
    rows+=("| \`${scenario}\` | ${verdict} |")
done

echo "${crashes} of ${#SCENARIOS[@]} scenarios crashed"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        echo "### ${LABEL}"
        echo
        echo '| Scenario | Result |'
        echo '| --- | --- |'
        printf '%s\n' "${rows[@]}"
        echo
    } >> "${GITHUB_STEP_SUMMARY}"
fi

if [[ "${FAIL_ON_CRASH}" == "1" && ${crashes} -gt 0 ]]; then
    exit 1
fi
