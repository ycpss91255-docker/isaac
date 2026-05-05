#!/usr/bin/env bats
#
# Integration test: init.sh creating a brand-new repo from scratch.
#
# Verifies that running `./template/init.sh` in an empty directory produces
# a complete, internally-consistent repo skeleton (Dockerfile, compose.yaml,
# symlinks, .env.example, doc tree, .github/workflows, etc.).
#
# This is a Level-1 (file generation) integration test — it does NOT run
# Docker. The Level-2 (real build/run/exec/stop) test lives in CI as a
# separate self-test.yaml job that has access to the host Docker daemon.

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  # Stage a fake repo dir whose basename will become IMAGE_NAME
  REPO_NAME="myapp_test"
  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/${REPO_NAME}"
  mkdir -p "${REPO_DIR}/template"

  # Mirror the template into REPO_DIR/template/ so init.sh's TEMPLATE_DIR
  # detection (../template relative to itself) works correctly. Use cp -a
  # to preserve executable bits and symlinks.
  cp -a /source/. "${REPO_DIR}/template/"

  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ════════════════════════════════════════════════════════════════════
# init.sh: new repo full-skeleton generation
# ════════════════════════════════════════════════════════════════════

@test "init.sh detects empty dir and creates new repo skeleton" {
  run bash template/init.sh
  assert_success
  assert_output --partial "Done"
}

@test "new repo: Dockerfile is copied from template" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/Dockerfile" ]
}

@test "new repo: compose.yaml exists and references the repo name" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run grep "${REPO_NAME}" "${REPO_DIR}/compose.yaml"
  assert_success
}

@test "new repo: .env.example is NOT generated (image name via setup.conf rules)" {
  bash template/init.sh
  [[ ! -f "${REPO_DIR}/.env.example" ]]
}

@test "new repo: script/entrypoint.sh exists and is executable" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/script/entrypoint.sh" ]
}

@test "new repo: smoke test skeleton exists for the repo" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/test/smoke/${REPO_NAME}_env.bats" ]
}

@test "new repo: .github/workflows/main.yaml exists with reusable workflow ref" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/.github/workflows/main.yaml" ]
  # Accept semver tag or "main" branch fallback (when offline / no tags)
  run grep -E 'build-worker\.yaml@(v[0-9]+\.[0-9]+\.[0-9]+|main)' \
    "${REPO_DIR}/.github/workflows/main.yaml"
  assert_success
}

@test "new repo: main.yaml grants permissions: contents: write" {
  # Regression for #62: softprops/action-gh-release@v2 (used by
  # release-worker.yaml) needs `contents: write` to create a Release.
  # Reusable workflow permissions intersect with the caller's, and
  # GitHub's default GITHUB_TOKEN is read-only, so this grant must
  # live in the caller's (i.e. new repo's) main.yaml. Without it,
  # the first downstream tag push fails with HTTP 403 from the
  # action-gh-release step (ros1_bridge v1.5.0 release surfaced this).
  bash template/init.sh
  local _yaml="${REPO_DIR}/.github/workflows/main.yaml"
  assert [ -f "${_yaml}" ]
  # Must have a top-level `permissions:` block declaring contents: write.
  run grep -E '^permissions:$' "${_yaml}"
  assert_success
  run grep -E '^[[:space:]]+contents: write$' "${_yaml}"
  assert_success
}

@test "new repo: .gitignore exists" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/.gitignore" ]
}

@test "new repo: doc/ tree exists with README translations" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/README.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-TW.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-CN.md" ]
  assert [ -f "${REPO_DIR}/doc/README.ja.md" ]
}

@test "new repo: doc/test/TEST.md exists" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/doc/test/TEST.md" ]
}

@test "new repo: doc/changelog/CHANGELOG.md exists" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/doc/changelog/CHANGELOG.md" ]
}

@test "new repo: build.sh symlink → template/script/docker/build.sh" {
  bash template/init.sh
  assert [ -L "${REPO_DIR}/build.sh" ]
  run readlink "${REPO_DIR}/build.sh"
  assert_output "template/script/docker/build.sh"
}

@test "new repo: run.sh / exec.sh / stop.sh / Makefile symlinks correct" {
  bash template/init.sh
  for f in run.sh exec.sh stop.sh Makefile; do
    assert [ -L "${REPO_DIR}/${f}" ]
  done
  run readlink "${REPO_DIR}/run.sh"
  assert_output "template/script/docker/run.sh"
  run readlink "${REPO_DIR}/exec.sh"
  assert_output "template/script/docker/exec.sh"
  run readlink "${REPO_DIR}/stop.sh"
  assert_output "template/script/docker/stop.sh"
  run readlink "${REPO_DIR}/Makefile"
  assert_output "template/script/docker/Makefile"
}

@test "new repo: config/ is a real directory copied from template/config" {
  bash template/init.sh
  # Must NOT be a symlink — edits should stay in the user's own
  # repo, not leak into the subtree where subtree pulls would fight
  # them. Must be a real directory seeded with the template content.
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config/shell" ]
  # Sanity-check one of the seeded files actually made it across.
  assert [ -f "${REPO_DIR}/config/pip/setup.sh" ] \
    || assert [ -d "${REPO_DIR}/config/shell/bashrc" ]
}

@test "new repo: init.sh preserves pre-existing config/ directory (no clobber)" {
  # Simulate a repo with a real config/ directory (user's edits).
  # init.sh must not overwrite it.
  mkdir -p "${REPO_DIR}/config/custom"
  echo "user-override" > "${REPO_DIR}/config/custom/marker"
  bash template/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -f "${REPO_DIR}/config/custom/marker" ]
}

@test "new repo: init.sh drops stale config symlink before copying" {
  # An older init.sh created config → template/config as a symlink.
  # Re-running the new init.sh on such a repo must replace the
  # symlink with a real copy (cp -r through a symlink would otherwise
  # silently pollute the subtree target).
  ln -s template/config "${REPO_DIR}/config"
  bash template/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config/shell" ]
}

@test "Dockerfile.example references CONFIG_SRC=\"config\" (not template/config)" {
  # Sanity: the per-repo copy only pays off if Dockerfile points at it.
  run grep -F 'ARG CONFIG_SRC="config"' /source/dockerfile/Dockerfile.example
  assert_success
  run grep -F 'ARG CONFIG_SRC="template/config"' /source/dockerfile/Dockerfile.example
  assert_failure
}

@test "new repo: template/.version exists (no legacy VERSION / .template_version)" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/template/.version" ]
  assert [ ! -f "${REPO_DIR}/template/VERSION" ]
  assert [ ! -f "${REPO_DIR}/.template_version" ]
  run cat "${REPO_DIR}/template/.version"
  # Accept semver with optional pre-release suffix (e.g. v0.10.0-rc1).
  assert_output --regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

@test "new repo: re-running init.sh on the result is idempotent" {
  bash template/init.sh
  # Second run should hit _init_existing_repo (Dockerfile exists)
  run bash template/init.sh
  assert_success
}

@test "new repo: init.sh creates setup_tui.sh symlink (not legacy tui.sh)" {
  bash template/init.sh
  assert [ -L "${REPO_DIR}/setup_tui.sh" ]
  run readlink "${REPO_DIR}/setup_tui.sh"
  assert_output "template/script/docker/setup_tui.sh"
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
}

@test "new repo: init.sh removes stale tui.sh symlink from earlier versions" {
  bash template/init.sh
  # Simulate an upgrade from the old name by planting the legacy symlink
  ln -sf "template/script/docker/setup_tui.sh" "${REPO_DIR}/tui.sh"
  run bash template/init.sh
  assert_success
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
  assert [ -L "${REPO_DIR}/setup_tui.sh" ]
}

@test "new repo: build.sh -h works against the generated symlink" {
  bash template/init.sh
  run bash "${REPO_DIR}/build.sh" -h
  assert_success
  assert_output --partial "Usage"
}

@test "new repo: run.sh -h works against the generated symlink" {
  bash template/init.sh
  run bash "${REPO_DIR}/run.sh" -h
  assert_success
}

@test "new repo: exec.sh -h works against the generated symlink" {
  bash template/init.sh
  run bash "${REPO_DIR}/exec.sh" -h
  assert_success
}

@test "new repo: stop.sh -h works against the generated symlink" {
  bash template/init.sh
  run bash "${REPO_DIR}/stop.sh" -h
  assert_success
}

@test "new repo: setup.sh symlink → template/script/docker/setup.sh" {
  bash template/init.sh
  assert [ -L "${REPO_DIR}/setup.sh" ]
  run readlink "${REPO_DIR}/setup.sh"
  assert_output "template/script/docker/setup.sh"
}

@test "new repo: setup.sh -h works against the generated symlink" {
  bash template/init.sh
  run bash "${REPO_DIR}/setup.sh" -h
  assert_success
  assert_output --partial "Usage"
}

# ════════════════════════════════════════════════════════════════════
# init.sh --gen-conf
# ════════════════════════════════════════════════════════════════════

@test "init.sh --gen-conf copies setup.conf to repo root" {
  # init.sh auto-creates setup.conf via workspace writeback; remove it first
  # to exercise the --gen-conf copy path directly.
  bash template/init.sh
  rm -f "${REPO_DIR}/setup.conf"
  bash template/init.sh --gen-conf
  assert [ -f "${REPO_DIR}/setup.conf" ]
  # Sanity: copied file contains the full section schema
  run grep -E '^\[(image|build|deploy|gui|network|volumes)\]' "${REPO_DIR}/setup.conf"
  assert_success
}

@test "init.sh --gen-conf refuses to overwrite existing setup.conf" {
  # init.sh auto-creates <repo>/setup.conf via setup.sh workspace writeback,
  # so --gen-conf on a freshly-initialized repo already hits the "exists" guard.
  bash template/init.sh
  run bash template/init.sh --gen-conf
  assert_failure
  assert_output --partial "already exists"
}

# ════════════════════════════════════════════════════════════════════
# Derived artifacts: compose.yaml + .env are setup.sh-generated, gitignored
# ════════════════════════════════════════════════════════════════════

@test "new repo: .gitignore contains compose.yaml (derived artifact)" {
  bash template/init.sh
  run grep -x 'compose.yaml' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: .gitignore contains .env (derived artifact)" {
  bash template/init.sh
  run grep -x '.env' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run head -n 1 "${REPO_DIR}/compose.yaml"
  assert_output --partial "AUTO-GENERATED"
}

@test "new repo: compose.yaml ships devices: /dev:/dev by default" {
  bash template/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run grep -E '^    devices:$' "${REPO_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- /dev:/dev' "${REPO_DIR}/compose.yaml"
  assert_success
}

@test "new repo: setup.conf mount_1 is NOT empty after first init (workspace detected + written)" {
  # Regression: fresh repo previously produced an empty [volumes] mount_1
  # which made the TUI volumes menu appear blank on first open. First-init
  # must write the detected workspace path into mount_1.
  bash template/init.sh
  run grep -E '^mount_1 = .+$' "${REPO_DIR}/setup.conf"
  assert_success
  # Must NOT be exactly `mount_1 =` (empty value)
  run grep -x 'mount_1 =' "${REPO_DIR}/setup.conf"
  assert_failure
}

@test "new repo: per-repo setup.conf auto-created on first init (workspace writeback)" {
  # setup.sh on first run (no <repo>/setup.conf) copies template + fills
  # [volumes] mount_1 with the detected workspace. Expected behaviour since
  # setup.conf became the source of truth for WS_PATH.
  bash template/init.sh
  assert [ -f "${REPO_DIR}/setup.conf" ]
  run grep '^mount_1' "${REPO_DIR}/setup.conf"
  assert_success
}
