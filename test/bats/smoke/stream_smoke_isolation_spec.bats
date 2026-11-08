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

  # Stub run.sh: record argv, the stream-container override it was handed,
  # and the stream service's container_name as compose.yaml reads at that
  # moment; succeed without touching docker. Invoked as ./script/run.sh from
  # inside repo_root (${FAKE}).
  export RUN_ARGS_FILE="${FAKE}/run-args.txt"
  export RUN_ENV_FILE="${FAKE}/run-env.txt"
  cat > "${FAKE}/script/run.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${RUN_ARGS_FILE:?}"
printf 'ISAAC_STREAM_CONTAINER=%s\n' "${ISAAC_STREAM_CONTAINER:-}" \
  >> "${RUN_ENV_FILE:?}"
grep 'container_name:' compose.yaml >> "${RUN_ENV_FILE}" 2>/dev/null || true
exit 0
STUB
  chmod +x "${FAKE}/script/run.sh"

  # Stub docker: record each invocation's argv (prefixed with the
  # COMPOSE_PROFILES it saw) to a file. By default it prints nothing, so
  # `docker compose ps -q` / `docker inspect` return empty and the liveness
  # probe reads "not alive". Opt-in fixtures:
  #   STUB_ALIVE=1     `compose ps -q` -> cid0, `inspect` -> true
  #   STUB_KIT_LOG     file copied to the kit log when Isaac is launched
  #   STUB_PROJECTS    newline list for the compose-project label listing
  #   STUB_NAMES       newline list for the container-name listing
  # `ps -aq --filter label=com.docker.compose.project=<p>` prints id-<p>.
  export DOCKER_ARGS_FILE="${FAKE}/docker-args.txt"
  export STUB_SMOKE_LOG="${FAKE}/isaac-sim/kit/logs/stream-smoke.log"
  cat > "${FAKE}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '[profiles=%s] %s\n' "${COMPOSE_PROFILES:-}" "$*" >> "${DOCKER_ARGS_FILE:?}"
case "$*" in
  *"ps -q stream"*)
    [ "${STUB_ALIVE:-0}" = 1 ] && echo cid0 ;;
  inspect\ -f*)
    [ "${STUB_ALIVE:-0}" = 1 ] && echo true ;;
  exec\ -d*runheadless*)
    if [ -n "${STUB_KIT_LOG:-}" ]; then
      mkdir -p "$(dirname "${STUB_SMOKE_LOG}")"
      cp "${STUB_KIT_LOG}" "${STUB_SMOKE_LOG}"
    fi ;;
  *"--format {{.Label \"com.docker.compose.project\"}}"*)
    printf '%s\n' "${STUB_PROJECTS:-}" ;;
  *"--format {{.Names}}"*)
    printf '%s\n' "${STUB_NAMES:-}" ;;
  "ps -aq --filter label=com.docker.compose.project="*)
    _last="${!#}"; echo "id-${_last##*=}" ;;
esac
exit 0
STUB
  chmod +x "${FAKE}/bin/docker"
  export PATH="${FAKE}/bin:${PATH}"
  unset SMOKE_REAP_PROJECT_PREFIX SMOKE_CLIENT_CMD STUB_ALIVE STUB_KIT_LOG \
    STUB_PROJECTS STUB_NAMES ISAAC_STREAM_CONTAINER
}

# A Kit 110 (Isaac Sim 6.0.1) stream-stage log, lines verbatim from the GPU
# host (isaac#291) with a real headless-Chromium peer attached. Optionally
# truncated after the signaling headers, which is as far as a peer that
# never answers the SDP offer gets.
write_kit110_log() {
  local _out="$1" _connected="${2:-1}"
  cat > "${_out}" <<'LOG'
2026-11-04T08:53:54Z [29,901ms] [Info] [omni.kit.livestream.app.plugin] Started primary stream server on signal port 49291 and stream port 47291
2026-11-04T08:55:58Z [153,318ms] [Info] [omni.kit.app.plugin] [153.392s] Isaac Sim Full Streaming App is loaded.
2026-11-04T08:59:41Z [376,091ms] [Info] [omni.kit.livestream.webrtc.plugin] Processing 12 signaling headers
LOG
  if [ "${_connected}" = 1 ]; then
    printf '%s\n' '2026-11-04T08:59:41Z [376,307ms] [Info] [omni.kit.livestream.webrtc.plugin] Client connected to WebRTC server' >> "${_out}"
  fi
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

@test "stream_smoke: the stream container gets a per-run name, the hook is told, compose.yaml is restored (isaac#291)" {
  # base v0.42.0 emits a fixed `container_name: ${USER_NAME}-isaac-stream`
  # that ignores PROJECT_NAME, so any other stream stack on the host (a
  # developer's, even merely exited) made `compose up` fail with "container
  # name ... already in use" before Isaac started. The smoke renames ITS copy
  # for the duration of the run and restores the derived file afterwards.
  cat > "${FAKE}/compose.yaml" <<'YAML'
name: ${PROJECT_NAME}
services:
  devel:
    container_name: ${USER_NAME}-isaac
  stream:
    container_name: ${USER_NAME}-isaac-stream
YAML
  cp "${FAKE}/compose.yaml" "${FAKE}/compose.orig"
  export SMOKE_PROJECT=isaac-smoke-7-1
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${RUN_ENV_FILE}" ]
  # run.sh saw the renamed stream service (and only that one renamed) ...
  grep -qxF '    container_name: ${USER_NAME}-isaac-stream-isaac-smoke-7-1' "${RUN_ENV_FILE}"
  grep -qxF '    container_name: ${USER_NAME}-isaac' "${RUN_ENV_FILE}"
  # ... and the post-run hook is handed the same name for its docker cp.
  grep -qxF 'ISAAC_STREAM_CONTAINER=alice-isaac-stream-isaac-smoke-7-1' "${RUN_ENV_FILE}"
  # The derived compose.yaml is back to what setup.sh generated.
  cmp -s "${FAKE}/compose.orig" "${FAKE}/compose.yaml"
}

@test "stream_smoke: teardown activates every profile so the profiled stream service is removed (isaac#291)" {
  # The stream service is `profiles: [stream]`; a plain `compose down` skips
  # inactive-profile services, which leaked the stream container (and its Kit)
  # on every run -- the leak then held the fixed name for the next run.
  export SMOKE_PROJECT=alice-isaac-demo
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${DOCKER_ARGS_FILE}" ]
  grep -qE '^\[profiles=\*\] compose -p alice-isaac-demo .* down' "${DOCKER_ARGS_FILE}"
  run grep -qE '^\[profiles=\] compose -p alice-isaac-demo .* down' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
}

@test "stream_smoke: reaps only OTHER projects under SMOKE_REAP_PROJECT_PREFIX, never a developer stack (isaac#291)" {
  export SMOKE_PROJECT=isaac-smoke-9-1
  export SMOKE_REAP_PROJECT_PREFIX=isaac-smoke-
  export STUB_PROJECTS=$'alice-isaac\nisaac-smoke-8-1\nisaac-smoke-9-1\nisaac-forklift-perf'
  export STUB_NAMES=$'alice-isaac-stream\nalice-isaac-owv\nalice-isaac-owv-isaac-smoke-8-1\nisaac-smoke-8-1-client-browser\nalice-isaac-owv-isaac-smoke-9-1\nisaac-forklift-perf-viewer-i1'
  run "${FAKE}/script/ci/stream_smoke.sh"

  [ -f "${DOCKER_ARGS_FILE}" ]
  # The leftover smoke project and its out-of-compose viewer / client go ...
  grep -qE '\] rm -f id-isaac-smoke-8-1$' "${DOCKER_ARGS_FILE}"
  grep -qE '\] rm -f alice-isaac-owv-isaac-smoke-8-1$' "${DOCKER_ARGS_FILE}"
  grep -qE '\] rm -f isaac-smoke-8-1-client-browser$' "${DOCKER_ARGS_FILE}"
  # ... while the developer project, a foreign project and this run's own
  # project are never reaped by the stale sweep.
  run grep -qE 'rm -f id-(alice-isaac|isaac-forklift-perf|isaac-smoke-9-1)$' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
  run grep -qE 'rm -f (alice-isaac-stream|alice-isaac-owv|isaac-forklift-perf-viewer-i1)$' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
}

@test "stream_smoke: no stale-project sweep unless SMOKE_REAP_PROJECT_PREFIX owns the run (isaac#291)" {
  export SMOKE_PROJECT=alice-isaac-demo
  export STUB_PROJECTS=$'isaac-smoke-8-1'
  run "${FAKE}/script/ci/stream_smoke.sh"
  run grep -qE 'ps -aq --filter label=com.docker.compose.project=' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]

  # A prefix that does not cover this run's own project is not trusted.
  : > "${DOCKER_ARGS_FILE}"
  export SMOKE_REAP_PROJECT_PREFIX=isaac-smoke-
  run "${FAKE}/script/ci/stream_smoke.sh"
  run grep -qE 'rm -f id-isaac-smoke-8-1' "${DOCKER_ARGS_FILE}"
  [ "$status" -ne 0 ]
}

@test "stream_smoke: a Kit 110 log with a connected peer passes on the default markers (isaac#291)" {
  # Before #291 the defaults waited for the Kit 107 `Streaming server
  # started.` line, which Isaac Sim 6.x never prints: every run timed out.
  write_kit110_log "${FAKE}/kit.log" 1
  export STUB_KIT_LOG="${FAKE}/kit.log" STUB_ALIVE=1
  export SMOKE_PROJECT=alice-isaac-demo SMOKE_CLIENT_CMD=true
  export SMOKE_TIMEOUT=2 SMOKE_CONNECT_TIMEOUT=2 SMOKE_DWELL=1 SMOKE_POLL=1
  run "${FAKE}/script/ci/stream_smoke.sh"
  [ "$status" -eq 0 ]
  [[ "${output}" == *"[smoke] PASS"* ]]
}

@test "stream_smoke: a peer that never completes the WebRTC handshake fails the attach (isaac#291)" {
  # What the old curl probe produced at best: signaling headers, no peer.
  write_kit110_log "${FAKE}/kit.log" 0
  export STUB_KIT_LOG="${FAKE}/kit.log" STUB_ALIVE=1
  export SMOKE_PROJECT=alice-isaac-demo SMOKE_CLIENT_CMD=true
  export SMOKE_TIMEOUT=2 SMOKE_CONNECT_TIMEOUT=2 SMOKE_DWELL=1 SMOKE_POLL=1
  run "${FAKE}/script/ci/stream_smoke.sh"
  [ "$status" -eq 1 ]
  [[ "${output}" == *"streams did not start"* ]]
}
