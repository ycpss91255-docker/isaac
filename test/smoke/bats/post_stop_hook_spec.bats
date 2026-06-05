#!/usr/bin/env bats
#
# Unit guard for script/hooks/post/stop.sh (base #440 post-stop hook).
#
# Responsibility: stop the web-viewer container that post/run.sh started
# out-of-compose. `stop.sh --instance NAME` tears down the compose
# (Isaac) containers but never sees the viewer, so the symmetric cleanup
# lives here. Replaces Makefile.local stop-stream + stop_instance.sh.
#
# Exercised via POST_RUN_DRYRUN=1 (shared dry-run flag with post/run).
# Baked into /smoke_test/ as post_stop_hook.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HOOK="${BATS_TEST_DIRNAME}/post_stop_hook.sh"
  export POST_RUN_DRYRUN=1
}

@test "post-stop: --instance stops the per-instance viewer" {
  run --separate-stderr "${HOOK}" --instance foo
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker (stop|rm -f) .*owv-foo'
}

@test "post-stop: no --instance stops the default viewer" {
  run --separate-stderr "${HOOK}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker (stop|rm -f) .*owv-default'
}
