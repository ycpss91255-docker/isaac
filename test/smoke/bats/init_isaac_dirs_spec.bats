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

  # Copy the script + write a fake .env one level up (matches script's
  # `${script_dir}/.env` expectation where script_dir = dirname/..).
  cp "${SCRIPT_UNDER_TEST}" "${REPO_ROOT}/script/init_isaac_dirs.sh"
  chmod +x "${REPO_ROOT}/script/init_isaac_dirs.sh"
  printf 'WS_PATH=%s\n' "${WS_PATH}" > "${REPO_ROOT}/.env"
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

@test "missing .env errors with actionable message" {
  rm "${REPO_ROOT}/.env"
  run "${REPO_ROOT}/script/init_isaac_dirs.sh"
  assert_failure
  run grep -q ".env not found" <<<"${output}"
  assert_success
}
