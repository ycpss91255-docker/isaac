#!/usr/bin/env bash
# upgrade.sh - Upgrade template subtree to the latest version
#
# Run from the repo root:
#   ./.base/dist/script/base/upgrade.sh              # latest tag
#   ./.base/dist/script/base/upgrade.sh v0.3.0       # specific version
#   ./.base/dist/script/base/upgrade.sh --check      # check only
#
# Steady-state users call `just base upgrade [vX.Y.Z]`; the raw path above
# is only for environments without `just`.

set -euo pipefail

# upgrade.sh lives deep in the subtree (.base/dist/script/base/upgrade.sh,
# relocated in  ADR-00000011 §8 / ADR-00000006). Walk up from the
# script's own directory to the subtree root -- the directory carrying the
# subtree markers `.version` + `dist/` -- so SUBTREE_ROOT is the
# subtree root regardless of how deep the script is nested. The subtree
# prefix is its basename, used DIRECTLY as the subtree-pull --prefix= flag
# and every filesystem reference, so a downstream rename still works
# without code changes.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly SCRIPT_DIR
SUBTREE_ROOT="${SCRIPT_DIR}"
while [[ "${SUBTREE_ROOT}" != "/" ]]; do
  [[ -f "${SUBTREE_ROOT}/.version" && -d "${SUBTREE_ROOT}/dist" ]] && break
  SUBTREE_ROOT="$(cd -- "${SUBTREE_ROOT}/.." && pwd -P)"
done
[[ -f "${SUBTREE_ROOT}/.version" ]] || {
  echo "upgrade.sh: cannot locate subtree root above ${SCRIPT_DIR}" >&2
  exit 1
}
readonly SUBTREE_ROOT
REPO_ROOT="$(cd -- "${SUBTREE_ROOT}/.." && pwd -P)"
readonly REPO_ROOT
TEMPLATE_REL="$(basename "${SUBTREE_ROOT}")"
readonly TEMPLATE_REL
# Where .base/ is pulled from. The default is the one shared upstream
# constant (upstream.sh), not a literal repeated per script. Export
# TEMPLATE_REMOTE=git@github.com:... to opt into SSH (needed for private
# forks, or when the user prefers agent-based auth) -- see README
# "Pointing .base at a different upstream". Everything this URL delivers
# is executed in the consumer's tree, so it is worth knowing which one it
# is.
# shellcheck source=dist/script/base/upstream.sh
source "${SCRIPT_DIR}/upstream.sh"
TEMPLATE_REMOTE="${TEMPLATE_REMOTE:-${BASE_UPSTREAM_REMOTE}}"
readonly TEMPLATE_REMOTE
VERSION_FILE="${REPO_ROOT}/${TEMPLATE_REL}/.version"
readonly VERSION_FILE

# upgrade.sh sources _lib.sh directly (not via _bootstrap), so set
# the verb here for transcript.sh's classification before the source.
export _WRAPPER_VERB=upgrade
# shellcheck disable=SC1091
source "${SUBTREE_ROOT}/dist/script/docker/lib/_lib.sh"
# _lib.sh does NOT pull in template_guard.sh, so source it explicitly
# (mirroring init.sh) for the self-run guard _assert_not_template_source.
# shellcheck disable=SC1091
source "${SUBTREE_ROOT}/dist/script/docker/lib/template_guard.sh"

cd "${REPO_ROOT}"

_log() { _log_info upgrade upgrade_started "display=$*"; }
_error() { _log_err upgrade upgrade_rollback "display=$*"; exit 1; }

# ── Safety guards ────────────────────────────────────────────────────────────
#
# git-subtree pull is known to misbehave on some versions (reports of
# destructive fast-forward have been seen on Jetson L4T shipping older
# git-subtree.sh). These helpers keep `upgrade.sh` safe regardless: fail
# fast if the repo is not in a state where subtree pull can succeed
# cleanly, and roll back if the pull ran but left `.base/` in a shape
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

# stale-path-lint: allow-begin -- the legacy-migration block must name the
# pre-relocation override path in order to relocate a downstream still
# carrying it. Every other mention of that path in runtime code is a defect
# (the override lives at the repo-root .setup.conf dotfile), so the opt-out
# is scoped to this block and ends at the matching allow-end below.
#
# _migrate_legacy_setup_conf <repo_root>
#
# setup.conf is `just setup`-managed, not hand-edited, so it left the
# hand-editable config/ surface: the per-repo override moved from
# config/docker/setup.conf to the repo root as the .setup.conf dotfile.
# Detect a downstream still carrying the legacy override and relocate it
# so the upgrade never silently drops the user's config (same fail-loud
# discipline the drift-warning family uses). Runs BEFORE the subtree
# pull and commits the move, so the pull still sees a clean tree.
#
# Idempotent: no-op when there is no legacy file. When BOTH the legacy
# and the new location exist, refuse to clobber — the root file wins,
# the legacy file is kept, and the conflict is reported for manual
# reconciliation.
_migrate_legacy_setup_conf() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _legacy="${_root}/config/docker/setup.conf"
  local _new="${_root}/.setup.conf"

  [[ -f "${_legacy}" ]] || return 0   # nothing to migrate

  if [[ -f "${_new}" ]]; then
    _log ""
    _log "WARNING: found BOTH a legacy config/docker/setup.conf and a"
    _log "         repo-root .setup.conf. The root file wins; your legacy"
    _log "         override was NOT merged and is left in place. Reconcile"
    _log "         and drop the legacy file manually:"
    _log ""
    _log "           diff -u config/docker/setup.conf .setup.conf"
    _log "           git rm config/docker/setup.conf"
    return 0
  fi

  _log ""
  _log "MIGRATION: relocating per-repo setup.conf override"
  _log "           config/docker/setup.conf -> .setup.conf"
  _log "           (setup.conf is tool-managed; it now lives at the repo"
  _log "            root as a dotfile, out of the hand-editable config/"
  _log "            surface)"

  # git mv when the override is tracked; plain mv + git add otherwise.
  # Either way the relocation lands as a committed change so the
  # subsequent subtree pull operates on a clean tree.
  #
  # Collect the paths the migration actually touches so the commit below
  # can be scoped to them. The legacy path is only nameable to `git
  # commit` when git tracked it; in the untracked case it exists in
  # neither HEAD nor the working tree and git rejects the pathspec.
  local -a _commit_paths=(".setup.conf")
  if git -C "${_root}" ls-files --error-unmatch "config/docker/setup.conf" \
       >/dev/null 2>&1; then
    git -C "${_root}" mv "config/docker/setup.conf" ".setup.conf"
    _commit_paths+=("config/docker/setup.conf")
  else
    mv "${_legacy}" "${_new}"
    git -C "${_root}" add ".setup.conf"
  fi

  # Clean up the now-empty legacy dir (git tracks no empty dirs; this is
  # a working-tree tidy so config/docker/setup.conf still present checks
  # stay accurate).
  rmdir "${_root}/config/docker" 2>/dev/null || true
  rmdir "${_root}/config" 2>/dev/null || true

  # Scoped to the migrated paths: the pre-flight deliberately does not
  # demand a clean index (only a clean merge state), so an unscoped
  # commit would sweep a user's unrelated staged work into a commit
  # labelled as the relocation. The pathspec form also leaves that
  # staged work staged, exactly as the user left it.
  git -C "${_root}" commit -q \
    -m "chore: relocate setup.conf override to repo-root .setup.conf" \
    -- "${_commit_paths[@]}" \
    || _log "  (nothing staged for the setup.conf relocation)"
}
# stale-path-lint: allow-end

# _migrate_lifecycle_restart_default <repo_root>
#
# `[lifecycle] restart` used to be a DEVEL-scoped key whose template
# default was the literal `restart = no`, and `init.sh --gen-conf` copies
# the WHOLE template to `<repo>/.setup.conf` -- so every downstream repo
# carries that literal whether or not anyone chose it. The key is now
# DEPLOY-scoped (deployable stages + the field bundle, never devel, never
# `*-test`) with a shipped default of `unless-stopped`, which makes the
# copied `no` stale BY CONSTRUCTION: it is a devel-scoped answer to a
# question that is now only ever asked about a field service, and left
# alone it silently denies that service its auto-start on host reboot.
#
# So rewrite it -- but only when this upgrade is the one crossing the
# rescope. The PRE-PULL vendored template is the discriminator: while it
# still ships `restart = no`, a downstream `restart = no` can only be the
# copied default; once the pull lands the new template the migration goes
# permanently inert, so a `no` the repo deliberately chooses AFTERWARDS is
# never touched. A repo that already chose something else (`on-failure:5`,
# `always`, ...) is never touched either.
#
# Runs BEFORE the subtree pull and commits the rewrite, so the pull still
# sees a clean tree (same discipline as _migrate_legacy_setup_conf).
_migrate_lifecycle_restart_default() {
  local _root="${1:?"${FUNCNAME[0]}: missing repo_root"}"
  local _conf="${_root}/.setup.conf"
  local _tpl="${_root}/${TEMPLATE_REL}/dist/.setup.conf"

  [[ -f "${_conf}" ]] || return 0
  # No vendored baseline -> cannot tell whether this upgrade crosses the
  # rescope, so touch nothing (fail-safe).
  [[ -f "${_tpl}" ]] || return 0
  _lifecycle_restart_is "${_tpl}" "no" || return 0
  _lifecycle_restart_is "${_conf}" "no" || return 0

  # Rewrite in place (`cat >` keeps the original mode + inode) so only the
  # one `[lifecycle] restart` line changes.
  local _tmp _line _trimmed _section=""
  _tmp="$(mktemp)"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _trimmed="$(_trim_ws "${_line}")"
    if [[ "${_trimmed}" == '['*']' ]]; then
      _section="${_trimmed#\[}"
      _section="${_section%\]}"
    elif [[ "${_section}" == "lifecycle" ]] \
         && [[ "${_trimmed}" =~ ^restart[[:space:]]*=[[:space:]]*no$ ]]; then
      _line="restart = unless-stopped"
    fi
    printf '%s\n' "${_line}" >> "${_tmp}"
  done < "${_conf}"
  cat "${_tmp}" > "${_conf}"
  rm -f "${_tmp}"

  _log ""
  _log "MIGRATION: [lifecycle] restart is now DEPLOY-scoped"
  _log "           restart = no -> restart = unless-stopped"
  _log "           (the old template default was devel-scoped; the key now"
  _log "            applies to deployable stages + the field bundle only,"
  _log "            never to devel or a *-test stage, and a field service"
  _log "            is meant to auto-start again after a host reboot)"
  _log "           Set it back to 'no' in .setup.conf if that is what you"
  _log "           actually want -- it will not be rewritten again."

  if git -C "${_root}" ls-files --error-unmatch ".setup.conf" \
       >/dev/null 2>&1; then
    git -C "${_root}" add ".setup.conf"
    git -C "${_root}" commit -q \
      -m "chore: migrate [lifecycle] restart default to unless-stopped" \
      || _log "  (nothing staged for the restart-default migration)"
  fi
}

# _trim_ws <line>
#   Echo <line> with surrounding whitespace stripped.
_trim_ws() {
  local _s="${1-}"
  _s="${_s#"${_s%%[![:space:]]*}"}"
  printf '%s' "${_s%"${_s##*[![:space:]]}"}"
}

# _lifecycle_restart_is <conf_path> <value>
#   True when <conf_path> carries `restart = <value>` inside its
#   `[lifecycle]` section. Section-scoped on purpose: a `[stage:*]`
#   section may legitimately carry its own `restart` key.
_lifecycle_restart_is() {
  local _path="${1:?}" _want="${2:?}"
  local _line _trimmed _section=""
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _trimmed="$(_trim_ws "${_line}")"
    if [[ "${_trimmed}" == '['*']' ]]; then
      _section="${_trimmed#\[}"
      _section="${_section%\]}"
      continue
    fi
    [[ "${_section}" == "lifecycle" ]] || continue
    [[ "${_trimmed}" =~ ^restart[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    [[ "$(_trim_ws "${BASH_REMATCH[1]}")" == "${_want}" ]] && return 0
  done < "${_path}"
  return 1
}

# _verify_subtree_intact <pre_head_sha>
#   Post-pull sanity check: `${TEMPLATE_REL}/` must still contain the
#   subtree markers. A known failure mode (older git-subtree) is to
#   fast-forward the synthetic squash commit, replacing <repo> root with
#   the upstream tree (moves `${TEMPLATE_REL}/*` to `<repo>/*` and
#   deletes repo-specific files). Detect that by checking subtree
#   markers, and hard-reset back to <pre_head_sha> if integrity is lost.
_verify_subtree_intact() {
  local _pre_head="$1"
  local _target_ver="${2:-}"

  # R1+ structural invariant: instead of asserting specific
  # files exist at hard-coded paths (which broke on the v0.39.0
  # `script/docker/setup.sh` -> `wrapper/setup.sh` reorg), check that
  # the subtree directory exists, is non-empty, and carries a
  # well-formed `.version`. Then verify the pulled version matches
  # the target the caller asked for (catches wrong-tag / wrong-remote
  # cases that pass the structural check but deliver the wrong thing).
  # Sibling path-coupling regions in upgrade.sh are intentionally not
  # covered here -- tracked in
  if [[ ! -d "${TEMPLATE_REL}" ]]; then
    _log_err upgrade upgrade_subtree_pull_failed "display=post-pull integrity check failed -- '${TEMPLATE_REL}/' subtree dir missing." "marker=${TEMPLATE_REL}"
    _rollback_subtree_pull "${_pre_head}"
  fi
  if [[ -z "$(ls -A "${TEMPLATE_REL}" 2>/dev/null)" ]]; then
    _log_err upgrade upgrade_subtree_pull_failed "display=post-pull integrity check failed -- '${TEMPLATE_REL}/' subtree dir is empty." "marker=${TEMPLATE_REL}"
    _rollback_subtree_pull "${_pre_head}"
  fi
  if [[ ! -f "${TEMPLATE_REL}/.version" ]]; then
    _log_err upgrade upgrade_subtree_pull_failed "display=post-pull integrity check failed -- '${TEMPLATE_REL}/.version' missing." "marker=${TEMPLATE_REL}/.version"
    _rollback_subtree_pull "${_pre_head}"
  fi

  local _pulled_ver
  _pulled_ver="$(tr -d '[:space:]' < "${TEMPLATE_REL}/.version")"
  if [[ ! "${_pulled_ver}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    _log_err upgrade upgrade_subtree_pull_failed "display=post-pull integrity check failed -- '${TEMPLATE_REL}/.version' content is not semver: '${_pulled_ver}'." "pulled=${_pulled_ver}"
    _rollback_subtree_pull "${_pre_head}"
  fi

  if [[ -n "${_target_ver}" ]] && [[ "${_pulled_ver#v}" != "${_target_ver#v}" ]]; then
    _log_err upgrade upgrade_version_mismatch "display=pulled ${_pulled_ver}, expected ${_target_ver}" "pulled=${_pulled_ver}" "expected=${_target_ver}"
    _rollback_subtree_pull "${_pre_head}"
  fi
}

_rollback_subtree_pull() {
  local _pre_head="$1"
  _log_err upgrade upgrade_rollback "display=Likely cause: git-subtree fast-forwarded destructively or pulled wrong tag."
  _log_info upgrade upgrade_rollback "display=Rolling back to ${_pre_head:0:12} ..." "commit=${_pre_head:0:12}"
  # Do NOT swallow a failed reset with `|| true`. This rollback runs when
  # a destructive subtree FF has already mangled the tree; if the rescue
  # reset itself fails (corrupt / gc'd / empty / bogus pre_head), the user
  # must hear the truth -- a still-broken tree -- not a reassuring
  # 'restored' message they might push damage on top of.
  if ! git reset --hard "${_pre_head}" >/dev/null 2>&1; then
    _log_err upgrade upgrade_rollback_failed "display=rollback FAILED -- could not reset to ${_pre_head:0:12}; manual recovery required (working tree is NOT restored)." "commit=${_pre_head:0:12}"
    exit 1
  fi
  _error "upgrade aborted; repo restored to pre-upgrade state"
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
  # Newest STABLE tag on the upstream remote, or "" when the remote cannot
  # be reached or carries no vX.Y.Z tag. `--sort=-v:refname` puts the
  # newest first, so the first match wins; rc / pre-release tags do not
  # match the pattern and are skipped.
  #
  # The scan is in-shell on purpose. It used to be
  # `git ls-remote ... | grep -oP ... | head -1 | sed ...`: `head -1`
  # closes the pipe after one line, the `grep -oP` still writing takes
  # SIGPIPE and exits 141, `pipefail` promotes that to the pipeline's
  # status, and under the caller's `set -e` the bare assignment killed the
  # script before _check's `_log` lines ran. `|| true` stopped the abort,
  # but by discarding the status -- including a genuine `git` failure --
  # and left the quieter defect in place: an EMPTY answer that reads as
  # "no newer release" when there is one.
  #
  # Nothing below can be killed by a reader that stopped reading, because
  # there is no reader: no pipe, no early exit, no status that depends on
  # how two processes were scheduled. An unreachable remote still yields
  # "", which _check reports as `Could not fetch ...` with the remote
  # named -- the one loud error this path has always had. Parsing the ref
  # in-shell also drops the `grep -oP` PCRE dependency, which does not
  # exist on a BSD / macOS host.
  local _line _ref _result=""
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ -n "${_result}" ]]; then
      continue
    fi
    # `git ls-remote` prints "<sha><TAB><ref>". Strip through the last run
    # of whitespace rather than a literal tab: the replaced `grep -oP`
    # matched the ref anywhere on the line, so anything that separates the
    # two fields has to keep working. A peeled `refs/tags/vX.Y.Z^{}` line
    # fails the anchored match and is skipped, as it was before.
    _ref="${_line##*[[:space:]]}"
    if [[ "${_ref}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      _result="${_ref#refs/tags/}"
    fi
  done < <(git ls-remote --tags --sort=-v:refname "${TEMPLATE_REMOTE}")
  printf '%s' "${_result}"
}

# ── Semver comparison ────────────────────────────────────────────────────────
#
# SemVer §11 says a pre-release version has LOWER precedence than the
# associated normal version (rc1 < final). GNU `sort -V` orders them
# the OTHER way (final < rc1, treats `-` as "less than empty"), so we
# can't just delegate. The wrong ordering causedonce
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
  ${TEMPLATE_REL}/.version manually and re-run the upgrade."
    fi
  fi

  # Pre-flight safety checks. Any failure exits non-zero without
  # touching the working tree.
  _require_git_identity
  _require_clean_merge_state

  # Relocate a legacy per-repo setup.conf override to the repo-root
  # .setup.conf before anything else touches the tree, committing the
  # move so the subtree pull below still sees a clean tree. The old path
  # is spelled out in _migrate_legacy_setup_conf, the one block allowed to
  # name it (see the stale-path-lint markers there).
  _migrate_legacy_setup_conf "${REPO_ROOT}"

  # Retire the stale devel-scoped `[lifecycle] restart = no` the old
  # template seeded into every repo. Must run BEFORE the pull: the
  # pre-pull vendored template is what tells this migration whether the
  # upgrade crosses the rescope.
  _migrate_lifecycle_restart_default "${REPO_ROOT}"

  # Snapshot HEAD so the post-pull integrity check can roll back if
  # git-subtree corrupts the tree. Captured AFTER the setup.conf
  # relocation commit so a rollback preserves the migration.
  local _pre_head
  _pre_head="$(git rev-parse HEAD)"

  _log "Upgrading: ${local_ver} → ${target_ver}"

  # Snapshot the pre-pull tree hash of ${TEMPLATE_REL}/dist/config so we can
  # tell the user if their seeded <repo>/config is now out of sync with
  # the upstream baseline. Git tree hashes are stable and cheap (no blob
  # compare); if HEAD has no ${TEMPLATE_REL}/dist/config yet (initial setup),
  # leave _pre_config_hash empty.
  local _pre_config_hash=""
  # --verify: print the resolved hash on success, print nothing on
  # failure. Without it, git's default mode echoes the unresolved ref
  # back to stdout for unknown paths, which would be mistaken for a
  # hash later by _warn_config_drift.
  _pre_config_hash="$(git rev-parse --verify "HEAD:${TEMPLATE_REL}/dist/config" 2>/dev/null || true)"

  # Snapshot pre-pull setup.conf hash too. Path is the location
  # ${TEMPLATE_REL}/dist/.setup.conf. If the upstream baseline
  # changed, the user may want to copy new sections / keys into their
  # per-repo setup.conf override ('s 2-file model makes this a
  # manual merge — we never overwrite the user's file).
  local _pre_setup_conf_hash=""
  _pre_setup_conf_hash="$(git rev-parse --verify "HEAD:${TEMPLATE_REL}/dist/.setup.conf" 2>/dev/null || true)"

  # Step 1: subtree pull
  _log "Step 1/5: git subtree pull"
  git subtree pull --prefix="${TEMPLATE_REL}" \
    "${TEMPLATE_REMOTE}" "${target_ver}" --squash \
    -m "chore: upgrade ${TEMPLATE_REL} subtree to ${target_ver}"

  # Step 2: post-pull integrity check (rolls back on corruption)
  _log "Step 2/5: verify ${TEMPLATE_REL}/ subtree integrity"
  _verify_subtree_intact "${_pre_head}" "${target_ver}"

  # Step 3: re-run init.sh to sync symlinks (in case template structure changed)
  _log "Step 3/5: re-run init.sh to sync symlinks"
  # when upgrading from <v0.30.0, init.sh's stale-removal loop
  # migrates the seven root *.sh symlinks into the script/ subfolder.
  _log "  (init.sh migrates root *.sh -> script/*.sh on upgrades from pre-v0.30.0)"
  "./${TEMPLATE_REL}/dist/script/base/init.sh"

  # Step 4: update main.yaml @tag references
  _log "Step 4/5: update workflow @tag references"
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

  # Step 5: heal downstream Dockerfile / entrypoint drift via the declarative
  # migration list (folds facet B). Each base contract change used
  # to grow another one-off sed here (the lib-copy split, the
  # wrapper-copy move); they have all moved into lib/dockerfile_migrate.sh as
  # an ordered, data-driven {detect, transform} table. upgrade.sh now just
  # sources the lib and calls the dispatcher: each migration auto-applies
  # (idempotently) where its shape is detected and SKIPs (warn, never
  # force-rewrite) where structure is missing or ambiguous. Adding the next
  # fanout breakage is a new {detect, transform} pair in the lib, not another
  # branch here.
  _log "Step 5/5: apply Dockerfile/entrypoint migrations (#567 / #579)"
  local _dockerfile="${REPO_ROOT}/Dockerfile"
  # shellcheck disable=SC1091
  source "${SUBTREE_ROOT}/dist/script/docker/lib/dockerfile_migrate.sh"
  apply_migrations "${_dockerfile}"
  # Stage any files the migrations rewrote (Dockerfile + the sibling
  # entrypoint, when present) so they land in the same commit below.
  [[ -f "${_dockerfile}" ]] && git add "${_dockerfile}"
  [[ -f "${REPO_ROOT}/script/entrypoint.sh" ]] && git add "${REPO_ROOT}/script/entrypoint.sh"

  # Step 3 ran init.sh which (re-)synced .gitignore via lib/gitignore.sh
  # and `git rm --cached`-ed any tracked-but-now-derived artifacts
  # The .gitignore mutation is unstaged; the rm is index-staged.
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
  # afterwards) against the new .base/dist/config/. Silent when the
  # baseline didn't change or there was no prior baseline.
  _warn_config_drift "${_pre_config_hash}"

  # Same pattern for .base/dist/.setup.conf: the user's per-repo
  # .setup.conf is the override file (committed, never overwritten by
  # template upgrades). When the upstream .base/dist/.setup.conf adds new
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
# When the upstream ${TEMPLATE_REL}/dist/config/ tree changed during this
# pull, print a WARNING pointing the user at the diff so they can merge
# into their <repo>/config/ manually. Never fails the upgrade (config is
# user-owned — we only report, not force).
_warn_config_drift() {
  local _pre="${1:-}"
  local _post
  _post="$(git rev-parse --verify "HEAD:${TEMPLATE_REL}/dist/config" 2>/dev/null || true)"
  [[ -z "${_post}" ]] && return 0         # no config in new subtree
  [[ "${_pre}" == "${_post}" ]] && return 0   # unchanged
  _log ""
  _log "WARNING: ${TEMPLATE_REL}/dist/config/ changed upstream since the last pull."
  _log "         Your <repo>/config/ is user-owned and was NOT updated."
  _log "         Review the diff and port any upstream changes you want:"
  _log ""
  _log "           diff -ruN ${TEMPLATE_REL}/dist/config config"
  if [[ -n "${_pre}" ]]; then
    _log ""
    _log "         Upstream-only diff (what moved in ${TEMPLATE_REL}/dist/config/):"
    _log "           git diff ${_pre:0:12}..${_post:0:12} -- ${TEMPLATE_REL}/dist/config"
  fi
}

# _warn_setup_conf_drift <pre_pull_blob_hash>
#
# sibling of _warn_config_drift. <repo>/.setup.conf
# (path) is the user-owned override file; this script never
# rewrites it. When the upstream template-side setup.conf changes (new
# sections, new keys, default tweaks), surface a pointer to the diff so
# the user can hand-merge any upstream additions they want into their
# override. Silent on no change.
_warn_setup_conf_drift() {
  local _pre="${1:-}"
  local _post
  _post="$(git rev-parse --verify "HEAD:${TEMPLATE_REL}/dist/.setup.conf" 2>/dev/null || true)"
  [[ -z "${_post}" ]] && return 0
  [[ "${_pre}" == "${_post}" ]] && return 0
  _log ""
  _log "WARNING: ${TEMPLATE_REL}/dist/.setup.conf changed upstream since the last pull."
  _log "         Your .setup.conf is the user override and was NOT updated."
  _log "         Review the diff and copy any new sections / keys you want:"
  _log ""
  _log "           diff -u ${TEMPLATE_REL}/dist/.setup.conf .setup.conf"
  if [[ -n "${_pre}" ]]; then
    _log ""
    _log "         Upstream-only diff (what moved in ${TEMPLATE_REL}/dist/.setup.conf):"
    _log "           git diff ${_pre:0:12}..${_post:0:12} -- ${TEMPLATE_REL}/dist/.setup.conf"
  fi
}

# ── Help ─────────────────────────────────────────────────────────────────────

_usage() {
  cat >&2 <<EOF
Usage: ./${TEMPLATE_REL}/dist/script/base/upgrade.sh [VERSION|--check|--gen-conf]
       (or, preferred: just base upgrade [VERSION])

Upgrade ${TEMPLATE_REL} subtree to the latest (or specified) version.

Arguments:
  VERSION       Target version (e.g. v0.5.0). Defaults to latest tag.
  --check       Check if an update is available (no changes made)
  --gen-conf    Copy ${TEMPLATE_REL}/dist/.setup.conf to
                <repo>/.setup.conf for per-repo overrides
                (delegates to init.sh --gen-conf)
  --lang LANG   Message language (en|zh-TW|zh-CN|ja; default: auto-detect
                from SETUP_LANG / \$LANG)
  -h, --help    Show this help

Examples:
  just base upgrade                                          # upgrade to latest
  just base upgrade v0.5.0                                   # specific version
  just base update                                           # check only
  ./${TEMPLATE_REL}/dist/script/base/upgrade.sh        # raw: latest
EOF
  exit 0
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  _transcript_begin  # capture this run's output (no-op if disabled)

  # upgrade.sh is a human-facing `base` namespace recipe, so it
  # accepts --lang and honors SETUP_LANG/$LANG via i18n.sh (sourced by
  # _lib.sh). Its own messages are English-only pending the localized pass
  # --lang is validated here so the flag is accepted, not an error,
  # uniformly with the docker wrappers. Strip --lang <code> from argv
  # before the positional dispatch below.
  local _LANG
  _resolve_lang _LANG
  local -a _args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "upgrade"
        shift 2
        ;;
      *) _args+=("$1"); shift ;;
    esac
  done
  set -- "${_args[@]+"${_args[@]}"}"

  case "${1:-}" in
    -h|--help) _usage ;;
  esac

  # Refuse to run inside the base template source itself (ADR-00000011
  # sec.8). A vendored `.base/` subtree never carries `.git`; the base
  # checkout/worktree does, so `.git` at the resolved subtree root means
  # "this is the template source, not a consumer" -- proceeding would
  # subtree-pull into base's PARENT dir. After --help (which must work
  # anywhere), before any mutation. Same helper init.sh uses.
  _assert_not_template_source "${SUBTREE_ROOT}" upgrade || exit 1

  [[ ! -d "${TEMPLATE_REL}" ]] && \
    _error "${TEMPLATE_REL}/ not found. Run from repo root."

  case "${1:-}" in
    --check) _check ;;
    --gen-conf) "./${TEMPLATE_REL}/dist/script/base/init.sh" --gen-conf ;;
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
