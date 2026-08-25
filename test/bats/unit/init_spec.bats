#!/usr/bin/env bats
#
# Unit tests for init.sh helpers. Complements the Level-1 integration test
# in test/integration/init_new_repo_spec.bats — which already covers
# end-to-end init.sh runs — by exercising individual helpers against
# edge cases that are hard to trigger from a real `bash .base/dist/script/base/init.sh`
# invocation (e.g. network-down version detection, main.yaml @ref
# fallback, _create_version_file with no argument).

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir

  # Mimic the integration-test layout so `init.sh` resolves TEMPLATE_DIR /
  # REPO_ROOT to a writable temp tree instead of /source. Symlinking
  # init.sh back to the real source keeps all edits in one place.
  # init.sh lives deep at dist/script/base/init.sh and self-locates
  # the subtree root by walking up to the dir carrying `.version` +
  # `dist/`, so seed both markers at .base/ and symlink at the deep
  # path; the walk-up still resolves TEMPLATE_DIR=.base, TEMPLATE_REL=.base.
  TMP_REPO="$(mktemp -d)"
  mkdir -p "${TMP_REPO}/.base/dockerfile" \
           "${TMP_REPO}/.base/dist/config" \
           "${TMP_REPO}/.base/dist/script/base" \
           "${TMP_REPO}/.base/dist/script/docker/lib" \
           "${TMP_REPO}/.base/dist/script/docker/runtime"
  echo "v0.0.0-test" > "${TMP_REPO}/.base/.version"
  ln -s /source/dist/script/base/init.sh \
        "${TMP_REPO}/.base/dist/script/base/init.sh"
  # init.sh sources its sibling upstream.sh on load (the one definition of
  # the upstream slug / clone URL, shared with upgrade.sh and the version
  # monitor), so the seeded subtree needs it next to init.sh.
  ln -s /source/dist/script/base/upstream.sh \
        "${TMP_REPO}/.base/dist/script/base/upstream.sh"
  # init.sh sources lib/gitignore.sh on load. Symlink the real
  # lib so its functions are available to tests that hit _create_new_repo.
  ln -s /source/dist/script/docker/lib/gitignore.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/gitignore.sh"
  # init.sh also sources lib/template_guard.sh on load (the self-run guard,
  # ADR-00000011 sec.8). Symlink it so _source_init resolves it. The seeded
  # subtree root (.base/, no .git) makes the guard a no-op for these tests.
  ln -s /source/dist/script/docker/lib/template_guard.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/template_guard.sh"
  # init.sh sources _lib.sh on load (routes _log / _error through
  # _log_info / _log_err). _lib.sh sources i18n.sh + lib/*.sh sub-libs
  # so symlink all three surfaces.
  ln -s /source/dist/script/docker/lib/_lib.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/_lib.sh"
  ln -s /source/dist/script/docker/lib/i18n.sh \
        "${TMP_REPO}/.base/dist/script/docker/lib/i18n.sh"
  # schema.sh joined the _lib.sh chain in; it sources _tui_conf.sh
  # for the validator bodies, so symlink both alongside the rest.
  for _sl in log transcript env conf setup_conf conf_logging _tui_conf schema stage resolve compose deploy compose_emit env_emit config_summary setup_cmd setup_detect drift hook; do
    ln -s "/source/dist/script/docker/lib/${_sl}.sh" \
          "${TMP_REPO}/.base/dist/script/docker/lib/${_sl}.sh"
  done
  unset _sl
  ln -s /source/dist/script/docker/lib/log-events.txt \
        "${TMP_REPO}/.base/dist/script/docker/lib/log-events.txt"
  cp /source/dist/script/docker/runtime/entrypoint.sh \
     "${TMP_REPO}/.base/dist/script/docker/runtime/entrypoint.sh"

  # Minimal Dockerfile.example stub for _create_new_repo's `cp` step.
  mkdir -p "${TMP_REPO}/.base/dist/dockerfile"
  cat > "${TMP_REPO}/.base/dist/dockerfile/Dockerfile" <<'EOF'
FROM alpine
EOF

  # Stub scripts referenced by _create_symlinks — empty files are fine
  # because symlinks only need a valid target path, not a valid payload.
  mkdir -p "${TMP_REPO}/.base/dist/script/docker/wrapper"
  for _f in build.sh run.sh exec.sh stop.sh setup.sh setup_tui.sh; do
    : > "${TMP_REPO}/.base/dist/script/docker/wrapper/${_f}"
  done
  : > "${TMP_REPO}/.base/dist/script/justfile"
  : > "${TMP_REPO}/.base/dist/script/docker/justfile.docker"
  : > "${TMP_REPO}/.base/dist/.hadolint.yaml"

  cd "${TMP_REPO}"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TMP_REPO}"
}

# Source init.sh within a `bash -c` so the test controls when functions
# are loaded and can mutate PATH / cwd before invocation. `bash -c ... "$0"`
# pattern via `run` is awkward — we wrap in a helper.
_source_init() {
  # shellcheck disable=SC1091
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
}

# ════════════════════════════════════════════════════════════════════
# _detect_template_version
# ════════════════════════════════════════════════════════════════════

@test "_detect_template_version: parses newest vX.Y.Z tag from git ls-remote" {
  # Mock emits refs in the order the real `--sort=-v:refname` would produce
  # (newest-first). _detect_template_version trusts the sort and just
  # takes `head -1`.
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
def456  refs/tags/v0.7.2
ghi789  refs/tags/v0.7.1
abc123  refs/tags/v0.7.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  # The walk-up marker .version (seeded in setup) doubles as
  # _detect_template_version's cache; remove it now that TEMPLATE_DIR is
  # resolved so this test exercises the git-ls-remote fallback path.
  rm -f "${TMP_REPO}/.base/.version"
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.2"
}

@test "_detect_template_version: returns empty when git ls-remote fails" {
  mock_cmd "git" 'exit 128'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" ""
}

@test "_detect_template_version: returns empty when no v*.*.* tags exist" {
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
abc123  refs/heads/main
def456  refs/tags/latest
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" ""
}

@test "_detect_template_version: ignores non-semver tags (e.g. rc suffixes)" {
  # --sort=-v:refname would rank v0.8.0-rc2 > v0.7.2-rc1 > v0.7.0, but
  # the regex strips the rc variants, leaving v0.7.0 as the only valid
  # vX.Y.Z entry.
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
ghi789  refs/tags/v0.8.0-rc2
def456  refs/tags/v0.7.2-rc1
abc123  refs/tags/v0.7.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.0"
}

# ════════════════════════════════════════════════════════════════════
# _detect_template_version: reads .version file
# ════════════════════════════════════════════════════════════════════

@test "_detect_template_version: an early-closing reader cannot empty the tag scan (#905)" {
  # Same pipeline as upgrade.sh's _get_latest_version, same `|| true`, and
  # the same surviving failure mode: `head -1` leaves after one line, the
  # `grep -oP` still writing dies of SIGPIPE, and the suppressed status
  # leaves an EMPTY version. init.sh then stamps a repo with no template
  # version at all rather than the tag it just resolved.
  #
  # Shims go on AFTER _source_init so they cannot perturb init.sh's
  # source-time self-location; only the function under test sees them.
  _source_init
  rm -f "${TMP_REPO}/.base/.version"  # exercise the no-cache fallback path
  shim_early_closing_reader "${MOCK_DIR}" head
  shim_late_writer "${MOCK_DIR}" git \
    "def456	refs/tags/v0.7.2" \
    "abc123	refs/tags/v0.7.0"

  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v0.7.2"
}

@test "_detect_template_version: reads .version file when present (no network)" {
  echo "v1.5.0" > "${TMP_REPO}/.base/.version"
  # Mock git to fail (simulate offline)
  mock_cmd "git" 'exit 128'
  _source_init
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v1.5.0"
}

@test "_detect_template_version: .version file takes priority over git ls-remote" {
  echo "v1.5.0" > "${TMP_REPO}/.base/.version"
  mock_cmd "git" '
    if [[ "$1" == "ls-remote" ]]; then
      cat <<REMOTE
abc123  refs/tags/v2.0.0
REMOTE
      exit 0
    fi
    exit 0'
  _source_init
  local result
  result="$(_detect_template_version)"
  assert_equal "${result}" "v1.5.0"
}

# ════════════════════════════════════════════════════════════════════
# _create_new_repo: ref threading into main.yaml
# ════════════════════════════════════════════════════════════════════

@test "_create_new_repo: main.yaml uses given ref in workflow @ref" {
  _source_init
  _create_new_repo "v9.9.9"
  assert [ -f "${TMP_REPO}/.github/workflows/main.yaml" ]
  run grep -E 'build-worker\.yaml@v9\.9\.9' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
  run grep -E 'release-worker\.yaml@v9\.9\.9' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

@test "_create_new_repo: main.yaml falls back to @main when ref arg omitted" {
  _source_init
  _create_new_repo
  run grep -E 'build-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
  run grep -E 'release-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

@test "_create_new_repo: main.yaml falls back to @main when ref arg is empty" {
  _source_init
  _create_new_repo ""
  run grep -E 'build-worker\.yaml@main' \
    "${TMP_REPO}/.github/workflows/main.yaml"
  assert_success
}

@test "_create_new_repo: does NOT generate .env.example (image name via setup.conf)" {
  _source_init
  _create_new_repo "main"
  [[ ! -f "${TMP_REPO}/.env.example" ]]
}

# ════════════════════════════════════════════════════════════════════
# _create_symlinks
# ════════════════════════════════════════════════════════════════════

@test "_create_symlinks: places 7 wrapper symlinks under script/ (#330)" {
  _source_init
  _create_symlinks
  # Seven wrappers under script/ with ../.base/dist/script/docker/wrapper/<name>.sh targets.
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ -L "${TMP_REPO}/script/${_f}" ]
    run readlink "${TMP_REPO}/script/${_f}"
    assert_output "../.base/dist/script/docker/wrapper/${_f}"
    # And must NOT exist at root.
    assert [ ! -e "${TMP_REPO}/${_f}" ]
  done
  # the root user entry is the justfile, not a Makefile.
  assert [ -L "${TMP_REPO}/justfile" ]
  assert [ ! -e "${TMP_REPO}/Makefile" ]
}

@test "_create_symlinks: places justfile at root with the direct .base/ target (#545)" {
  _source_init
  _create_symlinks
  # ADR-00000005: just is the new user-facing entry; the justfile symlink
  # sits at root (like Makefile) so `just <verb>` runs from the repo root.
  assert [ -L "${TMP_REPO}/justfile" ]
  run readlink "${TMP_REPO}/justfile"
  assert_output "script/justfile"
}

@test "_create_symlinks: does NOT symlink Makefile and cleans a stale root Makefile symlink (#546)" {
  # ADR-00000005 phase 2: the Makefile is retired in favour of `just`.
  # _create_symlinks must no longer create a root Makefile, and an
  # upgrading repo's pre-existing root Makefile symlink must be dropped
  # (init.sh resync) so it does not dangle once .base/ no longer ships one.
  _source_init
  ln -sf ".base/script/docker/Makefile" "${TMP_REPO}/Makefile"   # legacy symlink from an older base
  _create_symlinks
  assert [ ! -e "${TMP_REPO}/Makefile" ]
  assert [ ! -L "${TMP_REPO}/Makefile" ]
}

@test "_create_symlinks: replaces a stale file at the new symlink path under script/ (#330)" {
  # Pretend an earlier run left a regular file where the symlink should go.
  # the symlinks live under script/, so the stale-replacement
  # logic in _symlink runs against script/build.sh, not root build.sh.
  mkdir -p "${TMP_REPO}/script"
  echo "stale" > "${TMP_REPO}/script/build.sh"
  _source_init
  _create_symlinks
  assert [ -L "${TMP_REPO}/script/build.sh" ]
}

@test "_create_symlinks: removes stale root *.sh symlinks left by pre-#330 init (#330 migration loop)" {
  # Plant the seven root-level symlinks an older init.sh would have made;
  # the loop must drop them all so the user-facing entry is the
  # `script/` subfolder + root `Makefile`.
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    ln -sf ".base/script/docker/${_f}" "${TMP_REPO}/${_f}"
  done
  _source_init
  _create_symlinks
  for _f in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh; do
    assert [ ! -e "${TMP_REPO}/${_f}" ]
    assert [ -L "${TMP_REPO}/script/${_f}" ]
  done
}

@test "_create_symlinks: keeps custom .hadolint.yaml when it differs" {
  echo "# repo-specific rules" > "${TMP_REPO}/.hadolint.yaml"
  # Template's stub is empty — force a difference
  _source_init
  run _create_symlinks
  assert_success
  assert_output --partial "Keeping custom .hadolint.yaml"
  # Custom file should still be a regular file, not a symlink
  assert [ ! -L "${TMP_REPO}/.hadolint.yaml" ]
}

# ════════════════════════════════════════════════════════════════════
# _gen_setup_conf --force (reset path,)
# ════════════════════════════════════════════════════════════════════

@test "_gen_setup_conf default refuses to overwrite existing setup.conf" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "existing user config" > "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "false"
  assert_failure
  assert_output --partial "already exists"
}

@test "_gen_setup_conf --force overwrites and backs up existing setup.conf" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "old user conf" > "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  # new setup.conf must come from template
  run cat "${TMP_REPO}/.setup.conf"
  assert_output --partial "rules = @basename"
  # backup must contain the pre-overwrite user content
  assert [ -f "${TMP_REPO}/.setup.conf.bak" ]
  run cat "${TMP_REPO}/.setup.conf.bak"
  assert_output "old user conf"
}

@test "_gen_setup_conf --force also backs up .env to .env.bak" {
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  mkdir -p "${TMP_REPO}"
  echo "user conf" > "${TMP_REPO}/.setup.conf"
  echo "USER_NAME=existing" > "${TMP_REPO}/.env"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  assert [ -f "${TMP_REPO}/.env.bak" ]
  run cat "${TMP_REPO}/.env.bak"
  assert_output "USER_NAME=existing"
}

@test "_gen_setup_conf errors when the template setup.conf is absent (#692)" {
  # A broken/partial subtree has no template setup.conf -- the exact
  # scenario --gen-conf is meant to diagnose. _gen_setup_conf must fail
  # loudly rather than copy a non-existent source.
  rm -f "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf"
  _source_init
  run _gen_setup_conf "false"
  assert_failure
  assert_output --partial "Template setup.conf not found"
}

@test "_gen_setup_conf --force on clean repo does not create spurious .bak" {
  # No pre-existing setup.conf → first-time provision, nothing to back up.
  mkdir -p "${TMP_REPO}/.base/dist"
  printf "[image]\nrules = @basename\n" > "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf" "${TMP_REPO}/.env"
  _source_init
  run _gen_setup_conf "true"
  assert_success
  assert [ ! -f "${TMP_REPO}/.setup.conf.bak" ]
  assert [ ! -f "${TMP_REPO}/.env.bak" ]
}

# ════════════════════════════════════════════════════════════════════
# TEMPLATE_REL subtree-prefix auto-detection (prep)
# ════════════════════════════════════════════════════════════════════
#
# init.sh derives TEMPLATE_REL from `basename ${TEMPLATE_DIR}` (which is
# itself `dirname BASH_SOURCE[0]`). The conventional prefix is `.base/`
# but a downstream rename (e.g. `.base/`, planned for fanout) is
# picked up without code changes: the symlink targets and gen-conf paths
# follow whatever directory init.sh lives in.

@test "TEMPLATE_REL: auto-detects to '.base' when init.sh lives in .base/" {
  _source_init
  assert_equal "${TEMPLATE_REL}" ".base"
}

@test "TEMPLATE_REL: re-sourcing init.sh from .base/ keeps detection stable" {
  # the subtree always lives at `.base/`; re-sourcing init.sh
  # from that location must consistently derive TEMPLATE_REL = ".base"
  # so downstream symlinks point through the new prefix.
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
  assert_equal "${TEMPLATE_REL}" ".base"
}

@test "_create_symlinks: targets follow TEMPLATE_REL through .base/ (#330 script/ subfolder)" {
  # Companion to the auto-detect test above: when TEMPLATE_REL is `.base`,
  # `_create_symlinks` must wire script/build.sh -> ../.base/dist/script/docker/wrapper/build.sh
  # (sub-folder link target is relative to the link's directory), and
  # justfile / .hadolint.yaml at root keep the direct .base/ target.
  source "${TMP_REPO}/.base/dist/script/base/init.sh"
  _create_symlinks
  run readlink "${TMP_REPO}/script/build.sh"
  assert_output "../.base/dist/script/docker/wrapper/build.sh"
  run readlink "${TMP_REPO}/justfile"
  assert_output "script/justfile"
  run readlink "${TMP_REPO}/.hadolint.yaml"
  assert_output ".base/dist/.hadolint.yaml"
}

# ════════════════════════════════════════════════════════════════════
# _create_new_repo .gitignore covers the *.bak siblings
# ════════════════════════════════════════════════════════════════════

@test "_create_new_repo: .gitignore includes .setup.conf.bak and .env.bak" {
  _source_init
  _create_new_repo "main"
  run grep -Fxq .setup.conf.bak "${TMP_REPO}/.gitignore"
  assert_success
  run grep -Fxq .env.bak "${TMP_REPO}/.gitignore"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _create_hook_stubs — 14 stubs (7 wrappers x 2 phases)
# ════════════════════════════════════════════════════════════════════

@test "_create_hook_stubs: creates script/hooks/{pre,post}/ with 14 stubs (#440)" {
  _source_init
  _create_hook_stubs
  local _kind _wrapper _file
  for _kind in pre post; do
    for _wrapper in build run exec stop prune setup setup_tui; do
      _file="${TMP_REPO}/script/hooks/${_kind}/${_wrapper}.sh"
      [[ -f "${_file}" ]] || { echo "missing ${_file}"; return 1; }
      [[ -x "${_file}" ]] || { echo "not executable: ${_file}"; return 1; }
    done
  done
}

@test "_create_hook_stubs: each stub starts with shebang and ends with exit 0 (#440)" {
  _source_init
  _create_hook_stubs
  local _file
  for _file in "${TMP_REPO}/script/hooks/pre/run.sh" \
               "${TMP_REPO}/script/hooks/post/build.sh"; do
    run head -n 1 "${_file}"
    assert_output "#!/usr/bin/env bash"
    run tail -n 1 "${_file}"
    assert_output "exit 0"
  done
}

@test "_create_hook_stubs: idempotent — preserves user-modified stub on re-run (#440)" {
  _source_init
  _create_hook_stubs
  local _file="${TMP_REPO}/script/hooks/pre/run.sh"
  # Simulate user editing their hook
  printf '#!/usr/bin/env bash\necho USER_CONTENT\nexit 0\n' > "${_file}"
  chmod +x "${_file}"
  # Re-run init's stub creator
  _create_hook_stubs
  run grep -F "USER_CONTENT" "${_file}"
  assert_success
}

@test "_create_new_repo: includes hook stubs in new-repo layout (#440)" {
  _source_init
  _create_new_repo "main"
  [[ -x "${TMP_REPO}/script/hooks/pre/run.sh" ]] || { echo "missing pre/run.sh"; return 1; }
  [[ -x "${TMP_REPO}/script/hooks/post/run.sh" ]] || { echo "missing post/run.sh"; return 1; }
}

@test "_init_existing_repo: creates missing hook stubs on upgrade (#440)" {
  _source_init
  # Simulate an existing repo on template — no hooks/ dir yet
  [[ ! -d "${TMP_REPO}/script/hooks" ]] || rm -rf "${TMP_REPO}/script/hooks"
  : > "${TMP_REPO}/Dockerfile"   # mark as "existing repo"
  _init_existing_repo
  [[ -x "${TMP_REPO}/script/hooks/pre/build.sh" ]] || { echo "missing pre/build.sh after upgrade"; return 1; }
  [[ -x "${TMP_REPO}/script/hooks/post/setup_tui.sh" ]] || { echo "missing post/setup_tui.sh after upgrade"; return 1; }
}

# ════════════════════════════════════════════════════════════════════
# _sync_base_monitor_workflow — per-repo base version monitor
# ════════════════════════════════════════════════════════════════════

@test "_sync_base_monitor_workflow: generates base-version-monitor.yaml" {
  _source_init
  _sync_base_monitor_workflow
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

@test "_sync_base_monitor_workflow: schedules weekly + manual dispatch" {
  _source_init
  _sync_base_monitor_workflow
  local _wf="${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  run grep -F 'schedule:' "${_wf}"
  assert_success
  run grep -F 'workflow_dispatch' "${_wf}"
  assert_success
}

@test "_sync_base_monitor_workflow: grants issues: write" {
  _source_init
  _sync_base_monitor_workflow
  run grep -F 'issues: write' \
    "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_success
}

@test "_sync_base_monitor_workflow: runs the subtree-shipped checker via prefix" {
  _source_init
  _sync_base_monitor_workflow
  run grep -F '.base/dist/script/base/check-base-version.sh run' \
    "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_success
}

@test "_sync_base_monitor_workflow: idempotent — never clobbers a user-tuned file" {
  _source_init
  mkdir -p "${TMP_REPO}/.github/workflows"
  echo "user-tuned" > "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _sync_base_monitor_workflow
  run cat "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  assert_output "user-tuned"
}

@test "_create_new_repo: also generates base-version-monitor.yaml" {
  _source_init
  _create_new_repo "main"
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

@test "_init_existing_repo: syncs base-version-monitor.yaml on upgrade (#777)" {
  _source_init
  : > "${TMP_REPO}/Dockerfile"   # mark as "existing repo"
  rm -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml"
  _init_existing_repo
  assert [ -f "${TMP_REPO}/.github/workflows/base-version-monitor.yaml" ]
}

# ════════════════════════════════════════════════════════════════════
# _preflight_just / _bootstrap_just
# ════════════════════════════════════════════════════════════════════

# Build a clean bin dir holding symlinks to only the externals the
# preflight/bootstrap need (no `just`). The CI image ships `just` in
# /usr/bin alongside coreutils, so trimming PATH to standard dirs cannot
# hide it; a dedicated dir can. Echoes a PATH value (MOCK_DIR first so any
# mock_cmd stubs win) for the caller to scope to a single `run`, leaving
# the test shell's own PATH intact for teardown.
_nojust_path() {
  local _clean="${TMP_REPO}/.nojust"
  mkdir -p "${_clean}"
  local _cmd _src
  for _cmd in date cat mkdir env dirname basename grep sed tr head printf \
              rm chmod ln cp mv test bash sh; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" || continue
    ln -sf "${_src}" "${_clean}/${_cmd}"
  done
  printf '%s' "${MOCK_DIR}:${_clean}"
}

@test "_preflight_just: warns and exits 0 when just is absent (#607)" {
  _source_init
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "WARN"
  assert_output --partial "just runner not found on PATH"
}

@test "_preflight_just: emits the init_just_missing event under LOG_FORMAT=json (#607)" {
  _source_init
  # JSON format carries the structured event name (text format renders the
  # display= message only); assert the registered body is wired through.
  PATH="$(_nojust_path)" LOG_FORMAT=json run _preflight_just
  assert_success
  assert_output --partial '"body":"init_just_missing"'
}

@test "_preflight_just: install hint points at the documented methods (#607)" {
  _source_init
  PATH="$(_nojust_path)" run _preflight_just
  assert_success
  assert_output --partial "just.systems/install.sh"
  assert_output --partial "--bootstrap-just"
}

@test "_preflight_just: silent and exits 0 when just is present (#607)" {
  _source_init
  mock_cmd "just" 'exit 0'
  run _preflight_just
  assert_success
  refute_output --partial "init_just_missing"
  refute_output --partial "just runner not found"
}

@test "_bootstrap_just: no-op when just is already on PATH (#607)" {
  _source_init
  mock_cmd "just" 'exit 0'
  run _bootstrap_just
  assert_success
  assert_output --partial "already installed"
  refute_output --partial "Bootstrapping just"
}

@test "_bootstrap_just: runs the official installer into ~/.local/bin when absent (#607)" {
  _source_init
  # Mock curl + bash (the installer pipeline) into MOCK_DIR so it is
  # observable without touching the network. mock_cmd writes to MOCK_DIR,
  # which the no-just PATH puts first.
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  # Mock bash echoes what it received on stdin (curl output) + its argv so
  # the whole `curl ... | bash -s -- --to <dir>` pipeline is observable.
  mock_cmd "bash" 'echo "STDIN: $(cat)"; echo "BASH_INSTALLER $*"'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_success
  assert_output --partial "Bootstrapping just"
  assert_output --partial "CURL_INVOKED"
  assert_output --partial "install.sh"
  assert_output --partial "BASH_INSTALLER -s -- --to"
  [[ -d "${TMP_REPO}/home/.local/bin" ]] || { echo "~/.local/bin not created"; return 1; }
}

@test "_bootstrap_just: aborts with a clear error when the installer pipeline fails (#692)" {
  _source_init
  # The curl|bash installer pipeline returns non-zero (network down,
  # broken installer). _bootstrap_just must _error out, not silently
  # claim success. Mock bash (the pipeline tail) to fail.
  mock_cmd "curl" 'echo "CURL_INVOKED $*"'
  mock_cmd "bash" 'cat >/dev/null; exit 1'
  PATH="$(_nojust_path)" HOME="${TMP_REPO}/home" run _bootstrap_just
  assert_failure
  assert_output --partial "just bootstrap failed"
}

# ════════════════════════════════════════════════════════════════════
# _call_setup
# ════════════════════════════════════════════════════════════════════

@test "_call_setup: warns but returns 0 when setup.sh exits non-zero (#692)" {
  _source_init
  # A failing setup.sh must degrade to a WARNING, never abort init/upgrade.
  cat > "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  run _call_setup
  assert_success
  assert_output --partial "setup.sh exited non-zero"
}

@test "_call_setup: skips with a notice when setup.sh is absent (#692)" {
  _source_init
  rm -f "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh"
  run _call_setup
  assert_success
  assert_output --partial "Skipping setup.sh"
}

@test "_call_setup: returns 0 on a setup.sh that succeeds (#692)" {
  _source_init
  cat > "${TMP_REPO}/.base/dist/script/docker/wrapper/setup.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  run _call_setup
  assert_success
  refute_output --partial "exited non-zero"
  refute_output --partial "Skipping setup.sh"
}

# ════════════════════════════════════════════════════════════════════
# _smoke_test_count (S4 item 6 -- derived TEST.md figure source of truth)
# ════════════════════════════════════════════════════════════════════

@test "_smoke_test_count: sums ^@test across the per-stage smoke tree (S4 item 6)" {
  _source_init
  local _wd="${TMP_REPO}/count_repo"
  mkdir -p "${_wd}/test/bats/smoke/shared" \
           "${_wd}/test/bats/smoke/devel-test" \
           "${_wd}/test/bats/smoke/runtime-test"
  printf '@test "a" {\n  true\n}\n@test "b" {\n  true\n}\n' \
    > "${_wd}/test/bats/smoke/shared/env.bats"
  printf '@test "c" {\n  true\n}\n' \
    > "${_wd}/test/bats/smoke/devel-test/extra.bats"
  # .gitkeep placeholders carry no @test and must not inflate the count.
  : > "${_wd}/test/bats/smoke/runtime-test/.gitkeep"
  cd "${_wd}"
  run _smoke_test_count
  assert_success
  assert_output "3"
}

@test "_smoke_test_count: returns 0 when the smoke tree has no specs (S4 item 6)" {
  _source_init
  local _wd="${TMP_REPO}/empty_repo"
  mkdir -p "${_wd}/test/bats/smoke/shared"
  : > "${_wd}/test/bats/smoke/shared/.gitkeep"
  cd "${_wd}"
  run _smoke_test_count
  assert_success
  assert_output "0"
}

# ────────────────────────────────────────────────────────────────────
# _error -- the shared fatal path
#
# It passed the human message where _log_dispatch expects a REGISTERED
# EVENT ID, so every init.sh error surfaced as the logger's own
# "unregistered log body ... add it to log-events.txt" complaint: no
# [init] ERROR framing, no timestamp, no JSON record when piped, and an
# instruction to edit a registry file that means nothing to a user.
# upgrade.sh's sibling gets this right (_log_err upgrade
# upgrade_rollback "display=$*").
# ────────────────────────────────────────────────────────────────────

_stage_missing_template_conf() {
  rm -f "${TMP_REPO}/.base/dist/.setup.conf"
  rm -f "${TMP_REPO}/.setup.conf"
  _source_init
}

@test "_error: carries a registered event id under LOG_FORMAT=json (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=json run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '"body":"init_failed"'
  refute_output --partial 'unregistered log body'
}

@test "_error: text output is framed like every other init record (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=text run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '[init] ERROR'
  assert_output --partial 'Template setup.conf not found'
  refute_output --partial 'log-events.txt'
}

@test "_error: the human message rides the display attribute (#876)" {
  _stage_missing_template_conf
  LOG_FORMAT=json run _gen_setup_conf "false"
  assert_failure
  assert_output --partial '"display":"Template setup.conf not found'
}
