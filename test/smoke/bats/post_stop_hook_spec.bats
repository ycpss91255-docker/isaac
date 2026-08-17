#!/usr/bin/env bats
#
# Unit guard for script/hooks/post/stop.sh (base #440 post-stop hook).
#
# Responsibility: stop the web-viewer container that post/run.sh started
# out-of-compose. `stop.sh` tears down the compose (Isaac) containers but
# never sees the viewer, so the symmetric cleanup lives here.
#
# Single-sim only: same-repo multi-instance was removed (ADR-0019). The
# viewer container is the per-stack ${USER_NAME}-${IMAGE_NAME}-owv (the same
# name post/run uses), so two isolated stacks on one host do not tear down
# each other's viewer (#237).
#
# Exercised via POST_RUN_DRYRUN=1 (shared dry-run flag with post/run).
# Baked into /smoke_test/ as post_stop_hook.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HOOK="${BATS_TEST_DIRNAME}/post_stop_hook.sh"
  REPO="$(mktemp -d)"
  export FILE_PATH="${REPO}"
  export POST_RUN_DRYRUN=1
  # The default (no --instance) case must be byte-identical to today's name.
  # Clear any ambient INSTANCE_SUFFIX; the instance case sets it explicitly.
  unset INSTANCE_SUFFIX
  # Identity vars live in .env.generated (base A2 model); the hook must
  # source them to derive the per-stack viewer container name (same
  # identity post/run uses).
  printf 'USER_NAME=alice\nIMAGE_NAME=isaac\nDOCKER_HUB_USER=alice\n' \
    > "${REPO}/.env.generated"
}

teardown() {
  rm -rf "${REPO}"
}

@test "post-stop: stops the per-stack viewer (name derived from IMAGE_NAME)" {
  run --separate-stderr "${HOOK}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker (stop|rm -f) .*alice-isaac-owv'
  # Default case carries no -<instance> suffix.
  ! echo "${output}" | grep -qE 'owv-'
}

@test "post-stop: INSTANCE_SUFFIX scopes the viewer name (--instance, isaac#238)" {
  # stop.sh --instance demo exports INSTANCE_SUFFIX=-demo before this hook
  # fires (base _down_one -> _compute_project_name). The teardown must then
  # target the instance-scoped viewer, symmetric with what post/run created,
  # so one stack's stop cannot leave another stack's viewer name behind.
  export INSTANCE_SUFFIX=-demo
  run --separate-stderr "${HOOK}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker (stop|rm -f) .*alice-isaac-owv-demo'
}
