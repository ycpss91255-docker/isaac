#!/usr/bin/env bash
#
# sync-doc-counts.sh - regenerate the test-count figures in doc/test/*.md
# from the specs themselves, so they stop being hand-edited every PR.
#
# Single source of truth: `grep -c '^@test'` over each spec file. The
# check_test_md_drift.sh hook stays the validating safety net; this is the
# generator that makes the docs match. Idempotent.
#
# Two kinds of derived content are generated:
#
#   1. The count figures -- per-spec `### <path> (N)` headings, the per-type
#      `**N tests**` totals, and TEST.md's index table + blockquote prose.
#   2. The per-test CATALOG ROWS -- the `| Test | Description |` tables, one
#      row per `@test` (see "Catalog rows" below).
#
# (2) exists because (1) alone produced the worst kind of stale document: the
# heading count was regenerated and gated, the hand-written table of per-test
# rows beside it was neither, so the catalogue silently fell behind while the
# gate reported "in sync" (deploy_spec.bats: 43 tests, 36 rows, green).
# Generating the rows makes the catalogue complete by construction -- a human
# enriches a description, nobody has to remember to add one.
#
# Usage:
#   ./script/test/sync-doc-counts.sh            # sync REPO_ROOT/doc/test/*.md
#   ./script/test/sync-doc-counts.sh <root>     # sync <root>/doc/test/*.md
#
# Style: Google Shell Style Guide.

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# _dir_test_count <root> <relglob> -- total `^@test` count across the spec
# files matching <root>/<relglob>. This is the authoritative per-type total
# (what `just test` actually runs), independent of how many specs happen to
# have an individual `### <path> (N)` doc heading.
_dir_test_count() {
  local _root="$1" _glob="$2" _f _sum=0 _c
  # globstar so a caller can pass `<dir>/**/*_spec.bats` to recurse into
  # per-lib sub-folders (test/bats/unit/<lib>/<subunit>_spec.bats,
  # ADR-00000015). Saved/restored so sourcing this lib does not leak the
  # option to the caller.
  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  for _f in "${_root}"/${_glob}; do
    [[ -f "${_f}" ]] || continue
    _c="$(grep -cE '^@test' "${_f}" 2>/dev/null || true)"
    _sum=$(( _sum + ${_c:-0} ))
  done
  (( _globstar_was_set )) || shopt -u globstar
  printf '%s\n' "${_sum}"
}

# _doc_spec_glob <doc-basename> -- the root-relative spec glob the named
# doc/test catalogue covers, or nothing for a doc that is not a per-level
# catalogue (TEST.md is the index). Single source for "which specs belong in
# which doc", used by the per-type totals and by the missing-section sweep.
_doc_spec_glob() {
  case "$1" in
    unit.md) printf '%s\n' 'test/bats/unit/**/*_spec.bats' ;;
    integration.md) printf '%s\n' 'test/bats/integration/**/*_spec.bats' ;;
    system.md) printf '%s\n' 'test/bats/system/**/*_spec.bats' ;;
    acceptance.md) printf '%s\n' 'test/bats/acceptance/**/*_spec.bats' ;;
    smoke.md) printf '%s\n' 'dist/test/bats/smoke/**/*.bats' ;;
    *) return 0 ;;
  esac
}

# _sync_doc_sections <root> <doc> -- append a catalogue section for every spec
# file <doc>'s level covers but never mentions.
#
# Generating the ROWS makes a table complete; it cannot help a spec file that
# never got a `### <path> (N)` heading in the first place, which is the same
# rot one level up and just as invisible to a gate that only re-derives what
# the doc already mentions. So the section is generated too, for the same
# reason the rows are: the author enriches the prose, nobody has to remember
# the scaffolding. New sections land at the end of the doc; move one into its
# thematic group freely, the generator keys on the heading, not the position.
_sync_doc_sections() {
  local _root="$1" _doc="$2" _glob
  [[ -f "${_doc}" ]] || return 0
  _glob="$(_doc_spec_glob "$(basename -- "${_doc}")")"
  [[ -n "${_glob}" ]] || return 0

  # An appended heading must start its own line even if the doc did not end
  # with a newline.
  [[ -s "${_doc}" && -n "$(tail -c1 "${_doc}")" ]] && printf '\n' >> "${_doc}"

  local _globstar_was_set=0
  shopt -q globstar && _globstar_was_set=1
  shopt -s globstar
  local _f _rel
  for _f in "${_root}"/${_glob}; do
    [[ -f "${_f}" ]] || continue
    _rel="${_f#"${_root}"/}"
    grep -qE "^#{3,6}[[:space:]]+${_rel//./\\.}[[:space:]]+\([0-9]+\)[[:space:]]*$" \
      "${_doc}" && continue
    {
      printf '\n### %s (0)\n\n' "${_rel}"
      printf '| Test | Description |\n|------|-------------|\n'
    } >> "${_doc}"
  done
  (( _globstar_was_set )) || shopt -u globstar
  return 0
}

# _sync_headings <root> <doc> -- rewrite each `<hashes> <relpath> (N)` heading's
# N from grep -c '^@test' on <root>/<relpath> (leaving headings whose path does
# not resolve untouched). Any ATX depth is matched (### and #### and deeper) and
# re-emitted at its original depth: per-leaf-lib specs use level-4 `####`
# sub-headings (ADR-00000015), and anchoring on `###` alone left those counts
# unregenerated -- a silent drift the drift checker (same generator) was blind
# to.
_sync_headings() {
  local _root="$1" _doc="$2" _tmp _line
  [[ -f "${_doc}" ]] || return 0
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^(#{3,6})[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]]; then
      local _hashes="${BASH_REMATCH[1]}" _path="${BASH_REMATCH[2]}" _n
      if [[ -f "${_root}/${_path}" ]]; then
        _n="$(grep -cE '^@test' "${_root}/${_path}" 2>/dev/null || true)"
        printf '%s %s (%s)\n' "${_hashes}" "${_path}" "${_n:-0}"
        continue
      fi
    fi
    printf '%s\n' "${_line}"
  done < "${_doc}" > "${_tmp}"
  mv "${_tmp}" "${_doc}"
}

# ── Catalog rows ─────────────────────────────────────────────────────────────
#
# A spec section opts INTO a generated per-test catalogue by carrying a
# `| Test | Description |` table; the generator then guarantees exactly one
# row per `@test`, in spec file order. A section that summarises instead (the
# `| Category | Tests |` shape used by the very large specs) or carries only
# prose is left untouched -- an editorial choice about presentation, visible
# in the diff, not silent rot inside a table that claims to be per-test.
#
# The contract, in full (doc/test/unit.md states it for readers too):
#
#   Row identity   The test name, exactly as bats reports it. The name is
#                  read from the `@test "..." {` line with bash double-quote
#                  unescaping applied (`\"` `\\` `\$` `` \` `` lose the
#                  backslash), so a row can be pasted straight into
#                  `--filter`. A `|` in the name is escaped `\|` on the way
#                  into the table and unescaped on the way back out, so the
#                  table cannot be broken by a test name.
#   Preservation   A row whose test still exists keeps its description
#                  verbatim -- match is on the name, so hand-written prose
#                  survives regeneration. That is the whole point: the count
#                  was generated and the prose was not, and the asymmetry is
#                  what rotted.
#   Deletion       A row naming no existing test is dropped.
#   Rename         Delete plus add: the old row goes, the new name arrives
#                  with the placeholder description. Prose does NOT follow a
#                  rename -- there is no reliable way to tell a rename from a
#                  delete+add. To carry prose across a rename, rename the row
#                  in the doc in the same commit, then regenerate.
#   Ordering       Spec file order, not alphabetical. The table then reads as
#                  the spec reads (the deliberate grouping of related cases
#                  survives), and reordering a spec produces the matching doc
#                  diff instead of an unrelated scatter.
#   Placeholder    A test with no description gets `-`, the same "unset"
#                  marker the config summary uses. Enriching it is optional;
#                  omitting it is not possible.
#
# Only the FIRST per-test table in a section is treated as the catalogue; a
# second one is left to the author.

# _catalog_unescape_into <outvar> <raw> -- bash double-quote unescaping of
# <raw> into <outvar>: `\X` collapses to `X` for the four characters bash
# treats specially inside "...", every other backslash is literal. This is
# what bats does to the `@test "..."` name before printing it, so applying it
# here keeps a row's identity equal to the name in the TAP output.
_catalog_unescape_into() {
  local -n _catalog_unescape_out="$1"
  local _raw="$2" _res='' _i _ch _next
  local _bs=$'\\'
  local _len="${#_raw}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_raw:_i:1}"
    if [[ "${_ch}" == "${_bs}" && $(( _i + 1 )) -lt "${_len}" ]]; then
      _next="${_raw:_i+1:1}"
      if [[ "${_next}" == '"' || "${_next}" == "${_bs}" \
        || "${_next}" == '$' || "${_next}" == '`' ]]; then
        _res+="${_next}"
        (( _i++ ))
        continue
      fi
    fi
    _res+="${_ch}"
  done
  _catalog_unescape_out="${_res}"
}

# _spec_test_names <file> -- the bats test names in <file>, in file order,
# one per line. Kept in step with the `grep -cE '^@test'` the counts use: the
# same lines match, so a heading count and its row count cannot disagree.
_spec_test_names() {
  local _file="$1" _line _name
  [[ -f "${_file}" ]] || return 0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ "${_line}" =~ ^@test[[:space:]]+\"(.*)\"[[:space:]]*\{[[:space:]]*$ ]] \
      || continue
    _catalog_unescape_into _name "${BASH_REMATCH[1]}"
    printf '%s\n' "${_name}"
  done < "${_file}"
}

# _catalog_cell_split_into <name-outvar> <desc-outvar> <line> -- split a
# `| `name` | description |` row. Returns 1 for a line that is not a table
# row. Splitting is done on the first UNESCAPED `|` so a `\|` inside a test
# name does not end the cell; the description keeps any `|` it contains.
_catalog_cell_split_into() {
  local -n _catalog_split_name="$1"
  local -n _catalog_split_desc="$2"
  local _line="$3"
  [[ "${_line}" == '|'* ]] || return 1
  local _body="${_line#|}"
  local _cell='' _rest='' _i _ch
  local _bs=$'\\'
  local _len="${#_body}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_body:_i:1}"
    if [[ "${_ch}" == "${_bs}" && $(( _i + 1 )) -lt "${_len}" ]]; then
      _cell+="${_body:_i:2}"
      (( _i++ ))
      continue
    fi
    if [[ "${_ch}" == '|' ]]; then
      _rest="${_body:_i+1}"
      break
    fi
    _cell+="${_ch}"
  done
  # Trim, drop the code-span backticks (one or two, whatever the name needed)
  # and undo the table-level `\|` escaping to recover the raw test name.
  _cell="${_cell#"${_cell%%[![:space:]]*}"}"
  _cell="${_cell%"${_cell##*[![:space:]]}"}"
  _cell="${_cell#\`\`}"
  _cell="${_cell%\`\`}"
  _cell="${_cell#\`}"
  _cell="${_cell%\`}"
  _cell="${_cell//\\|/|}"
  # The description is everything up to the closing pipe of the row.
  _rest="${_rest%|}"
  _rest="${_rest#"${_rest%%[![:space:]]*}"}"
  _rest="${_rest%"${_rest##*[![:space:]]}"}"
  _catalog_split_name="${_cell}"
  _catalog_split_desc="${_rest}"
}

# _catalog_render_row <name> <desc> -- one markdown catalog row. A `|` in the
# name is escaped; a name containing a backtick gets a double-backtick code
# span so the span still closes where it should.
_catalog_render_row() {
  local _name="$1" _desc="$2" _fence='`'
  [[ "${_name}" == *'`'* ]] && _fence='``'
  printf '| %s%s%s | %s |\n' "${_fence}" "${_name//|/\\|}" "${_fence}" "${_desc}"
}

# _catalog_flush <spec-file> <descmap-varname> <rule-seen> -- emit the table
# body: the canonical rule when the source table had none, then one row per
# `@test` in <spec-file>, each carrying the description <descmap-varname>
# recorded for that name (`-` when there is none).
_catalog_flush() {
  local _spec_file="$1" _rule_seen="$3" _name
  local -n _catalog_flush_desc="$2"
  (( _rule_seen )) || printf '%s\n' '|------|-------------|'
  while IFS= read -r _name; do
    _catalog_render_row "${_name}" "${_catalog_flush_desc[${_name}]:--}"
  done < <(_spec_test_names "${_spec_file}")
}

# _sync_catalog_rows <root> <doc> -- regenerate every per-test catalog table
# in <doc> from the spec file its section heading names.
#
# Line-oriented state machine over the doc: the heading sets the current spec
# (empty when the path does not resolve, so a section about a spec that left
# the tree is preserved as history), the `| Test | Description |` header opens
# the table, the rows that follow are absorbed into a name -> description map,
# and the map plus the spec's own test list produce the new rows.
_sync_catalog_rows() {
  local _root="$1" _doc="$2"
  [[ -f "${_doc}" ]] || return 0
  local _tmp
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1

  local _spec='' _line _in_table=0 _rule_seen=0
  local -A _desc=()
  local _rowname _rowdesc

  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if (( _in_table )); then
      if [[ "${_line}" == '|'* ]]; then
        if (( ! _rule_seen )) && [[ "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]]; then
          printf '%s\n' "${_line}"
          _rule_seen=1
          continue
        fi
        if _catalog_cell_split_into _rowname _rowdesc "${_line}"; then
          [[ -n "${_rowname}" ]] && _desc["${_rowname}"]="${_rowdesc}"
        fi
        continue
      fi
      _catalog_flush "${_root}/${_spec}" _desc "${_rule_seen}"
      _in_table=0
      _rule_seen=0
      _desc=()
    fi

    if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
      _spec=''
      if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]] \
        && [[ -f "${_root}/${BASH_REMATCH[1]}" ]]; then
        _spec="${BASH_REMATCH[1]}"
      fi
      printf '%s\n' "${_line}"
      continue
    fi

    if [[ -n "${_spec}" ]] \
      && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|[[:space:]]*$ ]]; then
      printf '%s\n' "${_line}"
      _in_table=1
      continue
    fi

    printf '%s\n' "${_line}"
  done < "${_doc}" > "${_tmp}"
  # A table that runs to the end of file never hit the non-row line that
  # flushes it inside the loop.
  if (( _in_table )); then
    _catalog_flush "${_root}/${_spec}" _desc "${_rule_seen}" >> "${_tmp}"
  fi

  mv "${_tmp}" "${_doc}"
}

# _catalog_key <spec> <name> -- map key for one catalog row. Scoped by spec
# file because the same test name legitimately appears in two specs with two
# different descriptions.
_catalog_key() {
  printf '%s\t%s\n' "$1" "$2"
}

# _catalog_collect_descriptions <root> <doc> <mapvar> -- record every catalog
# row's description into the associative array <mapvar>, keyed by
# _catalog_key. Read-only. Used by resolve-doc-counts.sh to reconcile the two
# sides of a merge: descriptions are the one part of a catalog table the
# generator preserves rather than derives, so they are the one part a
# mechanical collapse could silently drop.
_catalog_collect_descriptions() {
  local _root="$1" _doc="$2"
  local -n _catalog_collect_map="$3"
  [[ -f "${_doc}" ]] || return 0
  local _spec='' _line _in_table=0 _rowname _rowdesc
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if (( _in_table )); then
      if [[ "${_line}" == '|'* ]]; then
        [[ "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]] && continue
        if _catalog_cell_split_into _rowname _rowdesc "${_line}"; then
          [[ -n "${_rowname}" ]] \
            && _catalog_collect_map["$(_catalog_key "${_spec}" "${_rowname}")"]="${_rowdesc}"
        fi
        continue
      fi
      _in_table=0
    fi
    if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
      _spec=''
      if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]] \
        && [[ -f "${_root}/${BASH_REMATCH[1]}" ]]; then
        _spec="${BASH_REMATCH[1]}"
      fi
      continue
    fi
    [[ -n "${_spec}" ]] \
      && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|[[:space:]]*$ ]] \
      && _in_table=1
  done < "${_doc}"
}

# _catalog_apply_descriptions <root> <doc> <mapvar> -- rewrite each catalog
# row's description from <mapvar> (rows with no entry keep what they have).
# The inverse of _catalog_collect_descriptions.
_catalog_apply_descriptions() {
  local _root="$1" _doc="$2"
  local -n _catalog_apply_map="$3"
  [[ -f "${_doc}" ]] || return 0
  local _tmp
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1
  local _spec='' _line _in_table=0 _rowname _rowdesc _key
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if (( _in_table )); then
      if [[ "${_line}" == '|'* ]]; then
        if [[ "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]]; then
          printf '%s\n' "${_line}"
          continue
        fi
        if _catalog_cell_split_into _rowname _rowdesc "${_line}" \
          && [[ -n "${_rowname}" ]]; then
          _key="$(_catalog_key "${_spec}" "${_rowname}")"
          _catalog_render_row "${_rowname}" \
            "${_catalog_apply_map[${_key}]:-${_rowdesc}}"
          continue
        fi
        printf '%s\n' "${_line}"
        continue
      fi
      _in_table=0
    fi
    if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
      _spec=''
      if [[ "${_line}" =~ ^#{3,6}[[:space:]]+(.+)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]] \
        && [[ -f "${_root}/${BASH_REMATCH[1]}" ]]; then
        _spec="${BASH_REMATCH[1]}"
      fi
      printf '%s\n' "${_line}"
      continue
    fi
    if [[ -n "${_spec}" ]] \
      && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*Description[[:space:]]*\|[[:space:]]*$ ]]; then
      _in_table=1
    fi
    printf '%s\n' "${_line}"
  done < "${_doc}" > "${_tmp}"
  mv "${_tmp}" "${_doc}"
}

# _sync_type_total <doc> <count> -- rewrite the per-type `...: **N tests**.`
# header to <count>.
_sync_type_total() {
  local _doc="$1" _count="$2"
  [[ -f "${_doc}" ]] || return 0
  sed -i -E "s/(: )\*\*[0-9]+ tests\*\*/\1**${_count} tests**/" "${_doc}"
}

# _sync_test_md_index <root> -- rewrite TEST.md's derived figures (grand total,
# per-type table, "not in the N figure", and the blockquote prose "System (N)
# and smoke (N)" pair) from the per-type totals. The prose pair is regenerated
# too: hand-maintaining it let it drift out of step with the table it sits
# next to.
_sync_test_md_index() {
  local _root="$1"
  local _t="${_root}/doc/test/TEST.md"
  [[ -f "${_t}" ]] || return 0
  # ISTQB taxonomy (ADR-00000018): levels unit / integration / system /
  # acceptance, plus the shipped build-time smoke type. system replaces the
  # retired behavioural category. Empty level dirs (e.g. acceptance before
  # S5 content lands) resolve to 0 via _dir_test_count's no-match path.
  local _u _i _sy _a _sm _tot
  _u="$(_dir_test_count "${_root}" 'test/bats/unit/**/*_spec.bats')"
  _i="$(_dir_test_count "${_root}" 'test/bats/integration/**/*_spec.bats')"
  _sy="$(_dir_test_count "${_root}" 'test/bats/system/**/*_spec.bats')"
  _a="$(_dir_test_count "${_root}" 'test/bats/acceptance/**/*_spec.bats')"
  _sm="$(_dir_test_count "${_root}" 'dist/test/bats/smoke/**/*.bats')"
  _tot=$(( _u + _i ))
  sed -i -E \
    "s/\*\*[0-9]+ tests\*\* total \([0-9]+ unit \+ [0-9]+ integration\)/**${_tot} tests** total (${_u} unit + ${_i} integration)/" \
    "${_t}"
  sed -i -E "s/not\*\* in the [0-9]+ figure/not** in the ${_tot} figure/" "${_t}"
  sed -i -E \
    "s/System \([0-9]+\) and smoke \([0-9]+\)/System (${_sy}) and smoke (${_sm})/" \
    "${_t}"
  sed -i -E "s#(\[unit\.md\]\(unit\.md\).*\| )[0-9]+ #\1${_u} #" "${_t}"
  sed -i -E "s#(\[integration\.md\]\(integration\.md\).*\| )[0-9]+ #\1${_i} #" "${_t}"
  sed -i -E "s#(\[system\.md\]\(system\.md\).*\| )[0-9]+ #\1${_sy} #" "${_t}"
  sed -i -E "s#(\[acceptance\.md\]\(acceptance\.md\).*\| )[0-9]+ #\1${_a} #" "${_t}"
  sed -i -E "s#(\[smoke\.md\]\(smoke\.md\).*\| )[0-9]+ #\1${_sm} #" "${_t}"
  sed -i -E "s/(grand total \(unit \+ integration\): )\*\*[0-9]+\*\*/\1**${_tot}**/" "${_t}"
}

# _sync_doc_counts [root] -- regenerate all doc/test/*.md count figures.
_sync_doc_counts() {
  local _root="${1:-${REPO_ROOT:-.}}"
  local _doc
  local _glob
  for _doc in "${_root}"/doc/test/*.md; do
    [[ -f "${_doc}" ]] || continue
    _sync_doc_sections "${_root}" "${_doc}"
    _sync_headings "${_root}" "${_doc}"
    _sync_catalog_rows "${_root}" "${_doc}"
    _glob="$(_doc_spec_glob "$(basename -- "${_doc}")")"
    [[ -n "${_glob}" ]] || continue
    _sync_type_total "${_doc}" "$(_dir_test_count "${_root}" "${_glob}")"
  done
  _sync_test_md_index "${_root}"
}

main() {
  local _root="${1:-${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
  _sync_doc_counts "${_root}"
  printf 'synced doc/test counts under %s\n' "${_root}/doc/test"
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
