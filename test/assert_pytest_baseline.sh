#!/usr/bin/env bash
#
# Assert the hosted-unit pytest baseline (ADR-0017 section 7, isaac#130).
#
# Runs the hosted unit suite (test/unit/pytest/, no Isaac Sim installed)
# in a plain Python container, then enforces:
#   1. all collected tests pass (a failure fails the job);
#   2. collected count >= HOSTED_UNIT_BASELINE from test/pytest-baseline.txt
#      (the ratchet -- a PR may not drop the baseline);
#   3. framework pure-surface coverage >= 80% (--cov-fail-under, the
#      [tool.coverage] exclude_also config drops Isaac-side function-local
#      code).
#
# Hosted by design: needs no GPU and no Isaac runtime, so it runs the M1
# stage gate independently of the self-hosted GPU integration suite.
#
# Usage: test/assert_pytest_baseline.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/test/pytest-baseline.txt"
PY_IMAGE="${PY_IMAGE:-python:3.11-slim}"

if [[ ! -f "${BASELINE_FILE}" ]]; then
  echo "error: baseline file not found: ${BASELINE_FILE}" >&2
  exit 1
fi

# Parse "HOSTED_UNIT_BASELINE = N" (ignore comments / whitespace).
baseline="$(
  grep -E '^[[:space:]]*HOSTED_UNIT_BASELINE[[:space:]]*=' "${BASELINE_FILE}" \
    | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/'
)"
if [[ -z "${baseline}" ]]; then
  echo "error: HOSTED_UNIT_BASELINE not found in ${BASELINE_FILE}" >&2
  exit 1
fi
echo "hosted-unit baseline = ${baseline}"

# Run pytest with coverage inside the slim Python container. cd framework
# so coverage picks up [tool.coverage] from framework/pyproject.toml.
docker run --rm -v "${REPO_ROOT}":/w -w /w "${PY_IMAGE}" sh -c '
  set -eu
  pip install --quiet pyyaml pytest pytest-cov
  cd framework
  python -m pytest ../test/unit/pytest/ \
    -p no:cacheprovider \
    --cov=isaac_devkit --cov-report=term-missing --cov-fail-under=80
'

# Re-derive the collected count for the ratchet assertion.
collected="$(
  docker run --rm -v "${REPO_ROOT}":/w -w /w "${PY_IMAGE}" sh -c '
    set -eu
    pip install --quiet pyyaml pytest >/dev/null
    python -m pytest test/unit/pytest/ --collect-only -q -p no:cacheprovider \
      2>/dev/null | grep -c "::"
  '
)"
echo "hosted-unit collected = ${collected}"

if (( collected < baseline )); then
  echo "error: hosted-unit collected ${collected} < baseline ${baseline}" \
    "(ratchet violation)" >&2
  exit 1
fi
echo "OK: hosted-unit ${collected} >= baseline ${baseline}, all green, coverage >= 80%"
