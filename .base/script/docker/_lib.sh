#!/usr/bin/env bash
#
# _lib.sh - Shared helpers for build.sh / run.sh / exec.sh / stop.sh.
#
# Sourced (not executed). Provides:
#   _LANG                            : detected message language
#   _load_env <env_file>             : source .env into the environment
#   _compute_project_name <instance> : set INSTANCE_SUFFIX and PROJECT_NAME
#   _compose                         : `docker compose` wrapper honoring DRY_RUN
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SOURCED=1

# i18n.sh lives next to _lib.sh in every deployment surface (consumer
# repo's template/script/docker/, and the /lint/ stage where the
# Dockerfile COPYs both). Issue #104 removed the duplicate fallback
# `_detect_lang` definitions that had already drifted (#103) — the
# one canonical _detect_lang + _LANG assignment lives in i18n.sh.
_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
source "${_lib_dir}/i18n.sh"
unset _lib_dir

# _load_env sources the given .env file with allexport so every assignment
# becomes an exported variable visible to docker compose.
#
# Args:
#   $1: absolute path to .env file
_load_env() {
  local env_file="${1:?_load_env requires an env file path}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${env_file}"
  set +o allexport
}

# _compute_project_name derives INSTANCE_SUFFIX and PROJECT_NAME for the
# current invocation, and exports INSTANCE_SUFFIX so compose.yaml can resolve
# ${INSTANCE_SUFFIX:-} when computing container_name.
#
# Args:
#   $1: instance name (may be empty for the default instance)
#
# Requires:
#   DOCKER_HUB_USER, IMAGE_NAME already in the environment (from .env).
#
# Sets (and exports INSTANCE_SUFFIX):
#   INSTANCE_SUFFIX  e.g. "-foo" or ""
#   PROJECT_NAME     e.g. "alice-myrepo-foo"
_compute_project_name() {
  local instance="${1:-}"
  if [[ -n "${instance}" ]]; then
    INSTANCE_SUFFIX="-${instance}"
  else
    INSTANCE_SUFFIX=""
  fi
  export INSTANCE_SUFFIX
  # shellcheck disable=SC2034  # PROJECT_NAME is consumed by callers, not _lib.sh
  PROJECT_NAME="${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX}"
}

# _dump_conf_section <file> <section>
#
# Emit key=value lines from the named INI section of <file>, skipping
# blank lines and comments. Stops at the next section header or EOF.
# Silent on missing file or missing section.
_dump_conf_section() {
  local _file="$1" _sec="$2"
  [[ -f "${_file}" ]] || return 0
  # Filter out empty values (`key =` / `key = `). An empty value means
  # "use the Docker / template default" and is noise in the summary.
  # Populated keys print as-is; cleared list slots (arg_N = / mount_N =)
  # are also hidden so they don't show up as blank rows.
  awk -v sec="[${_sec}]" '
    $0 == sec { in_sec=1; next }
    /^\[/ && in_sec { in_sec=0 }
    in_sec && /^[[:space:]]*#/ { next }
    in_sec && /^[[:space:]]*$/ { next }
    in_sec && /^[[:space:]]*[^#=]+=[[:space:]]*$/ { next }
    in_sec { print }
  ' "${_file}"
}

# _lib_msg <key>
#
# Translation table for labels printed by `_print_config_summary`.
# Uses the same `${_LANG}:${_key}` → output pattern as setup.sh /
# build.sh's `_msg`. Kept in a separate namespace (`_lib_msg`) so
# caller scripts can still define their own `_msg` for script-specific
# log lines without name collisions.
#
# Translated: section headings + descriptive labels. Left untranslated
# (technical terms / identifiers users recognise across locales): file
# names (setup.conf / .env / compose.yaml), INI section names in [ ],
# .env variable names (TZ, APT_MIRROR_*, IPC, CAPS), command strings
# in "Customize" hint.
_lib_msg() {
  local _key="${1:?}"
  case "${_LANG:-en}:${_key}" in
    # Section headings
    zh-TW:files)             echo "檔案" ;;
    zh-CN:files)             echo "文件" ;;
    ja:files)                echo "ファイル" ;;
    *:files)                 echo "Files" ;;
    zh-TW:identity)          echo "身分" ;;
    zh-CN:identity)          echo "身份" ;;
    ja:identity)             echo "ID" ;;
    *:identity)              echo "Identity" ;;
    zh-TW:resolved)          echo "解析結果" ;;
    zh-CN:resolved)          echo "解析结果" ;;
    ja:resolved)             echo "解決済み" ;;
    *:resolved)              echo "Resolved" ;;
    zh-TW:variables)         echo "變數對映" ;;
    zh-CN:variables)         echo "变量映射" ;;
    ja:variables)            echo "変数マッピング" ;;
    *:variables)             echo "Variables" ;;
    # Identity field labels
    zh-TW:user)              echo "使用者" ;;
    zh-CN:user)              echo "用户" ;;
    ja:user)                 echo "ユーザー" ;;
    *:user)                  echo "user" ;;
    zh-TW:group)             echo "群組" ;;
    zh-CN:group)             echo "组" ;;
    ja:group)                echo "グループ" ;;
    *:group)                 echo "group" ;;
    zh-TW:hardware)          echo "硬體" ;;
    zh-CN:hardware)          echo "硬件" ;;
    ja:hardware)             echo "ハードウェア" ;;
    *:hardware)              echo "hardware" ;;
    zh-TW:image_tag)         echo "映像 / 標籤" ;;
    zh-CN:image_tag)         echo "镜像 / 标签" ;;
    ja:image_tag)            echo "イメージ / タグ" ;;
    *:image_tag)             echo "image / tag" ;;
    zh-TW:project)           echo "專案" ;;
    zh-CN:project)           echo "项目" ;;
    ja:project)              echo "プロジェクト" ;;
    *:project)               echo "project" ;;
    zh-TW:workspace)         echo "工作區" ;;
    zh-CN:workspace)         echo "工作区" ;;
    ja:workspace)            echo "ワークスペース" ;;
    *:workspace)             echo "workspace" ;;
    # Resolved field labels
    zh-TW:gpu_enabled)       echo "GPU 已啟用" ;;
    zh-CN:gpu_enabled)       echo "GPU 已启用" ;;
    ja:gpu_enabled)          echo "GPU 有効" ;;
    *:gpu_enabled)           echo "GPU enabled" ;;
    zh-TW:count)             echo "數量" ;;
    zh-CN:count)             echo "数量" ;;
    ja:count)                echo "数量" ;;
    *:count)                 echo "count" ;;
    zh-TW:caps)              echo "能力" ;;
    zh-CN:caps)              echo "能力" ;;
    ja:caps)                 echo "ケーパビリティ" ;;
    *:caps)                  echo "caps" ;;
    zh-TW:gui_enabled)       echo "GUI 已啟用" ;;
    zh-CN:gui_enabled)       echo "GUI 已启用" ;;
    ja:gui_enabled)          echo "GUI 有効" ;;
    *:gui_enabled)           echo "GUI enabled" ;;
    zh-TW:network)           echo "網路" ;;
    zh-CN:network)           echo "网络" ;;
    ja:network)              echo "ネットワーク" ;;
    *:network)               echo "network" ;;
    zh-TW:privileged)        echo "特權" ;;
    zh-CN:privileged)        echo "特权" ;;
    ja:privileged)           echo "特権" ;;
    *:privileged)            echo "privileged" ;;
    # Hints / errors
    zh-TW:conf_missing)      echo "(找不到 setup.conf — 執行 ./setup_tui.sh 或 ./%s.sh --setup)" ;;
    zh-CN:conf_missing)      echo "(找不到 setup.conf — 运行 ./setup_tui.sh 或 ./%s.sh --setup)" ;;
    ja:conf_missing)         echo "(setup.conf が見つかりません — ./setup_tui.sh または ./%s.sh --setup を実行してください)" ;;
    *:conf_missing)          echo "(setup.conf not found — run ./setup_tui.sh or ./%s.sh --setup)" ;;
    zh-TW:conf_empty)        echo "(setup.conf 沒有 section 覆寫 — 全部使用模板預設值；./setup_tui.sh 或 edit setup.conf)" ;;
    zh-CN:conf_empty)        echo "(setup.conf 没有 section 覆写 — 全部使用模板默认值；./setup_tui.sh 或 edit setup.conf)" ;;
    ja:conf_empty)           echo "(setup.conf にセクション上書きがありません — 全てテンプレート既定値を使用；./setup_tui.sh または edit setup.conf)" ;;
    *:conf_empty)            echo "(setup.conf has no section overrides — using template defaults; run ./setup_tui.sh or edit setup.conf)" ;;
    zh-TW:customize)         echo "自訂" ;;
    zh-CN:customize)         echo "自定义" ;;
    ja:customize)            echo "カスタマイズ" ;;
    *:customize)             echo "Customize" ;;
  esac
}

# _print_config_summary <tag>
#
# Print the resolved runtime config right before the main action
# (docker build / up). Goal: first-time users can see every value
# this run will consume — file paths, .env-derived identity/hardware,
# and the complete [image]/[build]/[deploy]/[gui]/[network]/
# [security]/[resources]/[environment]/[tmpfs]/[devices]/[volumes]
# section contents from setup.conf — without having to diff `.env`
# or run `docker compose config`.
#
# Expects FILE_PATH + standard .env variables already in scope
# (caller must `_load_env` first). Missing values render as "-".
#
# Labels honor ${_LANG} via `_lib_msg`; technical terms stay
# untranslated (see _lib_msg header).
#
# Args:
#   $1: short tag prefix for log lines (e.g. "build", "run")
_print_config_summary() {
  local _tag="${1:?_print_config_summary requires a log tag}"
  local _fp="${FILE_PATH:-.}"
  local _conf="${_fp}/config/docker/setup.conf"
  local _line="────────────────────────────────────────────────────────────"
  local _img="${DOCKER_HUB_USER:-local}/${IMAGE_NAME:-unknown}"
  local _proj="${PROJECT_NAME:-${DOCKER_HUB_USER:-local}-${IMAGE_NAME:-unknown}}"

  printf "[%s] %s\n" "${_tag}" "${_line}"
  printf "[%s] %s\n" "${_tag}" "$(_lib_msg files)"
  printf "[%s]   setup.conf   : %s\n"   "${_tag}" "${_conf}"
  printf "[%s]   .env         : %s\n"   "${_tag}" "${_fp}/.env"
  printf "[%s]   compose.yaml : %s\n"   "${_tag}" "${_fp}/compose.yaml"
  printf "[%s] %s\n" "${_tag}" "$(_lib_msg identity)"
  printf "[%s]   %-12s : %s (uid=%s)  %s=%s (gid=%s)\n" "${_tag}" \
    "$(_lib_msg user)" "${USER_NAME:--}" "${USER_UID:--}" \
    "$(_lib_msg group)" "${USER_GROUP:--}" "${USER_GID:--}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg hardware)" "${HARDWARE:--}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg image_tag)" "${_img}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg project)" "${_proj}"
  printf "[%s]   %-12s : %s\n" "${_tag}" "$(_lib_msg workspace)" "${WS_PATH:--}"

  # Variables block: explicit map from setup.conf placeholders to the
  # detected runtime values. Identity prints the resolved values with
  # i18n labels (e.g. "使用者 : alice"); the [volumes] dump prints raw
  # `${USER_NAME}` / `${WS_PATH}` placeholders. This block bridges the
  # two so users can read mount_* lines without re-deriving the mapping
  # from translated labels.
  printf "[%s] %s\n" "${_tag}" "$(_lib_msg variables)"
  printf "[%s]   \${USER_NAME} = %s\n"  "${_tag}" "${USER_NAME:--}"
  printf "[%s]   \${USER_UID}  = %s\n"  "${_tag}" "${USER_UID:--}"
  printf "[%s]   \${USER_GROUP} = %s\n" "${_tag}" "${USER_GROUP:--}"
  printf "[%s]   \${USER_GID}  = %s\n"  "${_tag}" "${USER_GID:--}"
  printf "[%s]   \${WS_PATH}   = %s\n"  "${_tag}" "${WS_PATH:--}"

  # setup.conf section-by-section dump. Each section prints only if
  # non-empty to stay readable. Order matches the TUI main menu so
  # the printout and setup_tui.sh layout mirror each other.
  if [[ -f "${_conf}" ]]; then
    printf "[%s] setup.conf\n" "${_tag}"
    # When the file exists but contains no [section] headers (empty file
    # / comments-only / whitespace-only), every section silently falls
    # back to template defaults. Surface a parallel hint to the
    # missing-conf branch so users on build.sh's drift-check rebuild
    # path see the heads-up too (closes #157).
    if ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_conf}"; then
      # shellcheck disable=SC2059  # format string is intentional (i18n table owns no %s)
      printf "[%s]   $(_lib_msg conf_empty)\n" "${_tag}"
    else
      local _sec _content _l
      for _sec in image build deploy gui network security resources \
                  environment tmpfs devices volumes; do
        _content="$(_dump_conf_section "${_conf}" "${_sec}")"
        [[ -z "${_content}" ]] && continue
        printf "[%s]   [%s]\n" "${_tag}" "${_sec}"
        while IFS= read -r _l; do
          printf "[%s]     %s\n" "${_tag}" "${_l}"
        done <<< "${_content}"
      done
    fi
  else
    # shellcheck disable=SC2059  # format string is intentional (i18n table owns %s)
    printf "[%s]   $(_lib_msg conf_missing)\n" "${_tag}" "${_tag}"
  fi

  # Resolved post-merge flags that the user can't infer from setup.conf
  # alone (GPU/GUI depend on host detection in addition to mode=auto).
  printf "[%s] %s\n" "${_tag}" "$(_lib_msg resolved)"
  printf "[%s]   %s : %s  count=%s  caps=%s\n" "${_tag}" \
    "$(_lib_msg gpu_enabled)" "${GPU_ENABLED:--}" "${GPU_COUNT:--}" "${GPU_CAPABILITIES:--}"
  printf "[%s]   %s : %s\n" "${_tag}" \
    "$(_lib_msg gui_enabled)" "${SETUP_GUI_DETECTED:--}"
  printf "[%s]   %s     : %s  ipc=%s  %s=%s\n" "${_tag}" \
    "$(_lib_msg network)" "${NETWORK_MODE:--}" "${IPC_MODE:--}" \
    "$(_lib_msg privileged)" "${PRIVILEGED:--}"
  printf "[%s]   TZ=%s  apt_ubuntu=%s  apt_debian=%s\n" "${_tag}" \
    "${TZ:--}" "${APT_MIRROR_UBUNTU:--}" "${APT_MIRROR_DEBIAN:--}"

  printf "[%s] %s: ./setup_tui.sh  |  ./%s.sh --setup  |  edit setup.conf\n" \
    "${_tag}" "$(_lib_msg customize)" "${_tag}"
  printf "[%s] %s\n" "${_tag}" "${_line}"
}

# _compose runs `docker compose` with the given args, or prints what it would
# run if DRY_RUN=true. Use this instead of calling docker compose directly so
# every script honors --dry-run uniformly.
_compose() {
  if [[ "${DRY_RUN:-false}" == true ]]; then
    printf '[dry-run] docker compose'
    printf ' %q' "$@"
    printf '\n'
  else
    docker compose "$@"
  fi
}

# _compose_project runs `_compose` with -p / -f / --env-file pre-filled, so
# callers only need to pass the verb and its args.
#
# Requires:
#   PROJECT_NAME : set by _compute_project_name
#   FILE_PATH    : the repo root (where compose.yaml and .env live)
_compose_project() {
  _compose -p "${PROJECT_NAME}" \
    -f "${FILE_PATH}/compose.yaml" \
    --env-file "${FILE_PATH}/.env" \
    "$@"
}
