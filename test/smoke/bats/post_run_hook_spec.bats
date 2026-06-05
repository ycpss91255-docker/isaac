#!/usr/bin/env bats
#
# Unit guard for script/hooks/post/run.sh (base #440 post-run hook).
#
# Responsibility: after `run.sh -t stream -d [--instance NAME]` brings
# up the idle stream container, (1) validate + copy config/host.yaml
# into that container at /etc/host.yaml, and (2) start the web-viewer
# container. It does NOT launch Isaac Sim -- that stays an explicit
# `exec` step (driver script or runheadless), matching the documented
# stream flow. Replaces Makefile.local run-stream + run_instance.sh
# _start_web_viewer.
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
  mkdir -p "${REPO}/config/instances"
  printf 'USER_NAME=alice\nIMAGE_NAME=isaac\nDOCKER_HUB_USER=alice\n' > "${REPO}/.env"
  printf 'ISAAC_SIGNAL_PORT=49200\nVIEWER_PORT=5174\n' \
    > "${REPO}/config/instances/foo.env"
}

teardown() {
  rm -rf "${REPO}"
}

@test "post-run: non-stream target is a no-op" {
  run --separate-stderr "${HOOK}" -t headless -d --instance foo
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "post-run: stream without -d is a no-op" {
  run --separate-stderr "${HOOK}" -t stream --instance foo
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "post-run: stream + -d starts the viewer with stream-only + auto-launch" {
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e VIEWER_UI_MODE=stream-only'
  echo "${output}" | grep -qE 'docker run .*-e VIEWER_AUTO_LAUNCH=true'
  # Negative guard: the opposite values must not appear.
  ! echo "${output}" | grep -qE 'VIEWER_UI_MODE=usd-viewer'
  ! echo "${output}" | grep -qE 'VIEWER_AUTO_LAUNCH=false'
}

@test "post-run: viewer SIGNALING_PORT comes from the instance overlay env" {
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49200'
}

@test "post-run: viewer container is named per instance and removed first" {
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker rm -f owv-foo'
  echo "${output}" | grep -qE 'docker run .*--name owv-foo'
}

@test "post-run: default instance falls back to owv-default + port 49100" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qE 'docker run .*--name owv-default'
  echo "${output}" | grep -qE 'docker run .*-e SIGNALING_PORT=49100'
}

@test "post-run: host.yaml present is copied into the Isaac container" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 0 ]
  # cp into the per-instance Isaac container at /etc/host.yaml
  echo "${output}" | grep -qE 'docker cp .*alice-isaac-stream-foo:/etc/host.yaml'
}

@test "post-run: invalid host.yaml aborts with rc 1" {
  printf 'network:\n  public_ip: "a;rm -rf /"\n' > "${REPO}/config/host.yaml"
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 1 ]
}
