#!/usr/bin/env bash
#
# sync-readme-hashes.sh - stamp every localized README section with the hash
# of the English section it was translated against, so a later English-side
# edit is detectable per SECTION instead of being silently absorbed.
#
# The English author changes nothing. The translator never types a hash:
# after updating a translation they run this generator and it computes the
# current English hash and writes it. Same model as the sibling
# sync-doc-counts.sh (derived figures are generated, not hand-maintained);
# drivers/readme_sync.sh is the read-only validating twin, the way
# check_test_md_drift.sh is for the doc counts.
#
# Usage:
#   ./script/test/sync-readme-hashes.sh              # stamp REPO_ROOT
#   ./script/test/sync-readme-hashes.sh <root>       # stamp <root>
#   ./script/test/sync-readme-hashes.sh --accept <id>[,<id>...]
#
# Idempotent: stamping an already-stamped tree rewrites the same bytes.
#
# ── The marker ───────────────────────────────────────────────────────────────
#
# A translated section carries, on the line immediately above its heading:
#
#   <!-- sync: <section-id> <english-hash> <translation-hash> -->
#   ## <translated heading>
#
# HTML comments do not render, so a reader sees nothing. A translator writes
# the id-only form `<!-- sync: <section-id> -->` once, by hand, and this
# generator fills in (and thereafter re-stamps) both hashes.
#
# ── Why BOTH sides are recorded ──────────────────────────────────────────────
#
# Recording only the English hash makes a re-stamp meaningless. "I updated
# the translation, then synced" and "I synced so the gate would stop
# complaining" write the same bytes, so the generator becomes a one-command
# way to bless exactly the drift it exists to catch -- and it did: two
# sections sat green over translations that had never been updated.
#
# The second field is the translation section's OWN hash, computed by the
# same algorithm over the translated heading and body. It turns an
# unanswerable question into an arithmetic one: if the English hash moved
# and the recorded translation hash still matches the translation on disk,
# nobody re-translated, and the generator REFUSES to move that section's
# English hash. The section stays unstamped, the lint stays red, and the
# refusal names the file, the line and the id.
#
# The refusal is per section, so it also covers the bulk case: a run that
# would move every hash at once with no translation-side change is refused
# once per section rather than passing as a single anonymous re-stamp.
#
# ── The reviewed no-op: --accept ─────────────────────────────────────────────
#
# An English typo fix genuinely needs no re-translation, and that has to
# stay one command rather than a three-language chore. `--accept <id>`
# (comma-separated or repeated) is that command: it says "I read the
# English change and the translation is still correct", per section, by
# name. It is deliberately NOT the default -- a bare re-stamp can no longer
# express it -- and it leaves the evidence in the tree, because the marker
# then shows an English hash that moved beside a translation hash that did
# not.
#
# A section that deliberately has NO translation is declared instead, once,
# anywhere in the file:
#
#   <!-- sync-skip: <section-id> -- <why> -->
#
# The three localized READMEs are abridged by design -- they do not carry
# every English section -- so "no marker" cannot mean "fine": an omission has
# to be either translated or declared. The generator never invents that
# decision (it would silence exactly the drift the guard exists to catch); it
# reports the unclaimed sections and leaves the choice to a human.
#
# Both marker forms must start at column 0 on a line of their own.
#
# ── Section identity ─────────────────────────────────────────────────────────
#
# The heading text differs per language, so the identity cannot be the
# heading. `<section-id>` is the GitHub anchor slug of the ENGLISH heading:
# lowercased, every character outside [a-z0-9 _-] dropped, each remaining
# space turned into a hyphen, leading/trailing hyphens trimmed. That is the
# same string README.md's own table of contents links to, so the id is
# already a published, human-checkable name -- "field-deployment-just-docker
# -setup-deploy", not an opaque number. Renaming an English heading changes
# its id: the guard then reports the stale id as UNKNOWN and the new one as
# MISSING, which is the correct outcome (a heading rename is a
# translation-affecting change).
#
# ── What exactly is hashed ───────────────────────────────────────────────────
#
# For an English section, the hash input is, in order:
#
#   1. the section's heading line, verbatim, with trailing whitespace removed;
#   2. the section's body -- every line after the heading up to (not
#      including) the next ATX heading of ANY level -- each line with
#      trailing whitespace removed, with leading and trailing blank lines
#      dropped.
#
# Those lines are joined with LF and terminated with a single LF. The hash is
# the first 12 hex characters of the SHA-256 of that byte string.
#
# The translation side uses the SAME input, over the translated heading and
# body, with one addition: sync / sync-skip marker lines are dropped. A
# section's body runs up to the next heading, so the next section's marker
# would otherwise fall inside this one's body and make every translation
# hash depend on its neighbour's -- a fixed point the generator could never
# reach.
#
# Deliberate consequences, stated rather than discovered later:
#   - a nested subsection is its own section; a parent's body stops at it, so
#     drift is reported at the sub-heading that actually changed;
#   - reflowing a paragraph or fixing a typo DOES change the hash (an English
#     edit marks the translations stale; the translator either re-translates
#     and re-runs this generator, or confirms the change needs no
#     re-translation with `--accept <id>` -- one command either way, an
#     accepted cost);
#   - trailing whitespace and the blank lines that pad a section do NOT change
#     it, so a whitespace-only sweep does not mark three files stale;
#   - lines inside fenced code blocks (``` / ~~~) are never headings, so the
#     shell comments in the README's fenced examples do not invent sections;
#   - editing translated prose changes the translation hash, so a translation
#     edit is itself a reason to re-run this generator; the lint reports the
#     un-re-run case rather than letting the record decay into a forgeable
#     "the translation moved" signal.
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# The English source, the translation directory and the translation glob, all
# repo-root-relative. The glob (rather than a fixed list) means a fourth
# language file is guarded the day it is added, with no edit here.
readonly _README_SYNC_SOURCE_REL='README.md'
readonly _README_SYNC_DIR_REL='doc/readme'
readonly _README_SYNC_GLOB='README.*.md'

# Hex characters of the SHA-256 kept in the marker. 12 is short enough to
# read in a diff and long enough that a collision is not a practical concern
# for a few dozen sections.
readonly _README_SYNC_HASH_LEN=12

# Marker grammar. Both anchor at column 0 and consume the whole line. Both
# hash groups are optional: a translator writes the id-only form and lets
# the generator stamp it, and a marker left over from the English-hash-only
# era still parses (with no translation record, which the lint reports as
# UNSTAMPED rather than mis-reading it as a translation that never moved).
# Capture groups: 1 = id, 3 = English hash, 5 = translation hash.
readonly _README_SYNC_MARKER_RE='^<!--[[:space:]]+sync:[[:space:]]+([A-Za-z0-9._-]+)([[:space:]]+([0-9a-f]+))?([[:space:]]+([0-9a-f]+))?[[:space:]]*-->$'
readonly _README_SYNC_SKIP_RE='^<!--[[:space:]]+sync-skip:[[:space:]]+([A-Za-z0-9._-]+)([[:space:]]+--[[:space:]]+.*)?-->$'

# An ATX heading outside a fenced block: 1-6 hashes, a space, a non-empty
# title. Used for both the English index and the "a marker sits above a
# heading" check.
readonly _README_SYNC_HEADING_RE='^(#{1,6})[[:space:]]+(.*[^[:space:]])[[:space:]]*$'
readonly _README_SYNC_FENCE_RE='^[[:space:]]*(```|~~~)'

# _readme_sync_err <message>... -- diagnostic to stderr. Block-redirected
# rather than a bare `printf ... >&2` because this is a standalone,
# log.sh-free CI tool inside lint_bare_stderr.sh's scan scope (same rationale
# class as check_test_md_drift.sh).
_readme_sync_err() {
  {
    printf 'sync-readme-hashes: %s\n' "$@"
  } >&2
}

# _readme_slug <heading-text> -- the GitHub anchor slug of an English heading.
_readme_slug() {
  local _slug="${1,,}"
  _slug="${_slug//[^a-z0-9 _-]/}"
  _slug="${_slug// /-}"
  while [[ "${_slug}" == -* ]]; do _slug="${_slug#-}"; done
  while [[ "${_slug}" == *- ]]; do _slug="${_slug%-}"; done
  printf '%s\n' "${_slug}"
}

# _readme_index <file> -- emit "<slug><TAB><hash>" for every section of an
# English-side markdown file, in document order. Duplicate slugs are emitted
# as-is; detecting the ambiguity is the caller's job (the generator has
# nothing useful to do about it, the lint reports it).
_readme_index() {
  local _lineno _hash _slug
  while IFS=$'\t' read -r _lineno _hash _slug; do
    printf '%s\t%s\n' "${_slug}" "${_hash}"
  done < <(_readme_sections "$1")
}

# _readme_sections <file> -- emit "<heading-lineno><TAB><hash><TAB><slug>"
# for every section of a markdown file, in document order. The line number
# is 1-based and names the HEADING line, so a caller that knows where a
# marker sits can look up the section directly beneath it without
# re-deriving the section boundaries.
#
# Used for both sides. On a translation the slug is meaningless -- a
# translated heading slugs to whatever ASCII residue it has, usually nothing
# -- and the caller keys on the line number instead; the hash is what
# matters. The slug goes LAST precisely because it can be empty: TAB is an
# IFS whitespace character, so a `read` over an empty middle field silently
# shifts every field after it.
#
# Sync / sync-skip marker lines are dropped from the hash input. A section's
# body runs up to the next heading, so the next section's marker would
# otherwise fall inside this section's body -- every translation hash would
# then depend on its neighbour's recorded hash, and stamping would have no
# fixed point.
_readme_sections() {
  local _file="$1"
  local -a _lines=()
  mapfile -t _lines < "${_file}"

  # extglob for the `%%+([[:space:]])` right-trim (no subshell per line);
  # saved/restored so sourcing this lib never leaks the option to a caller,
  # the same idiom sync-doc-counts.sh uses for globstar.
  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _n="${#_lines[@]}"
  local -a _hidx=() _hslug=()
  local _i _fence=0
  for (( _i = 0; _i < _n; _i++ )); do
    if [[ "${_lines[_i]}" =~ ${_README_SYNC_FENCE_RE} ]]; then
      _fence=$(( 1 - _fence ))
      continue
    fi
    [[ "${_fence}" -eq 1 ]] && continue
    if [[ "${_lines[_i]}" =~ ${_README_SYNC_HEADING_RE} ]]; then
      _hidx+=( "${_i}" )
      _hslug+=( "$(_readme_slug "${BASH_REMATCH[2]}")" )
    fi
  done

  local _j _k _end _head _hash _bline
  local -a _body=()
  for (( _j = 0; _j < ${#_hidx[@]}; _j++ )); do
    if (( _j + 1 < ${#_hidx[@]} )); then
      _end=$(( ${_hidx[_j+1]} - 1 ))
    else
      _end=$(( _n - 1 ))
    fi
    _head="${_lines[${_hidx[_j]}]%%+([[:space:]])}"
    _body=()
    for (( _k = _hidx[_j] + 1; _k <= _end; _k++ )); do
      _bline="${_lines[_k]%%+([[:space:]])}"
      [[ "${_bline}" =~ ${_README_SYNC_MARKER_RE} ]] && continue
      [[ "${_bline}" =~ ${_README_SYNC_SKIP_RE} ]] && continue
      _body+=( "${_bline}" )
    done
    while [[ "${#_body[@]}" -gt 0 && -z "${_body[0]}" ]]; do
      _body=( "${_body[@]:1}" )
    done
    while [[ "${#_body[@]}" -gt 0 && -z "${_body[-1]}" ]]; do
      unset '_body[-1]'
    done
    _hash="$(printf '%s\n' "${_head}" "${_body[@]}" \
      | sha256sum | cut -c "1-${_README_SYNC_HASH_LEN}")"
    printf '%s\t%s\t%s\n' \
      "$(( _hidx[_j] + 1 ))" "${_hash}" "${_hslug[_j]}"
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob
}

# _readme_file_markers <file> -- emit one TAB-separated record per marker
# found in a translation, in document order:
#
#   <lineno><TAB>sync|skip<TAB><id><TAB><recorded-en><TAB><recorded-tr><TAB><current-tr><TAB>yes|no
#
# <recorded-en> / <recorded-tr> are what the marker carries (`-` when the
# field is absent); <current-tr> is the hash of the translated section this
# marker actually sits above, computed now. The three together are what lets
# a caller tell "the translation was updated" from "the English hash was
# copied over" -- the distinction the guard could not previously make.
#
# The last field answers "is this marker immediately above a heading". All
# four are `-` for a skip declaration, which deliberately has no section to
# sit above.
_readme_file_markers() {
  local _file="$1"
  local -a _lines=()
  mapfile -t _lines < "${_file}"

  # Heading line number -> that section's own hash. Sourced from the same
  # extractor the English side uses, so "the translation moved" is measured
  # by exactly the algorithm that measures "the English moved", and fenced
  # pseudo-headings are excluded from both.
  local -A _sections=()
  local _sec_line _sec_hash _sec_slug
  while IFS=$'\t' read -r _sec_line _sec_hash _sec_slug; do
    _sections["${_sec_line}"]="${_sec_hash}"
  done < <(_readme_sections "${_file}")

  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _n="${#_lines[@]}"
  local _i _j _probe _id _en_hash _tr_hash _cur_hash _follow
  for (( _i = 0; _i < _n; _i++ )); do
    _probe="${_lines[_i]%%+([[:space:]])}"
    if [[ "${_probe}" =~ ${_README_SYNC_SKIP_RE} ]]; then
      printf '%s\tskip\t%s\t-\t-\t-\t-\n' "$(( _i + 1 ))" "${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "${_probe}" =~ ${_README_SYNC_MARKER_RE} ]]; then
      _id="${BASH_REMATCH[1]}"
      _en_hash="${BASH_REMATCH[3]:--}"
      _tr_hash="${BASH_REMATCH[5]:--}"
      _follow='no'
      _cur_hash='-'
      for (( _j = _i + 1; _j < _n; _j++ )); do
        [[ -z "${_lines[_j]%%+([[:space:]])}" ]] && continue
        if [[ -n "${_sections[$(( _j + 1 ))]+x}" ]]; then
          _follow='yes'
          _cur_hash="${_sections[$(( _j + 1 ))]}"
        fi
        break
      done
      printf '%s\tsync\t%s\t%s\t%s\t%s\t%s\n' \
        "$(( _i + 1 ))" "${_id}" "${_en_hash}" "${_tr_hash}" \
        "${_cur_hash}" "${_follow}"
    fi
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob
}

# _readme_translation_files <root> -- emit the localized README paths under
# <root>, sorted. Empty output means none were found; the caller decides
# whether that is an error (for the lint it is: a vacuous pass).
_readme_translation_files() {
  local _root="$1" _file
  local _nullglob_was_set=0
  shopt -q nullglob && _nullglob_was_set=1
  shopt -s nullglob
  local -a _files=()
  for _file in "${_root}/${_README_SYNC_DIR_REL}"/${_README_SYNC_GLOB}; do
    _files+=( "${_file}" )
  done
  [[ "${_nullglob_was_set}" -eq 1 ]] || shopt -u nullglob
  [[ "${#_files[@]}" -eq 0 ]] || printf '%s\n' "${_files[@]}" | sort
}

# _sync_readme_hashes [root] [accepted-id]... -- stamp every recognized
# marker in every localized README under <root> with the current hash of its
# English section AND of the translated section itself.
#
# Returns non-zero, having stamped everything it legitimately could, when at
# least one section's English hash moved with no matching change on the
# translation side. Naming that section as an <accepted-id> is the caller
# asserting the English change needs no re-translation; `main` exposes that
# as `--accept <id>[,<id>...]`.
#
# A marker whose id is not an English section is left EXACTLY as it is: the
# generator cannot know whether the id is a typo or an English heading that
# was renamed, and quietly dropping or rewriting it would destroy the
# evidence. The lint names it instead. A marker that sits above no heading
# is likewise left alone -- there is no translated section to hash.
_sync_readme_hashes() {
  local _root="${1:-${REPO_ROOT:-.}}"
  if (( $# > 0 )); then
    shift
  fi
  local -A _accepted=()
  local _arg
  for _arg in "$@"; do
    [[ -n "${_arg}" ]] && _accepted["${_arg}"]=1
  done
  local _src="${_root}/${_README_SYNC_SOURCE_REL}"

  if [[ ! -f "${_src}" ]]; then
    _readme_sync_err \
      "no ${_README_SYNC_SOURCE_REL} under ${_root} -- nothing to hash against."
    return 1
  fi

  local -A _en=()
  local -a _en_order=()
  local _slug _hash
  while IFS=$'\t' read -r _slug _hash; do
    [[ -n "${_en[${_slug}]+x}" ]] || _en_order+=( "${_slug}" )
    _en["${_slug}"]="${_hash}"
  done < <(_readme_index "${_src}")

  local -a _files=()
  mapfile -t _files < <(_readme_translation_files "${_root}")
  if [[ "${#_files[@]}" -eq 0 ]]; then
    _readme_sync_err \
      "no ${_README_SYNC_DIR_REL}/${_README_SYNC_GLOB} under ${_root} -- nothing to stamp."
    return 1
  fi

  local _extglob_was_set=0
  shopt -q extglob && _extglob_was_set=1
  shopt -s extglob

  local _file _rel _tmp _line _id _lineno _kind _rec_en _rec_tr _cur_tr
  local _follow _ln _stamped=0
  local -a _unverified=()
  for _file in "${_files[@]}"; do
    _rel="${_file#"${_root}"/}"

    # One parse of the file, before any rewrite: what each marker records
    # and what its translated section hashes to right now. Keyed by line
    # number, which is what the rewrite loop below knows about a line.
    local -A _mk_id=() _mk_rec_en=() _mk_rec_tr=() _mk_cur_tr=() _claimed=()
    while IFS=$'\t' read -r \
        _lineno _kind _id _rec_en _rec_tr _cur_tr _follow; do
      _claimed["${_id}"]=1
      [[ "${_kind}" == 'sync' ]] || continue
      _mk_id["${_lineno}"]="${_id}"
      _mk_rec_en["${_lineno}"]="${_rec_en}"
      _mk_rec_tr["${_lineno}"]="${_rec_tr}"
      _mk_cur_tr["${_lineno}"]="${_cur_tr}"
    done < <(_readme_file_markers "${_file}")

    _tmp="$(mktemp "${_file}.XXXXXX")" || return 1
    _ln=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _ln=$(( _ln + 1 ))
      _id="${_mk_id[${_ln}]:-}"
      # Not a stampable marker: an unrecognized id, or one sitting above no
      # heading. Either way there is nothing to record, and the lint has the
      # vocabulary to say why.
      if [[ -z "${_id}" ]] \
        || [[ -z "${_en[${_id}]+x}" ]] \
        || [[ "${_mk_cur_tr[${_ln}]}" == '-' ]]; then
        printf '%s\n' "${_line}"
        continue
      fi
      _rec_en="${_mk_rec_en[${_ln}]}"
      _rec_tr="${_mk_rec_tr[${_ln}]}"
      _cur_tr="${_mk_cur_tr[${_ln}]}"
      # The silencing case: the English section moved away from what this
      # marker records, and the translation is provably the same text it was
      # stamped against. Moving the English hash here would assert a
      # re-translation that never happened, so the marker is left byte-for-
      # byte alone and the run fails naming it.
      if [[ "${_rec_en}" != '-' && "${_rec_en}" != "${_en[${_id}]}" ]] \
        && [[ "${_rec_tr}" == '-' || "${_rec_tr}" == "${_cur_tr}" ]] \
        && [[ -z "${_accepted[${_id}]+x}" ]]; then
        _unverified+=(
          "${_rel}:${_ln}: refusing to re-stamp '${_id}': ${_README_SYNC_SOURCE_REL} changed (recorded ${_rec_en}, now ${_en[${_id}]}) but this translation did not. Update the translated section and re-run, or -- if the English change needs no re-translation -- re-run with '--accept ${_id}'."
        )
        printf '%s\n' "${_line}"
        continue
      fi
      printf '<!-- sync: %s %s %s -->\n' \
        "${_id}" "${_en[${_id}]}" "${_cur_tr}"
      _stamped=$(( _stamped + 1 ))
    done < "${_file}" > "${_tmp}"
    mv "${_tmp}" "${_file}"

    # Advisory: which English sections this translation still accounts for
    # neither way. Never auto-declared -- see the header note.
    for _slug in "${_en_order[@]}"; do
      [[ -n "${_claimed[${_slug}]+x}" ]] && continue
      printf "%s: no marker for English section '%s' -- translate it and add '<!-- sync: %s -->' above the translated heading, or declare '<!-- sync-skip: %s -- <why> -->'\\n" \
        "${_rel}" "${_slug}" "${_slug}" "${_slug}"
    done
  done

  [[ "${_extglob_was_set}" -eq 1 ]] || shopt -u extglob

  printf 'stamped %s marker(s) across %s file(s) under %s\n' \
    "${_stamped}" "${#_files[@]}" "${_root}/${_README_SYNC_DIR_REL}"

  if [[ "${#_unverified[@]}" -gt 0 ]]; then
    _readme_sync_err "${_unverified[@]}"
    _readme_sync_err \
      "${#_unverified[@]} section(s) left unstamped. An English change with no translation change is the drift this guard exists to catch, so it is never re-stamped on the quiet."
    return 1
  fi
}

# _readme_sync_usage -- CLI help. Named rather than `usage` because this
# file is sourced into the self-test dispatcher, which owns that name.
_readme_sync_usage() {
  {
    cat <<'EOF'
Usage: ./script/test/sync-readme-hashes.sh [--accept <id>[,<id>...]] [<root>]

Stamp every localized README section under <root> (default: the repo root)
with the current hash of the English section it was translated against AND
of the translated section itself.

Options:
  --accept <id>[,<id>...]  Record a reviewed no-op for the named section(s):
                           the English text changed, you read the change,
                           and the translation is still correct. Repeatable.
  -h, --help               This help.

Exits non-zero, naming file / line / section, when an English section moved
and its translation did not -- that is the drift the guard exists to catch,
so it is never re-stamped without --accept.
EOF
  } >&2
}

main() {
  local _root=''
  local -a _accept_ids=() _split=()
  while (( $# > 0 )); do
    case "$1" in
      --accept)
        if [[ -z "${2:-}" ]]; then
          _readme_sync_err "--accept expects <id>[,<id>...]"
          return 2
        fi
        IFS=',' read -r -a _split <<< "$2"
        _accept_ids+=( "${_split[@]}" )
        shift 2
        ;;
      --accept=*)
        IFS=',' read -r -a _split <<< "${1#--accept=}"
        _accept_ids+=( "${_split[@]}" )
        shift
        ;;
      -h|--help)
        _readme_sync_usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        _readme_sync_err "unknown option '$1'"
        _readme_sync_usage
        return 2
        ;;
      *)
        if [[ -n "${_root}" ]]; then
          _readme_sync_err "unexpected argument '$1' (one <root> at most)"
          return 2
        fi
        _root="$1"
        shift
        ;;
    esac
  done
  if [[ -z "${_root}" ]]; then
    _root="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  fi
  _sync_readme_hashes "${_root}" "${_accept_ids[@]}"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
