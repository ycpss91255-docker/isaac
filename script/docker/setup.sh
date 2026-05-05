#!/usr/bin/env bash
# setup.sh - Auto-detect system parameters and generate .env + compose.yaml
#
# Reads <repo>/setup.conf (or template/setup.conf default) for the repo's
# runtime configuration ([image] rules, [build] apt_mirror, [deploy] GPU,
# [gui], [network], [volumes]), runs system detection (UID/GID, hardware,
# docker hub user, GPU, GUI, workspace path), then emits:
#   - <repo>/.env          (variable values + SETUP_* metadata for drift detection)
#   - <repo>/compose.yaml  (full compose with baseline + conditional blocks)
#
# Both output files are derived artifacts (gitignored). Source of truth is
# setup.conf + system detection. WS_PATH is detected once and written back
# to <repo>/setup.conf [volumes] mount_1; subsequent runs read mount_1.
#
# Usage: setup.sh [-h|--help] [--base-path <path>] [--lang en|zh-TW|zh-CN|ja]

# ── i18n messages ──────────────────────────────────────────────
# Resolve the symlink (<repo>/setup.sh → template/script/docker/setup.sh)
# so sibling sources (i18n.sh / _tui_conf.sh) are located in the
# template directory regardless of how the script was invoked.
_SETUP_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SETUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${_SETUP_SELF}")" && pwd -P)"
# shellcheck disable=SC1091
source "${_SETUP_SCRIPT_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${_SETUP_SCRIPT_DIR}/_tui_conf.sh"

# Renamed from `_msg` to `_setup_msg` (closes #101) so sourcing this
# file from build.sh / run.sh doesn't silently shadow their own
# top-level `_msg()` (which carries different keys like
# drift_regen / err_no_env / err_rerun_setup). The shadowed key
# lookup would silently return empty — `printf "%s\n" ""` ate the
# drift-regen status line on every fresh-host / setup.conf-changed
# run. Defensive namespacing fixes the class of bug for setup.sh's
# internal i18n table; future helpers added to setup.sh should
# follow the `_setup_*` prefix convention.
_setup_msg() {
  local _key="${1}"
  case "${_LANG}" in
    zh-TW)
      case "${_key}" in
        env_done)         echo ".env 與 compose.yaml 更新完成" ;;
        env_comment)      echo "自動偵測欄位請勿手動修改，如需變更 WS_PATH 可直接編輯此檔案" ;;
        unknown_arg)      echo "未知參數" ;;
        unknown_subcmd)   echo "未知子指令" ;;
        unknown_section)  echo "未知 section" ;;
        invalid_value)    echo "無效的值" ;;
        key_not_found)    echo "找不到鍵" ;;
        section_not_found) echo "找不到 section" ;;
        usage_set)        echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_show)       echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
        usage_list)       echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
        usage_add)        echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_remove)     echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        reset_confirm)    echo "將以模板預設值覆寫 setup.conf（舊檔備份為 setup.conf.bak / .env.bak）。繼續嗎？" ;;
        reset_aborted)    echo "已取消，未變更任何檔案" ;;
        reset_done)       echo "setup.conf 已重設為模板預設值（先前內容備份於 .bak）" ;;
        reset_needs_yes)  echo "非互動模式：請加 --yes 才會執行 reset（避免誤刪）" ;;
        warn_no_repo_conf) echo "未找到 repo 自有的 setup.conf — 全部 section 將使用模板預設值" ;;
        warn_empty_repo_conf) echo "repo 的 setup.conf 沒有任何 section 覆寫 — 全部 section 將使用模板預設值" ;;
      esac ;;
    zh-CN)
      case "${_key}" in
        env_done)         echo ".env 与 compose.yaml 更新完成" ;;
        env_comment)      echo "自动检测字段请勿手动修改，如需变更 WS_PATH 可直接编辑此文件" ;;
        unknown_arg)      echo "未知参数" ;;
        unknown_subcmd)   echo "未知子命令" ;;
        unknown_section)  echo "未知 section" ;;
        invalid_value)    echo "无效的值" ;;
        key_not_found)    echo "找不到键" ;;
        section_not_found) echo "找不到 section" ;;
        usage_set)        echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_show)       echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
        usage_list)       echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
        usage_add)        echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_remove)     echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        reset_confirm)    echo "将以模板默认值覆写 setup.conf（旧文件备份为 setup.conf.bak / .env.bak）。继续吗？" ;;
        reset_aborted)    echo "已取消，未更改任何文件" ;;
        reset_done)       echo "setup.conf 已重置为模板默认值（之前内容备份至 .bak）" ;;
        reset_needs_yes)  echo "非交互模式：请加 --yes 才会执行 reset（避免误删）" ;;
        warn_no_repo_conf) echo "未找到 repo 自有的 setup.conf — 全部 section 将使用模板默认值" ;;
        warn_empty_repo_conf) echo "repo 的 setup.conf 没有任何 section 覆写 — 全部 section 将使用模板默认值" ;;
      esac ;;
    ja)
      case "${_key}" in
        env_done)         echo ".env と compose.yaml 更新完了" ;;
        env_comment)      echo "自動検出フィールドは手動で編集しないでください。WS_PATH の変更はこのファイルを直接編集してください" ;;
        unknown_arg)      echo "不明な引数" ;;
        unknown_subcmd)   echo "不明なサブコマンド" ;;
        unknown_section)  echo "不明な section" ;;
        invalid_value)    echo "無効な値" ;;
        key_not_found)    echo "キーが見つかりません" ;;
        section_not_found) echo "section が見つかりません" ;;
        usage_set)        echo "使い方: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_show)       echo "使い方: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
        usage_list)       echo "使い方: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
        usage_add)        echo "使い方: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_remove)     echo "使い方: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        reset_confirm)    echo "テンプレートのデフォルト値で setup.conf を上書きします（旧ファイルは setup.conf.bak / .env.bak にバックアップ）。続行しますか？" ;;
        reset_aborted)    echo "中断されました。ファイルは変更されていません" ;;
        reset_done)       echo "setup.conf をテンプレートのデフォルトにリセットしました（旧内容は .bak に保存）" ;;
        reset_needs_yes)  echo "非対話モード: --yes を指定しないと reset は実行されません（誤削除防止）" ;;
        warn_no_repo_conf) echo "repo 固有の setup.conf が見つかりません — 全ての section でテンプレートのデフォルト値を使用します" ;;
        warn_empty_repo_conf) echo "repo の setup.conf にセクション上書きがありません — 全ての section でテンプレートのデフォルト値を使用します" ;;
      esac ;;
    *)
      case "${_key}" in
        env_done)         echo ".env + compose.yaml updated" ;;
        env_comment)      echo "Auto-detected fields, do not edit manually. Edit WS_PATH if needed" ;;
        unknown_arg)      echo "Unknown argument" ;;
        unknown_subcmd)   echo "Unknown subcommand" ;;
        unknown_section)  echo "Unknown section" ;;
        invalid_value)    echo "Invalid value" ;;
        key_not_found)    echo "Key not found" ;;
        section_not_found) echo "Section not found" ;;
        usage_set)        echo "Usage: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_show)       echo "Usage: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
        usage_list)       echo "Usage: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
        usage_add)        echo "Usage: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        usage_remove)     echo "Usage: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
        reset_confirm)    echo "Overwrite setup.conf with template default? (prior setup.conf → .bak, prior .env → .env.bak)" ;;
        reset_aborted)    echo "Aborted; no files changed" ;;
        reset_done)       echo "setup.conf reset to template default (prior contents saved to .bak)" ;;
        reset_needs_yes)  echo "Non-interactive: pass --yes to confirm reset (prevents accidental destruction)" ;;
        warn_no_repo_conf) echo "no per-repo setup.conf — using template defaults for all sections" ;;
        warn_empty_repo_conf) echo "per-repo setup.conf has no section overrides — using template defaults for all sections" ;;
      esac ;;
  esac
}

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# ════════════════════════════════════════════════════════════════════
# usage
#
# Prints CLI help. Phase A: English-only text; case scaffolding is in
# place so per-language translations can be added without restructuring.
# ════════════════════════════════════════════════════════════════════
usage() {
  case "${_LANG}" in
    *)
      cat >&2 <<'EOF'
Usage: ./setup.sh [<subcommand>] [-h|--help] [--base-path <path>] [--lang <en|zh-TW|zh-CN|ja>]

Regenerate .env + compose.yaml from setup.conf + system detection.
Normally invoked indirectly via `./build.sh --setup` or `./setup_tui.sh`
Save; run directly for non-interactive / scripted / CI use.

Subcommands:
  apply         (default) Regenerate .env + compose.yaml. No-arg
                invocation falls back to apply for backward compat.
  check-drift   Compare current system / setup.conf against .env's
                SETUP_* metadata. Exit 0 when in sync, exit 1 (with
                drift descriptions on stderr) when regen is needed.
                Used by build.sh / run.sh to decide auto-regen.
  set <section>.<key> <value>
                Write a single value into <base-path>/setup.conf
                (creates the section / key if missing). Validates
                known typed keys (deploy.gpu_count / volumes.mount_*
                / devices.cgroup_rule_* / network.port_* /
                environment.env_* / resources.shm_size). Does NOT
                regenerate .env — run `apply` afterwards if needed.
  show <section>[.<key>]
                Print the value of a single key, or all key=value
                pairs in a section (in on-disk order). Exits non-zero
                when the section / key is absent.
  list [<section>]
                Without an arg: print every section header + key in
                setup.conf. With an arg: equivalent to `show <section>`.
  add <section>.<list> <value>
                Append a value to a list-style section. Picks the next
                free numeric suffix (max+1) and writes `<list>_N = <value>`.
                e.g. `add volumes.mount /foo:/bar` lands in `mount_<next>`.
                Same validators as `set`.
  remove <section>.<key>            Delete the exact key.
  remove <section>.<list> <value>   Delete the first key under the
                section matching `<list>_*` whose value equals <value>.
  reset [-y|--yes]
                Overwrite setup.conf with the template default. Prior
                setup.conf / .env are saved to setup.conf.bak / .env.bak.
                Without --yes, prompts for confirmation; non-tty
                without --yes refuses to proceed.

Options:
  -h, --help            Show this help and exit.
  --base-path PATH      Repo root to operate on. Defaults to the repo
                        containing this script (template/../..).
  --lang LANG           Set message language (en|zh-TW|zh-CN|ja).
                        Defaults to $SETUP_LANG or auto-detected from
                        $LANG.

Outputs (apply only — both derived artifacts, gitignored):
  <base-path>/.env          Exported variables + SETUP_* drift metadata
  <base-path>/compose.yaml  Full compose with baseline + conditional
                            blocks (GPU / GUI / extra volumes / etc.)

Source of truth is setup.conf (template default + optional per-repo
override via section-replace). Edit setup.conf, not the derived files.
EOF
      ;;
  esac
  exit 0
}

# ════════════════════════════════════════════════════════════════════
# detect_user_info
#
# Usage: detect_user_info <user_outvar> <group_outvar> <uid_outvar> <gid_outvar>
# ════════════════════════════════════════════════════════════════════
detect_user_info() {
  local -n __dui_user="${1:?"${FUNCNAME[0]}: missing user outvar"}"; shift
  local -n __dui_group="${1:?"${FUNCNAME[0]}: missing group outvar"}"; shift
  local -n __dui_uid="${1:?"${FUNCNAME[0]}: missing uid outvar"}"; shift
  local -n __dui_gid="${1:?"${FUNCNAME[0]}: missing gid outvar"}"

  __dui_user="${USER:-$(id -un)}"
  __dui_group="$(id -gn)"
  __dui_uid="$(id -u)"
  __dui_gid="$(id -g)"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
#
# Usage: detect_hardware <outvar>
# ════════════════════════════════════════════════════════════════════
detect_hardware() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  _outvar="$(uname -m)"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
#
# Tries docker info first, falls back to USER, then id -un
#
# Usage: detect_docker_hub_user <outvar>
# ════════════════════════════════════════════════════════════════════
detect_docker_hub_user() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  local _name=""
  _name="$(docker info 2>/dev/null | awk '/^[[:space:]]*Username:/{print $2}')" || true
  _outvar="${_name:-${USER:-$(id -un)}}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
#
# Checks nvidia-container-toolkit via dpkg-query
#
# Usage: detect_gpu <outvar>
# outvar: "true" or "false"
# ════════════════════════════════════════════════════════════════════
detect_gpu() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  if dpkg-query -W -f='${db:Status-Abbrev}\n' -- "nvidia-container-toolkit" 2>/dev/null \
    | grep -q '^ii'; then
    _outvar=true
  else
    _outvar=false
  fi
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu_count
#
# Queries `nvidia-smi -L` for the number of installed NVIDIA GPUs. Emits
# "0" when nvidia-smi is missing or returns non-zero (host has no GPU,
# or the driver stack is broken). TUI uses this to show "Detected N"
# alongside the `[deploy] gpu_count` prompt.
#
# Usage: detect_gpu_count <outvar>
# ════════════════════════════════════════════════════════════════════
detect_gpu_count() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  # Use `__dgc_`-prefixed locals to avoid nameref shadowing when callers
  # name their outvar `_n` or `_line` — bash namerefs rebind to the nearest
  # local of the same name, which silently drops writes to the caller.
  local __dgc_n=0 __dgc_line
  if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS= read -r __dgc_line; do
      if [[ "${__dgc_line}" == "GPU "* ]]; then
        __dgc_n=$(( __dgc_n + 1 ))
      fi
    done < <(nvidia-smi -L 2>/dev/null || true)
  fi
  _outvar="${__dgc_n}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gui
#
# Returns "true" if host has X11 or Wayland display set, "false" otherwise.
#
# Usage: detect_gui <outvar>
# ════════════════════════════════════════════════════════════════════
detect_gui() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    _outvar=true
  else
    _outvar=false
  fi
}

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
# ════════════════════════════════════════════════════════════════════

# _parse_ini_section <file> <section> <keys_outvar> <values_outvar>
#
# Reads one section [<section>] from <file> into parallel arrays.
# Skips comments (#) and empty lines. Trims key/value whitespace.
# If a key is defined both in <base_path>/setup.conf and in template/setup.conf,
# caller should use _load_setup_conf which handles the merge (replace strategy).
_parse_ini_section() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _pis_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _pis_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  _pis_keys=()
  _pis_values=()
  [[ -f "${_file}" ]] || return 0

  local __pis_line __pis_current="" __pis_k __pis_v
  while IFS= read -r __pis_line || [[ -n "${__pis_line}" ]]; do
    [[ -z "${__pis_line}" || "${__pis_line}" =~ ^[[:space:]]*# ]] && continue

    # Trim
    __pis_line="${__pis_line#"${__pis_line%%[![:space:]]*}"}"
    __pis_line="${__pis_line%"${__pis_line##*[![:space:]]}"}"
    [[ -z "${__pis_line}" ]] && continue

    # Section header
    if [[ "${__pis_line}" =~ ^\[(.+)\]$ ]]; then
      __pis_current="${BASH_REMATCH[1]}"
      continue
    fi

    # Only collect entries for the requested section
    [[ "${__pis_current}" == "${_section}" ]] || continue

    # Require key = value
    [[ "${__pis_line}" != *=* ]] && continue
    __pis_k="${__pis_line%%=*}"
    __pis_v="${__pis_line#*=}"
    __pis_k="${__pis_k#"${__pis_k%%[![:space:]]*}"}"
    __pis_k="${__pis_k%"${__pis_k##*[![:space:]]}"}"
    __pis_v="${__pis_v#"${__pis_v%%[![:space:]]*}"}"
    __pis_v="${__pis_v%"${__pis_v##*[![:space:]]}"}"

    _pis_keys+=("${__pis_k}")
    _pis_values+=("${__pis_v}")
  done < "${_file}"
}

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Merges per-repo setup.conf with template default, section-replace
# strategy: if per-repo setup.conf has the section, use its entries;
# otherwise fall back to the template's section. SETUP_CONF env var forces
# a specific file (skips the merge entirely).
#
# #201: collapsed back to 2-file model. <repo>/setup.conf is the user
# override (committed, not gitignored, survives template upgrade because
# template subtree pull never touches it — it lives outside template/).
_load_setup_conf() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _section="${2:?"${FUNCNAME[0]}: missing section"}"
  local -n _lsc_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lsc_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"

  # If SETUP_CONF is set, only read from it (no merge)
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _parse_ini_section "${SETUP_CONF}" "${_section}" _lsc_keys _lsc_values
    return 0
  fi

  local _self_dir="${_SETUP_SCRIPT_DIR}"
  local _template_conf="${_self_dir}/../../setup.conf"
  local _repo_conf="${_base}/setup.conf"

  # Try per-repo setup.conf first; if the section exists there, use it.
  if [[ -f "${_repo_conf}" ]]; then
    local -a __lsc_k=() __lsc_v=()
    _parse_ini_section "${_repo_conf}" "${_section}" __lsc_k __lsc_v
    if (( ${#__lsc_k[@]} > 0 )); then
      _lsc_keys=("${__lsc_k[@]}")
      _lsc_values=("${__lsc_v[@]}")
      return 0
    fi
  fi

  # Fall back to template default
  _parse_ini_section "${_template_conf}" "${_section}" _lsc_keys _lsc_values
}

# _setup_load_merged_full <template_path> <local_path> \
#                         <sections_outvar> <keys_outvar> <values_outvar>
#
# Returns the section-replace merged view of <template_path> overlaid by
# <local_path>: for each section present in .local, the template's
# entries for that section are replaced wholesale by .local's entries;
# sections .local omits keep template values.
#
# Output arrays mirror `_load_setup_conf_full` shape: sections list +
# parallel `<section>.<key>` and value arrays. Used by `show`/`list` so
# users see effective post-apply values without having to re-run apply
# after every set/add/remove.
#
# #174: replaces direct reads of <base>/setup.conf in show/list, since
# setup.conf is now the materialized output of apply (potentially stale
# until the next apply).
_setup_load_merged_full() {
  local _tpl="${1:?}"
  local _loc="${2:?}"
  local -n _slm_sections="${3:?}"
  local -n _slm_keys="${4:?}"
  local -n _slm_values="${5:?}"

  _slm_sections=()
  _slm_keys=()
  _slm_values=()

  local -a _tpl_sects=() _tpl_keys=() _tpl_vals=()
  local -a _loc_sects=() _loc_keys=() _loc_vals=()
  if [[ -f "${_tpl}" ]]; then
    _load_setup_conf_full "${_tpl}" _tpl_sects _tpl_keys _tpl_vals
  fi
  if [[ -f "${_loc}" ]]; then
    _load_setup_conf_full "${_loc}" _loc_sects _loc_keys _loc_vals
  fi

  # Sections appearing only in template, in template order, then any
  # section in .local that template lacks.
  local _s
  for _s in "${_tpl_sects[@]}"; do
    _slm_sections+=("${_s}")
  done
  for _s in "${_loc_sects[@]}"; do
    local _seen=0 _e
    for _e in "${_slm_sections[@]}"; do
      [[ "${_e}" == "${_s}" ]] && { _seen=1; break; }
    done
    (( _seen )) || _slm_sections+=("${_s}")
  done

  # For each section in the union: if .local has it, copy .local's
  # entries (replace strategy); else copy template's entries.
  local _sec _i _ns
  for _sec in "${_slm_sections[@]}"; do
    local _local_has=0
    for _e in "${_loc_sects[@]}"; do
      [[ "${_e}" == "${_sec}" ]] && { _local_has=1; break; }
    done
    if (( _local_has )); then
      for (( _i=0; _i<${#_loc_keys[@]}; _i++ )); do
        _ns="${_loc_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_loc_vals[_i]}")
        fi
      done
    else
      for (( _i=0; _i<${#_tpl_keys[@]}; _i++ )); do
        _ns="${_tpl_keys[_i]}"
        if [[ "${_ns}" == "${_sec}."* ]]; then
          _slm_keys+=("${_ns}")
          _slm_values+=("${_tpl_vals[_i]}")
        fi
      done
    fi
  done
}

# _get_conf_value <keys_ref> <values_ref> <key> <default> <outvar>
#
# Returns the value for <key> in the parallel arrays; <default> if missing.
_get_conf_value() {
  local -n _gcv_keys="${1:?}"
  local -n _gcv_values="${2:?}"
  local _key="${3:?}"
  local _default="${4-}"
  local -n _gcv_out="${5:?}"

  local i
  for (( i=0; i<${#_gcv_keys[@]}; i++ )); do
    if [[ "${_gcv_keys[i]}" == "${_key}" ]]; then
      _gcv_out="${_gcv_values[i]}"
      return 0
    fi
  done
  _gcv_out="${_default}"
}

# _get_conf_list_sorted <keys_ref> <values_ref> <prefix> <outvar_array>
#
# Collects entries whose key starts with <prefix> (e.g. "mount_") and sorts
# by the numeric suffix. Returns VALUES in sorted order.
_get_conf_list_sorted() {
  local -n _gcls_keys="${1:?}"
  local -n _gcls_values="${2:?}"
  local _prefix="${3:?}"
  local -n _gcls_out="${4:?}"

  _gcls_out=()
  local -a __gcls_pairs=()
  local i __gcls_k __gcls_num
  for (( i=0; i<${#_gcls_keys[@]}; i++ )); do
    __gcls_k="${_gcls_keys[i]}"
    if [[ "${__gcls_k}" == "${_prefix}"* ]]; then
      __gcls_num="${__gcls_k#"${_prefix}"}"
      # Only numeric suffixes participate; empty values mean opt-out
      [[ "${__gcls_num}" =~ ^[0-9]+$ ]] || continue
      [[ -z "${_gcls_values[i]}" ]] && continue
      __gcls_pairs+=("${__gcls_num}:${_gcls_values[i]}")
    fi
  done

  # Sort by numeric prefix before ":"
  if (( ${#__gcls_pairs[@]} > 0 )); then
    local __gcls_sorted
    __gcls_sorted=$(printf '%s\n' "${__gcls_pairs[@]}" | sort -t: -k1,1n)
    while IFS= read -r __gcls_k; do
      _gcls_out+=("${__gcls_k#*:}")
    done <<< "${__gcls_sorted}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# Rule applicators for [image] rules (used by detect_image_name)
# ════════════════════════════════════════════════════════════════════

_rule_prefix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part _last=""
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    _last="${_part}"
    break
  done
  if [[ "${_last}" == "${_value}"* ]]; then
    echo "${_last#"${_value}"}"
  fi
}

_rule_suffix() {
  local _path="$1" _value="$2"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    if [[ "${_part}" == *"${_value}" ]]; then
      echo "${_part%"${_value}"}"
      return
    fi
  done
}

_rule_basename() {
  local _path="$1"
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${_path}"
  local i _part
  for (( i=${#_parts[@]}-1; i>=0; i-- )); do
    _part="${_parts[i]}"
    [[ -z "${_part}" ]] && continue
    echo "${_part}"
    return
  done
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name
#
# Reads [image] rules from setup.conf (per-repo or template default).
# rules is a comma-separated ordered list; first match wins.
#
# Usage: detect_image_name <outvar> <path>
# ════════════════════════════════════════════════════════════════════
detect_image_name() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _path="${1:?"${FUNCNAME[0]}: missing path"}"

  local _base="${BASE_PATH:-${_path}}"
  local -a __din_keys=() __din_values=()
  _load_setup_conf "${_base}" "image" __din_keys __din_values

  # Collect rule_N entries in numeric order.
  local -a _rule_arr=()
  _get_conf_list_sorted __din_keys __din_values "rule_" _rule_arr

  local _found=""
  if (( ${#_rule_arr[@]} > 0 )); then
    local _rule _value
    for _rule in "${_rule_arr[@]}"; do
      _rule="${_rule#"${_rule%%[![:space:]]*}"}"
      _rule="${_rule%"${_rule##*[![:space:]]}"}"
      [[ -z "${_rule}" ]] && continue

      if [[ "${_rule}" == prefix:* ]]; then
        _value="${_rule#prefix:}"
        _found="$(_rule_prefix "${_path}" "${_value}")"
      elif [[ "${_rule}" == suffix:* ]]; then
        _value="${_rule#suffix:}"
        _found="$(_rule_suffix "${_path}" "${_value}")"
      elif [[ "${_rule}" == string:* ]]; then
        # Short-circuit: user provided the exact image name as a string,
        # bypass any path-derived inference.
        _found="${_rule#string:}"
      elif [[ "${_rule}" == "@basename" ]]; then
        _found="$(_rule_basename "${_path}")"
      elif [[ "${_rule}" == @default:* ]]; then
        _found="${_rule#@default:}"
        printf "[setup] INFO: IMAGE_NAME using @default:%s\n" "${_found}" >&2
      fi

      [[ -n "${_found}" ]] && break
    done
  fi

  if [[ -z "${_found}" ]]; then
    printf "[setup] WARNING: IMAGE_NAME could not be detected. Using 'unknown'.\n" >&2
    _found="unknown"
  fi
  # Lowercase + sanitize: docker compose project names (and image tags)
  # forbid `.`, uppercase, and anything outside [a-z0-9_-]. `@basename`
  # on a dir like "tmp.abcdef" would otherwise produce
  # "yunchien-tmp.abcdef" which docker compose rejects. Map invalids to
  # `-`, collapse runs, and strip any leading non-alphanumeric.
  local _lower="${_found,,}"
  local _sanitized="${_lower//[^a-z0-9_-]/-}"
  # collapse multiple '-' in a row
  while [[ "${_sanitized}" == *--* ]]; do
    _sanitized="${_sanitized//--/-}"
  done
  # strip leading '-' / '_'
  _sanitized="${_sanitized#[-_]}"
  # strip trailing '-' / '_'
  _sanitized="${_sanitized%[-_]}"
  [[ -z "${_sanitized}" ]] && _sanitized="unknown"
  _outvar="${_sanitized}"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
#
# Workspace detection strategy (in order):
#   1. If current directory is docker_*, use sibling *_ws (strip prefix)
#   2. Traverse path upward looking for a *_ws component
#   3. Fall back to parent directory
#
# Usage: detect_ws_path <outvar> <base_path>
# ════════════════════════════════════════════════════════════════════
detect_ws_path() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _base_path="${1:?"${FUNCNAME[0]}: missing base_path"}"

  if [[ ! -d "${_base_path}" ]]; then
    printf "[setup] ERROR: detect_ws_path: base_path does not exist: %s\n" \
      "${_base_path}" >&2
    return 1
  fi
  _base_path="$(cd "${_base_path}" && pwd -P)"

  local _dirname=""
  _dirname="$(basename "${_base_path}")"

  if [[ "${_dirname}" == docker_* ]]; then
    local _name="${_dirname#docker_}"
    local _parent=""
    _parent="$(dirname "${_base_path}")"
    local _sibling="${_parent}/${_name}_ws"
    if [[ -d "${_sibling}" ]]; then
      _outvar="$(cd "${_sibling}" && pwd -P)"
      return 0
    fi
  fi

  local _check="${_base_path}"
  while [[ "${_check}" != "/" && "${_check}" != "." ]]; do
    if [[ "$(basename "${_check}")" == *_ws && -d "${_check}" ]]; then
      _outvar="$(cd "${_check}" && pwd -P)"
      return 0
    fi
    _check="$(dirname "${_check}")"
  done

  _outvar="$(dirname "${_base_path}")"
}

# ════════════════════════════════════════════════════════════════════
# Resolvers: mode + detection → final enabled state
# ════════════════════════════════════════════════════════════════════

# _resolve_gpu <mode> <detected> <outvar>
#   mode=auto   → enabled iff detected==true
#   mode=force  → always enabled
#   mode=off    → always disabled
_resolve_gpu() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rg_out="${3:?}"
  case "${_mode}" in
    force) _rg_out="true" ;;
    off)   _rg_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rg_out="true"; else _rg_out="false"; fi
      ;;
  esac
}

# _resolve_gui <mode> <detected> <outvar>
_resolve_gui() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rgu_out="${3:?}"
  case "${_mode}" in
    force) _rgu_out="true" ;;
    off)   _rgu_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rgu_out="true"; else _rgu_out="false"; fi
      ;;
  esac
}

# _detect_jetson
#   True if running on Jetson (JetPack / L4T) — NVIDIA ships
#   /etc/nv_tegra_release as the canonical marker on tegra-based boards.
#   Env override: SETUP_DETECT_JETSON=true|false forces detection result
#   (used by tests to avoid touching /etc/).
_detect_jetson() {
  if [[ -n "${SETUP_DETECT_JETSON:-}" ]]; then
    [[ "${SETUP_DETECT_JETSON}" == "true" ]]
    return
  fi
  [[ -f "/etc/nv_tegra_release" ]]
}

# _resolve_runtime <mode> <outvar>
#   mode=nvidia → "nvidia" (force, e.g. desktop with csv-mode toolkit)
#   mode=auto   → "nvidia" iff _detect_jetson, else ""
#   mode=off|"" → "" (no runtime key emitted; Docker default runc)
#
# When non-empty, setup.sh emits `runtime: <value>` at service level in
# compose.yaml. Required on Jetson because its nvidia-container-toolkit
# runs in csv mode, which refuses the modern `--gpus` flow that
# `deploy.resources.reservations.devices` translates to.
_resolve_runtime() {
  local _mode="${1:-off}"
  local -n _rr_out="${2:?}"
  case "${_mode}" in
    nvidia) _rr_out="nvidia" ;;
    auto)
      if _detect_jetson; then _rr_out="nvidia"; else _rr_out=""; fi
      ;;
    off|""|*) _rr_out="" ;;
  esac
}

# _resolve_build_network <mode> <outvar>
#   mode=host / bridge / none / default → pass through
#   mode=auto → "host" iff _detect_jetson, else "" (issue #102)
#   mode=off | "" → "" (no network key emitted; Docker defaults to bridge)
#
# Jetson L4T kernels commonly lack the iptables modules docker's bridge
# NAT needs, so first-time `docker build` on Jetson dies with DNS
# resolution failures before the apt step. Auto-promoting to host-net
# on Jetson removes the trap door; desktop hosts keep default bridge.
_resolve_build_network() {
  local _mode="${1:-}"
  local -n _rbn_out="${2:?}"
  case "${_mode}" in
    host|bridge|none|default) _rbn_out="${_mode}" ;;
    auto)
      if _detect_jetson; then _rbn_out="host"; else _rbn_out=""; fi
      ;;
    off|""|*) _rbn_out="" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash <base_path> <outvar>
#
# sha256 of the effective config (template default + per-repo
# setup.conf override). Used to detect conf drift in build.sh/run.sh.
# Drift means "user changed their override (or template was upgraded)".
# ════════════════════════════════════════════════════════════════════
_compute_conf_hash() {
  local _base="${1:?}"
  local -n _cch_out="${2:?}"
  local _self_dir="${_SETUP_SCRIPT_DIR}"
  local _template_conf="${_self_dir}/../../setup.conf"
  local _repo_conf="${_base}/setup.conf"

  # Use command substitution (not pipe-into-block) so the nameref
  # assignment happens in the function's scope, not a subshell.
  # The trailing `true` keeps the block's exit status 0 even when every
  # conditional cat is skipped (under `set -euo pipefail` a non-zero block
  # exit would propagate via command substitution and abort setup.sh).
  _cch_out="$(
    {
      [[ -f "${_template_conf}" ]] && cat "${_template_conf}"
      [[ -f "${_repo_conf}"     ]] && cat "${_repo_conf}"
      [[ -n "${SETUP_CONF:-}"   ]] && [[ -f "${SETUP_CONF}" ]] && cat "${SETUP_CONF}"
      true
    } | sha256sum | cut -d' ' -f1
  )"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml <out> <repo_name> <gui_enabled> <gpu_enabled>
#                       <gpu_count> <gpu_caps> <extras_array_ref>
#                       [<network_name>]
#
# Emits full compose.yaml with:
#   - Baseline: workspace + X11 (iff GUI) + GUI env block (iff GUI)
#   - Conditional: GPU deploy block (iff gpu_enabled=true)
#   - Extra volumes from [volumes] section (comes in via extras_array_ref)
#   - When network_name is given (only meaningful for mode=bridge), the
#     service joins that external network and a top-level `networks:`
#     block declares it external. Otherwise falls back to the env-driven
#     `network_mode: ${NETWORK_MODE}`.
# IPC/privileged always read from env var refs; .env provides values.
# ════════════════════════════════════════════════════════════════════
generate_compose_yaml() {
  local _out="${1:?}"
  local _name="${2:?}"
  local _gui="${3:?}"
  local _gpu="${4:?}"
  local _gpu_count="${5:?}"
  local _gpu_caps="${6:?}"
  local -n _gcy_extras="${7:?}"
  local _net_name="${8:-}"
  local _devices_str="${9:-}"
  local _env_str="${10:-}"
  local _tmpfs_str="${11:-}"
  local _ports_str="${12:-}"
  local _shm_size="${13:-}"
  local _net_mode="${14:-host}"
  local _ipc_mode="${15:-host}"
  local _cap_add_str="${16:-}"
  local _cap_drop_str="${17:-}"
  local _sec_opt_str="${18:-}"
  local _cgroup_rule_str="${19:-}"
  local _user_build_args_str="${20:-}"
  local _target_arch="${21:-}"
  local _build_network="${22:-}"
  local _runtime="${23:-}"
  local _additional_contexts_str="${24:-}"

  # additional_contexts emitter: forwards `[additional_contexts]
  # context_N = NAME=PATH` entries to compose.yaml's
  # `build.additional_contexts:` block under every service that has its
  # own `build:` (devel / runtime / test). Empty = omit the block so
  # repos that don't need named build contexts see no diff.
  _emit_additional_contexts_block() {
    [[ -z "${_additional_contexts_str}" ]] && return 0
    echo "      additional_contexts:"
    local _ac _name _path
    while IFS= read -r _ac; do
      [[ -z "${_ac}" ]] && continue
      _name="${_ac%%=*}"
      _path="${_ac#*=}"
      printf '        %s: %s\n' "${_name}" "${_path}"
    done <<< "${_additional_contexts_str}"
  }

  # TARGETARCH line emitter: only when target_arch is set. Empty =
  # omit the line entirely so BuildKit auto-fills TARGETARCH from the
  # host. Shared between devel + test service blocks below.
  _emit_target_arch_line() {
    [[ -z "${_target_arch}" ]] && return 0
    # shellcheck disable=SC2016  # literal ${} consumed by compose, not bash
    printf '        TARGETARCH: ${TARGET_ARCH}\n'
  }

  # build.network emitter: only when build_network is set. Empty =
  # omit the line so Docker uses its default (bridge). Non-empty =
  # force the build to use that network (typically "host" for
  # environments where bridge NAT doesn't work).
  _emit_build_network_line() {
    [[ -z "${_build_network}" ]] && return 0
    printf '      network: %s\n' "${_build_network}"
  }

  # runtime emitter: Jetson / csv-mode nvidia-container-toolkit hosts
  # need `runtime: nvidia` at service level to bypass the modern
  # --gpus flow (which `deploy.resources.reservations.devices`
  # translates to). Empty = omit so Docker uses the default runc.
  # Only emitted for the devel service; test doesn't run.
  _emit_runtime_line() {
    [[ -z "${_runtime}" ]] && return 0
    printf '    runtime: %s\n' "${_runtime}"
  }

  # Detect `FROM … AS runtime` in the sibling Dockerfile — if present,
  # emit a dedicated `runtime` compose service that extends `devel`'s
  # baseline (same volumes / network / caps / GPU) but with its own
  # image tag, container_name, and non-interactive tty settings so
  # `./run.sh -t runtime` auto-runs the Dockerfile CMD (e.g. a
  # parameter_bridge process). Absent `AS runtime` → skip emission so
  # repos without a runtime stage don't get a broken service entry.
  # Issue #108.
  local _dockerfile _has_runtime=false
  _dockerfile="$(dirname -- "${_out}")/Dockerfile"
  if [[ -f "${_dockerfile}" ]] \
     && grep -qE '^FROM[[:space:]]+[^[:space:]]+[[:space:]]+AS[[:space:]]+runtime[[:space:]]*$' "${_dockerfile}"; then
    _has_runtime=true
  fi

  # Convert space-separated caps to YAML array form [a, b, c]
  local -a _caps_arr=()
  read -ra _caps_arr <<< "${_gpu_caps}"
  local _caps_yaml="["
  local _first=1 _cap
  for _cap in "${_caps_arr[@]}"; do
    if (( _first )); then
      _caps_yaml+="${_cap}"
      _first=0
    else
      _caps_yaml+=", ${_cap}"
    fi
  done
  _caps_yaml+="]"

  {
    cat <<'HEADER'
# AUTO-GENERATED BY setup.sh — DO NOT EDIT.
# Edit setup.conf instead. Regenerate via ./build.sh --setup or ./run.sh --setup.
HEADER
    cat <<YAML
services:
  devel:
    build:
      context: .
      dockerfile: Dockerfile
      target: devel
YAML
    _emit_additional_contexts_block
    _emit_build_network_line
    cat <<YAML
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: \${TZ:-Asia/Taipei}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
YAML
    _emit_target_arch_line
    # User-added [build] args: emit each as `KEY: \${KEY}` — Dockerfile's
    # `ARG KEY="default"` fallback handles empty values. No hard-coded
    # defaults here since template doesn't know them.
    _emit_user_build_args() {
      [[ -z "${_user_build_args_str}" ]] && return 0
      local _ub _k
      while IFS= read -r _ub; do
        [[ -z "${_ub}" ]] && continue
        _k="${_ub%%=*}"
        # Emit literal compose substitution `${KEY}` into compose.yaml;
        # the ${} is consumed by docker compose at runtime, not bash.
        # shellcheck disable=SC2016
        printf '        %s: ${%s}\n' "${_k}" "${_k}"
      done <<< "${_user_build_args_str}"
    }
    _emit_user_build_args
    cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:devel
    container_name: ${_name}\${INSTANCE_SUFFIX:-}
    privileged: \${PRIVILEGED}
    ipc: \${IPC_MODE}
    stdin_open: true
    tty: true
YAML
    _emit_runtime_line
    # cap_add / cap_drop / security_opt from [security] section
    if [[ -n "${_cap_add_str}" ]]; then
      echo "    cap_add:"
      local _cap
      while IFS= read -r _cap; do
        [[ -z "${_cap}" ]] && continue
        echo "      - ${_cap}"
      done <<< "${_cap_add_str}"
    fi
    if [[ -n "${_cap_drop_str}" ]]; then
      echo "    cap_drop:"
      local _cd
      while IFS= read -r _cd; do
        [[ -z "${_cd}" ]] && continue
        echo "      - ${_cd}"
      done <<< "${_cap_drop_str}"
    fi
    if [[ -n "${_sec_opt_str}" ]]; then
      echo "    security_opt:"
      local _so
      while IFS= read -r _so; do
        [[ -z "${_so}" ]] && continue
        echo "      - ${_so}"
      done <<< "${_sec_opt_str}"
    fi
    if [[ -n "${_net_name}" ]]; then
      cat <<YAML
    networks:
      - ${_net_name}
YAML
    else
      echo "    network_mode: \${NETWORK_MODE}"
    fi
    # environment: merges GUI baseline (DISPLAY etc.) + user env_N entries
    if [[ "${_gui}" == "true" ]] || [[ -n "${_env_str}" ]]; then
      echo "    environment:"
      if [[ "${_gui}" == "true" ]]; then
        cat <<'YAML'
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=${XAUTHORITY:-}
YAML
      fi
      if [[ -n "${_env_str}" ]]; then
        local _ev
        while IFS= read -r _ev; do
          [[ -z "${_ev}" ]] && continue
          echo "      - ${_ev}"
        done <<< "${_env_str}"
      fi
    fi
    # ports: only emitted when network_mode=bridge (ignored under host)
    if [[ -n "${_ports_str}" ]] && [[ "${_net_mode}" == "bridge" ]]; then
      echo "    ports:"
      local _p
      while IFS= read -r _p; do
        [[ -z "${_p}" ]] && continue
        echo "      - \"${_p}\""
      done <<< "${_ports_str}"
    fi
    # volumes block (GUI baseline conditional; workspace + extras from
    # [volumes] mount_* — mount_1 is the workspace, auto-populated by
    # setup.sh on first run and user-editable thereafter).
    if [[ "${_gui}" == "true" ]] || (( ${#_gcy_extras[@]} > 0 )); then
      echo "    volumes:"
      if [[ "${_gui}" == "true" ]]; then
        cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:${XAUTHORITY:-/dev/null}:ro
YAML
      fi
      local _m
      for _m in "${_gcy_extras[@]}"; do
        echo "      - ${_m}"
      done
    fi
    # devices: + device_cgroup_rules: from [devices] section
    if [[ -n "${_devices_str}" ]]; then
      echo "    devices:"
      local _d
      while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        echo "      - ${_d}"
      done <<< "${_devices_str}"
    fi
    # device_cgroup_rules: (dynamic device permissions, e.g. USB hotplug)
    if [[ -n "${_cgroup_rule_str}" ]]; then
      echo "    device_cgroup_rules:"
      local _cr
      while IFS= read -r _cr; do
        [[ -z "${_cr}" ]] && continue
        echo "      - \"${_cr}\""
      done <<< "${_cgroup_rule_str}"
    fi
    # tmpfs: RAM-backed mounts
    if [[ -n "${_tmpfs_str}" ]]; then
      echo "    tmpfs:"
      local _tf
      while IFS= read -r _tf; do
        [[ -z "${_tf}" ]] && continue
        echo "      - ${_tf}"
      done <<< "${_tmpfs_str}"
    fi
    # shm_size: only emitted when ipc != host (otherwise Docker ignores it)
    if [[ -n "${_shm_size}" ]] && [[ "${_ipc_mode}" != "host" ]]; then
      echo "    shm_size: ${_shm_size}"
    fi
    if [[ "${_gpu}" == "true" ]]; then
      cat <<YAML
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${_gpu_count}
              capabilities: ${_caps_yaml}
YAML
    fi

    # runtime service (when Dockerfile has `AS runtime`): extends devel's
    # baseline (volumes, network, GPU, capabilities), overrides target +
    # image + container_name, disables tty/stdin_open since runtime is
    # auto-run headless (Dockerfile CMD drives). profiles: [runtime]
    # keeps plain `compose up` scoped to devel; `compose run runtime` or
    # `compose up runtime` still works because explicit-service targeting
    # bypasses the profile gate.
    if [[ "${_has_runtime}" == true ]]; then
      cat <<YAML

  runtime:
    extends:
      service: devel
    build:
      context: .
      dockerfile: Dockerfile
      target: runtime
YAML
      _emit_additional_contexts_block
      cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:runtime
    container_name: ${_name}-runtime\${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - runtime
YAML
    fi

    cat <<YAML

  test:
    build:
      context: .
      dockerfile: Dockerfile
      target: test
YAML
    _emit_additional_contexts_block
    _emit_build_network_line
    cat <<YAML
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: \${TZ:-Asia/Taipei}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
YAML
    _emit_target_arch_line
    _emit_user_build_args
    cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:test
    profiles:
      - test
YAML
    if [[ -n "${_net_name}" ]]; then
      cat <<YAML

networks:
  ${_net_name}:
    driver: bridge
YAML
    fi
  } > "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# write_env
#
# Usage: write_env <env_file> <user_name> <user_group> <uid> <gid>
#                  <hardware> <docker_hub_user> <gpu_detected>
#                  <image_name> <ws_path>
#                  <apt_mirror_ubuntu> <apt_mirror_debian> <tz>
#                  <network_mode> <ipc_mode> <privileged>
#                  <gpu_count> <gpu_caps>
#                  <gui_detected> <conf_hash>
#                  [<network_name>] [<user_build_args>] [<target_arch>]
#
# user_build_args is a newline-separated list of "KEY=VALUE" pairs
# from `[build] arg_N` entries outside the three known keys
# (APT_MIRROR_UBUNTU / APT_MIRROR_DEBIAN / TZ). Each pair is appended
# as an exported env var so compose.yaml's generated build.args block
# can reference them via ${KEY}.
#
# target_arch (optional): when non-empty, exported as TARGET_ARCH so
# build.sh / compose.yaml can force the Docker TARGETARCH build arg.
# Empty/omitted means "don't touch" — BuildKit's auto-detection of the
# host / --platform stays intact.
# ════════════════════════════════════════════════════════════════════
write_env() {
  local _env_file="${1:?}"; shift
  local _user_name="${1}"; shift
  local _user_group="${1}"; shift
  local _uid="${1}"; shift
  local _gid="${1}"; shift
  local _hardware="${1}"; shift
  local _docker_hub_user="${1}"; shift
  local _gpu_detected="${1}"; shift
  local _image_name="${1}"; shift
  local _ws_path="${1}"; shift
  local _apt_mirror_ubuntu="${1}"; shift
  local _apt_mirror_debian="${1}"; shift
  local _tz="${1}"; shift
  local _network_mode="${1}"; shift
  local _ipc_mode="${1}"; shift
  local _privileged="${1}"; shift
  local _gpu_count="${1}"; shift
  local _gpu_caps="${1}"; shift
  local _gui_detected="${1}"; shift
  local _conf_hash="${1}"; shift
  local _network_name="${1:-}"; shift || true
  local _user_build_args="${1:-}"; shift || true
  local _target_arch="${1:-}"; shift || true
  local _build_network="${1:-}"

  local _comment=""
  _comment="$(_setup_msg env_comment)"
  cat > "${_env_file}" << EOF
# Auto-generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ${_comment}

# ── User / hardware (auto-detected) ──────────
USER_NAME=${_user_name}
USER_GROUP=${_user_group}
USER_UID=${_uid}
USER_GID=${_gid}
HARDWARE=${_hardware}
DOCKER_HUB_USER=${_docker_hub_user}
GPU_ENABLED=${_gpu_detected}
IMAGE_NAME=${_image_name}

# ── Workspace ────────────────────────────────
WS_PATH=${_ws_path}

# ── APT Mirror ───────────────────────────────
APT_MIRROR_UBUNTU=${_apt_mirror_ubuntu}
APT_MIRROR_DEBIAN=${_apt_mirror_debian}

# ── Timezone ─────────────────────────────────
TZ=${_tz}

# ── Runtime config (from setup.conf) ─────────
NETWORK_MODE=${_network_mode}
NETWORK_NAME=${_network_name}
IPC_MODE=${_ipc_mode}
PRIVILEGED=${_privileged}
GPU_COUNT=${_gpu_count}
GPU_CAPABILITIES="${_gpu_caps}"

# ── Setup metadata (drift detection — do not edit) ──
SETUP_CONF_HASH=${_conf_hash}
SETUP_GUI_DETECTED=${_gui_detected}
SETUP_TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
EOF

  # ── Extra [build] args (user-added, beyond APT_MIRROR_* / TZ) ──
  # Appended after the fixed block so downstream consumers read them
  # via the same set -o allexport source.
  if [[ -n "${_user_build_args:-}" ]]; then
    {
      printf '\n# ── Extra build args (from [build] arg_N) ──\n'
      local _line _k _v
      while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        _k="${_line%%=*}"
        _v="${_line#*=}"
        # Quote the value so multi-word / shell-metachar values round-trip
        # safely through `source .env` (regression: GPU_CAPABILITIES).
        printf '%s=%q\n' "${_k}" "${_v}"
      done <<< "${_user_build_args}"
    } >> "${_env_file}"
  fi

  # TARGETARCH override: only emit when the user explicitly set it in
  # [build] target_arch. Empty stays unset so build.sh / compose skip
  # the --build-arg and BuildKit's auto-fill kicks in.
  if [[ -n "${_target_arch:-}" ]]; then
    {
      printf '\n# ── TARGETARCH override (from [build] target_arch) ──\n'
      printf 'TARGET_ARCH=%q\n' "${_target_arch}"
    } >> "${_env_file}"
  fi

  # BUILD_NETWORK override: only emit when the user set [build] network.
  # Empty stays unset so build.sh skips the `--network` flag and docker
  # compose build inherits its default.
  if [[ -n "${_build_network:-}" ]]; then
    {
      printf '\n# ── BUILD_NETWORK override (from [build] network) ──\n'
      printf 'BUILD_NETWORK=%q\n' "${_build_network}"
    } >> "${_env_file}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift <base_path>
#
# Compares current system state + setup.conf hash against .env's SETUP_*
# metadata. Prints drift descriptions to stderr when drift detected and
# returns 1 so the caller (build.sh / run.sh) can auto-regenerate the
# derived artifacts. Returns 0 (silent) when in sync.
#
# Requires .env to exist (caller checks first).
# ════════════════════════════════════════════════════════════════════
_check_setup_drift() {
  local _base="${1:?}"
  local _env_file="${_base}/.env"
  [[ -f "${_env_file}" ]] || return 0

  # Read stored values from .env without polluting caller's env
  local _stored_hash="" _stored_gui="" _stored_gpu="" _stored_uid=""
  _stored_hash="$(grep -oP '^SETUP_CONF_HASH=\K.*'    "${_env_file}" 2>/dev/null || true)"
  _stored_gui="$( grep -oP '^SETUP_GUI_DETECTED=\K.*' "${_env_file}" 2>/dev/null || true)"
  _stored_gpu="$( grep -oP '^GPU_ENABLED=\K.*'        "${_env_file}" 2>/dev/null || true)"
  _stored_uid="$( grep -oP '^USER_UID=\K.*'           "${_env_file}" 2>/dev/null || true)"

  local _now_hash="" _now_gui="" _now_gpu=""
  _compute_conf_hash "${_base}" _now_hash
  detect_gui _now_gui
  detect_gpu _now_gpu
  local _now_uid=""
  _now_uid="$(id -u)"

  local -a _drift=()
  [[ -n "${_stored_hash}" && "${_now_hash}" != "${_stored_hash}" ]] \
    && _drift+=("setup.conf modified since last setup")
  [[ -n "${_stored_gpu}"  && "${_now_gpu}"  != "${_stored_gpu}"  ]] \
    && _drift+=("GPU detection changed: ${_stored_gpu} → ${_now_gpu}")
  [[ -n "${_stored_gui}"  && "${_now_gui}"  != "${_stored_gui}"  ]] \
    && _drift+=("GUI detection changed: ${_stored_gui} → ${_now_gui}")
  [[ -n "${_stored_uid}"  && "${_now_uid}"  != "${_stored_uid}"  ]] \
    && _drift+=("USER_UID changed: ${_stored_uid} → ${_now_uid}")

  if (( ${#_drift[@]} > 0 )); then
    local _d
    printf "[setup] drift detected since last setup.sh run:\n" >&2
    for _d in "${_drift[@]}"; do
      printf "[setup]   - %s\n" "${_d}" >&2
    done
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_check_drift
#
# Subcommand handler for `setup.sh check-drift`. Parses --base-path /
# --lang flags then delegates to _check_setup_drift, which prints drift
# descriptions to stderr and returns 1 when the .env metadata no longer
# matches current system / setup.conf state.
#
# Build.sh / run.sh invoke this as a subprocess (instead of sourcing
# setup.sh) so internal helpers like _setup_msg can never shadow
# caller-side _msg keys (closes #101's class of bug).
#
# Usage: _setup_check_drift [--base-path <path>] [--lang <code>]
# ════════════════════════════════════════════════════════════════════
_setup_check_drift() {
  local _base_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"
  _check_setup_drift "${_base_path}"
}

# ════════════════════════════════════════════════════════════════════
# _announce_template_default_fallback <base_path>
#
# Surface a one-shot WARN when the per-repo setup.conf provides no
# overrides — either missing entirely or present but containing no
# [section] headers. Called from both `_setup_apply` and
# `_setup_check_drift` so build.sh / run.sh's drift-check rebuild path
# also surfaces the heads-up (closes #157, follow-up to #150 / #153).
# Emitted to stderr to keep stdout machine-parseable. #186 promoted
# the level from INFO to WARN so the notice doesn't scroll past
# unnoticed in normal build.sh / run.sh output.
# ════════════════════════════════════════════════════════════════════
_announce_template_default_fallback() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  # Existence check tracks the per-repo override file (setup.conf), the
  # source of truth post-#201.
  local _repo_conf="${_base}/setup.conf"
  if [[ ! -f "${_repo_conf}" ]]; then
    printf "[setup] WARN: %s\n" "$(_setup_msg warn_no_repo_conf)" >&2
  elif ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_repo_conf}"; then
    printf "[setup] WARN: %s\n" "$(_setup_msg warn_empty_repo_conf)" >&2
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_known_section <section>
#
# Returns 0 when <section> is one of the known setup.conf section
# names, 1 otherwise. Mirrors the section list documented in the
# project CLAUDE.md and `setup.conf` headers.
# ════════════════════════════════════════════════════════════════════
_setup_known_section() {
  local _s="${1-}"
  case "${_s}" in
    image|build|deploy|gui|network|security|resources|environment|tmpfs|devices|volumes|additional_contexts)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _setup_validate_kv <section> <key> <value>
#
# For typed keys with a matching validator in `_tui_conf.sh`, runs
# the validator and returns its exit code. Free-form keys (everything
# not in the typed list) accept any value (returns 0).
#
# Empty values are allowed (writes through `_upsert_conf_value` so the
# user can clear an opt-in key). The exception is keys whose validator
# rejects empty by design (gpu_count / mount_* / cgroup_rule_* /
# port_* / env_*); we delegate to the validator for those.
# ════════════════════════════════════════════════════════════════════
_setup_validate_kv() {
  local _section="${1-}"
  local _key="${2-}"
  local _value="${3-}"

  # Empty values: allowed (clear-key semantics) for free-form keys; for
  # typed keys, fall through to the validator which decides.
  case "${_section}.${_key}" in
    deploy.gpu_count)
      _validate_gpu_count "${_value}" ;;
    resources.shm_size)
      # Empty is meaningful (= "use compose default"); only validate
      # non-empty values.
      [[ -z "${_value}" ]] && return 0
      _validate_shm_size "${_value}" ;;
    *)
      case "${_section}" in
        volumes)
          if [[ "${_key}" == mount_* ]]; then
            # Empty mount_N is the documented opt-out; don't reject it.
            [[ -z "${_value}" ]] && return 0
            _validate_mount "${_value}"
          else
            return 0
          fi
          ;;
        devices)
          if [[ "${_key}" == cgroup_rule_* ]]; then
            [[ -z "${_value}" ]] && return 0
            _validate_cgroup_rule "${_value}"
          else
            return 0
          fi
          ;;
        environment)
          if [[ "${_key}" == env_* ]]; then
            [[ -z "${_value}" ]] && return 0
            _validate_env_kv "${_value}"
          else
            return 0
          fi
          ;;
        network)
          if [[ "${_key}" == port_* ]]; then
            [[ -z "${_value}" ]] && return 0
            _validate_port_mapping "${_value}"
          else
            return 0
          fi
          ;;
        additional_contexts)
          if [[ "${_key}" == context_* ]]; then
            [[ -z "${_value}" ]] && return 0
            _validate_additional_context "${_value}"
          else
            return 0
          fi
          ;;
        *)
          return 0 ;;
      esac
      ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _setup_set
#
# Subcommand handler for `setup.sh set <section>.<key> <value>`.
# Validates section + (where applicable) value, then upserts via
# `_upsert_conf_value` from `_tui_conf.sh` so behaviour matches the
# TUI's Save path. Does NOT regenerate .env — the user invokes
# `apply` explicitly when they want the derived artifacts refreshed.
#
# Usage: _setup_set <section>.<key> <value> [--base-path PATH]
#                                           [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_set() {
  local _base_path=""
  local _spec="" _value="" _have_value=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured the next bare arg is the value, even if
    # it starts with '-' (e.g. `set deploy.gpu_count -1` exercises an
    # invalid value path that the validator must reject — not a flag).
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage_set >&2
    return 1
  fi

  # Split <section>.<key>; the first '.' is the separator (keys
  # themselves never contain dots in setup.conf).
  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage_set >&2
    return 1
  fi
  local _section="${_spec%%.*}"
  local _key="${_spec#*.}"
  if [[ -z "${_section}" || -z "${_key}" ]]; then
    _setup_msg usage_set >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    printf "[setup] %s: %s\n" "$(_setup_msg unknown_section)" "${_section}" >&2
    return 2
  fi

  if ! _setup_validate_kv "${_section}" "${_key}" "${_value}"; then
    printf "[setup] %s: %s.%s = %s\n" \
      "$(_setup_msg invalid_value)" "${_section}" "${_key}" "${_value}" >&2
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  # Writes target the per-repo override file (setup.conf). Bootstrap
  # as empty when missing — `set` records only the user's intent, never
  # copies template defaults wholesale.
  local _conf="${_base_path}/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    : > "${_conf}"
  fi

  _upsert_conf_value "${_conf}" "${_section}" "${_key}" "${_value}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_show
#
# Subcommand handler for `setup.sh show <section>[.<key>]`. Reads
# <base-path>/setup.conf via `_load_setup_conf_full` so output stays
# aligned with the TUI's view of the file (preserves on-disk order,
# strips comments).
#
# Output:
#   show <section>.<key>  → single line with the value
#   show <section>        → "<key> = <value>" lines, on-disk order
# Returns 1 when the requested section or key is absent.
#
# Usage: _setup_show <section>[.<key>] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_show() {
  local _base_path=""
  local _spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -*)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" ]]; then
    _setup_msg usage_show >&2
    return 1
  fi

  local _section _key
  if [[ "${_spec}" == *.* ]]; then
    _section="${_spec%%.*}"
    _key="${_spec#*.}"
  else
    _section="${_spec}"
    _key=""
  fi

  if ! _setup_known_section "${_section}"; then
    printf "[setup] %s: %s\n" "$(_setup_msg unknown_section)" "${_section}" >&2
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  # show reads the merged view (template baseline ← repo override).
  # This is what `apply` would produce, so users see effective values
  # without having to re-run apply after every set/add/remove.
  local _repo_conf="${_base_path}/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
  local -a _ss_sections=() _ss_keys=() _ss_values=()
  _setup_load_merged_full "${_tpl_conf}" "${_repo_conf}" \
      _ss_sections _ss_keys _ss_values

  local _i _ns_key="${_section}.${_key}"
  if [[ -n "${_key}" ]]; then
    for (( _i=0; _i<${#_ss_keys[@]}; _i++ )); do
      if [[ "${_ss_keys[_i]}" == "${_ns_key}" ]]; then
        printf '%s\n' "${_ss_values[_i]}"
        return 0
      fi
    done
    printf "[setup] %s: %s\n" "$(_setup_msg key_not_found)" "${_ns_key}" >&2
    return 1
  fi

  # Whole-section dump.
  local _printed=0
  for (( _i=0; _i<${#_ss_keys[@]}; _i++ )); do
    if [[ "${_ss_keys[_i]}" == "${_section}."* ]]; then
      printf '%s = %s\n' "${_ss_keys[_i]#"${_section}".}" "${_ss_values[_i]}"
      _printed=1
    fi
  done
  if (( _printed == 0 )); then
    printf "[setup] %s: %s\n" "$(_setup_msg section_not_found)" "${_section}" >&2
    return 1
  fi
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_list
#
# Subcommand handler for `setup.sh list [<section>]`. Without an arg,
# prints the entire setup.conf (in on-disk order, comments stripped)
# as INI-style sections separated by blank lines — suitable for piping
# into other tooling. With a <section> arg, behaves like `show`.
#
# Usage: _setup_list [<section>] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_list() {
  local _base_path=""
  local _spec=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      -*)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -n "${_spec}" ]]; then
    # list <section> aliases show <section> for now (B-2 keeps them
    # equivalent; future iterations may differentiate keys-only vs
    # keys+values).
    if [[ -n "${_base_path}" ]]; then
      _setup_show "${_spec}" --base-path "${_base_path}" --lang "${_LANG}"
    else
      _setup_show "${_spec}" --lang "${_LANG}"
    fi
    return $?
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  # list reads the merged view (template ← repo override) — same
  # rationale as `show`. Reflects what `apply` would materialize.
  local _repo_conf="${_base_path}/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
  local -a _ll_sections=() _ll_keys=() _ll_values=()
  _setup_load_merged_full "${_tpl_conf}" "${_repo_conf}" \
      _ll_sections _ll_keys _ll_values

  local _si _ki _sect _first=1
  for _sect in "${_ll_sections[@]}"; do
    if (( _first )); then
      _first=0
    else
      printf '\n'
    fi
    printf '[%s]\n' "${_sect}"
    for (( _ki=0; _ki<${#_ll_keys[@]}; _ki++ )); do
      if [[ "${_ll_keys[_ki]}" == "${_sect}."* ]]; then
        printf '%s = %s\n' "${_ll_keys[_ki]#"${_sect}".}" "${_ll_values[_ki]}"
      fi
    done
  done
}

# ════════════════════════════════════════════════════════════════════
# _setup_add
#
# Subcommand handler for `setup.sh add <section>.<list> <value>`.
# Finds the next available numeric suffix N (max-existing + 1, or 1
# when the section has no entries with that prefix) and writes
# `<list>_N = <value>` via `_upsert_conf_value`. Bootstraps setup.conf
# from the template default if absent so first-time users can `add`
# before they ever ran `apply`. Validators fire through
# `_setup_validate_kv` against the synthesized key, so e.g.
# `add volumes.mount` enforces the same `_validate_mount` that
# `set volumes.mount_3` does. Does NOT regenerate .env.
#
# Numbering uses max+1 (never fills gaps left by remove). Predictable
# for tooling; matches the TUI's `_edit_list_section` "next slot"
# behaviour.
#
# Usage: _setup_add <section>.<list> <value>
#                   [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_add() {
  local _base_path=""
  local _spec="" _value="" _have_value=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured, the next bare arg is the value, even if
    # it begins with '-' (e.g. negative numbers shouldn't be parsed as
    # flags). Same shape as _setup_set.
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage_add >&2
    return 1
  fi

  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage_add >&2
    return 1
  fi
  local _section="${_spec%%.*}"
  local _list="${_spec#*.}"
  if [[ -z "${_section}" || -z "${_list}" ]]; then
    _setup_msg usage_add >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    printf "[setup] %s: %s\n" "$(_setup_msg unknown_section)" "${_section}" >&2
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi
  # Writes target the per-repo override (setup.conf); bootstrap as
  # empty when missing — `add` records only the user's intent.
  local _conf="${_base_path}/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    : > "${_conf}"
  fi

  # Scan keys[] for "<section>.<list>_<digits>". Pick the first slot
  # whose value is empty (reuses placeholder slots from the template
  # default, matches the TUI's `_edit_list_section` behaviour); fall
  # back to max+1 when every populated slot has content. Reads the
  # merged effective view (template ← repo override) so the new index
  # lands past any inherited template slot the user hasn't yet bumped.
  local -a _sects=() _keys=() _vals=()
  local -a _local_k=() _local_v=()
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
  _parse_ini_section "${_conf}" "${_section}" _local_k _local_v
  if (( ${#_local_k[@]} > 0 )); then
    # Override section present — replace strategy: only .local entries
    # exist for this section.
    local _li
    for (( _li=0; _li<${#_local_k[@]}; _li++ )); do
      _keys+=("${_section}.${_local_k[_li]}")
      _vals+=("${_local_v[_li]}")
    done
  elif [[ -f "${_tpl_conf}" ]]; then
    # Fall back to template baseline so max-suffix matches what the
    # merged view would produce.
    local -a _tpl_k=() _tpl_v=()
    _parse_ini_section "${_tpl_conf}" "${_section}" _tpl_k _tpl_v
    local _ti
    for (( _ti=0; _ti<${#_tpl_k[@]}; _ti++ )); do
      _keys+=("${_section}.${_tpl_k[_ti]}")
      _vals+=("${_tpl_v[_ti]}")
    done
  fi
  local _max=0 _empty_idx="" _i _k _suffix
  for (( _i=0; _i<${#_keys[@]}; _i++ )); do
    _k="${_keys[_i]}"
    if [[ "${_k}" == "${_section}.${_list}_"* ]]; then
      _suffix="${_k##*_}"
      if [[ "${_suffix}" =~ ^[0-9]+$ ]]; then
        if (( _suffix > _max )); then
          _max="${_suffix}"
        fi
        if [[ -z "${_empty_idx}" && -z "${_vals[_i]}" ]]; then
          _empty_idx="${_suffix}"
        fi
      fi
    fi
  done
  local _new_idx
  if [[ -n "${_empty_idx}" ]]; then
    _new_idx="${_empty_idx}"
  else
    _new_idx=$(( _max + 1 ))
  fi
  local _new_key="${_list}_${_new_idx}"

  if ! _setup_validate_kv "${_section}" "${_new_key}" "${_value}"; then
    printf "[setup] %s: %s.%s = %s\n" \
      "$(_setup_msg invalid_value)" "${_section}" "${_new_key}" "${_value}" >&2
    return 2
  fi

  _upsert_conf_value "${_conf}" "${_section}" "${_new_key}" "${_value}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_remove
#
# Two argument forms:
#   1) remove <section>.<key>           — delete that exact key
#   2) remove <section>.<list> <value>  — delete the FIRST key under
#      <section> matching `<list>_*` whose value equals <value>
#
# Form is selected by argc: a second positional arg switches to
# remove-by-value mode. Removes one entry per invocation; multiple
# matches keep the rest (call again to peel further). Preserves
# comments + ordering via `_write_setup_conf`. Does NOT regenerate
# .env. Does NOT renumber remaining keys (`_load_setup_conf_full`
# tolerates gaps, and downstream callers treat the prefix list as
# unordered).
#
# Usage: _setup_remove <section>.<key>            [--base-path] [--lang]
#        _setup_remove <section>.<list> <value>   [--base-path] [--lang]
# ════════════════════════════════════════════════════════════════════
_setup_remove() {
  local _base_path=""
  local _spec="" _value="" _have_value=0

  while [[ $# -gt 0 ]]; do
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-h|--help)
          ;;
        *)
          _value="$1"; _have_value=1; shift
          continue
          ;;
      esac
    fi
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      --)
        shift
        if [[ $# -gt 0 && -z "${_spec}" ]]; then
          _spec="$1"; shift
        fi
        if [[ $# -gt 0 && "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1; shift
        fi
        ;;
      -*)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_spec}" != *.* ]]; then
    _setup_msg usage_remove >&2
    return 1
  fi
  local _section="${_spec%%.*}"
  local _rest="${_spec#*.}"
  if [[ -z "${_section}" || -z "${_rest}" ]]; then
    _setup_msg usage_remove >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    printf "[setup] %s: %s\n" "$(_setup_msg unknown_section)" "${_section}" >&2
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi
  # remove only operates on the per-repo override. If setup.conf
  # doesn't exist, there's nothing to remove (template baseline isn't
  # a removable input).
  local _conf="${_base_path}/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    printf "[setup] %s: %s\n" "$(_setup_msg key_not_found)" "${_spec}" >&2
    return 1
  fi

  local -a _sects=() _keys=() _vals=()
  _load_setup_conf_full "${_conf}" _sects _keys _vals

  local _target_key="" _i
  if (( _have_value )); then
    # Remove-by-value: scan for first <section>.<rest>_* with matching value.
    for (( _i=0; _i<${#_keys[@]}; _i++ )); do
      if [[ "${_keys[_i]}" == "${_section}.${_rest}_"* ]] \
         && [[ "${_vals[_i]}" == "${_value}" ]]; then
        _target_key="${_keys[_i]#"${_section}".}"
        break
      fi
    done
    if [[ -z "${_target_key}" ]]; then
      printf "[setup] %s: %s.%s = %s\n" \
        "$(_setup_msg key_not_found)" "${_section}" "${_rest}" "${_value}" >&2
      return 1
    fi
  else
    # Remove-by-key: assert <section>.<rest> exists.
    local _found=0
    for (( _i=0; _i<${#_keys[@]}; _i++ )); do
      if [[ "${_keys[_i]}" == "${_section}.${_rest}" ]]; then
        _found=1
        break
      fi
    done
    if (( ! _found )); then
      printf "[setup] %s: %s\n" "$(_setup_msg key_not_found)" "${_spec}" >&2
      return 1
    fi
    _target_key="${_rest}"
  fi

  # _write_setup_conf truncates dst before reading tpl, so when dst==src
  # we'd lose data. Stage current contents into a sibling temp file and
  # use that as the read source.
  local _tmp
  _tmp="$(mktemp "${_conf}.XXXXXX")"
  cp "${_conf}" "${_tmp}"
  local -a _empty_s=() _empty_k=() _empty_v=()
  _write_setup_conf "${_conf}" "${_tmp}" \
    _empty_s _empty_k _empty_v "${_section}.${_target_key}"
  rm -f "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_reset
#
# Subcommand handler for `setup.sh reset [--yes]`. Overwrites the
# repo's setup.conf with the template default, archiving the prior
# setup.conf to setup.conf.bak and the prior .env to .env.bak so the
# user has a one-shot rollback path. Mirrors what `build.sh
# --reset-conf` does today, but exposes it as a setup.sh subcommand
# for scripted use.
#
# Does NOT regenerate .env. The user invokes `apply` afterwards (or
# build/run will trigger auto-regen via drift detection on the next
# invocation, since the conf hash will have changed).
#
# Without --yes, refuses to proceed when stdin is not a TTY (safety
# guard so accidental pipeline invocations don't destroy state).
# With --yes, skips the confirmation regardless of TTY.
#
# Usage: _setup_reset [--yes] [--base-path PATH] [--lang LANG]
# ════════════════════════════════════════════════════════════════════
_setup_reset() {
  local _base_path=""
  local _yes=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -y|--yes)
        _yes=1
        shift
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  # reset clears the per-repo override (setup.conf) so the next `apply`
  # rebuilds .env + compose.yaml purely from the template baseline. The
  # workspace mount_1 is re-detected and re-written via the bootstrap
  # path on the next apply.
  local _conf="${_base_path}/setup.conf"
  local _env="${_base_path}/.env"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
  if [[ ! -f "${_tpl_conf}" ]]; then
    printf "[setup] template setup.conf not found at %s\n" "${_tpl_conf}" >&2
    return 1
  fi

  if (( ! _yes )); then
    if [[ ! -t 0 ]]; then
      printf "[setup] %s\n" "$(_setup_msg reset_needs_yes)" >&2
      return 1
    fi
    printf "[setup] %s [y/N]: " "$(_setup_msg reset_confirm)"
    local _ans=""
    read -r _ans
    case "${_ans}" in
      y|Y|yes|YES) ;;
      *)
        printf "[setup] %s\n" "$(_setup_msg reset_aborted)" >&2
        return 1
        ;;
    esac
  fi

  # Backup the existing per-repo override and the .env snapshot.
  if [[ -f "${_conf}" ]]; then
    cp -f "${_conf}" "${_conf}.bak"
    rm -f "${_conf}"
  fi
  if [[ -f "${_env}" ]]; then
    cp -f "${_env}" "${_env}.bak"
  fi

  printf "[setup] %s\n" "$(_setup_msg reset_done)"
}

# ════════════════════════════════════════════════════════════════════
# _setup_apply
#
# Subcommand handler for `setup.sh apply`. Regenerates .env +
# compose.yaml from setup.conf + system detection. Other subcommands
# (set/add/remove/reset) intentionally do NOT regen — apply is the
# explicit gate.
#
# Usage: _setup_apply [-h|--help] [--base-path <path>] [--lang <code>]
# ════════════════════════════════════════════════════════════════════
_setup_apply() {
  local _base_path=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --base-path)
        _base_path="${2:?"--base-path requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "setup"
        shift 2
        ;;
      *)
        printf "[setup] %s: %s\n" "$(_setup_msg unknown_arg)" "$1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"

  local _env_file="${_base_path}/.env"

  if [[ -f "${_env_file}" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "${_env_file}"
    set +o allexport
  fi

  # ── Detections ──
  local user_name="" user_group="" user_uid="" user_gid=""
  local hardware="" docker_hub_user="" gpu_detected="" gui_detected="" image_name=""
  local ws_path="${WS_PATH:-}"

  detect_user_info       user_name user_group user_uid user_gid
  detect_hardware        hardware
  detect_docker_hub_user docker_hub_user
  detect_gpu             gpu_detected
  detect_gui             gui_detected
  BASE_PATH="${_base_path}" detect_image_name image_name "${_base_path}"

  # ── Load setup.conf sections ──
  local -a _dep_k=() _dep_v=() _gui_k=() _gui_v=() _net_k=() _net_v=() _vol_k=() _vol_v=()
  local -a _build_k=() _build_v=()
  local -a _dev_k=() _dev_v=()
  local -a _res_k=() _res_v=()
  local -a _env_k=() _env_v=()
  local -a _tmp_k=() _tmp_v=()
  local -a _sec_k=() _sec_v=()
  local -a _ac_k=() _ac_v=()
  _load_setup_conf "${_base_path}" "build"               _build_k _build_v
  _load_setup_conf "${_base_path}" "deploy"              _dep_k _dep_v
  _load_setup_conf "${_base_path}" "gui"                 _gui_k _gui_v
  _load_setup_conf "${_base_path}" "network"             _net_k _net_v
  _load_setup_conf "${_base_path}" "volumes"             _vol_k _vol_v
  _load_setup_conf "${_base_path}" "devices"             _dev_k _dev_v
  _load_setup_conf "${_base_path}" "resources"           _res_k _res_v
  _load_setup_conf "${_base_path}" "environment"         _env_k _env_v
  _load_setup_conf "${_base_path}" "tmpfs"               _tmp_k _tmp_v
  _load_setup_conf "${_base_path}" "security"            _sec_k _sec_v
  _load_setup_conf "${_base_path}" "additional_contexts" _ac_k   _ac_v

  # Build args: each `[build] arg_N = KEY=VALUE` entry becomes a
  # compose build.arg. Empty VALUE means "do not override" — let
  # compose.yaml's `${VAR:-<default>}` fallback pick the Dockerfile
  # default (archive.ubuntu.com for APT, Asia/Taipei for TZ, etc.).
  local -a _build_args=()
  _get_conf_list_sorted _build_k _build_v "arg_" _build_args

  # Back-compat: repos that still have the old named-key schema
  # (apt_mirror_ubuntu = …, tz = …) keep working without having to
  # rewrite setup.conf. We lift those named keys into the arg_N list
  # at runtime; the TUI saves in the new format the next time the
  # user hits Save.
  if (( ${#_build_args[@]} == 0 )); then
    local _bc_v=""
    _get_conf_value _build_k _build_v "apt_mirror_ubuntu" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_UBUNTU=${_bc_v}")
    _bc_v=""
    _get_conf_value _build_k _build_v "apt_mirror_debian" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("APT_MIRROR_DEBIAN=${_bc_v}")
    _bc_v=""
    _get_conf_value _build_k _build_v "tz" "" _bc_v
    [[ -n "${_bc_v}" ]] && _build_args+=("TZ=${_bc_v}")
  fi

  # Extract specific known values that write_env + the hardcoded
  # compose.yaml build.args block reference by name. Anything not in
  # the known set is emitted as a generic user-added arg.
  local apt_mirror_ubuntu="" apt_mirror_debian="" tz=""
  local -a _user_build_args=()
  local _arg _k _v
  for _arg in "${_build_args[@]}"; do
    [[ "${_arg}" != *=* ]] && continue
    _k="${_arg%%=*}"
    _v="${_arg#*=}"
    case "${_k}" in
      APT_MIRROR_UBUNTU) apt_mirror_ubuntu="${_v}" ;;
      APT_MIRROR_DEBIAN) apt_mirror_debian="${_v}" ;;
      TZ)                tz="${_v}" ;;
      *)                 _user_build_args+=("${_k}=${_v}") ;;
    esac
  done

  # TARGETARCH override: scalar `[build] target_arch` sits alongside
  # the arg_N list. Empty = let BuildKit auto-fill from host /
  # --platform (no --build-arg passed, no compose build.arg emitted).
  # Non-empty = pin the value for cross-build or explicit control.
  local target_arch=""
  _get_conf_value _build_k _build_v "target_arch" "" target_arch

  # Build-time network override: scalar `[build] network`. Empty =
  # docker default (bridge). Non-empty = passed as `build.network` in
  # compose.yaml and `--network <value>` to the auxiliary test-tools
  # docker build. Typical value: `host`, for hosts whose docker bridge
  # NAT is unusable (stripped embedded kernels, iptables:false).
  local build_network_mode=""
  _get_conf_value _build_k _build_v "network" "auto" build_network_mode
  local build_network=""
  _resolve_build_network "${build_network_mode}" build_network

  local gpu_mode="" gpu_count="" gpu_caps="" runtime_mode=""
  local gui_mode=""
  local net_mode="" ipc_mode="" privileged="" network_name=""
  _get_conf_value _dep_k _dep_v "gpu_mode"         "auto" gpu_mode
  _get_conf_value _dep_k _dep_v "gpu_count"        "all"  gpu_count
  _get_conf_value _dep_k _dep_v "gpu_capabilities" "gpu"  gpu_caps
  _get_conf_value _dep_k _dep_v "runtime"          "auto" runtime_mode
  _get_conf_value _gui_k _gui_v "mode"             "auto" gui_mode
  _get_conf_value _net_k _net_v "mode"             "host" net_mode
  _get_conf_value _net_k _net_v "ipc"              "host" ipc_mode
  _get_conf_value _net_k _net_v "network_name"     ""     network_name
  _get_conf_value _sec_k _sec_v "privileged"       "true" privileged

  # ── WS_PATH + workspace mount ──
  #
  # mount_1 can be:
  #   - `${WS_PATH}:/home/${USER_NAME}/work` — portable form (default
  #     since v0.9.4). docker-compose resolves ${WS_PATH} from .env on
  #     each machine. setup.sh re-runs detect_ws_path locally.
  #   - absolute host path — user pinned a specific directory. Honored
  #     as long as the path exists on this machine.
  #   - stale absolute path (baked from another machine, path absent
  #     locally) — warn, auto-migrate mount_1 back to the portable
  #     ${WS_PATH} form, and re-detect locally.
  #   - empty — user opted out; skip the mount but still detect WS_PATH
  #     so .env remains populated.
  #
  # First-time bootstrap (no <repo>/setup.conf) copies the template and
  # writes mount_1 in the portable form.
  local _repo_conf="${_base_path}/setup.conf"
  local _mount_1=""
  _get_conf_value _vol_k _vol_v "mount_1" "" _mount_1

  # SC2016: literal ${WS_PATH} / ${USER_NAME} are intentional — this
  # string is written into setup.conf and expanded by docker-compose
  # (via .env) at container start time, not by shell here.
  # shellcheck disable=SC2016
  local _ws_portable_form='${WS_PATH}:/home/${USER_NAME}/work'

  if [[ ! -f "${_repo_conf}" ]]; then
    # First-time bootstrap: create per-repo setup.conf from template.
    # Write mount_1 as the portable ${WS_PATH} form so the committed
    # file stays machine-agnostic; .env carries the detected absolute
    # path for docker-compose to expand.
    if [[ -z "${ws_path}" ]] || [[ ! -d "${ws_path}" ]]; then
      detect_ws_path ws_path "${_base_path}"
    fi
    [[ -d "${ws_path}" ]] && ws_path="$(cd "${ws_path}" && pwd -P)"
    local _tpl_conf
    _tpl_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
    if [[ -f "${_tpl_conf}" ]]; then
      cp "${_tpl_conf}" "${_repo_conf}"
      _upsert_conf_value "${_repo_conf}" "volumes" "mount_1" \
        "${_ws_portable_form}"
      # Reload [volumes] so extra_volumes picks up the new mount_1.
      _vol_k=(); _vol_v=()
      _load_setup_conf "${_base_path}" "volumes" _vol_k _vol_v
      _get_conf_value _vol_k _vol_v "mount_1" "" _mount_1
    fi
  elif [[ -n "${_mount_1}" ]]; then
    local _mount_1_host=""
    _mount_host_path "${_mount_1}" _mount_1_host
    # SC2016: literal ${WS_PATH} / $WS_PATH substrings are intentional
    # — we are matching the variable reference stored in setup.conf,
    # not expanding it.
    # shellcheck disable=SC2016
    if [[ "${_mount_1_host}" == *'${WS_PATH}'* ]] \
        || [[ "${_mount_1_host}" == *'$WS_PATH'* ]]; then
      # Portable form — detect ws_path locally; mount_1 stays untouched.
      ws_path=""
      detect_ws_path ws_path "${_base_path}"
      [[ -d "${ws_path}" ]] && ws_path="$(cd "${ws_path}" && pwd -P)"
    elif [[ -d "${_mount_1_host}" ]]; then
      # User pinned an absolute path that exists locally — honor it.
      ws_path="${_mount_1_host}"
    else
      # Absolute path that doesn't exist on this machine — almost always
      # a stale bake from another contributor's clone. Warn loudly so
      # the user understands the rewrite, then migrate mount_1 back to
      # the portable form.
      printf "[setup] WARNING: [volumes] mount_1 host path '%s' does not exist on this machine.\n" \
        "${_mount_1_host}" >&2
      printf "[setup]          This is usually a stale absolute path committed from\n" >&2
      printf "[setup]          a different machine. Rewriting mount_1 to the portable\n" >&2
      printf "[setup]          '\${WS_PATH}:/home/\${USER_NAME}/work' form and re-detecting\n" >&2
      printf "[setup]          WS_PATH locally. Commit the updated setup.conf to share.\n" >&2
      ws_path=""
      detect_ws_path ws_path "${_base_path}"
      [[ -d "${ws_path}" ]] && ws_path="$(cd "${ws_path}" && pwd -P)"
      _upsert_conf_value "${_repo_conf}" "volumes" "mount_1" \
        "${_ws_portable_form}"
      _vol_k=(); _vol_v=()
      _load_setup_conf "${_base_path}" "volumes" _vol_k _vol_v
      _get_conf_value _vol_k _vol_v "mount_1" "" _mount_1
    fi
  else
    # setup.conf exists but user cleared mount_1: best-effort detection
    # for WS_PATH only; do not touch setup.conf.
    if [[ -z "${ws_path}" ]] || [[ ! -d "${ws_path}" ]]; then
      detect_ws_path ws_path "${_base_path}"
    fi
    [[ -d "${ws_path}" ]] && ws_path="$(cd "${ws_path}" && pwd -P)"
  fi

  # shellcheck disable=SC2034  # populated via nameref by _get_conf_list_sorted
  local -a extra_volumes=()
  _get_conf_list_sorted _vol_k _vol_v "mount_" extra_volumes

  # ── Collect [devices] entries (device_*) ──
  local -a _devices_arr=()
  _get_conf_list_sorted _dev_k _dev_v "device_" _devices_arr
  local _devices_str=""
  if (( ${#_devices_arr[@]} > 0 )); then
    _devices_str="$(printf '%s\n' "${_devices_arr[@]}")"
  fi

  # ── Collect [devices] cgroup_rule_* ──
  local -a _cgroup_rule_arr=()
  _get_conf_list_sorted _dev_k _dev_v "cgroup_rule_" _cgroup_rule_arr
  local _cgroup_rule_str=""
  if (( ${#_cgroup_rule_arr[@]} > 0 )); then
    _cgroup_rule_str="$(printf '%s\n' "${_cgroup_rule_arr[@]}")"
  fi

  # ── Collect [environment] env_*, [tmpfs] tmpfs_*, [network] port_* ──
  local -a _env_arr=() _tmpfs_arr=() _ports_arr=()
  _get_conf_list_sorted _env_k _env_v "env_"    _env_arr
  _get_conf_list_sorted _tmp_k _tmp_v "tmpfs_"  _tmpfs_arr
  _get_conf_list_sorted _net_k _net_v "port_"   _ports_arr
  local _env_str="" _tmpfs_str="" _ports_str=""
  (( ${#_env_arr[@]}    > 0 )) && _env_str="$(printf '%s\n'    "${_env_arr[@]}")"
  (( ${#_tmpfs_arr[@]}  > 0 )) && _tmpfs_str="$(printf '%s\n'  "${_tmpfs_arr[@]}")"
  (( ${#_ports_arr[@]}  > 0 )) && _ports_str="$(printf '%s\n'  "${_ports_arr[@]}")"

  # ── Collect [security] cap_add_*, cap_drop_*, security_opt_* ──
  local -a _cap_add_arr=() _cap_drop_arr=() _sec_opt_arr=()
  _get_conf_list_sorted _sec_k _sec_v "cap_add_"      _cap_add_arr
  _get_conf_list_sorted _sec_k _sec_v "cap_drop_"     _cap_drop_arr
  _get_conf_list_sorted _sec_k _sec_v "security_opt_" _sec_opt_arr

  # Security fallback: if the per-repo [security] section wiped a list
  # (no cap_add_* entries at all, likewise for cap_drop_* / security_opt_*),
  # fall back to the template's baseline rather than Docker's stripped-
  # down default — avoids surprising the user with "my container lost
  # SYS_ADMIN / unconfined seccomp after I cleared the list".
  local _tpl_setup_conf
  _tpl_setup_conf="${_SETUP_SCRIPT_DIR}/../../setup.conf"
  local -a _tpl_sec_k=() _tpl_sec_v=()
  [[ -f "${_tpl_setup_conf}" ]] \
    && _parse_ini_section "${_tpl_setup_conf}" "security" _tpl_sec_k _tpl_sec_v
  (( ${#_cap_add_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_add_"      _cap_add_arr
  (( ${#_cap_drop_arr[@]} == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_drop_"     _cap_drop_arr
  (( ${#_sec_opt_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "security_opt_" _sec_opt_arr

  local _cap_add_str="" _cap_drop_str="" _sec_opt_str=""
  (( ${#_cap_add_arr[@]}  > 0 )) && _cap_add_str="$(printf '%s\n'  "${_cap_add_arr[@]}")"
  (( ${#_cap_drop_arr[@]} > 0 )) && _cap_drop_str="$(printf '%s\n' "${_cap_drop_arr[@]}")"
  (( ${#_sec_opt_arr[@]}  > 0 )) && _sec_opt_str="$(printf '%s\n'  "${_sec_opt_arr[@]}")"

  # ── Collect [additional_contexts] context_* ──
  # Each entry is `NAME=PATH`. Validation (NAME shape, PATH non-empty)
  # lives in `_validate_additional_context`; setup.sh trusts the parsed
  # values here and emits them verbatim into compose.yaml. Empty list
  # means no `additional_contexts:` block is emitted.
  local -a _ac_arr=()
  _get_conf_list_sorted _ac_k _ac_v "context_" _ac_arr
  local _additional_contexts_str=""
  (( ${#_ac_arr[@]} > 0 )) && _additional_contexts_str="$(printf '%s\n' "${_ac_arr[@]}")"

  # ── [resources] shm_size (only meaningful when ipc != host) ──
  local _shm_size=""
  _get_conf_value _res_k _res_v "shm_size" "" _shm_size

  # ── Resolve final enabled states ──
  local gpu_enabled_eff="" gui_enabled_eff=""
  _resolve_gpu "${gpu_mode}" "${gpu_detected}" gpu_enabled_eff
  _resolve_gui "${gui_mode}" "${gui_detected}" gui_enabled_eff

  # ── Compute hash for drift detection ──
  local conf_hash=""
  _compute_conf_hash "${_base_path}" conf_hash

  # Join user-added build args (newline-separated) for write_env.
  local _user_build_args_str=""
  if (( ${#_user_build_args[@]} > 0 )); then
    _user_build_args_str="$(printf '%s\n' "${_user_build_args[@]}")"
  fi

  # ── Generate artifacts ──
  write_env "${_env_file}" \
    "${user_name}" "${user_group}" "${user_uid}" "${user_gid}" \
    "${hardware}" "${docker_hub_user}" "${gpu_detected}" \
    "${image_name}" "${ws_path}" \
    "${apt_mirror_ubuntu}" "${apt_mirror_debian}" "${tz}" \
    "${net_mode}" "${ipc_mode}" "${privileged}" \
    "${gpu_count}" "${gpu_caps}" \
    "${gui_detected}" "${conf_hash}" \
    "${network_name}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}"

  local runtime_resolved=""
  _resolve_runtime "${runtime_mode}" runtime_resolved

  generate_compose_yaml "${_base_path}/compose.yaml" "${image_name}" \
    "${gui_enabled_eff}" "${gpu_enabled_eff}" \
    "${gpu_count}" "${gpu_caps}" \
    extra_volumes "${network_name}" \
    "${_devices_str}" \
    "${_env_str}" "${_tmpfs_str}" "${_ports_str}" \
    "${_shm_size}" "${net_mode}" "${ipc_mode}" \
    "${_cap_add_str}" "${_cap_drop_str}" "${_sec_opt_str}" \
    "${_cgroup_rule_str}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}" \
    "${runtime_resolved}" \
    "${_additional_contexts_str}"

  printf "[setup] %s\n" "$(_setup_msg env_done)"
  printf "[setup] USER=%s (%s:%s)  GPU=%s/%s  GUI=%s/%s  IMAGE=%s  WS=%s\n" \
    "${user_name}" "${user_uid}" "${user_gid}" \
    "${gpu_enabled_eff}" "${gpu_mode}" \
    "${gui_enabled_eff}" "${gui_mode}" \
    "${image_name}" "${ws_path}"
}

# ════════════════════════════════════════════════════════════════════
# main
#
# Top-level entry. Routes to subcommand handlers; preserves the legacy
# flag-only invocation (`setup.sh --base-path X --lang Y`) by falling
# top-level subcommand dispatch.
#
# B-4 BREAKING: no-arg / flag-only invocations no longer alias to
# `apply`. Either pass `-h`/`--help` (or no args, which now prints
# the same help) or use an explicit subcommand.
#
# Usage: main <subcommand> [args...]
#   subcommands: apply | check-drift | set | show | list | add | remove | reset
# ════════════════════════════════════════════════════════════════════
main() {
  local _subcmd=""
  # B-4 BREAKING: no-arg → help (was: silently aliased to apply).
  # Bare flag invocations (`setup.sh --base-path X --lang Y`, no
  # subcommand) also error now — the legacy fall-through is gone, so
  # accidental invocations don't clobber .env / compose.yaml without
  # an explicit subcommand. Downstream callers (build.sh / run.sh) all
  # pass `apply` explicitly as of this commit.
  if [[ $# -eq 0 ]]; then
    usage
  fi
  case "$1" in
    -h|--help)
      usage
      ;;
    apply|check-drift|set|show|list|add|remove|reset)
      _subcmd="$1"
      shift
      ;;
    *)
      printf "[setup] %s: %s\n" "$(_setup_msg unknown_subcmd)" "$1" >&2
      return 1
      ;;
  esac

  case "${_subcmd}" in
    apply)        _setup_apply       "$@" ;;
    check-drift)  _setup_check_drift "$@" ;;
    set)          _setup_set         "$@" ;;
    show)         _setup_show        "$@" ;;
    list)         _setup_list        "$@" ;;
    add)          _setup_add         "$@" ;;
    remove)       _setup_remove      "$@" ;;
    reset)        _setup_reset       "$@" ;;
  esac
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
