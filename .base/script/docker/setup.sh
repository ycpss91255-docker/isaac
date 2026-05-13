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
        stage_invalid_format) echo "Dockerfile stage 名稱格式無效，已跳過該 stage" ;;
        stage_baseline_collision) echo "Dockerfile stage 名稱與 template 內建 stage 衝突，請改名" ;;
        stage_reserved_tag) echo "Dockerfile stage 名稱使用 template 控制的 image tag namespace，請改名" ;;
        stage_unknown_referenced) echo "setup.conf 內 [stage:...] 對應的 stage 在 Dockerfile 中不存在，已忽略該區段" ;;
        stage_override_key_not_allowed) echo "[stage:...] 區段內含不在 per-stage 允許清單內的 key，已忽略該 key" ;;
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
        stage_invalid_format) echo "Dockerfile stage 名称格式无效，已跳过该 stage" ;;
        stage_baseline_collision) echo "Dockerfile stage 名称与 template 内建 stage 冲突，请改名" ;;
        stage_reserved_tag) echo "Dockerfile stage 名称使用 template 控制的 image tag namespace，请改名" ;;
        stage_unknown_referenced) echo "setup.conf 内 [stage:...] 对应的 stage 在 Dockerfile 中不存在，已忽略该区段" ;;
        stage_override_key_not_allowed) echo "[stage:...] 区段内含不在 per-stage 允许清单内的 key，已忽略该 key" ;;
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
        stage_invalid_format) echo "Dockerfile stage 名のフォーマットが無効です。該当 stage はスキップされます" ;;
        stage_baseline_collision) echo "Dockerfile stage 名が template 管理の stage と衝突しています。改名してください" ;;
        stage_reserved_tag) echo "Dockerfile stage 名が template が管理する image tag namespace を使用しています。改名してください" ;;
        stage_unknown_referenced) echo "setup.conf 内の [stage:...] が指す stage が Dockerfile に存在しません。該当セクションは無視されます" ;;
        stage_override_key_not_allowed) echo "[stage:...] セクション内に per-stage 許可リスト外の key が含まれています。該当 key は無視されます" ;;
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
        stage_invalid_format) echo "invalid Dockerfile stage name format; stage skipped" ;;
        stage_baseline_collision) echo "Dockerfile stage name collides with a template-managed baseline stage; rename it" ;;
        stage_reserved_tag) echo "Dockerfile stage name uses a template-controlled image tag namespace; rename it" ;;
        stage_unknown_referenced) echo "setup.conf [stage:...] references a stage missing from the Dockerfile; section ignored" ;;
        stage_override_key_not_allowed) echo "[stage:...] section contains a key outside the per-stage allowlist; key ignored" ;;
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
                Write a single value into <base-path>/config/docker/setup.conf
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
  local _template_conf="${_self_dir}/../../config/docker/setup.conf"
  local _repo_conf="${_base}/config/docker/setup.conf"

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
  local _template_conf="${_self_dir}/../../config/docker/setup.conf"
  local _repo_conf="${_base}/config/docker/setup.conf"

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
# Stage helpers (#215)
# ════════════════════════════════════════════════════════════════════

# _validate_stage_name <stage>
#
# Returns:
#   0 — valid; auto-emit as compose service
#   1 — invalid format (caller WARNs + skips, continues parsing other stages)
#   2 — collides with template-managed baseline
#       {sys, devel-base, devel, devel-test, runtime-test}; hard error
#       (caller exits non-zero). For backward compatibility during the
#       v0.21.x transition the legacy names {base, test} are also
#       accepted as baseline (downstream Dockerfiles renamed to
#       devel-base / devel-test over a coordinated rollout); they will
#       be removed from the blocklist in a future major release.
#   3 — collides with template-controlled image-tag namespace
#       ({latest} | v[0-9]*); hard error
#
# Exit codes are distinct so the parser/emitter can react differently
# (skip-with-warn vs abort) without re-validating.
_validate_stage_name() {
  local _stage="$1"
  # Order matters: collision / reserved checks fire BEFORE format check
  # so a name that matches both a reserved pattern AND has a format
  # quirk (e.g. `v1.2` — dotted, but still in v[0-9]* reserved
  # namespace) gets the more severe verdict (hard error 3) instead of
  # the milder format-only verdict (skip 1). Same name should not
  # silently drop as "invalid format" if its real problem is namespace
  # collision.

  # 1. baseline collision (template-managed stages)
  #    Forward-looking: sys / devel-base / devel / devel-test / runtime-test
  #    Legacy (backward-compat during v0.21.x transition): base / test
  case "${_stage}" in
    sys|devel-base|devel|devel-test|runtime-test) return 2 ;;
    base|test) return 2 ;;
  esac
  # 2. reserved tag namespace (template-controlled tag slots)
  case "${_stage}" in
    latest)   return 3 ;;
    v[0-9]*)  return 3 ;;
  esac
  # 3. format check (lowercase, leading letter, [a-z0-9_-])
  [[ "${_stage}" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  return 0
}

# _parse_dockerfile_stages <dockerfile_path>
#
# Reads `^FROM <base> AS <stage>` lines from the Dockerfile, dedups,
# filters out the baseline blocklist {sys, devel-base, devel,
# devel-test, runtime-test} (plus the legacy {base, test} accepted
# during the v0.21.x transition), and echoes the surviving stages
# one per line preserving file order.
#
# Match rules:
#   - Line must start with `FROM` (case-sensitive — Docker spec is
#     case-insensitive but tooling convention is uppercase)
#   - `AS` keyword must be uppercase (lowercase `as` is technically valid
#     but treated as user typo / hand-edited and ignored)
#   - Comments (#) on the line block the match — only bare directives count
#   - Trailing whitespace tolerated
#
# Missing Dockerfile → empty output (silent), exit 0. Caller decides
# whether to treat that as "no extra stages" or an error.
_parse_dockerfile_stages() {
  local _dockerfile="$1"
  [[ -f "${_dockerfile}" ]] || return 0
  # Read the Dockerfile directly (no grep|awk pipe) so an empty match
  # set under `set -o pipefail` does not propagate exit 1 back through
  # process substitution. BASH_REMATCH captures the stage name from
  # the same regex shape grep used.
  local _line _stage _seen=" "
  while IFS= read -r _line; do
    [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+([^[:space:]#]+)[[:space:]]*$ ]] || continue
    _stage="${BASH_REMATCH[1]}"
    case "${_stage}" in
      sys|devel-base|devel|devel-test|runtime-test) continue ;;
      base|test) continue ;;
    esac
    case "${_seen}" in
      *" ${_stage} "*) continue ;;  # already emitted (dedup)
    esac
    _seen+="${_stage} "
    printf '%s\n' "${_stage}"
  done < "${_dockerfile}"
  return 0
}

# _compute_dockerfile_hash <base_path> <outvar>
#
# sha256 of the Dockerfile's stage-list projection (just `FROM ... AS
# <stage>` lines), NOT the whole Dockerfile. Drift detection scope:
# adding/removing a stage changes which compose services exist, so the
# hash must change on those edits — but unrelated `RUN apt-get install`
# changes must not, otherwise every Dockerfile edit triggers a full
# compose regen.
#
# Empty output if Dockerfile is missing (caller decides what to do).
_compute_dockerfile_hash() {
  local _base="${1:?}"
  local -n _cdh_out="${2:?}"
  local _dockerfile="${_base}/Dockerfile"
  if [[ ! -f "${_dockerfile}" ]]; then
    _cdh_out=""
    return 0
  fi
  # Build the stage-list projection inline (no grep|sha256sum pipe) so
  # an empty match set under pipefail does not propagate failure. The
  # regex matches grep's exact shape used by _parse_dockerfile_stages.
  local _line _stage_lines=""
  while IFS= read -r _line; do
    [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+[^[:space:]#]+[[:space:]]*$ ]] || continue
    _stage_lines+="${_line}"$'\n'
  done < "${_dockerfile}"
  _cdh_out="$(printf '%s' "${_stage_lines}" | sha256sum | cut -d' ' -f1)"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# Per-stage overrides (#220)
#
# `[stage:<name>]` sections in <repo>/setup.conf override top-level
# settings on a per-stage basis. Only the v1 allowlist (gui.mode, the
# whole [deploy] / [network] blocks, security.privileged, [volumes]
# mounts, [environment] env_*) is honored — anything else is WARN'd
# and skipped by the validator.
#
# List fields use append-default + opt-out semantics: stage's `mount_*`
# / `port_*` / `env_*` items are appended to the top-level list unless
# the matching `<list>_inherit = false` flag is set, in which case
# only the stage's own entries survive.
# ════════════════════════════════════════════════════════════════════

# _parse_stage_sections <file> <out_array_var>
#
# Scans <file> for `^\[stage:NAME\]$` headers, returns NAME list in
# file order. Stage names matching `[a-z][a-z0-9_-]*` are collected;
# malformed names are silently skipped here (caller surfaces them
# via _validate_stage_name). Empty / missing file → empty output.
_parse_stage_sections() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _pss_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  _pss_out=()
  [[ -f "${_file}" ]] || return 0
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^\[stage:([a-z][a-z0-9_-]*)\][[:space:]]*$ ]]; then
      _pss_out+=("${BASH_REMATCH[1]}")
    fi
  done < "${_file}"
}

# _load_stage_overrides <base_path> <stage> <keys_outvar> <values_outvar>
#
# Reads the `[stage:<stage>]` section from <base_path>/setup.conf into
# parallel arrays. Stage sections only live in the per-repo file
# (template's setup.conf doesn't carry stage overrides — it doesn't
# know which Dockerfile stages exist downstream). Honors SETUP_CONF
# the same way _load_setup_conf does.
_load_stage_overrides() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local -n _lso_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lso_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"
  _lso_keys=()
  _lso_values=()

  local _conf
  if [[ -n "${SETUP_CONF:-}" ]]; then
    _conf="${SETUP_CONF}"
  else
    _conf="${_base}/config/docker/setup.conf"
  fi
  [[ -f "${_conf}" ]] || return 0
  _parse_ini_section "${_conf}" "stage:${_stage}" _lso_keys _lso_values
}

# _validate_stage_override_key <key>
#
# Returns 0 when <key> is in the v1 per-stage override allowlist,
# 1 otherwise. Allowlist scope:
#
#   [deploy]      gpu_mode, gpu_count, gpu_capabilities, runtime
#   [gui]         mode
#   [network]     mode, ipc, network_name, port_<N>, port_inherit
#   [security]    privileged
#   [volumes]     mount_<N>, mount_inherit
#   [environment] env_<N>, env_inherit
#
# Excluded by design (v1):
#   [image_name] / [build] / security.cap_*/security_opt_* / [devices] /
#   [tmpfs] / [additional_contexts] / [resources] — outside the
#   "Isaac Sim per-stage runtime" use case driving #220. Re-evaluate in
#   v2 once a real downstream need surfaces.
_validate_stage_override_key() {
  local _key="${1:?"${FUNCNAME[0]}: missing key"}"
  case "${_key}" in
    deploy.gpu_mode|deploy.gpu_count|deploy.gpu_capabilities|deploy.runtime) return 0 ;;
    gui.mode) return 0 ;;
    network.mode|network.ipc|network.network_name) return 0 ;;
    security.privileged) return 0 ;;
    network.port_inherit|volumes.mount_inherit|environment.env_inherit) return 0 ;;
  esac
  if [[ "${_key}" =~ ^(network\.port|volumes\.mount|environment\.env)_[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

# _resolve_stage_scalar <keys_var> <values_var> <key> <fallback> <out_var>
#
# Look up <key> in the stage's parallel arrays. If found, set <out_var>
# to that value; otherwise set <out_var> to <fallback>. Used for
# per-stage scalar overrides (gui.mode, network.mode, etc.) where there
# is no merge — the stage value either replaces the top-level or
# falls through entirely.
_resolve_stage_scalar() {
  local -n _rss_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rss_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _fallback="${4-}"
  local -n _rss_out="${5:?"${FUNCNAME[0]}: missing out var"}"
  local i
  for (( i = 0; i < ${#_rss_keys[@]}; i++ )); do
    if [[ "${_rss_keys[i]}" == "${_key}" ]]; then
      _rss_out="${_rss_values[i]}"
      return 0
    fi
  done
  _rss_out="${_fallback}"
}

# _resolve_stage_list <keys_var> <values_var> <prefix> <inherit_key> \
#                     <top_level_str> <out_var>
#
# Computes the effective list for a list field (volumes.mount_*,
# network.port_*, environment.env_*) on a per-stage basis.
#
# Args:
#   keys_var / values_var  Stage's parallel override arrays
#   prefix                 Full dotted prefix e.g. "volumes.mount_"
#                          — keys matching `<prefix>[0-9]+` are list items
#   inherit_key            Meta-key e.g. "volumes.mount_inherit"
#                          — value "false" switches to replace mode
#   top_level_str          Newline-separated top-level list (the same
#                          aggregate format setup.sh uses elsewhere)
#   out_var                Newline-separated effective list (no
#                          trailing newline)
#
# Default (inherit unspecified or anything ≠ "false"): top-level entries
# come first, stage entries appended afterward in setup.conf order.
# Replace mode (inherit=false): only stage entries appear; top-level
# is dropped. The opt-out lets a stage opt out of inherited mounts
# entirely (e.g. headless that wants no host-side ssh keys, regardless
# of the top-level mount_2 setting).
_resolve_stage_list() {
  local -n _rsl_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rsl_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _prefix="${3:?"${FUNCNAME[0]}: missing prefix"}"
  local _inherit_key="${4:?"${FUNCNAME[0]}: missing inherit_key"}"
  local _top="${5-}"
  local -n _rsl_out="${6:?"${FUNCNAME[0]}: missing out var"}"

  # Default to inheriting top-level. Only the literal "false" toggles
  # replace mode — anything else (including "true", empty, malformed)
  # keeps the safe append-default behavior.
  local _inherit="true" i
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    if [[ "${_rsl_keys[i]}" == "${_inherit_key}" ]]; then
      [[ "${_rsl_values[i]}" == "false" ]] && _inherit="false"
      break
    fi
  done

  # Collect stage's own list entries in setup.conf order. Match only
  # `<prefix><digits>` so meta-keys like `mount_inherit` (which share
  # the prefix) are not pulled in.
  local -a _stage_entries=()
  local _suffix
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    [[ "${_rsl_keys[i]}" == "${_prefix}"* ]] || continue
    _suffix="${_rsl_keys[i]#"${_prefix}"}"
    [[ "${_suffix}" =~ ^[0-9]+$ ]] || continue
    _stage_entries+=("${_rsl_values[i]}")
  done

  if [[ "${_inherit}" == "true" ]]; then
    if [[ -n "${_top}" ]] && (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="${_top}"$'\n'"$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    elif [[ -n "${_top}" ]]; then
      _rsl_out="${_top}"
    elif (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  else
    if (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  fi
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

# _expand_env_cross_refs <input-newline-list> <output-array-name>
#
# Reads `KEY=VALUE` entries (one per line, blank lines skipped) and
# substitutes `${KEY}` references in each value with the value of an
# earlier-seen sibling KEY. Order-sensitive: forward references (a value
# referencing a sibling not yet parsed) survive as the literal `${VAR}`,
# as do unknown references with no matching sibling -- compose.yaml's
# own substitution layer (.env / shell env) gets a chance at file-load
# time, surfacing genuinely undefined names visibly rather than silently
# substituting empty.
#
# Resolves issue #236: previously, sibling cross-references in
# `[environment] env_N` were emitted literally and compose's `${VAR}`
# substitution does NOT consult sibling environment entries -- so e.g.
#   env_1 = BUILD_TARGET=production
#   env_2 = LD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib
# would ship `LD_LIBRARY_PATH=/foo//lib` to the container.
_expand_env_cross_refs() {
  local _input="$1"
  local -n _expand_out_arr="$2"
  _expand_out_arr=()
  declare -A _seen=()
  local _line _k _v _ref_k _ref_v _expanded
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _expanded="${_v}"
    # Substitute every ${ref_k} found in _v against earlier siblings.
    # Multiple-pass not needed because _seen already holds fully-expanded
    # values from prior iterations (transitive references resolve through
    # the chain naturally).
    for _ref_k in "${!_seen[@]}"; do
      _ref_v="${_seen[${_ref_k}]}"
      _expanded="${_expanded//\$\{${_ref_k}\}/${_ref_v}}"
    done
    _seen["${_k}"]="${_expanded}"
    _expand_out_arr+=("${_k}=${_expanded}")
  done <<< "${_input}"
}

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
  # Only emitted for the devel service; devel-test doesn't run.
  _emit_runtime_line() {
    [[ -z "${_runtime}" ]] && return 0
    printf '    runtime: %s\n' "${_runtime}"
  }

  # Auto-emit any `FROM <base> AS <stage>` outside the baseline
  # blocklist {sys, base, devel, test} as a compose service that
  # `extends: devel` and only overrides target / image / container_name /
  # stdin_open / tty / profiles. Issue #215 generalized the v0.10.0
  # `runtime`-only detection (#108) so any user-added stage gets a
  # corresponding service automatically — e.g. NVIDIA Isaac Sim's
  # `headless` + `gui` stages share devel's baseline (GPU / network /
  # volumes) and differ only in ENTRYPOINT.
  #
  # Validation: each parsed stage runs through _validate_stage_name.
  # Returns 1 (invalid format) → WARN + skip but keep parsing.
  # Returns 2 (baseline collision) / 3 (reserved tag namespace) →
  # caller exits non-zero so user fixes the Dockerfile before retry.
  # Per-stage diff (different volumes / GPU / network than devel) is
  # out of scope v1; declare via Dockerfile ARG + conditional RUN.
  local _dockerfile _setup_base
  _setup_base="$(dirname -- "${_out}")"
  _dockerfile="${_setup_base}/Dockerfile"
  local -a _emit_stages=()
  local _stage _vrc
  while IFS= read -r _stage; do
    [[ -z "${_stage}" ]] && continue
    _vrc=0
    _validate_stage_name "${_stage}" || _vrc=$?
    case "${_vrc}" in
      0) _emit_stages+=("${_stage}") ;;
      1) printf '[setup] WARN: %s: %q\n' "$(_setup_msg stage_invalid_format)" "${_stage}" >&2 ;;
      2) printf '[setup] ERROR: %s: %q\n' "$(_setup_msg stage_baseline_collision)" "${_stage}" >&2; return 1 ;;
      3) printf '[setup] ERROR: %s: %q\n' "$(_setup_msg stage_reserved_tag)" "${_stage}" >&2; return 1 ;;
    esac
  done < <(_parse_dockerfile_stages "${_dockerfile}")

  # Per-stage overrides (#220) — validate setup.conf [stage:*] sections.
  #
  #   sys / base / test       → hard error (baseline collision)
  #   latest / v[0-9]*        → hard error (reserved tag namespace)
  #   devel                   → reserved (v1 no-op WARN)
  #   foo (not in Dockerfile) → orphan WARN, ignored
  #
  # Stages with malformed names that don't match `[a-z][a-z0-9_-]*`
  # never reach _conf_stages because _parse_stage_sections's regex
  # already filters them; that's an acceptable v1 silent-drop since
  # the TUI is the primary write path and validates names upfront.
  local -a _conf_stages=()
  _parse_stage_sections "${_setup_base}/config/docker/setup.conf" _conf_stages
  local _cs
  for _cs in "${_conf_stages[@]}"; do
    case "${_cs}" in
      sys|base|test)
        printf '[setup] ERROR: %s: [stage:%s]\n' \
          "$(_setup_msg stage_baseline_collision)" "${_cs}" >&2
        return 1
        ;;
      latest|v[0-9]*)
        printf '[setup] ERROR: %s: [stage:%s]\n' \
          "$(_setup_msg stage_reserved_tag)" "${_cs}" >&2
        return 1
        ;;
      devel)
        printf '[setup] WARN: [stage:devel] is reserved; not applied in v1 (#220). Edit top-level sections to tune devel.\n' >&2
        continue
        ;;
    esac
    # Orphan check: stage is referenced but Dockerfile doesn't have it.
    local _is_emitted=0 _es
    for _es in "${_emit_stages[@]}"; do
      [[ "${_es}" == "${_cs}" ]] && _is_emitted=1 && break
    done
    if (( ! _is_emitted )); then
      printf '[setup] WARN: %s: [stage:%s]\n' \
        "$(_setup_msg stage_unknown_referenced)" "${_cs}" >&2
    fi
  done

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
        # Expand `${KEY}` cross-references against earlier siblings so
        # the emitted compose.yaml carries the user's intent verbatim
        # (compose's own substitution layer does NOT see sibling env
        # entries -- refs #236).
        local -a _env_expanded=()
        _expand_env_cross_refs "${_env_str}" _env_expanded
        local _ev
        for _ev in "${_env_expanded[@]}"; do
          [[ -z "${_ev}" ]] && continue
          echo "      - ${_ev}"
        done
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

    # Auto-emit a service per non-baseline stage parsed from the
    # Dockerfile (#215). Each service:
    #   - extends `devel` (compose merges network / ipc / privileged /
    #     cap_add / volumes / environment / deploy.resources / runtime)
    #   - overrides build.target so docker builds the right stage
    #   - tags `image:` and `container_name:` per stage so multiple
    #     stages coexist locally without clobbering devel's `:devel`
    #   - disables stdin_open / tty: stages are typically headless
    #     entrypoints (e.g. `headless` runs runheadless.sh, `runtime`
    #     runs CMD-driven daemons). Interactive debug uses
    #     `./exec.sh -t <stage>` after `./run.sh -t <stage>`.
    #   - profiles: [<stage>] keeps plain `docker compose up` scoped to
    #     devel; explicit `compose up <stage>` or `./run.sh -t <stage>`
    #     bypasses the profile gate.
    #
    # `runtime` is no longer special-cased (#108) — it falls through
    # this loop like any other non-baseline stage, preserving its
    # behavior since `runtime` is not in the baseline blocklist.
    # Build a snapshot of the top-level volumes list (newline-separated
    # — same shape `_resolve_stage_list` consumes/produces). The list is
    # what feeds into compose.yaml's volumes block before per-stage
    # append/replace logic kicks in. _gcy_extras already excludes the
    # GUI baseline (X11) — those are emitted separately based on
    # effective gui resolution.
    local _top_volumes_str=""
    if (( ${#_gcy_extras[@]} > 0 )); then
      _top_volumes_str="$(printf '%s\n' "${_gcy_extras[@]}")"
      _top_volumes_str="${_top_volumes_str%$'\n'}"
    fi

    local _emit_stage
    for _emit_stage in "${_emit_stages[@]}"; do
      # Load + filter [stage:<name>] overrides for this stage.
      local -a _so_keys=() _so_values=()
      _load_stage_overrides "${_setup_base}" "${_emit_stage}" _so_keys _so_values
      local -a _so_filtered_keys=() _so_filtered_values=()
      local _ki
      for (( _ki = 0; _ki < ${#_so_keys[@]}; _ki++ )); do
        if _validate_stage_override_key "${_so_keys[_ki]}"; then
          _so_filtered_keys+=("${_so_keys[_ki]}")
          _so_filtered_values+=("${_so_values[_ki]}")
        else
          printf '[setup] WARN: %s: %q (stage=%s)\n' \
            "$(_setup_msg stage_override_key_not_allowed)" \
            "${_so_keys[_ki]}" "${_emit_stage}" >&2
        fi
      done
      local _has_overrides=0
      (( ${#_so_filtered_keys[@]} > 0 )) && _has_overrides=1

      # Zero-diff path: stage with NO overrides keeps the minimal
      # extends:devel shape from #215. Critical for the 17 existing
      # downstream repos (no [stage:*] sections → byte-for-byte
      # identical compose.yaml output to pre-#220).
      if (( ! _has_overrides )); then
        cat <<YAML

  ${_emit_stage}:
    extends:
      service: devel
    build:
      context: .
      dockerfile: Dockerfile
      target: ${_emit_stage}
YAML
        _emit_additional_contexts_block
        cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_emit_stage}
    container_name: ${_name}-${_emit_stage}\${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - ${_emit_stage}
YAML
        continue
      fi

      # Resolve effective per-stage values. For modes (gui / gpu),
      # absent or "auto" inherits the parent's already-resolved boolean
      # — we don't re-detect inside the stage. For other scalars, the
      # parent's effective value is the fallback.
      local _eff_gui_mode _eff_gui
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "gui.mode" "" _eff_gui_mode
      case "${_eff_gui_mode}" in
        off)   _eff_gui="false" ;;
        force) _eff_gui="true" ;;
        *)     _eff_gui="${_gui}" ;;
      esac

      local _eff_gpu_mode _eff_gpu
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "deploy.gpu_mode" "" _eff_gpu_mode
      case "${_eff_gpu_mode}" in
        off)   _eff_gpu="false" ;;
        force) _eff_gpu="true" ;;
        *)     _eff_gpu="${_gpu}" ;;
      esac

      local _eff_gpu_count _eff_gpu_caps _eff_runtime
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "deploy.gpu_count" "${_gpu_count}" _eff_gpu_count
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "deploy.gpu_capabilities" "${_gpu_caps}" _eff_gpu_caps
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "deploy.runtime" "${_runtime}" _eff_runtime

      local _eff_net_mode _eff_ipc_mode _eff_net_name _eff_privileged
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "network.mode" "${_net_mode}" _eff_net_mode
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "network.ipc" "${_ipc_mode}" _eff_ipc_mode
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "network.network_name" "${_net_name}" _eff_net_name
      _resolve_stage_scalar _so_filtered_keys _so_filtered_values "security.privileged" "" _eff_privileged

      local _eff_volumes _eff_environment _eff_ports
      _resolve_stage_list _so_filtered_keys _so_filtered_values "volumes.mount_" "volumes.mount_inherit" "${_top_volumes_str}" _eff_volumes
      _resolve_stage_list _so_filtered_keys _so_filtered_values "environment.env_" "environment.env_inherit" "${_env_str}" _eff_environment
      _resolve_stage_list _so_filtered_keys _so_filtered_values "network.port_" "network.port_inherit" "${_ports_str}" _eff_ports

      # ── Standalone emit (#220 v0.18.1 fix) ──────────────────────────
      #
      # Stages with overrides drop `extends: devel` and emit a full
      # service block. Reason: compose `extends` MERGES list fields
      # (volumes / environment / ports / cap_add / deploy.devices) by
      # appending child entries to parent's, not replacing them. So a
      # stage that wants `gui.mode = off` cannot suppress devel's X11
      # mount / DISPLAY env via extends — they merge back in. The Isaac
      # Sim headless validation (#220 comment 2026-05-06) confirmed
      # this. Standalone emit sidesteps the merge entirely: every list
      # the stage touches contains exactly the resolved set of entries.
      #
      # Top-level fields not yet in the per-stage allowlist (`cap_add` /
      # `cap_drop` / `security_opt` / `devices` / `cgroup_rules` /
      # `tmpfs`) are re-emitted from the enclosing scope's top-level
      # values so the stage still inherits those by default.
      #
      # Cost: a stage with even a single scalar override now produces
      # ~150 lines of compose.yaml instead of ~10. compose.yaml is
      # auto-generated, so the verbosity is fine; correctness wins.

      cat <<YAML

  ${_emit_stage}:
    build:
      context: .
      dockerfile: Dockerfile
      target: ${_emit_stage}
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
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_emit_stage}
    container_name: ${_name}-${_emit_stage}\${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - ${_emit_stage}
YAML
      # privileged: literal when stage overrides; else env-var ref
      # (same shape devel emits — .env's PRIVILEGED applies).
      if [[ -n "${_eff_privileged}" ]]; then
        echo "    privileged: ${_eff_privileged}"
      else
        echo "    privileged: \${PRIVILEGED}"
      fi
      # ipc: literal when stage overrides; else env-var ref.
      if [[ "${_eff_ipc_mode}" != "${_ipc_mode}" ]]; then
        echo "    ipc: ${_eff_ipc_mode}"
      else
        echo "    ipc: \${IPC_MODE}"
      fi
      # runtime: only when explicitly set non-empty / non-auto / non-off.
      if [[ -n "${_eff_runtime}" ]] && \
         [[ "${_eff_runtime}" != "off" ]] && \
         [[ "${_eff_runtime}" != "auto" ]]; then
        echo "    runtime: ${_eff_runtime}"
      fi
      # cap_add / cap_drop / security_opt — re-emit from top-level
      # (not yet in per-stage allowlist; v2 may revisit).
      if [[ -n "${_cap_add_str}" ]]; then
        echo "    cap_add:"
        local _sa_cap
        while IFS= read -r _sa_cap; do
          [[ -z "${_sa_cap}" ]] && continue
          echo "      - ${_sa_cap}"
        done <<< "${_cap_add_str}"
      fi
      if [[ -n "${_cap_drop_str}" ]]; then
        echo "    cap_drop:"
        local _sa_cd
        while IFS= read -r _sa_cd; do
          [[ -z "${_sa_cd}" ]] && continue
          echo "      - ${_sa_cd}"
        done <<< "${_cap_drop_str}"
      fi
      if [[ -n "${_sec_opt_str}" ]]; then
        echo "    security_opt:"
        local _sa_so
        while IFS= read -r _sa_so; do
          [[ -z "${_sa_so}" ]] && continue
          echo "      - ${_sa_so}"
        done <<< "${_sec_opt_str}"
      fi
      # network: literal mode + optional named network. When stage
      # didn't override mode, fall back to env-var ref (matches devel).
      if [[ "${_eff_net_mode}" == "bridge" ]] && [[ -n "${_eff_net_name}" ]]; then
        cat <<YAML
    networks:
      - ${_eff_net_name}
YAML
      elif [[ "${_eff_net_mode}" != "${_net_mode}" ]]; then
        echo "    network_mode: ${_eff_net_mode}"
      else
        echo "    network_mode: \${NETWORK_MODE}"
      fi
      # environment: GUI baseline (effective gui) + effective env list.
      if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_environment}" ]]; then
        echo "    environment:"
        if [[ "${_eff_gui}" == "true" ]]; then
          cat <<'YAML'
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=${XAUTHORITY:-}
YAML
        fi
        if [[ -n "${_eff_environment}" ]]; then
          local _ev
          while IFS= read -r _ev; do
            [[ -z "${_ev}" ]] && continue
            echo "      - ${_ev}"
          done <<< "${_eff_environment}"
        fi
      fi
      # ports: only under bridge mode (compose ignores it under host).
      if [[ -n "${_eff_ports}" ]] && [[ "${_eff_net_mode}" == "bridge" ]]; then
        echo "    ports:"
        local _sp
        while IFS= read -r _sp; do
          [[ -z "${_sp}" ]] && continue
          echo "      - \"${_sp}\""
        done <<< "${_eff_ports}"
      fi
      # volumes: GUI baseline (effective gui) + effective volume list.
      if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_volumes}" ]]; then
        echo "    volumes:"
        if [[ "${_eff_gui}" == "true" ]]; then
          cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:${XAUTHORITY:-/dev/null}:ro
YAML
        fi
        if [[ -n "${_eff_volumes}" ]]; then
          local _m
          while IFS= read -r _m; do
            [[ -z "${_m}" ]] && continue
            echo "      - ${_m}"
          done <<< "${_eff_volumes}"
        fi
      fi
      # devices: + cgroup_rules: from top-level (not yet per-stage).
      if [[ -n "${_devices_str}" ]]; then
        echo "    devices:"
        local _sd
        while IFS= read -r _sd; do
          [[ -z "${_sd}" ]] && continue
          echo "      - ${_sd}"
        done <<< "${_devices_str}"
      fi
      if [[ -n "${_cgroup_rule_str}" ]]; then
        echo "    device_cgroup_rules:"
        local _scr
        while IFS= read -r _scr; do
          [[ -z "${_scr}" ]] && continue
          echo "      - \"${_scr}\""
        done <<< "${_cgroup_rule_str}"
      fi
      # tmpfs: from top-level.
      if [[ -n "${_tmpfs_str}" ]]; then
        echo "    tmpfs:"
        local _stf
        while IFS= read -r _stf; do
          [[ -z "${_stf}" ]] && continue
          echo "      - ${_stf}"
        done <<< "${_tmpfs_str}"
      fi
      # shm_size: depends on effective ipc (only emitted under
      # non-host ipc, mirroring devel).
      if [[ -n "${_shm_size}" ]] && [[ "${_eff_ipc_mode}" != "host" ]]; then
        echo "    shm_size: ${_shm_size}"
      fi
      # deploy / GPU block: emit when effective gpu is enabled.
      if [[ "${_eff_gpu}" == "true" ]]; then
        local -a _eff_caps_arr=()
        read -ra _eff_caps_arr <<< "${_eff_gpu_caps}"
        local _eff_caps_yaml="["
        local _ef=1 _ec
        for _ec in "${_eff_caps_arr[@]}"; do
          if (( _ef )); then _eff_caps_yaml+="${_ec}"; _ef=0
          else _eff_caps_yaml+=", ${_ec}"; fi
        done
        _eff_caps_yaml+="]"
        cat <<YAML
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${_eff_gpu_count}
              capabilities: ${_eff_caps_yaml}
YAML
      fi
    done

    cat <<YAML

  test:
    build:
      context: .
      dockerfile: Dockerfile
      target: devel-test
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
  local _dockerfile_hash="${1}"; shift
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
SETUP_DOCKERFILE_HASH=${_dockerfile_hash}
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
  local _stored_hash="" _stored_df_hash="" _stored_gui="" _stored_gpu="" _stored_uid=""
  _stored_hash="$(   grep -oP '^SETUP_CONF_HASH=\K.*'       "${_env_file}" 2>/dev/null || true)"
  _stored_df_hash="$(grep -oP '^SETUP_DOCKERFILE_HASH=\K.*' "${_env_file}" 2>/dev/null || true)"
  _stored_gui="$(    grep -oP '^SETUP_GUI_DETECTED=\K.*'    "${_env_file}" 2>/dev/null || true)"
  _stored_gpu="$(    grep -oP '^GPU_ENABLED=\K.*'           "${_env_file}" 2>/dev/null || true)"
  _stored_uid="$(    grep -oP '^USER_UID=\K.*'              "${_env_file}" 2>/dev/null || true)"

  local _now_hash="" _now_df_hash="" _now_gui="" _now_gpu=""
  _compute_conf_hash       "${_base}" _now_hash
  _compute_dockerfile_hash "${_base}" _now_df_hash
  detect_gui _now_gui
  detect_gpu _now_gpu
  local _now_uid=""
  _now_uid="$(id -u)"

  local -a _drift=()
  [[ -n "${_stored_hash}"    && "${_now_hash}"    != "${_stored_hash}"    ]] \
    && _drift+=("setup.conf modified since last setup")
  [[ -n "${_stored_df_hash}" && "${_now_df_hash}" != "${_stored_df_hash}" ]] \
    && _drift+=("Dockerfile stage list changed since last setup (added/removed FROM ... AS <stage>)")
  [[ -n "${_stored_gpu}"     && "${_now_gpu}"     != "${_stored_gpu}"     ]] \
    && _drift+=("GPU detection changed: ${_stored_gpu} → ${_now_gpu}")
  [[ -n "${_stored_gui}"     && "${_now_gui}"     != "${_stored_gui}"     ]] \
    && _drift+=("GUI detection changed: ${_stored_gui} → ${_now_gui}")
  [[ -n "${_stored_uid}"     && "${_now_uid}"     != "${_stored_uid}"     ]] \
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
  local _repo_conf="${_base}/config/docker/setup.conf"
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
  local _conf="${_base_path}/config/docker/setup.conf"
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
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
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
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
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
  local _conf="${_base_path}/config/docker/setup.conf"
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
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
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
  local _conf="${_base_path}/config/docker/setup.conf"
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
  local _conf="${_base_path}/config/docker/setup.conf"
  local _env="${_base_path}/.env"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
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
  local _repo_conf="${_base_path}/config/docker/setup.conf"
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
    _tpl_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
    if [[ -f "${_tpl_conf}" ]]; then
      # Ensure config/docker/ parent dir exists before cp (post-#262
      # path; first-time bootstrap on a fresh repo will not have it).
      mkdir -p "$(dirname "${_repo_conf}")"
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
  _tpl_setup_conf="${_SETUP_SCRIPT_DIR}/../../config/docker/setup.conf"
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

  # ── Compute hashes for drift detection ──
  local conf_hash=""
  _compute_conf_hash "${_base_path}" conf_hash
  # Dockerfile hash covers the stage-list projection only — adds /
  # removes / renames an `^FROM ... AS <stage>` line, but unrelated
  # `RUN apt-get install` edits do not trigger compose regen.
  local dockerfile_hash=""
  _compute_dockerfile_hash "${_base_path}" dockerfile_hash

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
    "${gui_detected}" "${conf_hash}" "${dockerfile_hash}" \
    "${network_name}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}"

  local runtime_resolved=""
  _resolve_runtime "${runtime_mode}" runtime_resolved

  # Propagate generate_compose_yaml's exit explicitly: when sourced
  # (no `set -e`) a hard-error return from the stage validator (#215
  # baseline collision / reserved-tag) would otherwise be swallowed
  # and apply would print "updated" with a half-written compose.yaml.
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
    "${_additional_contexts_str}" \
    || return $?

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
