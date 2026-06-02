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

# Extract the _start_web_viewer function body once for the structural
# assertions below (avoids whole-file greps that pass on a comment or a
# stale string outside the docker run -- #107).
_wv_body() {
  awk '
    /^_start_web_viewer\(\)/ { in_fn = 1 }
    in_fn { print }
    in_fn && /^\}/ { exit }
  ' "${RUN_INSTANCE}"
}

@test "run_instance.sh: VIEWER_* passed as -e flags inside _start_web_viewer (#79/#107)" {
  assert_file_exists "${RUN_INSTANCE}"
  body="$(_wv_body)"
  # Must be -e FLAG=VALUE args, not a bare string elsewhere in the file.
  echo "${body}" | grep -qE '[-]e[[:space:]]+"?VIEWER_UI_MODE=stream-only"?'
  echo "${body}" | grep -qE '[-]e[[:space:]]+"?VIEWER_AUTO_LAUNCH=true"?'
  # Negative guard: the opposite (usd-viewer / false) must NOT appear.
  ! echo "${body}" | grep -qE 'VIEWER_UI_MODE=usd-viewer'
  ! echo "${body}" | grep -qE 'VIEWER_AUTO_LAUNCH=false'
}

@test "run_instance.sh: _start_web_viewer removes a stale container first (#105)" {
  assert_file_exists "${RUN_INSTANCE}"
  body="$(_wv_body)"
  # docker rm -f on the viewer container before docker run -- idempotent re-run.
  echo "${body}" | grep -qE 'docker rm -f[[:space:]]+"?\$\{?WV_CONTAINER\}?"?'
}

@test "run_instance.sh: web-viewer launch is gated on the stream stage (#105)" {
  assert_file_exists "${RUN_INSTANCE}"
  # The guard around the _start_web_viewer call must test stage == stream
  # (or skip non-stream), so headless does not spawn a viewer.
  grep -qE '\$\{?stage\}?"?[[:space:]]*(!=|==)[[:space:]]*"?stream' "${RUN_INSTANCE}"
}

@test "run_instance.sh: uses the shared validated host.yaml parser (#104)" {
  assert_file_exists "${RUN_INSTANCE}"
  grep -q "resolve_public_ip" "${RUN_INSTANCE}"
  # The old permissive inline awk parser must be gone.
  ! grep -qE "awk -F': \\*'.*public_ip" "${RUN_INSTANCE}"
}

@test "run_instance.sh: success message distinguishes remote vs localhost-only (#108)" {
  assert_file_exists "${RUN_INSTANCE}"
  body="$(_wv_body)"
  echo "${body}" | grep -qiE 'remote'
  echo "${body}" | grep -qiE 'localhost only'
  # localhost-only branch points the user at host.yaml public_ip.
  echo "${body}" | grep -q 'config/host.yaml'
}

@test "run_instance.sh: viewer guard also requires an initialized .base (#109)" {
  assert_file_exists "${RUN_INSTANCE}"
  grep -qE '\$\{?WV_DIR\}?/\.base' "${RUN_INSTANCE}"
  grep -q "submodule update --init --recursive" "${RUN_INSTANCE}"
}
