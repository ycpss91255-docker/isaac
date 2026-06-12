#!/usr/bin/env bash
#
# agent_proxy_gate.sh - the M5 onboarding agent-proxy gate harness (isaac#135).
#
# The PRD onboarding metric (M5) is: a fresh agent or newcomer given ONLY
# `example/` + its README can scaffold -> run -> swap WITHOUT reading the
# framework source. This harness makes that gate repeatable. It has two
# parts, run in sequence by the gate runbook (doc/onboarding/agent-proxy-gate.md):
#
#   1. STRUCTURE PRECONDITION (this script, default mode). The mechanical,
#      repeatable half: assert that `example/` + the example README are
#      self-sufficient for the three onboarding tasks BEFORE a proxy run --
#      i.e. the README exists in 4 languages, documents the three tasks,
#      carries the lidar/imu out-of-scope callout, and the camera_bot URDF
#      + the per-sensor `custom.yaml` (the in-scope swap surfaces) are
#      present. If this fails, the proxy cannot possibly pass, so the gate
#      short-circuits here. This is the part hosted CI / a developer can
#      re-run any time; the pytest mirror lives in
#      test/unit/pytest/test_onboarding_gate.py.
#
#   2. TOOL-CALL AUDIT (--audit <log>). The enforcement half. The proxy run
#      itself is driven by an agent harness (the orchestrator spawns a fresh
#      general-purpose sub-agent with ONLY the example/ + README context and
#      the three tasks, forbidding framework reads). That run emits a
#      tool-call log; this mode greps the log for any read of
#      framework/isaac_devkit/* and FAILS the gate if one is found. This is
#      the mechanical "audit the tool-call log" enforcement the PRD names as
#      the fallback when framework/ cannot be made unreadable in-process.
#
# Enforcement level (be honest, per the issue DoD): making framework/
# unreadable mid-run is NOT mechanically enforceable in this harness (the
# sub-agent shares the read-only filesystem; we cannot chmod the mounted
# tree). So enforcement is ADVISORY-via-AUDIT: the structure precondition is
# mechanical and repeatable, and the tool-call audit is mechanical WHEN a log
# is supplied, but nothing physically blocks a read at the moment it happens.
# The pre-1.0.0 human dry-run (doc/onboarding/agent-proxy-gate.md, step 4)
# is the real backstop and stays OPEN until a human runs it before v1.0.0.
#
# Usage:
#   test/onboarding/agent_proxy_gate.sh                 # structure precondition
#   test/onboarding/agent_proxy_gate.sh --audit <log>   # tool-call audit only
#   test/onboarding/agent_proxy_gate.sh --help
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXAMPLE_DIR="${REPO_ROOT}/example"
README_BASENAME="README"
# The framework source path that a passing proxy run must NOT touch.
FRAMEWORK_GLOB="framework/isaac_devkit/"

_fail() {
  printf '[onboarding-gate] FAIL: %s\n' "$*" >&2
  exit 1
}

_ok() {
  printf '[onboarding-gate] ok: %s\n' "$*"
}

_usage() {
  awk '/^# Usage:/{s=1} s&&/^[^#]/{exit} s{sub(/^# ?/,"");print}' \
    "${BASH_SOURCE[0]}"
}

# ---------------------------------------------------------------------------
# --audit mode: scan a proxy tool-call log for framework-source reads.
# ---------------------------------------------------------------------------
_audit_log() {
  local log="$1"
  [[ -f "${log}" ]] || _fail "audit log not found: ${log}"
  # Any line that both names a read/open/cat-like access AND the framework
  # source path is a violation. Keep the match broad: the log format is the
  # agent harness's, so match the path substring on any line.
  if grep -nE "${FRAMEWORK_GLOB}" "${log}" >/dev/null 2>&1; then
    printf '[onboarding-gate] FAIL: framework source referenced in proxy log:\n' >&2
    grep -nE "${FRAMEWORK_GLOB}" "${log}" >&2
    exit 1
  fi
  _ok "audit: no framework/isaac_devkit/* read in ${log}"
  echo "[onboarding-gate] AUDIT PASS"
}

# ---------------------------------------------------------------------------
# default mode: structure precondition.
# ---------------------------------------------------------------------------
_check_structure() {
  [[ -d "${EXAMPLE_DIR}" ]] || _fail "example/ not found at ${EXAMPLE_DIR}"

  # (a) The onboarding README exists in all four languages and lives next to
  #     the example the proxy is given.
  local langs=("md" "zh-TW.md" "zh-CN.md" "ja.md")
  local readme="${EXAMPLE_DIR}/${README_BASENAME}"
  local lang
  for lang in "${langs[@]}"; do
    [[ -f "${readme}.${lang}" ]] \
      || _fail "missing onboarding README: ${readme}.${lang}"
  done
  _ok "4-lang example README present"

  # (b) The English README documents the three onboarding tasks (first-topic
  #     via scaffold/run, URDF swap, in-scope sensor swap) so a fresh agent
  #     can do all three without reading framework source.
  local en="${readme}.md"
  grep -qiE "new-workspace|just run|first.?topic|camera topic" "${en}" \
    || _fail "README does not document the first-topic / run path"
  grep -qiE "URDF|swap.*robot|swap.*URDF" "${en}" \
    || _fail "README does not document the URDF swap task"
  grep -qiE "resolution|fps|second camera|topic override|sensor swap" "${en}" \
    || _fail "README does not document the in-scope sensor swap task"
  _ok "README documents the three onboarding tasks"

  # (c) The lidar/imu NotImplementedError out-of-scope boundary is an
  #     explicit callout (the documented edge of the in-scope sensor swap).
  grep -qiE "NotImplementedError" "${en}" \
    || _fail "README does not call out the NotImplementedError boundary"
  grep -qiE "lidar|imu" "${en}" \
    || _fail "README boundary callout does not name lidar/imu"
  grep -qiE "out of scope|out-of-scope|not yet implemented|not implemented" \
    "${en}" \
    || _fail "README does not mark the boundary as out of scope"
  _ok "README carries the lidar/imu out-of-scope callout"

  # (d) The swap surfaces the proxy edits exist: the camera_bot URDF (URDF
  #     swap) and the per-sensor custom.yaml (sensor swap) without needing
  #     to open framework source.
  [[ -f "${EXAMPLE_DIR}/sim/model/camera_bot.urdf" ]] \
    || _fail "camera_bot.urdf (URDF-swap surface) missing"
  [[ -f "${EXAMPLE_DIR}/sim/config/sensor/custom.yaml" ]] \
    || _fail "custom.yaml (sensor-swap surface) missing"
  _ok "URDF + sensor swap surfaces present"

  echo "[onboarding-gate] STRUCTURE PASS"
}

main() {
  case "${1:-}" in
    -h|--help)
      _usage
      ;;
    --audit)
      [[ $# -ge 2 ]] || _fail "--audit needs a log path"
      _audit_log "$2"
      ;;
    "")
      _check_structure
      ;;
    *)
      _fail "unknown argument: $1 (try --help)"
      ;;
  esac
}

main "$@"
