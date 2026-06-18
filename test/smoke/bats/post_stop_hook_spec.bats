#!/usr/bin/env bats
#
# Unit guard for script/hooks/post/stop.sh (base #440 post-stop hook).
#
# Responsibility: stop the web-viewer container that post/run.sh started
# out-of-compose. `stop.sh` tears down the compose (Isaac) containers but
# never sees the viewer, so the symmetric cleanup lives here.
#
# Single-sim only: same-repo multi-instance was removed (ADR-0019). The
# viewer container is the default `owv` (the same name post/run uses).
#
# Exercised via POST_RUN_DRYRUN=1 (shared dry-run flag with post/run).
# Baked into /smoke_test/ as post_stop_hook.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HOOK="${BATS_TEST_DIRNAME}/post_stop_hook.sh"
  export POST_RUN_DRYRUN=1
}

@test "post-stop: stops the default viewer owv" {
  run --separate-stderr "${HOOK}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker (stop|rm -f) .*owv'
  # No -<instance> suffix (ADR-0019).
  ! echo "${output}" | grep -qE 'owv-'
}
