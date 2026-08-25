#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/issueref.sh -- the "no transient
# issue refs in code comments" lint (ADR-00000013). The detection runs
# against a controlled temp REPO_ROOT so the spec is independent of the
# live tree's contents.

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
  source /source/script/test/drivers/issueref.sh

  # A scratch repo root the driver will scan. Mirror the in-scope roots so
  # the driver's find walk has somewhere to look.
  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script" "${SCRATCH}/script" "${SCRATCH}/test"
  REPO_ROOT="${SCRATCH}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# ════════════════════════════════════════════════════════════════════
# _run_issueref: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_issueref: flags a bare #NNN in a leading comment" {
  printf '%s\n' '# rationale for the gate #440' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#440'* ]]
}

@test "_run_issueref: flags a bare #NNN in a trailing comment" {
  printf '%s\n' 'echo hi   # auto-build gate #216' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#216'* ]]
}

@test "_run_issueref: flags the (#NNN) paren form in a comment" {
  printf '%s\n' '# the EXIT-trap cleanup (#429)' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'(#429)'* ]]
}

@test "_run_issueref: flags a bare 2-digit ref (lower accept boundary) (#692)" {
  # The accept window is [2,4] digits. Pin the 2-digit lower bound so a
  # regression re-capping it (the original mawk bug capped at 2) is caught.
  printf '%s\n' '# gate #42' > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#42'* ]]
}

@test "_run_issueref: flags a bare 4-digit ref (upper accept boundary) (#692)" {
  # The whole awk `+` rewrite exists because 3-4 digit refs were silently
  # exempted under Debian mawk; pin the 4-digit upper bound is flagged.
  printf '%s\n' '# gate #1234' > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *'#1234'* ]]
}

@test "_run_issueref: flags refs in .bats helper comments (not @test names)" {
  # Fixture built via printf with the refs in vars (not a heredoc with bare
  # comment tokens) so this spec is itself immune to the comment sweep that
  # runs over test/. ref_a is a helper-comment ref (flagged); ref_b lives
  # in an @test name (must NOT be flagged).
  local ref_a='#319' ref_b='#388'
  {
    printf '%s\n' '#!/usr/bin/env bats'
    printf '%s\n' "# helper comment with a stale ref ${ref_a}"
    printf '%s\n' "@test \"behaviour stays named with (${ref_b})\" {"
    printf '%s\n' '  true'
    printf '%s\n' '}'
  } > "${SCRATCH}/test/sample.bats"
  run _run_issueref
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${ref_a}"* ]]
  [[ "${output}" != *"${ref_b}"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_issueref: must-keep (no false positives)
# ════════════════════════════════════════════════════════════════════

@test "_run_issueref: passes clean on a tree with no comment refs" {
  printf '%s\n' '# describes what the gate does, no number' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'clean'* ]]
}

@test "_run_issueref: does NOT flag a #NNN inside a string literal" {
  printf '%s\n' 'echo "patched (#567 m7)"   # plain comment, no ref' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag ADR-0000xxxx references" {
  printf '%s\n' '# layered consumer entry (ADR-00000011)' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag DL/SC directive codes or version tags" {
  printf '%s\n' '# hadolint DL3007 / shellcheck SC1090, since v0.41.0' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag word-prefixed cross-repo refs" {
  printf '%s\n' '# layered COPY chain (template#254), see harness#53' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag single-digit or 5+-digit numbers" {
  printf '%s\n' '# step #1 of the loop; PID #12345 placeholder' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT treat a \${#arr[@]} expansion as a comment" {
  printf '%s\n' 'len=${#arr[@]}; echo "${len} items"' \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

@test "_run_issueref: does NOT flag a #NNN opener in heredoc usage prose" {
  # A token-leading '#' directly followed by a digit is not a comment
  # marker (no real comment opens with hash-then-digit); it only occurs as
  # a ref in heredoc / usage body prose, functional text rather than a code
  # comment. The literal is built via a var so the sweep over test/ cannot
  # strip it from this spec.
  local ref='#321'
  printf '%s\n' "                       Debug knob for ${ref}." \
    > "${SCRATCH}/script/sample.sh"
  run _run_issueref
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _ISSUEREF_AWK: cross-engine portability (busybox-awk / mawk / gawk)
# ════════════════════════════════════════════════════════════════════
#
# The driver runs under busybox awk in the alpine test-tools image but
# under mawk in the kcov/kcov debian coverage shard. Debian's mawk 1.3.4
# match() does not extend chained `?` repeats greedily, so an earlier
# `#[0-9][0-9]?...` form silently no-op'd 3-4 digit refs ONLY under that
# mawk -- a kcov-only failure invisible to the alpine `just test` loop.
# These tests run the _ISSUEREF_AWK program directly under EVERY awk
# engine present in the image (the Dockerfile.test-tools final stage
# installs mawk + gawk alongside busybox awk for exactly this), asserting
# identical detection so a portability regression fails the FAST local
# loop. This is the first of a two-layer local==CI gate; the alpine mawk
# build happens to be greedy, so the Debian-mawk-specific greediness bug
# is additionally gated by running the real kcov path locally with
# `just test coverage 2/4` (the shard carrying this spec). The engine
# list adapts: an engine absent from the host is skipped, never a hard
# failure (keeps the spec runnable on a bare workstation).

# Detect available awk engines once. busybox awk is invoked as
# `busybox awk`; mawk / gawk as themselves when on PATH.
_issueref_engines() {
  command -v busybox >/dev/null 2>&1 && echo "busybox awk"
  command -v mawk    >/dev/null 2>&1 && echo "mawk"
  command -v gawk    >/dev/null 2>&1 && echo "gawk"
}

@test "_ISSUEREF_AWK: flags a 3-digit ref identically under every awk engine" {
  local fixture="${SCRATCH}/script/sample.sh"
  printf '%s\n' '# rationale for the gate #440' > "${fixture}"
  local found=0 engine out
  while IFS= read -r engine; do
    [[ -z "${engine}" ]] && continue
    found=1
    out="$(${engine} -v relbase="${SCRATCH}/" "${_ISSUEREF_AWK}" "${fixture}")"
    echo "engine=${engine} out=[${out}]"
    [[ "${out}" == *'#440'* ]] || {
      echo "FAIL: ${engine} did not flag #440"
      return 1
    }
  done < <(_issueref_engines)
  [[ "${found}" -eq 1 ]]
}

@test "_ISSUEREF_AWK: flags the 2-digit and 4-digit accept boundaries under every awk engine (#692)" {
  # Pin BOTH ends of the [2,4] accept window across every awk engine so a
  # portability regression (e.g. mawk re-capping the window to 2) fails the
  # fast local loop, not just kcov.
  local fixture="${SCRATCH}/script/sample.sh"
  local found=0 engine out ref
  while IFS= read -r engine; do
    [[ -z "${engine}" ]] && continue
    found=1
    for ref in '#42' '#1234'; do
      printf '%s\n' "# gate ${ref}" > "${fixture}"
      out="$(${engine} -v relbase="${SCRATCH}/" "${_ISSUEREF_AWK}" "${fixture}")"
      [[ "${out}" == *"${ref}"* ]] || {
        echo "FAIL: ${engine} did not flag boundary ref ${ref} -> [${out}]"
        return 1
      }
    done
  done < <(_issueref_engines)
  [[ "${found}" -eq 1 ]]
}

@test "_ISSUEREF_AWK: keeps the must-keep cases clean under every awk engine" {
  local fixture="${SCRATCH}/script/sample.sh"
  # One line per exemption: string-literal ref, ADR ref, DL/SC + version,
  # word-prefixed cross-repo ref, single-digit + 5-digit, \${#arr} expansion.
  # Each is built so the comment portion carries no bare 2-4 digit #NNN.
  local -a keep=(
    'echo "patched (#567 m7)"   # plain comment, no ref'
    '# layered consumer entry (ADR-00000011)'
    '# hadolint DL3007 / shellcheck SC1090, since v0.41.0'
    '# layered COPY chain (template#254), see harness#53'
    '# step #1 of the loop; PID #12345 placeholder'
    'len=${#arr[@]}; echo "${len} items"'
  )
  local found=0 engine out line
  while IFS= read -r engine; do
    [[ -z "${engine}" ]] && continue
    found=1
    for line in "${keep[@]}"; do
      printf '%s\n' "${line}" > "${fixture}"
      out="$(${engine} -v relbase="${SCRATCH}/" "${_ISSUEREF_AWK}" "${fixture}")"
      [[ -z "${out}" ]] || {
        echo "FAIL: ${engine} flagged a must-keep line: [${line}] -> [${out}]"
        return 1
      }
    done
  done < <(_issueref_engines)
  [[ "${found}" -eq 1 ]]
}
