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
  # Keep the mounted workspace clean: -p no:cacheprovider drops pytest's
  # assertion-rewrite cache, and PYTHONDONTWRITEBYTECODE=1 +
  # PYTHONPYCACHEPREFIX redirect every imported module's __pycache__/*.pyc
  # off the bind-mount (into a container-local /tmp tree). Without this,
  # Isaac's bundled python writes framework/isaac_devkit/__pycache__/*.pyc
  # into the mounted tree owned by the container user, and the next
  # actions/checkout (running as the runner user) cannot unlink them
  # (EACCES) -- the same workspace-poison class the hosted leg already
  # guards against (#131 CI fix).
  GPU_PYTEST="${GPU_PYTEST_PATH:-test/integration/pytest/}"
  GPU_JUNIT="${GPU_JUNIT_PATH:-test/.gpu-pytest-report.xml}"
  # ROS 2 domain isolation. The example runner's /cmd_vel round-trip uses
  # network=host (the compose default), so on a shared self-hosted runner
  # it shares ROS_DOMAIN_ID=0 (baked into the compose `environment:`, which
  # outranks any env_file overlay) with every other ROS 2 node on the box
  # -- including leaked sibling ros:humble containers from the
  # cross-container test that keep publishing /cmd_vel (0.37/0.19). The
  # example runner's io.latest('/cmd_vel') then picks up that foreign
  # traffic, breaking the "latest() is None before publish" check and the
  # round-trip value assertion (it sees 0.37, not its own 0.42). Pass an
  # explicit ROS_DOMAIN_ID into the in-container pytest process via the
  # `env` wrapper -- a command-line env assignment outranks the container's
  # `environment:` for that process tree, and the example runner subprocess
  # inherits it -- so the run is isolated onto a private domain. CI passes
  # a per-run value via GPU_ROS_DOMAIN_ID; default 0 keeps local behavior.
  "${REPO_ROOT}/script/run.sh" -t test -- \
    env PYTHONDONTWRITEBYTECODE=1 PYTHONPYCACHEPREFIX=/tmp/gpu-pycache \
    ROS_DOMAIN_ID="${GPU_ROS_DOMAIN_ID:-0}" \
    /isaac-sim/python.sh -m pytest \
    "${GPU_PYTEST}" \
    -p no:cacheprovider \
    --junitxml="${GPU_JUNIT}"

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
  echo "in-container gpu-integration: collected=${total} passed=${passed} " \
    "skipped=${skipped} failures=${failures} errors=${errors}"

  # Host cross-container round-trip leg (isaac#132, PRD Pre-Publish item
  # 1). It spawns sibling ros:humble containers running the example/ros2/
  # ament nodes, so it CANNOT run inside the Isaac container (no docker
  # socket) -- it runs here on the self-hosted GPU host (which has docker
  # + the built isaac:test image). Its collected/passed counts are summed
  # into the GPU-integration totals below. -p no:cacheprovider keeps the
  # mounted tree clean. Skipped (not failed) on a host missing docker /
  # the test image -- a skip does NOT advance the passed counter, so the
  # "passed > 0" gate still rejects a non-GPU host.
  XC_PYTEST="${XC_PYTEST_PATH:-${REPO_ROOT}/test/integration/pytest/test_cross_container_roundtrip.py}"
  XC_REPORT="${REPO_ROOT}/test/.xc-pytest-report.xml"
  rm -f "${XC_REPORT}"
  xc_total=0; xc_failures=0; xc_errors=0; xc_skipped=0
  if python3 -m pytest --version >/dev/null 2>&1; then
    set +e
    python3 -m pytest "${XC_PYTEST}" -p no:cacheprovider \
      --junitxml="${XC_REPORT}"
    set -e
    if [[ -f "${XC_REPORT}" ]]; then
      read -r xc_total xc_failures xc_errors xc_skipped < <(
        python3 - "${XC_REPORT}" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
suite = root if root.tag == "testsuite" else root.find("testsuite")
attrs = suite.attrib if suite is not None else {}
print(attrs.get("tests", 0), attrs.get("failures", 0),
      attrs.get("errors", 0), attrs.get("skipped", 0))
PY
      )
    fi
  else
    echo "warning: host python3 has no pytest; cross-container leg not run" >&2
  fi
  xc_passed=$(( xc_total - xc_failures - xc_errors - xc_skipped ))
  echo "host cross-container: collected=${xc_total} passed=${xc_passed} " \
    "skipped=${xc_skipped} failures=${xc_failures} errors=${xc_errors}"

  # Fold the host leg into the GPU-integration aggregate.
  total=$(( total + xc_total ))
  passed=$(( passed + xc_passed ))
  failures=$(( failures + xc_failures ))
  errors=$(( errors + xc_errors ))
  skipped=$(( skipped + xc_skipped ))
  echo "gpu-integration (in-container + host xc): collected=${total} " \
    "passed=${passed} skipped=${skipped} failures=${failures} " \
    "errors=${errors}"

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
