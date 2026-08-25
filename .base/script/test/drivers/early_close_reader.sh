#!/usr/bin/env bash
# drivers/early_close_reader.sh - "no pipeline into an early-closing
# reader" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_early_close_reader, the recurrence guard for a defect this tree has
# now been bitten by ten times.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/bash_source_guard.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main, region-delimited opt-out).
#
# Why: a reader that stops reading turns its own success into the
# pipeline's failure. `grep -q` leaves the instant it matches and
# `head -n1` after one line; a writer still writing then takes SIGPIPE and
# exits 141, and under `pipefail` 141 becomes the PIPELINE's status. An
# `if` reads that as false, so a SUCCESSFUL match is reported as "not
# found" -- the status is not lost, it is INVERTED, and the caller takes
# the other branch in silence. Where the status feeds a bare assignment
# under `set -e` instead, the caller dies with no message at all.
#
# Whether the race is lost is environment-dependent, which is what makes
# this worth a lint rather than a test: the same pipeline lost it 0 times
# in 20000 iterations on the host (glibc, bash 5.1) and 6.4% of the time
# inside the alpine test-tools image (musl, coreutils 9.5, bash 5.2).
# "I ran it and it was fine" is not evidence about a coin the platform
# weights, and downstream repos run this code on whatever host they have.
#
# The fix is always to remove the dependency -- drain the stream, or do
# the work in-shell -- never `|| true`, which trades a loud wrong answer
# for a silent one and discards genuine failures with it.
#
# Scope: *.sh under dist/ (the shipped runtime tree every downstream repo
# executes) and script/ (base's own tooling). NOT test/bats/**, and that
# restriction is the whole reason the rule is worth having. A bats test
# body runs with errexit ON and pipefail OFF -- measured, `false | true`
# yields 0 there -- so its ~65 `| head -n1` / `| grep -q` lines are
# structurally incapable of the inversion. A whole-tree rule would be ~65
# candidates and 0 true positives; scoped here it flagged exactly the nine
# real defects and nothing else, across every release from v0.30.0 to
# v0.41.0.
#
# What is a violation: a PIPELINE (a single `|`) whose next command is
# `head`, or `grep` carrying a quiet flag (`-q` in any short cluster, or
# `--quiet` / `--silent`). The reader may sit on its own continuation
# line, which is how both `| head -1` sites in this tree were written.
#
# What is NOT:
#   - a reader that drains the stream. `grep -v` and `grep -c` read to
#     EOF, so nothing upstream is ever stranded; build.sh, prune.sh and
#     setup_tui.sh use exactly these.
#   - `grep -q` with a FILE operand. No pipe, no writer, no race --
#     dockerfile_migrate.sh is full of them.
#   - `||`, which is not a pipeline, and a here-string (`<<<`), which is a
#     redirection whose status pipefail never sees.
#   - comment lines. Every fix in this tree carries a comment spelling the
#     bad pipeline out; prose about the rule must not violate it.
#
# Known limitation, stated rather than papered over: `head` and `grep -q`
# are not the only commands that stop reading (`sed 1q`,
# `awk 'NR==1{exit}'`, a `read` at the end of a pipe). They are the two
# the tree has actually used, and widening the rule to shapes with no
# instances would trade its measured zero false positives for guesswork.
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW pipeline elsewhere in an allowlisted file is still
# caught. Bracket the legitimate lines with
#   # early-close-lint: allow-begin -- <why>
#   ...
#   # early-close-lint: allow-end
# The case for one is a pipeline whose status genuinely cannot be read
# (display only, discarded). There is no live region today. Unbalanced
# markers (an unterminated begin, an unmatched end) fail the lint -- a
# silently swallowed region would re-open exactly the hole this closes.

# ── Early-closing-reader pipeline lint ───────────────────────────────────────

# The scanned trees, repo-root-relative. Each must exist: a missing root
# would make the scan pass vacuously.
readonly _EARLY_CLOSE_SCAN_ROOTS=('dist' 'script')

# The reader names are assembled as data rather than baked into a pattern
# literal, for the reason bash_source_guard.sh splits its own token: this
# driver lives INSIDE a scanned tree, so its source must not carry the
# very shape it hunts for.
readonly _EARLY_CLOSE_HEAD='head'
readonly _EARLY_CLOSE_GREP='grep'

# A pipe that opens a real pipeline, followed by the reader name and a
# word boundary. `||` and `|&` are masked out before these are applied.
readonly _EARLY_CLOSE_PIPE='\|[[:space:]]*'
# End-of-word: anything that is not a word character, or end of line. Not
# just whitespace -- a bare `... | head)"` closing a command substitution
# is the same reader, and `| header` is not.
readonly _EARLY_CLOSE_BOUND='([^A-Za-z0-9_.-]|$)'

# Quiet grep: the name, any number of intervening words, then a short
# cluster containing `q` (-q, -qx, -qxF, -x -q) or the long spellings.
# The intervening-words hop is what catches `grep -x -q -- pat`.
readonly _EARLY_CLOSE_WORD='[^|[:space:]]+[[:space:]]+'
readonly _EARLY_CLOSE_QFLAG='(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)'

# Region markers for the explicit opt-out (see the header note).
readonly _EARLY_CLOSE_ALLOW_BEGIN='early-close-lint: allow-begin'
readonly _EARLY_CLOSE_ALLOW_END='early-close-lint: allow-end'

# _early_close_hit <line> -- true when <line> pipes into a reader that
# stops reading.
#
# `||` and `|&` are masked first so only real pipelines remain: `||` is a
# logical OR, not a pipe, and the tree already has a dozen
# `... || grep -q ... <file>` lines that must not be flagged. The mask
# characters are chosen so nothing they replace can re-form a match.
_early_close_hit() {
  local _line="${1}"
  _line="${_line//||/@@}"
  _line="${_line//|&/@@}"

  # A here-string is a redirection, not a pipeline; drop it (and anything
  # it quotes) before looking for pipes.
  _line="${_line//<<</ }"

  local _head_re="${_EARLY_CLOSE_PIPE}${_EARLY_CLOSE_HEAD}${_EARLY_CLOSE_BOUND}"
  if [[ "${_line}" =~ ${_head_re} ]]; then
    return 0
  fi

  local _grep_re
  _grep_re="${_EARLY_CLOSE_PIPE}${_EARLY_CLOSE_GREP}[[:space:]]+"
  _grep_re="${_grep_re}(${_EARLY_CLOSE_WORD})*"
  _grep_re="${_grep_re}${_EARLY_CLOSE_QFLAG}${_EARLY_CLOSE_BOUND}"
  [[ "${_line}" =~ ${_grep_re} ]]
}

_run_early_close_reader() {
  echo "--- Running early-closing-reader pipeline lint ---"
  local _violations=0
  local _root _abs_root _file _rel _line _lineno _in_allow _begin_line

  local -a _files=()
  for _root in "${_EARLY_CLOSE_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    if [[ ! -d "${_abs_root}" ]]; then
      _die ci_early_close_reader \
        "scan root '${_root}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the shipped runtime tree and base's own tooling tree."
      return 1
    fi
    while IFS= read -r -d '' _file; do
      _files+=("${_file}")
    done < <(find "${_abs_root}" -name '*.sh' -type f -print0 2>/dev/null \
      | sort -z)
  done

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_EARLY_CLOSE_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_EARLY_CLOSE_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue
      # Comment lines: prose about the shape, not an instance of it.
      [[ "${_line}" =~ ^[[:space:]]*# ]] && continue

      if _early_close_hit "${_line}"; then
        printf '%s:%d: %s\n' "${_rel}" "${_lineno}" "${_line}"
        _violations=$(( _violations + 1 ))
      fi
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_early_close_reader \
      "${_violations} pipeline(s) into an early-closing reader / unbalanced allow marker(s) under ${_EARLY_CLOSE_SCAN_ROOTS[*]}. A reader that stops reading strands the writer with SIGPIPE, pipefail promotes that 141 to the pipeline's status, and an 'if' reads a SUCCESSFUL match as 'not found' -- the answer is inverted, not lost, and the caller takes the other branch in silence. Drain the stream (a 'while IFS= read -r' loop over a process substitution) or do the work in-shell. NOT '|| true': that hides the wrong answer instead of removing it, and discards genuine failures with it. A pipeline whose status truly cannot be read opts out by bracketing it with '# ${_EARLY_CLOSE_ALLOW_BEGIN} -- <why>' / '# ${_EARLY_CLOSE_ALLOW_END}'."
    return 1
  fi
  echo "early-closing-reader pipeline lint: clean"
}
