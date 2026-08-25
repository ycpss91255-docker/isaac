#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/bash_source_guard.sh -- the "no
# unguarded BASH_SOURCE self-location read" lint.
#
# A self-locating read with no default aborts under nounset in every
# context where bash does not populate the array for the running file --
# most sharply under the kcov-instrumented shell of the coverage shard,
# where it is found in CI rather than locally. Defaulting the read to $0
# is inert under direct execution (both expand to the same path) and
# degrades instead of aborting elsewhere; this lint is the recurrence
# guard, and sourceable_scripts_spec.bats is its behavioural half.
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# tree to prove it passes today. Shape mirrors home_literal_lint_spec.bats
# / stale_setup_conf_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/bash_source_guard.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" \
    "${SCRATCH}/script/test/drivers"
  REPO_ROOT="${SCRATCH}"

  # The array name is assembled at runtime so this spec's fixtures carry
  # the token only where a test means them to, and never as a stray plain
  # literal the driver's own real-tree case could trip over.
  BS='${BASH_SOURCE'
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a scanned-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_bash_source_guard: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_bash_source_guard: FAILS on a bare indexed read, naming file and line (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    '#!/usr/bin/env bash' \
    "_dir=\"\$(dirname -- \"${BS}[0]}\")\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/x.sh:2"* ]]
}

@test "_run_bash_source_guard: FAILS on a suffix-stripped read (\${BASH_SOURCE[0]%/*}) (#869)" {
  # The %/* dirname shorthand is just as unbound-fatal as the plain read;
  # a lint that only matched the bare closing brace would miss it.
  _write "dist/script/docker/lib/log.sh" \
    "_LOG_LIB_DIR=\"${BS}[0]%/*}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"log.sh:1"* ]]
}

@test "_run_bash_source_guard: FAILS on a caller-frame read (\${BASH_SOURCE[1]}) (#869)" {
  # Frame 1 is the one that is genuinely absent when a function is reached
  # from a top-level context, so it needs the default more than frame 0.
  _write "dist/script/docker/lib/bootstrap.sh" \
    "  : \"\${_caller:=${BS}[1]}}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"bootstrap.sh:1"* ]]
}

@test "_run_bash_source_guard: FAILS on a subscript-less read (\${BASH_SOURCE}) (#869)" {
  # No subscript means element 0; kcov's own PS4 is spelled this way.
  _write "dist/script/docker/lib/y.sh" "_self=\"${BS}}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"y.sh:1"* ]]
}

@test "_run_bash_source_guard: FAILS on a read in base's own tooling tree, not just dist/ (#869)" {
  # script/ is scanned too: the self-test dispatcher and its drivers hit
  # exactly this failure in the coverage shard.
  _write "script/test/drivers/z.sh" "_d=\"\$(dirname -- \"${BS}[0]}\")\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"script/test/drivers/z.sh:1"* ]]
}

@test "_run_bash_source_guard: names the default form in the failure message (#869)" {
  # The message has to carry the fix, not just the finding.
  _write "dist/script/docker/lib/x.sh" "_self=\"${BS}[0]}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *':-$0'* ]]
}

@test "_run_bash_source_guard: FAILS on a read AFTER an allow-end (region does not leak) (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    "# ${_BASH_SOURCE_ALLOW_BEGIN} deliberate" \
    "_a=\"${BS}[0]}\"" \
    "# ${_BASH_SOURCE_ALLOW_END}" \
    "_b=\"${BS}[0]}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"x.sh:4"* ]]
  [[ "${output}" != *"x.sh:2"* ]]
}

@test "_run_bash_source_guard: FAILS on an unterminated allow-begin region (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    "# ${_BASH_SOURCE_ALLOW_BEGIN} deliberate" \
    "_a=\"${BS}[0]}\""
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_bash_source_guard: FAILS on an allow-end with no matching allow-begin (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    '#!/usr/bin/env bash' \
    "# ${_BASH_SOURCE_ALLOW_END}"
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_bash_source_guard: accepted forms
# ════════════════════════════════════════════════════════════════════

@test "_run_bash_source_guard: PASSES the \$0-defaulted read (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    "_dir=\"\$(cd -- \"\$(dirname -- \"${BS}[0]:-\$0}\")\" && pwd -P)\""
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: PASSES the empty-defaulted sourced-vs-executed guard (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    "if [[ \"${BS}[0]:-}\" == \"\${0:-}\" ]]; then" \
    '  main "$@"' \
    'fi'
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: PASSES a defaulted higher frame (\${BASH_SOURCE[2]:-unknown}) (#869)" {
  _write "dist/script/docker/lib/log.sh" \
    "  local caller_file=\"${BS}[2]:-unknown}\""
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: PASSES whole-array expansions, which nounset tolerates (#869)" {
  # bash yields an empty list for ${arr[@]} / ${#arr[@]} on an unset array
  # even under set -u, so the array-wide forms are not the hazard and
  # flagging them would push authors toward noise.
  _write "dist/script/docker/lib/bootstrap.sh" \
    "  for _frame in \"${BS}[@]:1}\"; do :; done" \
    "  _n=\"\${#BASH_SOURCE[@]}\"" \
    "  _all=\"${BS}[*]}\""
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: PASSES a comment that merely names the array (#869)" {
  # Prose explaining the rule (this driver's own header, the ADR, every
  # sibling comment) must not be a violation, or the guard becomes
  # unwritable in its own terms.
  _write "dist/script/docker/lib/x.sh" \
    "# resolve it from ${BS}[0]} (this file), not the caller's layout" \
    "   # a leading-whitespace comment counts too: ${BS}[1]}"
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: EXEMPTS a read inside an allow-begin/allow-end region (#869)" {
  _write "dist/script/docker/lib/x.sh" \
    "# ${_BASH_SOURCE_ALLOW_BEGIN} deliberate" \
    "_a=\"${BS}[0]}\"" \
    "# ${_BASH_SOURCE_ALLOW_END}"
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_bash_source_guard: ignores non-.sh files and files outside the scanned trees (#869)" {
  mkdir -p "${SCRATCH}/doc"
  printf '%s\n' "the old shape read ${BS}[0]} with no default" \
    > "${SCRATCH}/doc/notes.md"
  _write "dist/script/docker/lib/notes.txt" "_a=\"${BS}[0]}\""
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_bash_source_guard: scan-root guard
# ════════════════════════════════════════════════════════════════════

@test "_run_bash_source_guard: FAILS when a scan root is missing (no vacuous pass) (#869)" {
  rm -rf "${SCRATCH}/dist"
  run _run_bash_source_guard
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_bash_source_guard: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_bash_source_guard: the REAL shipped + tooling trees pass today (#869)" {
  REPO_ROOT="/source"
  run _run_bash_source_guard
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
