#!/usr/bin/env bats
#
# Behavioral guard for test/assert_pytest_baseline.sh --gpu (owv#55 second
# axis; the first axis was isaac#239).
#
# The GPU pytest tier runs the integration suite via `./script/run.sh -t test`.
# That is a FOREGROUND run.sh with no --no-rm and no --instance, so run.sh
# installs its EXIT trap _app_cleanup, which does a PROJECT-WIDE
# `COMPOSE_PROFILES='*' compose down --remove-orphans` over the compose
# project. With no --instance, _compute_project_name resolves the DEFAULT
# project (yunchien-isaac) -- the exact project a manually-run stream stack
# lives in on the same GPU host. So the tier's teardown would remove every
# container in that project, including a co-hosted manual `stream` container
# (owv#55). Giving the run.sh -t test call its own --instance scopes
# _app_cleanup's project-wide teardown to an isolated project instead.
#
# This spec runs assert_pytest_baseline.sh --gpu against a STUB run.sh that
# records the argv it receives, and asserts the GPU pytest invocation carries
# --instance (i.e. it is placed in a NON-default, isolated compose project).
# It is behavioral -- it observes the argv actually passed to run.sh, not the
# source text -- and hermetic: no real docker, no GPU. The stub satisfies the
# script far enough to observe the call.
#
# Baked into /smoke_test/ next to assert_pytest_baseline.sh by the
# devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  FAKE="$(mktemp -d)"
  mkdir -p "${FAKE}/test" "${FAKE}/script"

  # Real script under test, run from a fake REPO_ROOT so it resolves our
  # stub script/run.sh. run.sh's REPO_ROOT is derived from BASH_SOURCE, so
  # placing the copy at ${FAKE}/test/ makes REPO_ROOT resolve to ${FAKE}.
  cp "${BATS_TEST_DIRNAME}/assert_pytest_baseline.sh" \
    "${FAKE}/test/assert_pytest_baseline.sh"
  chmod +x "${FAKE}/test/assert_pytest_baseline.sh"

  # Minimal baseline file so --gpu mode gets past its key lookups and
  # reaches the run.sh -t test invocation.
  cat > "${FAKE}/test/pytest-baseline.txt" <<'BASE'
HOSTED_UNIT_BASELINE = 100
GPU_INTEGRATION_BASELINE = 1
AGGREGATE_TARGET = 101
BASE

  # Stub run.sh: record the argv it is called with, then succeed without
  # touching docker. It writes no JUnit report, so assert_pytest_baseline.sh
  # exits at its missing-report check afterwards -- irrelevant here, we
  # assert on the recorded argv regardless of the script's final status.
  export RUN_ARGS_FILE="${FAKE}/run-args.txt"
  cat > "${FAKE}/script/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${RUN_ARGS_FILE:?}"
exit 0
STUB
  chmod +x "${FAKE}/script/run.sh"
}

teardown() {
  rm -rf "${FAKE}"
}

@test "assert_pytest_baseline --gpu isolates the GPU pytest run in its own compose project (--instance)" {
  run "${FAKE}/test/assert_pytest_baseline.sh" --gpu

  # run.sh must have actually been invoked (guards against the script
  # failing before it reaches the -t test call).
  [ -f "${RUN_ARGS_FILE}" ]

  # The invocation is the -t test compose stage ...
  grep -qx -- '-t' "${RUN_ARGS_FILE}"
  grep -qx -- 'test' "${RUN_ARGS_FILE}"

  # ... placed in a dedicated, NON-default compose project via --instance,
  # so _app_cleanup's project-wide `down --remove-orphans` can never reach
  # the default yunchien-isaac project a manual stream stack lives in.
  grep -qx -- '--instance' "${RUN_ARGS_FILE}"
}
