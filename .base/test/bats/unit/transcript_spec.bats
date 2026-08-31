#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/lib/transcript.sh.
#
# The wrapper transcript tees a non-interactive verb's combined output to
# log/<verb>/<ts>-<traceid8>.log (ANSI stripped) with a per-verb
# latest.log symlink, an exit-code+duration closing line, retention, and
# an atexit registry that owns the single EXIT trap. Pure helpers are
# tested directly; the tee + EXIT-finalize is exercised end-to-end by
# running a tiny harness in a subshell.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/log.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/transcript.sh
  TMP_DIR="$(mktemp -d)"
  TRANSCRIPT_SH="/source/dist/script/docker/lib/transcript.sh"
  LOG_SH="/source/dist/script/docker/lib/log.sh"
  # The self-test runner exports WRAPPER_TRANSCRIPT=false globally so
  # other specs never write a log/ tree into the checkout. This spec is the
  # one that exercises the conf-based enable logic, so clear the env override
  # here and let each test set it explicitly.
  unset WRAPPER_TRANSCRIPT
}

teardown() { rm -rf "${TMP_DIR}"; }

# ── verb classification ─────────────────────────────────────────────

@test "_transcript_is_full_verb: the 5 non-interactive verbs are captured (#606)" {
  for _v in build setup stop prune upgrade; do
    run _transcript_is_full_verb "${_v}"
    assert_success
  done
}

@test "_transcript_is_full_verb: interactive verbs + unknown are NOT captured (#606)" {
  for _v in run exec setup_tui "" foo; do
    run _transcript_is_full_verb "${_v}"
    assert_failure
  done
}

@test "_transcript_is_interactive_verb: run/exec/setup_tui yes; full verbs + unknown no (#608)" {
  for _v in run exec setup_tui; do
    run _transcript_is_interactive_verb "${_v}"
    assert_success
  done
  for _v in build setup stop prune upgrade "" foo; do
    run _transcript_is_interactive_verb "${_v}"
    assert_failure
  done
}

@test "_transcript_is_capture_verb: every full + interactive verb captures; unknown does not (#608)" {
  for _v in build setup stop prune upgrade run exec setup_tui; do
    run _transcript_is_capture_verb "${_v}"
    assert_success
  done
  for _v in "" foo; do
    run _transcript_is_capture_verb "${_v}"
    assert_failure
  done
}

# ── filename + meta line ────────────────────────────────────────────

@test "_transcript_filename: <root>/log/<verb>/<ts>-<traceid8>.log (#606)" {
  run _transcript_filename /repo build 20260618T101112Z deadbeef
  assert_output "/repo/log/build/20260618T101112Z-deadbeef.log"
}

@test "_transcript_meta_line: formats an lnav-parseable level line (#606)" {
  _WRAPPER_VERB=build run _transcript_meta_line INFO "transcript_complete exit_code=0"
  assert_output --partial "[build] INFO"
  assert_output --partial "transcript_complete exit_code=0"
}

# ── trace id resolution ─────────────────────────────────────────────

@test "_transcript_resolve_traceid: inherits a well-formed TRACEPARENT trace_id (#606)" {
  local _tid=""
  TRACEPARENT="00-0123456789abcdef0123456789abcdef-aabbccddeeff0011-01" \
    _transcript_resolve_traceid _tid
  assert_equal "${_tid}" "0123456789abcdef0123456789abcdef"
  assert_equal "${_TRANSCRIPT_TRACE_SOURCE}" "inherited"
}

@test "_transcript_resolve_traceid: generates a 32-hex id when TRACEPARENT absent (#606)" {
  local _tid=""
  unset TRACEPARENT
  _transcript_resolve_traceid _tid
  [[ "${_tid}" =~ ^[0-9a-f]{32}$ ]]
  assert_equal "${_TRANSCRIPT_TRACE_SOURCE}" "generated"
}

# ── enabled / kill switch ───────────────────────────────────────────

@test "_transcript_enabled: true by default when no setup.conf (#606)" {
  FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_success
}

@test "_transcript_enabled: false when wrapper_transcript = false (#606)" {
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/.setup.conf"
  FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
}

@test "_transcript_enabled: WRAPPER_TRANSCRIPT=false env wins over conf=true (#622)" {
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = true\n' > "${TMP_DIR}/.setup.conf"
  WRAPPER_TRANSCRIPT=false FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
}

@test "_transcript_enabled: WRAPPER_TRANSCRIPT=true env wins over conf=false (#622)" {
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/.setup.conf"
  WRAPPER_TRANSCRIPT=true FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_success
}

@test "_transcript_enabled: a non-boolean WRAPPER_TRANSCRIPT is refused, not ignored (#895)" {
  # The override outranks a conf key the user set and can read back in
  # `setup.sh show`, so a typo silently handing the decision BACK to that
  # key is the worst outcome: the user believes the environment won and
  # sees no sign that it did not. Refuse the run instead.
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = true\n' > "${TMP_DIR}/.setup.conf"
  WRAPPER_TRANSCRIPT=flase FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
  assert_output --partial "WRAPPER_TRANSCRIPT"
  assert_output --partial "flase"
}

@test "_transcript_enabled: an empty WRAPPER_TRANSCRIPT means unset, not invalid (#895)" {
  # `WRAPPER_TRANSCRIPT=` is how a caller clears an inherited override, and
  # `env -u` is not always available to it. Empty defers to the conf key.
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/.setup.conf"
  WRAPPER_TRANSCRIPT= FILE_PATH="${TMP_DIR}" run _transcript_enabled
  assert_failure
  refute_output --partial "WRAPPER_TRANSCRIPT"
}

# ── atexit registry ─────────────────────────────────────────────────

@test "_atexit: registered callbacks run LIFO on exit (#606)" {
  run bash -c "
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    a() { printf 'a\n'; }; b() { printf 'b\n'; }
    _atexit a; _atexit b
  "
  assert_success
  # b registered last -> runs first.
  assert_line --index 0 "b"
  assert_line --index 1 "a"
}

# ── retention ───────────────────────────────────────────────────────

@test "_transcript_prune: keeps the N most recent, drops the rest (#606)" {
  local _d="${TMP_DIR}/log/build"
  mkdir -p "${_d}"
  local _i
  for _i in $(seq -w 1 25); do
    printf 'x\n' > "${_d}/2026010${_i}.log"
    touch -d "2026-01-01 00:00:${_i}" "${_d}/2026010${_i}.log" 2>/dev/null || true
  done
  _transcript_prune "${_d}" 20 3650
  run bash -c "ls ${_d}/*.log | wc -l"
  assert_output "20"
}

@test "_transcript_prune: keep=0 would delete every transcript (#691)" {
  # Pins the raw behaviour of prune itself: with keep=0 the count-based
  # drop removes ALL *.log files. This is why the read-side guard in
  # _transcript_begin MUST reject 0 (see next test) -- the validator
  # already does (^[1-9][0-9]*$), but a hand-edited setup.conf bypasses it.
  local _d="${TMP_DIR}/log/build"
  mkdir -p "${_d}"
  printf 'a\n' > "${_d}/a.log"
  printf 'b\n' > "${_d}/b.log"
  _transcript_prune "${_d}" 0 3650
  run bash -c "ls ${_d}/*.log 2>/dev/null | wc -l"
  assert_output "0"
}

@test "_transcript_begin: hand-edited wrapper_transcript_keep=0 is rejected, falls back to 20 (#691)" {
  # The validator rejects 0 (>=1) but the Apply/read path does not
  # revalidate; the read-side guard must reject an out-of-range 0 so a
  # hand-edited setup.conf cannot drive prune with keep=0 (wipe-all).
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript_keep = 0\n' \
    > "${TMP_DIR}/.setup.conf"
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'KEEP=%s\n' \"\${_TRANSCRIPT_KEEP}\"
    exit 0
  "
  assert_success
  assert_output --partial "KEEP=20"
}

@test "_transcript_prune: drops files older than <days> regardless of count (#606)" {
  local _d="${TMP_DIR}/log/build"
  mkdir -p "${_d}"
  printf 'old\n' > "${_d}/old.log"; touch -d "60 days ago" "${_d}/old.log"
  printf 'new\n' > "${_d}/new.log"; touch -d "1 day ago" "${_d}/new.log"
  _transcript_prune "${_d}" 20 14
  assert [ ! -f "${_d}/old.log" ]
  assert [ -f "${_d}/new.log" ]
}

# ── end-to-end: tee + finalize ──────────────────────────────────────

_run_transcript_harness() {  # <verb> <extra-env...>
  local _verb="$1"; shift
  run bash -c "
    export _WRAPPER_VERB='${_verb}' FILE_PATH='${TMP_DIR}' ${*}
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'plain stdout line\n'
    printf '\033[1;31mcolored\033[0m\n'
    printf 'to stderr\n' >&2
    exit 0
  "
}

@test "transcript: a full verb produces log/<verb>/<ts>-<id>.log with content (#606)" {
  _run_transcript_harness build
  assert_success
  # output still reaches the caller (tee is transparent)
  assert_output --partial "plain stdout line"
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "plain stdout line"
  assert_output --partial "to stderr"
}

@test "transcript: the file is ANSI-stripped while the terminal keeps colour (#606)" {
  _run_transcript_harness build
  # the caller saw the raw ANSI...
  assert_output --partial $'\033[1;31m'
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log | head -n1)"
  # ...but the file has the escape stripped.
  run grep -F $'\033[' "${_f}"
  assert_failure
  run grep -F "colored" "${_f}"
  assert_success
}

@test "transcript: closing line carries the exit code + duration (#606)" {
  _run_transcript_harness build
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log | head -n1)"
  run grep -F "transcript_complete exit_code=0" "${_f}"
  assert_success
  assert_output --partial "duration="
}

@test "transcript: a non-zero wrapper exit is recorded AND propagated (#691)" {
  # The whole point of the transcript is to record FAILING runs, yet the
  # shared harness always exits 0. Here the wrapper exits 7: the EXIT
  # handler must (a) write transcript_complete exit_code=7 to the file and
  # (b) `return "${_rc}"` so the real code reaches the caller (`just`),
  # not get swallowed/rewritten by finalize (wait/rm clobbering $?).
  run -7 bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'work then fail\n'
    exit 7
  "
  # (a) exit code propagated to the caller.
  assert_equal "${status}" 7
  assert_output --partial "work then fail"
  # (b) the recorded closing line carries the real non-zero code.
  local _f
  _f="$(ls "${TMP_DIR}/log/build/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run grep -F "transcript_complete exit_code=7" "${_f}"
  assert_success
}

@test "transcript: latest.log symlink points at the run's file (#606)" {
  _run_transcript_harness build
  assert [ -L "${TMP_DIR}/log/build/latest.log" ]
  run cat "${TMP_DIR}/log/build/latest.log"
  assert_output --partial "plain stdout line"
}

@test "transcript: wrapper_transcript=false is a complete no-op (no file) (#606)" {
  mkdir -p "${TMP_DIR}"
  printf '[logging]\nwrapper_transcript = false\n' > "${TMP_DIR}/.setup.conf"
  _run_transcript_harness build
  assert_success
  assert_output --partial "plain stdout line"
  assert [ ! -d "${TMP_DIR}/log/build" ]
}

# ── degrade-to-no-op failure branches ───────────────────────────────
#
# _transcript_begin has three failure-safe branches that must keep the
# wrapper running (return 0, WARN only) when the logging substrate is
# unavailable. A regression turning any into a hard failure would break
# every wrapper on a read-only checkout or a tee-less image, silently.

@test "_transcript_begin: mkdir-fail degrades to no-op + WARN, wrapper continues (#691)" {
  # Make log/ a regular FILE so `mkdir -p log/build` cannot succeed.
  printf '' > "${TMP_DIR}/log"
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}' LOG_FORMAT=text
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    rc=\$?
    printf 'wrapper still runs\n'
    exit \"\${rc}\"
  " 2>&1
  assert_success
  assert_output --partial "wrapper still runs"
  assert_output --partial "transcript_dir_create_failed"
  # No transcript directory was created (log/ is still the file).
  assert [ -f "${TMP_DIR}/log" ]
  assert [ ! -d "${TMP_DIR}/log/build" ]
}

@test "_transcript_begin: file-unwritable degrades to no-op + WARN (#691)" {
  # mkdir succeeds, but the raw capture path `: > <file>.raw` must fail.
  # chmod-based write denial is bypassed by root (the harness runs as
  # root), so instead PRE-CREATE the exact raw path as a DIRECTORY (the
  # same root-proof trick the entrypoint-logging spec uses): `: >` onto a
  # directory always fails. The raw path is deterministic once we pin both
  # the trace id (via TRACEPARENT) and the timestamp (via a `date` stub).
  local _bin="${TMP_DIR}/datestub"
  mkdir -p "${_bin}"
  local _real_date; _real_date="$(command -v date)"
  cat > "${_bin}/date" <<STUB
#!/usr/bin/env bash
# Fixed UTC filename timestamp; delegate every other date call to the real binary.
if [[ "\$*" == *"%Y%m%dT%H%M%SZ"* ]]; then
  printf '20260625T000000Z\n'
  exit 0
fi
exec "${_real_date}" "\$@"
STUB
  chmod +x "${_bin}/date"
  local _tid8="0123456789abcdef0123456789abcdef"
  local _raw="${TMP_DIR}/log/build/20260625T000000Z-${_tid8:0:8}.log.raw"
  mkdir -p "${_raw}"   # occupy the raw path with a directory -> `: >` fails
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}' LOG_FORMAT=text
    export TRACEPARENT='00-${_tid8}-aabbccddeeff0011-01'
    export PATH='${_bin}:'\"\${PATH}\"
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    rc=\$?
    printf 'wrapper still runs\n'
    exit \"\${rc}\"
  " 2>&1
  assert_success
  assert_output --partial "wrapper still runs"
  assert_output --partial "transcript_file_unwritable"
}

@test "_transcript_begin: tee-missing degrades to no-op + WARN (#691)" {
  # The tee-less PATH stub perturbs the kcov coverage wrapper (which itself
  # shells out through PATH), not the helper; the degrade path is covered by
  # the plain bats-unit run. Skip only under coverage.
  [ "${COVERAGE:-0}" = 1 ] && skip "tee-less PATH stub perturbs the kcov wrapper (#613)"
  # Build a stub PATH that has every external _transcript_begin reaches
  # BEFORE the tee check (mkdir, date) but NOT tee, so `command -v tee`
  # fails and the begin must warn-and-continue.
  local _bin="${TMP_DIR}/stubbin"
  mkdir -p "${_bin}"
  local _t
  for _t in bash mkdir date rm ls head od tr cat dirname basename grep; do
    ln -s "$(command -v "${_t}")" "${_bin}/${_t}" 2>/dev/null || true
  done
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}' LOG_FORMAT=text
    export PATH='${_bin}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    rc=\$?
    printf 'wrapper still runs\n'
    exit \"\${rc}\"
  " 2>&1
  assert_success
  assert_output --partial "wrapper still runs"
  assert_output --partial "transcript_tee_missing"
}

# ──interactive verbs (orchestration capture + detach) ────────

@test "transcript: an interactive verb without detach full-captures (the run -d path) (#608)" {
  _run_transcript_harness run
  assert_success
  assert_output --partial "plain stdout line"
  local _f
  _f="$(ls "${TMP_DIR}/log/run/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "plain stdout line"
}

@test "transcript: _transcript_detach captures orchestration only, not the interactive session (#608)" {
  run bash -c "
    export _WRAPPER_VERB=exec FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_begin
    printf 'orchestration phase\n'
    _transcript_detach
    printf 'interactive session output\n'
    exit 0
  "
  assert_success
  # both lines still reach the caller's terminal
  assert_output --partial "orchestration phase"
  assert_output --partial "interactive session output"
  local _f
  _f="$(ls "${TMP_DIR}/log/exec/"*.log 2>/dev/null | head -n1)"
  assert [ -n "${_f}" ]
  run cat "${_f}"
  assert_output --partial "orchestration phase"
  assert_output --partial "transcript_detached"
  refute_output --partial "interactive session output"
}

@test "transcript: _transcript_detach is a no-op when the transcript never began (#608)" {
  run bash -c "
    export _WRAPPER_VERB=build FILE_PATH='${TMP_DIR}'
    source ${LOG_SH}; source ${TRANSCRIPT_SH}
    _transcript_detach
    printf 'ok\n'
  "
  assert_success
  assert_output --partial "ok"
}

# ── wiring guards ───────────────────────────────────────────────────

@test "wiring: the 5 full verbs call _transcript_begin (#606)" {
  for _w in build stop prune setup; do
    run grep -qF '_transcript_begin' "/source/dist/script/docker/wrapper/${_w}.sh"
    assert_success
  done
  run grep -qF '_transcript_begin' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "wiring: run/exec/setup_tui call both _transcript_begin and _transcript_detach (#608)" {
  for _w in run exec setup_tui; do
    run grep -qF '_transcript_begin' "/source/dist/script/docker/wrapper/${_w}.sh"
    assert_success
    run grep -qF '_transcript_detach' "/source/dist/script/docker/wrapper/${_w}.sh"
    assert_success
  done
}
