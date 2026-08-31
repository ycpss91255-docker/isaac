#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/coverage_gate.sh -- the self-hosted,
# CI-agnostic coverage-floor gate (ADR-00000008). The gate MERGES the
# per-shard kcov cobertura reports into ONE project line-rate by per-line
# UNION (a line is covered if ANY shard ran it; valid = distinct source
# lines), NOT a SUM of root counters (which double-counts source shared
# across shards and drifts with the shard count -- see the merge bug fix)
# and exits non-zero when the merged rate is below COVERAGE_MIN. These
# tests drive it against controlled cobertura fixtures so they are
# independent of any live kcov run.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The gate script is standalone-runnable (CI invokes it directly with
  # the per-shard cobertura paths). Resolve it via the mounted /source
  # tree the test-tools container exposes.
  GATE=/source/script/test/drivers/coverage_gate.sh

  SCRATCH="$(mktemp -d)"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# Write a minimal kcov-style cobertura.xml at $1 with <covered> of <valid>
# per-line <line> elements (the gate merges by per-line UNION). The
# class filename defaults to a UNIQUE name per fixture dir, so distinct
# fixtures are DISJOINT source -> their union equals the old sum (the
# pre-union assertions stay valid). Pass $4 to force a SHARED filename so two
# shards overlap on the same source (exercises the union dedupe).
#   $1 path  $2 covered  $3 valid  [$4 filename]
_make_cobertura() {
  local _path="${1}" _covered="${2}" _valid="${3}"
  local _fn="${4:-$(basename "$(dirname "${_path}")").sh}"
  mkdir -p "$(dirname "${_path}")"
  {
    echo '<?xml version="1.0" ?>'
    echo "<coverage lines-covered=\"${_covered}\" lines-valid=\"${_valid}\" version=\"1.9\" timestamp=\"0\">"
    echo '  <packages><package name="p"><classes>'
    echo "  <class name=\"c\" filename=\"${_fn}\"><lines>"
    local _i
    for (( _i = 1; _i <= _valid; _i++ )); do
      if (( _i <= _covered )); then
        echo "    <line number=\"${_i}\" hits=\"1\"/>"
      else
        echo "    <line number=\"${_i}\" hits=\"0\"/>"
      fi
    done
    echo '  </lines></class>'
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${_path}"
}

# Write a kcov-style cobertura report at $1 from one or more class specs,
# each given as `<filename>:<valid>:<lo>:<hi>`: a <class> with <valid>
# per-line <line> elements of which lines lo..hi carry hits="1" (lo=0 =>
# none covered). Unlike _make_cobertura this emits SEVERAL classes per
# report, which is what kcov does and what the path-alias cases need. The
# root lines-covered / lines-valid counters are deliberately omitted: the
# gate merges by per-line union and never reads them.
_make_multi_cobertura() {
  local _path="${1}"
  shift
  mkdir -p "$(dirname "${_path}")"
  {
    echo '<?xml version="1.0" ?>'
    echo '<coverage version="1.9" timestamp="0">'
    echo '  <packages><package name="p"><classes>'
    local _spec _fn _valid _lo _hi _i
    for _spec in "$@"; do
      IFS=: read -r _fn _valid _lo _hi <<< "${_spec}"
      echo "  <class name=\"c\" filename=\"${_fn}\"><lines>"
      for (( _i = 1; _i <= _valid; _i++ )); do
        if (( _lo > 0 && _i >= _lo && _i <= _hi )); then
          echo "    <line number=\"${_i}\" hits=\"1\"/>"
        else
          echo "    <line number=\"${_i}\" hits=\"0\"/>"
        fi
      done
      echo '  </lines></class>'
    done
    echo '  </classes></package></packages>'
    echo '</coverage>'
  } > "${_path}"
}

# ════════════════════════════════════════════════════════════════════
# Floor pass / fail
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: passes when merged rate >= COVERAGE_MIN" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]
}

@test "coverage_gate: passes at exactly the floor (boundary)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 50 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
}

@test "coverage_gate: fails when merged rate < COVERAGE_MIN" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 40 100
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"40.00"* ]]
  [[ "${output}" == *"50"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Multi-shard merge math: per-line UNION, do NOT average; do NOT double-count
# shared source across shards
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: merges DISJOINT shards by union (= sum), not averaging" {
  # Distinct fixtures -> distinct class filenames -> disjoint source, so the
  # union equals the line-weighted sum. A 90/100 (90%), B 10/900 (~1.1%) ->
  # union = 100/1000 = 10.00%; the average of the rates would be ~45.6%.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 90 100
  _make_cobertura "${SCRATCH}/b/cobertura.xml" 10 900
  run env COVERAGE_MIN=0 bash "${GATE}" \
    "${SCRATCH}/a/cobertura.xml" "${SCRATCH}/b/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"10.00"* ]]
  [[ "${output}" != *"45.6"* ]]
}

@test "coverage_gate: SHARED source across shards is unioned, not double-counted (#730)" {
  # The real bug dynamic sharding exposed: every shard's kcov reports the WHOLE tree, so a
  # source file run by specs in multiple shards appears in EACH shard's report.
  # Two shards over the SAME file (filename "shared.sh", 100 lines): shard A
  # covers lines 1-30, shard B covers lines 31-60. UNION = 60/100 = 60.00%.
  # The old SUM math double-counted valid: (30+30)/(100+100) = 30.00% (wrong).
  mkdir -p "${SCRATCH}/a" "${SCRATCH}/b"
  {
    echo '<coverage lines-covered="30" lines-valid="100" version="1.9">'
    echo '<packages><package><classes><class name="c" filename="shared.sh"><lines>'
    for i in $(seq 1 100); do
      if (( i <= 30 )); then echo "<line number=\"${i}\" hits=\"1\"/>"
      else echo "<line number=\"${i}\" hits=\"0\"/>"; fi
    done
    echo '</lines></class></classes></package></packages></coverage>'
  } > "${SCRATCH}/a/cobertura.xml"
  {
    echo '<coverage lines-covered="30" lines-valid="100" version="1.9">'
    echo '<packages><package><classes><class name="c" filename="shared.sh"><lines>'
    for i in $(seq 1 100); do
      if (( i >= 31 && i <= 60 )); then echo "<line number=\"${i}\" hits=\"1\"/>"
      else echo "<line number=\"${i}\" hits=\"0\"/>"; fi
    done
    echo '</lines></class></classes></package></packages></coverage>'
  } > "${SCRATCH}/b/cobertura.xml"
  run env COVERAGE_MIN=0 bash "${GATE}" \
    "${SCRATCH}/a/cobertura.xml" "${SCRATCH}/b/cobertura.xml"
  [ "${status}" -eq 0 ]
  # union 60/100 = 60.00%, NOT the double-counted sum 30.00%
  [[ "${output}" == *"60.00"* ]]
  [[ "${output}" != *"30.00"* ]]
}

@test "coverage_gate: four shards merge into one weighted total" {
  _make_cobertura "${SCRATCH}/s1/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s2/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s3/cobertura.xml" 25 100
  _make_cobertura "${SCRATCH}/s4/cobertura.xml" 25 100
  run env COVERAGE_MIN=20 bash "${GATE}" \
    "${SCRATCH}"/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  # (25*4)/(100*4) = 25.00%
  [[ "${output}" == *"25.00"* ]]
}

# ════════════════════════════════════════════════════════════════════
# kcov path aliases: one source file is reported under several
# prefix-truncated filenames, so the union key must be canonicalised
# (longest observed path-suffix match) before it is counted
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: prefix path aliases of one file are counted once (#853)" {
  # kcov emits the SAME source file under several prefix truncations. Each
  # alias is a different union key, so each contributes its own full copy of
  # the file's lines to the denominator while only the alias that recorded
  # hits contributes to the numerator. One 100-line file, 50 lines covered
  # under the fully-qualified alias -> 50/100 = 50.00%, NOT 50/400 = 12.50%.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:100:1:50" \
    "script/docker/lib/_lib.sh:100:0:0" \
    "docker/lib/_lib.sh:100:0:0" \
    "lib/_lib.sh:100:0:0"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"50.00"* ]]
  [[ "${output}" != *"12.50"* ]]
}

@test "coverage_gate: different files sharing a basename stay separate (#853)" {
  # The trap that rules basename-only keying out: distinct files legitimately
  # share a basename (a shipped lib deploy.sh and the generated field
  # launcher). Neither name is a path suffix of the other, so they must keep
  # separate keys: 80/200 = 40.00%, NOT the merged 80/100 = 80.00%.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/deploy.sh:100:1:80" \
    "deploy/robot-field-1.0.0/deploy.sh:100:0:0"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"40.00"* ]]
  [[ "${output}" != *"80.00"* ]]
}

@test "coverage_gate: rate is unchanged when the suite is resharded under other aliases (#853)" {
  # The invariant the union already claimed but aliasing broke: which alias a
  # file appears under depends on which shard executed it, and shard
  # membership is recomputed from the spec-file list -- so adding one spec
  # reshuffles the shards and moved the reported rate. The SAME suite (one
  # 100-line file, lines 1-60 covered) split two ways must report the same
  # rate: 60/100 = 60.00%.
  _make_multi_cobertura "${SCRATCH}/two/s1/cobertura.xml" \
    "script/docker/lib/_lib.sh:100:1:30"
  _make_multi_cobertura "${SCRATCH}/two/s2/cobertura.xml" \
    "lib/_lib.sh:100:31:60"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}"/two/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]

  _make_multi_cobertura "${SCRATCH}/four/s1/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:100:1:15"
  _make_multi_cobertura "${SCRATCH}/four/s2/cobertura.xml" \
    "script/docker/lib/_lib.sh:100:16:30"
  _make_multi_cobertura "${SCRATCH}/four/s3/cobertura.xml" \
    "docker/lib/_lib.sh:100:31:45"
  _make_multi_cobertura "${SCRATCH}/four/s4/cobertura.xml" \
    "lib/_lib.sh:100:46:60"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}"/four/s*/cobertura.xml
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"60.00"* ]]
}

@test "coverage_gate: reports the collapsed-alias count as a diagnostic (#853)" {
  # A regression in kcov's path reporting must be visible, not silent: the
  # gate states how many observed filenames collapsed into a canonical one.
  # Four aliases of one file plus one unaliased file -> 3 collapsed.
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:10:1:5" \
    "script/docker/lib/_lib.sh:10:0:0" \
    "docker/lib/_lib.sh:10:0:0" \
    "lib/_lib.sh:10:0:0" \
    "dist/script/docker/lib/deploy.sh:10:1:5"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collapsed 3"* ]]
}

@test "coverage_gate: reports zero collapsed aliases when nothing is aliased (#853)" {
  _make_multi_cobertura "${SCRATCH}/a/cobertura.xml" \
    "dist/script/docker/lib/_lib.sh:10:1:5" \
    "dist/script/docker/lib/deploy.sh:10:1:5"
  run env COVERAGE_MIN=0 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"collapsed 0"* ]]
}

# ════════════════════════════════════════════════════════════════════
# Missing / empty / malformed report handling
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: errors when no report files are given" {
  run env COVERAGE_MIN=50 bash "${GATE}"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors when a named report file is missing" {
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/does-not-exist.xml"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors when total valid lines is zero (empty report)" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 0 0
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
}

@test "coverage_gate: errors on a report missing the line counters" {
  mkdir -p "${SCRATCH}/a"
  printf '%s\n' '<coverage version="1.9"></coverage>' \
    > "${SCRATCH}/a/cobertura.xml"
  run env COVERAGE_MIN=50 bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# COVERAGE_MIN default + visibility
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate: default COVERAGE_MIN does not false-fail at the measured 84.72%" {
  # The rate CI measures on main (84.72%, 5907/6972 lines) must clear the
  # built-in default floor. Model it with a report at that rate and assert
  # pass with NO COVERAGE_MIN override.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 5907 6972
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"84.72"* ]]
}

@test "coverage_gate: default COVERAGE_MIN is 80 -- a report exactly at 80 passes" {
  # Pin the floor VALUE from below: 80.00% is the lowest rate the built-in
  # default accepts. Asserted with NO override so the constant itself is
  # under test, and the reported floor is read back out of the verdict
  # line so a silent re-base cannot pass unnoticed.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 8000 10000
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"floor 80% -> PASS"* ]]
}

@test "coverage_gate: default COVERAGE_MIN is 80 -- a report just under 80 fails" {
  # Pin the same value from above: 79.99% must FAIL on the built-in
  # default. Together with the boundary-pass case this fixes the floor at
  # exactly 80, so lowering it back silently breaks a test.
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 7999 10000
  run bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"floor 80% -> FAIL"* ]]
}

@test "coverage_gate: emits a GitHub step summary table when GITHUB_STEP_SUMMARY is set" {
  _make_cobertura "${SCRATCH}/a/cobertura.xml" 60 100
  local _summary="${SCRATCH}/summary.md"
  run env COVERAGE_MIN=50 GITHUB_STEP_SUMMARY="${_summary}" \
    bash "${GATE}" "${SCRATCH}/a/cobertura.xml"
  [ "${status}" -eq 0 ]
  [ -f "${_summary}" ]
  run cat "${_summary}"
  [[ "${output}" == *"Coverage"* ]]
  [[ "${output}" == *"60.00"* ]]
}

# ════════════════════════════════════════════════════════════════════
# --merge-timings: aggregate per-shard runtime files into one weights file
#
# Each coverage shard uploads a `<seconds> <basename>` timings file
# (from _junit_to_timings). The coverage-gate job already downloads every
# shard artifact, so it also merges the timings into one weights file that
# the NEXT run restores as SHARD_WEIGHTS_FILE. A spec runs in exactly one
# shard, so normally one entry per basename; the merge keeps the MAX as a
# defensive dedup and tolerates a shard that produced no file.
# ════════════════════════════════════════════════════════════════════

@test "coverage_gate --merge-timings: merges per-shard timings keeping max seconds per basename (#733)" {
  printf '%s\n' "10 foo_spec.bats" "3 bar_spec.bats" > "${SCRATCH}/a.tsv"
  printf '%s\n' "5 baz_spec.bats" "7 foo_spec.bats" > "${SCRATCH}/b.tsv"
  run bash "${GATE}" --merge-timings "${SCRATCH}/w.tsv" \
    "${SCRATCH}/a.tsv" "${SCRATCH}/b.tsv" "${SCRATCH}/missing.tsv"
  [ "${status}" -eq 0 ]
  run cat "${SCRATCH}/w.tsv"
  assert_line "10 foo_spec.bats"
  assert_line "3 bar_spec.bats"
  assert_line "5 baz_spec.bats"
}

@test "coverage_gate --merge-timings: no input files yields an empty weights file (#733)" {
  run bash "${GATE}" --merge-timings "${SCRATCH}/w.tsv" "${SCRATCH}/none.tsv"
  [ "${status}" -eq 0 ]
  [ -f "${SCRATCH}/w.tsv" ]
  run cat "${SCRATCH}/w.tsv"
  [ -z "${output}" ]
}
