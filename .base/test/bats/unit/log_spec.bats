#!/usr/bin/env bats
#
# log_spec.bats - Tests for OTel-aligned log.sh.
# Single-sink tty-detect dispatch: text on TTY, JSON on non-TTY.
# LOG_FORMAT=auto|text|json override. Strict body enforcement.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LOG_SH="/source/dist/script/docker/lib/log.sh"
}

# ── Text output format (LOG_FORMAT=text) ──────────────────────────

@test "_log_info text output has timestamp + aligned level + tag" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  assert_equal "${stderr}" ""
  [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [[ "${output}" == *"[setup] INFO : env_regenerated" ]]
}

@test "_log_err text output to stderr with timestamp" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_err build build_no_env"
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
  [[ "${stderr}" == *"[build] ERROR: build_no_env" ]]
}

@test "_log_warn text output uses WARN (not WARNING)" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_warn run run_no_env"
  assert_success
  [[ "${stderr}" =~ 'WARN : run_no_env'$ ]]
}

@test "_log_debug text output to stdout" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_debug build dry_run_cmd"
  assert_success
  [[ "${output}" =~ 'DEBUG: dry_run_cmd'$ ]]
  assert_equal "${stderr}" ""
}

@test "_log_fatal text output to stderr" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_fatal init init_missing_required_arg"
  assert_success
  [[ "${stderr}" =~ 'FATAL: init_missing_required_arg'$ ]]
}

@test "text levels are right-aligned to 5 chars" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}
    _log_info  setup env_regenerated
    _log_debug setup dry_run_cmd
  "
  assert_success
  [[ "${lines[0]}" =~ 'INFO : env_regenerated'$ ]]
  [[ "${lines[1]}" =~ 'DEBUG: dry_run_cmd'$ ]]
}

@test "text output joins multi-token message with spaces" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_err build build_no_env word2 word3"
  assert_success
  [[ "${stderr}" =~ 'ERROR: build_no_env word2 word3'$ ]]
}

@test "text output skips attr=val args in message" {
  run bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp conf_hash=abc"
  assert_success
  [[ "${output}" =~ 'INFO : env_regenerated'$ ]]
  refute_line --partial "ws_path"
}

@test "text output uses display= attribute over body when present" {
  run bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated 'display=Env regenerated OK' ws_path=/tmp"
  assert_success
  [[ "${output}" =~ 'INFO : Env regenerated OK'$ ]]
  refute_line --partial "env_regenerated"
  refute_line --partial "ws_path"
}

@test "JSON includes display= as attribute alongside registered body" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated 'display=Env regenerated OK'"
  assert_success
  [[ "${output}" == *'"body":"env_regenerated"'* ]]
  [[ "${output}" == *'"display":"Env regenerated OK"'* ]]
}

# ── Timestamp: UTC + microsecond ───────────────────────────

@test "text timestamp is UTC with microsecond precision" {
  run bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z ]]
}

@test "JSON timestamp is UTC with microsecond precision" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  local ts
  ts="$(printf '%s' "${output}" | grep -o '"timestamp":"[^"]*"')"
  [[ "${ts}" =~ \"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z\" ]]
}

# ── Stream routing (LOG_FORMAT=text) ──────────────────────────────

@test "_log_info and _log_debug route to stdout" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated; _log_debug setup dry_run_cmd"
  assert_success
  assert_equal "${stderr}" ""
  [[ "${output}" == *"env_regenerated"* ]]
  [[ "${output}" == *"dry_run_cmd"* ]]
}

@test "_log_warn _log_err _log_fatal route to stderr" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}
    _log_warn  setup xauth_rewrite_failed
    _log_err   setup conf_invalid_value
    _log_fatal setup conf_unknown_subcmd
  "
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" == *"WARN"* ]]
  [[ "${stderr}" == *"ERROR"* ]]
  [[ "${stderr}" == *"FATAL"* ]]
}

# ── Single-sink tty-detect dispatch ────────────────────────

@test "non-TTY stdout emits JSON by default (auto-detect)" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp"
  assert_success
  [[ "${output}" == *'"severity_text":"INFO"'* ]]
  [[ "${output}" == *'"body":"env_regenerated"'* ]]
  [[ "${output}" == *'"ws_path":"/tmp"'* ]]
}

@test "non-TTY stderr emits JSON for _log_err" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_err build build_no_env"
  assert_success
  assert_equal "${output}" ""
  [[ "${stderr}" == *'"severity_text":"ERROR"'* ]]
  [[ "${stderr}" == *'"body":"build_no_env"'* ]]
}

@test "LOG_FORMAT=text forces text output on non-TTY" {
  run bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" =~ 'INFO : env_regenerated'$ ]]
  [[ "${output}" != *'"severity_text"'* ]]
}

@test "LOG_FORMAT=json forces JSON output" {
  run bash -c "
    export LOG_FORMAT=json
    source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" == *'"severity_text":"INFO"'* ]]
  [[ "${output}" == *'"body":"env_regenerated"'* ]]
}

@test "LOG_FORMAT=auto is equivalent to unset (non-TTY -> JSON)" {
  local out_auto out_unset
  out_auto="$(bash -c "export LOG_FORMAT=auto; source ${LOG_SH}; _log_info setup env_regenerated" 2>/dev/null)"
  out_unset="$(bash -c "unset LOG_FORMAT; source ${LOG_SH}; _log_info setup env_regenerated" 2>/dev/null)"
  [[ "${out_auto}" == *'"severity_text":"INFO"'* ]]
  [[ "${out_unset}" == *'"severity_text":"INFO"'* ]]
}

# ── Startup TTY cache (_LOG_IS_TTY) ─────────────────────────
#
# A later transcript tee on fd1 makes `test -t 1` false mid-run,
# which would flip the live terminal to JSON / no-color. _LOG_IS_TTY
# caches the run's real TTY-ness at startup (return code: 0 = tty,
# non-zero = not) so the auto-format + color decisions survive the tee.
# Unset -> live `test -t` fallback (standalone sourcing ==).

@test "_log_is_tty helper is defined after sourcing (#605)" {
  run bash -c "source ${LOG_SH}; declare -F _log_is_tty"
  assert_success
}

@test "_log_is_tty: cached 0 wins over a non-TTY fd (#605)" {
  run bash -c "export _LOG_IS_TTY=0; source ${LOG_SH}; _log_is_tty 1"
  assert_success
}

@test "_log_is_tty: cached non-zero wins over the live probe (#605)" {
  run bash -c "export _LOG_IS_TTY=1; source ${LOG_SH}; _log_is_tty 1"
  assert_failure
}

@test "_log_is_tty: unset falls back to live test -t (non-TTY pipe -> non-zero) (#605)" {
  run bash -c "unset _LOG_IS_TTY; source ${LOG_SH}; _log_is_tty 1"
  assert_failure
}

@test "auto dispatch: _LOG_IS_TTY=0 forces text even on a non-TTY pipe (#605)" {
  run bash -c "export _LOG_IS_TTY=0; source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" =~ 'INFO : env_regenerated'$ ]]
  [[ "${output}" != *'"severity_text"'* ]]
}

@test "auto dispatch: _LOG_IS_TTY unset preserves live detection (non-TTY -> JSON) (#605)" {
  run bash -c "unset _LOG_IS_TTY; source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" == *'"severity_text":"INFO"'* ]]
}

@test "explicit LOG_FORMAT=json ignores _LOG_IS_TTY=0 (cache scoped to auto) (#605)" {
  run bash -c "export LOG_FORMAT=json _LOG_IS_TTY=0; source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" == *'"severity_text":"INFO"'* ]]
}

@test "explicit LOG_FORMAT=text ignores _LOG_IS_TTY=1 (cache scoped to auto) (#605)" {
  run bash -c "export LOG_FORMAT=text _LOG_IS_TTY=1; source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
  [[ "${output}" =~ 'INFO : env_regenerated'$ ]]
  [[ "${output}" != *'"severity_text"'* ]]
}

@test "_log_color_enabled honours _LOG_IS_TTY=0 on a non-TTY (#605)" {
  run bash -c "source ${LOG_SH}; _LOG_IS_TTY=0 _log_color_enabled 1"
  assert_success
}

@test "_log_color_enabled with _LOG_IS_TTY=1 stays disabled (#605)" {
  run bash -c "source ${LOG_SH}; _LOG_IS_TTY=1 _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled: NO_COLOR wins over _LOG_IS_TTY=0 (#605)" {
  run bash -c "source ${LOG_SH}; NO_COLOR=1 _LOG_IS_TTY=0 _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled: FORCE_COLOR wins over _LOG_IS_TTY=1 (#605)" {
  run bash -c "source ${LOG_SH}; FORCE_COLOR=1 _LOG_IS_TTY=1 _log_color_enabled 1"
  assert_success
}

# ── JSON output format (non-TTY auto-detect) ─────────────────────

@test "JSON output contains OTel fields" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp"
  assert_success
  [[ "${output}" == *'"timestamp":'* ]]
  [[ "${output}" == *'"severity_text":"INFO"'* ]]
  [[ "${output}" == *'"severity_number":9'* ]]
  [[ "${output}" == *'"body":"env_regenerated"'* ]]
  [[ "${output}" == *'"service.name":"setup"'* ]]
  [[ "${output}" == *'"service.lang":"bash"'* ]]
  [[ "${output}" == *'"code.filepath":'* ]]
  [[ "${output}" == *'"code.lineno":'* ]]
  [[ "${output}" == *'"thread.id":'* ]]
}

@test "JSON output contains custom attributes" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated ws_path=/tmp conf_hash=abc123"
  assert_success
  [[ "${output}" == *'"ws_path":"/tmp"'* ]]
  [[ "${output}" == *'"conf_hash":"abc123"'* ]]
}

@test "JSON severity_number: DEBUG=5 INFO=9 WARN=13 ERROR=17 FATAL=21" {
  run bash -c "
    source ${LOG_SH}
    _log_debug build dry_run_cmd
    _log_info  setup env_regenerated
  "
  assert_success
  [[ "${output}" == *'"severity_number":5'* ]]
  [[ "${output}" == *'"severity_number":9'* ]]

  run bash -c "
    source ${LOG_SH}
    _log_warn  setup xauth_rewrite_failed
    _log_err   setup conf_invalid_value
    _log_fatal init  init_missing_required_arg
  " 2>/dev/null
  assert_success
  local combined="${output}${stderr}"
  [[ "${combined}" == *'"severity_number":13'* ]]
  [[ "${combined}" == *'"severity_number":17'* ]]
  [[ "${combined}" == *'"severity_number":21'* ]]
}

# ── JSON escaping (_log_json_escape) ──────────────────────────────
#
# _log_json_escape is the only thing keeping JSON well-formed when an
# attribute value / key / service / body carries a metacharacter. Every
# other JSON test feeds clean values, so a regression in the escaper
# (dropped backslash-doubling, inverted substitution order, an
# unhandled control char) would still pass them. These pin each escape
# explicitly: `"`, `\`, newline, tab, CR.

# Inputs are built with printf into a variable so the metacharacters are
# unambiguous (no nested-quoting guesswork over the bats -> bash -c hop).
@test "_log_json_escape escapes a double-quote" {
  source "${LOG_SH}"
  run _log_json_escape 'a"b'
  assert_success
  assert_output 'a\"b'
}

@test "_log_json_escape doubles a lone backslash (no double-escape)" {
  source "${LOG_SH}"
  local _in; printf -v _in 'a\\b'   # a<backslash>b
  run _log_json_escape "${_in}"
  assert_success
  assert_output 'a\\b'              # one backslash in -> two out (not four)
}

@test "_log_json_escape escapes newline tab and carriage-return" {
  source "${LOG_SH}"
  local _in; printf -v _in 'x\ny\tz\r'
  run _log_json_escape "${_in}"
  assert_success
  assert_output 'x\ny\tz\r'
}

@test "_log_json_escape applies substitutions in order (backslash before quote)" {
  source "${LOG_SH}"
  # A backslash directly before a quote must become \\ then \" -> \\\" ,
  # never \" + a stray doubled backslash. Pins the substitution ordering.
  local _in; printf -v _in '%s' '\"'   # backslash then quote
  run _log_json_escape "${_in}"
  assert_success
  assert_output '\\\"'
}

@test "JSON attribute value with quote/backslash/tab is escaped and line stays well-formed" {
  source "${LOG_SH}"
  local _v; printf -v _v 'say "hi"\tend\\done'   # quote, tab, backslash
  run _log_info setup env_regenerated "note=${_v}"
  assert_success
  # The escaped substring appears verbatim in the JSON.
  [[ "${output}" == *'"note":"say \"hi\"\tend\\done"'* ]]
  # Line is still a single well-formed JSON object.
  [[ "${output}" == "{"*"}" ]]
  [[ "${output}" == *'"body":"env_regenerated"'* ]]
}

@test "JSON output is valid per-line (starts with { ends with })" {
  run bash -c "
    source ${LOG_SH}
    _log_info setup env_regenerated
    _log_info setup env_drift_detected
  "
  assert_success
  local count=0
  local line
  while IFS= read -r line; do
    [[ "${line}" == "{"*"}" ]]
    [[ "${line}" == *'"timestamp":'* ]]
    [[ "${line}" == *'"body":'* ]]
    count=$(( count + 1 ))
  done <<< "${output}"
  [[ "${count}" -eq 2 ]]
}

# ── TRACEPARENT in JSON ───────────────────────────────────────────

@test "JSON includes trace_id and span_id when TRACEPARENT is set" {
  run bash -c "
    export TRACEPARENT='00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01'
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
  [[ "${output}" == *'"trace_id":"0af7651916cd43dd8448eb211c80319c"'* ]]
  [[ "${output}" == *'"span_id":"b7ad6b7169203331"'* ]]
}

@test "JSON omits trace_id when TRACEPARENT is unset" {
  run bash -c "
    unset TRACEPARENT
    source ${LOG_SH}
    _log_info setup env_regenerated
  "
  assert_success
  [[ "${output}" != *'"trace_id"'* ]]
}

# ── Strict body enforcement ────────────────────────────────

@test "unregistered body causes fatal exit" {
  run bash -c "source ${LOG_SH}; _log_info setup not_a_real_event"
  assert_failure
  [[ "${output}${stderr}" == *'unregistered'* ]]
  [[ "${output}${stderr}" == *'not_a_real_event'* ]]
}

@test "registered body succeeds normally" {
  run bash -c "source ${LOG_SH}; _log_info setup env_regenerated"
  assert_success
}

@test "empty body is allowed (no strict check)" {
  run bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}; _log_info setup"
  assert_success
}

@test "strict body error names the offending body and log-events.txt" {
  run bash -c "source ${LOG_SH}; _log_info setup typo_event_name"
  assert_failure
  [[ "${output}${stderr}" == *'typo_event_name'* ]]
  [[ "${output}${stderr}" == *'log-events.txt'* ]]
}

# ── Missing service is rejected ────────────────────────────────────

@test "_log_info with no args exits non-zero" {
  run -127 bash -c "source ${LOG_SH}; _log_info"
}

@test "_log_err with no args exits non-zero" {
  run -127 bash -c "source ${LOG_SH}; _log_err"
}

# ── _log_fatal does NOT auto-exit ──────────────────────────────────

@test "_log_fatal does not exit; caller controls exit" {
  run --separate-stderr bash -c "
    export LOG_FORMAT=text
    source ${LOG_SH}
    _log_fatal init init_missing_required_arg
    echo 'still running'
  "
  assert_success
  assert_equal "${output}" "still running"
}

# ── Scoped wrappers ────────────────────────────────────────────────

@test "_log_with_trace sets TRACEPARENT and restores prior value" {
  run bash -c "
    source ${LOG_SH}
    export TRACEPARENT='00-aaaa0000aaaa0000aaaa0000aaaa0000-bbbb0000bbbb0000-01'
    _log_with_trace bash -c 'echo \$TRACEPARENT' 2>/dev/null
    echo \"restored=\${TRACEPARENT}\"
  "
  assert_success
  assert_line --partial "00-"
  assert_line "restored=00-aaaa0000aaaa0000aaaa0000aaaa0000-bbbb0000bbbb0000-01"
}

@test "_log_with_trace without prior TRACEPARENT unsets on return" {
  run bash -c "
    unset TRACEPARENT
    source ${LOG_SH}
    _log_with_trace bash -c 'echo inside=\$TRACEPARENT' 2>/dev/null
    echo \"after=\${TRACEPARENT:-unset}\"
  "
  assert_success
  assert_line --partial "inside=00-"
  assert_line "after=unset"
}

@test "_log_with_span preserves trace_id from parent" {
  run bash -c "
    export TRACEPARENT='00-deadbeef00000000deadbeef00000000-1111111111111111-01'
    source ${LOG_SH}
    _log_with_span child_op bash -c 'echo \$TRACEPARENT'
    echo \"restored=\${TRACEPARENT}\"
  "
  assert_success
  assert_line --regexp "^00-deadbeef00000000deadbeef00000000-[0-9a-f]{16}-01$"
  assert_line "restored=00-deadbeef00000000deadbeef00000000-1111111111111111-01"
}

@test "_log_with_trace prints trace started message to stderr" {
  run --separate-stderr bash -c "source ${LOG_SH}; _log_with_trace true"
  assert_success
  [[ "${stderr}" == *"[trace started:"* ]]
}

# ── _log_plain removed ─────────────────────────────────────

@test "_log_plain is no longer defined" {
  run bash -c "source ${LOG_SH}; declare -F _log_plain"
  assert_failure
}

# ── _log_color_enabled ─────────────────────────────────────────────

@test "_log_color_enabled returns non-zero on non-TTY without overrides" {
  run bash -c "source ${LOG_SH}; _log_color_enabled 1"
  assert_failure
}

@test "_log_color_enabled returns 0 with FORCE_COLOR=1" {
  run bash -c "FORCE_COLOR=1 source ${LOG_SH}; FORCE_COLOR=1 _log_color_enabled 1"
  assert_success
}

@test "_log_color_enabled returns non-zero with NO_COLOR=1 + FORCE_COLOR=1" {
  run bash -c "NO_COLOR=1 FORCE_COLOR=1 source ${LOG_SH}; NO_COLOR=1 FORCE_COLOR=1 _log_color_enabled 1"
  assert_failure
}

# ── FORCE_COLOR text ───────────────────────────────────────────────

@test "_log_err FORCE_COLOR=1 emits red bold ANSI in text" {
  run --separate-stderr bash -c "
    export FORCE_COLOR=1 LOG_FORMAT=text
    source ${LOG_SH}; _log_err build build_no_env"
  assert_success
  [[ "${stderr}" == *$'\033[1;31m'* ]]
  [[ "${stderr}" == *"ERROR"* ]]
  [[ "${stderr}" == *"build_no_env"* ]]
}

@test "_log_warn FORCE_COLOR=1 emits yellow ANSI in text" {
  run --separate-stderr bash -c "
    export FORCE_COLOR=1 LOG_FORMAT=text
    source ${LOG_SH}; _log_warn run run_no_env"
  assert_success
  [[ "${stderr}" == *$'\033[33m'* ]]
  [[ "${stderr}" == *"WARN"* ]]
}

@test "NO_COLOR=1 text omits ANSI" {
  run --separate-stderr bash -c "
    export NO_COLOR=1 FORCE_COLOR=1 LOG_FORMAT=text
    source ${LOG_SH}; _log_err build build_no_env"
  assert_success
  [[ "${stderr}" != *$'\033['* ]]
  [[ "${stderr}" == *"ERROR: build_no_env"* ]]
}

# ── Event registry ─────────────────────────────────────────────────

@test "log-events.txt is loaded and contains env_regenerated" {
  run bash -c "source ${LOG_SH}; _log_is_registered env_regenerated && echo yes"
  assert_output "yes"
}

@test "unregistered event returns false" {
  run bash -c "source ${LOG_SH}; _log_is_registered not_a_real_event || echo no"
  assert_output "no"
}

@test "log-events.txt comment lines are not registered as events" {
  run bash -c "source ${LOG_SH}; _log_is_registered '# setup.sh' || echo no"
  assert_output "no"
}

# ── lnav format file ──────────────────────────────────────────────

@test "log.lnav-format.json exists and contains format key" {
  local _f="/source/dist/script/docker/lib/log.lnav-format.json"
  [[ -f "${_f}" ]]
  run grep -q '"ycpss91255_otel_log"' "${_f}"
  assert_success
}

@test "log.lnav-format.json declares json: true" {
  run grep -q '"json": true' /source/dist/script/docker/lib/log.lnav-format.json
  assert_success
}

# ── _dry_run_cmd (-B) ──────────────────────────────────────────
#
# Unifies the wrapper dry-run dispatch: under DRY_RUN=true it prints the
# planned command (`[dry-run]` + %q-quoted argv) and does NOT execute;
# otherwise it runs the command verbatim. Plain command echo (NOT a
# structured log event) so the `[dry-run] docker compose -p ...` line
# the wrapper-dispatch specs assert stays byte-stable.

@test "_dry_run_cmd: DRY_RUN=true prints [dry-run] argv and does not execute" {
  local _marker="${BATS_TEST_TMPDIR}/dry_run_marker"
  run bash -c "
    source ${LOG_SH}
    DRY_RUN=true _dry_run_cmd touch '${_marker}'
  "
  assert_success
  assert_output "[dry-run] touch ${_marker}"
  [[ ! -e "${_marker}" ]] || { echo "command executed under DRY_RUN"; return 1; }
}

@test "_dry_run_cmd: DRY_RUN=false executes the command" {
  local _marker="${BATS_TEST_TMPDIR}/dry_run_exec"
  run bash -c "
    source ${LOG_SH}
    DRY_RUN=false _dry_run_cmd touch '${_marker}'
  "
  assert_success
  [[ -e "${_marker}" ]] || { echo "command not executed when DRY_RUN=false"; return 1; }
}

@test "_dry_run_cmd: DRY_RUN unset defaults to executing" {
  local _marker="${BATS_TEST_TMPDIR}/dry_run_default"
  run bash -c "
    source ${LOG_SH}
    unset DRY_RUN
    _dry_run_cmd touch '${_marker}'
  "
  assert_success
  [[ -e "${_marker}" ]] || { echo "command not executed when DRY_RUN unset"; return 1; }
}

@test "_dry_run_cmd: DRY_RUN=true %q-quotes args containing spaces" {
  run bash -c "
    source ${LOG_SH}
    DRY_RUN=true _dry_run_cmd echo 'a b' c
  "
  assert_success
  assert_output "[dry-run] echo a\\ b c"
}
