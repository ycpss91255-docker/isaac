#!/usr/bin/env bats
#
# Unit guard for script/hooks/post/run.sh (base #440 post-run hook).
#
# Responsibility: after `run.sh -t stream -d` brings up the idle stream
# container, (1) validate + copy config/host.yaml into that container at
# /etc/host.yaml, and (2) start the web-viewer container. It does NOT
# launch Isaac Sim -- that stays an explicit `exec` step (driver script or
# runheadless), matching the documented stream flow.
#
# Single-sim only: same-repo multi-instance was removed (ADR-0019; the
# design is preserved in multi_run#15, the base `--instance` primitive in
# base #465). The Isaac container is the default
# ${USER_NAME}-${IMAGE_NAME}-stream and the viewer is the per-stack
# ${USER_NAME}-${IMAGE_NAME}-owv (symmetric with -stream, #237).
#
# Gate: only acts on the stream stage WITH -d/--detach. Anything else
# (headless, foreground, a driver CMD) is a no-op.
#
# Exercised via POST_RUN_DRYRUN=1, which prints the planned docker
# commands instead of executing them. Baked into /smoke_test/ as
# post_run_hook.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HOOK="${BATS_TEST_DIRNAME}/post_run_hook.sh"
  REPO="$(mktemp -d)"
  export FILE_PATH="${REPO}"
  export POST_RUN_DRYRUN=1
  export HOST_YAML_LIB="${BATS_TEST_DIRNAME}/host_yaml.sh"
  # The default-project case must be byte-identical to today's names. Clear
  # any ambient PROJECT_NAME so the default tests never see a viewer suffix
  # leaked in from the harness env; the distinct-project case sets
  # PROJECT_NAME explicitly via .env.generated below. base v0.42.0 removed
  # INSTANCE_SUFFIX (base#666); the viewer suffix is now derived from the
  # resolved PROJECT_NAME (empty when it equals ${DOCKER_HUB_USER}-${IMAGE_NAME}).
  unset PROJECT_NAME
  mkdir -p "${REPO}/config"
  # Identity vars live in .env.generated (base A2 model), NOT .env -- the
  # hook must source .env.generated to resolve USER_NAME / IMAGE_NAME /
  # DOCKER_HUB_USER. .env is only the (optional) user overlay.
  printf 'USER_NAME=alice\nIMAGE_NAME=isaac\nDOCKER_HUB_USER=alice\n' \
    > "${REPO}/.env.generated"
}

teardown() {
  rm -rf "${REPO}"
}

@test "post-run: non-stream target is a no-op" {
  run --separate-stderr "${HOOK}" -t headless -d
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "post-run: stream without -d is a no-op" {
  run --separate-stderr "${HOOK}" -t stream
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "post-run: stream + -d starts the viewer with stream-only UI mode" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e VIEWER_UI_MODE=stream-only'
  # Negative guard: the opposite value must not appear.
  ! echo "${output}" | grep -qE 'VIEWER_UI_MODE=usd-viewer'
  # auto-launch was dropped (#123): the flag must not be passed at all.
  ! echo "${output}" | grep -qE 'VIEWER_AUTO_LAUNCH'
}

@test "post-run: omitted ports fall back to viewer defaults 49100/5173 (#231)" {
  # No host.yaml at all -> the viewer still gets today's exact defaults:
  # signal 49100 (Kit's default, which the viewer is told) and serve 5173
  # (the viewer's own Vite default). media is NOT pinned (negotiated).
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49100'
  echo "${output}" | grep -qE 'docker run .*-e SERVE_PORT=5173'
  ! echo "${output}" | grep -qE 'docker run .*-e MEDIA_PORT='
  # Single-sim: no per-instance --env-file overlay (ADR-0019).
  ! echo "${output}" | grep -qE 'docker run .*--env-file'
}

@test "post-run: viewer signal/serve ports sourced from host.yaml (#231)" {
  printf 'network:\n  public_ip: "127.0.0.1"\nlivestream:\n  ports:\n    signal: 49200\n    serve: 5273\n' \
    > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49200'
  echo "${output}" | grep -qE 'docker run .*-e SERVE_PORT=5273'
  # Not the literal old defaults any more.
  ! echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49100'
  ! echo "${output}" | grep -qE 'docker run .*-e SERVE_PORT=5173'
}

@test "post-run: media port omitted -> no MEDIA_PORT on the viewer (#231)" {
  printf 'network:\n  public_ip: "127.0.0.1"\nlivestream:\n  ports:\n    signal: 49200\n' \
    > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  ! echo "${output}" | grep -qE 'MEDIA_PORT'
}

@test "post-run: media port set -> MEDIA_PORT wired to the viewer (#231, PRD:94)" {
  printf 'network:\n  public_ip: "127.0.0.1"\nlivestream:\n  ports:\n    media: 47998\n' \
    > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e MEDIA_PORT=47998'
}

@test "post-run: isaac ports are copied into the Isaac container as an env file (#231)" {
  printf 'network:\n  public_ip: "127.0.0.1"\nlivestream:\n  ports:\n    signal: 49200\n    media: 47998\n    api: 8111\n' \
    > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # A second docker cp lands the resolved ISAAC_*_PORT env into the container.
  echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream:/etc/isaac/livestream-ports.env'
}

@test "post-run: no livestream ports -> no env file copied to the Isaac container (#231)" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  ! echo "${output}" | grep -qE 'livestream-ports.env'
}

@test "post-run: invalid livestream port aborts with rc 1 (#231)" {
  printf 'network:\n  public_ip: "127.0.0.1"\nlivestream:\n  ports:\n    signal: nope\n' \
    > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 1 ]
}

@test "post-run: viewer container name derives from IMAGE_NAME (per-stack)" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker rm -f alice-isaac-owv'
  echo "${output}" | grep -qE 'docker run .*--name alice-isaac-owv'
  # No -<instance> suffix (ADR-0019).
  ! echo "${output}" | grep -qE 'owv-'
}

@test "post-run: a distinct PROJECT_NAME suffixes the viewer; the Isaac cp target stays base-fixed (owv#55, isaac#238)" {
  # base v0.42.0 removed INSTANCE_SUFFIX (base#666). Under a distinct resolved
  # PROJECT_NAME (what a CI actor pins for its own isolated stack), the hook
  # derives an isaac-owned viewer suffix from it so co-hosted stacks get
  # distinct viewer names. The Isaac stream container's name is base-fixed by
  # compose.yaml (container_name: ${USER_NAME}-isaac-stream, no suffix -- the
  # residual co-host collision on that fixed name is filed upstream as
  # base#920), so the docker cp target stays that fixed name.
  printf 'USER_NAME=alice\nIMAGE_NAME=isaac\nDOCKER_HUB_USER=alice\nPROJECT_NAME=alice-isaac-demo\n' \
    > "${REPO}/.env.generated"
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # Viewer is the per-project name for both the stale-drop and the run.
  echo "${output}" | grep -qE 'docker rm -f alice-isaac-owv-demo'
  echo "${output}" | grep -qE 'docker run .*--name alice-isaac-owv-demo'
  # Isaac container (docker cp target) is the base-fixed stream name.
  echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream:/etc/host.yaml'
  # Never a per-project-suffixed Isaac container cp target. Guard via
  # `run ...; [ status -ne 0 ]` (effective under bats set -e; a bare
  # `! grep` is exempt, SC2314) -- and LAST, since `run` clobbers $output.
  run grep -qE 'docker cp .*alice-isaac-stream-demo:/etc/host.yaml' <<< "${output}"
  [ "$status" -ne 0 ]
}

@test "post-run: host.yaml present is copied into the default Isaac container" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # cp into the default Isaac container at /etc/host.yaml (no -<instance> suffix).
  echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream:/etc/host.yaml'
  ! echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream-[^:]'
}

@test "post-run: invalid host.yaml aborts with rc 1" {
  printf 'network:\n  public_ip: "a;rm -rf /"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 1 ]
}

@test "post-run: identity is read from .env.generated, not .env (base A2 model)" {
  # Reality: setup.sh writes USER_NAME / IMAGE_NAME / DOCKER_HUB_USER to
  # .env.generated; .env may be absent entirely. The hook must still
  # resolve identity from .env.generated. With an EMPTY USER_NAME the
  # Isaac container name becomes "-isaac-stream" (leading dash, which
  # `docker cp` parses as a flag and dies) and the viewer image becomes
  # "local/..." -- the two S7 live-run defects this fix closes.
  rm -f "${REPO}/.env"
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # Container name uses USER_NAME from .env.generated -- crucially NO leading dash.
  echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream:/etc/host.yaml'
  ! echo "${output}" | grep -qE 'docker cp .*[ ]-isaac-stream:'
  # Viewer image uses DOCKER_HUB_USER from .env.generated, not the local fallback.
  echo "${output}" | grep -qE 'docker run .*alice/omniverse_web_viewer:runtime'
  ! echo "${output}" | grep -qE 'docker run .*local/omniverse_web_viewer:runtime'
}

@test "post-run: .env overlays .env.generated identity (user override wins)" {
  # .env.generated provides the base identity; .env, sourced second, is the
  # user overlay and must win. Here .env bumps USER_NAME to bob.
  printf 'USER_NAME=bob\n' > "${REPO}/.env"
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker cp .*bob-isaac-stream:/etc/host.yaml'
}

@test "post-run: viewer image is omniverse_web_viewer:runtime, not stale owv:runtime (#121)" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # Image follows the compose naming ${DOCKER_HUB_USER:-local}/omniverse_web_viewer:runtime
  # (owv renamed the serve image to :runtime; #123 tracks the hook switch).
  echo "${output}" | grep -qE 'docker run .*alice/omniverse_web_viewer:runtime'
  # Regression guard (#121): the old short stale image name must not be launched.
  ! echo "${output}" | grep -qE 'owv:runtime'
}
