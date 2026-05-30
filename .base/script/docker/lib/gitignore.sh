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
#   `make upgrade` -> ./.base/upgrade.sh -> init.sh resync chain.
_canonical_gitignore_entries() {
  cat <<'EOF'
.env
.env.bak
runtime.env
compose.yaml
setup.conf.bak
setup.conf.local
coverage/
.Dockerfile.generated
.docker.xauth
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

# _sync_logging_gitignore <base_path>
#
# Ensure the per-repo .gitignore covers every relative `local_path`
# declared in setup.conf [logging] / [logging.<svc>], so users don't
# accidentally commit container logs. Absolute paths and `~/...` are
# skipped -- gitignore patterns apply only inside the repo.
#
# Entries live inside a managed block introduced by a stable marker
# comment. The block scope is the marker line plus any immediately-
# following lines that look like a gitignore dir entry (`/<path>/`);
# the first non-matching line ends the block. On each sync we rewrite
# the block to exactly the current desired entries, which prunes
# stale entries left over from prior local_path values (#390). The
# marker comment itself is dropped when the block ends up empty so a
# sync with no logging local_path leaves no trace. Lines outside the
# managed block are user-owned and never touched.
#
# Moved from script/docker/wrapper/setup.sh's apply path in #402
# (PR-B). The runtime sync used to fire on every setup.sh apply call;
# the new lifecycle ties .gitignore updates to init.sh / upgrade.sh
# so the file stays consistent across template versions without
# needing a wrapper invocation between setup.conf edit and the next
# build.
_sync_logging_gitignore() {
  local _base="${1:?}"
  local _gitignore="${_base%/}/.gitignore"
  local _marker='# managed by template: [logging] local_path (do not remove)'

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

  # Split existing content into pre-marker / post-marker, dropping
  # the marker block itself (re-emitted below from _desired).
  local -a _pre=() _post=()
  local _in_block=0 _seen_marker=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_seen_marker}" -eq 0 && "${_line}" == "${_marker}" ]]; then
      _seen_marker=1
      _in_block=1
      continue
    fi
    if [[ "${_in_block}" -eq 1 ]]; then
      if [[ "${_line}" =~ ^/.+/$ ]]; then
        continue
      fi
      _in_block=0
      _post+=("${_line}")
      continue
    fi
    if [[ "${_seen_marker}" -eq 1 ]]; then
      _post+=("${_line}")
    else
      _pre+=("${_line}")
    fi
  done < "${_gitignore}"

  # Compose output: pre / marker+desired (if any) / post. When there
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
      printf '%s\n' "${_marker}"
      printf '%s\n' "${_desired[@]}"
    fi
    if (( ${#_post[@]} > 0 )); then
      printf '%s\n' "${_post[@]}"
    fi
  } > "${_gitignore}"
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
