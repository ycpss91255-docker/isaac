#!/usr/bin/env bats
#
# Behavioral guard for script/ci/stream_smoke.sh compose-project isolation
# (remaining axis of ycpss91255-docker/omniverse_web_viewer#55).
#
# The nightly Tier A GPU smoke brings up its own stream stack and tears it
# down. Before this fix it (a) brought the stack up in the DEFAULT compose
# project (`./script/run.sh -t stream -d`) and (b) tore it down BY NAME with
# `docker rm -f "${USER}-${IMAGE}-stream" owv` -- the exact name a
# manually-run DEFAULT stream stack uses, plus the literal `owv` (a stale
# pre-isaac#238 viewer name that now matches nothing, so the real viewer was
# left running on the serve port). On a shared GPU host that reaped a
# co-hosted manual stack.
#
# base v0.42.0 removed --instance (base#666); isolation is now a DISTINCT
# resolved PROJECT_NAME. The smoke pins one (default `<derived>-smoke`,
# overridable via SMOKE_PROJECT) into the derived .env.generated cache, brings
# the stack up with a plain `run.sh -t stream -d` (now under that project),
# resolves the stream container BY PROJECT (`docker compose -p <proj> ps -q
# stream`), and tears down PROJECT-scoped (`docker compose -p <proj> down`)
# plus the isaac-owned per-project viewer (`...-owv-<suffix>`) -- never the
# bare default-project stream name, never the stale literal `owv`. A distinct
# project fully contains run.sh's project-wide EXIT-trap teardown, so the
# owv#55 reap invariant holds without the removed --instance primitive.
#
# This spec runs the REAL stream_smoke.sh against a STUB run.sh and a STUB
# docker (both record the argv they receive), so it is behavioral (it
# observes the argv actually passed + the resulting file state) and hermetic:
# no real docker, no GPU. The stubs satisfy the script far enough to observe
# the bring-up + the project-scoped teardown; the wait then fails closed (the
# stub docker reports no live container) and the script exits non-zero --
# irrelevant here, we assert on the recorded argv regardless.
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

  # Derived cache the script sources for identity + the default project name
  # (base A2 model). PROJECT_NAME carries the DEFAULT resolved project; the
  # script must overwrite it with the isolated smoke project.
  cat > "${FAKE}/.env.generated" <<'ENV'
USER_NAME=alice
IMAGE_NAME=isaac
DOCKER_HUB_USER=alice
PROJECT_NAME=alice-isaac
ENV
  # A compose.yaml so the project-scoped resolve/teardown have a -f target
  # (contents irrelevant: docker is stubbed and never reads it).
  printf 'name: ${PROJECT_NAME}\n' > "${FAKE}/compose.yaml"

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
  # `docker compose ps -q` / `docker inspect` return empty and the liveness
  # probe reads "not alive").
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

@test "stream_smoke: brings the stack up under a distinct PROJECT_NAME, no --instance (owv#55)" {
  export SMOKE_PROJECT=alice-isaac-demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  # run.sh must have actually been invoked (guards against the script
  # failing before it reaches the bring-up).
  [ -f "${RUN_ARGS_FILE}" ]

  # The bring-up is the -t stream -d stage ...
  grep -qx -- '-t' "${RUN_ARGS_FILE}"
  grep -qx -- 'stream' "${RUN_ARGS_FILE}"
  grep -qx -- '-d' "${RUN_ARGS_FILE}"
  # ... with NO --instance (base v0.42.0 removed it, base#666); isolation is
  # the distinct project pinned in the cache instead.
  run grep -qx -- '--instance' "${RUN_ARGS_FILE}"
  [ "$status" -ne 0 ]
  # The distinct smoke project is written into the derived cache run.sh reads.
  grep -qE '^PROJECT_NAME=alice-isaac-demo$' "${FAKE}/.env.generated"
}

@test "stream_smoke: resolves the stream container BY PROJECT, not by a global name (owv#55)" {
  export SMOKE_PROJECT=alice-isaac-demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${DOCKER_ARGS_FILE}" ]
  # The container id is resolved via the project's own compose ps, so a
  # co-hosted stack's identically-named container is never addressed.
  grep -qE 'compose -p alice-isaac-demo .* ps -q stream' "${DOCKER_ARGS_FILE}"
}

@test "stream_smoke: teardown is project-scoped + the per-project viewer, not the bare name or literal owv (owv#55, isaac#238)" {
  export SMOKE_PROJECT=alice-isaac-demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${DOCKER_ARGS_FILE}" ]

  # Teardown brings the whole project down (cannot touch a globally-named
  # manual/default stack) ...
  grep -qE 'compose -p alice-isaac-demo .* down' "${DOCKER_ARGS_FILE}"
  # ... plus removes the isaac-owned per-project viewer post/run.sh created.
  grep -qE 'rm -f alice-isaac-owv-demo' "${DOCKER_ARGS_FILE}"

  # Regression guards, via `run ...; [ status -ne 0 ]` so they are effective
  # under bats' set -e. Never `docker rm -f` the bare default-project stream
  # container by name (project-scoped down owns that now) ...
  run grep -qE 'rm -f alice-isaac-stream' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
  # ... and never the stale pre-isaac#238 literal `owv` (which matches no
  # real container, leaving the true viewer running on the serve port).
  run grep -qE 'rm -f owv( |$)' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
}

@test "stream_smoke: project defaults to '<derived>-smoke' when SMOKE_PROJECT is unset (owv#55)" {
  unset SMOKE_PROJECT
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${RUN_ARGS_FILE}" ]
  [ -f "${DOCKER_ARGS_FILE}" ]

  # Dedicated default project `<derived>-smoke`, so a bare manual
  # `run.sh -t stream -d` (the default stack, project alice-isaac) never
  # collides with the nightly smoke.
  grep -qE '^PROJECT_NAME=alice-isaac-smoke$' "${FAKE}/.env.generated"
  grep -qE 'compose -p alice-isaac-smoke .* down' "${DOCKER_ARGS_FILE}"
  grep -qE 'rm -f alice-isaac-owv-smoke' "${DOCKER_ARGS_FILE}"
}
