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
# ${USER_NAME}-${IMAGE_NAME}-stream and the viewer is `owv`.
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

@test "post-run: viewer ports are the literal default -e flags" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49100'
  echo "${output}" | grep -qE 'docker run .*-e SERVE_PORT=5173'
  # Single-sim: no per-instance --env-file overlay (ADR-0019).
  ! echo "${output}" | grep -qE 'docker run .*--env-file'
}

@test "post-run: viewer container is the default owv and removed first" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker rm -f owv'
  echo "${output}" | grep -qE 'docker run .*--name owv'
  # No -<instance> suffix (ADR-0019).
  ! echo "${output}" | grep -qE 'owv-'
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
