#!/usr/bin/env bats
#
# lib_spec.bats - Execution tests for dist/script/docker/lib/_lib.sh helpers.
#
# These tests source _lib.sh in a fresh subshell and call each helper so
# the bash branches actually run (kcov can then attribute coverage).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="/source/dist/script/docker/lib/_lib.sh"
}

# ── _detect_lang / _LANG ────────────────────────────────────────────────────

# Part B: i18n.sh no longer sets _LANG as a module-load side-effect;
# callers resolve it explicitly via _resolve_lang. These assert the new
# contract -- the function maps LANG / SETUP_LANG to the canonical code.

@test "_resolve_lang sets 'en' when LANG is unset (#568)" {
  run bash -c "unset LANG SETUP_LANG; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "en"
}

@test "_resolve_lang sets 'zh-TW' for zh_TW.UTF-8 (#568)" {
  run bash -c "unset SETUP_LANG; LANG=zh_TW.UTF-8; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-TW"
}

@test "_resolve_lang sets 'zh-CN' for zh_CN.UTF-8 (#568)" {
  run bash -c "unset SETUP_LANG; LANG=zh_CN.UTF-8; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-CN"
}

@test "_resolve_lang sets 'zh-CN' for zh_SG (Singapore) (#568)" {
  run bash -c "unset SETUP_LANG; LANG=zh_SG.UTF-8; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-CN"
}

@test "_resolve_lang sets 'ja' for ja_JP.UTF-8 (#568)" {
  run bash -c "unset SETUP_LANG; LANG=ja_JP.UTF-8; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "ja"
}

@test "_resolve_lang honors SETUP_LANG override (#568)" {
  run bash -c "SETUP_LANG=ja LANG=en_US.UTF-8; source ${LIB}; _resolve_lang _LANG; echo \"\${_LANG}\""
  assert_success
  assert_output "ja"
}

@test "_lib.sh does NOT set _LANG at source time (#568 Part B)" {
  # The load-time side-effect is removed -- sourcing the lib chain leaves
  # _LANG unset until a caller invokes _resolve_lang explicitly.
  run bash -c "unset SETUP_LANG; LANG=zh_TW.UTF-8; source ${LIB}; echo \"\${_LANG:-UNSET}\""
  assert_success
  assert_output "UNSET"
}

# ── lib self-sourcing (load order not load-bearing, Part A) ─────────────

@test "conf_logging.sh self-sources its conf.sh dependency in isolation (#568)" {
  # Sourcing conf_logging.sh alone (no _lib.sh / conf.sh first) must still
  # make its _parse_ini_section dependency available -- the module
  # idempotently self-sources its deps so _lib.sh load order is not
  # load-bearing.
  run bash -c "source /source/dist/script/docker/lib/conf_logging.sh; declare -F _parse_ini_section"
  assert_success
}

# ── double-source guard ─────────────────────────────────────────────────────

@test "_lib.sh is idempotent when sourced twice" {
  run bash -c "source ${LIB}; source ${LIB}; echo \"\${_DOCKER_LIB_SOURCED}\""
  assert_success
  assert_output "1"
}

# ── _load_env ───────────────────────────────────────────────────────────────

@test "_load_env exports variables from a .env file" {
  local _tmp
  _tmp="$(mktemp)"
  cat > "${_tmp}" <<EOF
FOO=bar
BAZ=qux
EOF
  run bash -c "source ${LIB}; _load_env '${_tmp}'; echo \"\${FOO}-\${BAZ}\""
  assert_success
  assert_output "bar-qux"
  rm -f "${_tmp}"
}

@test "_load_env errors when no path is given" {
  run -127 bash -c "source ${LIB}; _load_env"
}

@test "_load_env round-trips shell-hostile values verbatim (no exec, no split) (#689)" {
  # _load_env does `set -o allexport; source "${env_file}"`, executing the
  # .env as shell. write_env is responsible for producing safe quoting (it
  # emits hostile build-arg values via `printf '%s=%q'`). This pins the
  # loader half of that contract: a value carrying a command-substitution
  # string, a backtick string, spaces, and a single quote -- written with
  # the SAME %q quoting write_env uses -- must round-trip to the literal
  # bytes (no command substitution executed, no word-splitting).
  local _tmp
  _tmp="$(mktemp)"
  local _spaces='a b c'
  local _dollar='X=$(id)'
  local _backtick='Y=`whoami`'
  local _squote="it's"
  {
    printf '%s=%q\n' FOO "${_spaces}"
    printf '%s=%q\n' BAR "${_dollar}"
    printf '%s=%q\n' BAZ "${_backtick}"
    printf '%s=%q\n' QUX "${_squote}"
  } > "${_tmp}"
  run bash -c "source ${LIB}; _load_env '${_tmp}'; printf '%s\n' \"\${FOO}\" \"\${BAR}\" \"\${BAZ}\" \"\${QUX}\""
  assert_success
  assert_line --index 0 "a b c"
  assert_line --index 1 'X=$(id)'
  assert_line --index 2 'Y=`whoami`'
  assert_line --index 3 "it's"
  # The substitutions must NOT have executed: no uid= leakage anywhere.
  refute_output --partial "uid="
  rm -f "${_tmp}"
}

@test "_load_env aborts under set -euo pipefail when the file does not exist (#689)" {
  # kcov instrumentation perturbs the inner set -u shell (BASH_SOURCE comes
  # back unbound), masking the real "No such file" diagnostic; the abort
  # behaviour is covered by the plain bats-unit run. Skip only under coverage.
  [ "${COVERAGE:-0}" = 1 ] && skip "kcov perturbs the inner set -u shell (#613)"
  # The path is provided but the file is gone -- the race the wrapper's
  # no_env guard is meant to prevent, and which run.sh would hit at
  # `_load_env "${FILE_PATH}/.env.generated"`. _load_env sources $1 with
  # no `[[ -f ]]` guard, so under the wrappers' `set -euo pipefail` the
  # failed `source` aborts the script. Pin that failure mode: non-zero
  # exit, a "No such file" diagnostic, and that the line past _load_env
  # never runs.
  run bash -c "set -euo pipefail; source ${LIB}; _load_env /no/such/.env.generated; echo REACHED"
  assert_failure
  refute_output --partial "REACHED"
  assert_output --partial "No such file"
}

# ── _compute_project_name ───────────────────────────────────────────────────

@test "_compute_project_name produces clean PROJECT_NAME (single-instance #600)" {
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name
    echo \"\${PROJECT_NAME}\"
  "
  assert_success
  assert_output "alice-myrepo"
}

@test "_compute_project_name honours the PROJECT_NAME resolved into .env.generated (#893)" {
  # The wrapper's -p and compose.yaml's `name:` must be ONE value. That
  # value is resolved once at setup time and recorded in .env.generated;
  # _load_env puts it in scope, and the wrapper must not recompute over it.
  # Today the assignment is unconditional, so a resolved project name is
  # silently discarded and two worktrees collide with no way to differ.
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo PROJECT_NAME=alice-myrepo-wt2
    _compute_project_name
    echo \"\${PROJECT_NAME}\"
  "
  assert_success
  assert_output "alice-myrepo-wt2"
}

@test "_compose_project passes the resolved PROJECT_NAME to -p (#893)" {
  local _repo
  _repo="$(mktemp -d)"
  printf 'PROJECT_NAME=alice-myrepo-wt2\n' > "${_repo}/.env.generated"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_repo}'
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _load_env '${_repo}/.env.generated'
    _compute_project_name
    DRY_RUN=true _compose_project ps
  "
  assert_success
  assert_output --partial "-p alice-myrepo-wt2"
  rm -rf "${_repo}"
}

# ── _resolve_project_name (the single producer of a project name) ───────────

@test "_resolve_project_name: a configured name is used verbatim (#893)" {
  run bash -c "
    source ${LIB}
    _resolve_project_name 'myrepo-wt2' alice myrepo /tmp/whatever _out
    echo \"\${_out}\"
  "
  assert_success
  assert_output "myrepo-wt2"
}

@test "_resolve_project_name: empty configured name derives the historical default (#893)" {
  run bash -c "
    source ${LIB}
    _resolve_project_name '' alice myrepo /tmp/whatever _out
    echo \"\${_out}\"
  "
  assert_success
  assert_output "alice-myrepo"
}

@test "_resolve_project_name: falls back to local + directory basename with nothing to go on (#893)" {
  run bash -c "
    source ${LIB}
    _resolve_project_name '' '' '' /tmp/some-checkout _out
    echo \"\${_out}\"
  "
  assert_success
  assert_output "local-some-checkout"
}

@test "_compute_project_name warns when .env.generated carries no PROJECT_NAME (#893)" {
  # A cache generated before the project-name key existed. Falling back
  # silently would leave the user with a name they cannot find the source
  # of; the resolved cache is stale and must say so.
  local _repo
  _repo="$(mktemp -d)"
  printf 'IMAGE_NAME=myrepo\n' > "${_repo}/.env.generated"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_repo}'
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name
    echo \"\${PROJECT_NAME}\"
  "
  assert_success
  assert_output --partial "alice-myrepo"
  assert_output --partial "PROJECT_NAME"
  rm -rf "${_repo}"
}

# ── _compose / _compose_project (DRY_RUN path) ──────────────────────────────

@test "_compose with DRY_RUN=true prints command instead of running" {
  run bash -c "source ${LIB}; DRY_RUN=true _compose ps --all"
  assert_success
  assert_output --partial "[dry-run] docker compose"
  assert_output --partial "ps"
  assert_output --partial "--all"
}

@test "_compose without DRY_RUN tries to invoke docker compose (sanity)" {
  # When DRY_RUN is unset/false, _compose calls real docker compose; on a
  # CI runner without docker the command exits non-zero, but we just want
  # to confirm the false branch executes (kcov coverage).
  run -127 bash -c "source ${LIB}; PATH=/nonexistent _compose version"
  # PATH=/nonexistent forces `docker compose` lookup to fail with rc 127,
  # confirming the non-dry-run branch was taken (reached the real invocation).
  refute_output --partial "[dry-run]"
}

@test "_compose_project pre-fills -p / -f / --env-file from PROJECT_NAME and FILE_PATH" {
  local _repo
  _repo="$(mktemp -d)"
  : > "${_repo}/.env.generated"   # present -> --env-file is included
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name ''
    FILE_PATH='${_repo}'
    DRY_RUN=true _compose_project ps
  "
  assert_success
  assert_output --partial "-p alice-myrepo"
  assert_output --partial "-f ${_repo}/compose.yaml"
  assert_output --partial "--env-file ${_repo}/.env.generated"
  assert_output --partial " ps"
  rm -rf "${_repo}"
}

@test "_compose_project omits --env-file when .env.generated is absent (self-managed repo)" {
  # base self-use (ADR-00000011 sec.4): a hand-authored compose.yaml with no
  # generated .env.generated -- _compose_project must still pass -p / -f but
  # drop --env-file so docker compose does not error on a missing file.
  local _repo
  _repo="$(mktemp -d)"   # no .env.generated created
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name ''
    FILE_PATH='${_repo}'
    DRY_RUN=true _compose_project ps
  "
  assert_success
  assert_output --partial "-p alice-myrepo"
  assert_output --partial "-f ${_repo}/compose.yaml"
  refute_output --partial "--env-file"
  assert_output --partial " ps"
  rm -rf "${_repo}"
}

# ════════════════════════════════════════════════════════════════════
# _sanitize_lang (i18n.sh)
# ════════════════════════════════════════════════════════════════════

@test "_sanitize_lang accepts en / zh-TW / zh-CN / ja unchanged" {
  run bash -c "source ${LIB}; v=en;    _sanitize_lang v; echo \"\${v}\""
  assert_success
  assert_output "en"
  run bash -c "source ${LIB}; v=zh-TW; _sanitize_lang v; echo \"\${v}\""
  assert_success
  assert_output "zh-TW"
  run bash -c "source ${LIB}; v=zh-CN; _sanitize_lang v; echo \"\${v}\""
  assert_success
  assert_output "zh-CN"
  run bash -c "source ${LIB}; v=ja;    _sanitize_lang v; echo \"\${v}\""
  assert_success
  assert_output "ja"
}

@test "_sanitize_lang warns and falls back to 'en' for unsupported values (English default)" {
  # Locale-agnostic / English system: English WARNING is emitted.
  run bash -c "unset LANG; source ${LIB}; v=foo; _sanitize_lang v test 2>&1; echo \"--VALUE=\${v}\""
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "foo"
  assert_output --partial "--VALUE=en"
}

@test "_sanitize_lang warns for the old bare 'zh' code (post zh→zh-TW rename)" {
  run bash -c "unset LANG; source ${LIB}; v=zh; _sanitize_lang v tui 2>&1; echo \"--VALUE=\${v}\""
  assert_success
  assert_output --partial "WARNING"
  assert_output --partial "--VALUE=en"
}

@test "_sanitize_lang warning is localized to system LANG (zh-TW)" {
  # Regression: v0.9.7 Agent A scoped this helper out of i18n coverage.
  # v0.9.11 localizes the warning using the SYSTEM LANG (not _LANG,
  # which holds the invalid input), so a user whose shell is zh-TW sees
  # the warning in Traditional Chinese rather than English.
  run env LANG=zh_TW.UTF-8 bash -c "source ${LIB}; v=foo; _sanitize_lang v test 2>&1"
  assert_success
  assert_output --partial "警告"
  assert_output --partial "foo"
  refute_output --partial "WARNING"
}

@test "_sanitize_lang warning is localized to system LANG (zh-CN)" {
  run env LANG=zh_CN.UTF-8 bash -c "source ${LIB}; v=foo; _sanitize_lang v test 2>&1"
  assert_success
  assert_output --partial "警告"
  refute_output --partial "WARNING"
}

@test "_sanitize_lang warning is localized to system LANG (ja)" {
  run env LANG=ja_JP.UTF-8 bash -c "source ${LIB}; v=foo; _sanitize_lang v test 2>&1"
  assert_success
  assert_output --partial "警告: サポート外"
  refute_output --partial "WARNING"
}

# ── _dump_conf_section / _print_config_summary ─────────────────────────────

_write_sample_conf() {
  # Minimal setup.conf with comments, blanks, and two sections — used by
  # the dump tests to verify comment/blank skipping and section boundaries.
  mkdir -p "$(dirname "${1}")"
  cat > "${1}" <<'EOF'
[image]
# rule comment — should be skipped
rule_1 = @basename

rule_2 = @default:unknown

[build]
arg_1 = TZ=Asia/Taipei
arg_2 = APT_MIRROR_UBUNTU=tw.archive.ubuntu.com

[volumes]
# populated at first init
mount_1 = /home/alice/work:/home/alice/work
EOF
}

@test "_dump_conf_section extracts keys from the named section" {
  local _f="${BATS_TEST_TMPDIR}/setup.conf"
  _write_sample_conf "${_f}"
  run bash -c "source ${LIB}; _dump_conf_section '${_f}' image"
  assert_success
  assert_output --partial "rule_1 = @basename"
  assert_output --partial "rule_2 = @default:unknown"
  refute_output --partial "arg_1"
  refute_output --partial "mount_1"
  refute_output --partial "rule comment"
}

@test "_dump_conf_section stops at the next section header" {
  local _f="${BATS_TEST_TMPDIR}/setup.conf"
  _write_sample_conf "${_f}"
  run bash -c "source ${LIB}; _dump_conf_section '${_f}' build"
  assert_success
  assert_output --partial "arg_1 = TZ=Asia/Taipei"
  assert_output --partial "arg_2 = APT_MIRROR_UBUNTU=tw.archive.ubuntu.com"
  refute_output --partial "rule_"
  refute_output --partial "mount_"
}

@test "_dump_conf_section returns silent empty for missing file" {
  run bash -c "source ${LIB}; _dump_conf_section /no/such/file.conf image"
  assert_success
  assert_output ""
}

@test "_dump_conf_section returns silent empty for unknown section" {
  local _f="${BATS_TEST_TMPDIR}/setup.conf"
  _write_sample_conf "${_f}"
  run bash -c "source ${LIB}; _dump_conf_section '${_f}' no_such_section"
  assert_success
  assert_output ""
}

@test "_dump_conf_section hides keys with empty values (using default)" {
  # Empty `key =` means "use the Docker / template default"; surfacing
  # it in the summary is noise. Populated keys in the same section
  # still print.
  local _f="${BATS_TEST_TMPDIR}/setup.conf"
  cat > "${_f}" <<'EOF'
[build]
target_arch =
network =
arg_1 = TZ=Asia/Taipei
[resources]
shm_size =
EOF
  run bash -c "source ${LIB}; _dump_conf_section '${_f}' build"
  assert_success
  assert_output --partial "arg_1 = TZ=Asia/Taipei"
  refute_output --partial "target_arch ="
  refute_output --partial "network ="

  # Section with only empty keys → empty output → caller skips the
  # whole section header via the [[ -z ${_content} ]] check.
  run bash -c "source ${LIB}; _dump_conf_section '${_f}' resources"
  assert_success
  assert_output ""
}

@test "_print_config_summary prints files, identity, all populated sections, resolved" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    HARDWARE=x86_64 DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    WS_PATH=/home/alice/work
    GPU_ENABLED=true GPU_COUNT=all GPU_CAPABILITIES='gpu compute'
    SETUP_GUI_DETECTED=true NETWORK_MODE=host IPC_MODE=host PRIVILEGED=false
    TZ=Asia/Taipei APT_MIRROR_UBUNTU=tw.archive.ubuntu.com
    APT_MIRROR_DEBIAN=mirror.twds.com.tw
    PROJECT_NAME=alice-myrepo
    _print_config_summary build
  "
  assert_success
  # File paths
  assert_output --partial "setup.conf   : ${_fp}/.setup.conf"
  assert_output --partial ".env         : ${_fp}/.env"
  assert_output --partial "compose.yaml : ${_fp}/compose.yaml"
  # Identity
  assert_output --partial "alice (uid=1000)"
  assert_output --partial "hardware     : x86_64"
  assert_output --partial "image / tag  : alice/myrepo"
  assert_output --partial "project      : alice-myrepo"
  assert_output --partial "workspace    : /home/alice/work"
  # setup.conf dump — each populated section
  assert_output --partial "[image]"
  assert_output --partial "rule_1 = @basename"
  assert_output --partial "[build]"
  assert_output --partial "arg_1 = TZ=Asia/Taipei"
  assert_output --partial "[volumes]"
  assert_output --partial "mount_1 = /home/alice/work:/home/alice/work"
  # Resolved
  assert_output --partial "GPU enabled : true"
  assert_output --partial "GUI enabled : true"
  assert_output --partial "network     : host"
  assert_output --partial "TZ=Asia/Taipei"
  # Customize hint
  assert_output --partial "./setup_tui.sh"
}

@test "_print_config_summary names an active .setup.conf.local and its sections (#893)" {
  # A config layer nobody else can see must never be invisible in the run
  # that uses it: the summary is the one place the user is told which files
  # this invocation resolved from.
  local _fp="${BATS_TEST_TMPDIR}/withlocal"
  mkdir -p "${_fp}"
  _write_sample_conf "${_fp}/.setup.conf"
  printf '[gui]\nmode = off\n[network]\nmode = bridge\n' > "${_fp}/.setup.conf.local"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo PROJECT_NAME=alice-myrepo
    _print_config_summary build
  "
  assert_success
  assert_output --partial "${_fp}/.setup.conf.local"
  assert_output --partial "gui, network"
}

@test "_print_config_summary says nothing about a .setup.conf.local that is absent (#893)" {
  local _fp="${BATS_TEST_TMPDIR}/nolocal"
  mkdir -p "${_fp}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo PROJECT_NAME=alice-myrepo
    _print_config_summary build
  "
  assert_success
  refute_output --partial ".setup.conf.local"
}

@test "_print_config_summary prints Variables block mapping setup.conf placeholders to detected values" {
  # The Identity block already shows resolved user/workspace, but the
  # setup.conf [volumes] dump prints raw `${WS_PATH}` / `${USER_NAME}`
  # placeholders. Variables block bridges the gap so users can map the
  # placeholder to the value at a glance without re-deriving from
  # Identity field labels.
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    HARDWARE=x86_64 DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    WS_PATH=/home/alice/work
    GPU_ENABLED=true GPU_COUNT=all GPU_CAPABILITIES='gpu compute'
    SETUP_GUI_DETECTED=true NETWORK_MODE=host IPC_MODE=host PRIVILEGED=false
    TZ=Asia/Taipei APT_MIRROR_UBUNTU=tw.archive.ubuntu.com
    APT_MIRROR_DEBIAN=mirror.twds.com.tw
    PROJECT_NAME=alice-myrepo
    _print_config_summary build
  "
  assert_success
  assert_output --partial "Variables"
  assert_output --partial "\${USER_NAME} = alice"
  assert_output --partial "\${USER_UID}  = 1000"
  assert_output --partial "\${USER_GROUP} = alice"
  assert_output --partial "\${USER_GID}  = 1000"
  assert_output --partial "\${WS_PATH}   = /home/alice/work"
}

@test "_print_config_summary Variables block falls back to '-' for unset values" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    FILE_PATH='${_fp}'
    unset USER_NAME USER_UID USER_GROUP USER_GID WS_PATH
    _print_config_summary build
  "
  assert_success
  assert_output --partial "\${USER_NAME} = -"
  assert_output --partial "\${WS_PATH}   = -"
}

@test "_print_config_summary hides sections that are empty in setup.conf" {
  local _fp="${BATS_TEST_TMPDIR}"
  # Minimal conf with only [image]; expect no [build]/[volumes] headers
  mkdir -p "${_fp}" && cat > "${_fp}/.setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  run bash -c "source ${LIB}; FILE_PATH='${_fp}'; _print_config_summary build"
  assert_success
  assert_output --partial "[image]"
  refute_output --partial "  [build]"
  refute_output --partial "  [volumes]"
}

@test "_print_config_summary warns when setup.conf is missing" {
  local _fp="${BATS_TEST_TMPDIR}/no_conf"
  mkdir -p "${_fp}"
  run bash -c "source ${LIB}; FILE_PATH='${_fp}'; _print_config_summary build"
  assert_success
  assert_output --partial "setup.conf not found"
  assert_output --partial "./setup_tui.sh"
}

@test "_print_config_summary wraps dividers + section headers in ANSI when FORCE_COLOR=1 (#309)" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    FORCE_COLOR=1 source ${LIB}
    FORCE_COLOR=1
    FILE_PATH='${_fp}'
    _print_config_summary build
  "
  assert_success
  # Dividers wrapped in dim ANSI (\033[2m...\033[0m)
  assert_output --partial $'\033[2m──'
  # Section headers wrapped in bold ANSI (\033[1m...\033[0m)
  assert_output --partial $'\033[1mFiles\033[0m'
  assert_output --partial $'\033[1mIdentity\033[0m'
  assert_output --partial $'\033[1mVariables\033[0m'
  assert_output --partial $'\033[1msetup.conf\033[0m'
  assert_output --partial $'\033[1mResolved\033[0m'
  # Indented value lines stay un-styled
  refute_output --partial $'\033[1m  setup.conf'
  refute_output --partial $'\033[2m  setup.conf'
}

@test "_print_config_summary omits ANSI when NO_COLOR=1 overrides FORCE_COLOR=1 (#309)" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    NO_COLOR=1 FORCE_COLOR=1 source ${LIB}
    NO_COLOR=1 FORCE_COLOR=1
    FILE_PATH='${_fp}'
    _print_config_summary build
  "
  assert_success
  # No ANSI escape sequences anywhere in output
  refute_output --partial $'\033['
  # Headers still present as plain text
  assert_output --partial "Files"
  assert_output --partial "Resolved"
}

@test "_print_config_summary warns when setup.conf exists but has no [section] headers" {
  # Empty / comments-only setup.conf is the same situation as missing
  # from a behavior standpoint (every section falls back to template
  # defaults), but the existing missing-conf branch never fires because
  # the file does exist. Surface a parallel hint inside the file-exists
  # branch so downstream `build.sh` users see the warning.
  local _fp="${BATS_TEST_TMPDIR}/empty_conf"
  mkdir -p "${_fp}"
  mkdir -p "${_fp}" && cat > "${_fp}/.setup.conf" <<'EOF'
# only comments, no [section] headers
EOF
  run bash -c "source ${LIB}; FILE_PATH='${_fp}'; _print_config_summary build"
  assert_success
  assert_output --partial "no section overrides"
}

# ── _lib_msg / _print_config_summary i18n ──────────────────────────────────

@test "_lib_msg returns English by default" {
  run bash -c "source ${LIB}; unset _LANG; echo \"\$(_lib_msg files)|\$(_lib_msg identity)|\$(_lib_msg resolved)|\$(_lib_msg customize)\""
  assert_success
  assert_output "Files|Identity|Resolved|Customize"
}

@test "_lib_msg returns zh-TW translations" {
  run bash -c "source ${LIB}; _LANG=zh-TW; echo \"\$(_lib_msg files)|\$(_lib_msg identity)|\$(_lib_msg user)|\$(_lib_msg hardware)|\$(_lib_msg gpu_enabled)|\$(_lib_msg network)\""
  assert_success
  assert_output "檔案|身分|使用者|硬體|GPU 已啟用|網路"
}

@test "_lib_msg returns zh-CN translations" {
  run bash -c "source ${LIB}; _LANG=zh-CN; echo \"\$(_lib_msg files)|\$(_lib_msg user)|\$(_lib_msg hardware)|\$(_lib_msg workspace)\""
  assert_success
  assert_output "文件|用户|硬件|工作区"
}

@test "_lib_msg returns ja translations" {
  run bash -c "source ${LIB}; _LANG=ja; echo \"\$(_lib_msg files)|\$(_lib_msg identity)|\$(_lib_msg user)|\$(_lib_msg hardware)\""
  assert_success
  assert_output "ファイル|ID|ユーザー|ハードウェア"
}

@test "_lib_msg returns count / caps across all languages" {
  # Regression: these two keys are only invoked inline in the
  # "Resolved" block of _print_config_summary and were missed by
  # spot-check assertions; kcov flagged both branches as uncovered.
  run bash -c "source ${LIB}; _LANG=en; echo \"\$(_lib_msg count)|\$(_lib_msg caps)\""
  assert_success
  assert_output "count|caps"

  run bash -c "source ${LIB}; _LANG=zh-TW; echo \"\$(_lib_msg count)|\$(_lib_msg caps)\""
  assert_success
  assert_output "數量|能力"

  run bash -c "source ${LIB}; _LANG=zh-CN; echo \"\$(_lib_msg count)|\$(_lib_msg caps)\""
  assert_success
  assert_output "数量|能力"

  run bash -c "source ${LIB}; _LANG=ja; echo \"\$(_lib_msg count)|\$(_lib_msg caps)\""
  assert_success
  assert_output "数量|ケーパビリティ"
}

@test "_lib_msg falls back to English for unknown _LANG value" {
  # unknown locale should not silently output empty — falls through to *:.
  run bash -c "source ${LIB}; _LANG=de; echo \"\$(_lib_msg files)|\$(_lib_msg identity)\""
  assert_success
  assert_output "Files|Identity"
}

@test "_print_config_summary uses zh-TW labels when _LANG=zh-TW" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    _LANG=zh-TW
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    HARDWARE=aarch64 DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    WS_PATH=/home/alice/work
    GPU_ENABLED=true GPU_COUNT=all GPU_CAPABILITIES='gpu compute'
    SETUP_GUI_DETECTED=false NETWORK_MODE=host IPC_MODE=host PRIVILEGED=true
    TZ=Asia/Taipei APT_MIRROR_UBUNTU=tw.archive.ubuntu.com
    APT_MIRROR_DEBIAN=mirror.twds.com.tw
    PROJECT_NAME=alice-myrepo
    _print_config_summary run
  "
  assert_success
  # Translated section headings
  assert_output --partial "[run] 檔案"
  assert_output --partial "[run] 身分"
  assert_output --partial "[run] 解析結果"
  # Translated field labels
  assert_output --partial "使用者"
  assert_output --partial "硬體"
  assert_output --partial "工作區"
  assert_output --partial "GPU 已啟用"
  assert_output --partial "GUI 已啟用"
  assert_output --partial "網路"
  assert_output --partial "特權"
  # Customize hint translated
  assert_output --partial "自訂:"
  # English key labels preserved (technical terms / .env var names)
  assert_output --partial "TZ=Asia/Taipei"
  assert_output --partial "ipc=host"
}

@test "_print_config_summary uses ja labels when _LANG=ja" {
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/.setup.conf"
  run bash -c "
    source ${LIB}
    _LANG=ja
    FILE_PATH='${_fp}'
    USER_NAME=alice USER_UID=1000 USER_GROUP=alice USER_GID=1000
    HARDWARE=x86_64 DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    WS_PATH=/home/alice/work
    GPU_ENABLED=true GPU_COUNT=all GPU_CAPABILITIES='gpu'
    SETUP_GUI_DETECTED=true NETWORK_MODE=host IPC_MODE=host PRIVILEGED=false
    PROJECT_NAME=alice-myrepo
    _print_config_summary build
  "
  assert_success
  assert_output --partial "[build] ファイル"
  assert_output --partial "[build] ID"
  assert_output --partial "[build] 解決済み"
  assert_output --partial "ユーザー"
  assert_output --partial "ハードウェア"
  assert_output --partial "ワークスペース"
}

@test "_print_config_summary conf_missing hint is translated (zh-TW)" {
  local _fp="${BATS_TEST_TMPDIR}/no_conf_zh"
  mkdir -p "${_fp}"
  run bash -c "source ${LIB}; _LANG=zh-TW; FILE_PATH='${_fp}'; _print_config_summary build"
  assert_success
  assert_output --partial "找不到 setup.conf"
  assert_output --partial "./build.sh --setup"
}
