#!/usr/bin/env bash
#
# Assert the pytest baseline (ADR-0017 section 7, isaac#130 / #132).
#
# Two modes, matching the CI hosted/self-hosted split:
#
#   (default, hosted)  Runs the hosted unit suite (test/unit/pytest/, no
#     Isaac Sim installed) in a plain Python container, then enforces:
#       1. all collected tests pass (a failure fails the job);
#       2. collected count >= HOSTED_UNIT_BASELINE (the ratchet -- a PR
#          may not drop the baseline);
#       3. framework pure-surface coverage >= 80% (--cov-fail-under).
#     Needs no GPU and no Isaac runtime: this is the M1 stage gate, run
#     on every PR independently of the GPU suite.
#
#   --gpu (self-hosted)  Runs the GPU integration suite
#     (test/integration/pytest/) inside the devel-test GPU container via
#     ./script/run.sh -t test, then enforces the M2 cross-runner gate:
#       1. the GPU suite actually RAN -- passed > 0 (an all-skipped or
#          collected-only GPU job does NOT count as green, PRD Testing &
#          Acceptance);
#       2. collected count >= GPU_INTEGRATION_BASELINE (ratchet);
#       3. the cross-runner aggregate (HOSTED_UNIT + GPU_INTEGRATION) >=
#          AGGREGATE_TARGET (the PRD 126 parity floor).
#     The hosted leg is re-derived from the baseline file (no second
#     container run); only the GPU collected/passed counts come from the
#     live GPU run.
#
# Usage:
#   test/assert_pytest_baseline.sh           # hosted-unit (M1 gate)
#   test/assert_pytest_baseline.sh --gpu     # GPU aggregate (M2 gate)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/test/pytest-baseline.txt"
PY_IMAGE="${PY_IMAGE:-python:3.11-slim}"

MODE="hosted"
if [[ "${1:-}" == "--gpu" ]]; then
  MODE="gpu"
fi

if [[ ! -f "${BASELINE_FILE}" ]]; then
  echo "error: baseline file not found: ${BASELINE_FILE}" >&2
  exit 1
fi

# Parse "KEY = N" from the baseline file (ignore comments / whitespace).
_baseline_val() {
  local key="$1"
  grep -E "^[[:space:]]*${key}[[:space:]]*=" "${BASELINE_FILE}" \
    | head -1 | sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/'
}

# ---------------------------------------------------------------------------
# --gpu mode: M2 cross-runner aggregate gate.
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "gpu" ]]; then
  hosted_baseline="$(_baseline_val HOSTED_UNIT_BASELINE)"
  gpu_baseline="$(_baseline_val GPU_INTEGRATION_BASELINE)"
  aggregate_target="$(_baseline_val AGGREGATE_TARGET)"
  for kv in "HOSTED_UNIT_BASELINE=${hosted_baseline}" \
            "GPU_INTEGRATION_BASELINE=${gpu_baseline}" \
            "AGGREGATE_TARGET=${aggregate_target}"; do
    if [[ -z "${kv#*=}" ]]; then
      echo "error: ${kv%=*} not found in ${BASELINE_FILE}" >&2
      exit 1
    fi
  done
  echo "gpu-integration baseline = ${gpu_baseline}"
  echo "hosted-unit baseline     = ${hosted_baseline}"
  echo "aggregate target         = ${aggregate_target}"

  # Run the GPU integration suite for real inside the devel-test
  # container. -p no:cacheprovider keeps the mounted tree clean. The
  # JUnit XML is the machine-readable source of passed/skipped counts;
  # it is written to a repo-relative path under the mounted workspace,
  # so the host reads the same file the container wrote regardless of the
  # container's absolute mount point. The caller passes the test path as
  # seen INSIDE the container via GPU_PYTEST_PATH (CI checkout = ~/work,
  # so test/integration/pytest/ resolves; a nested worktree sets it to
  # worktree/<name>/test/integration/pytest/).
  GPU_REPORT="${REPO_ROOT}/test/.gpu-pytest-report.xml"
  rm -f "${GPU_REPORT}"
  "${REPO_ROOT}/script/run.sh" -t test -- /isaac-sim/python.sh -m pytest \
    "${GPU_PYTEST_PATH:-test/integration/pytest/}" \
    -p no:cacheprovider \
    --junitxml="${GPU_JUNIT_PATH:-test/.gpu-pytest-report.xml}"

  if [[ ! -f "${GPU_REPORT}" ]]; then
    echo "error: GPU pytest produced no JUnit report (${GPU_REPORT}); " \
      "GPU job did not run -- not green" >&2
    exit 1
  fi

  # Pull tests / failures / errors / skipped off the (singular)
  # <testsuite> element. Parse the XML tree rather than regex so the
  # <testsuites> wrapper element is not mistaken for it.
  read -r total failures errors skipped < <(
    python3 - "${GPU_REPORT}" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
suite = root if root.tag == "testsuite" else root.find("testsuite")
attrs = suite.attrib if suite is not None else {}
print(attrs.get("tests", 0), attrs.get("failures", 0),
      attrs.get("errors", 0), attrs.get("skipped", 0))
PY
  )
  passed=$(( total - failures - errors - skipped ))
  echo "gpu-integration: collected=${total} passed=${passed} " \
    "skipped=${skipped} failures=${failures} errors=${errors}"

  if (( failures > 0 || errors > 0 )); then
    echo "error: GPU integration suite has failures/errors -- not green" >&2
    exit 1
  fi
  if (( passed < 1 )); then
    echo "error: GPU integration suite ran 0 passing tests (all skipped/" \
      "collected-only) -- a skipped GPU job does NOT count as green" >&2
    exit 1
  fi
  if (( total < gpu_baseline )); then
    echo "error: gpu-integration collected ${total} < baseline " \
      "${gpu_baseline} (ratchet violation)" >&2
    exit 1
  fi

  aggregate=$(( hosted_baseline + total ))
  echo "cross-runner aggregate = ${hosted_baseline} (hosted) + ${total} " \
    "(gpu) = ${aggregate}"
  if (( aggregate < aggregate_target )); then
    echo "error: aggregate ${aggregate} < target ${aggregate_target}" >&2
    exit 1
  fi
  echo "OK: gpu-integration ${total} >= ${gpu_baseline}, ${passed} passed, " \
    "aggregate ${aggregate} >= target ${aggregate_target}"
  exit 0
fi

# ---------------------------------------------------------------------------
# default mode: hosted-unit M1 gate.
# ---------------------------------------------------------------------------
baseline="$(_baseline_val HOSTED_UNIT_BASELINE)"
if [[ -z "${baseline}" ]]; then
  echo "error: HOSTED_UNIT_BASELINE not found in ${BASELINE_FILE}" >&2
  exit 1
fi
echo "hosted-unit baseline = ${baseline}"

# Run pytest with coverage inside the slim Python container. cd framework
# so coverage picks up [tool.coverage] from framework/pyproject.toml.
#
# Run the container as the host user (--user + HOME=/tmp). The repo is
# bind-mounted, so pytest's assertion-rewrite cache (__pycache__/*.pyc,
# which ignores PYTHONDONTWRITEBYTECODE / PYTHONPYCACHEPREFIX for test
# modules) lands in the mounted tree. As root those files are root-owned
# and poison a self-hosted runner's workspace: the next actions/checkout
# runs as the runner user and cannot unlink them (EACCES). Running as the
# invoking UID/GID makes any written cache owned by the runner user, so
# checkout's clean step removes it. pip installs into a per-run --user
# prefix under HOME=/tmp (writable for the non-root UID).
RUN_AS="$(id -u):$(id -g)"
docker run --rm --user "${RUN_AS}" -e HOME=/tmp \
  -v "${REPO_ROOT}":/w -w /w "${PY_IMAGE}" sh -c '
  set -eu
  pip install --quiet --user pyyaml pytest pytest-cov
  cd framework
  python -m pytest ../test/unit/pytest/ \
    -p no:cacheprovider \
    --cov=isaac_devkit --cov-report=term-missing --cov-fail-under=80
'

# Re-derive the collected count for the ratchet assertion.
collected="$(
  docker run --rm --user "${RUN_AS}" -e HOME=/tmp \
    -v "${REPO_ROOT}":/w -w /w "${PY_IMAGE}" sh -c '
    set -eu
    pip install --quiet --user pyyaml pytest >/dev/null
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
