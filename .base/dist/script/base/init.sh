#!/usr/bin/env bash
# init.sh - Initialize a repo with template
#
# Full setup from scratch (git subtree add needs HEAD, so an initial commit is
# required before adding the subtree):
#   mkdir <repo_name> && cd <repo_name>
#   git init
#   git commit --allow-empty -m "chore: initial commit"
#   git subtree add --prefix=.base \
#       https://github.com/ycpss91255-docker/base.git main --squash
#   ./.base/dist/script/base/init.sh
#
# (Substitute `git@github.com:...` for SSH if you have a key configured.)
#
# Steady-state users call `just base init`; the raw path above is only the
# one-time bootstrap before `just` is wired up.
#
# Auto-detects:
#   - Has Dockerfile → existing repo: create symlinks
#   - No Dockerfile → new repo: generate full project structure

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# init.sh lives deep in the subtree (.base/dist/script/base/init.sh,
# relocated in  ADR-00000011 §8 / ADR-00000006 Region A). Walk up from
# the script's own directory to the subtree root -- the directory carrying
# the subtree markers `.version` + `dist/` -- so TEMPLATE_DIR is the
# subtree root regardless of how deep the script is nested. The subtree
# prefix is its basename, used DIRECTLY as the symlink-target prefix below,
# so a downstream rename still works without code changes.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly SCRIPT_DIR
TEMPLATE_DIR="${SCRIPT_DIR}"
while [[ "${TEMPLATE_DIR}" != "/" ]]; do
  [[ -f "${TEMPLATE_DIR}/.version" && -d "${TEMPLATE_DIR}/dist" ]] && break
  TEMPLATE_DIR="$(cd -- "${TEMPLATE_DIR}/.." && pwd -P)"
done
[[ -f "${TEMPLATE_DIR}/.version" ]] || {
  echo "init.sh: cannot locate subtree root above ${SCRIPT_DIR}" >&2
  exit 1
}
readonly TEMPLATE_DIR
REPO_ROOT="$(cd -- "${TEMPLATE_DIR}/.." && pwd -P)"
readonly REPO_ROOT
TEMPLATE_REL="$(basename "${TEMPLATE_DIR}")"
readonly TEMPLATE_REL

# shellcheck source=dist/script/base/upstream.sh
source "${SCRIPT_DIR}/upstream.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/gitignore.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/_lib.sh"
# shellcheck disable=SC1091
source "${TEMPLATE_DIR}/dist/script/docker/lib/template_guard.sh"

_log() { _log_info init init_progress "display=$*"; }

# ── Symlink helper ──────────────────────────────────────────────────────────

_symlink() {
  local target="$1" link="$2"
  if [[ -L "${link}" || -f "${link}" ]]; then
    rm -f "${link}"
  fi
  ln -sf "${target}" "${link}"
  _log "  ${link} -> ${target}"
}

_create_symlinks() {
  _log "Creating symlinks:"
  # the seven user-facing wrappers live under script/ now, with
  # link targets relative to the link's directory ("../" prefix).
  # the root user entry is the `justfile` (the container-ops
  # Makefile was retired); recipes forward to ./script/<verb>.sh.
  mkdir -p script
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/build.sh" "script/build.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/run.sh" "script/run.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/exec.sh" "script/exec.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/stop.sh" "script/stop.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/prune.sh" "script/prune.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/setup.sh" "script/setup.sh"
  _symlink "../${TEMPLATE_REL}/dist/script/docker/wrapper/setup_tui.sh" "script/setup_tui.sh"
  # Migration hygiene: drop root *.sh symlinks (now under
  # script) plus the pre-setup_tui-rename `tui.sh` legacy name. The
  # [[ -L X ]] guard makes the loop idempotent on already-migrated
  # repos and silent on very old forks that never carried setup.sh /
  # setup_tui.sh at root.
  # Migration hygiene also drops the retired root `Makefile` symlink
  # (ADR-00000005 phase 2): base no longer ships a container-ops
  # Makefile, so an upgrading repo's stale root symlink must go or it
  # dangles. (The base-only `justfile.test` is unrelated -- it is a
  # regular file under `.base/`, never a root symlink.)
  local _stale
  for _stale in build.sh run.sh exec.sh stop.sh prune.sh setup.sh setup_tui.sh tui.sh Makefile; do
    if [[ -L "${_stale}" ]]; then
      rm -f "${_stale}"
      _log "  Removed stale root symlink ${_stale}"
    fi
  done
  # ADR-00000005 / ADR-00000010 / ADR-00000011: `just` is the user-facing
  # entry, now layered + fully namespaced. <repo>/justfile -> script/justfile
  # -> .base/dist/script/justfile (the entry), which `mod?`s the docker
  # + base namespaces. mod paths in the entry resolve relative to the repo
  # root (the symlink location), so each module is linked at its
  # <repo>/script/<ns>/justfile.<ns> path.
  mkdir -p script/docker script/base
  _symlink "script/justfile" "justfile"
  _symlink "../${TEMPLATE_REL}/dist/script/justfile" "script/justfile"
  _symlink "../../${TEMPLATE_REL}/dist/script/docker/justfile.docker" "script/docker/justfile.docker"
  # `base` namespace: `just base upgrade` / `just base update`
  # manage the .base subtree (apt-aligned); `just base init` re-wires symlinks;
  # `just base completions` installs opt-in shell tab-completion.
  _symlink "../../${TEMPLATE_REL}/dist/script/base/justfile.base" "script/base/justfile.base"
  _symlink "../../${TEMPLATE_REL}/dist/script/base/completions.sh" "script/base/completions.sh"
  # `template` namespace: `just template new <name>` scaffolds a
  # repo-local command group. The entry `mod?`s script/template/justfile.template;
  # new.sh + skel/ are linked alongside (base-owned, flow on upgrade).
  mkdir -p script/template
  _symlink "../../${TEMPLATE_REL}/dist/script/template/justfile.template" "script/template/justfile.template"
  _symlink "../../${TEMPLATE_REL}/dist/script/template/new.sh" "script/template/new.sh"
  _symlink "../../${TEMPLATE_REL}/dist/script/template/skel" "script/template/skel"

  if [[ ! -f .hadolint.yaml ]] \
    || diff -q .hadolint.yaml "${TEMPLATE_REL}/dist/.hadolint.yaml" \
      >/dev/null 2>&1; then
    _symlink "${TEMPLATE_REL}/dist/.hadolint.yaml" ".hadolint.yaml"
  else
    _log "  Keeping custom .hadolint.yaml (differs from template)"
  fi

  _populate_config
  _seed_local
}

# _populate_config
#
# On first init (no <repo>/config), create an empty placeholder
# directory at `<repo>/config/` with a `.gitkeep`. The Dockerfile's
# layered COPY chain (template#254) reads `.base/dist/config/` first
# as the default layer and `<repo>/config/` second as the override
# overlay; an empty <repo>/config/ means "no overrides, take all
# template defaults". Downstream adds files under <repo>/config/
# only when they want to override a specific template default.
#
# Rationale (compared to the full-copy seed):
#   * a symlink would make edits spill into the subtree and fight
#     `git subtree pull`;
#   * a plain Dockerfile COPY from `.base/dist/config/` alone would
#     deny the user any per-repo override path at all;
#   * a full-copy seed gives the user a clean
#     repo-local editing surface but freezes their config at the
#     init-time template version -- subsequent template-side
#     improvements drift, requiring manual diff/reconcile;
#   * an EMPTY placeholder lets the layered COPY do
#     the merge at build time. Repos opt into per-file overrides
#     only when they need them; everything else flows through
#     from .base/dist/config/ on every build, keeping
#     <repo>/config/ small and the override-vs-default contract
#     visible in `git status` / `git diff`.
#
# Existing repos with a full <repo>/config/ snapshot from a
# pre-v0.22.0 init keep working unchanged: their copy still
# overrides every template default at build time, identical to
# behaviour. They can manually trim files that match
# template default to start receiving template-side improvements.
_populate_config() {
  # User already has a real config/ — preserve (contains their edits
  # or full-copy snapshot, both layered correctly).
  if [[ -d config && ! -L config ]]; then
    _log "  Keeping existing config/ directory"
    return 0
  fi
  # Stale symlink from an earlier init.sh version — drop it before
  # creating the placeholder. Without rm, `mkdir` would fail if the
  # symlink target is a real dir, or pollute the subtree if it's a
  # .base/dist/config/ symlink.
  if [[ -L config ]]; then
    rm -f config
  fi
  # Create empty placeholder + .gitkeep so the dir exists in git
  # (Docker COPY of <repo>/config/ requires the path to exist).
  mkdir -p config
  cat > config/.gitkeep <<'EOF'
# Placeholder so this directory exists in git. The Dockerfile's
# layered COPY (template#254) reads .base/dist/config/ first then
# overlays <repo>/config/ on top. Drop files under <repo>/config/
# only when you want to override a specific template default
# (e.g. <repo>/config/shell/bashrc to override template's bashrc,
# or <repo>/config/shell/bashrc.d/your-snippet.sh to add a drop-in).
# Files NOT placed here keep flowing through from .base/dist/config/
# on every build.
EOF
  _log "  Created empty config/ placeholder (.base/dist/config/ is the default layer; <repo>/config/ overlays per-file)"
}

# _seed_local
#
# Seed the REPO-OWNED script/local/ starter pair (ADR-00000010): the
# command-group registry justfile.local + a companion bash template
# local.sh. Both are real files the repo commits, never overwritten by a
# subtree upgrade, mirroring the skel/ pair pattern (justfile.skel +
# skel.sh) that `just template new` uses. Each file has its OWN
# non-clobber guard, so an existing repo carrying only justfile.local (a
# pre-S4 init) still picks up local.sh on its next upgrade, and vice
# versa -- neither guard short-circuits the other.
_seed_local() {
  mkdir -p script/local
  if [[ -f script/local/justfile.local ]]; then
    _log "  Keeping existing script/local/justfile.local"
  else
    cat > script/local/justfile.local <<'EOF'
# Repo-local just command groups (registry). REPO-OWNED: committed by this
# repo, never clobbered by a base subtree upgrade. The base entry imports
# this file optionally (`import?`), so an empty registry is fine.
#
# Register a group with one `mod?` line (path relative to this file's dir,
# i.e. script/local):
#
#   mod? deploy 'deploy/justfile.deploy'
#
# then `just deploy <recipe>` runs it. Scaffold a new group with
# `just template new <name>` -- it appends the `mod?` line here for you.
#
# A companion bash template ships beside this file as local.sh. Wire it to
# a recipe you add here, e.g.:
#
#   local-hello:
#       @./local.sh
EOF
    _log "  Created script/local/justfile.local (repo-local command-group registry)"
  fi

  if [[ -f script/local/local.sh ]]; then
    _log "  Keeping existing script/local/local.sh"
  else
    cat > script/local/local.sh <<'EOF'
#!/usr/bin/env bash
# local.sh -- companion bash template for repo-local just recipes.
#
# REPO-OWNED: committed by this repo, never clobbered by a base subtree
# upgrade (like justfile.local beside it). It is a starting point -- replace
# the body with your own logic and back a recipe in justfile.local, e.g.:
#
#   local-hello:
#       @./local.sh
#
# For a fuller, namespaced command group prefer `just template new <name>`,
# which scaffolds script/local/<name>/{justfile.<name>,<name>.sh} and
# registers it for you; this top-level local.sh is the lightweight option.
set -euo pipefail

main() {
  echo "hello from script/local/local.sh -- edit me"
}

main "$@"
EOF
    chmod +x script/local/local.sh
    _log "  Created script/local/local.sh (companion bash template)"
  fi
}

_detect_template_version() {
  # Prefer .version file inside template (auto-synced by subtree pull)
  local version_file="${TEMPLATE_DIR}/.version"
  if [[ -f "${version_file}" ]]; then
    tr -d '[:space:]' < "${version_file}"
    return 0
  fi
  # Fallback: query remote tags (for fresh subtree add before .version existed).
  # Default from the one shared upstream constant (upstream.sh); override
  # via the TEMPLATE_REMOTE env var (SSH, or a private fork) -- see README
  # "Pointing .base at a different upstream".
  local _remote="${TEMPLATE_REMOTE:-${BASE_UPSTREAM_REMOTE}}"
  # In-shell scan, for the reason upgrade.sh's _get_latest_version carries
  # at length: `... | head -1 | sed ...` hands the answer to a reader that
  # stops reading, the `grep -oP` still writing dies of SIGPIPE, `pipefail`
  # makes 141 the pipeline's status, and the `|| true` that stopped the
  # resulting abort discarded the status with it -- leaving an EMPTY
  # version that reads as "the remote has no tags". Nothing here can be
  # killed by a reader that stopped reading, because there is no reader.
  # `--sort=-v:refname` puts the newest first, so the first vX.Y.Z ref
  # wins and rc / pre-release tags are skipped.
  local _line _ref _result=""
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ -n "${_result}" ]]; then
      continue
    fi
    # "<sha><TAB><ref>"; strip through the last run of whitespace, for the
    # reason upgrade.sh's twin spells out -- the replaced `grep -oP`
    # matched the ref anywhere on the line.
    _ref="${_line##*[[:space:]]}"
    if [[ "${_ref}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _result="${_ref#refs/tags/}"
    fi
  done < <(git ls-remote --tags --sort=-v:refname "${_remote}" 2>/dev/null)
  printf '%s' "${_result}"
}

# ── New repo scaffolding ────────────────────────────────────────────────────

_detect_repo_name() {
  basename "${REPO_ROOT}"
}

# _smoke_test_count -- total `^@test` count across the freshly-generated
# per-stage smoke specs under test/bats/smoke/. This is the SAME source of
# truth base's script/test/sync-doc-counts.sh uses (`grep -c '^@test'`),
# reimplemented inline because that script lives in base's own tree, not the
# shipped subtree (dist/), so init.sh cannot source it from a consumer's
# .base/. Keeps the generated doc/test/TEST.md figure equal to what the
# generated specs actually contain. Run with cwd = REPO_ROOT (main cd's
# there before scaffolding).
_smoke_test_count() {
  local _f _sum=0 _c
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _f in test/bats/smoke/**/*.bats; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _sum=$(( _sum + ${_c:-0} ))
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_sum}"
}

_create_new_repo() {
  local ref="${1:-main}"
  local name=""
  name="$(_detect_repo_name)"
  _log "Creating new repo: ${name}"

  # Dockerfile
  cp "${TEMPLATE_DIR}/dist/dockerfile/Dockerfile" Dockerfile
  _log "  Created Dockerfile (from template)"

  # compose.yaml is a derived artifact generated by setup.sh based on
  # setup.conf; _call_setup at the end of this flow will emit it.

  # script/entrypoint.sh
  mkdir -p script
  cp "${TEMPLATE_DIR}/dist/script/docker/runtime/entrypoint.sh" script/entrypoint.sh
  chmod +x script/entrypoint.sh
  _log "  Created script/entrypoint.sh"

  # test/bats/smoke/<stage>/ -- per-Dockerfile-stage smoke tree, tool-first
  # (bats layer), mirroring .base/dist/test/bats/smoke/. shared/ runs on
  # every -test stage; devel-test/ and runtime-test/ hold stage-specific
  # specs. The repo-specific env spec asserts entrypoint + bash, both
  # present in every stage, so it lands under shared/. The per-stage
  # devel-test/ and runtime-test/ folders start empty (a .gitkeep
  # placeholder) so the Dockerfile's per-stage selective COPY resolves
  # before the consumer adds specs -- including the commented-out
  # runtime-test COPY block, which needs the folder to exist the moment
  # the runtime split is enabled. Mirrors the dist smoke tree 1:1 (S3).
  mkdir -p test/bats/smoke/shared test/bats/smoke/devel-test \
    test/bats/smoke/runtime-test
  cat > "test/bats/smoke/shared/${name}_env.bats" <<BATS
#!/usr/bin/env bats
#
# Repo-specific runtime smoke tests. Exercise the \`devel\` image built
# from this repo's Dockerfile, via the \`devel-test\` stage. Use the shared
# helpers in test_helper.bash (assert_cmd_installed, assert_file_exists,
# assert_dir_exists, assert_file_owned_by, assert_pip_pkg, ...) to keep
# assertions terse. Add one assertion per meaningful installation
# artifact. Assertions here run on EVERY -test stage (shared/), so keep
# them to the universal surface; put stage-specific checks under
# test/bats/smoke/<stage>/.

setup() {
  load "\${BATS_TEST_DIRNAME}/test_helper"
}

@test "entrypoint.sh is installed and executable" {
  assert_file_exists /entrypoint.sh
  assert [ -x /entrypoint.sh ]
}

@test "bash is available on PATH" {
  assert_cmd_installed bash
}
BATS
  cat > test/bats/smoke/devel-test/.gitkeep <<'KEEP'
# Reserved for devel-test-only smoke specs. Empty until a devel-test
# specific assertion is added; the shared/ baseline still runs here.
KEEP
  cat > test/bats/smoke/runtime-test/.gitkeep <<'KEEP'
# Reserved for runtime-test-only smoke specs (opt-in runtime split). Empty
# until the runtime stage is enabled and a runtime-specific assertion is
# added; the shared/ baseline still runs here. The placeholder keeps the
# folder present so the Dockerfile's commented-out runtime-test COPY block
# resolves the moment the split is turned on.
KEEP
  _log "  Created test/bats/smoke/shared/${name}_env.bats"

  # .github/workflows/main.yaml
  mkdir -p .github/workflows
  cat > .github/workflows/main.yaml <<YAML
name: Main CI/CD

on:
  push:
    branches: [main, master]
    tags:
      - 'v*'
  pull_request:
  workflow_dispatch:

# call-release uses softprops/action-gh-release@v2 which needs
# contents: write to create a GitHub Release. Reusable workflow
# permissions intersect with the caller's, and GitHub Actions'
# default GITHUB_TOKEN is read-only, so this grant must live here
# (release-worker.yaml declaring it upstream is not enough).
permissions:
  contents: write

jobs:
  call-docker-build:
    uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/build-worker.yaml@${ref}
    with:
      image_name: ${name}

  call-release:
    needs: call-docker-build
    if: startsWith(github.ref, 'refs/tags/')
    uses: ${BASE_UPSTREAM_SLUG}/.github/workflows/release-worker.yaml@${ref}
    with:
      archive_name_prefix: ${name}
YAML
  _log "  Created .github/workflows/main.yaml"

  # .github/workflows/base-version-monitor.yaml (per-repo upgrade reminder)
  _sync_base_monitor_workflow

  # .gitignore: source canonical set from lib/gitignore.sh so future
  # template-added derived artifacts propagate via the existing-repo
  # sync path on next upgrade. PR-B adds the [logging]
  # local_path managed block here so new repos start with the right
  # entries without waiting for the first setup.sh apply.
  _sync_gitignore "${REPO_ROOT}/.gitignore"
  _sync_logging_gitignore "${REPO_ROOT}"
  _log "  Created .gitignore"

  # .dockerignore: same derived-artifact set as .gitignore so generated
  # files (.env / compose.yaml / coverage/ ...) never bloat the Docker
  # build context. Per-repo build-context lines stay hand-maintained
  # above the managed block.
  _sync_dockerignore "${REPO_ROOT}/.dockerignore"
  _log "  Created .dockerignore"

  # doc/
  mkdir -p doc/test doc/changelog
  cat > README.md <<MD
# ${name}

**[English](README.md)** | **[繁體中文](doc/README.zh-TW.md)** | **[简体中文](doc/README.zh-CN.md)** | **[日本語](doc/README.ja.md)**

## Quick Start

\`\`\`bash
./build.sh && ./run.sh
\`\`\`

## Smoke Tests

See [TEST.md](doc/test/TEST.md) for details.
MD

  for lang_file in "README.zh-TW.md" "README.zh-CN.md" "README.ja.md"; do
    cat > "doc/${lang_file}" <<MD
# ${name}

**[English](../README.md)** | **[繁體中文](README.zh-TW.md)** | **[简体中文](README.zh-CN.md)** | **[日本語](README.ja.md)**
MD
  done
  _log "  Created README.md + doc/ translations"

  # TEST.md figures are DERIVED, never hardcoded: count `^@test` across the
  # smoke specs just generated (same source of truth as sync-doc-counts.sh)
  # so the total matches reality, and use a `### <path> (N)` level-3 heading
  # the auto-counter can actually match (the pre-S4 scaffold shipped a stale
  # "**1 test**" under a `##` heading the counter's regex skipped).
  local _smoke_spec="test/bats/smoke/shared/${name}_env.bats"
  local _smoke_total _shared_n
  _smoke_total="$(_smoke_test_count)"
  _shared_n="$(grep -cE '^@test' "${_smoke_spec}" 2>/dev/null || true)"
  cat > doc/test/TEST.md <<MD
# TEST.md

Smoke tests: **${_smoke_total:-0} tests** total.

Build-time smoke specs run inside each Dockerfile \`-test\` stage. Specs live
under \`test/bats/smoke/{shared,devel-test,runtime-test}/\`; \`shared/\` runs on
every \`-test\` stage, the per-stage folders hold stage-specific assertions.
The figure above is the total \`@test\` count across all stage folders, kept
in sync with \`grep -cE '^@test'\` (base's \`sync-doc-counts.sh\` source of
truth) -- regenerate it when you add or remove specs.

## Smoke specs

### ${_smoke_spec} (${_shared_n:-0})

| Test | Description |
|------|-------------|
| \`entrypoint.sh is installed and executable\` | Entrypoint present + executable |
| \`bash is available on PATH\` | bash resolvable on PATH |
MD
  _log "  Created doc/test/TEST.md"

  cat > doc/changelog/CHANGELOG.md <<MD
# Changelog

## [Unreleased]

### Added
- Initial release
MD
  _log "  Created doc/changelog/CHANGELOG.md"

  # hook scaffolding under script/hooks/{pre,post}/.
  _create_hook_stubs
  _log "  Created script/hooks/{pre,post}/ stubs"
}

# ── Existing repo initialization ────────────────────────────────────────────

_init_existing_repo() {
  _log "Existing repo detected (Dockerfile found)"
  _create_symlinks
  _sync_existing_gitignore
  # ensure the pre/post hook scaffolding exists. Idempotent;
  # already-present stubs are left untouched. Upgrades from
  # templates pick up the 14 stubs automatically here.
  _create_hook_stubs
  # ensure the base version monitor workflow exists; existing repos
  # pick it up on their next upgrade (upgrade.sh Step 3 re-runs init).
  _sync_base_monitor_workflow
}

# _create_hook_stubs
#   Creates 14 stub files (7 wrappers x 2 phases) under
#   script/hooks/{pre,post}/. Idempotent: never overwrites an
#   existing file (so user-authored hooks survive re-init / upgrade).
#   All freshly-written stubs land with mode 755 so the
#   non-executable hard-fail path in lib/hook.sh never trips
#   spuriously on a fresh init.
_create_hook_stubs() {
  mkdir -p "${REPO_ROOT}/script/hooks/pre" "${REPO_ROOT}/script/hooks/post"
  local _wrapper _kind _file _verb _abort
  for _kind in pre post; do
    if [[ "${_kind}" == "pre" ]]; then
      _verb="before"
      _abort="aborts the wrapper"
    else
      _verb="after"
      _abort="fails the wrapper with this rc"
    fi
    for _wrapper in build run exec stop prune setup setup_tui; do
      _file="${REPO_ROOT}/script/hooks/${_kind}/${_wrapper}.sh"
      [[ -e "${_file}" ]] && continue
      cat > "${_file}" <<HOOK
#!/usr/bin/env bash
# ${_kind}-${_wrapper} hook: host-side, runs ${_verb} ${_wrapper}.sh main logic.
# Receives the same "\$@" as ${_wrapper}.sh. Non-zero exit ${_abort}.
# Replace \`exit 0\` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{$_wrapper}.sh runs with --dry-run.
exit 0
HOOK
      chmod 755 "${_file}"
    done
  done
}

# _sync_base_monitor_workflow
#   Generate .github/workflows/base-version-monitor.yaml if absent.
#   Idempotent like _create_hook_stubs: never overwrites,
#   so a repo that hand-tunes the schedule keeps its edits across
#   upgrades. The version-compare + issue-dedupe logic ships in the
#   subtree (check-base-version.sh) and refreshes on every upgrade, so
#   the generated workflow is a thin weekly scheduler. Called from both
#   the new-repo path and the existing-repo (upgrade) path so every repo
#   converges on it.
_sync_base_monitor_workflow() {
  local _wf="${REPO_ROOT}/.github/workflows/base-version-monitor.yaml"
  [[ -e "${_wf}" ]] && return 0
  mkdir -p "${REPO_ROOT}/.github/workflows"
  cat > "${_wf}" <<YAML
name: Base Version Monitor

# Opens a tracking issue in THIS repo when ycpss91255-docker/base ships a
# newer stable release than the pinned subtree (${TEMPLATE_REL}/.version).
# Pull-based: each repo polls and files into itself with the default
# GITHUB_TOKEN -- no PAT, no central repo list. Generated by init.sh; the
# comparison logic ships in the subtree
# (${TEMPLATE_REL}/dist/script/base/check-base-version.sh) and refreshes
# on upgrade, so this file is just a thin weekly scheduler.

on:
  schedule:
    - cron: '37 5 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Check for a newer base release
        env:
          GH_TOKEN: \${{ github.token }}
          GH_REPO: \${{ github.repository }}
        run: ./${TEMPLATE_REL}/dist/script/base/check-base-version.sh run
YAML
  _log "  Created .github/workflows/base-version-monitor.yaml"
}

# _sync_existing_gitignore
#   On existing-repo init / upgrade, append any canonical entries the
#   user's .gitignore is missing AND `git rm --cached` any tracked
#   files that have since become derived artifacts. Heals the 15-repo
#   drift, in one shot — no separate sweep PR needed.
_sync_existing_gitignore() {
  _sync_gitignore "${REPO_ROOT}/.gitignore"
  _untrack_canonical_in_repo "${REPO_ROOT}"
  # append-missing the same derived-artifact set into .dockerignore
  # (created if absent), preserving user build-context lines.
  _sync_dockerignore "${REPO_ROOT}/.dockerignore"
  # PR-B: rebuild the [logging] local_path managed block from the
  # current setup.conf. Used to live in setup.sh apply (runtime); now
  # tied to init/upgrade lifecycle so the file stays consistent even
  # when setup.conf changed between wrapper invocations.
  _sync_logging_gitignore "${REPO_ROOT}"
}

# ── Generate per-repo setup.conf ────────────────────────────────────────────
#
# Copies <subtree-prefix>/.setup.conf to <repo>/.setup.conf
# so the user can override any section. Replace strategy: a section present
# in the per-repo file fully replaces the template's corresponding section;
# omitted sections fall back to template.

_gen_setup_conf() {
  local _src="${TEMPLATE_DIR}/dist/.setup.conf"
  local _dst="${REPO_ROOT}/.setup.conf"
  local _force="${1:-false}"
  # .setup.conf is a repo-root dotfile — no parent dir to create.
  if [[ ! -f "${_src}" ]]; then
    _error "Template setup.conf not found at ${_src}"
  fi
  if [[ -f "${_dst}" ]]; then
    if [[ "${_force}" != "true" ]]; then
      _error "setup.conf already exists at ${_dst}. Remove it first or edit directly."
    fi
    # --force path: back up the existing conf (and .env, since a reset
    # will regenerate it from the new conf baseline) to *.bak siblings
    # before overwriting. `.gitignore` ignores these so they never get
    # committed by accident.
    local _bak="${_dst}.bak"
    cp -f "${_dst}" "${_bak}"
    _log "Backed up existing setup.conf → ${_bak}"
    if [[ -f "${REPO_ROOT}/.env" ]]; then
      local _env_bak="${REPO_ROOT}/.env.bak"
      cp -f "${REPO_ROOT}/.env" "${_env_bak}"
      _log "Backed up existing .env → ${_env_bak}"
    fi
  fi
  cp -f "${_src}" "${_dst}"
  _log "Created ${_dst}"
  _log "Edit it to customize runtime settings for this repo."
}

# ── Trigger setup.sh to materialize .env + compose.yaml ─────────────────────

_call_setup() {
  local _setup="${TEMPLATE_DIR}/dist/script/docker/wrapper/setup.sh"
  if [[ ! -f "${_setup}" ]]; then
    _log "Skipping setup.sh (${_setup} not found)"
    return 0
  fi
  _log "Running setup.sh to generate .env + compose.yaml"
  if ! bash "${_setup}" apply --base-path "${REPO_ROOT}" >/dev/null; then
    _log "WARNING: setup.sh exited non-zero; inspect manually and rerun ./build.sh --setup"
  fi
}

# _error <message>
#
# The shared fatal path. _log_* takes a REGISTERED EVENT ID as its
# second argument and the human text as a display= attribute -- passing
# the message positionally made every init.sh failure print the logger's
# own unregistered-body complaint instead of the error. Same shape as
# upgrade.sh's sibling.
_error() { _log_err init init_failed "display=$*"; exit 1; }

# ── just runner host preflight ───────────────────────────────────────
#
# `just` is the user-facing entry point for every repo this template
# scaffolds (ADR-00000005 / ADR-00000010 / ADR-00000011): the generated
# `justfile` symlink forwards `just <ns> <verb>` to script/<verb>.sh. But
# the runner lives on the HOST, not in the subtree -- vendoring it is
# rejected (arch-specific binary, --squash injects it into every
# downstream history, a committed binary never updates; Notes).
# So init.sh probes whether `just` is on PATH and, on a miss, emits ONE
# advisory warning pointing at the install methods. It is deliberately
# NON-FATAL: the symlinks + wrappers are already laid down, so installing
# `just` later makes the repo work immediately, and each recipe has a raw
# `./script/<verb>.sh` fallback in the meantime. Idempotent (a pure
# command-presence probe with no side effects), so it is safe on both the
# new-repo and existing-repo init paths.

_just_install_hint() {
  # Single source of truth for the install pointer, mirroring README
  # "Prerequisites". Terse on purpose: the README carries the full method
  # list, this is just enough to unblock the user at the moment it matters.
  cat <<'EOF'
  just is NOT auto-installed by init.sh. Install it on the host, e.g.:
    apt install just      # Debian 13+ / Ubuntu 24.04+
    brew install just     # macOS / Linuxbrew
    cargo install just    # from crates.io
    # or the official prebuilt-binary installer:
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin
    # or let init bootstrap it for you (opt-in): just base init --bootstrap-just
  See README "Prerequisites" or https://github.com/casey/just#installation.
EOF
}

_preflight_just() {
  if command -v just >/dev/null 2>&1; then
    return 0
  fi
  # One clear warning carried on a single WARN event. The display= body
  # is a leading line plus the install hint so the whole advisory rides
  # one log record rather than fragmenting across several.
  _log_warn init init_just_missing \
    "display=just runner not found on PATH -- the repo's \`just <ns> <verb>\` commands will not run until it is installed.
$(_just_install_hint)"
}

# _bootstrap_just
#
# Opt-in only (--bootstrap-just). Runs the OFFICIAL prebuilt-binary
# installer into ~/.local/bin exactly as documented in README; never
# invoked without the flag. Prints a PATH reminder when ~/.local/bin is
# absent from PATH so the freshly installed binary is actually reachable.
_bootstrap_just() {
  if command -v just >/dev/null 2>&1; then
    _log "just is already installed ($(command -v just)); nothing to bootstrap"
    return 0
  fi
  local _bindir="${HOME}/.local/bin"
  _log_warn init init_bootstrap_just \
    "display=Bootstrapping just via the official installer into ${_bindir} (opt-in)."
  mkdir -p "${_bindir}"
  if ! curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh \
      | bash -s -- --to "${_bindir}"; then
    _error "just bootstrap failed -- install manually (see README Prerequisites)"
  fi
  _log "Installed just to ${_bindir}"
  case ":${PATH}:" in
    *":${_bindir}:"*) : ;;
    *) _log "  NOTE: ${_bindir} is not on PATH -- add it (e.g. in ~/.bashrc) to use \`just\`" ;;
  esac
}

# ── Main ────────────────────────────────────────────────────────────────────

main() {
  # init.sh is a human-facing `base` namespace recipe, so it accepts
  # --lang and honors SETUP_LANG/$LANG via i18n.sh (sourced by _lib.sh). Its
  # own messages are English-only pending the localized pass; --lang
  # is validated here so the flag is accepted, not an error, uniformly with
  # the docker wrappers. Strip --lang <code> before the positional dispatch.
  local _LANG
  _resolve_lang _LANG
  local _bootstrap_just=false
  local -a _args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "init"
        shift 2
        ;;
      # opt-in host bootstrap of the `just` runner. Parsed before the
      # positional dispatch so it composes with the new/existing-repo flow
      # (run the bootstrap first, then init proceeds with `just` present).
      --bootstrap-just)
        _bootstrap_just=true
        shift
        ;;
      *) _args+=("$1"); shift ;;
    esac
  done
  set -- "${_args[@]+"${_args[@]}"}"

  if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
    cat >&2 <<'EOF'
Usage: ./<subtree-prefix>/init.sh [--gen-conf [--force]] [--bootstrap-just] [--lang <en|zh-TW|zh-CN|ja>]

Initialize a repo with the template subtree. Auto-detects:
  - Has Dockerfile → create symlinks, then run setup.sh
  - No Dockerfile  → generate full project structure, then run setup.sh

The subtree prefix is taken from init.sh's own directory; the standard
prefix is `.base/` but the script handles any prefix without code
changes.

Version is tracked in <subtree-prefix>/.version (auto-synced by subtree
pull).

Options:
  --gen-conf         Copy <subtree-prefix>/.setup.conf to
                     <repo>/.setup.conf so the user can
                     override any section (image_name / gpu / gui /
                     network / volumes / security / stage:*). Refuses
                     to overwrite an existing per-repo setup.conf unless
                     --force is given.
  --force            With --gen-conf: overwrite existing setup.conf,
                     backing up the previous .setup.conf to .setup.conf.bak
                     and .env to .env.bak first.
  --bootstrap-just   Opt-in: install the `just` runner via the official
                     prebuilt-binary installer into ~/.local/bin before
                     init proceeds. Without this flag, a missing `just`
                     only triggers a non-fatal warning (never auto-
                     installed). No-op when `just` is already on PATH.

By default init prints a one-line warning when `just` is not on PATH
(`just` is the user-facing entry point, ADR-00000005); init still
completes so installing `just` later makes the repo work immediately.

Run from the repo root after:
  git subtree add --prefix=<subtree-prefix> \
      <template-remote-url> <version> --squash
EOF
    return 0
  fi

  # Refuse to run inside the base template source itself (ADR-00000011 sec.8).
  # A vendored `.base/` subtree never carries `.git`; the base checkout/
  # worktree does, so `.git` at the resolved subtree root means "this is the
  # template source, not a consumer" -- proceeding would scaffold into base's
  # PARENT dir. After --help (which must work anywhere), before any mutation.
  _assert_not_template_source "${TEMPLATE_DIR}" init || exit 1

  cd "${REPO_ROOT}"

  if [[ "${1:-}" == "--gen-conf" ]]; then
    local _force=false
    [[ "${2:-}" == "--force" ]] && _force=true
    _gen_setup_conf "${_force}"
    return 0
  fi

  # opt-in `just` bootstrap runs first so the rest of init proceeds
  # with the runner present (and the closing preflight stays quiet).
  if [[ "${_bootstrap_just}" == "true" ]]; then
    _bootstrap_just
  fi

  local template_version=""
  template_version="$(_detect_template_version)"

  if [[ -f Dockerfile ]]; then
    _init_existing_repo
  else
    _create_new_repo "${template_version:-main}"
    _create_symlinks
  fi

  _call_setup

  # host preflight for the `just` runner. Runs on BOTH the new-repo
  # and existing-repo paths (placed in main, after the scaffolding/setup
  # that lays down the justfile symlink). Non-fatal: warns and continues.
  _preflight_just

  _log ""
  _log "Done!"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
