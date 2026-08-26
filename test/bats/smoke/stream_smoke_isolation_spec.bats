#!/usr/bin/env bats
#
# Behavioral guard for script/ci/stream_smoke.sh compose-project isolation
# (remaining axis of ycpss91255-docker/omniverse_web_viewer#55).
#
# The nightly Tier A GPU smoke brings up its own stream stack and tears it
# down by NAME. Before this fix it (a) brought the stack up in the DEFAULT
# compose project (`./script/run.sh -t stream -d`, no --instance) and (b)
# tore it down with `docker rm -f "${USER}-${IMAGE}-stream" owv` -- the exact
# name a manually-run DEFAULT stream stack uses, plus the literal `owv`
# (the pre-isaac#238 viewer name that now matches nothing, so the real
# viewer container was left running and holding the serve port). On a shared
# GPU host that reaped a co-hosted manual stack.
#
# The fix runs the smoke under a dedicated instance (default `smoke`,
# overridable via SMOKE_COMPOSE_INSTANCE) so run.sh places the stack in its
# own project and the teardown targets the instance-scoped stream + viewer
# that post/run.sh creates for that instance -- never the bare default names
# nor the stale literal `owv`.
#
# This spec runs the REAL stream_smoke.sh against a STUB run.sh and a STUB
# docker (both record the argv they receive), so it is behavioral (it
# observes the argv actually passed) and hermetic: no real docker, no GPU.
# The stubs satisfy the script far enough to observe the bring-up + the
# pre-clean teardown; the wait then fails closed (the stub docker reports no
# live container) and the script exits non-zero -- irrelevant here, we
# assert on the recorded argv regardless of the script's final status.
#
# Baked into /smoke_test/ next to stream_smoke.sh + stream_smoke_lib.sh by
# the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  FAKE="$(mktemp -d)"
  mkdir -p "${FAKE}/script/ci" "${FAKE}/bin"

  # Real script under test, run from a fake repo root. stream_smoke.sh
  # derives repo_root as $(dirname BASH_SOURCE)/../.. , so placing the copy
  # at ${FAKE}/script/ci/ makes repo_root resolve to ${FAKE}.
  cp "${BATS_TEST_DIRNAME}/stream_smoke.sh" "${FAKE}/script/ci/stream_smoke.sh"
  chmod +x "${FAKE}/script/ci/stream_smoke.sh"

  # Identity vars the script sources from .env.generated (base A2 model).
  printf 'USER_NAME=alice\nIMAGE_NAME=isaac\nDOCKER_HUB_USER=alice\n' \
    > "${FAKE}/.env.generated"

  # Point the script's sourced libs at the baked copies (no host.yaml, so
  # resolve_port no-ops and the signal port falls back to Kit's default).
  export SMOKE_LIB="${BATS_TEST_DIRNAME}/stream_smoke_lib.sh"
  export HOST_YAML_LIB="${BATS_TEST_DIRNAME}/host_yaml.sh"
  # Keep the (fail-closed) wait short: the stub docker reports no live
  # container, so the very first liveness check ends the wait regardless.
  export SMOKE_TIMEOUT=1 SMOKE_POLL=1

  # Stub run.sh: record argv, succeed without touching docker. Invoked as
  # ./script/run.sh from inside repo_root (${FAKE}).
  export RUN_ARGS_FILE="${FAKE}/run-args.txt"
  cat > "${FAKE}/script/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${RUN_ARGS_FILE:?}"
exit 0
STUB
  chmod +x "${FAKE}/script/run.sh"

  # Stub docker: record each invocation's argv to a file (NOT stdout, so
  # `docker ps` stays empty and the liveness probe reads "not alive").
  export DOCKER_ARGS_FILE="${FAKE}/docker-args.txt"
  cat > "${FAKE}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DOCKER_ARGS_FILE:?}"
exit 0
STUB
  chmod +x "${FAKE}/bin/docker"
  export PATH="${FAKE}/bin:${PATH}"
}

teardown() {
  rm -rf "${FAKE}"
}

@test "stream_smoke: brings the stack up under a dedicated --instance (owv#55)" {
  export SMOKE_COMPOSE_INSTANCE=demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  # run.sh must have actually been invoked (guards against the script
  # failing before it reaches the bring-up).
  [ -f "${RUN_ARGS_FILE}" ]

  # The bring-up is the -t stream -d stage ...
  grep -qx -- '-t' "${RUN_ARGS_FILE}"
  grep -qx -- 'stream' "${RUN_ARGS_FILE}"
  grep -qx -- '-d' "${RUN_ARGS_FILE}"
  # ... placed in a dedicated, NON-default compose project via --instance,
  # so it never brings its stack up in the default project a manual stream
  # stack lives in.
  grep -qx -- '--instance' "${RUN_ARGS_FILE}"
  grep -qx -- 'demo' "${RUN_ARGS_FILE}"
}

@test "stream_smoke: teardown targets the instance-scoped stream + viewer, not the bare name or literal owv (owv#55, isaac#238)" {
  export SMOKE_COMPOSE_INSTANCE=demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${DOCKER_ARGS_FILE}" ]

  # docker rm -f targets the instance-scoped stream container AND the
  # instance-scoped viewer that post/run.sh creates for that instance.
  grep -qE 'rm -f alice-isaac-stream-demo alice-isaac-owv-demo' "${DOCKER_ARGS_FILE}"

  # Regression guards, via `run ...; [ status -ne 0 ]` so they are effective
  # under bats' set -e (a bare `! grep` is exempt from errexit -- SC2314 --
  # and would never fail the test). Never the bare (default-project) stream
  # container ...
  run grep -qE 'rm -f alice-isaac-stream( |$)' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
  # ... and never the stale pre-isaac#238 literal `owv` (which matches no
  # real container, leaving the true viewer running on the serve port).
  run grep -qE ' owv( |$)' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
}

@test "stream_smoke: instance defaults to 'smoke' when SMOKE_COMPOSE_INSTANCE is unset (owv#55)" {
  unset SMOKE_COMPOSE_INSTANCE
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${RUN_ARGS_FILE}" ]
  [ -f "${DOCKER_ARGS_FILE}" ]

  # Dedicated default instance `smoke`, so a bare `run.sh -t stream -d` (the
  # manual default-stack invocation) never collides with the nightly smoke.
  grep -qx -- '--instance' "${RUN_ARGS_FILE}"
  grep -qx -- 'smoke' "${RUN_ARGS_FILE}"
  grep -qE 'rm -f alice-isaac-stream-smoke alice-isaac-owv-smoke' "${DOCKER_ARGS_FILE}"
}
