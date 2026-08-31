#!/usr/bin/env bats
#
# Unit tests for script/test/test.sh helper functions.
# Only helpers that can be exercised without a full CI run are covered here.
#
# NOTE: these tests confine PATH to MOCK_DIR *after* sourcing test.sh so
# the mocked binaries resolve instead of the real ones.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  create_mock_dir
  local _cmd
  # sha256sum + cut back the name derivations (_compute_test_tools_hash /
  # _compute_compose_project_name); without them a PATH-confined test would
  # exercise their fail-loud guard instead of the behaviour under test.
  for _cmd in grep date cat printf sha256sum cut; do
    local _path
    _path="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_path}" "${MOCK_DIR}/${_cmd}"
  done
}

teardown() {
  cleanup_mock_dir
}

# ════════════════════════════════════════════════════════════════════
# _run_shellcheck
#
# Regression guard: if someone adds a new shell script under script/ or
# config/ but forgets to wire it into _run_shellcheck, the list drifts
# out of sync with reality. These tests pin the expected invocations so
# that drift surfaces as a test failure.
# ════════════════════════════════════════════════════════════════════

@test "_run_shellcheck: invokes shellcheck against every expected script" {
  # Log each invocation to a capture file so we can inspect the set.
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  # xargs needs a mock too — the real one would forward to the real
  # shellcheck binary (which lives in MOCK_DIR), so this is just a
  # belt-and-braces ensure PATH is honored.
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success

  assert [ -f "${_log}" ]
  run cat "${_log}"
  assert_output --partial "script/test/test.sh"
  assert_output --partial "sync-doc-counts.sh"
  assert_output --partial "init.sh"
  assert_output --partial "upgrade.sh"
  assert_output --partial "config/shell/terminator/setup.sh"
  assert_output --partial "config/shell/tmux/setup.sh"
  # the base namespace scripts (completions.sh) are shellchecked too.
  assert_output --partial "dist/script/base"
}

@test "_run_shellcheck: picks up every .sh file in script/docker/" {
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success

  # Every .sh under dist/script/docker/wrapper/ and lib/ must appear.
  for _f in /source/dist/script/docker/wrapper/*.sh /source/dist/script/docker/lib/*.sh; do
    run grep -F "${_f}" "${_log}"
    assert_success
  done
}

@test "_run_shellcheck: picks up every .sh file in script/test/ (#876)" {
  # The driver used to name script/test/*.sh one by one, so
  # check_test_md_drift.sh, lint_bare_stderr.sh and the 333-line
  # sync-readme-hashes.sh generator went unlinted -- and the same batch
  # that added resolve-doc-counts.sh to the list forgot them. A find
  # sweep makes a new gate script linted the moment it exists.
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success

  local _f _missing=""
  while IFS= read -r _f; do
    grep -qF "${_f}" "${_log}" || _missing+=" ${_f}"
  done < <(find /source/script/test -name '*.sh' -type f | sort)
  [ -z "${_missing}" ] || { echo "script/test scripts never linted:${_missing}"; false; }
}

@test "_run_shellcheck: exits non-zero when shellcheck fails on any script" {
  # Simulate a lint violation on init.sh specifically.
  mock_cmd "shellcheck" '
    for _arg in "$@"; do
      if [[ "${_arg}" == *"/init.sh" ]]; then
        printf "SC0001: fake violation\n" >&2
        exit 1
      fi
    done
    exit 0'
  # Enable -e to mirror real CI invocation (test.sh sets it when run
  # directly; when sourced, the caller owns strict mode).
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _run_lint_tool: an abort the driver cannot explain
#
# A lint driver that dies at a command reporting nothing -- a signal
# above all, SIGPIPE from a pipeline whose reader closed early -- used to
# surface as a bare exit code from `just`, reading like a lint finding
# rather than a broken driver. The dispatcher names the tool, the status
# and the command that stopped it, through the registered event id.
# ════════════════════════════════════════════════════════════════════

@test "_run_lint_tool: names the tool and the signal when a driver dies of SIGPIPE (#898)" {
  run env LOG_FORMAT=json bash -c '
    source /source/script/test/test.sh
    set -eo pipefail
    _run_adr_numbering() {
      local _v
      # A writer whose reader is already gone: SIGPIPE -> 141, which
      # pipefail promotes to the pipeline status, exactly as a
      # `... | sort | head -n1` losing the race would.
      _v="$( { sleep 0.2; printf "x\n"; } | true )"
    }
    _run_lint_tool adr-numbering
  '
  assert_failure
  assert_output --partial "ci_lint_driver_failed"
  assert_output --partial "adr-numbering"
  assert_output --partial "141"
  assert_output --partial "SIGPIPE"
}

@test "_run_lint_tool: names the tool when a driver fails without a signal (#898)" {
  run env LOG_FORMAT=json bash -c '
    source /source/script/test/test.sh
    set -eo pipefail
    _run_adr_numbering() { false; }
    _run_lint_tool adr-numbering
  '
  assert_failure
  assert_output --partial "ci_lint_driver_failed"
  assert_output --partial "adr-numbering"
  assert_output --partial "false"
}

@test "_run_lint_tool: a clean driver reports nothing and leaves no ERR trap armed (#898)" {
  run env LOG_FORMAT=json bash -c '
    source /source/script/test/test.sh
    set -eo pipefail
    _run_adr_numbering() { echo "driver ok"; }
    _run_lint_tool adr-numbering
    trap -p ERR
    echo "trap-listing-ends"
  '
  assert_success
  assert_output --partial "driver ok"
  refute_output --partial "ci_lint_driver_failed"
  refute_output --partial "_lint_driver_failed"
}

# ════════════════════════════════════════════════════════════════════
# _run_via_compose / main routing
#
# Regression guards: default `test.sh` (no flag) must hit the alpine
# `ci` service; `--coverage` must hit the `coverage` service (which now
# shares the same test-tools image). Mock `docker` so the test captures
# the chosen service name + COVERAGE env without actually running
# compose.
# ════════════════════════════════════════════════════════════════════

@test "_run_via_compose: routes default mode to the ci service with COVERAGE=0" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=0"
  assert_output --partial " ci"
  refute_output --partial "COVERAGE=1"
}

@test "_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose coverage 1
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose"
  assert_output --partial "COVERAGE=1"
  assert_output --partial " coverage"
}

@test "main: dispatches no-flag default to the ci service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "COVERAGE=0"
}

@test "_run_tests: passes --jobs N when parallel is on PATH" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "parallel" 'exit 0'
  mock_cmd "nproc" 'echo 8'
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "--jobs 8"
}

@test "_run_tests: omits --jobs when parallel is absent (graceful fallback)" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  # Intentionally NOT mocking `parallel` so command -v misses.
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_tests
  '
  assert_success
  assert_output --partial "serial"
  assert_output --partial "parallel not in PATH"

  run cat "${_log}"
  assert_success
  refute_output --partial "--jobs"
}

@test "main: dispatches --coverage to the coverage service" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
}

# ════════════════════════════════════════════════════════════════════
# --coverage-shard: sharded kcov matrix (ADR-00000008, weight-balanced)
#
# Coverage is the primary unit gate. _shard_unit_files is the partition
# primitive: greedy weight-balanced bin-packing by per-spec @test count
# (heaviest-first into the lightest shard) so the slowest shard's load
# approaches total/N. _run_coverage <n>/<total> kcov's that slice (+
# integration on the last shard). main --coverage-shard plumbs
# COVERAGE_SHARD into the coverage service.
# ════════════════════════════════════════════════════════════════════

@test "_shard_unit_files: a single shard returns real unit spec paths (#615)" {
  run bash -c '
    source /source/script/test/test.sh
    _shard_unit_files 1/4
  '
  assert_success
  assert_output --partial "test/bats/unit/"
  assert_output --partial "_spec.bats"
}

@test "_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615, #724)" {
  # Union of every shard of 4 must equal the full sorted spec list (unit +
  # integration, folded into one pool), with no file in two shards (the
  # invariant the coverage-gate merge relies on: every spec runs exactly
  # once across the matrix).
  run bash -c '
    source /source/script/test/test.sh
    all=$(find "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration" \
            -name "*_spec.bats" | sort)
    union=$( { _shard_unit_files 1/4; _shard_unit_files 2/4; \
               _shard_unit_files 3/4; _shard_unit_files 4/4; } | sort )
    [[ "${all}" == "${union}" ]] || { echo "MISMATCH"; exit 1; }
    # disjoint: total line count equals the full list count (no dupes)
    n_all=$(printf "%s\n" "${all}" | wc -l)
    n_union=$( { _shard_unit_files 1/4; _shard_unit_files 2/4; \
                 _shard_unit_files 3/4; _shard_unit_files 4/4; } | wc -l)
    [[ "${n_all}" -eq "${n_union}" ]] || { echo "DUPES"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_shard_unit_files: greedy weight-balance keeps no shard wildly above the @test average (#677)" {
  # The round-robin floor dumped the heaviest specs into one shard (~2x the
  # others). The greedy bin-packing must keep every shard's @test load
  # within a sane factor of the average (total/4); assert the heaviest
  # shard is at most ~1.5x the average so a single big spec can't pin it.
  run bash -c '
    source /source/script/test/test.sh
    total=$(grep -rhcE "^@test" "${REPO_ROOT}"/test/bats/unit/ | paste -sd+ | bc)
    avg=$(( total / 4 ))
    max=0
    for s in 1 2 3 4; do
      load=0
      while IFS= read -r f; do
        [[ -n "${f}" ]] || continue
        c=$(grep -cE "^@test" "${f}")
        load=$(( load + c ))
      done < <(_shard_unit_files "${s}/4")
      echo "shard ${s}/4 load=${load}"
      (( load > max )) && max=${load}
    done
    echo "avg=${avg} max=${max}"
    # heaviest shard must be < 1.5 * avg (round-robin floor was ~2x)
    (( max * 2 < avg * 3 )) || { echo "IMBALANCED"; exit 1; }
    echo BALANCED
  '
  assert_success
  assert_output --partial "BALANCED"
}

@test "_shard_unit_files: rejects an out-of-range shard spec (#615, #692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files 5/4
  '
  assert_failure
  assert_output --partial "Need 1<=n<=total"
}

@test "_shard_unit_files: rejects a no-slash shard spec (#692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files abc
  '
  assert_failure
  assert_output --partial "Expected <n>/<total>"
}

@test "_shard_unit_files: rejects a non-numeric shard spec (#692)" {
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _shard_unit_files a/b
  '
  assert_failure
  assert_output --partial "Need 1<=n<=total"
}

@test "_shard_unit_files: dies ci_empty_shard when a valid shard matches no files (#692)" {
  # Greedy-LPT leaves the tail shards empty whenever total exceeds the spec
  # count. Driven over a fixture REPO_ROOT holding exactly two specs so the
  # Greedy-LPT fills one shard per spec before reusing any, so asking for
  # (spec count + 1) shards leaves the last one empty by construction. The
  # total is DERIVED from the tree rather than hardcoded: an earlier version
  # asked for shard 100/100 on the assumption that the repo would stay under
  # 100 specs, and started passing for the wrong reason once it grew past
  # that. REPO_ROOT is readonly in test.sh, so the count is taken from the
  # same globs the function itself walks.
  run bash -c '
    set -e
    source /source/script/test/test.sh
    shopt -s globstar
    _n=0
    for _f in "${REPO_ROOT}"/test/bats/unit/**/*_spec.bats \
              "${REPO_ROOT}"/test/bats/integration/**/*_spec.bats; do
      [[ -e "${_f}" ]] && _n=$(( _n + 1 ))
    done
    _shard_unit_files "$(( _n + 1 ))/$(( _n + 1 ))"
  '
  assert_failure
  assert_output --partial "No spec files matched"
}

# ════════════════════════════════════════════════════════════════════
# _spec_weight: time-weighted shard partition (ADR-00000008 amend)
#
# The shard partition (greedy LPT in _shard_unit_files) weights each spec
# by RUNTIME, not `@test` count: equal-count specs of unequal duration
# imbalance the shards otherwise. Weight source is a timings file (seconds
# per spec basename) populated automatically from prior CI runs; a spec
# absent from it (new spec / no data yet) falls back to its `@test` count.
# ════════════════════════════════════════════════════════════════════

@test "_spec_weight: returns the recorded seconds from SHARD_WEIGHTS_FILE (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    printf "%s\n" "12 foo_spec.bats" "3 bar_spec.bats" > "${wf}"
    SHARD_WEIGHTS_FILE="${wf}" _spec_weight "/any/path/foo_spec.bats"
  '
  assert_success
  assert_output "12"
}

@test "_spec_weight: falls back to @test count when the spec has no recorded time (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    printf "%s\n" "12 other_spec.bats" > "${wf}"
    spec="${BATS_TEST_TMPDIR}/new_spec.bats"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n" > "${spec}"
    SHARD_WEIGHTS_FILE="${wf}" _spec_weight "${spec}"
  '
  assert_success
  assert_output "2"
}

@test "_spec_weight: falls back to @test count when no SHARD_WEIGHTS_FILE is set (#724)" {
  run bash -c '
    source /source/script/test/test.sh
    spec="${BATS_TEST_TMPDIR}/c_spec.bats"
    printf "@test \"a\" {\n:\n}\n@test \"b\" {\n:\n}\n@test \"c\" {\n:\n}\n" > "${spec}"
    unset SHARD_WEIGHTS_FILE
    _spec_weight "${spec}"
  '
  assert_success
  assert_output "3"
}

@test "_spec_weight: reads the default repo weights file when SHARD_WEIGHTS_FILE is unset (#733)" {
  # CI restores the cached weights to ${REPO_ROOT}/test/bats/.shard-weights
  # (the mounted /source tree), so the in-container coverage run picks them up
  # WITHOUT any -e plumbing. Source only the driver so REPO_ROOT (readonly in
  # test.sh) can point at a tmpdir holding a controlled default weights file.
  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/test/bats"
    printf "%s\n" "42 foo_spec.bats" > "${REPO_ROOT}/test/bats/.shard-weights"
    source /source/script/test/drivers/bats.sh
    unset SHARD_WEIGHTS_FILE
    _spec_weight "/any/path/foo_spec.bats"
  '
  assert_success
  assert_output "42"
}

@test "_shard_unit_files: partitions by recorded time when SHARD_WEIGHTS_FILE is set (#724)" {
  # Give ONE real spec a dominating runtime and everything else ~0; with 2
  # shards, greedy-LPT-by-time must isolate the heavy spec on its own shard.
  # Count-based weighting (which ignores SHARD_WEIGHTS_FILE) would not.
  run bash -c '
    source /source/script/test/test.sh
    specs=$(find "${REPO_ROOT}/test/bats/unit" -name "*_spec.bats" | sort)
    heavy=$(printf "%s\n" "${specs}" | head -1 | xargs -n1 basename)
    wf="${BATS_TEST_TMPDIR}/w.tsv"
    : > "${wf}"
    while IFS= read -r p; do
      [[ -n "${p}" ]] || continue
      b=$(basename "${p}")
      if [[ "${b}" == "${heavy}" ]]; then echo "100000 ${b}"; else echo "1 ${b}"; fi
    done <<< "${specs}" >> "${wf}"
    s1=$(SHARD_WEIGHTS_FILE="${wf}" _shard_unit_files 1/2 | grep -c .)
    s2=$(SHARD_WEIGHTS_FILE="${wf}" _shard_unit_files 2/2 | grep -c .)
    echo "s1=${s1} s2=${s2}"
    { [[ "${s1}" -eq 1 ]] || [[ "${s2}" -eq 1 ]]; } || { echo FAIL; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

# ════════════════════════════════════════════════════════════════════
# _junit_to_timings: capture real per-spec-file kcov-mode runtime
#
# A coverage shard runs `kcov ... bats --report-formatter junit`, which
# emits one <testsuite name=<spec> time=<sec>> per FILE. _junit_to_timings
# turns that report into the `<seconds> <basename>` lines _spec_weight
# reads, so the NEXT run's partition weights by real runtime instead of
# the @test-count fallback. Seconds round to the nearest whole, floored at
# 1 so a sub-second spec still carries a non-zero LPT weight.
# ════════════════════════════════════════════════════════════════════

@test "_junit_to_timings: emits <seconds> <basename> per testsuite, rounded and floored at 1 (#733)" {
  run bash -c '
    source /source/script/test/test.sh
    xml="${BATS_TEST_TMPDIR}/report.xml"
    cat > "${xml}" <<EOF
<?xml version="1.0"?>
<testsuites time="3.6">
  <testsuite name="test/bats/unit/foo_spec.bats" tests="2" time="2.4">
    <testcase classname="x" name="a" time="1.2"/>
  </testsuite>
  <testsuite name="bar_spec.bats" tests="1" time="0.3">
    <testcase classname="x" name="b" time="0.3"/>
  </testsuite>
</testsuites>
EOF
    _junit_to_timings "${xml}"
  '
  assert_success
  # 2.4 -> 2; basename strips the path prefix
  assert_line "2 foo_spec.bats"
  # 0.3 rounds to 0 then floors to 1 (non-zero LPT weight)
  assert_line "1 bar_spec.bats"
}

@test "_junit_to_timings: ignores the <testsuites> root and a missing file is a no-op (#733)" {
  run bash -c '
    source /source/script/test/test.sh
    _junit_to_timings "/no/such/report.xml"
    echo "rc=$?"
  '
  assert_success
  assert_output "rc=0"
}

@test "_run_coverage: writes coverage/timings.tsv from the bats junit report (#733)" {
  # A coverage run records each spec FILE's real kcov-mode runtime so the
  # NEXT partition is time-balanced. Mock kcov to simulate the wrapped
  # `bats --report-formatter junit --output DIR` by dropping a report at the
  # requested dir; assert _run_coverage converts it into coverage/timings.tsv.
  # REPO_ROOT is redirected to a tmpdir so the real mounted /source/coverage
  # is never touched.
  run bash -c '
    # Source only the bats driver (test.sh makes REPO_ROOT readonly, which we
    # must redirect to a tmpdir here); the driver is a pure function library.
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" \
             "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration"
    source /source/script/test/drivers/bats.sh
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat > "${BATS_TEST_TMPDIR}/bin/kcov" <<"SH"
#!/usr/bin/env bash
outdir=""; prev=""
for a in "$@"; do [[ "${prev}" == "--output" ]] && outdir="${a}"; prev="${a}"; done
mkdir -p "${outdir}"
printf "%s\n" "<testsuites><testsuite name=\"mock_spec.bats\" time=\"4.0\"></testsuite></testsuites>" \
  > "${outdir}/report.xml"
exit 0
SH
    chmod +x "${BATS_TEST_TMPDIR}/bin/kcov"
    PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" _run_coverage >/dev/null 2>&1
    cat "${REPO_ROOT}/coverage/timings.tsv"
  '
  assert_success
  assert_output "4 mock_spec.bats"
}

@test "_shard_unit_files: integration specs are partitioned into the pool, not pinned to one shard (#724)" {
  # Previously ALL integration specs ran on the last shard (count-era). They
  # are now folded into the time-balanced pool so an integration spec lands
  # on exactly one shard (still kcov'd once across the matrix) but spread by
  # time.
  run bash -c '
    source /source/script/test/test.sh
    union=$( { _shard_unit_files 1/3; _shard_unit_files 2/3; _shard_unit_files 3/3; } )
    printf "%s\n" "${union}" | grep -q "/test/bats/integration/.*_spec.bats" \
      || { echo MISSING-INTEGRATION; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_run_coverage: shard N/T kcov's only that unit slice, not the whole tree (#615)" {
  # No PATH override: _run_coverage shells out to find/sort/awk via
  # _shard_unit_files. mock_cmd already PREPENDS MOCK_DIR to PATH, so the
  # kcov + bats mocks win while the real coreutils stay reachable.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 1/4
  '
  assert_success
  assert_output --partial "shard 1/4"

  run cat "${_log}"
  assert_success
  # kcov wraps bats over specific shard spec files, not the whole unit dir.
  assert_output --partial "_spec.bats"
  refute_output --partial "test/bats/unit/ bats"
}

@test "_run_coverage: shard targets are individual spec files, never the whole integration dir (#724)" {
  # This supersedes the old last-shard rule: integration specs are folded
  # into the time-balanced pool, so a shard kcov's individual spec FILES
  # (unit + integration mixed) and the whole integration DIR is never a
  # target (which would re-cover all integration on one shard).
  mock_cmd "kcov" 'exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage 2/2
  '
  assert_success
  refute_output --partial "integration suite (last shard)"
  refute_output --regexp 'cov-shard:.*/test/bats/integration/$'
  assert_output --partial "_spec.bats"
}

@test "_run_coverage: no argument keeps the full-suite path (unit + integration) (#615)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage
  '
  assert_success
  assert_output --partial "full suite"

  run cat "${_log}"
  assert_success
  assert_output --partial "test/bats/unit/"
  assert_output --partial "test/bats/integration/"
}

@test "main --coverage-shard: routes to the coverage service with COVERAGE_SHARD set (#615)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-shard 2/4
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
  assert_output --partial "COVERAGE_SHARD=2/4"
}

@test "main --ci with COVERAGE=1 skips the lint phase (lint is a separate matrix concern) (#615)" {
  # The coverage shards are a kcov-only concern; lint is measured by the
  # dedicated shellcheck/hadolint jobs. Running the lint phase once per
  # coverage shard would be wasted work, so COVERAGE=1 deliberately skips
  # it even though the shared test-tools image now ships both linters.
  # Assert the --ci COVERAGE path does NOT shell out to either.
  local _sc_log="${BATS_TEST_TMPDIR}/sc.log"
  local _hd_log="${BATS_TEST_TMPDIR}/hd.log"
  mock_cmd "shellcheck" 'printf "called\n" >> "'"${_sc_log}"'"; exit 0'
  mock_cmd "hadolint" 'printf "called\n" >> "'"${_hd_log}"'"; exit 0'
  mock_cmd "kcov" 'exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    COVERAGE=1 COVERAGE_SHARD=1/4 main --ci
  '
  assert_success
  assert [ ! -f "${_sc_log}" ]
  assert [ ! -f "${_hd_log}" ]
}

@test "main --coverage-shard + --bats-path is rejected (coverage mode guard) (#615)" {
  # --coverage-shard sets coverage mode, which the single-path guard
  # rejects (single-path is the fast no-kcov loop).
  run bash -c '
    source /source/script/test/test.sh
    main --coverage-shard 1/4 --bats-path test/bats/unit/ci_spec.bats
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
}

# ════════════════════════════════════════════════════════════════════
# --bats-fragile: the kcov-fragile unit specs run in plain mode
#
# The coverage matrix is the primary unit gate but SKIPS the kcov-fragile
# tests (guarded by `[ "${COVERAGE:-0}" = 1 ] && skip`). The bats-fragile
# job runs exactly those spec files in plain mode so no unit test goes
# unrun. _fragile_unit_files computes the set at runtime (grep for the skip
# guard) so it self-maintains; these guards pin the contract.
# ════════════════════════════════════════════════════════════════════

@test "_fragile_unit_files: returns exactly the spec files with a kcov-skip guard (#677)" {
  # The runtime-computed set must equal an independent grep for the
  # line-anchored skip guard — a NEW fragile-skip in a 10th file is picked
  # up automatically. The anchor (leading whitespace + literal bracket)
  # excludes comments that merely mention the guard.
  run bash -c '
    source /source/script/test/test.sh
    want=$(grep -rlE "${_FRAGILE_GUARD_RE}" "${REPO_ROOT}/test/bats/unit" | sort)
    got=$(_fragile_unit_files | sort)
    [[ "${want}" == "${got}" ]] || { echo "MISMATCH"; printf "want:\n%s\ngot:\n%s\n" "${want}" "${got}"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_fragile_unit_files: every kcov-skipped file is in the fragile set (no unit test goes unrun) (#677)" {
  # Coverage skips a test only in files in the fragile set; this asserts
  # the inverse direction too — there is NO file containing a kcov-skip
  # guard that is missing from _fragile_unit_files. Together with the
  # coverage partition this proves every unit test runs SOMEWHERE.
  run bash -c '
    source /source/script/test/test.sh
    fragile=$(_fragile_unit_files | sort)
    while IFS= read -r f; do
      [[ -n "${f}" ]] || continue
      printf "%s\n" "${fragile}" | grep -qxF "${f}" \
        || { echo "MISSING: ${f}"; exit 1; }
    done < <(grep -rlE "${_FRAGILE_GUARD_RE}" "${REPO_ROOT}/test/bats/unit" | sort)
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_run_bats_fragile: runs bats over only the fragile spec files, not the whole unit tree (#677)" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_bats_fragile
  '
  assert_success
  assert_output --partial "kcov-fragile"

  run cat "${_log}"
  assert_success
  assert_output --partial "_spec.bats"
  # The whole-unit-dir target must NOT be passed (that is coverage's job).
  refute_output --partial "test/bats/unit/ "
}

@test "_run_bats_fragile: does NOT set COVERAGE=1 so the kcov-skip guards fall through (#677)" {
  # The fragile tests are precisely the ones coverage skips; running them
  # here in PLAIN mode (COVERAGE != 1) is the whole point. Run with
  # COVERAGE explicitly unset in the child shell and assert the runner
  # never turns it into 1.
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "COVERAGE=[%s]\n" "${COVERAGE:-unset}" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    unset COVERAGE
    source /source/script/test/test.sh
    _run_bats_fragile
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "COVERAGE=[unset]"
  refute_output --partial "COVERAGE=[1]"
}

@test "main --bats-fragile: routes to the ci service with BATS_FRAGILE=1 + BATS_ONLY=1, no COVERAGE (#677)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-fragile
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "BATS_FRAGILE=1"
  assert_output --partial "BATS_ONLY=1"
  assert_output --partial "COVERAGE=0"
  refute_output --partial "COVERAGE=1"
}

# ════════════════════════════════════════════════════════════════════
# --bats-path / --filter single-path inner loop
# ════════════════════════════════════════════════════════════════════

@test "main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " ci"
  assert_output --partial "BATS_FILE=test/bats/unit/ci_spec.bats"
  assert_output --partial "BATS_ONLY=1"
  refute_output --partial "COVERAGE=1"
}

@test "main --bats-path: accepts a directory" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "BATS_FILE=test/bats/unit/"
}

@test "main --bats-path: non-existent path dies with ci_bats_path_not_found" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/does_not_exist_spec.bats
  '
  assert_failure
  assert_output --partial "No such spec file or directory"
  refute_output --partial "docker should not be called"
}

@test "main --bats-path: test/bats/system/ path dies with a clear hint" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/system/runtime_test_smoke_spec.bats
  '
  assert_failure
  assert_output --partial "ci-system"
  refute_output --partial "docker should not be called"
}

@test "main --bats-path + --coverage is rejected (ci_bats_path_coverage)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats --coverage
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
}

# ════════════════════════════════════════════════════════════════════
# --coverage-path: ONE spec under kcov instrumentation
#
# The kcov-only failure class ("this spec is red under kcov and green
# without it") had no inner loop: the only instrumented entries were the
# whole suite and a whole shard, 8-12 minutes each, and --bats-path
# refuses --coverage because it is the fast NO-kcov loop. --coverage-path
# is the third mode: kcov wrapping exactly one named spec.
#
# Two properties carry the whole design and are asserted below rather
# than described:
#
#   1. It produces NO coverage figure. The report goes to a throwaway
#      directory inside the container and is deleted, so nothing this
#      mode runs can reach the cobertura/timings artifacts the
#      coverage-gate merges -- a one-spec run must never be able to feed
#      the gate a number.
#   2. It is independent of the shard partition. The spec is named
#      directly, so neither the greedy-LPT bin-packing nor the recorded
#      weights file decides what runs -- the local partition and CI's
#      differ (locally there is no weights file to restore), and
#      "run THIS spec" has to mean the same thing in both.
# ════════════════════════════════════════════════════════════════════

@test "_run_coverage_path: writes nothing into the checkout's coverage/ (#887)" {
  # The gate reads coverage/cobertura.xml + coverage/timings.tsv from the
  # mounted checkout. A single-spec run that dropped either there would
  # hand the merge a partial figure (or reweight the next partition off
  # one spec), so the checkout's coverage/ must come out untouched.
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    _out=""
    for _a in "$@"; do
      case "${_a}" in --*) continue ;; esac
      _out="${_a}"; break
    done
    mkdir -p "${_out}"
    : > "${_out}/cobertura.xml"
    : > "${_out}/index.html"
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" "${REPO_ROOT}/test/bats/unit"
    : > "${REPO_ROOT}/coverage/sentinel"
    : > "${REPO_ROOT}/test/bats/unit/one_spec.bats"
    source /source/script/test/drivers/bats.sh
    _run_coverage_path test/bats/unit/one_spec.bats >/dev/null
    ls -A "${REPO_ROOT}/coverage"
  '
  assert_success
  assert_output "sentinel"
}

@test "_run_coverage_path: the kcov report dir is a throwaway outside the checkout, removed after the run (#887)" {
  local _log="${BATS_TEST_TMPDIR}/outdir.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    _out=""
    for _a in "$@"; do
      case "${_a}" in --*) continue ;; esac
      _out="${_a}"; break
    done
    printf "%s\n" "${_out}" >> "'"${_log}"'"
    mkdir -p "${_out}"
    : > "${_out}/cobertura.xml"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
    _out="$(cat "'"${_log}"'")"
    [[ -n "${_out}" ]] || { echo "KCOV-NEVER-RAN"; exit 1; }
    [[ "${_out}" != "${REPO_ROOT}"* ]] \
      || { echo "REPORT-INSIDE-CHECKOUT: ${_out}"; exit 1; }
    [[ ! -e "${_out}" ]] || { echo "REPORT-DIR-LEFT-BEHIND: ${_out}"; exit 1; }
    echo OK
  '
  assert_success
  assert_output --partial "OK"
}

@test "_run_coverage_path: kcov's exactly the named spec, never a shard slice (#887)" {
  # A weights file is planted that a greedy-LPT partition would honour, so
  # a re-implementation routed through _shard_unit_files would pull in the
  # other specs. Naming the spec must mean that spec and nothing else --
  # this is what makes the entry point behave identically on a host with no
  # restored .shard-weights and on CI where the cache restores one.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/test/bats/unit" "${REPO_ROOT}/test/bats/integration"
    for _n in a b c d; do
      printf "@test \"%s\" { :; }\n" "${_n}" > "${REPO_ROOT}/test/bats/unit/${_n}_spec.bats"
    done
    printf "%s\n" "90 a_spec.bats" "1 b_spec.bats" "80 c_spec.bats" "70 d_spec.bats" \
      > "${REPO_ROOT}/test/bats/.shard-weights"
    _die() { echo "DIE: $*"; exit 1; }
    source /source/script/test/drivers/bats.sh
    _run_coverage_path test/bats/unit/b_spec.bats >/dev/null
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "/test/bats/unit/b_spec.bats"
  refute_output --partial "a_spec.bats"
  refute_output --partial "c_spec.bats"
  refute_output --partial "d_spec.bats"
}

@test "_run_coverage_path: instruments with the same include/exclude set a coverage shard uses (#887)" {
  # The point of the mode is to reproduce what the coverage shard does to
  # one spec. Instrument a different tree than the shard does and the
  # red-under-kcov failure it exists to reproduce may not reproduce, so
  # the two runners must hand kcov the same paths.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    for _a in "$@"; do
      case "${_a}" in
        --include-path=*|--exclude-path=*) printf "%s\n" "${_a}" >> "'"${_log}"'" ;;
      esac
    done
    exit 0'

  run bash -c '
    REPO_ROOT="${BATS_TEST_TMPDIR}/repo"
    mkdir -p "${REPO_ROOT}/coverage" "${REPO_ROOT}/test/bats/unit" \
             "${REPO_ROOT}/test/bats/integration"
    printf "@test \"a\" { :; }\n" > "${REPO_ROOT}/test/bats/unit/a_spec.bats"
    printf "@test \"b\" { :; }\n" > "${REPO_ROOT}/test/bats/unit/b_spec.bats"
    _die() { echo "DIE: $*"; exit 1; }
    source /source/script/test/drivers/bats.sh
    _run_coverage 1/2 >/dev/null
    _run_coverage_path test/bats/unit/b_spec.bats >/dev/null
    _n="$(wc -l < "'"${_log}"'")"
    [[ "${_n}" -eq 4 ]] \
      || { echo "EXPECTED-TWO-INSTRUMENTED-RUNS-GOT-${_n}-PATH-ARGS"; exit 1; }
    _shard="$(head -2 "'"${_log}"'")"
    _single="$(tail -2 "'"${_log}"'")"
    [[ "${_shard}" == "${_single}" ]] \
      || { printf "shard:\n%s\nsingle:\n%s\n" "${_shard}" "${_single}"; exit 1; }
    printf "%s\n" "${_single}"
  '
  assert_success
  assert_output --partial "--include-path=${BATS_TEST_TMPDIR}/repo"
  assert_output --partial "--exclude-path="
}

@test "_run_coverage_path: propagates the spec's exit status so a red spec is a red run (#887)" {
  # The entry point exists to be a red-green loop. A runner that swallowed
  # the failure would report green on the exact run whose whole purpose is
  # to show the spec failing under instrumentation.
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" 'exit 3'

  run bash -c '
    source /source/script/test/test.sh
    _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
    echo "rc=$?"
  '
  assert_success
  assert_output "rc=3"
}

@test "_run_coverage_path: BATS_FILTER appends a bats -f name filter (#887)" {
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "bats" 'exit 0'
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    BATS_FILTER="SIGTERM" _run_coverage_path test/bats/unit/ci_spec.bats >/dev/null
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "-f SIGTERM"
  assert_output --partial "test/bats/unit/ci_spec.bats"
}

@test "main --coverage-path: routes one spec to the coverage service with COVERAGE_PATH + BATS_ONLY=1 (#887)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --filter shard
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial " coverage"
  assert_output --partial "COVERAGE=1"
  assert_output --partial "COVERAGE_PATH=test/bats/unit/ci_spec.bats"
  assert_output --partial "BATS_FILTER=shard"
  assert_output --partial "BATS_ONLY=1"
  # Never a shard: the mode names its target, it does not partition.
  refute_output --regexp 'COVERAGE_SHARD=[0-9]'
}

@test "main --ci: COVERAGE=1 with COVERAGE_PATH runs the one spec and reports no coverage figure (#887)" {
  # The in-container dispatch must branch BEFORE _run_coverage, which
  # kcov's the whole suite and writes coverage/timings.tsv + the report
  # line into the mounted checkout.
  local _log="${BATS_TEST_TMPDIR}/kcov.log"
  mock_cmd "kcov" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "bats" 'exit 0'

  run bash -c '
    source /source/script/test/test.sh
    COVERAGE=1 COVERAGE_PATH=test/bats/unit/ci_spec.bats main --ci
  '
  assert_success
  refute_output --partial "Coverage report:"
  refute_output --partial "full suite"

  run cat "${_log}"
  assert_success
  assert_output --partial "test/bats/unit/ci_spec.bats"
  refute_output --partial "/test/bats/integration/ "
}

@test "main --coverage-path: non-existent path dies before docker is called (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/does_not_exist_spec.bats
  '
  assert_failure
  assert_output --partial "No such spec file or directory"
  refute_output --partial "docker should not be called"
}

@test "main --coverage-path: test/bats/system/ dies with the ci-system hint (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/system/runtime_test_smoke_spec.bats
  '
  assert_failure
  assert_output --partial "ci-system"
  refute_output --partial "docker should not be called"
}

@test "main --coverage-path + --coverage-shard is rejected (#887)" {
  # One asks for a figure over a partition, the other for instrumentation
  # over one named spec. Silently letting one win would be how a one-spec
  # run ends up uploaded as a shard.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --coverage-shard 1/4
  '
  assert_failure
  assert_output --partial "--coverage-path"
  assert_output --partial "cannot combine"
  refute_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

@test "main --coverage-path + --bats-path is rejected (#887)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --coverage-path test/bats/unit/ci_spec.bats --bats-path test/bats/unit/lib_spec.bats
  '
  assert_failure
  assert_output --partial "--coverage-path"
  assert_output --partial "cannot combine"
  refute_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

@test "main --bats-path + --coverage stays rejected: the fast loop is still kcov-free (#887)" {
  # --coverage-path did NOT lift the original refusal. --bats-path is the
  # no-kcov loop by definition; combining it with --coverage would have
  # meant one flag pair with two runners behind it.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bats-path test/bats/unit/ci_spec.bats --coverage
  '
  assert_failure
  assert_output --partial "cannot combine with --coverage"
  assert_output --partial "--coverage-path"
  refute_output --partial "docker should not be called"
}

@test "main: unknown option dies with ci_unknown_option (#692)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --bogus
  '
  assert_failure
  assert_output --partial "Unknown option"
  refute_output --partial "docker should not be called"
}

@test "main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)" {
  # `--hadolint` narrows --lint; standalone is the easy-to-make typo for
  # --hadolint-only. It must fail loudly, not silently no-op.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --hadolint
  '
  assert_failure
  assert_output --partial "narrows --lint"
  refute_output --partial "docker should not be called"
}

@test "main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)" {
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=bogus main --ci
  '
  assert_failure
  assert_output --partial "Unknown LINT_TOOL"
}

@test "main --ci: LINT_TOOL=stale-setup-conf runs the stale setup.conf lint (#845)" {
  # Wiring guard: the lint must reach the CI gate, not only an Edit-time
  # hook. An unwired tool falls through to the ci_unknown_lint_tool branch
  # (the test above), so a passing run here proves the dispatch case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=stale-setup-conf main --ci
  '
  assert_success
  assert_output --partial "stale setup.conf path lint: clean"
}

@test "main --ci: LINT_TOOL=readme-sync runs the localized README sync lint (#846)" {
  # Wiring guard: the translation drift guard must reach the CI gate, not
  # only the on-demand generator. An unwired tool falls through to the
  # ci_unknown_lint_tool branch, so a passing run here proves the dispatch
  # case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=readme-sync main --ci
  '
  assert_success
  assert_output --partial "localized README sync lint: clean"
}

@test "main --ci: LINT_TOOL=doc-counts runs the doc/test count drift gate (#864)" {
  # Wiring guard: the doc-count drift gate must reach the CI gate, not only
  # `just test sync-docs-check` and the advisory harness hook. An unwired
  # tool falls through to the ci_unknown_lint_tool branch, so a passing run
  # here proves the dispatch case exists.
  run bash -c '
    source /source/script/test/test.sh
    LINT_ONLY=1 LINT_TOOL=doc-counts main --ci
  '
  assert_success
  assert_output --partial "doc/test count drift gate: clean"
}

@test "main --doc-counts-only: runs the drift gate on the host, no compose (#864)" {
  # CI-reachability guard. The lint phase runs in `just test`, but no CI job
  # runs it: the GHA lint jobs are shellcheck (--shellcheck-only) and
  # hadolint (--lint --hadolint), and every bats job passes BATS_ONLY=1,
  # which skips the phase. So the gate needs a host-direct primitive the
  # plain ubuntu-latest runner can call -- the same shape as
  # --shellcheck-only. Docker must not be touched on this path.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --doc-counts-only
  '
  assert_success
  assert_output --partial "doc/test count drift gate: clean"
  refute_output --partial "docker should not be called"
}

@test "main --issueref-only: runs the issue-ref comment lint on the host, no compose (#866)" {
  # CI-reachability guard, same shape as --doc-counts-only / --shellcheck-only.
  # The lint phase is what enforces ADR-00000013, and no CI job ran that
  # phase, so the rule gated nothing on a PR. The lint-static matrix entry
  # calls this primitive on a plain ubuntu-latest runner; docker must not be
  # touched on the path.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --issueref-only
  '
  assert_success
  assert_output --partial "issue-ref comment lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --adr-numbering-only: runs the ADR-numbering lint on the host, no compose (#866)" {
  # Ungated in CI on purpose: doc/adr/ filenames are a doc-only change, so a
  # code_changed gate would skip the lint on exactly the PR that duplicates
  # an ADR number. That only works if the lint is host-direct.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --adr-numbering-only
  '
  assert_success
  assert_output --partial "ADR-numbering lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --stale-setup-conf-only: runs the stale setup.conf path lint on the host, no compose (#866)" {
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --stale-setup-conf-only
  '
  assert_success
  assert_output --partial "stale setup.conf path lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --home-literal-only: runs the hardcoded home path lint on the host, no compose (#799)" {
  # Same CI-reachability shape as the sibling primitives: the lint-static
  # matrix entry calls this on a plain ubuntu-latest runner, so the driver
  # must be pure bash over the checkout and never touch docker.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --home-literal-only
  '
  assert_success
  assert_output --partial "hardcoded home path lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main --readme-sync-only: runs the localized README sync lint on the host, no compose (#866)" {
  # The clearest case for an ungated CI job: a README.md edit that leaves a
  # translation behind is a doc-only change end to end.
  mock_cmd "docker" 'echo "docker should not be called"; exit 1'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"':${PATH}"
    main --readme-sync-only
  '
  assert_success
  assert_output --partial "localized README sync lint: clean"
  refute_output --partial "docker should not be called"
}

@test "main: _LINT_TOOLS is the one table every lint-phase caller dispatches through (#866)" {
  # Three callers used to repeat the tool list (the full phase, the
  # in-container LINT_TOOL narrowing, the host-direct --<tool>-only
  # primitives), so a new lint could be wired into one and missed by the
  # others. They now share this table, which is also what the
  # self-test.yaml completeness guard reads to prove every lint has a CI
  # job.
  run bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${_LINT_TOOLS[@]}"
  '
  assert_success
  assert_line "shellcheck"
  assert_line "hadolint"
  assert_line "issueref"
  assert_line "adr-numbering"
  assert_line "stale-setup-conf"
  assert_line "readme-sync"
  assert_line "doc-counts"
  assert_line "home-literal"
}

@test "main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    main --filter cap_add
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "BATS_FILTER=cap_add"
  assert_output --partial "BATS_ONLY=1"
  assert_output --partial "BATS_FILE= "
}

@test "_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="test/bats/unit/ci_spec.bats" BATS_FILTER="shard" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/ci_spec.bats"
  assert_output --partial "-f shard"
}

@test "_run_bats_path: filter-only runs bats across unit + integration" {
  local _log="${BATS_TEST_TMPDIR}/bats.log"
  mock_cmd "bats" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    BATS_FILE="" BATS_FILTER="cap_add" _run_bats_path
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "test/bats/unit/"
  assert_output --partial "test/bats/integration/"
  assert_output --partial "-f cap_add"
}

# ════════════════════════════════════════════════════════════════════
# Dispatcher + per-tool driver structure (ADR-00000011 #5)
#
# test.sh is the dispatcher; the per-tool execution lives in sourced
# driver libraries under script/test/drivers/. These guards pin the
# split so a future refactor can't silently re-inline a tool or drop a
# `source` line.
# ════════════════════════════════════════════════════════════════════

@test "drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist" {
  assert [ -f /source/script/test/drivers/bats.sh ]
  assert [ -f /source/script/test/drivers/shellcheck.sh ]
  # hadolint joins the per-tool drivers so it runs in BOTH `just
  # test` and the CI hadolint job (local==CI single source).
  assert [ -f /source/script/test/drivers/hadolint.sh ]
}

@test "drivers: test.sh sources all per-tool drivers" {
  run grep -F 'source "${SCRIPT_DIR}/drivers/shellcheck.sh"' /source/script/test/test.sh
  assert_success
  run grep -F 'source "${SCRIPT_DIR}/drivers/hadolint.sh"' /source/script/test/test.sh
  assert_success
  run grep -F 'source "${SCRIPT_DIR}/drivers/bats.sh"' /source/script/test/test.sh
  assert_success
}

@test "drivers: the bats runners live in drivers/bats.sh, not test.sh" {
  # Each runner must be defined once (in the driver), and NOT re-inlined
  # back into the dispatcher.
  local _fn
  for _fn in _run_unit_tests _run_integration_tests _run_unit_shard \
             _run_bats_fragile _run_bats_path _run_system _run_coverage \
             _bats_args_with_label; do
    run grep -E "^${_fn}\(\) \{" /source/script/test/drivers/bats.sh
    assert_success
    run grep -E "^${_fn}\(\) \{" /source/script/test/test.sh
    assert_failure
  done
}

@test "drivers: _run_shellcheck lives in drivers/shellcheck.sh, not test.sh" {
  run grep -E '^_run_shellcheck\(\) \{' /source/script/test/drivers/shellcheck.sh
  assert_success
  run grep -E '^_run_shellcheck\(\) \{' /source/script/test/test.sh
  assert_failure
}

@test "drivers: _run_hadolint lives in drivers/hadolint.sh, not test.sh (#650)" {
  run grep -E '^_run_hadolint\(\) \{' /source/script/test/drivers/hadolint.sh
  assert_success
  run grep -E '^_run_hadolint\(\) \{' /source/script/test/test.sh
  assert_failure
}

@test "drivers: are sourced libraries (no top-level main invocation)" {
  run grep -E '^main "\$@"' /source/script/test/drivers/bats.sh
  assert_failure
  run grep -E '^main "\$@"' /source/script/test/drivers/shellcheck.sh
  assert_failure
  run grep -E '^main "\$@"' /source/script/test/drivers/hadolint.sh
  assert_failure
}

@test "drivers: _run_shellcheck also lints the driver files themselves" {
  local _log="${BATS_TEST_TMPDIR}/shellcheck.log"
  mock_cmd "shellcheck" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_shellcheck
  '
  assert_success
  run cat "${_log}"
  assert_output --partial "script/test/drivers"
}

# ════════════════════════════════════════════════════════════════════
# _run_hadolint (ADR-00000011)
#
# Single source of truth for the Dockerfiles + config the self-test
# lints. These guards pin the exact file list + config so the driver
# can't silently drift from the self-test.yaml hadolint job (which now
# runs THIS driver, not the hadolint-action).
# ════════════════════════════════════════════════════════════════════

@test "_run_hadolint: lints every Dockerfile in the tree with the shared config" {
  local _log="${BATS_TEST_TMPDIR}/hadolint.log"
  mock_cmd "hadolint" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_success

  assert [ -f "${_log}" ]
  run cat "${_log}"
  # Every Dockerfile the repo carries, with the dist/.hadolint.yaml config
  # (single source of truth). A Dockerfile no lint pass names is a
  # Dockerfile whose next edit is unchecked, which is how the tooling one
  # was linted only by a CI action before this driver existed.
  assert_output --partial "--config /source/dist/.hadolint.yaml"
  assert_output --partial "dist/dockerfile/Dockerfile"
  assert_output --partial "dockerfile/Dockerfile.test-tools"
  assert_output --partial "dockerfile/Dockerfile.smoke"
}

@test "_run_hadolint: the linted list is every Dockerfile the tree carries" {
  # The list is hand-maintained (the CI hadolint job invokes this driver,
  # so it has to be a constant, not a glob evaluated at some other cwd).
  # This is what notices a Dockerfile added beside the others and never
  # added to it.
  local _found _listed
  _found="$( (cd /source && ls dockerfile/Dockerfile.* dist/dockerfile/Dockerfile) | sort)"
  _listed="$(bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${_HADOLINT_DOCKERFILES[@]}"' | sort)"
  [[ "${_found}" == "${_listed}" ]]
}

@test "_run_hadolint: invokes hadolint once per Dockerfile (no extra targets)" {
  local _log="${BATS_TEST_TMPDIR}/hadolint.log"
  mock_cmd "hadolint" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  run bash -c '
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_success
  # One hadolint invocation per listed Dockerfile, no extras.
  local _n
  _n="$(bash -c '
    source /source/script/test/test.sh
    printf "%s\n" "${#_HADOLINT_DOCKERFILES[@]}"')"
  run grep -c -- '--config' "${_log}"
  assert_output "${_n}"
}

@test "_run_hadolint: dies with a clear message when hadolint is absent" {
  # The host has no hadolint binary; the driver must fail loudly pointing
  # at the test-tools container path, not silently no-op.
  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_hadolint
  '
  assert_failure
  assert_output --partial "hadolint not in PATH"
}

@test "_run_hadolint: exits non-zero when hadolint fails on any Dockerfile" {
  mock_cmd "hadolint" '
    for _arg in "$@"; do
      if [[ "${_arg}" == *"Dockerfile.test-tools" ]]; then
        printf "DL3000 fake violation\n" >&2
        exit 1
      fi
    done
    exit 0'
  run bash -c '
    set -e
    source /source/script/test/test.sh
    _run_hadolint
  '
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _system_setup prerequisite guards (drivers/bats.sh)
# ════════════════════════════════════════════════════════════════════
#
# _system_setup fails fast with two distinct _die calls when the
# system prerequisites are absent. Both guards probe SYSTEM_DOCKER_SOCK
# (default /var/run/docker.sock), so each test points it at its OWN
# BATS_TEST_TMPDIR path: the socket-absent test needs a path that does not
# exist, the CLI-absent test creates a transient socket at its path so the
# socket guard passes first. Per-test paths eliminate the race the two
# tests used to have on the shared process-global /var/run/docker.sock
# under parallel bats jobs.

@test "_system_setup: dies ci_no_docker_socket when the docker socket is absent (#692)" {
  local _sock="${BATS_TEST_TMPDIR}/absent.sock"
  run env SYSTEM_DOCKER_SOCK="${_sock}" bash -c '
    set -e
    source /source/script/test/test.sh
    _system_setup
  '
  assert_failure
  assert_output --partial "requires ${_sock}"
}

@test "_system_setup: dies ci_no_docker_cli when docker is not on PATH (#692)" {
  # Create a transient unix socket at a per-test path so the socket guard
  # passes, then run with a PATH that omits docker to hit the CLI guard.
  local _sock="${BATS_TEST_TMPDIR}/present.sock"
  perl -e 'use IO::Socket::UNIX; my $p = $ARGV[0]; unlink $p; IO::Socket::UNIX->new(Type=>SOCK_STREAM, Local=>$p, Listen=>1) or die $!;' "${_sock}"
  local _clean="${BATS_TEST_TMPDIR}/nodocker"
  mkdir -p "${_clean}"
  local _cmd _src
  for _cmd in bash sh env cat printf date grep sed find sort awk mktemp \
              dirname basename id tr head tail cut wc rm mkdir ln cp test pwd; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_src}" "${_clean}/${_cmd}"
  done
  run env PATH="${_clean}" SYSTEM_DOCKER_SOCK="${_sock}" bash -c '
    set -e
    source /source/script/test/test.sh
    _system_setup
  '
  assert_failure
  assert_output --partial "requires docker CLI"
}

# ════════════════════════════════════════════════════════════════════
# _compute_test_tools_hash / _resolve_test_tools_image
#
# The local tooling tag used to be the fixed literal `test-tools:local`,
# written identically by every checkout on the host. A sibling run
# rebuilding it displaced the image a live run was already using, with no
# error anywhere: kcov vanished from the image mid-pass and the pass still
# reported green. The tag is now keyed to the build inputs -- identical
# inputs resolve to one tag (a build-cache hit, NOT a rebuild), any input
# difference resolves to a tag that cannot clobber the other.
# ════════════════════════════════════════════════════════════════════

@test "_resolve_test_tools_image: different tooling inputs resolve to different tags (#891)" {
  local _a="${BATS_TEST_TMPDIR}/a.Dockerfile"
  local _b="${BATS_TEST_TMPDIR}/b.Dockerfile"
  printf 'FROM alpine:3.21\nRUN apk add --no-cache kcov\n' > "${_a}"
  printf 'FROM alpine:3.21\n' > "${_b}"

  run bash -c '
    source /source/script/test/test.sh
    unset TEST_TOOLS_IMAGE
    _resolve_test_tools_image "'"${_a}"'"
    _resolve_test_tools_image "'"${_b}"'"
  '
  assert_success
  assert [ "${lines[0]}" != "${lines[1]}" ]
  [[ "${lines[0]}" =~ ^test-tools:[0-9a-f]{12}$ ]]
  [[ "${lines[1]}" =~ ^test-tools:[0-9a-f]{12}$ ]]
}

@test "_resolve_test_tools_image: identical inputs at different paths resolve to the same tag (#891)" {
  # The cache contract: two checkouts whose tooling Dockerfile is
  # byte-identical must land on ONE tag, so the second build is a cache hit
  # rather than a rebuild. The checkout path must therefore not enter the
  # digest.
  local _a="${BATS_TEST_TMPDIR}/one/Dockerfile.test-tools"
  local _b="${BATS_TEST_TMPDIR}/two/Dockerfile.test-tools"
  mkdir -p "${BATS_TEST_TMPDIR}/one" "${BATS_TEST_TMPDIR}/two"
  printf 'FROM alpine:3.21\nRUN apk add --no-cache kcov\n' > "${_a}"
  cp "${_a}" "${_b}"

  run bash -c '
    source /source/script/test/test.sh
    unset TEST_TOOLS_IMAGE
    _resolve_test_tools_image "'"${_a}"'"
    _resolve_test_tools_image "'"${_b}"'"
  '
  assert_success
  assert [ "${lines[0]}" = "${lines[1]}" ]
}

@test "_resolve_test_tools_image: TEST_TOOLS_IMAGE wins verbatim (#891)" {
  # CI pins published, version-scoped tags through this env
  # (build-worker / publish-worker / release-test-tools), and
  # self-test.yaml pins test-tools:local. The derivation must never
  # rewrite a caller-pinned value.
  run bash -c '
    source /source/script/test/test.sh
    TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:v9.9.9 \
      _resolve_test_tools_image "/source/dockerfile/Dockerfile.test-tools"
  '
  assert_success
  assert_output "ghcr.io/ycpss91255-docker/test-tools:v9.9.9"
}

@test "_resolve_test_tools_image: fails loud when the tooling Dockerfile is missing (#891)" {
  # No bare-literal fallback: a silent `test-tools:local` here would resolve
  # to whatever another checkout last built.
  run bash -c '
    source /source/script/test/test.sh
    unset TEST_TOOLS_IMAGE
    _resolve_test_tools_image "'"${BATS_TEST_TMPDIR}"'/absent.Dockerfile"
  '
  assert_failure
  assert_output --partial "absent.Dockerfile"
}

@test "main --test-tools-image: prints the resolved tag for the justfile (#891)" {
  # The single entry point the `just test system` recipe reads, so the
  # build-only test-tools service and the ci-system consumer cannot
  # disagree about which tag this run means.
  run bash -c '
    unset TEST_TOOLS_IMAGE
    /source/script/test/test.sh --test-tools-image
  '
  assert_success
  [[ "${output}" =~ ^test-tools:[0-9a-f]{12}$ ]]
}

# ════════════════════════════════════════════════════════════════════
# _compute_compose_project_name / _resolve_compose_project_name
#
# `docker compose run` was invoked with no `-p`, so compose fell back to
# the checkout DIRECTORY BASENAME. Two checkouts at ~/a/base and ~/b/base
# therefore shared one project -- one set of containers, one network --
# with no warning. The project name is now derived from the ABSOLUTE
# checkout path, which is the actual discriminator (two worktrees are
# routinely on the same commit, so a commit-keyed name would collide in
# exactly the concurrent case this separates).
# ════════════════════════════════════════════════════════════════════

@test "_compute_compose_project_name: two checkouts sharing a basename get different names (#891)" {
  run bash -c '
    source /source/script/test/test.sh
    _n=""
    _compute_compose_project_name "/home/dev/a/base" _n; printf "%s\n" "${_n}"
    _compute_compose_project_name "/home/dev/b/base" _n; printf "%s\n" "${_n}"
  '
  assert_success
  [[ "${lines[0]}" =~ ^base-[0-9a-f]{12}$ ]]
  [[ "${lines[1]}" =~ ^base-[0-9a-f]{12}$ ]]
  assert [ "${lines[0]}" != "${lines[1]}" ]
}

@test "_compute_compose_project_name: the same checkout path is stable across calls (#891)" {
  # Keyed to the path, not the commit or the run: a checkout keeps ONE
  # project (and one network) instead of churning a fresh one per commit.
  run bash -c '
    source /source/script/test/test.sh
    _n=""
    _compute_compose_project_name "/home/dev/a/base" _n; printf "%s\n" "${_n}"
    _compute_compose_project_name "/home/dev/a/base" _n; printf "%s\n" "${_n}"
  '
  assert_success
  assert [ "${lines[0]}" = "${lines[1]}" ]
}

@test "_compute_compose_project_name: a hostile checkout path still yields a legal project name (#891)" {
  # Compose accepts only [a-z0-9][a-z0-9_-]* and a checkout path can hold
  # anything: spaces, uppercase, punctuation, non-ASCII, a leading dot.
  # The derivation has to guarantee the grammar, not hope for it.
  run bash -c '
    source /source/script/test/test.sh
    _n=""
    _compute_compose_project_name "/home/Dev/.My Projects/(BASE) #1/ünïcode/BASE/" _n
    printf "%s\n" "${_n}"
  '
  assert_success
  [[ "${output}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

@test "_resolve_compose_project_name: COMPOSE_PROJECT_NAME wins verbatim (#891)" {
  # CI keys the project to its run id through this env; the derivation is a
  # local default only.
  run bash -c '
    source /source/script/test/test.sh
    COMPOSE_PROJECT_NAME=ci-run-4242 _resolve_compose_project_name
  '
  assert_success
  assert_output "ci-run-4242"
}

@test "_run_via_compose: passes an explicit -p so the project is not the directory basename (#891)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    unset COMPOSE_PROJECT_NAME
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --regexp "compose -p base-[0-9a-f]{12} "
}

@test "_run_via_compose: honours COMPOSE_PROJECT_NAME (#891)" {
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    export COMPOSE_PROJECT_NAME=ci-run-4242
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "compose -p ci-run-4242 "
}

@test "_run_via_compose: hands compose the very tag the tooling resolver prints (#896)" {
  # compose.yaml names every service's image ${TEST_TOOLS_IMAGE} with NO
  # default, so this runner resolves it -- and it must be the SAME value
  # `just docker build --target test-tools` writes, not a second derivation
  # that happens to agree. Exported, because compose reads it while
  # interpolating the file on the host, not inside the container.
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s|%s\n" "${TEST_TOOLS_IMAGE:-<unset>}" "$*" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" 'echo 1000'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    unset TEST_TOOLS_IMAGE
    _run_via_compose ci 0
  '
  assert_success

  local _resolved
  _resolved="$(unset TEST_TOOLS_IMAGE; /source/script/test/test.sh --test-tools-image)"
  run grep -F "${_resolved}|compose -p" "${_log}"
  assert_success
}

@test "_ensure_test_tools_image: builds the derived tag when the host does not have it (#896)" {
  # The derived tag is local-only -- no registry can serve it -- so an
  # absent one means "not built yet", never "pull it". It is built through
  # the same compose service the docker namespace builds.
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    [[ "${1}" == "image" ]] && exit 1
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    unset TEST_TOOLS_IMAGE
    _ensure_test_tools_image test-tools:abc123abc123 base-000000000000
  '
  assert_success

  run cat "${_log}"
  assert_output --partial "compose -p base-000000000000 -f /source/compose.yaml build test-tools"
}

@test "_ensure_test_tools_image: leaves a caller-pinned image alone (#896)" {
  # CI pins a published GHCR tag, or an in-run tag it built itself, and
  # provisioning it is the caller's job -- building over it here would
  # replace what the caller asked for.
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    [[ "${1}" == "image" ]] && exit 1
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    export TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:v9.9.9
    _ensure_test_tools_image "${TEST_TOOLS_IMAGE}" base-000000000000
  '
  assert_success

  run cat "${_log}"
  refute_output --partial "build test-tools"
}

@test "_ensure_test_tools_image: does not rebuild a tag the host already has (#896)" {
  # Identical tooling inputs resolve to one tag on purpose: the second run
  # is a cache HIT, not a rebuild.
  local _log="${BATS_TEST_TMPDIR}/docker.log"
  mock_cmd "docker" '
    printf "%s\n" "$*" >> "'"${_log}"'"
    exit 0'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    unset TEST_TOOLS_IMAGE
    _ensure_test_tools_image test-tools:abc123abc123 base-000000000000
  '
  assert_success

  run cat "${_log}"
  refute_output --partial "build test-tools"
}

@test "main --compose-project-name: prints the resolved project for the justfile (#891)" {
  # The `just test system` recipe reads this so its bare `docker compose run`
  # names the project the same way test.sh's does, instead of inheriting the
  # directory basename at a second call site.
  run bash -c '
    unset COMPOSE_PROJECT_NAME
    /source/script/test/test.sh --compose-project-name
  '
  assert_success
  [[ "${output}" =~ ^base-[0-9a-f]{12}$ ]]
}

@test "_compute_compose_project_name: fails loud when the digest cannot be produced (#891)" {
  # A short/empty digest would degrade to the bare `base-` prefix -- a name
  # EVERY checkout resolves, i.e. the collision this derivation exists to
  # prevent, reintroduced silently.
  local _clean="${BATS_TEST_TMPDIR}/nosha"
  mkdir -p "${_clean}"
  printf '#!/bin/bash\nexit 0\n' > "${_clean}/sha256sum"
  chmod +x "${_clean}/sha256sum"
  local _cmd _src
  for _cmd in bash cut printf date grep sed tr head; do
    _src="$(command -v "${_cmd}" 2>/dev/null)" && ln -sf "${_src}" "${_clean}/${_cmd}"
  done

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${_clean}"'"
    _n=""
    _compute_compose_project_name "/home/dev/a/base" _n
  '
  assert_failure
  assert_output --partial "no usable digest"
}

# ════════════════════════════════════════════════════════════════════
# HOST_UID / HOST_GID: the ownership of everything the suite writes
#
# The self-test containers run against a bind-mounted checkout, so these
# two decide who owns the files the suite leaves in the working tree.
# compose used to substitute 1000 when they were absent, which on any host
# whose developer is not uid 1000 wrote files owned by a stranger and said
# nothing. The fallback is gone, so every path that reaches compose has to
# supply them -- and `-e HOST_UID=...` does NOT: that sets the variable
# inside the container, while compose's own `${HOST_UID}` interpolation
# reads the environment of the `docker compose` process.
# ════════════════════════════════════════════════════════════════════

@test "_run_via_compose: the real ids are in the environment compose interpolates (#895)" {
  local _log="${BATS_TEST_TMPDIR}/docker-env.log"
  mock_cmd "docker" '
    printf "uid=%s gid=%s\n" "${HOST_UID:-UNSET}" "${HOST_GID:-UNSET}" >> "'"${_log}"'"
    exit 0'
  mock_cmd "id" '
    case "${1}" in
      -u) echo 4242 ;;
      -g) echo 4243 ;;
    esac'

  run bash -c '
    source /source/script/test/test.sh
    export PATH="'"${MOCK_DIR}"'"
    _run_via_compose ci 0
  '
  assert_success

  run cat "${_log}"
  assert_success
  assert_output --partial "uid=4242 gid=4243"
}

@test "_fix_permissions: refuses a non-numeric id instead of handing it to chown (#895)" {
  # A junk id reaches `chown` as a username, and `chown -R nobody:` on a
  # tree the suite just wrote is not a diagnostic anyone wants to read
  # backwards from. Say which variable is wrong.
  local _dir="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${_dir}/coverage"
  run env HOST_UID="root " HOST_GID=1000 bash -c '
    source /source/script/test/test.sh
    REPO_ROOT="'"${_dir}"'"
    _fix_permissions
  '
  assert_failure
  assert_output --partial "HOST_UID"
}
