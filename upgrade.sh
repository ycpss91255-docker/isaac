#!/usr/bin/env bash
# upgrade.sh - Upgrade template subtree to the latest version
#
# Run from the repo root:
#   ./template/upgrade.sh              # upgrade to latest tag
#   ./template/upgrade.sh v0.3.0       # upgrade to specific version
#   ./template/upgrade.sh --check      # check if update available

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT
# Default to HTTPS so users without an SSH key (fresh clone, CI runner,
# first-time contributor) can `./template/upgrade.sh` out of the box.
# Export TEMPLATE_REMOTE=git@github.com:... to opt into SSH (needed for
# private forks, or when the user prefers agent-based auth).
TEMPLATE_REMOTE="${TEMPLATE_REMOTE:-https://github.com/ycpss91255-docker/template.git}"
readonly TEMPLATE_REMOTE
VERSION_FILE="${REPO_ROOT}/template/.version"
readonly VERSION_FILE

cd "${REPO_ROOT}"

_log() { printf "[upgrade] %s\n" "$*"; }
_error() { printf "[upgrade] ERROR: %s\n" "$*" >&2; exit 1; }

# ── Safety guards ────────────────────────────────────────────────────────────
#
# git-subtree pull is known to misbehave on some versions (reports of
# destructive fast-forward have been seen on Jetson L4T shipping older
# git-subtree.sh). These helpers keep `upgrade.sh` safe regardless: fail
# fast if the repo is not in a state where subtree pull can succeed
# cleanly, and roll back if the pull ran but left `template/` in a shape
# that doesn't match a subtree (e.g. markers missing, working tree
# contains template-repo root files at <repo>/ root).

# _require_git_identity
#   git-subtree internally calls `git commit-tree`, which needs
#   user.name + user.email. Missing identity on Jetson was observed to
#   leave git in a partial state that the next run then fast-forwarded
#   destructively. Fail fast with an actionable message instead.
_require_git_identity() {
  local _name _email
  _name="$(git config user.name 2>/dev/null || true)"
  _email="$(git config user.email 2>/dev/null || true)"
  if [[ -z "${_name}" || -z "${_email}" ]]; then
    _error "git identity not configured. Set it before upgrading:
  git config --global user.name \"Your Name\"
  git config --global user.email \"you@example.com\""
  fi
}

# _require_clean_merge_state
#   Refuse to start if a merge / rebase / cherry-pick / revert is in
#   progress; our subtree merge would be conflated with the user's
#   in-flight operation.
_require_clean_merge_state() {
  local _git_dir _state
  _git_dir="$(git rev-parse --git-dir)"
  for _state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    if [[ -e "${_git_dir}/${_state}" ]]; then
      _error "${_state} present in ${_git_dir} — resolve or abort it before upgrading."
    fi
  done
}

# _verify_subtree_intact <pre_head_sha>
#   Post-pull sanity check: `template/` must still contain the subtree
#   markers. A known failure mode (older git-subtree) is to fast-forward
#   the synthetic squash commit, replacing <repo> root with template's
#   tree (moves `template/*` to `<repo>/*` and deletes repo-specific
#   files). Detect that by checking subtree markers, and hard-reset back
#   to <pre_head_sha> if integrity is lost.
_verify_subtree_intact() {
  local _pre_head="$1"
  local _markers=(
    "template/.version"
    "template/init.sh"
    "template/script/docker/setup.sh"
  )
  local _marker
  for _marker in "${_markers[@]}"; do
    if [[ ! -f "${_marker}" ]]; then
      printf "[upgrade] ERROR: post-pull integrity check failed — '%s' missing.\n" "${_marker}" >&2
      printf "[upgrade] Likely cause: git-subtree fast-forwarded destructively.\n" >&2
      printf "[upgrade] Rolling back to %s ...\n" "${_pre_head:0:12}" >&2
      git reset --hard "${_pre_head}" >/dev/null 2>&1 || true
      _error "upgrade aborted; repo restored to pre-upgrade state"
    fi
  done
}

# ── Get versions ─────────────────────────────────────────────────────────────

_get_local_version() {
  if [[ -f "${VERSION_FILE}" ]]; then
    tr -d '[:space:]' < "${VERSION_FILE}"
  else
    echo "unknown"
  fi
}

_get_latest_version() {
  # `head -1` closes stdin after one line, which delivers SIGPIPE to the
  # upstream `grep -oP`. With `pipefail` set, the pipe inherits that
  # non-zero exit. Bash 5.3 (alpine 3.23 — the test-tools image runner
  # introduced in #168) propagates that failed command-substitution exit
  # through the caller's `set -e` and silently kills the script before
  # _check's `_log` lines run; bash 5.2 (debian bookworm / kcov-runner)
  # does not. Wrap the pipe with `|| true` so this function unconditionally
  # returns 0 — an empty result still funnels into `[[ -z latest_ver ]]`
  # → `_error "Could not fetch ..."` in _check, so genuine network failures
  # still surface with a clear message.
  local _result=""
  _result=$(git ls-remote --tags --sort=-v:refname "${TEMPLATE_REMOTE}" \
    | grep -oP 'refs/tags/v\d+\.\d+\.\d+$' \
    | head -1 \
    | sed 's|refs/tags/||') || true
  printf '%s' "${_result}"
}

# ── Semver comparison ────────────────────────────────────────────────────────
#
# SemVer §11 says a pre-release version has LOWER precedence than the
# associated normal version (rc1 < final). GNU `sort -V` orders them
# the OTHER way (final < rc1, treats `-` as "less than empty"), so we
# can't just delegate. The wrong ordering caused issue #156: once
# v0.12.0 was published, downstreams still pinned to v0.12.0-rc1
# would have been told they were "ahead" of stable, hiding the upgrade.
#
# This comparator handles the only semver shape we ship —
# v<MAJOR>.<MINOR>.<PATCH>[-<PRERELEASE>] — and applies §11 explicitly:
#   - core compared via `sort -V` (purely numeric, no `-` involved)
#   - same-core final beats same-core pre-release
#   - same-core pre-releases compared lexicographically (rc1 < rc2 etc.)
#
# Returns: 0 = equal, 1 = a < b, 2 = a > b.
_semver_cmp() {
  local _a="${1#v}"
  local _b="${2#v}"
  local _a_core="${_a%%-*}"
  local _b_core="${_b%%-*}"
  local _a_pre=""
  local _b_pre=""
  [[ "${_a}" == *"-"* ]] && _a_pre="${_a#*-}"
  [[ "${_b}" == *"-"* ]] && _b_pre="${_b#*-}"

  if [[ "${_a_core}" != "${_b_core}" ]]; then
    local _newer
    _newer="$(printf '%s\n%s\n' "${_a_core}" "${_b_core}" | sort -V | tail -1)"
    [[ "${_newer}" == "${_a_core}" ]] && return 2 || return 1
  fi

  if [[ -z "${_a_pre}" && -z "${_b_pre}" ]]; then return 0; fi
  [[ -z "${_a_pre}" ]] && return 2
  [[ -z "${_b_pre}" ]] && return 1

  if [[ "${_a_pre}" < "${_b_pre}" ]]; then return 1; fi
  if [[ "${_a_pre}" > "${_b_pre}" ]]; then return 2; fi
  return 0
}

# ── Check mode ───────────────────────────────────────────────────────────────

_check() {
  local local_ver latest_ver
  local_ver="$(_get_local_version)"
  latest_ver="$(_get_latest_version)"

  if [[ -z "${latest_ver}" ]]; then
    _error "Could not fetch latest version from ${TEMPLATE_REMOTE}"
  fi

  _log "Local:  ${local_ver}"
  _log "Latest: ${latest_ver}"

  if [[ "${local_ver}" == "unknown" ]]; then
    _log "Update available: ${local_ver} →${latest_ver}"
    return 1
  fi

  local _cmp=0
  _semver_cmp "${local_ver}" "${latest_ver}" || _cmp=$?
  case "${_cmp}" in
    0) _log "Already up to date."; return 0 ;;
    1) _log "Update available: ${local_ver} →${latest_ver}"; return 1 ;;
    2) _log "Local is ahead of latest stable (prerelease or local-only tag)."; return 0 ;;
  esac
}

# ── Upgrade ──────────────────────────────────────────────────────────────────

_upgrade() {
  local target_ver="$1"
  local local_ver
  local_ver="$(_get_local_version)"

  if [[ "${local_ver}" == "${target_ver}" ]]; then
    _log "Already at ${target_ver}. Nothing to do."
    return 0
  fi

  # Refuse implicit downgrade. Without this guard the user can ratchet
  # back from v0.12.0-rc1 to an older v0.11.0 without realising it,
  # which silently undoes prerelease testing and re-introduces fixed
  # bugs. _semver_cmp returns 2 when local > target per SemVer §11.
  if [[ "${local_ver}" != "unknown" ]]; then
    local _cmp=0
    _semver_cmp "${local_ver}" "${target_ver}" || _cmp=$?
    if (( _cmp == 2 )); then
      _error "Refusing implicit downgrade from ${local_ver} to ${target_ver}.
  If this is intentional (rolling back a bad release), edit
  template/.version manually and re-run the upgrade."
    fi
  fi

  # Pre-flight safety checks. Any failure exits non-zero without
  # touching the working tree.
  _require_git_identity
  _require_clean_merge_state

  # Snapshot HEAD so the post-pull integrity check can roll back if
  # git-subtree corrupts the tree.
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  _log "Upgrading: ${local_ver} → ${target_ver}"

  # Snapshot the pre-pull tree hash of template/config so we can tell
  # the user if their seeded <repo>/config is now out of sync with the
  # upstream baseline. Git tree hashes are stable and cheap (no blob
  # compare); if HEAD has no template/config yet (initial setup),
  # leave _pre_config_hash empty.
  local _pre_config_hash=""
  # --verify: print the resolved hash on success, print nothing on
  # failure. Without it, git's default mode echoes the unresolved ref
  # back to stdout for unknown paths, which would be mistaken for a
  # hash later by _warn_config_drift.
  _pre_config_hash="$(git rev-parse --verify "HEAD:template/config" 2>/dev/null || true)"

  # Snapshot pre-pull template/setup.conf hash too. If the upstream
  # baseline changed, the user may want to copy new sections / keys
  # into their <repo>/setup.conf override (issue #201's 2-file model
  # makes this a manual merge — we never overwrite the user's file).
  local _pre_setup_conf_hash=""
  _pre_setup_conf_hash="$(git rev-parse --verify "HEAD:template/setup.conf" 2>/dev/null || true)"

  # Step 1: subtree pull
  _log "Step 1/4: git subtree pull"
  git subtree pull --prefix=template \
    "${TEMPLATE_REMOTE}" "${target_ver}" --squash \
    -m "chore: upgrade template subtree to ${target_ver}"

  # Step 2: post-pull integrity check (rolls back on corruption)
  _log "Step 2/4: verify template/ subtree integrity"
  _verify_subtree_intact "${_pre_head}"

  # Step 3: re-run init.sh to sync symlinks (in case template structure changed)
  _log "Step 3/4: re-run init.sh to sync symlinks"
  ./template/init.sh

  # Step 4: update main.yaml @tag references
  _log "Step 4/4: update workflow @tag references"
  local main_yaml="${REPO_ROOT}/.github/workflows/main.yaml"
  if [[ -f "${main_yaml}" ]]; then
    # Replace @vX.Y.Z(-prerelease)? with new version in reusable workflow
    # references. Match each worker file by name to avoid greedy patterns
    # clobbering siblings. The `-E` regex anchors on a full semver shape
    # (optional pre-release per §9) — the prior `[0-9.]*` stopped at the
    # first `-`, so upgrading from an RC tag (e.g. v0.10.0-rc1 → -rc2)
    # left the old suffix in place and produced `@v0.10.0-rc2-rc1`.
    sed -i -E "s|build-worker\.yaml@v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|build-worker.yaml@${target_ver}|g" "${main_yaml}"
    sed -i -E "s|release-worker\.yaml@v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|release-worker.yaml@${target_ver}|g" "${main_yaml}"
    git add "${main_yaml}"
  fi

  # Step 3 ran init.sh which (re-)synced .gitignore via lib/gitignore.sh
  # and `git rm --cached`-ed any tracked-but-now-derived artifacts
  # (#172). The .gitignore mutation is unstaged; the rm is index-staged.
  # Stage .gitignore so both land in the same commit.
  if [[ -f "${REPO_ROOT}/.gitignore" ]]; then
    git add "${REPO_ROOT}/.gitignore"
  fi

  # Commit workflow + .gitignore + index removals together
  git commit -m "$(cat <<COMMIT
chore: update template references to ${target_ver}

- main.yaml: workflow @tag updated to ${target_ver}
- .gitignore: synced canonical entries (template lib/gitignore.sh)
- untracked any derived artifacts now covered by .gitignore
COMMIT
)" || _log "No additional changes to commit"

  # Post-pull: warn when the upstream config baseline moved so the
  # user can reconcile <repo>/config/ (seeded by init.sh, user-owned
  # afterwards) against the new template/config/. Silent when the
  # baseline didn't change or there was no prior baseline.
  _warn_config_drift "${_pre_config_hash}"

  # Same pattern for template/setup.conf: post-#201 the user's per-repo
  # setup.conf is the override file (committed, never overwritten by
  # template upgrades). When the upstream template/setup.conf adds new
  # sections / keys / changes defaults, point the user at the diff so
  # they can opt in.
  _warn_setup_conf_drift "${_pre_setup_conf_hash}"

  _log "Done! Upgraded to ${target_ver}"
  _log ""
  _log "Next steps:"
  _log "  1. Run ./build.sh test to verify"
  _log "  2. git push"
}

# _warn_config_drift <pre_pull_tree_hash>
#
# When the upstream template/config/ tree changed during this pull,
# print a WARNING pointing the user at the diff so they can merge into
# their <repo>/config/ manually. Never fails the upgrade (config is
# user-owned — we only report, not force).
_warn_config_drift() {
  local _pre="${1:-}"
  local _post
  _post="$(git rev-parse --verify "HEAD:template/config" 2>/dev/null || true)"
  [[ -z "${_post}" ]] && return 0         # no config in new subtree
  [[ "${_pre}" == "${_post}" ]] && return 0   # unchanged
  _log ""
  _log "WARNING: template/config/ changed upstream since the last pull."
  _log "         Your <repo>/config/ is user-owned and was NOT updated."
  _log "         Review the diff and port any upstream changes you want:"
  _log ""
  _log "           diff -ruN template/config config"
  if [[ -n "${_pre}" ]]; then
    _log ""
    _log "         Upstream-only diff (what moved in template/config/):"
    _log "           git diff ${_pre:0:12}..${_post:0:12} -- template/config"
  fi
}

# _warn_setup_conf_drift <pre_pull_blob_hash>
#
# Post-#201 sibling of _warn_config_drift. <repo>/setup.conf is the
# user-owned override file; this script never rewrites it. When the
# upstream template/setup.conf changes (new sections, new keys, default
# tweaks), surface a pointer to the diff so the user can hand-merge any
# upstream additions they want into their override. Silent on no change.
_warn_setup_conf_drift() {
  local _pre="${1:-}"
  local _post
  _post="$(git rev-parse --verify "HEAD:template/setup.conf" 2>/dev/null || true)"
  [[ -z "${_post}" ]] && return 0
  [[ "${_pre}" == "${_post}" ]] && return 0
  _log ""
  _log "WARNING: template/setup.conf changed upstream since the last pull."
  _log "         Your <repo>/setup.conf is the user override and was NOT updated."
  _log "         Review the diff and copy any new sections / keys you want:"
  _log ""
  _log "           diff -u template/setup.conf setup.conf"
  if [[ -n "${_pre}" ]]; then
    _log ""
    _log "         Upstream-only diff (what moved in template/setup.conf):"
    _log "           git diff ${_pre:0:12}..${_post:0:12} -- template/setup.conf"
  fi
}

# ── Help ─────────────────────────────────────────────────────────────────────

_usage() {
  cat >&2 <<'EOF'
Usage: ./template/upgrade.sh [VERSION|--check|--gen-conf]

Upgrade template subtree to the latest (or specified) version.

Arguments:
  VERSION       Target version (e.g. v0.5.0). Defaults to latest tag.
  --check       Check if an update is available (no changes made)
  --gen-conf    Copy template/setup.conf to repo root for per-repo
                configuration overrides (delegates to init.sh --gen-conf)
  -h, --help    Show this help

Examples:
  ./template/upgrade.sh               # upgrade to latest
  ./template/upgrade.sh v0.5.0        # upgrade to specific version
  ./template/upgrade.sh --check       # check only
  ./template/upgrade.sh --gen-conf    # copy setup.conf to repo root
EOF
  exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    -h|--help) _usage ;;
  esac

  [[ ! -d template ]] && _error "template/ not found. Run from repo root."

  case "${1:-}" in
    --check) _check ;;
    --gen-conf) ./template/init.sh --gen-conf ;;
    v*)
      _upgrade "$1"
      ;;
    "")
      local latest
      latest="$(_get_latest_version)"
      [[ -z "${latest}" ]] && _error "Could not fetch latest version"
      _upgrade "${latest}"
      ;;
    *) _error "Unknown argument: $1" ;;
  esac
}

main "$@"
