#!/usr/bin/env bash
# drivers/issueref.sh - "no transient issue refs in code comments" per-tool
# driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_issueref, the enforcer for ADR-00000013 (strip transient issue
# numbers from code comments; keep ADR refs + what/why prose).
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/shellcheck.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# What it flags: a bare transient issue ref (#NNN, 2-4 digits) inside the
# COMMENT portion of an in-scope file. A "comment" is a `#` that begins a
# token outside any quoted string -- so a `#NNN` inside a printf / _log_*
# string literal, or inside a `${#var}` expansion, is not a comment and is
# not flagged.
#
# What it deliberately does NOT flag (per ADR-00000013):
#   - ADR-0000xxxx references (no `#`, durable curated rationale).
#   - `@test "..."` description strings -- test identities mirrored in
#     TEST.md, not comments; the whole `@test` line is skipped.
#   - Word-prefixed cross-repo / upstream refs that name their tracker
#     (`base#321`, `docker_harness#53`, `moby/buildkit#3403`) -- only a
#     BARE `#NNN` (preceded by start-of-comment / whitespace / `(` / `/`)
#     is transient base shorthand.
#   - hadolint / shellcheck directive codes (`DL3007`, `SC1090`) and
#     version tags (`v0.41.0`) -- they carry no `#`, so the pattern never
#     matches them.
#   - Issue refs inside non-comment code (string literals, runtime-emitted
#     text).

# ── No transient issue refs in code comments ─────────────────────────────────

# In-scope file types (ADR-00000013). Repo-root-relative roots are
# walked for these extensions; @test description strings are exempt inside
# .bats files (handled by the comment extractor below).
readonly _ISSUEREF_ROOTS=(
  "dist"
  "script"
  "test"
)
readonly _ISSUEREF_TOPLEVEL=(
  "compose.yaml"
  "justfile"
)

# The awk comment-state machine that does the detection. Sourced as a
# single-quoted heredoc-free string so the same program backs both the
# driver run and the unit-test harness. A `#` inside a quoted string is
# never treated as a comment; @test lines are skipped wholesale; only a
# bare `#NNN` (not word-prefixed) in the comment portion is flagged.
# FILENAME is rewritten repo-root-relative via the `relbase` var.
# shellcheck disable=SC2016 # awk program; $-vars are awk's, not the shell's.
readonly _ISSUEREF_AWK='
  function is_ws(c) { return (c == " " || c == "\t") }
  {
    line = $0
    if (line ~ /^[[:space:]]*@test[[:space:]]/) next
    in_s = 0; in_d = 0; cstart = -1; prev = ""
    n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (in_s) { if (c == "\47") in_s = 0; prev = c; continue }
      if (in_d) { if (c == "\"") in_d = 0; prev = c; continue }
      if (c == "\47") { in_s = 1; prev = c; continue }
      if (c == "\"") { in_d = 1; prev = c; continue }
      if (c == "#") {
        # A comment opener is `#` at start-of-token (prev is SOL or ws). A
        # `#` immediately followed by a digit is NOT a comment marker -- no
        # genuine comment opens `#<digit>`; that shape only occurs as a ref
        # embedded in prose / a heredoc usage body (functional text, not a
        # code comment). Skip it so such lines are not flagged.
        if ((prev == "" || is_ws(prev)) && substr(line, i + 1, 1) !~ /[0-9]/) {
          cstart = i; break
        }
      }
      prev = c
    }
    if (cstart < 0) next
    comment = substr(line, cstart)
    m = comment
    # `#[0-9]+` (greedy `+`, not the chained `[0-9]?` repeats) so the match
    # captures EVERY consecutive digit. The chained-optional form behaved
    # differently under mawk, whose match() does not extend the `?` repeats
    # greedily -- it capped RLENGTH at a hash plus two digits, so a three-
    # or four-digit ref matched only its first two digits with the trailing
    # digit left in `after`, silently exempting it (issue refs went
    # undetected under the kcov debian/mawk shard while busybox-awk / gawk
    # flagged them). With `+` the digit run is whole and the count is exact
    # across busybox-awk, mawk, and gawk; the 2-4 digit window is enforced
    # by length(digits).
    while (match(m, /#[0-9]+/)) {
      hashpos = RSTART
      before = (hashpos > 1) ? substr(m, hashpos - 1, 1) : "#"
      if (before !~ /[A-Za-z0-9_]/) {
        digits = substr(m, hashpos + 1, RLENGTH - 1)
        if (length(digits) >= 2 && length(digits) <= 4) {
          rel = FILENAME; sub(relbase, "", rel)
          printf "%s:%d: %s\n", rel, FNR, line
          next
        }
      }
      m = substr(m, hashpos + RLENGTH)
    }
  }
'

_run_issueref() {
  echo "--- Running issue-ref comment lint (ADR-00000013) ---"
  local _violations=0
  local _root _file _out
  local -a _files=()

  # Collect in-scope files: the extension set under the scan roots, plus
  # the top-level compose.yaml / justfile.
  while IFS= read -r -d '' _file; do
    _files+=("${_file}")
  done < <(find "${_ISSUEREF_ROOTS[@]/#/${REPO_ROOT}/}" \
      \( -name '*.sh' -o -name 'justfile*' -o -name 'compose.yaml' \
         -o -name '*.bats' -o -name 'Dockerfile*' \) \
      -type f -print0 2>/dev/null | sort -z)
  for _file in "${_ISSUEREF_TOPLEVEL[@]}"; do
    [[ -f "${REPO_ROOT}/${_file}" ]] && _files+=("${REPO_ROOT}/${_file}")
  done

  # Scan each file; awk prints offending lines prefixed with their
  # repo-root-relative path. Count printed lines for the failure summary.
  for _file in "${_files[@]}"; do
    _out="$(awk -v relbase="${REPO_ROOT}/" "${_ISSUEREF_AWK}" "${_file}")"
    if [[ -n "${_out}" ]]; then
      printf '%s\n' "${_out}"
      _violations=$(( _violations + $(printf '%s\n' "${_out}" | grep -c '') ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_issueref_in_comment \
      "${_violations} transient issue ref(s) found in code comments. Per ADR-00000013, strip #NNN from comments (keep ADR-0000xxxx refs + what/why prose)."
    return 1
  fi
  echo "issue-ref comment lint: clean"
}
