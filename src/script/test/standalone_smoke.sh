#!/usr/bin/env bash
# Smoke test for isaac_ws/src/script/*_standalone.py
#
# For each standalone script: launch via ./exec.sh -t standalone, watch
# stdout for the script's "ready marker" phrase, kill once seen. If the
# marker doesn't appear within TIMEOUT, the case fails.
#
# Why integration not unit:
#   These scripts boot kit + livestream + rclpy; pure-Python unit tests
#   can't substitute for "does it actually reach the ROS subscriber loop".
#   The marker phrase is the contract — each script prints exactly one
#   line "<tag> standalone <verb> ..." once its core setup finished.
#
# Why this lives in isaac_ws/src/script/test/:
#   The script dir is the natural home; isaac_ws/src/script/ is currently
#   not git-tracked so a separate per-repo test dir wasn't picked.
#
# Exit codes:
#   0 = all PASS (SKIPped cases tolerated by default)
#   1 = at least one FAIL
#   2 = pre-flight failure (docker dir missing / standalone container won't start)
#
# Flags:
#   --strict       Treat SKIP as FAIL (e.g. CI where USD must be pre-generated).
#   --only <name>  Run a single case by script basename (substring match).
#   -h, --help     Print usage.
#
# Typical run (full matrix; ~6-10 min):
#   ./isaac_ws/src/script/test/standalone_smoke.sh
#
# Single case (fast iteration):
#   ./isaac_ws/src/script/test/standalone_smoke.sh --only cmd_vel

set -uo pipefail

DOCKER_DIR=/home/yunchien/workspace/coreSAM_ws/isaac_ws/src/docker
SCRIPT_PATH_IN_CONTAINER=/home/yunchien/work/src/script
USD_HOST=/home/yunchien/workspace/coreSAM_ws/isaac_ws/src/model/usd/openbase/openbase.usda
CONTAINER=yunchien-isaac-standalone

# Smoke matrix: <basename>|<grep-marker>|<timeout-sec>|<needs-usd>
CASES=(
  "ros2_test_pub_standalone.py|standalone publishing|150|no"
  "ros2_test_sub_standalone.py|standalone subscribed to|150|no"
  "cmd_vel_planar_standalone.py|standalone subscribed|180|yes"
  "move_openbase_planar_standalone.py|\\[tick|180|yes"
)

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
  exit 0
}

STRICT=0
ONLY=""
while (( $# > 0 )); do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

# Pre-flight ---------------------------------------------------------
if [[ ! -d "$DOCKER_DIR" ]]; then
  echo "FAIL: docker dir missing: $DOCKER_DIR" >&2
  exit 2
fi

# Bring standalone up if needed (no-op if already running)
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "[smoke] starting standalone container..."
  "$DOCKER_DIR/run.sh" -t standalone -d >/dev/null 2>&1 || {
    echo "FAIL: ./run.sh -t standalone -d failed" >&2
    exit 2
  }
  sleep 3
fi

# Per-case runner ----------------------------------------------------
# Args: script_basename, marker_regex, timeout_sec, needs_usd (yes|no)
# Echoes "PASS|FAIL|SKIP <script> (<elapsed>s)" and returns 0 / 1 / 0.
_run_case() {
  local script="$1" marker="$2" timeout="$3" needs_usd="$4"

  if [[ "$needs_usd" == "yes" && ! -f "$USD_HOST" ]]; then
    echo "SKIP $script (USD missing at $USD_HOST — run import_urdf.py first)"
    return 0  # SKIP not counted as FAIL unless --strict
  fi

  local tmp
  tmp="$(mktemp)"

  # Launch script in background; capture stdout+stderr to tmp.
  "$DOCKER_DIR/exec.sh" -t standalone /isaac-sim/python.sh \
    "$SCRIPT_PATH_IN_CONTAINER/$script" > "$tmp" 2>&1 &
  local exec_pid=$!

  local elapsed=0 result="FAIL"
  while (( elapsed < timeout )); do
    if grep -q -E "$marker" "$tmp" 2>/dev/null; then
      result="PASS"
      break
    fi
    if ! kill -0 "$exec_pid" 2>/dev/null; then
      # Process died before marker — likely error in script
      break
    fi
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done

  # Cleanup: kill local exec wrapper + remote python.sh inside container.
  # docker exec doesn't propagate SIGTERM to the remote process, so kill
  # remote explicitly too.
  kill -TERM "$exec_pid" 2>/dev/null
  docker exec "$CONTAINER" bash -c \
    'pkill -TERM -f /isaac-sim/python.sh' 2>/dev/null
  wait "$exec_pid" 2>/dev/null

  if [[ "$result" == "FAIL" ]]; then
    echo "FAIL $script (marker '$marker' not reached within ${elapsed}s)"
    echo "--- last 20 lines of stdout/stderr ---"
    tail -20 "$tmp" >&2
    echo "--- end ---"
  else
    echo "PASS $script (${elapsed}s)"
  fi

  rm -f "$tmp"
  [[ "$result" == "PASS" ]]
}

# Drive matrix -------------------------------------------------------
pass=0 fail=0 skip=0
for c in "${CASES[@]}"; do
  IFS='|' read -r script marker timeout needs_usd <<< "$c"
  if [[ -n "$ONLY" && "$script" != *"$ONLY"* ]]; then
    continue
  fi
  echo "=== $script ==="
  if _run_case "$script" "$marker" "$timeout" "$needs_usd"; then
    if [[ "$needs_usd" == "yes" && ! -f "$USD_HOST" ]]; then
      skip=$(( skip + 1 ))
    else
      pass=$(( pass + 1 ))
    fi
  else
    fail=$(( fail + 1 ))
  fi
  # Settle between cases — let previous kit fully exit
  sleep 5
done

echo "---"
echo "smoke summary: pass=$pass fail=$fail skip=$skip"

if (( fail > 0 )); then
  exit 1
fi
if (( STRICT == 1 && skip > 0 )); then
  echo "FAIL: --strict mode and $skip cases skipped"
  exit 1
fi
exit 0
