#!/usr/bin/env bats
#
# wrapper_lib_spec.bats - unit tests for the wrapper-runtime module
# dist/script/docker/lib/wrapper.sh.
#
# The runtime hoists the cross-cutting surfaces the 5 docker wrappers
# (build / run / exec / stop / prune) used to duplicate: the _msg
# dispatcher, the --lang pre-pass, and the build/run setup/drift
# orchestration. These tests exercise each helper in isolation -- sourced
# directly (not through a wrapper) so the bash branches run and kcov can
# attribute coverage -- AND assert the "called from each of the 5
# wrappers" parameterisation (verb-derived log tags, per-verb message
# tables).

bats_require_minimum_version 1.5.0

LIB="/source/dist/script/docker/lib"

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── _msg dispatcher ─────────────────────────────────────────────────────────

@test "_msg dispatches <category> <key> to _msg_<category> (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _msg_errors() { case \"\${_LANG}:\$1\" in *:no_env) echo 'no env here';; esac; }
    _msg errors no_env
  "
  assert_success
  assert_output "no env here"
}

@test "_msg reads the global _LANG for locale selection (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=ja
    _msg_errors() { case \"\${_LANG}:\$1\" in ja:no_env) echo 'JP';; *:no_env) echo 'EN';; esac; }
    _msg errors no_env
  "
  assert_success
  assert_output "JP"
}

@test "_msg errors when category is missing (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _msg"
  assert_failure
  assert_output --partial "requires category"
}

@test "_msg errors when key is missing (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _msg errors"
  assert_failure
  assert_output --partial "requires key"
}

# ── _wrapper_lang_prepass ───────────────────────────────────────────────────

@test "_wrapper_lang_prepass sets _LANG from --lang (#565, #222)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass build --help --lang zh-TW
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "zh-TW"
}

@test "_wrapper_lang_prepass finds --lang even when it is not first (#565, #222)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass run -d --lang ja -- somecmd
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "ja"
}

@test "_wrapper_lang_prepass leaves _LANG untouched when no --lang given (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    _wrapper_lang_prepass stop --prune --dry-run
    echo \"\${_LANG}\"
  "
  assert_success
  assert_output "en"
}

@test "_wrapper_lang_prepass falls back to 'en' on an unsupported --lang value (#565)" {
  # _sanitize_lang warns + rewrites to en; the verb appears in the warning.
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    LANG=en_US.UTF-8 _LANG=en
    _wrapper_lang_prepass prune --lang klingon
    echo \"LANG=\${_LANG}\"
  "
  assert_success
  assert_output --partial "LANG=en"
  assert_output --partial "[prune]"
}

@test "_wrapper_lang_prepass requires a verb argument (#565)" {
  run bash -c "source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh; _wrapper_lang_prepass"
  assert_failure
  assert_output --partial "requires verb"
}

# Parameterisation: each of the 5 wrappers passes its own verb through to
# _sanitize_lang, so the unsupported-value warning is tagged per wrapper.
@test "_wrapper_lang_prepass threads each wrapper's verb into the warning (#565)" {
  local _v
  for _v in build run exec stop prune; do
    run bash -c "
      source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
      LANG=en_US.UTF-8 _LANG=en
      _wrapper_lang_prepass ${_v} --lang nope
    "
    assert_success
    assert_output --partial "[${_v}]"
  done
}

# ── _wrapper_setup_sync ─────────────────────────────────────────────────────
#
# Build a minimal sandbox with a mock setup.sh so the orchestration runs
# end-to-end without docker. The mock records its invocation and writes
# .env.generated + compose.yaml on `apply`.

_make_setup_sandbox() {
  local _root="$1"
  mkdir -p "${_root}/.base/dist/script/docker/wrapper" \
           "${_root}/config/docker"
  export SETUP_LOG="${TEMP_DIR}/setup.log"
  : > "${SETUP_LOG}"
  cat > "${_root}/.base/dist/script/docker/wrapper/setup.sh" <<EOS
#!/usr/bin/env bash
set -euo pipefail
_subcmd="apply"
case "\${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --base-path) _base="\$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "\${_subcmd}" in
  check-drift) exit "\${MOCK_DRIFT_RC:-0}" ;;
  apply)
    printf 'apply base=%s\n' "\${_base}" >> "${SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "\${_base}/.env.generated"
    echo "# mock compose" > "\${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${_root}/.base/dist/script/docker/wrapper/setup.sh"
}

# Run _wrapper_setup_sync for a given verb in a fresh subshell against a
# sandbox at $1. Extra env (RUN_SETUP, MOCK_DRIFT_RC, ...) is inherited.
_run_setup_sync() {
  local _root="$1" _verb="$2"
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${_root}'
    RUN_SETUP=\${RUN_SETUP:-false}
    declare -a SETUP_FORWARD_ARGS=()
    # Per-verb message tables the orchestration calls.
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen drift'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
    _wrapper_setup_sync ${_verb}
    echo 'SYNC_OK'
  "
}

@test "_wrapper_setup_sync bootstraps via setup.sh when .env is missing (#565)" {
  local R="${TEMP_DIR}/repo"
  _make_setup_sandbox "${R}"
  _run_setup_sync "${R}" build
  assert_success
  assert_output --partial "First run"
  assert_output --partial "SYNC_OK"
  assert [ -f "${R}/.env.generated" ]
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync RUN_SETUP=true forces an interactive setup run (#565)" {
  local R="${TEMP_DIR}/repo2"
  _make_setup_sandbox "${R}"
  # Pre-seed all three artifacts so the only reason setup runs is RUN_SETUP.
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  RUN_SETUP=true _run_setup_sync "${R}" run
  assert_success
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync drift-check clean path does NOT re-apply (#565)" {
  local R="${TEMP_DIR}/repo3"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  MOCK_DRIFT_RC=0 _run_setup_sync "${R}" build
  assert_success
  # check-drift returned 0 → no apply recorded.
  run cat "${SETUP_LOG}"
  refute_output --partial "apply base="
}

@test "_wrapper_setup_sync regenerates on drift (check-drift non-zero) (#565)" {
  local R="${TEMP_DIR}/repo4"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  MOCK_DRIFT_RC=1 _run_setup_sync "${R}" run
  assert_success
  assert_output --partial "regen drift"
  run cat "${SETUP_LOG}"
  assert_output --partial "apply base=${R}"
}

@test "_wrapper_setup_sync exits 1 with no_env error when setup leaves no .env (#565)" {
  local R="${TEMP_DIR}/repo5"
  mkdir -p "${R}/.base/dist/script/docker/wrapper" "${R}"
  # setup.sh that does nothing (writes neither .env nor compose).
  cat > "${R}/.base/dist/script/docker/wrapper/setup.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${R}/.base/dist/script/docker/wrapper/setup.sh"
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${R}'
    RUN_SETUP=false
    declare -a SETUP_FORWARD_ARGS=()
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env produced';; rerun_setup) echo 'rerun me';; esac; }
    _wrapper_setup_sync build
    echo 'SHOULD_NOT_REACH'
  "
  assert_failure 1
  assert_output --partial "no env produced"
  assert_output --partial "rerun me"
  refute_output --partial "SHOULD_NOT_REACH"
}

# Parameterisation: build + run share the orchestration; the verb is
# threaded into _log_* as the service name (`[<verb>]` tag) and the event
# name (`<verb>_bootstrap`). The text log format surfaces the `[<verb>]`
# tag; assert both verbs emit their own tagged bootstrap line.
@test "_wrapper_setup_sync tags log events with the caller's verb (#565)" {
  local _v
  for _v in build run; do
    local R="${TEMP_DIR}/repo_${_v}"
    _make_setup_sandbox "${R}"
    run bash -c "
      source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
      _LANG=en
      FILE_PATH='${R}'
      RUN_SETUP=false
      declare -a SETUP_FORWARD_ARGS=()
      _msg_bootstrap() { echo 'First run'; }
      _msg_drift()     { echo 'regen'; }
      _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
      _wrapper_setup_sync ${_v}
    "
    assert_success
    # text log line carries the per-verb service tag "[<verb>]".
    assert_output --partial "[${_v}]"
  done
}

@test "_wrapper_setup_sync requires a verb argument (#565)" {
  run bash -c "
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    FILE_PATH='${TEMP_DIR}'
    _wrapper_setup_sync
  "
  assert_failure
  assert_output --partial "requires verb"
}

@test "_wrapper_setup_sync degrades to empty forward-args when SETUP_FORWARD_ARGS is unset (#565)" {
  # lib defensive-unset convention: a caller that never declared the
  # override array must not trip set -u. RUN_SETUP=true reaches the
  # _run_interactive branch that reads the array.
  local R="${TEMP_DIR}/repo_noargs"
  _make_setup_sandbox "${R}"
  echo "x" > "${R}/.setup.conf"
  echo "USER_NAME=a" > "${R}/.env.generated"
  echo "# c" > "${R}/compose.yaml"
  run bash -c "
    set -u
    source ${LIB}/_lib.sh; source ${LIB}/wrapper.sh
    _LANG=en
    FILE_PATH='${R}'
    RUN_SETUP=true
    # NOTE: SETUP_FORWARD_ARGS intentionally NOT declared.
    _msg_bootstrap() { echo 'First run'; }
    _msg_drift()     { echo 'regen'; }
    _msg_errors()    { case \"\$1\" in no_env) echo 'no env';; rerun_setup) echo 'rerun';; esac; }
    _wrapper_setup_sync build
    echo 'NOARGS_OK'
  "
  assert_success
  assert_output --partial "NOARGS_OK"
}
