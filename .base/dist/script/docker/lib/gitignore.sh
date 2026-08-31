#!/usr/bin/env bash
# lib/gitignore.sh - Canonical .gitignore entries + sync/untrack helpers.
#
# every release cycle adds new derived artifacts (compose.yaml,
# .env.bak, coverage/, ...). Without sync, downstream repos accumulate
# drift and end up tracking files they shouldn't. This lib is the single
# source of truth, sourced by init.sh (new-repo + existing-repo paths)
# and consumed indirectly by upgrade.sh through init.sh.

# _sync_logging_gitignore refuses a malformed managed block and reports
# the migration of a legacy one, so this lib needs the logger even when a
# consumer sourced it on its own (init.sh gets it via _lib.sh; the unit
# specs source this file directly). log.sh is self-guarding, so the
# double source is free -- same shape as schema.sh pulling in _tui_conf.sh.
_gitignore_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/log.sh
source "${_gitignore_lib_dir}/log.sh"
unset _gitignore_lib_dir

# _canonical_gitignore_entries
#   Print the canonical .gitignore set, one entry per line. Order is
#   stable so consumers can diff outputs across versions.
#
#   Add new entries here when the template introduces another derived or
#   machine-local artifact, then bump the next release. `.setup.conf.local`
#   is the one member that is NOT derived: it is the operator's per-worktree
#   config override, hand-authored and never regenerated, and it is here
#   because it must never be committed -- an untracked layer that got
#   committed would silently become everyone's config. Downstreams pick it up via
#   `just base upgrade` -> ./.base/dist/script/base/upgrade.sh ->
#   init.sh resync chain.
_canonical_gitignore_entries() {
  cat <<'EOF'
.env
.env.generated
.env.bak
compose.yaml
.setup.conf.bak
.setup.conf.local
coverage/
.Dockerfile.generated
.docker.xauth
log/
/deploy/
EOF
}

# _canonical_dockerignore_entries
#   Print the canonical .dockerignore derived-artifact set, one entry per
#   line. This is exactly _canonical_gitignore_entries: a derived artifact
#   not worth committing is not worth shipping in the Docker build context
#   either, so the two share a single source and never drift. Per-repo
#   build-context specifics (script/ test/ config/, .git, docs) are
#   hand-maintained ABOVE the managed block and are never touched by the
#   sync. New derived artifacts are added in _canonical_gitignore_entries
#   and propagate here automatically (this is also how will land
#   `log/` in both files from one edit).
_canonical_dockerignore_entries() {
  _canonical_gitignore_entries
}

# _retired_gitignore_entries
#   Print the entries the template used to emit and no longer does, one per
#   line. Kept as a list rather than deleted outright so the sync can RETRACT
#   what it once wrote instead of leaving a dead line sitting under a
#   `# managed by template (do not remove)` marker -- a marker that reads as
#   a promise the entry still means something.
#
#   Currently EMPTY, and that is a state to be careful with rather than a
#   dead function. Its one member was `.setup.conf.local`: retired while
#   nothing read the file it named, then UN-retired when the per-worktree
#   override layer restored the mechanism. It is canonical again above.
#
#   The two lists are exclusive by construction, and gitignore_spec asserts
#   it: an entry in both is retracted and re-appended on every single sync,
#   forever, in every downstream at once -- a repo that deletes the line it
#   just added. Before retiring an entry, remove it from
#   _canonical_gitignore_entries in the same edit.
#
#   Shared by .gitignore and .dockerignore for the same reason the canonical
#   set is: what one retracts, the other retracts.
_retired_gitignore_entries() {
  # An empty here-doc rather than a bare `return`, so the emitter's contract
  # (one entry per line on stdout) holds for the empty case too.
  cat <<'EOF'
EOF
}

# _prune_retired_entries <path>
#   Delete every _retired_gitignore_entries line from <path>'s MANAGED half
#   -- the lines below the `# managed by template` marker, which is the half
#   the template owns. A retired entry the user wrote above the marker is
#   theirs and is left alone: the template retracts only what the template
#   added.
#
#   No-op when the file or the marker is absent (nothing is claimed as
#   managed), and idempotent by construction.
_prune_retired_entries() {
  local _path="$1"
  [[ -f "${_path}" ]] || return 0

  # Find the marker by reading the file in-shell. It used to be
  # `grep -n ... | head -1 | cut -d: -f1 || true`, which had two problems
  # at once. A file with no marker makes grep exit 1, and under the
  # callers' `set -euo pipefail` that aborts init.sh instead of taking the
  # "nothing is managed here" branch below -- which is what the `|| true`
  # was for. But `head -1` also stops reading after one line, so a grep
  # still writing takes SIGPIPE and the pipeline goes 141, and `|| true`
  # discards that just as silently: `cut` printed nothing, the marker read
  # as ABSENT, and a retired entry stayed in the file the template was
  # trying to retract it from.
  #
  # A loop over the file has no status to suppress and no reader to leave
  # early. `|| [[ -n ... ]]` so a final line with no trailing newline is
  # still counted -- the marker could be it.
  local _marker_ln="" _line _lineno=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    if [[ -z "${_marker_ln}" && "${_line}" == '# managed by template'* ]]; then
      _marker_ln="${_lineno}"
    fi
  done < "${_path}"
  [[ -n "${_marker_ln}" ]] || return 0

  local -a _retired=()
  local _entry
  while IFS= read -r _entry; do
    [[ -n "${_entry}" ]] && _retired+=("${_entry}")
  done < <(_retired_gitignore_entries)
  (( ${#_retired[@]} > 0 )) || return 0

  local _tmp
  _tmp="$(mktemp "${_path}.XXXXXX")" || return 0
  if awk -v marker="${_marker_ln}" -v retired="$(printf '%s\n' "${_retired[@]}")" '
      BEGIN { _n = split(retired, _r, "\n") }
      {
        if (NR > marker) {
          for (_i = 1; _i <= _n; _i++) {
            if (_r[_i] != "" && $0 == _r[_i]) { next }
          }
        }
        print
      }
    ' "${_path}" > "${_tmp}"; then
    mv -f -- "${_tmp}" "${_path}"
  else
    rm -f -- "${_tmp}"
  fi
}

# _sync_managed_entries <path> <emitter>
#   Shared mechanism behind _sync_gitignore / _sync_dockerignore: append
#   the canonical entries printed by <emitter> that are missing from
#   <path>, preserving user-defined lines and any pre-existing canonical
#   lines (no duplicates, no reordering, no removals).
#
#   On first sync of a fresh file the appended block is preceded by a
#   `# managed by template (do not remove)` comment so future readers
#   know not to delete the entries. The comment is added only once;
#   subsequent syncs that add a new entry append it without a second
#   comment.
#
#   Retraction is the one exception to "no removals": entries the template
#   has retired (_retired_gitignore_entries) are pruned from the managed
#   half first, so a line the template stopped shipping stops being
#   advertised in every repo that already has it, not just in new ones.
#
#   Idempotent: running twice in a row never modifies the file the
#   second time.
_sync_managed_entries() {
  local _path="$1"
  local _emitter="$2"
  local -a _missing=()
  local _entry

  # Retract before adding: the prune must run even when nothing is missing,
  # which is the common case for an up-to-date repo.
  _prune_retired_entries "${_path}"

  while IFS= read -r _entry; do
    [[ -z "${_entry}" ]] && continue
    if [[ ! -f "${_path}" ]] || ! grep -qxF "${_entry}" "${_path}"; then
      _missing+=("${_entry}")
    fi
  done < <("${_emitter}")

  if (( ${#_missing[@]} == 0 )); then
    return 0
  fi

  if [[ ! -f "${_path}" ]]; then
    : > "${_path}"
  fi

  # Ensure file ends with newline so the appended entries don't get
  # concatenated onto the user's last line. Skip on empty file (nothing
  # to terminate).
  #
  # The `; printf x` sentinel is load-bearing: command substitution
  # strips EVERY trailing newline, so a bare `$(tail -c 1 ...)` yields
  # the empty string for both "ends with a newline" and "is a lone
  # newline". Appending a sentinel byte inside the substitution keeps
  # the newline observable, so the guard actually guards instead of
  # unconditionally appending a blank line.
  if [[ -s "${_path}" ]]; then
    local _last
    _last="$(tail -c 1 -- "${_path}"; printf 'x')"
    if [[ "${_last}" != $'\nx' ]]; then
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

# _sync_gitignore <path>
#   Append the canonical .gitignore set (the entries from
#   _canonical_gitignore_entries) that are missing from <path>. See
#   _sync_managed_entries for the mechanics.
_sync_gitignore() {
  _sync_managed_entries "$1" _canonical_gitignore_entries
}

# _sync_dockerignore <path>
#   Append the canonical .dockerignore derived-artifact set that is
#   missing from <path>, preserving the hand-maintained build-context
#   lines above the managed block. See _sync_managed_entries.
_sync_dockerignore() {
  _sync_managed_entries "$1" _canonical_dockerignore_entries
}

# _sync_logging_gitignore <base_path>
#
# Ensure the per-repo .gitignore covers every relative `local_path`
# declared in setup.conf [logging] / [logging.<svc>], so users don't
# accidentally commit container logs. Absolute paths and `~/...` are
# skipped -- gitignore patterns apply only inside the repo.
#
# Entries live inside a managed block delimited by an explicit BEGIN /
# END marker pair, the same allow-begin / allow-end region shape the
# stale-setup-conf and home-literal lints use. Only lines STRICTLY
# between the two markers are template-owned; the sync rewrites them to
# exactly the current desired entries, which prunes stale entries left
# over from prior local_path values. Both markers are dropped when the
# block ends up empty, so a sync with no logging local_path leaves no
# trace. Lines outside the managed block are user-owned and never
# touched -- including lines BELOW it, which is where a user naturally
# appends a new rule.
#
# A begin marker with no end marker (or an end marker with no begin) is
# a malformed block: the sync REFUSES, leaving the file byte-identical,
# rather than guessing where the block stops. Guessing is exactly what
# the previous shape heuristic did, and it silently deleted user rules.
#
# Migration. Templates before this change wrote a begin marker only, so
# a downstream .gitignore can carry an unterminated legacy block that is
# not corruption. It is recognised by its own distinct marker text and
# migrated in place: the sync consumes the contiguous run of `/<dir>/`
# lines below it that the block itself would emit (i.e. lines present in
# the CURRENT desired set) and re-emits the block with the new BEGIN /
# END pair. Anything else below the legacy marker -- a user rule, or the
# newer canonical `/deploy/` entry _sync_gitignore appends immediately
# before this sync runs in the same init pass -- ends the legacy block
# and is handed back as user-owned content, with a warning naming the
# `/<dir>/` lines that changed hands. That is deliberately one-directional:
# leaving a stale ignore line behind is a cosmetic wart, deleting a user's
# rule is data loss. After one sync the block is terminated and the legacy
# path is never taken again.
#
# Moved from script/docker/wrapper/setup.sh's apply path in
# (PR-B). The runtime sync used to fire on every setup.sh apply call;
# the new lifecycle ties .gitignore updates to init.sh / upgrade.sh
# so the file stays consistent across template versions without
# needing a wrapper invocation between setup.conf edit and the next
# build.
_sync_logging_gitignore() {
  local _base="${1:?}"
  local _gitignore="${_base%/}/.gitignore"
  local _marker_begin='# managed by template: [logging] local_path begin (do not remove)'
  local _marker_end='# managed by template: [logging] local_path end (do not remove)'
  # The pre-bounded marker older templates wrote. Recognised for the
  # one-time migration only; never emitted again.
  local _marker_legacy='# managed by template: [logging] local_path (do not remove)'

  local _global="" _per_svc=""
  _collect_logging "${_base}" _global _per_svc

  local -a _candidates=()
  local _line _k _v
  if [[ -n "${_global}" ]]; then
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      _k="${_line%%=*}"
      _v="${_line#*=}"
      [[ "${_k}" == "local_path" && -n "${_v}" ]] && _candidates+=("${_v}")
    done <<< "${_global}"
  fi
  if [[ -n "${_per_svc}" ]]; then
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      # per_svc entry shape: "<svc>:KEY=VALUE"
      local _kv="${_line#*:}"
      _k="${_kv%%=*}"
      _v="${_kv#*=}"
      [[ "${_k}" == "local_path" && -n "${_v}" ]] && _candidates+=("${_v}")
    done <<< "${_per_svc}"
  fi

  # Filter: keep only relative paths; strip leading `./`, trailing `/`.
  local -a _entries=()
  local _p
  for _p in "${_candidates[@]}"; do
    [[ "${_p}" == /* ]] && continue
    [[ "${_p}" == "~"* ]] && continue
    _p="${_p#./}"
    while [[ "${_p}" == */ ]]; do
      _p="${_p%/}"
    done
    [[ -z "${_p}" ]] && continue
    # gitignore: leading `/` anchors to repo root; trailing `/` marks
    # it as a directory so it matches the dir + its contents.
    _entries+=("/${_p}/")
  done

  # Dedup.
  local -A _seen=()
  local -a _desired=()
  for _p in "${_entries[@]}"; do
    [[ -n "${_seen[${_p}]:-}" ]] && continue
    _seen[${_p}]=1
    _desired+=("${_p}")
  done

  # If file doesn't exist and nothing desired, leave it absent.
  if [[ ! -f "${_gitignore}" ]]; then
    (( ${#_desired[@]} == 0 )) && return 0
    : > "${_gitignore}"
  fi

  # Split existing content into pre-block / post-block, dropping the
  # managed block itself (re-emitted below from _desired). States:
  #   outside  not inside any managed block
  #   managed  between the BEGIN and END markers -- template-owned
  #   legacy   below a pre-bounded marker -- consume only what the
  #            block itself would have emitted (see the header note)
  local -a _pre=() _post=() _orphans=()
  local _state="outside" _seen_marker=0 _migrated=0 _begin_line=0 _lineno=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))

    if [[ "${_state}" == "managed" ]]; then
      # Only the END marker closes the block; everything before it is
      # template-owned and dropped.
      [[ "${_line}" == "${_marker_end}" ]] && _state="outside"
      continue
    fi

    if [[ "${_state}" == "legacy" ]]; then
      if [[ "${_line}" =~ ^/.+/$ && -n "${_seen[${_line}]:-}" ]]; then
        continue
      fi
      _state="outside"
      [[ "${_line}" =~ ^/.+/$ ]] && _orphans+=("${_line}")
      _post+=("${_line}")
      continue
    fi

    # state: outside
    if [[ "${_line}" == "${_marker_begin}" || "${_line}" == "${_marker_legacy}" ]]; then
      if (( _seen_marker )); then
        _log_err init gitignore_managed_block_invalid \
          "display=${_gitignore}:${_lineno}: a second [logging] local_path managed block begins here (the first began at line ${_begin_line}). Keep exactly one block, then re-run the sync." \
          "path=${_gitignore}" "line=${_lineno}"
        return 1
      fi
      _seen_marker=1
      _begin_line="${_lineno}"
      if [[ "${_line}" == "${_marker_legacy}" ]]; then
        _state="legacy"
        _migrated=1
      else
        _state="managed"
      fi
      continue
    fi
    if [[ "${_line}" == "${_marker_end}" ]]; then
      _log_err init gitignore_managed_block_invalid \
        "display=${_gitignore}:${_lineno}: [logging] local_path end marker with no matching begin marker. Restore the begin marker or delete this line, then re-run the sync." \
        "path=${_gitignore}" "line=${_lineno}"
      return 1
    fi

    if (( _seen_marker )); then
      _post+=("${_line}")
    else
      _pre+=("${_line}")
    fi
  done < "${_gitignore}"

  # An unterminated BEGIN is corruption, not a legacy block (the legacy
  # marker is a different literal and always ends at EOF). Refuse loudly
  # and leave the file untouched rather than guess the block's extent.
  if [[ "${_state}" == "managed" ]]; then
    _log_err init gitignore_managed_block_invalid \
      "display=${_gitignore}:${_begin_line}: unterminated [logging] local_path managed block (no '${_marker_end}'). Restore the end marker, then re-run the sync. The file was NOT modified." \
      "path=${_gitignore}" "line=${_begin_line}"
    return 1
  fi

  # Compose output: pre / begin+desired+end (if any) / post. When there
  # is nothing desired and no prior marker existed, return early so
  # the file stays byte-identical.
  if (( ${#_desired[@]} == 0 && _seen_marker == 0 )); then
    return 0
  fi

  {
    if (( ${#_pre[@]} > 0 )); then
      printf '%s\n' "${_pre[@]}"
    fi
    if (( ${#_desired[@]} > 0 )); then
      printf '%s\n' "${_marker_begin}"
      printf '%s\n' "${_desired[@]}"
      printf '%s\n' "${_marker_end}"
    fi
    if (( ${#_post[@]} > 0 )); then
      printf '%s\n' "${_post[@]}"
    fi
  } > "${_gitignore}"

  if (( _migrated )); then
    _log_info init gitignore_managed_block_migrated \
      "display=${_gitignore}: migrated the [logging] local_path block to explicit begin/end markers." \
      "path=${_gitignore}"
    if (( ${#_orphans[@]} > 0 )); then
      _log_warn init gitignore_managed_block_orphans \
        "display=${_gitignore}: ${_orphans[*]} sat below the old unbounded [logging] local_path block but is not a current managed entry, so it was left in place (kept, not deleted) outside the new block. Delete any line there that the template used to manage." \
        "path=${_gitignore}" "entries=${_orphans[*]}"
    fi
  fi
}

# _untrack_canonical_in_repo <repo_root>
#   For each canonical entry that's still git-tracked under <repo_root>,
#   run `git rm --cached`. Working tree is preserved — the file just
#   stops being tracked, so the next commit drops it from history's
#   active set and `setup.sh`'s regen no longer pollutes `git status`.
#
#   Heals the 15-repo drift documented in (compose.yaml tracked
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
