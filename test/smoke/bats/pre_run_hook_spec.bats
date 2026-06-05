#!/usr/bin/env bats
#
# Unit guard for script/hooks/pre/run.sh (base #440 pre-run hook).
#
# Responsibility: for `run.sh ... --instance NAME`, create that
# instance's per-instance cache directory tree on the host so the
# compose bind mounts inherit the caller's ownership (salvages the
# mkdir logic from the retired init_instance.sh). No --instance -> no-op.
#
# The hook reads config/instances/<name>.env relative to FILE_PATH
# (exported by run.sh). Tests point FILE_PATH at a temp repo and assert
# the real directories are created. Baked into /smoke_test/ as
# pre_run_hook.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  HOOK="${BATS_TEST_DIRNAME}/pre_run_hook.sh"
  REPO="$(mktemp -d)"
  CACHE="$(mktemp -d)"
  export FILE_PATH="${REPO}"
  mkdir -p "${REPO}/config/instances"
}

teardown() {
  rm -rf "${REPO}" "${CACHE}"
}

_write_instance() {
  # $1 = name, $2 = INSTANCE_CACHE_DIR
  printf 'INSTANCE_CACHE_DIR=%s\nISAAC_SIGNAL_PORT=49200\n' "$2" \
    > "${REPO}/config/instances/$1.env"
}

@test "pre-run: --instance creates the 8 cache subdirs (absolute path)" {
  _write_instance foo "${CACHE}/foo"
  run --separate-stderr "${HOOK}" -t stream -d --instance foo
  [ "$status" -eq 0 ]
  for sub in kit/cache kit/data kit/logs ov/cache ov/data ov/logs \
             nvidia/glcache nvidia/computecache; do
    [ -d "${CACHE}/foo/${sub}" ]
  done
}

@test "pre-run: relative INSTANCE_CACHE_DIR resolves against FILE_PATH" {
  _write_instance bar "instance/bar"
  run --separate-stderr "${HOOK}" --instance bar -t stream -d
  [ "$status" -eq 0 ]
  [ -d "${REPO}/instance/bar/kit/cache" ]
}

@test "pre-run: no --instance is a no-op (creates nothing)" {
  run --separate-stderr "${HOOK}" -t stream -d
  [ "$status" -eq 0 ]
  # config/instances has no per-instance cache dirs created
  [ -z "$(find "${CACHE}" -mindepth 1 2>/dev/null)" ]
}

@test "pre-run: --instance with missing env warns but does not fail" {
  run --separate-stderr "${HOOK}" --instance ghost -t stream -d
  [ "$status" -eq 0 ]
  [[ "${stderr}" == *ghost* ]]
}
