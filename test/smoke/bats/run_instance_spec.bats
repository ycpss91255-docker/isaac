#!/usr/bin/env bats
#
# Regression guard for script/run_instance.sh -- issue #81.
#
# Bug A: kit_args[0] must be /isaac-sim/runheadless.sh
#   The headless / stream stages idle on start (CMD = sleep infinity).
#   When run_instance.sh overrides CMD to launch Isaac directly, the
#   first token has to be the Kit launcher binary, not a flag. The
#   image entrypoint is `exec "$@"` -- passing `-v --/...` straight
#   makes bash exec eat `-v` as a flag and the container dies with
#   exitCode=2, execDuration=0 before Isaac even runs.
#
# Bug B: _start_web_viewer must pass SIGNALING_SERVER env to the
#   viewer container. omniverse_web_viewer entrypoint reads
#   /etc/host.yaml when present (#12), but the env passthrough is
#   defense in depth -- recovers when the viewer image is stale
#   (built before #12) or the host.yaml mount fails. Without it the
#   viewer JS bundle gets sed'd with SIGNALING_SERVER=127.0.0.1 and
#   the browser shows a white screen.
#
# run_instance.sh is baked into /smoke_test/ by the devel-test stage
# in Dockerfile, the same pattern used for Makefile.local.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RUN_INSTANCE="${BATS_TEST_DIRNAME}/run_instance.sh"
}

@test "run_instance.sh: kit_args starts with /isaac-sim/runheadless.sh (#81 bug A)" {
  assert_file_exists "${RUN_INSTANCE}"
  # Find the kit_args=( line and grab the next non-blank, non-comment
  # token. It must be /isaac-sim/runheadless.sh -- not -v or any
  # --/app/... flag.
  first_token=$(awk '
    /^kit_args=\(/ { in_arr = 1; next }
    in_arr && /^\)/ { exit }
    in_arr && /^[[:space:]]*#/ { next }
    in_arr && NF > 0 {
      gsub(/^[[:space:]]+/, "")
      gsub(/[[:space:]]+$/, "")
      gsub(/^"/, ""); gsub(/"$/, "")
      print
      exit
    }
  ' "${RUN_INSTANCE}")
  [ "${first_token}" = "/isaac-sim/runheadless.sh" ]
}

@test "run_instance.sh: _start_web_viewer passes SIGNALING_SERVER env (#81 bug B)" {
  assert_file_exists "${RUN_INSTANCE}"
  # Extract the _start_web_viewer function body and assert it contains
  # a SIGNALING_SERVER env passthrough sourced from ${public_ip}.
  body=$(awk '
    /^_start_web_viewer\(\)/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "${RUN_INSTANCE}")
  echo "${body}" | grep -qE 'SIGNALING_SERVER=.*\$\{?public_ip\}?'
}

@test "run_instance.sh: web-viewer launched in stream-only auto-launch (#79)" {
  assert_file_exists "${RUN_INSTANCE}"
  grep -q "VIEWER_UI_MODE=stream-only" "${RUN_INSTANCE}"
  grep -q "VIEWER_AUTO_LAUNCH=true" "${RUN_INSTANCE}"
}
