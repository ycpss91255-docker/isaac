#!/usr/bin/env bats
#
# Integration test: init.sh creating a brand-new repo from scratch.
#
# Verifies that running `./.base/init.sh` in an empty directory produces
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
  mkdir -p "${REPO_DIR}/.base"

  # Mirror the template into REPO_DIR/.base/ so init.sh's TEMPLATE_DIR
  # detection (../template relative to itself) works correctly. Use cp -a
  # to preserve executable bits and symlinks.
  cp -a /source/. "${REPO_DIR}/.base/"

  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ════════════════════════════════════════════════════════════════════
# init.sh: new repo full-skeleton generation
# ════════════════════════════════════════════════════════════════════

@test "init.sh detects empty dir and creates new repo skeleton" {
  run bash .base/init.sh
  assert_success
  assert_output --partial "Done"
}

@test "new repo: Dockerfile is copied from template" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/Dockerfile" ]
}

@test "new repo: compose.yaml exists and references the repo name" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run grep "${REPO_NAME}" "${REPO_DIR}/compose.yaml"
  assert_success
}

@test "new repo: .env.example is NOT generated (image name via setup.conf rules)" {
  bash .base/init.sh
  [[ ! -f "${REPO_DIR}/.env.example" ]]
}

@test "new repo: script/entrypoint.sh exists and is executable" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/script/entrypoint.sh" ]
}

@test "new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)" {
  # The helper is no-op safe when LOG_FILE_PATH is unset (early-return
  # in _entrypoint_logging.sh), so default-sourcing has zero side
  # effect when [logging] local_path is empty. Wiring it here closes
  # the v0.30.0 `local_path` UX gap: setting the conf alone is now
  # enough for the host file to materialise -- no manual entrypoint.sh
  # edit required.
  #
  # The source path is the stable in-image path shipped by #368 / PR
  # #372 (COPY into /usr/local/lib/base/). It deliberately avoids
  # ${USER} expansion + the workspace bind mount path, both of which
  # the v0.30.0 example mis-used.
  bash .base/init.sh
  local _entry="${REPO_DIR}/script/entrypoint.sh"
  assert [ -f "${_entry}" ]
  # Source line — must be the in-image path.
  run grep -F '. /usr/local/lib/base/_entrypoint_logging.sh' "${_entry}"
  assert_success
  # Explanatory comment so casual readers know what the source does.
  run grep -F '[logging] local_path' "${_entry}"
  assert_success
  # Regression guards against the broken v0.30.0 example.
  run grep -F '${USER}' "${_entry}"
  assert_failure
  run grep -F '/home/' "${_entry}"
  assert_failure
}

@test "new repo: smoke test skeleton exists for the repo" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/test/smoke/${REPO_NAME}_env.bats" ]
}

@test "new repo: .github/workflows/main.yaml exists with reusable workflow ref" {
  bash .base/init.sh
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
  bash .base/init.sh
  local _yaml="${REPO_DIR}/.github/workflows/main.yaml"
  assert [ -f "${_yaml}" ]
  # Must have a top-level `permissions:` block declaring contents: write.
  run grep -E '^permissions:$' "${_yaml}"
  assert_success
  run grep -E '^[[:space:]]+contents: write$' "${_yaml}"
  assert_success
}

@test "new repo: .gitignore exists" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/.gitignore" ]
}

@test "new repo: doc/ tree exists with README translations" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/README.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-TW.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-CN.md" ]
  assert [ -f "${REPO_DIR}/doc/README.ja.md" ]
}

@test "new repo: doc/test/TEST.md exists" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/doc/test/TEST.md" ]
}

@test "new repo: doc/changelog/CHANGELOG.md exists" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/doc/changelog/CHANGELOG.md" ]
}

@test "new repo: build.sh symlink lives under script/, not root (#330)" {
  bash .base/init.sh
  assert [ -L "${REPO_DIR}/script/build.sh" ]
  run readlink "${REPO_DIR}/script/build.sh"
  assert_output "../.base/script/docker/build.sh"
  # Root must NOT have build.sh after #330.
  assert [ ! -e "${REPO_DIR}/build.sh" ]
}

@test "new repo: 7 wrapper symlinks under script/, Makefile stays at root (#330)" {
  bash .base/init.sh
  # 7 wrappers under script/, each pointing to ../.base/script/docker/<name>.sh
  for f in run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ -L "${REPO_DIR}/script/${f}" ]
    run readlink "${REPO_DIR}/script/${f}"
    assert_output "../.base/script/docker/${f}"
    # And NOT at root.
    assert [ ! -e "${REPO_DIR}/${f}" ]
  done
  # Makefile retains the root location (the elevated user entry).
  assert [ -L "${REPO_DIR}/Makefile" ]
  run readlink "${REPO_DIR}/Makefile"
  assert_output ".base/script/docker/Makefile"
}

@test "new repo: config/ is an empty placeholder (template#254 layered override)" {
  bash .base/init.sh
  # Must NOT be a symlink — edits should stay in the user's own
  # repo, not leak into the subtree where subtree pulls would fight
  # them. Must be a real directory.
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  # Pre-#254 init.sh seeded a FULL copy of .base/config/ here.
  # Post-#254 (template v0.22.0+) init.sh creates an empty
  # placeholder with just a .gitkeep -- the Dockerfile's layered
  # COPY chain reads .base/config/ as defaults and <repo>/config/
  # as overrides, so an empty <repo>/config/ means "no overrides,
  # use all template defaults". Downstream adds files only when
  # they want to override a specific template file.
  assert [ -f "${REPO_DIR}/config/.gitkeep" ]
  # Confirm no full-tree seed: shell/, pip/, etc. should NOT be
  # auto-populated. (Existing repos with a pre-#254 full copy still
  # work via the next test's preserve-existing path.)
  # Post-#262: config/docker/ is allowed because setup.sh's first-time
  # bootstrap seeds config/docker/setup.conf from the template; nothing
  # else under config/ is auto-populated.
  run find "${REPO_DIR}/config" -mindepth 1 -maxdepth 1 \
    -not -name '.gitkeep' -not -name 'docker'
  assert_output ""
  # Confirm docker/ contains only the bootstrapped setup.conf.
  run find "${REPO_DIR}/config/docker" -mindepth 1 -maxdepth 1 -not -name 'setup.conf'
  assert_output ""
}

@test "new repo: init.sh preserves pre-existing config/ directory (no clobber)" {
  # Simulate a repo with a real config/ directory (user's edits).
  # init.sh must not overwrite it.
  mkdir -p "${REPO_DIR}/config/custom"
  echo "user-override" > "${REPO_DIR}/config/custom/marker"
  bash .base/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -f "${REPO_DIR}/config/custom/marker" ]
}

@test "new repo: init.sh drops stale config symlink before creating placeholder" {
  # An older init.sh created config → .base/config as a symlink.
  # Re-running the post-#254 init.sh on such a repo must replace the
  # symlink with the empty placeholder (mkdir through a symlink
  # would otherwise pollute the subtree target).
  ln -s .base/config "${REPO_DIR}/config"
  bash .base/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -f "${REPO_DIR}/config/.gitkeep" ]
}

@test "Dockerfile.example references CONFIG_SRC=\"config\" (not .base/config)" {
  # Sanity: the per-repo copy only pays off if Dockerfile points at it.
  run grep -F 'ARG CONFIG_SRC="config"' /source/dockerfile/Dockerfile.example
  assert_success
  run grep -F 'ARG CONFIG_SRC=".base/config"' /source/dockerfile/Dockerfile.example
  assert_failure
}

@test "Dockerfile.example has layered config COPY chain (template#254): .base/config first, then config" {
  # Layered file-level override: layer 1 brings .base/config/
  # defaults, layer 2 overlays <repo>/config/. Files in layer 2
  # override same-path files from layer 1; files only in layer 1
  # remain. Order matters -- if layer 2 came first, layer 1 would
  # overwrite the overrides. Test asserts both lines exist AND the
  # order is correct.
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Both COPY lines exist with --chown / --chmod metadata.
  run grep -E '^COPY --chown=.* .base/config "\$\{CONFIG_DIR\}"$' "${_df}"
  assert_success
  run grep -E '^COPY --chown=.* "\$\{CONFIG_SRC\}" "\$\{CONFIG_DIR\}"$' "${_df}"
  assert_success
  # Order: .base/config COPY line number must be LESS than
  # config-src COPY line number.
  local _line1 _line2
  _line1=$(grep -nE '^COPY --chown=.* .base/config "\$\{CONFIG_DIR\}"$' "${_df}" | head -1 | cut -d: -f1)
  _line2=$(grep -nE '^COPY --chown=.* "\$\{CONFIG_SRC\}" "\$\{CONFIG_DIR\}"$' "${_df}" | head -1 | cut -d: -f1)
  [[ "${_line1}" -lt "${_line2}" ]] || {
    echo "expected .base/config COPY (line ${_line1}) BEFORE config-src COPY (line ${_line2})"
    return 1
  }
}

@test "Dockerfile.example declares ENV HOME before WORKDIR \${HOME}/work (#334)" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # WORKDIR is a Docker directive that interpolates build-time ARG /
  # ENV, not shell-time $HOME. Without an explicit ENV HOME, the
  # `WORKDIR "${HOME}/work"` collapses to /work and BuildKit emits
  # `WARN: UndefinedVar`. The ENV must appear BEFORE the WORKDIR.
  run grep -nF 'ENV HOME="/home/${USER_NAME}"' "${_df}"
  assert_success
  local _env_line _workdir_line
  _env_line="$(grep -nF 'ENV HOME="/home/${USER_NAME}"' "${_df}" | head -1 | cut -d: -f1)"
  _workdir_line="$(grep -nF 'WORKDIR "${HOME}/work"' "${_df}" | grep -v '^[0-9]*:#' | head -1 | cut -d: -f1)"
  [[ -n "${_env_line}" && -n "${_workdir_line}" ]]
  (( _env_line < _workdir_line ))
}

@test "Dockerfile.example sets up bashrc.d drop-in directory (template#254)" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The shell-setup RUN block must mkdir ~/.bashrc.d AND copy
  # *.sh from CONFIG_DIR/shell/bashrc.d/ into it. The cp -n form
  # tolerates missing source files (.base/config/shell/bashrc.d/
  # is empty by default; only an explicit .gitkeep ships).
  run grep -F 'mkdir -p "${HOME}/.bashrc.d"' "${_df}"
  assert_success
  run grep -F 'cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/"' "${_df}"
  assert_success
}

@test "new repo: Dockerfile contains _entrypoint_logging.sh in-image COPY (#368)" {
  # End-to-end check that a fresh init.sh-generated repo includes the
  # Dockerfile COPY for the helper. The helper must land at the
  # stable in-image path so downstream entrypoints can source it
  # with a clean `. /usr/local/lib/base/_entrypoint_logging.sh`
  # one-liner -- no $USER deref, no WS_PATH dependence, works at
  # build-time smoke AND runtime on multi-repo workspaces. Pin the
  # COPY here so init.sh seeding regressions are caught.
  bash .base/init.sh
  local _df="${REPO_DIR}/Dockerfile"
  assert [ -f "${_df}" ]
  run grep -F 'COPY --chmod=0755 .base/script/docker/_entrypoint_logging.sh /usr/local/lib/base/_entrypoint_logging.sh' "${_df}"
  assert_success
}

@test "new repo: .base/.version exists (no legacy VERSION / .template_version)" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/.base/.version" ]
  assert [ ! -f "${REPO_DIR}/.base/VERSION" ]
  assert [ ! -f "${REPO_DIR}/.template_version" ]
  run cat "${REPO_DIR}/.base/.version"
  # Accept semver with optional pre-release suffix (e.g. v0.10.0-rc1).
  assert_output --regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

@test "new repo: re-running init.sh on the result is idempotent" {
  bash .base/init.sh
  # Second run should hit _init_existing_repo (Dockerfile exists)
  run bash .base/init.sh
  assert_success
}

@test "new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)" {
  bash .base/init.sh
  assert [ -L "${REPO_DIR}/script/setup_tui.sh" ]
  run readlink "${REPO_DIR}/script/setup_tui.sh"
  assert_output "../.base/script/docker/setup_tui.sh"
  # Neither old root-level setup_tui.sh nor pre-rename tui.sh.
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
  assert [ ! -e "${REPO_DIR}/setup_tui.sh" ]
}

@test "new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)" {
  bash .base/init.sh
  # Simulate a very old upgrade path: legacy tui.sh symlink at root.
  ln -sf ".base/script/docker/setup_tui.sh" "${REPO_DIR}/tui.sh"
  run bash .base/init.sh
  assert_success
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
  assert [ -L "${REPO_DIR}/script/setup_tui.sh" ]
}

@test "new repo: init.sh removes stale root *.sh symlinks (#330 migration)" {
  bash .base/init.sh
  # Simulate a pre-#330 layout by planting the seven root-level symlinks
  # an older init.sh would have produced. Re-running the post-#330
  # init.sh must remove all of them and ensure script/ versions exist.
  for f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    ln -sf ".base/script/docker/${f}" "${REPO_DIR}/${f}"
  done
  run bash .base/init.sh
  assert_success
  for f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ ! -e "${REPO_DIR}/${f}" ]
    assert [ -L "${REPO_DIR}/script/${f}" ]
  done
}

@test "new repo: build.sh -h works against the generated symlink" {
  bash .base/init.sh
  run bash "${REPO_DIR}/script/build.sh" -h
  assert_success
  assert_output --partial "Usage"
}

@test "new repo: run.sh -h works against the generated symlink" {
  bash .base/init.sh
  run bash "${REPO_DIR}/script/run.sh" -h
  assert_success
}

@test "new repo: exec.sh -h works against the generated symlink" {
  bash .base/init.sh
  run bash "${REPO_DIR}/script/exec.sh" -h
  assert_success
}

@test "new repo: stop.sh -h works against the generated symlink" {
  bash .base/init.sh
  run bash "${REPO_DIR}/script/stop.sh" -h
  assert_success
}

@test "new repo: setup.sh symlink under script/ → ../.base/script/docker/setup.sh" {
  bash .base/init.sh
  assert [ -L "${REPO_DIR}/script/setup.sh" ]
  run readlink "${REPO_DIR}/script/setup.sh"
  assert_output "../.base/script/docker/setup.sh"
}

@test "new repo: setup.sh -h works against the generated symlink" {
  bash .base/init.sh
  run bash "${REPO_DIR}/script/setup.sh" -h
  assert_success
  assert_output --partial "Usage"
}

# ════════════════════════════════════════════════════════════════════
# init.sh --gen-conf
# ════════════════════════════════════════════════════════════════════

@test "init.sh --gen-conf copies setup.conf to repo root" {
  # init.sh auto-creates setup.conf via workspace writeback; remove it first
  # to exercise the --gen-conf copy path directly.
  bash .base/init.sh
  rm -f "${REPO_DIR}/config/docker/setup.conf"
  bash .base/init.sh --gen-conf
  assert [ -f "${REPO_DIR}/config/docker/setup.conf" ]
  # Sanity: copied file contains the full section schema
  run grep -E '^\[(image|build|deploy|gui|network|volumes)\]' "${REPO_DIR}/config/docker/setup.conf"
  assert_success
}

@test "init.sh --gen-conf refuses to overwrite existing setup.conf" {
  # init.sh auto-creates <repo>/config/docker/setup.conf via setup.sh workspace writeback,
  # so --gen-conf on a freshly-initialized repo already hits the "exists" guard.
  bash .base/init.sh
  run bash .base/init.sh --gen-conf
  assert_failure
  assert_output --partial "already exists"
}

# ════════════════════════════════════════════════════════════════════
# Derived artifacts: compose.yaml + .env are setup.sh-generated, gitignored
# ════════════════════════════════════════════════════════════════════

@test "new repo: .gitignore contains compose.yaml (derived artifact)" {
  bash .base/init.sh
  run grep -x 'compose.yaml' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: .gitignore contains .env (derived artifact)" {
  bash .base/init.sh
  run grep -x '.env' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)" {
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run head -n 1 "${REPO_DIR}/compose.yaml"
  assert_output --partial "AUTO-GENERATED"
}

@test "new repo: compose.yaml ships devices: /dev:/dev by default" {
  bash .base/init.sh
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
  bash .base/init.sh
  run grep -E '^mount_1 = .+$' "${REPO_DIR}/config/docker/setup.conf"
  assert_success
  # Must NOT be exactly `mount_1 =` (empty value)
  run grep -x 'mount_1 =' "${REPO_DIR}/config/docker/setup.conf"
  assert_failure
}

@test "new repo: per-repo setup.conf auto-created on first init (workspace writeback)" {
  # setup.sh on first run (no <repo>/config/docker/setup.conf) copies template + fills
  # [volumes] mount_1 with the detected workspace. Expected behaviour since
  # setup.conf became the source of truth for WS_PATH.
  bash .base/init.sh
  assert [ -f "${REPO_DIR}/config/docker/setup.conf" ]
  run grep '^mount_1' "${REPO_DIR}/config/docker/setup.conf"
  assert_success
}
