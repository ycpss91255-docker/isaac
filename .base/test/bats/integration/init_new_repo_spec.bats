#!/usr/bin/env bats
#
# Integration test: init.sh creating a brand-new repo from scratch.
#
# Verifies that running `./.base/dist/script/base/init.sh` in an empty directory produces
# a complete, internally-consistent repo skeleton (Dockerfile, compose.yaml,
# symlinks, .env.example, doc tree, .github/workflows, etc.).
#
# This is a Level-1 (file generation) integration test — it does NOT run
# Docker. The Level-2 (real build/run/exec/stop) test lives in CI as a
# separate self-test.yaml job that has access to the host Docker daemon.

setup() {
  export LOG_FORMAT=text
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
  # A real vendored subtree never carries `.git` (the consumer's `.git`
  # lives at the repo root, outside the subtree). `cp -a /source/.` copies
  # the source checkout's `.git`, which the self-run guard (ADR-00000011
  # sec.8) would (correctly) read as "this is the base source" -- strip it
  # so the fixture matches a genuine `.base/` subtree.
  rm -rf "${REPO_DIR}/.base/.git"

  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ════════════════════════════════════════════════════════════════════
# init.sh: new repo full-skeleton generation
# ════════════════════════════════════════════════════════════════════

@test "init.sh detects empty dir and creates new repo skeleton" {
  run bash .base/dist/script/base/init.sh
  assert_success
  assert_output --partial "Done"
}

@test "new repo: Dockerfile is copied from template" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/Dockerfile" ]
}

@test "new repo: compose.yaml exists and references the repo name" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run grep "${REPO_NAME}" "${REPO_DIR}/compose.yaml"
  assert_success
}

@test "new repo: .env.example is NOT generated (image name via setup.conf rules)" {
  bash .base/dist/script/base/init.sh
  [[ ! -f "${REPO_DIR}/.env.example" ]]
}

@test "new repo: script/entrypoint.sh exists and is executable" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/script/entrypoint.sh" ]
}

@test "new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)" {
  # The helper is no-op safe when LOG_FILE_PATH is unset (early-return
  # in logging.sh), so default-sourcing has zero side
  # effect when [logging] local_path is empty. Wiring it here closes
  # the v0.30.0 `local_path` UX gap: setting the conf alone is now
  # enough for the host file to materialise -- no manual entrypoint.sh
  # edit required.
  #
  # The source path is the stable in-image path shipped byPR
  # (COPY into /usr/local/lib/base). It deliberately avoids
  # ${USER} expansion + the workspace bind mount path, both of which
  # the v0.30.0 example mis-used.
  bash .base/dist/script/base/init.sh
  local _entry="${REPO_DIR}/script/entrypoint.sh"
  assert [ -f "${_entry}" ]
  # Source line — must be the in-image path.
  run grep -F '. /usr/local/lib/base/logging.sh' "${_entry}"
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
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/test/bats/smoke/shared/${REPO_NAME}_env.bats" ]
}

@test "new repo: smoke tree is per-stage tool-first (shared/devel-test/runtime-test), not flat test/smoke/ (S4 items 5,8)" {
  bash .base/dist/script/base/init.sh
  # Tool-first bats layer, one folder per Dockerfile -test stage, mirroring
  # .base/dist/test/bats/smoke/. shared/ runs on every -test stage; the
  # per-stage folders start as reserved placeholders so the Dockerfile's
  # per-stage selective COPY resolves before the consumer adds specs.
  assert [ -d "${REPO_DIR}/test/bats/smoke/shared" ]
  assert [ -f "${REPO_DIR}/test/bats/smoke/devel-test/.gitkeep" ]
  assert [ -f "${REPO_DIR}/test/bats/smoke/runtime-test/.gitkeep" ]
  # The retired flat layout must NOT be scaffolded.
  assert [ ! -d "${REPO_DIR}/test/smoke" ]
}

@test "new repo: shared smoke spec loads test_helper (resolves via Dockerfile COPY at build time) (S4 item 8)" {
  bash .base/dist/script/base/init.sh
  # The generated repo spec load-s test_helper; that name resolves only
  # because each -test Dockerfile stage COPYs .base/dist/test/bats/smoke/
  # shared/ (which ships test_helper.bash) alongside the repo's own
  # test/bats/smoke/shared/ into /smoke_test/. Assert the load line and
  # the shipped helper both exist so the build-time resolution holds.
  run grep -F 'load "${BATS_TEST_DIRNAME}/test_helper"' \
    "${REPO_DIR}/test/bats/smoke/shared/${REPO_NAME}_env.bats"
  assert_success
  assert [ -f "${REPO_DIR}/.base/dist/test/bats/smoke/shared/test_helper.bash" ]
}

@test "new repo: .github/workflows/main.yaml exists with reusable workflow ref" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.github/workflows/main.yaml" ]
  # Accept semver tag or "main" branch fallback (when offline / no tags)
  run grep -E 'build-worker\.yaml@(v[0-9]+\.[0-9]+\.[0-9]+|main)' \
    "${REPO_DIR}/.github/workflows/main.yaml"
  assert_success
}

@test "new repo: .github/workflows/base-version-monitor.yaml exists (#777)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.github/workflows/base-version-monitor.yaml" ]
  # Thin scheduler that defers to the subtree-shipped checker.
  run grep -F '.base/dist/script/base/check-base-version.sh run' \
    "${REPO_DIR}/.github/workflows/base-version-monitor.yaml"
  assert_success
}

@test "new repo: main.yaml grants permissions: contents: write" {
  # Regression forsoftprops/action-gh-release@v2 (used by
  # release-worker.yaml) needs `contents: write` to create a Release.
  # Reusable workflow permissions intersect with the caller's, and
  # GitHub's default GITHUB_TOKEN is read-only, so this grant must
  # live in the caller's (i.e. new repo's) main.yaml. Without it,
  # the first downstream tag push fails with HTTP 403 from the
  # action-gh-release step (ros1_bridge v1.5.0 release surfaced this).
  bash .base/dist/script/base/init.sh
  local _yaml="${REPO_DIR}/.github/workflows/main.yaml"
  assert [ -f "${_yaml}" ]
  # Must have a top-level `permissions:` block declaring contents: write.
  run grep -E '^permissions:$' "${_yaml}"
  assert_success
  run grep -E '^[[:space:]]+contents: write$' "${_yaml}"
  assert_success
}

@test "new repo: .gitignore exists" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.gitignore" ]
}

@test "new repo: .dockerignore exists (#604)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.dockerignore" ]
}

@test "new repo: .dockerignore contains compose.yaml (derived artifact) (#604)" {
  bash .base/dist/script/base/init.sh
  run grep -x 'compose.yaml' "${REPO_DIR}/.dockerignore"
  assert_success
}

@test "new repo: doc/ tree exists with README translations" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/README.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-TW.md" ]
  assert [ -f "${REPO_DIR}/doc/README.zh-CN.md" ]
  assert [ -f "${REPO_DIR}/doc/README.ja.md" ]
}

@test "new repo: doc/test/TEST.md exists" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/doc/test/TEST.md" ]
}

@test "new repo: TEST.md total matches the actual generated @test count (no stale 1 test) (S4 item 6)" {
  bash .base/dist/script/base/init.sh
  local _test_md="${REPO_DIR}/doc/test/TEST.md"
  assert [ -f "${_test_md}" ]
  # Source of truth: grep -cE '^@test' across the generated smoke specs,
  # identical to base's sync-doc-counts.sh counting mechanism. The
  # hardcoded "**1 test** total" the pre-S4 scaffold shipped was both a
  # wrong figure (the spec carries 2 @tests) AND under a `##` heading the
  # auto-counter's `### <path> (N)` regex cannot match.
  local _actual=0 _f _c
  shopt -s globstar
  for _f in "${REPO_DIR}"/test/bats/smoke/**/*.bats; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _actual=$(( _actual + ${_c:-0} ))
  done
  shopt -u globstar
  # The generated total must equal the real @test count.
  run grep -E "\*\*${_actual} tests?\*\*" "${_test_md}"
  assert_success
  # And the stale hardcoded "1 test" figure must be gone (guard against
  # regressing to the drifted constant). Only meaningful when the real
  # count is not itself 1.
  if [[ "${_actual}" -ne 1 ]]; then
    run grep -F '**1 test**' "${_test_md}"
    assert_failure
  fi
}

@test "new repo: TEST.md per-file heading is level-3 (### path (N)) so sync-doc-counts can match (S4 item 6)" {
  bash .base/dist/script/base/init.sh
  local _test_md="${REPO_DIR}/doc/test/TEST.md"
  # sync-doc-counts.sh's _sync_headings only rewrites `### <relpath> (N)`
  # headings; the pre-S4 scaffold used a `## test/bats/... (1)` level-2
  # heading the regex could never match. Assert a level-3 heading that
  # points at the generated spec with its real @test count.
  local _spec="test/bats/smoke/shared/${REPO_NAME}_env.bats"
  local _n
  _n="$(grep -cE '^@test' "${REPO_DIR}/${_spec}" 2>/dev/null || true)"
  run grep -E "^### ${_spec} \\(${_n}\\)$" "${_test_md}"
  assert_success
}

@test "new repo: doc/changelog/CHANGELOG.md exists" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/doc/changelog/CHANGELOG.md" ]
}

@test "new repo: build.sh symlink lives under script/, not root (#330)" {
  bash .base/dist/script/base/init.sh
  assert [ -L "${REPO_DIR}/script/build.sh" ]
  run readlink "${REPO_DIR}/script/build.sh"
  assert_output "../.base/dist/script/docker/wrapper/build.sh"
  # Root must NOT have build.sh after
  assert [ ! -e "${REPO_DIR}/build.sh" ]
}

@test "new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)" {
  bash .base/dist/script/base/init.sh
  # 7 wrappers under script/, each pointing to ../.base/dist/script/docker/wrapper/<name>.sh
  for f in run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ -L "${REPO_DIR}/script/${f}" ]
    run readlink "${REPO_DIR}/script/${f}"
    assert_output "../.base/dist/script/docker/wrapper/${f}"
    # And NOT at root.
    assert [ ! -e "${REPO_DIR}/${f}" ]
  done
  # the root user entry is the justfile (Makefile retired).
  assert [ -L "${REPO_DIR}/justfile" ]
  run readlink "${REPO_DIR}/justfile"
  assert_output "script/justfile"
  assert [ ! -e "${REPO_DIR}/Makefile" ]
}

@test "new repo: config/ is an empty placeholder (template#254 layered override)" {
  bash .base/dist/script/base/init.sh
  # Must NOT be a symlink — edits should stay in the user's own
  # repo, not leak into the subtree where subtree pulls would fight
  # them. Must be a real directory.
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  # init.sh seeded a FULL copy of .base/dist/config/ here.
  # (template v0.22.0+) init.sh creates an empty
  # placeholder with just a .gitkeep -- the Dockerfile's layered
  # COPY chain reads .base/dist/config/ as defaults and <repo>/config/
  # as overrides, so an empty <repo>/config/ means "no overrides,
  # use all template defaults". Downstream adds files only when
  # they want to override a specific template file.
  assert [ -f "${REPO_DIR}/config/.gitkeep" ]
  # Confirm no full-tree seed: shell/, pip/, etc. should NOT be
  # auto-populated. The tool-managed setup.conf no longer lives under
  # config/ at all -- it bootstraps to the repo-root .setup.conf
  # dotfile -- so config/ holds ONLY the .gitkeep placeholder.
  run find "${REPO_DIR}/config" -mindepth 1 -maxdepth 1 -not -name '.gitkeep'
  assert_output ""
  # The first-time bootstrap seeds the per-repo override at the repo
  # root as .setup.conf, outside the hand-editable config/ surface.
  assert [ -f "${REPO_DIR}/.setup.conf" ]
}

@test "new repo: init.sh preserves pre-existing config/ directory (no clobber)" {
  # Simulate a repo with a real config/ directory (user's edits).
  # init.sh must not overwrite it.
  mkdir -p "${REPO_DIR}/config/custom"
  echo "user-override" > "${REPO_DIR}/config/custom/marker"
  bash .base/dist/script/base/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -f "${REPO_DIR}/config/custom/marker" ]
}

@test "new repo: script/local/justfile.local seeded (repo-local command-group registry, #632)" {
  bash .base/dist/script/base/init.sh
  # Repo-owned (a real file, not a symlink into the subtree) so the repo
  # commits its own group registrations and a subtree upgrade never clobbers
  # them. The entry imports it with `import?`.
  assert [ -f "${REPO_DIR}/script/local/justfile.local" ]
  assert [ ! -L "${REPO_DIR}/script/local/justfile.local" ]
  run grep -F "import? 'script/local/justfile.local'" "${REPO_DIR}/.base/dist/script/justfile"
  assert_success
}

@test "new repo: init.sh preserves a pre-existing script/local/justfile.local (no clobber, #632)" {
  mkdir -p "${REPO_DIR}/script/local"
  printf "mod? deploy 'deploy/justfile.deploy'\n" > "${REPO_DIR}/script/local/justfile.local"
  bash .base/dist/script/base/init.sh
  run cat "${REPO_DIR}/script/local/justfile.local"
  assert_output --partial "mod? deploy 'deploy/justfile.deploy'"
}

@test "new repo: script/local/ seeds a bash companion template alongside justfile.local (S4 item 7)" {
  bash .base/dist/script/base/init.sh
  # The skel/ pair pattern ships both a justfile + a .sh; the seeded
  # script/local/ mirrors that so a fresh repo has a ready-to-edit bash
  # template next to the justfile.local registry. REPO-OWNED (a real file,
  # not a symlink into the subtree) + executable so it can back a recipe.
  local _sh="${REPO_DIR}/script/local/local.sh"
  assert [ -f "${_sh}" ]
  assert [ ! -L "${_sh}" ]
  assert [ -x "${_sh}" ]
  # Valid bash starter: shebang + strict mode.
  run head -n 1 "${_sh}"
  assert_output --partial "bash"
  run grep -F 'set -euo pipefail' "${_sh}"
  assert_success
}

@test "new repo: init.sh preserves a pre-existing script/local/local.sh (no clobber, S4 item 7)" {
  mkdir -p "${REPO_DIR}/script/local"
  printf '#!/usr/bin/env bash\n# user edits\necho custom\n' \
    > "${REPO_DIR}/script/local/local.sh"
  bash .base/dist/script/base/init.sh
  run cat "${REPO_DIR}/script/local/local.sh"
  assert_output --partial "user edits"
}

@test "new repo: init.sh seeds local.sh even when justfile.local already exists (independent guards, S4 item 7)" {
  # An existing repo upgrading from a pre-S4 base already carries
  # justfile.local but no local.sh; the seed must not short-circuit on the
  # justfile.local guard and skip the companion.
  mkdir -p "${REPO_DIR}/script/local"
  printf "mod? deploy 'deploy/justfile.deploy'\n" > "${REPO_DIR}/script/local/justfile.local"
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/script/local/local.sh" ]
  # The pre-existing registry is still untouched.
  run cat "${REPO_DIR}/script/local/justfile.local"
  assert_output --partial "mod? deploy 'deploy/justfile.deploy'"
}

@test "new repo: script/template/ symlinks wired for the template namespace (#633)" {
  bash .base/dist/script/base/init.sh
  # base-owned (symlinks into the subtree, flow on upgrade): justfile.template
  # + new.sh + skel/, so `just template new <name>` is available out of the box.
  assert [ -L "${REPO_DIR}/script/template/justfile.template" ]
  assert [ -L "${REPO_DIR}/script/template/new.sh" ]
  assert [ -L "${REPO_DIR}/script/template/skel" ]
  run readlink "${REPO_DIR}/script/template/justfile.template"
  assert_output "../../.base/dist/script/template/justfile.template"
  run grep -F "mod? template 'script/template/justfile.template'" "${REPO_DIR}/.base/dist/script/justfile"
  assert_success
}

@test "new repo: script/base/ symlink wired for the base namespace (#652, #653)" {
  bash .base/dist/script/base/init.sh
  # base-owned (symlinks into the subtree, flow on upgrade): justfile.base +
  # completions.sh, so `just base upgrade` / `update` / `init` / `completions`
  # are available out of the box.
  assert [ -L "${REPO_DIR}/script/base/justfile.base" ]
  run readlink "${REPO_DIR}/script/base/justfile.base"
  assert_output "../../.base/dist/script/base/justfile.base"
  assert [ -L "${REPO_DIR}/script/base/completions.sh" ]
  run readlink "${REPO_DIR}/script/base/completions.sh"
  assert_output "../../.base/dist/script/base/completions.sh"
  run grep -F "mod? base 'script/base/justfile.base'" "${REPO_DIR}/.base/dist/script/justfile"
  assert_success
}

@test "new repo: init.sh drops stale config symlink before creating placeholder" {
  # An older init.sh created config → .base/dist/config as a symlink.
  # Re-running the init.sh on such a repo must replace the
  # symlink with the empty placeholder (mkdir through a symlink
  # would otherwise pollute the subtree target).
  ln -s .base/dist/config "${REPO_DIR}/config"
  bash .base/dist/script/base/init.sh
  assert [ ! -L "${REPO_DIR}/config" ]
  assert [ -d "${REPO_DIR}/config" ]
  assert [ -f "${REPO_DIR}/config/.gitkeep" ]
}

@test "Dockerfile.example references CONFIG_SRC=\"config\" (not .base/dist/config)" {
  # Sanity: the per-repo copy only pays off if Dockerfile points at it.
  run grep -F 'ARG CONFIG_SRC="config"' /source/dist/dockerfile/Dockerfile
  assert_success
  run grep -F 'ARG CONFIG_SRC=".base/dist/config"' /source/dist/dockerfile/Dockerfile
  assert_failure
}

@test "Dockerfile.example has layered config COPY chain (template#254): .base/dist/config first, then config" {
  # Layered file-level override: layer 1 brings .base/dist/config/
  # defaults, layer 2 overlays <repo>/config/. Files in layer 2
  # override same-path files from layer 1; files only in layer 1
  # remain. Order matters -- if layer 2 came first, layer 1 would
  # overwrite the overrides. Test asserts both lines exist AND the
  # order is correct.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Both COPY lines exist with --chown / --chmod metadata.
  run grep -E '^COPY --chown=.* .base/dist/config "\$\{CONFIG_DIR\}"$' "${_df}"
  assert_success
  run grep -E '^COPY --chown=.* "\$\{CONFIG_SRC\}" "\$\{CONFIG_DIR\}"$' "${_df}"
  assert_success
  # Order: .base/dist/config COPY line number must be LESS than
  # config-src COPY line number.
  local _line1 _line2
  _line1=$(grep -nE '^COPY --chown=.* .base/dist/config "\$\{CONFIG_DIR\}"$' "${_df}" | head -1 | cut -d: -f1)
  _line2=$(grep -nE '^COPY --chown=.* "\$\{CONFIG_SRC\}" "\$\{CONFIG_DIR\}"$' "${_df}" | head -1 | cut -d: -f1)
  [[ "${_line1}" -lt "${_line2}" ]] || {
    echo "expected .base/dist/config COPY (line ${_line1}) BEFORE config-src COPY (line ${_line2})"
    return 1
  }
}

@test "Dockerfile.example declares ENV HOME before WORKDIR \${HOME}/work (#334)" {
  local _df="/source/dist/dockerfile/Dockerfile"
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
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The shell-setup RUN block must mkdir ~/.bashrc.d AND copy
  # *.sh from CONFIG_DIR/shell/bashrc.d/ into it. The cp -n form
  # tolerates missing source files (.base/dist/config/shell/bashrc.d/
  # is empty by default; only an explicit .gitkeep ships).
  run grep -F 'mkdir -p "${HOME}/.bashrc.d"' "${_df}"
  assert_success
  run grep -F 'cp -n "${CONFIG_DIR}"/shell/bashrc.d/*.sh "${HOME}/.bashrc.d/"' "${_df}"
  assert_success
}

@test "new repo: Dockerfile contains logging.sh in-image COPY (#368)" {
  # End-to-end check that a fresh init.sh-generated repo includes the
  # Dockerfile COPY for the helper. The helper must land at the
  # stable in-image path so downstream entrypoints can source it
  # with a clean `. /usr/local/lib/base/logging.sh`
  # one-liner -- no $USER deref, no WS_PATH dependence, works at
  # build-time smoke AND runtime on multi-repo workspaces. Pin the
  # COPY here so init.sh seeding regressions are caught.
  bash .base/dist/script/base/init.sh
  local _df="${REPO_DIR}/Dockerfile"
  assert [ -f "${_df}" ]
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}"
  assert_success
}

@test "new repo: .base/.version exists (no legacy VERSION / .template_version)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.base/.version" ]
  assert [ ! -f "${REPO_DIR}/.base/VERSION" ]
  assert [ ! -f "${REPO_DIR}/.template_version" ]
  run cat "${REPO_DIR}/.base/.version"
  # Accept semver with optional pre-release suffix (e.g. v0.10.0-rc1).
  assert_output --regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

@test "new repo: re-running init.sh on the result is idempotent" {
  bash .base/dist/script/base/init.sh
  # Second run should hit _init_existing_repo (Dockerfile exists)
  run bash .base/dist/script/base/init.sh
  assert_success
}

@test "new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)" {
  bash .base/dist/script/base/init.sh
  assert [ -L "${REPO_DIR}/script/setup_tui.sh" ]
  run readlink "${REPO_DIR}/script/setup_tui.sh"
  assert_output "../.base/dist/script/docker/wrapper/setup_tui.sh"
  # Neither old root-level setup_tui.sh nor pre-rename tui.sh.
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
  assert [ ! -e "${REPO_DIR}/setup_tui.sh" ]
}

@test "new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)" {
  bash .base/dist/script/base/init.sh
  # Simulate a very old upgrade path: legacy tui.sh symlink at root.
  ln -sf ".base/dist/script/docker/wrapper/setup_tui.sh" "${REPO_DIR}/tui.sh"
  run bash .base/dist/script/base/init.sh
  assert_success
  assert [ ! -e "${REPO_DIR}/tui.sh" ]
  assert [ -L "${REPO_DIR}/script/setup_tui.sh" ]
}

@test "new repo: init.sh removes stale root *.sh symlinks (#330 migration)" {
  bash .base/dist/script/base/init.sh
  # Simulate a layout by planting the seven root-level symlinks
  # an older init.sh would have produced. Re-running the
  # init.sh must remove all of them and ensure script/ versions exist.
  for f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    ln -sf ".base/dist/script/docker/wrapper/${f}" "${REPO_DIR}/${f}"
  done
  run bash .base/dist/script/base/init.sh
  assert_success
  for f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ ! -e "${REPO_DIR}/${f}" ]
    assert [ -L "${REPO_DIR}/script/${f}" ]
  done
}

@test "new repo: build.sh -h works against the generated symlink" {
  bash .base/dist/script/base/init.sh
  run bash "${REPO_DIR}/script/build.sh" -h
  assert_success
  assert_output --partial "Usage"
}

@test "new repo: run.sh -h works against the generated symlink" {
  bash .base/dist/script/base/init.sh
  run bash "${REPO_DIR}/script/run.sh" -h
  assert_success
}

@test "new repo: exec.sh -h works against the generated symlink" {
  bash .base/dist/script/base/init.sh
  run bash "${REPO_DIR}/script/exec.sh" -h
  assert_success
}

@test "new repo: stop.sh -h works against the generated symlink" {
  bash .base/dist/script/base/init.sh
  run bash "${REPO_DIR}/script/stop.sh" -h
  assert_success
}

@test "new repo: setup.sh symlink under script/ → ../.base/dist/script/docker/wrapper/setup.sh" {
  bash .base/dist/script/base/init.sh
  assert [ -L "${REPO_DIR}/script/setup.sh" ]
  run readlink "${REPO_DIR}/script/setup.sh"
  assert_output "../.base/dist/script/docker/wrapper/setup.sh"
}

@test "new repo: setup.sh -h works against the generated symlink" {
  bash .base/dist/script/base/init.sh
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
  bash .base/dist/script/base/init.sh
  rm -f "${REPO_DIR}/.setup.conf"
  bash .base/dist/script/base/init.sh --gen-conf
  assert [ -f "${REPO_DIR}/.setup.conf" ]
  # Sanity: copied file contains the full section schema
  run grep -E '^\[(image|build|deploy|gui|network|volumes)\]' "${REPO_DIR}/.setup.conf"
  assert_success
}

@test "init.sh --gen-conf refuses to overwrite existing setup.conf" {
  # init.sh auto-creates <repo>/.setup.conf via setup.sh workspace writeback,
  # so --gen-conf on a freshly-initialized repo already hits the "exists" guard.
  bash .base/dist/script/base/init.sh
  run bash .base/dist/script/base/init.sh --gen-conf
  assert_failure
  assert_output --partial "already exists"
}

# ════════════════════════════════════════════════════════════════════
# Derived artifacts: compose.yaml + .env are setup.sh-generated, gitignored
# ════════════════════════════════════════════════════════════════════

@test "new repo: .gitignore contains compose.yaml (derived artifact)" {
  bash .base/dist/script/base/init.sh
  run grep -x 'compose.yaml' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: .gitignore contains .env (derived artifact)" {
  bash .base/dist/script/base/init.sh
  run grep -x '.env' "${REPO_DIR}/.gitignore"
  assert_success
}

@test "new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)" {
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run head -n 1 "${REPO_DIR}/compose.yaml"
  assert_output --partial "AUTO-GENERATED"
}

@test "new repo: compose.yaml omits devices block by default (#466 opt-in)" {
  # F2: a fresh repo no longer binds /dev:/dev (or any device) by
  # default -- device access is opt-in. Repos that need it uncomment the
  # template example or add via the TUI / `setup.sh add devices.device`.
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/compose.yaml" ]
  run grep -E '^    devices:$' "${REPO_DIR}/compose.yaml"
  assert_failure
  run grep -F -- '- /dev:/dev' "${REPO_DIR}/compose.yaml"
  assert_failure
}

@test "new repo: setup.conf mount_1 is NOT empty after first init (workspace detected + written)" {
  # Regression: fresh repo previously produced an empty [volumes] mount_1
  # which made the TUI volumes menu appear blank on first open. First-init
  # must write the detected workspace path into mount_1.
  bash .base/dist/script/base/init.sh
  run grep -E '^mount_1 = .+$' "${REPO_DIR}/.setup.conf"
  assert_success
  # Must NOT be exactly `mount_1 =` (empty value)
  run grep -x 'mount_1 =' "${REPO_DIR}/.setup.conf"
  assert_failure
}

@test "new repo: per-repo setup.conf auto-created on first init (workspace writeback)" {
  # setup.sh on first run (no <repo>/.setup.conf) copies template + fills
  # [volumes] mount_1 with the detected workspace. Expected behaviour since
  # setup.conf became the source of truth for WS_PATH.
  bash .base/dist/script/base/init.sh
  assert [ -f "${REPO_DIR}/.setup.conf" ]
  run grep '^mount_1' "${REPO_DIR}/.setup.conf"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# just runner host preflight
# ════════════════════════════════════════════════════════════════════

@test "new repo: init warns + exits 0 + still creates symlinks when just is absent (#607)" {
  # Shadow PATH so `command -v just` misses but coreutils (needed by
  # setup.sh) stay reachable. A stub bin dir is prepended but holds no
  # `just`, and the kept PATH dirs (usr/bin:/bin) carry no `just` on the
  # CI image, so the preflight reliably fires.
  local _stub="${TMP_ROOT}/nojust_bin"
  mkdir -p "${_stub}"
  # Symlink the externals init.sh + setup.sh need into a clean dir that
  # holds no `just` (the CI image ships just in /usr/bin alongside
  # coreutils, so trimming to standard dirs cannot hide it).
  local _cmd _src
  for _cmd in bash sh env date cat mkdir rm cp mv ln chmod grep sed awk tr \
              head tail cut sort uniq wc find dirname basename readlink \
              git diff touch test printf realpath; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" || continue
    ln -sf "${_src}" "${_stub}/${_cmd}"
  done
  run env LOG_FORMAT=text PATH="${_stub}" bash .base/dist/script/base/init.sh
  assert_success
  assert_output --partial "WARN"
  assert_output --partial "just runner not found on PATH"
  # Non-fatal: the user-facing justfile entry symlink is still laid down,
  # so a later `just` install works immediately.
  assert [ -L "${REPO_DIR}/justfile" ]
  assert [ -L "${REPO_DIR}/script/build.sh" ]
}

@test "new repo: init is silent about just when the runner is present (#607)" {
  # Provide a `just` stub on PATH; the preflight must not warn.
  local _stub="${TMP_ROOT}/withjust_bin"
  mkdir -p "${_stub}"
  printf '#!/bin/bash\nexit 0\n' > "${_stub}/just"
  chmod +x "${_stub}/just"
  run env LOG_FORMAT=text PATH="${_stub}:${PATH}" bash .base/dist/script/base/init.sh
  assert_success
  refute_output --partial "init_just_missing"
  refute_output --partial "just runner not found on PATH"
}

# ════════════════════════════════════════════════════════════════════
# init.sh self-run guard (ADR-00000011 sec.8)
# ════════════════════════════════════════════════════════════════════

@test "init.sh refuses to run when the subtree root carries .git (base template source)" {
  # The base template SOURCE is itself a git checkout/worktree, so its
  # subtree root carries `.git`; a vendored `.base/` subtree never does
  # (the consumer's `.git` lives at the repo root, outside the subtree).
  # Give the subtree root a `.git` to mimic the source, and assert init
  # refuses instead of scaffolding -- otherwise it would pollute the
  # parent dir.
  rm -rf "${REPO_DIR}/.base/.git"
  mkdir -p "${REPO_DIR}/.base/.git"
  run env LOG_FORMAT=text bash .base/dist/script/base/init.sh
  assert_failure
  assert_output --partial "template source"
  assert [ ! -f "${REPO_DIR}/Dockerfile" ]
}
