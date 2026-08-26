#!/usr/bin/env bats
#
# Behavioral guard for test/assert_pytest_baseline.sh --gpu (owv#55 second
# axis; the first axis was isaac#239).
#
# The GPU pytest tier runs the integration suite via `./script/run.sh -t test`.
# That is a FOREGROUND run.sh with no --no-rm, so run.sh installs its EXIT
# trap _app_cleanup, which does a PROJECT-WIDE
# `COMPOSE_PROFILES='*' compose down --remove-orphans` over the resolved
# compose project. base v0.42.0 removed the --instance flag (base#666); the
# project is now the single resolved PROJECT_NAME `setup apply` writes into
# .env.generated. Left at the DEFAULT project (${DOCKER_HUB_USER}-${IMAGE_NAME},
# e.g. yunchien-isaac) that teardown would reap a co-hosted manual `stream`
# container living in the same project on a shared GPU host. So the tier pins
# a DISTINCT PROJECT_NAME in .env.generated (the derived cache run.sh's
# _load_env reads, then _compute_project_name keeps) before the run.sh -t test
# call, scoping _app_cleanup's project-wide teardown to an isolated project.
#
# We pin via a surgical sed of the PROJECT_NAME= line in .env.generated -- the
# same post-apply sed the CI WS_PATH pin uses -- rather than `setup.sh apply`
# with a .setup.conf.local override, because a second apply here would re-run
# detection and clobber the CI WS_PATH pin the prior apply step wrote.
#
# This spec runs assert_pytest_baseline.sh --gpu against a STUB run.sh that
# records the argv it receives, and a fake .env.generated, and asserts the
# GPU pytest invocation NO LONGER carries --instance and that the isolated
# PROJECT_NAME was written into the cache before run.sh fired. Behavioral --
# it observes the argv actually passed to run.sh + the resulting file state,
# not the source text -- and hermetic: no real docker, no GPU.
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

  # Derived cache the wrapper reads (base A2 model). Carries the DEFAULT
  # resolved project name (${DOCKER_HUB_USER}-${IMAGE_NAME}); the script must
  # overwrite this PROJECT_NAME line with the isolated baseline project.
  cat > "${FAKE}/.env.generated" <<'ENV'
USER_NAME=alice
IMAGE_NAME=isaac
DOCKER_HUB_USER=alice
PROJECT_NAME=alice-isaac
ENV

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
  # assert on the recorded argv + file state regardless of the final status.
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

@test "assert_pytest_baseline --gpu isolates the GPU pytest run in its own compose project (PROJECT_NAME, owv#55)" {
  export BASELINE_PROJECT=isaac-baseline-run42
  run "${FAKE}/test/assert_pytest_baseline.sh" --gpu

  # run.sh must have actually been invoked (guards against the script
  # failing before it reaches the -t test call).
  [ -f "${RUN_ARGS_FILE}" ]

  # The invocation is the -t test compose stage ...
  grep -qx -- '-t' "${RUN_ARGS_FILE}"
  grep -qx -- 'test' "${RUN_ARGS_FILE}"

  # ... with NO --instance any more (base v0.42.0 removed it, base#666).
  # Effective under bats set -e via `run ...; [ status -ne 0 ]`.
  run grep -qx -- '--instance' "${RUN_ARGS_FILE}"
  [ "$status" -ne 0 ]

  # The isolation is a DISTINCT PROJECT_NAME pinned in the derived cache the
  # wrapper reads, so _app_cleanup's project-wide `down --remove-orphans` can
  # never reach the default alice-isaac project a manual stream stack lives in.
  grep -qE '^PROJECT_NAME=isaac-baseline-run42$' "${FAKE}/.env.generated"
}

@test "assert_pytest_baseline --gpu defaults the baseline project to <derived>-baseline when BASELINE_PROJECT is unset (owv#55)" {
  unset BASELINE_PROJECT
  run "${FAKE}/test/assert_pytest_baseline.sh" --gpu

  [ -f "${RUN_ARGS_FILE}" ]
  # Default is a dedicated <derived>-baseline (derived from the cache's own
  # PROJECT_NAME), distinct from the default project -- still isolated even
  # when CI does not pass a per-run-unique value.
  grep -qE '^PROJECT_NAME=alice-isaac-baseline$' "${FAKE}/.env.generated"
}
