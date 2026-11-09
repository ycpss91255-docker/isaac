#!/usr/bin/env bats
#
# Unit tests for script/init_isaac_dirs.sh — the host-side mkdir helper
# that pre-creates Isaac Sim cache dirs so the container's non-root user
# can write to them. Tests both:
#   - the post-2026-05-21 namespaced layout dirs are created
#   - the auto-migration from the pre-refactor flat layout (issue #21)
#
# Runs inside the devel-test stage. The script + a fake .env / WS_PATH
# are set up in BATS_TEST_TMPDIR so the test never touches real host state.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # The Dockerfile devel-test stage COPYs `script/*.sh` to /lint/script/.
  # Use that as the canonical copy of init_isaac_dirs.sh (kept in sync
  # with /home/${USER_NAME}/work/script/ via the bind mount at runtime,
  # but the lint copy is the image-baked version we want to assert).
  SCRIPT_UNDER_TEST="/lint/script/init_isaac_dirs.sh"

  REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
  WS_PATH="${BATS_TEST_TMPDIR}/ws"
  mkdir -p "${REPO_ROOT}/script" "${WS_PATH}"

  # Copy the script + write the setup-derived cache one level up. base
  # v0.42.0 writes WS_PATH to .env.generated; .env is only the hand-edited
  # workload overlay and carries no WS_PATH.
  cp "${SCRIPT_UNDER_TEST}" "${REPO_ROOT}/script/init_isaac_dirs.sh"
  chmod +x "${REPO_ROOT}/script/init_isaac_dirs.sh"
  printf 'WS_PATH=%s\n' "${WS_PATH}" > "${REPO_ROOT}/.env.generated"
}

@test "script-under-test is baked into the test stage" {
  assert_file_exists "${SCRIPT_UNDER_TEST}"
}

@test "fresh run creates all 10 namespaced dirs" {
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  for d in \
      "${WS_PATH}/isaac-sim/kit/cache" \
      "${WS_PATH}/isaac-sim/kit/data" \
      "${WS_PATH}/isaac-sim/kit/logs" \
      "${WS_PATH}/isaac-sim/ov/cache" \
      "${WS_PATH}/isaac-sim/ov/data" \
      "${WS_PATH}/isaac-sim/ov/logs" \
      "${WS_PATH}/isaac-sim/pip" \
      "${WS_PATH}/isaac-sim/nvidia/glcache" \
      "${WS_PATH}/isaac-sim/nvidia/computecache" \
      "${WS_PATH}/isaac-sim/documents"; do
    test -d "${d}" || { echo "expected dir missing: ${d}" >&2; return 1; }
  done
}

@test "second run is idempotent (no error, no double-mkdir noise)" {
  "${REPO_ROOT}/script/init_isaac_dirs.sh" > /dev/null
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
}

@test "migration: pre-2026-05-21 layout is auto-moved to new namespaces" {
  # Seed pre-refactor layout with sentinel files so we can assert
  # the migration is a `mv` (content preserved), not just an `mkdir`.
  base="${WS_PATH}/isaac-sim"
  mkdir -p "${base}/cache/kit" "${base}/cache/ov" "${base}/cache/pip" \
           "${base}/cache/glcache" "${base}/cache/computecache" \
           "${base}/logs" "${base}/data"
  echo "kit-cache-sentinel" > "${base}/cache/kit/marker"
  echo "ov-cache-sentinel"  > "${base}/cache/ov/marker"
  echo "pip-sentinel"       > "${base}/cache/pip/marker"
  echo "glcache-sentinel"   > "${base}/cache/glcache/marker"
  echo "compute-sentinel"   > "${base}/cache/computecache/marker"
  echo "logs-sentinel"      > "${base}/logs/marker"
  echo "data-sentinel"      > "${base}/data/marker"

  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success

  # Each migrated sentinel must land at the new namespaced path.
  run cat "${base}/kit/cache/marker";          assert_output "kit-cache-sentinel"
  run cat "${base}/ov/cache/marker";           assert_output "ov-cache-sentinel"
  run cat "${base}/pip/marker";                assert_output "pip-sentinel"
  run cat "${base}/nvidia/glcache/marker";     assert_output "glcache-sentinel"
  run cat "${base}/nvidia/computecache/marker";assert_output "compute-sentinel"
  run cat "${base}/ov/logs/marker";            assert_output "logs-sentinel"
  run cat "${base}/ov/data/marker";            assert_output "data-sentinel"

  # Old paths must be gone after the move (verifies it's `mv` not `cp`).
  for old in cache/kit cache/ov cache/pip cache/glcache cache/computecache logs data; do
    test ! -d "${base}/${old}" || { echo "leftover old dir: ${old}" >&2; return 1; }
  done
}

@test "migration skips when destination already exists (no overwrite)" {
  base="${WS_PATH}/isaac-sim"
  mkdir -p "${base}/cache/kit" "${base}/kit/cache"
  echo "old-content" > "${base}/cache/kit/marker"
  echo "new-content" > "${base}/kit/cache/marker"

  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success

  # When destination exists, migration is skipped (new wins, old preserved).
  run cat "${base}/kit/cache/marker"
  assert_output "new-content"
  # Old path stays — operator can inspect / merge / delete manually.
  test -d "${base}/cache/kit"
}

@test "WS_PATH comes from .env.generated, not the .env overlay" {
  # A fresh checkout's .env is the workload overlay; it has no WS_PATH, and
  # a stale one must not win over the resolved cache.
  printf 'WS_PATH=%s\n' "${BATS_TEST_TMPDIR}/wrong" > "${REPO_ROOT}/.env"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  test -d "${WS_PATH}/isaac-sim/kit/cache"
  test ! -e "${BATS_TEST_TMPDIR}/wrong/isaac-sim"
}

@test "no .env.generated yet: runs ./script/setup.sh apply to generate it" {
  rm "${REPO_ROOT}/.env.generated"
  # Stub of the base setup wrapper: records the call, writes the cache.
  cat > "${REPO_ROOT}/script/setup.sh" <<STUB
#!/usr/bin/env bash
echo "\$*" > "${BATS_TEST_TMPDIR}/setup.args"
printf 'WS_PATH=%s\n' "${WS_PATH}" > "${REPO_ROOT}/.env.generated"
STUB
  chmod +x "${REPO_ROOT}/script/setup.sh"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  run cat "${BATS_TEST_TMPDIR}/setup.args"
  assert_output "apply"
  test -d "${WS_PATH}/isaac-sim/documents"
}

@test "no .env.generated and no setup.sh: actionable error, no removed ./build.sh hint" {
  rm "${REPO_ROOT}/.env.generated"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_failure
  assert_output --partial "setup.sh apply"
  refute_output --partial "./build.sh"
}

@test "success hint names just docker, not the removed ./build.sh / ./run.sh" {
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  assert_output --partial "just docker build"
  refute_output --partial "./build.sh"
  refute_output --partial "./run.sh"
}

@test "Kit screenshots dir is pre-created writable and a mode-000 one is repaired" {
  local _shots="${WS_PATH}/isaac-sim/documents/Kit/shared/screenshots"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  test -d "${_shots}" && test -w "${_shots}" && test -x "${_shots}"
  # Kit creates this dir with mode 000 when it does not exist yet.
  chmod 000 "${_shots}"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_success
  run stat -c '%a' "${_shots}"
  assert_output "755"
}

@test "pre-run hook creates the cache dirs before compose can mount them as root" {
  # `just docker run` before init used to let the daemon mkdir the mount
  # sources as root, and Kit then failed to register the ROS 2 OmniGraph
  # nodes ([Errno 13] .../kit/cache/ogn_generated) while still exiting 0.
  printf 'WS_PATH=%s\nIMAGE_NAME=isaac-wt-1a2b3c\nPROJECT_NAME=alice-isaac-wt-1a2b3c\nDOCKER_HUB_USER=alice\n' \
    "${WS_PATH}" > "${REPO_ROOT}/.env.generated"
  FILE_PATH="${REPO_ROOT}" ISAAC_IDENTITY_LIB="${BATS_TEST_DIRNAME}/checkout_identity.sh" \
    run "${BATS_TEST_DIRNAME}/pre_run_hook.sh" -t headless -d
  assert_success
  test -d "${WS_PATH}/isaac-sim/kit/cache"
  test -d "${WS_PATH}/isaac-sim/documents/Kit/shared/screenshots"
}
