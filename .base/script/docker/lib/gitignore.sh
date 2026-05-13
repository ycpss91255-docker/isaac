#!/usr/bin/env bash
# lib/gitignore.sh - Canonical .gitignore entries + sync/untrack helpers.
#
# Issue #172: every release cycle adds new derived artifacts (compose.yaml,
# .env.bak, coverage/, ...). Without sync, downstream repos accumulate
# drift and end up tracking files they shouldn't. This lib is the single
# source of truth, sourced by init.sh (new-repo + existing-repo paths)
# and consumed indirectly by upgrade.sh through init.sh.

# _canonical_gitignore_entries
#   Print the canonical .gitignore set, one entry per line. Order is
#   stable so consumers can diff outputs across versions.
#
#   Add new entries here when the template introduces another derived
#   artifact, then bump the next release. Downstreams pick it up via
#   `make upgrade` -> ./template/upgrade.sh -> init.sh resync chain.
_canonical_gitignore_entries() {
  cat <<'EOF'
.env
.env.bak
compose.yaml
setup.conf.bak
setup.conf.local
coverage/
.Dockerfile.generated
EOF
}

# _sync_gitignore <path>
#   Append canonical entries that are missing from <path>, preserving
#   user-defined lines and any pre-existing canonical lines (no
#   duplicates, no reordering, no removals).
#
#   On first sync of a fresh repo the appended block is preceded by a
#   `# managed by template (do not remove)` comment so future readers
#   know not to delete the entries. The comment is only added once;
#   subsequent syncs that need to add a new entry append it without a
#   second comment.
#
#   Idempotent: running twice in a row never modifies the file the
#   second time.
_sync_gitignore() {
  local _path="$1"
  local -a _missing=()
  local _entry

  while IFS= read -r _entry; do
    [[ -z "${_entry}" ]] && continue
    if [[ ! -f "${_path}" ]] || ! grep -qxF "${_entry}" "${_path}"; then
      _missing+=("${_entry}")
    fi
  done < <(_canonical_gitignore_entries)

  if (( ${#_missing[@]} == 0 )); then
    return 0
  fi

  if [[ ! -f "${_path}" ]]; then
    : > "${_path}"
  fi

  # Ensure file ends with newline so the appended entries don't get
  # concatenated onto the user's last line. Skip on empty file (nothing
  # to terminate).
  if [[ -s "${_path}" ]]; then
    local _last
    _last="$(tail -c 1 -- "${_path}")"
    if [[ "${_last}" != $'\n' ]]; then
      printf '\n' >> "${_path}"
    fi
  fi

  # Marker comment added only if absent — keeps re-syncs from stacking
  # comments on every release.
  if ! grep -q '^# managed by template' "${_path}"; then
    printf '# managed by template (do not remove)\n' >> "${_path}"
  fi

  printf '%s\n' "${_missing[@]}" >> "${_path}"
}

# _untrack_canonical_in_repo <repo_root>
#   For each canonical entry that's still git-tracked under <repo_root>,
#   run `git rm --cached`. Working tree is preserved — the file just
#   stops being tracked, so the next commit drops it from history's
#   active set and `setup.sh`'s regen no longer pollutes `git status`.
#
#   Heals the 15-repo drift documented in #172 (compose.yaml tracked
#   despite being a v0.9.0+ derived artifact) without requiring a
#   separate per-repo PR.
#
#   No-op when:
#     - <repo_root> is not a git repo
#     - no canonical entry matches a tracked path
#   Idempotent: re-running after the entries are gone is silent.
_untrack_canonical_in_repo() {
  local _repo="$1"
  if ! git -C "${_repo}" rev-parse --git-dir >/dev/null 2>&1; then
    return 0
  fi
  local _entry _path
  while IFS= read -r _entry; do
    [[ -z "${_entry}" ]] && continue
    _path="${_entry%/}"
    # ls-files emits matching tracked paths; empty output means nothing
    # to untrack. -z guard avoids running `git rm` on empty pathspec.
    if [[ -n "$(git -C "${_repo}" ls-files -- "${_path}" 2>/dev/null)" ]]; then
      git -C "${_repo}" rm --cached -r --quiet -- "${_path}" >/dev/null 2>&1 || true
    fi
  done < <(_canonical_gitignore_entries)
}
