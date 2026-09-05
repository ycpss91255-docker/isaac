#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/adr_numbering.sh -- the ADR-numbering
# lint. The registry is the filesystem: ADR files live at
# doc/adr/NNNNNNNN-<slug>.md. The lint FAILS on a duplicate ADR number or a
# malformed filename, and WARNS (exit 0) on a numbering gap. The detection
# runs against a controlled temp REPO_ROOT so the spec is independent of the
# live tree's contents; a final case drives the REAL doc/adr/ to prove it
# passes today with the intentional 00000009 gap warned-not-failed.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/adr_numbering.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/doc/adr"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
  # `if`, not `&&`: SHIM_DIR is set by only two of the cases, and a bare
  # `[[ ... ]] && ...` as teardown's LAST statement would fail teardown
  # (and so the test) for every case that never shimmed anything.
  if [[ -n "${SHIM_DIR:-}" ]]; then
    rm -rf "${SHIM_DIR}"
  fi
}

# _touch_adr <NNNNNNNN-slug.md> -- create an empty ADR fixture file.
_touch_adr() {
  : > "${SCRATCH}/doc/adr/${1}"
}

# _shim_early_closing_reader -- populate ${SHIM_DIR} with a `head` that
# closes the pipe before reading and a `sort` that writes only after a
# delay, so a `... | sort | head` min/max computation loses the SIGPIPE
# race on EVERY run instead of a few percent of them. The real race is
# scheduler-dependent (sort writing while head has already left); these
# shims pin the losing interleaving so the regression is deterministic.
# A driver that computes min/max in-shell never execs either one.
_shim_early_closing_reader() {
  SHIM_DIR="$(mktemp -d)"
  cat > "${SHIM_DIR}/head" << 'EOF'
#!/bin/sh
# A reader that already has what it needs: leave at once, so the write
# end of the pipe has no reader left.
exit 0
EOF
  cat > "${SHIM_DIR}/sort" << 'EOF'
#!/bin/sh
# Drain stdin, sort for real, then write LATE -- the losing side of the
# race every time.
_data="$(/usr/bin/sort "$@")"
sleep 0.2
printf '%s\n' "${_data}"
EOF
  chmod +x "${SHIM_DIR}/head" "${SHIM_DIR}/sort"
}

# _run_driver_strict -- run _run_adr_numbering the way the lint phase
# runs it: a fresh `set -euo pipefail` shell, ${SHIM_DIR} first on PATH.
# bats' own `run` clears errexit, which is exactly the setting that turns
# a 141 pipeline into a silent abort, so the production strictness has to
# be re-established in a child shell for the failure mode to show at all.
#
# The strict shell is a script FILE, never `bash -c '...'`. The coverage
# shard runs bash under kcov, which counts lines from xtrace with a PS4
# that expands ${BASH_SOURCE}; at the top level of a `bash -c` string that
# array is EMPTY, so the first command traced after `set -u` dies
# "BASH_SOURCE: unbound variable" before the driver is ever reached. That
# aborts the harness, not the driver, and it is why these cases passed
# plain and failed under coverage -- i.e. failed in the musl/coreutils
# container where the SIGPIPE defect is the one that actually reproduces.
# A script file populates BASH_SOURCE[0], so the same strict shell now
# survives instrumentation and the shims decide the outcome. The identical
# interaction is documented in sourceable_scripts_spec.bats.
_run_driver_strict() {
  local _runner="${SCRATCH}/run_driver_strict.sh"
  # Quoted heredoc: every expansion below belongs to the strict child, not
  # to this shell.
  cat > "${_runner}" << 'EOF'
set -euo pipefail
source /source/dist/script/docker/lib/_lib.sh
_die() { local _ev="${1}"; shift; printf "die %s: %s\n" "${_ev}" "$*"; exit 1; }
source /source/script/test/drivers/adr_numbering.sh
REPO_ROOT="${SCRATCH_ROOT}"
PATH="${SHIM_DIR}:${PATH}"
_run_adr_numbering
EOF
  run env SHIM_DIR="${SHIM_DIR}" SCRATCH_ROOT="${SCRATCH}" bash "${_runner}"
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: failures
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_numbering: FAILS on a duplicate ADR number, naming both files (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000002-gamma.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"00000002"* ]]
  [[ "${output}" == *"00000002-beta.md"* ]]
  [[ "${output}" == *"00000002-gamma.md"* ]]
}

@test "_run_adr_numbering: FAILS on a malformed filename, naming the file (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "notes.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"notes.md"* ]]
}

@test "_run_adr_numbering: FAILS on a too-short (non-8-digit) number prefix (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "0001-short.md"
  run _run_adr_numbering
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"0001-short.md"* ]]
}

@test "_run_adr_numbering: EXEMPTS doc/adr/README.md (the index), not flagged malformed (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  : > "${SCRATCH}/doc/adr/README.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"README.md"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: passes (gaps allowed)
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_numbering: PASSES a clean set WITH a gap, warning the gap (exit 0) (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  # 00000003 intentionally missing -> advisory gap, not a failure.
  _touch_adr "00000004-delta.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"00000003"* ]]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_adr_numbering: PASSES a clean contiguous set with no gap warning (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000003-gamma.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
  [[ "${output}" != *"gap"* ]]
}

@test "_run_adr_numbering: does NOT flag a gap as a duplicate or malformed (#808)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000005-epsilon.md"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  # 00000002..00000004 are all advisory gaps; none is a failure.
  [[ "${output}" == *"00000002"* ]]
  [[ "${output}" == *"00000004"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: no early-closing-reader pipeline
#
# The min/max scan must not hand its exit status to a reader that stops
# reading. `sort` writing into a departed `head` dies of SIGPIPE (141),
# `pipefail` makes that the pipeline's status, and the bare assignment
# under `set -e` kills the whole lint phase with no message at all --
# which fails the local-CI stamp, not a test. These two cases pin the
# losing interleaving so the defect cannot come back intermittently.
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_numbering: an early-closing reader cannot abort the min/max scan (#898)" {
  _touch_adr "00000001-alpha.md"
  _touch_adr "00000002-beta.md"
  _touch_adr "00000003-gamma.md"
  _shim_early_closing_reader
  _run_driver_strict
  # assert_success, not a bare `[ "${status}" -eq 0 ]`: the child shell is
  # where anything goes wrong here, and the bare test reports only its own
  # source line, so a real abort in there arrives with no message at all.
  assert_success
  [[ "${output}" == *"clean"* ]]
}

@test "_run_adr_numbering: min/max stay correct with sort/head unusable (#898)" {
  _touch_adr "00000002-beta.md"
  _touch_adr "00000005-epsilon.md"
  _shim_early_closing_reader
  _run_driver_strict
  assert_success
  # min=00000002, max=00000005 -> 3 and 4 are the advisory gaps, and
  # neither end of the run is itself reported as missing.
  [[ "${output}" == *"00000003"* ]]
  [[ "${output}" == *"00000004"* ]]
  [[ "${output}" != *"gap at 00000002"* ]]
  [[ "${output}" != *"gap at 00000005"* ]]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_adr_numbering: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_adr_numbering: the REAL doc/adr/ passes today (00000009 gap warned) (#808)" {
  REPO_ROOT="/source"
  run _run_adr_numbering
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"00000009"* ]]
  [[ "${output}" == *"clean"* ]]
}
