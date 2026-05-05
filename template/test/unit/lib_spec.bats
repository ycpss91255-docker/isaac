#!/usr/bin/env bats
#
# lib_spec.bats - Execution tests for script/docker/_lib.sh helpers.
#
# These tests source _lib.sh in a fresh subshell and call each helper so
# the bash branches actually run (kcov can then attribute coverage).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="/source/script/docker/_lib.sh"
}

# ── _detect_lang / _LANG ────────────────────────────────────────────────────

@test "_lib.sh sets _LANG to 'en' when LANG is unset" {
  run bash -c "unset LANG SETUP_LANG; source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "en"
}

@test "_lib.sh sets _LANG to 'zh-TW' for zh_TW.UTF-8" {
  run bash -c "unset SETUP_LANG; LANG=zh_TW.UTF-8 source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-TW"
}

@test "_lib.sh sets _LANG to 'zh-CN' for zh_CN.UTF-8" {
  run bash -c "unset SETUP_LANG; LANG=zh_CN.UTF-8 source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-CN"
}

@test "_lib.sh sets _LANG to 'zh-CN' for zh_SG (Singapore)" {
  run bash -c "unset SETUP_LANG; LANG=zh_SG.UTF-8 source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "zh-CN"
}

@test "_lib.sh sets _LANG to 'ja' for ja_JP.UTF-8" {
  run bash -c "unset SETUP_LANG; LANG=ja_JP.UTF-8 source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "ja"
}

@test "_lib.sh honors SETUP_LANG override" {
  run bash -c "SETUP_LANG=ja LANG=en_US.UTF-8 source ${LIB}; echo \"\${_LANG}\""
  assert_success
  assert_output "ja"
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

# ── _compute_project_name ───────────────────────────────────────────────────

@test "_compute_project_name with empty instance produces clean PROJECT_NAME" {
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name ''
    echo \"\${PROJECT_NAME}|\${INSTANCE_SUFFIX}\"
  "
  assert_success
  assert_output "alice-myrepo|"
}

@test "_compute_project_name with named instance suffixes both" {
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name 'dev2'
    echo \"\${PROJECT_NAME}|\${INSTANCE_SUFFIX}\"
  "
  assert_success
  assert_output "alice-myrepo-dev2|-dev2"
}

@test "_compute_project_name exports INSTANCE_SUFFIX so child processes see it" {
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name 'foo'
    bash -c 'echo \"\${INSTANCE_SUFFIX}\"'
  "
  assert_success
  assert_output "-foo"
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
  run bash -c "
    source ${LIB}
    DOCKER_HUB_USER=alice IMAGE_NAME=myrepo
    _compute_project_name ''
    FILE_PATH=/tmp/fakerepo
    DRY_RUN=true _compose_project ps
  "
  assert_success
  assert_output --partial "-p alice-myrepo"
  assert_output --partial "-f /tmp/fakerepo/compose.yaml"
  assert_output --partial "--env-file /tmp/fakerepo/.env"
  assert_output --partial " ps"
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
  _write_sample_conf "${_fp}/setup.conf"
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
  assert_output --partial "setup.conf   : ${_fp}/setup.conf"
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

@test "_print_config_summary prints Variables block mapping setup.conf placeholders to detected values" {
  # The Identity block already shows resolved user/workspace, but the
  # setup.conf [volumes] dump prints raw `${WS_PATH}` / `${USER_NAME}`
  # placeholders. Variables block bridges the gap so users can map the
  # placeholder to the value at a glance without re-deriving from
  # Identity field labels.
  local _fp="${BATS_TEST_TMPDIR}"
  _write_sample_conf "${_fp}/setup.conf"
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
  _write_sample_conf "${_fp}/setup.conf"
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
  cat > "${_fp}/setup.conf" <<'EOF'
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

@test "_print_config_summary warns when setup.conf exists but has no [section] headers" {
  # Empty / comments-only setup.conf is the same situation as missing
  # from a behavior standpoint (every section falls back to template
  # defaults), but the existing missing-conf branch never fires because
  # the file does exist. Surface a parallel hint inside the file-exists
  # branch so downstream `build.sh` users see the warning.
  local _fp="${BATS_TEST_TMPDIR}/empty_conf"
  mkdir -p "${_fp}"
  cat > "${_fp}/setup.conf" <<'EOF'
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
  _write_sample_conf "${_fp}/setup.conf"
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
  _write_sample_conf "${_fp}/setup.conf"
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
