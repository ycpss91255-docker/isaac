#!/usr/bin/env bash
# setup.sh - Auto-detect system parameters and generate .env + compose.yaml
#
# Reads <repo>/setup.conf (or .base/setup.conf default) for the repo's
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
# Resolve the symlink (<repo>/setup.sh → .base/script/docker/setup.sh)
# so sibling sources (i18n.sh / _tui_conf.sh) are located in the
# template directory regardless of how the script was invoked.
_SETUP_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SETUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${_SETUP_SELF}")" && pwd -P)"
_SETUP_LIB_DIR="$(cd -- "${_SETUP_SCRIPT_DIR}/../lib" && pwd -P)"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_tui_conf.sh"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_lib.sh"

# i18n message table, split per category and routed through _log_*
# (closes #290). Renamed from a monolithic `_msg` to `_setup_msg`
# (closes #101) so sourcing this file from build.sh / run.sh doesn't
# silently shadow their own top-level `_msg()`. The category split
# mirrors #278 PR-2 (which did the same for build/run/exec/stop):
# each _setup_msg_<category> returns plain i18n body only; tag +
# LEVEL keyword are added by the _log_* caller (English-only; level
# keyword no longer translated — see #283).

_setup_msg_env() {
  case "${_LANG}:${1:?}" in
    zh-TW:done)     echo ".env 與 compose.yaml 更新完成" ;;
    zh-CN:done)     echo ".env 与 compose.yaml 更新完成" ;;
    ja:done)        echo ".env と compose.yaml 更新完了" ;;
    *:done)         echo ".env + compose.yaml updated" ;;
    zh-TW:comment)  echo "自動偵測欄位請勿手動修改，如需變更 WS_PATH 可直接編輯此檔案" ;;
    zh-CN:comment)  echo "自动检测字段请勿手动修改，如需变更 WS_PATH 可直接编辑此文件" ;;
    ja:comment)     echo "自動検出フィールドは手動で編集しないでください。WS_PATH の変更はこのファイルを直接編集してください" ;;
    *:comment)      echo "Auto-detected fields, do not edit manually. Edit WS_PATH if needed" ;;
  esac
}

_setup_msg_errors() {
  case "${_LANG}:${1:?}" in
    zh-TW:unknown_arg)       echo "未知參數" ;;
    zh-CN:unknown_arg)       echo "未知参数" ;;
    ja:unknown_arg)          echo "不明な引数" ;;
    *:unknown_arg)           echo "Unknown argument" ;;
    zh-TW:unknown_subcmd)    echo "未知子指令" ;;
    zh-CN:unknown_subcmd)    echo "未知子命令" ;;
    ja:unknown_subcmd)       echo "不明なサブコマンド" ;;
    *:unknown_subcmd)        echo "Unknown subcommand" ;;
    zh-TW:unknown_section)   echo "未知 section" ;;
    zh-CN:unknown_section)   echo "未知 section" ;;
    ja:unknown_section)      echo "不明な section" ;;
    *:unknown_section)       echo "Unknown section" ;;
    zh-TW:invalid_value)     echo "無效的值" ;;
    zh-CN:invalid_value)     echo "无效的值" ;;
    ja:invalid_value)        echo "無効な値" ;;
    *:invalid_value)         echo "Invalid value" ;;
    zh-TW:key_not_found)     echo "找不到鍵" ;;
    zh-CN:key_not_found)     echo "找不到键" ;;
    ja:key_not_found)        echo "キーが見つかりません" ;;
    *:key_not_found)         echo "Key not found" ;;
    zh-TW:section_not_found) echo "找不到 section" ;;
    zh-CN:section_not_found) echo "找不到 section" ;;
    ja:section_not_found)    echo "section が見つかりません" ;;
    *:section_not_found)     echo "Section not found" ;;
  esac
}

_setup_msg_warnings() {
  case "${_LANG}:${1:?}" in
    zh-TW:no_repo_conf)    echo "未找到 repo 自有的 setup.conf — 全部 section 將使用模板預設值" ;;
    zh-CN:no_repo_conf)    echo "未找到 repo 自有的 setup.conf — 全部 section 将使用模板默认值" ;;
    ja:no_repo_conf)       echo "repo 固有の setup.conf が見つかりません — 全ての section でテンプレートのデフォルト値を使用します" ;;
    *:no_repo_conf)        echo "no per-repo setup.conf — using template defaults for all sections" ;;
    zh-TW:empty_repo_conf) echo "repo 的 setup.conf 沒有任何 section 覆寫 — 全部 section 將使用模板預設值" ;;
    zh-CN:empty_repo_conf) echo "repo 的 setup.conf 没有任何 section 覆写 — 全部 section 将使用模板默认值" ;;
    ja:empty_repo_conf)    echo "repo の setup.conf にセクション上書きがありません — 全ての section でテンプレートのデフォルト値を使用します" ;;
    *:empty_repo_conf)     echo "per-repo setup.conf has no section overrides — using template defaults for all sections" ;;
  esac
}

# usage_* messages are short subcommand-usage hints printed directly
# (no [setup] / LEVEL prefix) — they are help text, not log lines.
_setup_msg_usage() {
  case "${_LANG}:${1:?}" in
    zh-TW:set)    echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:set)    echo "用法: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:set)       echo "使い方: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    *:set)        echo "Usage: setup.sh set <section>.<key> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-TW:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    ja:show)      echo "使い方: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    *:show)       echo "Usage: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    ja:list)      echo "使い方: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    *:list)       echo "Usage: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:add)    echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:add)    echo "用法: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:add)       echo "使い方: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    *:add)        echo "Usage: setup.sh add <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-TW:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    zh-CN:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    ja:remove)    echo "使い方: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
    *:remove)     echo "Usage: setup.sh remove <section>.<key> | <section>.<list> <value> [--base-path PATH] [--lang LANG]" ;;
  esac
}

_setup_msg_reset() {
  case "${_LANG}:${1:?}" in
    zh-TW:confirm)   echo "將以模板預設值覆寫 setup.conf（舊檔備份為 setup.conf.bak / .env.bak）。繼續嗎？" ;;
    zh-CN:confirm)   echo "将以模板默认值覆写 setup.conf（旧文件备份为 setup.conf.bak / .env.bak）。继续吗？" ;;
    ja:confirm)      echo "テンプレートのデフォルト値で setup.conf を上書きします（旧ファイルは setup.conf.bak / .env.bak にバックアップ）。続行しますか？" ;;
    *:confirm)       echo "Overwrite setup.conf with template default? (prior setup.conf → .bak, prior .env → .env.bak)" ;;
    zh-TW:aborted)   echo "已取消，未變更任何檔案" ;;
    zh-CN:aborted)   echo "已取消，未更改任何文件" ;;
    ja:aborted)      echo "中断されました。ファイルは変更されていません" ;;
    *:aborted)       echo "Aborted; no files changed" ;;
    zh-TW:done)      echo "setup.conf 已重設為模板預設值（先前內容備份於 .bak）" ;;
    zh-CN:done)      echo "setup.conf 已重置为模板默认值（之前内容备份至 .bak）" ;;
    ja:done)         echo "setup.conf をテンプレートのデフォルトにリセットしました（旧内容は .bak に保存）" ;;
    *:done)          echo "setup.conf reset to template default (prior contents saved to .bak)" ;;
    zh-TW:needs_yes) echo "非互動模式：請加 --yes 才會執行 reset（避免誤刪）" ;;
    zh-CN:needs_yes) echo "非交互模式：请加 --yes 才会执行 reset（避免误删）" ;;
    ja:needs_yes)    echo "非対話モード: --yes を指定しないと reset は実行されません（誤削除防止）" ;;
    *:needs_yes)     echo "Non-interactive: pass --yes to confirm reset (prevents accidental destruction)" ;;
  esac
}

_setup_msg_stage() {
  case "${_LANG}:${1:?}" in
    zh-TW:invalid_format)           echo "Dockerfile stage 名稱格式無效，已跳過該 stage" ;;
    zh-CN:invalid_format)           echo "Dockerfile stage 名称格式无效，已跳过该 stage" ;;
    ja:invalid_format)              echo "Dockerfile stage 名のフォーマットが無効です。該当 stage はスキップされます" ;;
    *:invalid_format)               echo "invalid Dockerfile stage name format; stage skipped" ;;
    zh-TW:baseline_collision)       echo "Dockerfile stage 名稱與 template 內建 stage 衝突，請改名" ;;
    zh-CN:baseline_collision)       echo "Dockerfile stage 名称与 template 内建 stage 冲突，请改名" ;;
    ja:baseline_collision)          echo "Dockerfile stage 名が template 管理の stage と衝突しています。改名してください" ;;
    *:baseline_collision)           echo "Dockerfile stage name collides with a template-managed baseline stage; rename it" ;;
    zh-TW:reserved_tag)             echo "Dockerfile stage 名稱使用 template 控制的 image tag namespace，請改名" ;;
    zh-CN:reserved_tag)             echo "Dockerfile stage 名称使用 template 控制的 image tag namespace，请改名" ;;
    ja:reserved_tag)                echo "Dockerfile stage 名が template が管理する image tag namespace を使用しています。改名してください" ;;
    *:reserved_tag)                 echo "Dockerfile stage name uses a template-controlled image tag namespace; rename it" ;;
    zh-TW:unknown_referenced)       echo "setup.conf 內 [stage:...] 對應的 stage 在 Dockerfile 中不存在，已忽略該區段" ;;
    zh-CN:unknown_referenced)       echo "setup.conf 内 [stage:...] 对应的 stage 在 Dockerfile 中不存在，已忽略该区段" ;;
    ja:unknown_referenced)          echo "setup.conf 内の [stage:...] が指す stage が Dockerfile に存在しません。該当セクションは無視されます" ;;
    *:unknown_referenced)           echo "setup.conf [stage:...] references a stage missing from the Dockerfile; section ignored" ;;
    zh-TW:override_key_not_allowed) echo "[stage:...] 區段內含不在 per-stage 允許清單內的 key，已忽略該 key" ;;
    zh-CN:override_key_not_allowed) echo "[stage:...] 区段内含不在 per-stage 允许清单内的 key，已忽略该 key" ;;
    ja:override_key_not_allowed)    echo "[stage:...] セクション内に per-stage 許可リスト外の key が含まれています。該当 key は無視されます" ;;
    *:override_key_not_allowed)     echo "[stage:...] section contains a key outside the per-stage allowlist; key ignored" ;;
  esac
}

# Dispatcher — keeps a single _setup_msg call shape across the script.
_setup_msg_deploy() {
  case "${_LANG}:${1:?}" in
    zh-TW:runtime_deprecated) echo "[deploy] runtime 已更名為 gpu_runtime；舊鍵仍可用（永久別名），請改用 gpu_runtime（v1.0.0 將移除）" ;;
    zh-CN:runtime_deprecated) echo "[deploy] runtime 已更名为 gpu_runtime；旧键仍可用（永久别名），请改用 gpu_runtime（v1.0.0 将移除）" ;;
    ja:runtime_deprecated)    echo "[deploy] runtime は gpu_runtime に改名されました。旧キーは当面有効（恒久エイリアス）ですが gpu_runtime へ移行してください（v1.0.0 で削除）" ;;
    *:runtime_deprecated)     echo "[deploy] runtime is renamed to gpu_runtime; the old key still works (permanent alias) but please migrate to gpu_runtime (removal at v1.0.0)" ;;
  esac
}

_setup_msg() {
  local _category="${1:?_setup_msg requires category}"
  local _key="${2:?_setup_msg requires key}"
  "_setup_msg_${_category}" "${_key}"
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
  deploy [--stage S] [--output F] [--dry-run] [-y|--yes]
                Build a self-contained field bundle for stage S (default
                runtime): bake [environment] as ENV + COPY config/app
                into the image, docker build --target S, generate
                deploy.sh, docker save, and tar.xz {image, deploy.sh}.
                Previews the resolved launcher (every inlined docker
                flag) and prompts before building; --dry-run prints the
                plan only; -y skips the prompt. Default output is
                <base-path>/deploy/<name>-<stage>.tar.xz. Field flow:
                extract, docker load < image.tar, ./deploy.sh.

Options:
  -h, --help            Show this help and exit.
  --base-path PATH      Repo root to operate on. Defaults to the repo
                        containing this script (.base/../..).
  --lang LANG           Set message language (en|zh-TW|zh-CN|ja).
                        Defaults to $SETUP_LANG or auto-detected from
                        $LANG.
  -q, --quiet           Suppress the success-confirmation lines on
                        set / add / remove / reset / apply. Errors
                        still go to stderr. Used by setup_tui.sh to
                        avoid double-printing after its `[tui] saved`
                        line.

Apply-only options (#338):
  --gui auto|force|off  Per-invocation override for [gui] mode. Wins
                        over $SETUP_GUI env var and setup.conf. Useful
                        for debugging X11 or one-off headless runs on
                        a GUI repo. Equivalent forms: `--gui=auto`.
  --no-x11-cookie       Skip the SSH X11 cookie rewrite even when
                        SSH X11 forwarding is detected. GUI itself
                        stays enabled per [gui] mode resolution;
                        $XAUTHORITY stays at the host value the user's
                        SSH session populated. Debug knob for #321.
  --print-resolved      Run all detection + resolution logic and
                        print the effective state to stdout as
                        `KEY=VALUE` lines (one per line), then exit
                        without writing .env / compose.yaml /
                        .gitignore. Subsumes the dry-run piece of
                        the #230 base-mcp setup_resolve plan.

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
# _is_ssh_x11
#
# Detect if the current session is using SSH X11 forwarding.
# Returns 0 (success) when SSH_CONNECTION is set AND DISPLAY matches
# the "localhost:N[.M]" pattern that SSH writes for X11 tunnels.
# Returns non-zero otherwise (local X session, no display, etc.).
#
# Used by the SSH X11 cookie-rewrite + non-host-network warn path
# in apply flow (refs base#321).
# ════════════════════════════════════════════════════════════════════
_is_ssh_x11() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  [[ "${DISPLAY:-}" =~ ^localhost:[0-9]+(\.[0-9]+)?$ ]] || return 1
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_ssh_x11_cookie <file_path>
#
# Rewrite the X11 authentication cookie for the current DISPLAY so it
# is accepted regardless of hostname (the container's hostname differs
# from the host's). Standard `ssh + Docker + X11` recipe:
#
#   xauth nlist $DISPLAY | sed 's/^..../ffff/' | xauth -f <out> nmerge -
#
# The `ffff` family code in the cookie's first 4 bytes tells libX11
# "ignore the hostname when matching", so the container can find the
# cookie under its own hostname. The rewritten cookie is written to
# `<file_path>/.docker.xauth`, which gets mounted into the container by
# generate_compose_yaml's existing XAUTHORITY mount line (XAUTHORITY
# in .env points at this path; see write_env's _ssh_x11_xauth arg).
#
# Echoes the absolute path on success. Returns non-zero (and logs a
# warning) if `xauth` is not installed; caller should fall through to
# leaving XAUTHORITY untouched in .env. Refs base#321.
#
# Usage:
#   local _xauth_path
#   _xauth_path="$(_setup_ssh_x11_cookie "${_file_path}")" || _xauth_path=""
# ════════════════════════════════════════════════════════════════════
_setup_ssh_x11_cookie() {
  local _file_path="${1:?_setup_ssh_x11_cookie requires <file_path>}"
  if ! command -v xauth >/dev/null 2>&1; then
    _log_warn setup ssh_x11_no_xauth "display=SSH X11 forwarding detected but 'xauth' is not in PATH; skipping cookie rewrite. Install xauth (apt: x11-xauth-utils) and re-run setup."
    return 1
  fi
  local _out="${_file_path}/.docker.xauth"
  : > "${_out}"
  # `-i` (ignore locks) bypasses ~/.Xauthority lockfile contention from
  # parallel xauth invocations (e.g. another tmux session, ssh-agent,
  # or DE startup hook holding flock). Without -i, `xauth nlist`
  # silently returns empty output (the lock error goes to stderr,
  # exit 0) on a contended file, the sed pipeline gets nothing, and
  # nmerge writes a 0-byte cookie file — defeating the rewrite. Read
  # is a non-mutating op so ignoring the lock is safe.
  # Family-byte rewrite: 'ffff' means "any host" so libX11 inside the
  # container does not fail the hostname check.
  xauth -i nlist "${DISPLAY}" 2>/dev/null \
    | sed -e 's/^..../ffff/' \
    | xauth -i -f "${_out}" nmerge - >/dev/null 2>&1 || {
        _log_warn setup xauth_rewrite_failed "display=xauth cookie rewrite failed; XAUTHORITY left at host value."
        return 1
      }
  # Defensive: verify the rewrite actually produced content. The pipe
  # above can succeed (all three commands exit 0) yet write 0 bytes if
  # nlist hit a soft failure (e.g. wrong DISPLAY key under SSH X11
  # forwarding). Treat empty output as failure so the caller falls back
  # to leaving XAUTHORITY untouched rather than emitting an empty
  # cookie path into .env (which then makes the container mount a
  # 0-byte cookie and fail X11 auth silently).
  if [[ ! -s "${_out}" ]]; then
    _log_warn setup xauth_empty_cookie "display=xauth cookie rewrite produced an empty cookie file; XAUTHORITY left at host value."
    return 1
  fi
  printf '%s\n' "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# INI parser for setup.conf
#
# _parse_ini_section moved to lib/conf.sh in #402 (PR-B) so init.sh
# can reach it via _lib.sh without sourcing setup.sh. The function
# stays callable from this file via the same name (_lib.sh sources
# conf.sh in the umbrella loader near setup.sh's top).
# ════════════════════════════════════════════════════════════════════

# _load_setup_conf <base_path> <section> <keys_outvar> <values_outvar>
#
# Merges per-repo setup.conf with template default, section-replace
# strategy: if per-repo setup.conf has the section, use its entries;
# otherwise fall back to the template's section. SETUP_CONF env var forces
# a specific file (skips the merge entirely).
#
# #201: collapsed back to 2-file model. <repo>/setup.conf is the user
# override (committed, not gitignored, survives template upgrade because
# template subtree pull never touches it — it lives outside .base/).
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
  local _template_conf="${_self_dir}/../../../config/docker/setup.conf"
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
        _log_info setup conf_image_name_default "display=IMAGE_NAME using @default:${_found}" "default=${_found}"
      fi

      [[ -n "${_found}" ]] && break
    done
  fi

  if [[ -z "${_found}" ]]; then
    _log_warn setup conf_image_name_unknown "display=IMAGE_NAME could not be detected. Using 'unknown'."
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

# _detect_dri_groups
#   Echo space-separated unique numeric GIDs that own the host's
#   /dev/dri/{card*,renderD*} nodes (#496) so a container can be granted
#   /dev/dri access via group_add on non-NVIDIA (Intel/AMD iGPU) hosts.
#   Numeric GIDs only -- the render GID varies per host, so names are
#   non-portable. Echoes empty when /dev/dri is absent (graceful).
#   Env override SETUP_DETECT_DRI_GROUPS forces the result (used by tests
#   to avoid touching /dev/dri).
_detect_dri_groups() {
  if [[ -n "${SETUP_DETECT_DRI_GROUPS:-}" ]]; then
    printf '%s' "${SETUP_DETECT_DRI_GROUPS}"
    return 0
  fi
  local _gids
  # stat over a non-matching glob just yields no output (stderr suppressed);
  # sort -u dedups the common case where card* + renderD* share the video GID.
  _gids="$(stat -c %g /dev/dri/card* /dev/dri/renderD* 2>/dev/null \
             | sort -u | tr '\n' ' ')"
  printf '%s' "${_gids% }"
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
  local _template_conf="${_self_dir}/../../../config/docker/setup.conf"
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
  #    Forward-looking: sys / devel-base / devel / runtime-test
  #    Legacy (backward-compat during v0.21.x transition): base / test
  #    #493 (A1'-b): `devel-test` is NOT in this set — it is emitted as a
  #    compose service (legacy name `test`) through the per-stage
  #    inherit-with-override loop, so `[stage:devel-test]` gives it a
  #    runtime control surface (e.g. GPU pytest). The service name `test`
  #    stays blocklisted below so a Dockerfile `AS test` can't collide
  #    with devel-test's emitted service.
  case "${_stage}" in
    sys|devel-base|devel|runtime-test) return 2 ;;
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
      sys|devel-base|devel|runtime-test) continue ;;
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
# _generate_runtime_dockerfile <dockerfile> <env_str> <out>
#
# S3 of #497 (#503): bake the `[environment]` defaults as `ENV` into the
# runtime stage so a bare `docker run <runtime-image>` carries sane
# defaults with no env file -- delivery channel 1 (the only one that
# reaches the field). Copies <dockerfile> to <out>, inserting an
# `ENV KEY="VALUE"` block immediately after the `FROM ... AS runtime`
# line. <env_str> is the newline-separated `KEY=VALUE` [environment]
# list; cross-refs (`${KEY}`) are expanded against earlier siblings, the
# same way the compose `environment:` block does (#236).
#
# Returns 0 and writes <out> only when the Dockerfile declares an
# `AS runtime` stage AND <env_str> is non-empty; returns 1 (writes
# nothing) otherwise, so a repo with no runtime stage keeps building from
# the plain Dockerfile (zero behaviour change). The dev `.env` overlay
# (S2) and `deploy.sh -e` (S6) still override these baked defaults at run
# time, because container env_file / environment beats image `ENV`.
# ════════════════════════════════════════════════════════════════════
_generate_runtime_dockerfile() {
  local _dockerfile="${1:?}"
  local _env_str="${2:-}"
  local _out="${3:?}"

  [[ -f "${_dockerfile}" && -n "${_env_str}" ]] || return 1

  local _line _has_runtime=0
  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+runtime[[:space:]]*$ ]]; then
      _has_runtime=1
      break
    fi
  done < "${_dockerfile}"
  (( _has_runtime )) || return 1

  local -a _env_expanded=()
  _expand_env_cross_refs "${_env_str}" _env_expanded

  local _tmp
  _tmp="$(mktemp "${_out}.XXXXXX")"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if [[ "${_line}" =~ ^FROM[[:space:]]+[^[:space:]#]+[[:space:]]+AS[[:space:]]+runtime[[:space:]]*$ ]]; then
      printf '# >>> [environment] baked defaults (generated by setup.sh, #503) <<<\n' >> "${_tmp}"
      local _kv _k _v
      for _kv in "${_env_expanded[@]}"; do
        [[ -z "${_kv}" || "${_kv}" != *=* ]] && continue
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        printf 'ENV %s="%s"\n' "${_k}" "${_v}" >> "${_tmp}"
      done
    fi
  done < "${_dockerfile}"
  mv -- "${_tmp}" "${_out}"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _emit_docker_run_flags <flags_assoc> <out_array>
#
# S6 of #497 (#506): map a resolved docker-flag record to a `docker run`
# argv fragment for the self-contained field launcher (`deploy.sh`). The
# deploy generator resolves the chosen stage's flags through the S5
# layer (_resolve_docker_flags) and merges in the top-level-only fields,
# then calls this to turn that record into runnable `docker run` args.
#
# <flags_assoc> recognised keys (all optional; absent = unset):
#   privileged          "true" -> --privileged
#   gpu / gpu_count / gpu_caps
#                       gpu="true" -> --gpus (count>0 -> count=N[,capabilities=csv];
#                       else "all")
#   runtime             non-empty & not off/auto -> --runtime=<v>
#   net_mode / net_name host -> --network=host; bridge+name -> --network=<name>
#   ipc_mode            non-empty & != private -> --ipc=<v>
#   pid_mode            host -> --pid=host
#   shm_size            set & ipc_mode != host -> --shm-size=<v>
#   restart             set & != no -> --restart=<v>
#   volumes (nl list)   each -> -v <entry>
#   ports (nl list)     each -> -p <entry>  (only when net_mode=bridge)
#   devices (nl list)   plain -> --device <entry>; entry with a propagation
#                       mode (rslave/rshared/...) -> -v <entry> (docker run
#                       --device has no propagation, mirroring compose #450)
#   cap_add (nl list)   each -> --cap-add <cap>
#   cap_drop (nl list)  each -> --cap-drop <cap>
#   security_opt (nl)   each -> --security-opt <opt>
#   dri_groups (space)  each gid -> --group-add <gid>
#   cgroup_rules (nl)   each -> --device-cgroup-rule <rule>
#
# Deliberately NOT mapped: [environment] (baked into the image as ENV by
# S3, so the launcher carries only docker-level flags) and gui / X11 (the
# field launcher targets headless run; GUI is a dev-only compose concern).
# Each flag and its value are pushed as SEPARATE array elements so the
# caller can quote them individually when writing deploy.sh.
# ════════════════════════════════════════════════════════════════════
_emit_docker_run_flags() {
  local -n _edrf_f="${1:?"${FUNCNAME[0]}: missing flags assoc"}"
  local -n _edrf_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  local _item

  # Push "<flag> <item>" for each non-empty line of a newline-list value.
  _edrf_push_list() {
    local _flag="${1}" _list="${2}"
    [[ -n "${_list}" ]] || return 0
    while IFS= read -r _item; do
      [[ -n "${_item}" ]] || continue
      _edrf_out+=("${_flag}" "${_item}")
    done <<< "${_list}"
  }

  [[ "${_edrf_f["privileged"]:-}" == "true" ]] && _edrf_out+=("--privileged")

  if [[ "${_edrf_f["gpu"]:-}" == "true" ]]; then
    local _gc="${_edrf_f["gpu_count"]:-}" _gcaps="${_edrf_f["gpu_caps"]:-}" _spec
    if [[ "${_gc}" =~ ^[0-9]+$ ]] && (( _gc > 0 )); then
      _spec="count=${_gc}"
      [[ -n "${_gcaps}" ]] && _spec+=",capabilities=${_gcaps// /,}"
    else
      _spec="all"
    fi
    _edrf_out+=("--gpus" "${_spec}")
  fi

  local _rt="${_edrf_f["runtime"]:-}"
  if [[ -n "${_rt}" && "${_rt}" != "off" && "${_rt}" != "auto" ]]; then
    _edrf_out+=("--runtime=${_rt}")
  fi

  local _nm="${_edrf_f["net_mode"]:-}" _nn="${_edrf_f["net_name"]:-}"
  if [[ "${_nm}" == "host" ]]; then
    _edrf_out+=("--network=host")
  elif [[ "${_nm}" == "bridge" && -n "${_nn}" ]]; then
    _edrf_out+=("--network=${_nn}")
  fi

  local _ipc="${_edrf_f["ipc_mode"]:-}"
  [[ -n "${_ipc}" && "${_ipc}" != "private" ]] && _edrf_out+=("--ipc=${_ipc}")

  [[ "${_edrf_f["pid_mode"]:-}" == "host" ]] && _edrf_out+=("--pid=host")

  local _shm="${_edrf_f["shm_size"]:-}"
  [[ -n "${_shm}" && "${_ipc}" != "host" ]] && _edrf_out+=("--shm-size=${_shm}")

  local _rs="${_edrf_f["restart"]:-}"
  [[ -n "${_rs}" && "${_rs}" != "no" ]] && _edrf_out+=("--restart=${_rs}")

  _edrf_push_list "-v" "${_edrf_f["volumes"]:-}"

  if [[ "${_nm}" == "bridge" ]]; then
    _edrf_push_list "-p" "${_edrf_f["ports"]:-}"
  fi

  # Devices: a propagation mode in the 3rd colon field cannot ride on
  # `docker run --device`, so route those to `-v` (mirrors the compose
  # device->volume redirect from #450); plain devices stay on --device.
  local _dev
  if [[ -n "${_edrf_f["devices"]:-}" ]]; then
    while IFS= read -r _dev; do
      [[ -n "${_dev}" ]] || continue
      if [[ "${_dev}" =~ :(rslave|rshared|rprivate|slave|shared|private)([,:]|$) ]]; then
        _edrf_out+=("-v" "${_dev}")
      else
        _edrf_out+=("--device" "${_dev}")
      fi
    done <<< "${_edrf_f["devices"]}"
  fi

  _edrf_push_list "--cap-add" "${_edrf_f["cap_add"]:-}"
  _edrf_push_list "--cap-drop" "${_edrf_f["cap_drop"]:-}"
  _edrf_push_list "--security-opt" "${_edrf_f["security_opt"]:-}"

  local _gid
  if [[ -n "${_edrf_f["dri_groups"]:-}" ]]; then
    for _gid in ${_edrf_f["dri_groups"]}; do
      _edrf_out+=("--group-add" "${_gid}")
    done
  fi

  _edrf_push_list "--device-cgroup-rule" "${_edrf_f["cgroup_rules"]:-}"

  unset -f _edrf_push_list
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context <base_path> <out_assoc>
#
# S6b of #497 (#506): the single conf-derived resolution layer shared by
# `apply` (the compose renderer) and the deploy generator. Loads the
# relevant setup.conf sections from <base_path> and resolves the
# scalar modes + aggregated list strings that both paths consume, into
# <out_assoc>. This is the global counterpart to the per-stage
# _resolve_docker_flags (S5): apply unpacks the record into its existing
# locals, and the deploy generator (S6b-gen) feeds it as the parent for
# the runtime stage. Keeping one resolver means the field deploy can
# never drift from what `apply` would produce for the same setup.conf.
#
# Pure resolution: it does NOT apply the `--gui` CLI / SETUP_GUI env
# override (apply layers that on top of the returned gui_mode), it does
# NOT resolve the detection-dependent enabled booleans (callers run
# _resolve_gpu / _resolve_gui with their own host detection), and it does
# NOT touch the WS_PATH / mount_1 migration or the #450 device/volume
# validation warnings (those stay apply-side -- dev-specific side
# effects). The one intrinsic side effect kept here is the legacy
# `[deploy] runtime` deprecation warning (#481), since it is tied to
# resolving gpu_runtime from the conf.
#
# Populated keys: build_network gpu_mode gpu_count gpu_caps
#   gpu_runtime_mode gui_mode net_mode ipc_mode pid_mode network_name
#   privileged restart_policy dri_groups_str devices_str cgroup_rule_str
#   env_str tmpfs_str ports_str cap_add_str cap_drop_str sec_opt_str
#   shm_size  (assoc subscripts quoted so ShellCheck does not read them
#   as arithmetic refs (SC2154) -- the out-param is a nameref).
# ════════════════════════════════════════════════════════════════════
_resolve_deploy_context() {
  local _rdc_base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _rdc_out="${2:?"${FUNCNAME[0]}: missing out assoc"}"

  local -a _b_k=() _b_v=() _d_k=() _d_v=() _g_k=() _g_v=() _n_k=() _n_v=()
  local -a _s_k=() _s_v=() _l_k=() _l_v=() _r_k=() _r_v=() _e_k=() _e_v=()
  local -a _t_k=() _t_v=() _dv_k=() _dv_v=()
  _load_setup_conf "${_rdc_base}" "build"       _b_k  _b_v
  _load_setup_conf "${_rdc_base}" "deploy"      _d_k  _d_v
  _load_setup_conf "${_rdc_base}" "gui"         _g_k  _g_v
  _load_setup_conf "${_rdc_base}" "network"     _n_k  _n_v
  _load_setup_conf "${_rdc_base}" "security"    _s_k  _s_v
  _load_setup_conf "${_rdc_base}" "lifecycle"   _l_k  _l_v
  _load_setup_conf "${_rdc_base}" "resources"   _r_k  _r_v
  _load_setup_conf "${_rdc_base}" "environment" _e_k  _e_v
  _load_setup_conf "${_rdc_base}" "tmpfs"       _t_k  _t_v
  _load_setup_conf "${_rdc_base}" "devices"     _dv_k _dv_v

  local _tmp=""

  # build-time network (scalar [build] network; auto -> host on Jetson).
  local _build_network_mode="" _build_network=""
  _get_conf_value _b_k _b_v "network" "auto" _build_network_mode
  _resolve_build_network "${_build_network_mode}" _build_network
  _rdc_out["build_network"]="${_build_network}"

  # [deploy] GPU family.
  _get_conf_value _d_k _d_v "gpu_mode"         "auto" _tmp; _rdc_out["gpu_mode"]="${_tmp}"
  _get_conf_value _d_k _d_v "gpu_count"        "all"  _tmp; _rdc_out["gpu_count"]="${_tmp}"
  _get_conf_value _d_k _d_v "gpu_capabilities" "gpu"  _tmp; _rdc_out["gpu_caps"]="${_tmp}"
  # #481: gpu_runtime is the canonical key; legacy `runtime` is a permanent
  # alias (W3) consumed with a deprecation warning, removed at v1.0.0.
  local _gpu_runtime_mode=""
  _get_conf_value _d_k _d_v "gpu_runtime" "" _gpu_runtime_mode
  if [[ -z "${_gpu_runtime_mode}" ]]; then
    local _legacy_runtime=""
    _get_conf_value _d_k _d_v "runtime" "" _legacy_runtime
    if [[ -n "${_legacy_runtime}" ]]; then
      _gpu_runtime_mode="${_legacy_runtime}"
      _log_warn setup conf_runtime_key_deprecated \
        "display=$(_setup_msg deploy runtime_deprecated)"
    else
      _gpu_runtime_mode="auto"
    fi
  fi
  _rdc_out["gpu_runtime_mode"]="${_gpu_runtime_mode}"

  # [gui] mode (conf only -- caller layers the --gui / SETUP_GUI override).
  _get_conf_value _g_k _g_v "mode" "auto" _tmp; _rdc_out["gui_mode"]="${_tmp}"

  # [network] + [security] scalars.
  _get_conf_value _n_k _n_v "mode"         "host"    _tmp; _rdc_out["net_mode"]="${_tmp}"
  _get_conf_value _n_k _n_v "ipc"          "host"    _tmp; _rdc_out["ipc_mode"]="${_tmp}"
  _get_conf_value _n_k _n_v "pid"          "private" _tmp; _rdc_out["pid_mode"]="${_tmp}"
  _get_conf_value _n_k _n_v "network_name" ""        _tmp; _rdc_out["network_name"]="${_tmp}"
  # #466: privileged opt-in -- default false when the key is absent.
  _get_conf_value _s_k _s_v "privileged"   "false"   _tmp; _rdc_out["privileged"]="${_tmp}"

  # #478: [lifecycle] restart policy (default no).
  _get_conf_value _l_k _l_v "restart" "no" _tmp; _rdc_out["restart_policy"]="${_tmp}"

  # #496: dri_groups (non-NVIDIA iGPU /dev/dri); auto -> detect host GIDs.
  local _dri_groups_mode="" _dri_groups_str=""
  _get_conf_value _d_k _d_v "dri_groups" "auto" _dri_groups_mode
  [[ "${_dri_groups_mode}" == "auto" ]] && _dri_groups_str="$(_detect_dri_groups)"
  _rdc_out["dri_groups_str"]="${_dri_groups_str}"

  # [devices] device_* + cgroup_rule_*.
  local -a _devices_arr=() _cgroup_rule_arr=()
  _get_conf_list_sorted _dv_k _dv_v "device_"      _devices_arr
  _get_conf_list_sorted _dv_k _dv_v "cgroup_rule_" _cgroup_rule_arr
  local _devices_str="" _cgroup_rule_str=""
  (( ${#_devices_arr[@]}      > 0 )) && _devices_str="$(printf '%s\n' "${_devices_arr[@]}")"
  (( ${#_cgroup_rule_arr[@]}  > 0 )) && _cgroup_rule_str="$(printf '%s\n' "${_cgroup_rule_arr[@]}")"
  _rdc_out["devices_str"]="${_devices_str}"
  _rdc_out["cgroup_rule_str"]="${_cgroup_rule_str}"

  # [environment] env_*, [tmpfs] tmpfs_*, [network] port_*.
  local -a _env_arr=() _tmpfs_arr=() _ports_arr=()
  _get_conf_list_sorted _e_k _e_v "env_"   _env_arr
  _get_conf_list_sorted _t_k _t_v "tmpfs_" _tmpfs_arr
  _get_conf_list_sorted _n_k _n_v "port_"  _ports_arr
  local _env_str="" _tmpfs_str="" _ports_str=""
  (( ${#_env_arr[@]}   > 0 )) && _env_str="$(printf '%s\n'   "${_env_arr[@]}")"
  (( ${#_tmpfs_arr[@]} > 0 )) && _tmpfs_str="$(printf '%s\n' "${_tmpfs_arr[@]}")"
  (( ${#_ports_arr[@]} > 0 )) && _ports_str="$(printf '%s\n' "${_ports_arr[@]}")"
  _rdc_out["env_str"]="${_env_str}"
  _rdc_out["tmpfs_str"]="${_tmpfs_str}"
  _rdc_out["ports_str"]="${_ports_str}"

  # [security] cap_add_*, cap_drop_*, security_opt_* with template fallback:
  # a per-repo [security] that wipes a list falls back to the template
  # baseline rather than Docker's stripped default (#466 rationale).
  local -a _cap_add_arr=() _cap_drop_arr=() _sec_opt_arr=()
  _get_conf_list_sorted _s_k _s_v "cap_add_"      _cap_add_arr
  _get_conf_list_sorted _s_k _s_v "cap_drop_"     _cap_drop_arr
  _get_conf_list_sorted _s_k _s_v "security_opt_" _sec_opt_arr
  local _tpl_setup_conf
  _tpl_setup_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
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
  _rdc_out["cap_add_str"]="${_cap_add_str}"
  _rdc_out["cap_drop_str"]="${_cap_drop_str}"
  _rdc_out["sec_opt_str"]="${_sec_opt_str}"

  # [resources] shm_size (only meaningful when ipc != host).
  _get_conf_value _r_k _r_v "shm_size" "" _tmp; _rdc_out["shm_size"]="${_tmp}"
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
#   [network]     mode, ipc, pid, network_name, port_<N>, port_inherit
#   [security]    privileged, cap_add_<N>, cap_add_inherit,
#                 cap_drop_<N>, cap_drop_inherit,
#                 security_opt_<N>, security_opt_inherit
#   [volumes]     mount_<N>, mount_inherit
#   [environment] env_<N>, env_inherit
#
# security cap_add / cap_drop / security_opt (#526): added in v2 once a
# real downstream need surfaced (jetson_sdk_manager#69 — per-stage caps so
# a read-only probe stage drops the flash stage's SYS_ADMIN). Same
# append-by-default / *_inherit=false-replaces list convention as
# volumes / env / ports.
#
# Excluded by design:
#   [image_name] / [build] / [devices] / [tmpfs] /
#   [additional_contexts] / [resources] — outside the "Isaac Sim
#   per-stage runtime" use case driving #220. Re-evaluate once a real
#   downstream need surfaces.
_validate_stage_override_key() {
  local _key="${1:?"${FUNCNAME[0]}: missing key"}"
  case "${_key}" in
    deploy.gpu_mode|deploy.gpu_count|deploy.gpu_capabilities|deploy.gpu_runtime|deploy.runtime) return 0 ;;
    gui.mode) return 0 ;;
    network.mode|network.ipc|network.pid|network.network_name) return 0 ;;
    security.privileged) return 0 ;;
    network.port_inherit|volumes.mount_inherit|environment.env_inherit) return 0 ;;
    security.cap_add_inherit|security.cap_drop_inherit|security.security_opt_inherit) return 0 ;;
  esac
  if [[ "${_key}" =~ ^(network\.port|volumes\.mount|environment\.env|security\.cap_add|security\.cap_drop|security\.security_opt)_[0-9]+$ ]]; then
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

# _resolve_docker_flags <stage_keys> <stage_values> <parent_assoc> <out_assoc>
#
# THE single per-stage docker-flag resolution layer (#505). Given one
# stage's [stage:<name>] overrides (already filtered to the allowlist)
# layered over the parent (devel / top-level) already-resolved values,
# it computes the stage's effective docker flags into <out_assoc>.
#
# Both renderers call this so per-stage semantics never drift:
#   - the compose renderer (generate_compose_yaml's per-stage loop), and
#   - the deploy renderer (S6 #506), which resolves the runtime stage's
#     flags to emit a field docker-run launcher.
#
# Modes (gui / gpu) inherit the parent's already-resolved boolean unless
# the stage forces off / force — per-stage does NOT re-detect hardware
# (that host-specific detection is the global resolution's job, upstream
# of this layer). Other scalars fall back to the parent's effective
# value; list fields (volumes / environment / ports) delegate to
# _resolve_stage_list (append-by-default, replace on `*_inherit = false`).
#
# Args:
#   $1 stage_keys    (array ref)  filtered [stage:*] override keys
#   $2 stage_values  (array ref)  parallel override values
#   $3 parent        (assoc ref)  parent fallbacks + top-level lists:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name volumes_top env_top ports_top
#        cap_add_top cap_drop_top sec_opt_top
#   $4 out           (assoc ref)  effective record, keys:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name privileged volumes environment ports
#        cap_add cap_drop security_opt
_resolve_docker_flags() {
  local -n _rdf_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rdf_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local -n _rdf_parent="${3:?"${FUNCNAME[0]}: missing parent assoc"}"
  local -n _rdf_out="${4:?"${FUNCNAME[0]}: missing out assoc"}"
  local _mode _tmp

  # gui / gpu: off|force decide outright; anything else (incl. absent or
  # "auto") inherits the parent's already-resolved boolean. Assoc-array
  # subscripts are quoted as string literals so ShellCheck does not read
  # them as arithmetic variable references (SC2154) -- _rdf_out is a
  # nameref, so ShellCheck cannot infer it is associative.
  _resolve_stage_scalar _rdf_keys _rdf_values "gui.mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gui"]="false" ;;
    force) _rdf_out["gui"]="true" ;;
    *)     _rdf_out["gui"]="${_rdf_parent["gui"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gpu"]="false" ;;
    force) _rdf_out["gpu"]="true" ;;
    *)     _rdf_out["gpu"]="${_rdf_parent["gpu"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_count" "${_rdf_parent["gpu_count"]}" _tmp
  _rdf_out["gpu_count"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_capabilities" "${_rdf_parent["gpu_caps"]}" _tmp
  _rdf_out["gpu_caps"]="${_tmp}"

  # #481: gpu_runtime primary, legacy deploy.runtime alias as fallback.
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_runtime" "${_rdf_parent["runtime"]}" _tmp
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.runtime" "${_tmp}" _tmp
  _rdf_out["runtime"]="${_tmp}"

  _resolve_stage_scalar _rdf_keys _rdf_values "network.mode" "${_rdf_parent["net_mode"]}" _tmp
  _rdf_out["net_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.ipc" "${_rdf_parent["ipc_mode"]}" _tmp
  _rdf_out["ipc_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.pid" "${_rdf_parent["pid_mode"]}" _tmp
  _rdf_out["pid_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.network_name" "${_rdf_parent["net_name"]}" _tmp
  _rdf_out["net_name"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "security.privileged" "" _tmp
  _rdf_out["privileged"]="${_tmp}"

  _resolve_stage_list _rdf_keys _rdf_values "volumes.mount_" "volumes.mount_inherit" "${_rdf_parent["volumes_top"]}" _tmp
  _rdf_out["volumes"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "environment.env_" "environment.env_inherit" "${_rdf_parent["env_top"]}" _tmp
  _rdf_out["environment"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "network.port_" "network.port_inherit" "${_rdf_parent["ports_top"]}" _tmp
  _rdf_out["ports"]="${_tmp}"

  # #526: per-stage [security] cap_add / cap_drop / security_opt as list
  # fields, same append-by-default / *_inherit=false-replaces convention as
  # volumes / env / ports above. A stage sets `cap_add_inherit = false`
  # (and lists no entries) to drop all inherited caps — e.g. a read-only
  # probe stage that should not inherit the flash stage's SYS_ADMIN.
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_add_" "security.cap_add_inherit" "${_rdf_parent["cap_add_top"]}" _tmp
  _rdf_out["cap_add"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_drop_" "security.cap_drop_inherit" "${_rdf_parent["cap_drop_top"]}" _tmp
  _rdf_out["cap_drop"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.security_opt_" "security.security_opt_inherit" "${_rdf_parent["sec_opt_top"]}" _tmp
  _rdf_out["security_opt"]="${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_sh <base_path> <stage> <image_ref> <container_name> <out>
#
# S6b-gen of #497 (#506): write a self-contained `docker run` field
# launcher (`deploy.sh`) for the baked <stage> image. Ties the three
# resolution layers together:
#   _resolve_deploy_context  (global conf, S6b) -> the stage parent
#   _resolve_docker_flags    (per-stage overrides, S5) -> effective record
#   _emit_docker_run_flags   (S6a) -> the `docker run` argv fragment
#
# The launcher carries only docker-level flags. By design it omits:
#   - environment (-e): [environment] is baked into the image as ENV (S3);
#   - volumes (-v): bind mounts reference dev-host paths absent in the
#     field, and structured config is COPY-baked (S4); so the field image
#     is self-contained.
# GPU enablement is resolved with the generating host's detection (same as
# apply); the runtime stage's [stage:runtime] overrides still apply. The
# image / container name are overridable at run time via DEPLOY_IMAGE /
# DEPLOY_CONTAINER_NAME, and trailing args are appended to the container
# command. The generated file is chmod +x and ShellCheck-clean.
#
# Consumed by the S6 bundle orchestrator (S6c): build --target <stage> ->
# docker save -> tar.xz {image, deploy.sh}.
# ════════════════════════════════════════════════════════════════════
_generate_deploy_sh() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _image_ref="${3:?"${FUNCNAME[0]}: missing image_ref"}"
  local _container_name="${4:?"${FUNCNAME[0]}: missing container_name"}"
  local _out="${5:?"${FUNCNAME[0]}: missing out path"}"

  # Global conf context (shared with apply via S6b).
  local -A _ctx=()
  _resolve_deploy_context "${_base}" _ctx

  # Detection-dependent enabled state + runtime, resolved like apply does.
  local _gpu_detected="" _gpu_enabled="" _runtime_resolved=""
  detect_gpu _gpu_detected
  _resolve_gpu "${_ctx["gpu_mode"]}" "${_gpu_detected}" _gpu_enabled
  _resolve_runtime "${_ctx["gpu_runtime_mode"]}" _runtime_resolved

  # Per-stage [stage:<stage>] overrides, filtered to the allowlist.
  local -a _so_k=() _so_v=() _sof_k=() _sof_v=()
  _load_stage_overrides "${_base}" "${_stage}" _so_k _so_v
  local _ki
  for (( _ki = 0; _ki < ${#_so_k[@]}; _ki++ )); do
    if _validate_stage_override_key "${_so_k[_ki]}"; then
      _sof_k+=("${_so_k[_ki]}")
      _sof_v+=("${_so_v[_ki]}")
    fi
  done

  # Parent record for the per-stage resolver. gui is forced off (the field
  # launcher is headless); volumes_top / env_top are empty so the field run
  # carries no bind mounts and no -e (baked ENV instead).
  local -A _parent=(
    [gui]="false"
    [gpu]="${_gpu_enabled}"
    [gpu_count]="${_ctx["gpu_count"]}"
    [gpu_caps]="${_ctx["gpu_caps"]}"
    [runtime]="${_runtime_resolved}"
    [net_mode]="${_ctx["net_mode"]}"
    [ipc_mode]="${_ctx["ipc_mode"]}"
    [pid_mode]="${_ctx["pid_mode"]}"
    [net_name]="${_ctx["network_name"]}"
    [volumes_top]=""
    [env_top]=""
    [ports_top]="${_ctx["ports_str"]}"
    [cap_add_top]="${_ctx["cap_add_str"]}"
    [cap_drop_top]="${_ctx["cap_drop_str"]}"
    [sec_opt_top]="${_ctx["sec_opt_str"]}"
  )
  local -A _eff=()
  _resolve_docker_flags _sof_k _sof_v _parent _eff

  # Merge the per-stage effective scalars with the top-level-only fields
  # (devices / caps / security_opt / shm / dri / cgroup / restart) into the
  # record _emit_docker_run_flags maps. volumes / environment are omitted.
  # privileged: _resolve_docker_flags only fills it from a [stage:*]
  # security.privileged override (empty otherwise, since compose carries the
  # global value via the devel `${PRIVILEGED}` env var). The field launcher
  # has no such env layer, so fall back to the global [security] privileged.
  local -A _flags=(
    [privileged]="${_eff["privileged"]:-${_ctx["privileged"]}}"
    [gpu]="${_eff["gpu"]}"
    [gpu_count]="${_eff["gpu_count"]}"
    [gpu_caps]="${_eff["gpu_caps"]}"
    [runtime]="${_eff["runtime"]}"
    [net_mode]="${_eff["net_mode"]}"
    [net_name]="${_eff["net_name"]}"
    [ipc_mode]="${_eff["ipc_mode"]}"
    [pid_mode]="${_eff["pid_mode"]}"
    [ports]="${_eff["ports"]}"
    [shm_size]="${_ctx["shm_size"]}"
    [restart]="${_ctx["restart_policy"]}"
    [devices]="${_ctx["devices_str"]}"
    [cap_add]="${_eff["cap_add"]}"
    [cap_drop]="${_eff["cap_drop"]}"
    [security_opt]="${_eff["security_opt"]}"
    [dri_groups]="${_ctx["dri_groups_str"]}"
    [cgroup_rules]="${_ctx["cgroup_rule_str"]}"
  )
  local -a _argv=()
  _emit_docker_run_flags _flags _argv

  # Emit deploy.sh. Runtime-expanded vars / backticks are escaped so they
  # land literally in the generated script; per-arg %q quoting keeps each
  # flag a single, safely-quoted token.
  {
    cat <<EOF
#!/usr/bin/env bash
# AUTO-GENERATED field deployment launcher (setup.sh S6, #506). DO NOT EDIT.
#
# Self-contained \`docker run\` launcher for the baked \`${_stage}\` image.
# The docker-level flags below are inlined from the resolved \`${_stage}\`
# stage of setup.conf; [environment] defaults and structured config are
# baked into the image (S3/S4), so no env file or config bind travels.
# Field flow: \`docker load < <image>.tar\` then \`./deploy.sh\`.
#
# Overrides: DEPLOY_IMAGE / DEPLOY_CONTAINER_NAME env vars; any args after
# \`./deploy.sh\` are appended to the container command. Note: --group-add
# GIDs (iGPU /dev/dri) are from the generating host and may need adjusting
# on a different field machine.
set -euo pipefail

IMAGE="\${DEPLOY_IMAGE:-${_image_ref}}"
CONTAINER_NAME="\${DEPLOY_CONTAINER_NAME:-${_container_name}}"

exec docker run \\
  --detach \\
  --name "\${CONTAINER_NAME}" \\
EOF
    local _a
    for _a in "${_argv[@]}"; do
      printf '  %q \\\n' "${_a}"
    done
    # SC2016: the ${IMAGE} / "$@" tokens are emitted verbatim into the
    # generated deploy.sh and expand at field run time, not here.
    # shellcheck disable=SC2016
    printf '  "${IMAGE}" \\\n'
    # shellcheck disable=SC2016
    printf '  "$@"\n'
  } > "${_out}"
  chmod +x "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _bake_config_copy <src_dockerfile> <stage> <out>
#
# S4 deploy half (#504/#506): splice `COPY config/app /opt/app/config`
# into the <stage> stage of <src_dockerfile>, writing the result to <out>.
# The dev side bind-mounts config/app (apply); the field image bakes it in
# as an immutable layer so the deploy bundle is self-contained. Insert is
# right after the `FROM ... AS <stage>` line (handles src == out via a
# temp file). Caller only invokes this when <base>/config/app exists.
# ════════════════════════════════════════════════════════════════════
_bake_config_copy() {
  local _src="${1:?"${FUNCNAME[0]}: missing src dockerfile"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _out="${3:?"${FUNCNAME[0]}: missing out"}"
  local _tmp _line
  _tmp="$(mktemp)"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if [[ "${_line}" =~ ^FROM[[:space:]].*[[:space:]]AS[[:space:]]+"${_stage}"[[:space:]]*$ ]]; then
      printf '# >>> config/app baked (generated by setup.sh, #504/#506) <<<\n' >> "${_tmp}"
      printf 'COPY config/app /opt/app/config\n' >> "${_tmp}"
    fi
  done < "${_src}"
  mv -- "${_tmp}" "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_bundle <base_path> <stage> <out_bundle>
#
# S6c of #497 (#506): orchestrate the self-contained field bundle.
#   1. resolve image name + [environment] defaults
#   2. _generate_runtime_dockerfile -> baked-ENV Dockerfile (S3); falls
#      back to the plain Dockerfile when there is no runtime stage / no
#      [environment]
#   3. _bake_config_copy -> COPY config/app into the image when present (S4)
#   4. docker build --target <stage> -t <name>:<stage>
#   5. _generate_deploy_sh -> deploy.sh (S6b-gen)
#   6. docker save -> image.tar
#   7. tar -cJf <out_bundle> image.tar deploy.sh  (the tar.xz field bundle)
#
# The generated Dockerfile + deploy.sh are written under a temp dir (no
# repo side effect; `docker build -f <tmp> <base>` keeps the build context
# at the repo). The docker / tar steps go through _dry_run_cmd, so
# DRY_RUN=true prints the plan without building. Field flow: extract the
# bundle, `docker load < image.tar`, `./deploy.sh`.
# ════════════════════════════════════════════════════════════════════
_generate_deploy_bundle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _bundle="${3:?"${FUNCNAME[0]}: missing out_bundle"}"

  local _name=""
  BASE_PATH="${_base}" detect_image_name _name "${_base}"
  local _image="${_name}:${_stage}"
  local _container="${_name}-${_stage}"

  local -A _ctx=()
  _resolve_deploy_context "${_base}" _ctx

  local _work
  _work="$(mktemp -d)"
  local _gen="${_work}/Dockerfile.deploy"
  local _build_dockerfile="${_base}/Dockerfile"

  # Bake [environment] as ENV into the runtime stage (S3). On no-op (no
  # runtime stage / empty env) keep the plain Dockerfile.
  if _generate_runtime_dockerfile "${_base}/Dockerfile" "${_ctx["env_str"]}" "${_gen}"; then
    _build_dockerfile="${_gen}"
  fi
  # Bake config/app into the image (S4 deploy half) when the repo ships it.
  if [[ -d "${_base}/config/app" ]]; then
    _bake_config_copy "${_build_dockerfile}" "${_stage}" "${_gen}"
    _build_dockerfile="${_gen}"
  fi

  # Generate the field launcher up front so the plan is inspectable even
  # under DRY_RUN (the docker/tar steps below are the only guarded ones).
  _generate_deploy_sh "${_base}" "${_stage}" "${_image}" "${_container}" "${_work}/deploy.sh"

  local _rc=0
  _dry_run_cmd docker build --target "${_stage}" \
    -f "${_build_dockerfile}" -t "${_image}" "${_base}" || _rc=$?
  if (( _rc == 0 )); then
    _dry_run_cmd docker save -o "${_work}/image.tar" "${_image}" || _rc=$?
  fi
  if (( _rc == 0 )); then
    _dry_run_cmd tar -C "${_work}" -cJf "${_bundle}" image.tar deploy.sh || _rc=$?
  fi

  rm -rf "${_work}"
  return "${_rc}"
}

# _parse_logging_svc_sections / _collect_logging moved to
# lib/conf_logging.sh in #402 (PR-A) so both setup.sh and the
# upcoming PR-B gitignore sync (lib/gitignore.sh) can share them
# without circular sourcing. _lib.sh now pulls conf_logging.sh in
# automatically, so callers below still resolve the same names.

# _sync_logging_local_paths_gitignore moved to lib/gitignore.sh in
# #402 (PR-B) and renamed _sync_logging_gitignore (now takes only
# <base_path>, calls _collect_logging itself). Sync runs at
# init.sh / upgrade.sh time instead of every setup.sh apply, so
# the file stays in step across template versions even when no
# wrapper has fired since the last setup.conf edit.

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

# _write_runtime_env was retired in S7 (#507): runtime.env (#462) is
# superseded by the S3 baked ENV (in-container) + .env.generated/.env
# (host-side helpers source these instead).

_device_has_propagation() {
  local _entry="${1}"
  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_entry}"
  (( ${#_parts[@]} == 3 )) || return 1
  [[ "${_parts[2]}" =~ (rslave|rshared|rprivate|slave|shared|private) ]]
}

_emit_device_as_volume() {
  local _entry="${1}" _indent="${2:-    }"
  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_entry}"
  local _src="${_parts[0]}" _tgt="${_parts[1]}" _opts="${_parts[2]}"
  local _propagation="" _read_only=""
  local _o
  IFS=',' read -ra _oarr <<< "${_opts}"
  for _o in "${_oarr[@]}"; do
    case "${_o}" in
      ro) _read_only="true" ;;
      rw) _read_only="false" ;;
      rslave|rshared|rprivate|slave|shared|private) _propagation="${_o}" ;;
    esac
  done
  echo "${_indent}  - type: bind"
  echo "${_indent}    source: ${_src}"
  echo "${_indent}    target: ${_tgt}"
  [[ -n "${_read_only}" ]] && echo "${_indent}    read_only: ${_read_only}"
  echo "${_indent}    bind:"
  echo "${_indent}      propagation: ${_propagation}"
}

# _classify_volume_lhs <mount_string>
#
# Classify a `host:container[:mode]` mount by its left-hand side (#482,
# Option A / D-Strict). A LHS that looks like a path -- starts with `/`,
# `./`, `~/`, or a `${...}` variable reference -- is a bind mount; anything
# else is a Docker named-volume reference. Echoes `bind` or `named`.
_classify_volume_lhs() {
  # The `~/` and `${` globs are single-quoted so they stay literal: an
  # unquoted `~/*` case pattern undergoes tilde expansion (to $HOME/*) and
  # would never match a literal `~/...` LHS; an unquoted `${`-glob is fine
  # but quoting keeps both path-prefix markers consistent and silences
  # SC2016 (the literal `${` is intentional -- a `${VAR}` LHS is a bind path).
  # shellcheck disable=SC2016,SC2088
  case "${1%%:*}" in
    /*|./*|'~/'*|'${'*) printf 'bind\n' ;;
    *)                 printf 'named\n' ;;
  esac
}

# _collect_named_volumes <assoc_array_name> <newline_separated_mounts>
#
# Add the named-volume names from <mounts> into the associative array used
# as a set (key = volume name, the LHS before the first `:`, which already
# excludes any `:mode` suffix). Bind mounts are skipped.
_collect_named_volumes() {
  local -n _cnv_set="$1"
  local _line
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    [[ "$(_classify_volume_lhs "${_line}")" == named ]] || continue
    _cnv_set["${_line%%:*}"]=1
  done <<< "$2"
}

# _emit_volumes_block <assoc_array_name>
#
# Emit a top-level `volumes:` declaration with one bare stub per collected
# named volume (no driver / labels / options -> Docker's default `local`
# driver). Emits nothing when the set is empty (zero-diff for bind-only
# repos). Names are sorted for deterministic output.
_emit_volumes_block() {
  local -n _evb_set="$1"
  (( ${#_evb_set[@]} == 0 )) && return 0
  printf '\nvolumes:\n'
  local _k
  while IFS= read -r _k; do
    printf '  %s:\n' "${_k}"
  done < <(printf '%s\n' "${!_evb_set[@]}" | sort)
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
  local _pid_mode="${16:-private}"
  local _cap_add_str="${17:-}"
  local _cap_drop_str="${18:-}"
  local _sec_opt_str="${19:-}"
  local _cgroup_rule_str="${20:-}"
  local _user_build_args_str="${21:-}"
  local _target_arch="${22:-}"
  local _build_network="${23:-}"
  local _runtime="${24:-}"
  local _additional_contexts_str="${25:-}"
  local _logging_global_str="${26:-}"
  local _logging_per_svc_str="${27:-}"
  local _restart="${28:-no}"
  local _dri_groups_str="${29:-}"

  # _logging_svc_kv <svc> <out_assoc_name>
  #
  # Resolve effective logging KV map for compose service <svc>:
  #   1. seed with global [logging] entries (`_logging_global_str`)
  #   2. overlay per-service [logging.<svc>] entries — key-level merge
  #
  # If both inputs are empty the map stays empty and the emitter
  # downstream skips the `logging:` block entirely (back-compat with
  # downstream repos that haven't adopted [logging] yet).
  _logging_svc_kv() {
    local _svc="$1"
    local -n _lkv="$2"
    _lkv=()
    local _line _k _v
    if [[ -n "${_logging_global_str}" ]]; then
      while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        _k="${_line%%=*}"
        _v="${_line#*=}"
        _lkv["${_k}"]="${_v}"
      done <<< "${_logging_global_str}"
    fi
    if [[ -n "${_logging_per_svc_str}" ]]; then
      while IFS= read -r _line; do
        [[ -z "${_line}" ]] && continue
        [[ "${_line%%:*}" == "${_svc}" ]] || continue
        _line="${_line#*:}"
        _k="${_line%%=*}"
        _v="${_line#*=}"
        _lkv["${_k}"]="${_v}"
      done <<< "${_logging_per_svc_str}"
    fi
  }

  # _emit_logging_block <svc>
  #
  # Emit compose `logging:` mapping for service <svc>. Maps four
  # setup.conf keys (driver / max_size / max_file / compress) to the
  # corresponding Docker compose option names (driver as scalar;
  # max-size / max-file / compress as `options:` sub-keys, dash-named
  # per Docker docs). The 5th key, `local_path`, is **not** a Docker
  # logging option -- it triggers a per-service volume bind via
  # `_logging_svc_local_path_mount` (emitted from each service's
  # `volumes:` block), so this function deliberately ignores it.
  # No-op when no docker-option key is set on this service.
  _emit_logging_block() {
    local _svc="$1"
    local -A _kv=()
    _logging_svc_kv "${_svc}" _kv
    local _have_opts=0 _k
    for _k in driver max_size max_file compress; do
      [[ -n "${_kv[${_k}]:-}" ]] && _have_opts=1 && break
    done
    (( _have_opts == 0 )) && return 0
    echo "    logging:"
    [[ -n "${_kv[driver]:-}" ]] && echo "      driver: ${_kv[driver]}"
    local _opts=0
    for _k in max_size max_file compress; do
      [[ -n "${_kv[${_k}]:-}" ]] && _opts=1 && break
    done
    if (( _opts )); then
      echo "      options:"
      [[ -n "${_kv[max_size]:-}" ]] && echo "        max-size: \"${_kv[max_size]}\""
      [[ -n "${_kv[max_file]:-}" ]] && echo "        max-file: \"${_kv[max_file]}\""
      [[ -n "${_kv[compress]:-}" ]] && echo "        compress: \"${_kv[compress]}\""
    fi
    return 0
  }

  # _logging_svc_local_path_mount <svc> <out_var>
  #
  # Resolves the effective `local_path` for service <svc> against the
  # repo base directory and emits a compose volume mount string
  # `<host>:/var/log/<repo>` (no leading indentation; caller decides
  # placement). Empty out when local_path is unset or empty.
  #
  # Path semantics (from #328):
  #   ./logs/     relative to repo root (dirname of generated compose.yaml)
  #   /abs/path/  used verbatim
  #   ~/dir/      ~ expanded against $HOME
  #   (empty)     feature disabled, no mount
  #
  # The function also creates the host directory eagerly with
  # `mkdir -p` so the bind mount works on first `./run.sh` without
  # Docker silently creating a root-owned dir.
  _logging_svc_local_path_mount() {
    local _svc="$1"
    local -n _llp_out="$2"
    _llp_out=""
    local -A _kv=()
    _logging_svc_kv "${_svc}" _kv
    local _raw="${_kv[local_path]:-}"
    [[ -z "${_raw}" ]] && return 0
    # ~ expansion at front only (not embedded — same restriction as
    # POSIX sh). The pattern uses single-char literal match (\~) and
    # case so shellcheck SC2088 doesn't flag it; we're matching the
    # user's *literal* `~/foo` setup.conf value and rewriting it to
    # ${HOME}/foo.
    case "${_raw}" in
      \~/*)
        _raw="${HOME}/${_raw#\~/}" ;;
      \~)
        _raw="${HOME}" ;;
    esac
    # Strip trailing slashes for predictable mount string.
    while [[ "${_raw}" == */ && "${_raw}" != "/" ]]; do
      _raw="${_raw%/}"
    done
    # Relative -> resolve against repo root (the compose.yaml's
    # directory, captured earlier in generate_compose_yaml as
    # _setup_base).
    if [[ "${_raw}" != /* ]]; then
      _raw="${_setup_base%/}/${_raw}"
    fi
    # Create the dir eagerly so `docker run` doesn't auto-create it
    # root-owned. Failure is non-fatal -- if the user's running setup
    # without write perms to that dir, the eventual docker run will
    # raise a clear error.
    mkdir -p "${_raw}" 2>/dev/null || true
    _llp_out="${_raw}:/var/log/${_name}"
  }

  # _emit_logging_local_path_volume <svc>
  #
  # Prints a single compose volume line if service <svc> resolves a
  # non-empty `local_path`. Indentation matches the surrounding
  # `volumes:` block (6 spaces, list-item dash, then the resolved
  # mount string).
  _emit_logging_local_path_volume() {
    local _mount=""
    _logging_svc_local_path_mount "$1" _mount
    [[ -z "${_mount}" ]] || echo "      - ${_mount}"
  }

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

  # restart emitter (#478): [lifecycle] restart policy on the devel service.
  # Default `no` emits nothing (zero-diff). Stages that `extends: devel`
  # inherit the value via compose. `on-failure:N` is quoted because the `:`
  # would otherwise read as a YAML mapping.
  _emit_restart_line() {
    [[ "${_restart}" == "no" ]] && return 0
    case "${_restart}" in
      on-failure:*) printf '    restart: "%s"\n' "${_restart}" ;;
      *)            printf '    restart: %s\n'   "${_restart}" ;;
    esac
  }

  # env_file emitter (#502): inject the hand-authored .env workload
  # overlay into the service so per-task env vars take effect with
  # `make run` alone (no regenerate, no SETUP_CONF_HASH drift). Path is
  # relative to compose.yaml (repo root). The devel block emits it and
  # `extends: devel` stages inherit it; the per-stage standalone block
  # (override mode, no extends) re-emits it. Plain (not required:false):
  # setup.sh scaffolds .env on apply, so it always exists before compose
  # runs. .env.generated (the resolved cache) is NOT listed here -- it
  # feeds compose interpolation via the CLI --env-file flag, not the
  # container environment (#502 two-role split).
  _emit_env_file_block() {
    cat <<'YAML'
    env_file:
      - .env
YAML
  }

  # #410: section emitters shared by the devel block and the per-stage
  # standalone block. Both iterate the SAME top-level [security] /
  # [devices] / [tmpfs] strings (a stage standalone block re-emits the
  # enclosing-scope values, #220), so the emitted bytes are identical --
  # hoisting removes the duplication without touching the principled
  # devel-vs-stage differences (env-var refs vs literals, extends base
  # vs standalone, stdin/tty, profiles) which stay inline per mode.

  # cap_add / cap_drop / security_opt. Defaults to the enclosing-scope
  # top-level [security] strings (the devel block). The per-stage
  # standalone block (#526) passes its effective resolved lists so a
  # stage can override / clear inherited caps via [stage:*] security.*.
  _emit_caps_block() {
    local _cap_add="${1-${_cap_add_str}}"
    local _cap_drop="${2-${_cap_drop_str}}"
    local _sec_opt="${3-${_sec_opt_str}}"
    local _c
    if [[ -n "${_cap_add}" ]]; then
      echo "    cap_add:"
      while IFS= read -r _c; do
        [[ -z "${_c}" ]] && continue
        echo "      - ${_c}"
      done <<< "${_cap_add}"
    fi
    if [[ -n "${_cap_drop}" ]]; then
      echo "    cap_drop:"
      while IFS= read -r _c; do
        [[ -z "${_c}" ]] && continue
        echo "      - ${_c}"
      done <<< "${_cap_drop}"
    fi
    if [[ -n "${_sec_opt}" ]]; then
      echo "    security_opt:"
      while IFS= read -r _c; do
        [[ -z "${_c}" ]] && continue
        echo "      - ${_c}"
      done <<< "${_sec_opt}"
    fi
  }

  # group_add for /dev/dri (#496): GUI-gated; caller passes the effective
  # gui flag (devel's _gui or a stage's _eff_gui). Numeric GIDs quoted.
  _emit_group_add_block() {
    local _g="$1"
    [[ "${_g}" == "true" && -n "${_dri_groups_str}" ]] || return 0
    echo "    group_add:"
    local _gid
    for _gid in ${_dri_groups_str}; do
      echo "      - \"${_gid}\""
    done
  }

  # device_cgroup_rules from [devices] cgroup_rule_* (enclosing scope).
  _emit_cgroup_rules_block() {
    [[ -n "${_cgroup_rule_str}" ]] || return 0
    echo "    device_cgroup_rules:"
    local _cr
    while IFS= read -r _cr; do
      [[ -z "${_cr}" ]] && continue
      echo "      - \"${_cr}\""
    done <<< "${_cgroup_rule_str}"
  }

  # tmpfs from [tmpfs] (enclosing scope).
  _emit_tmpfs_block() {
    [[ -n "${_tmpfs_str}" ]] || return 0
    echo "    tmpfs:"
    local _tf
    while IFS= read -r _tf; do
      [[ -z "${_tf}" ]] && continue
      echo "      - ${_tf}"
    done <<< "${_tmpfs_str}"
  }

  # deploy GPU reservation: caller passes the effective gpu flag, count,
  # and pre-built capabilities YAML array (devel's globals or a stage's
  # resolved values).
  _emit_gpu_deploy_block() {
    local _g="$1" _count="$2" _caps="$3"
    [[ "${_g}" == "true" ]] || return 0
    cat <<YAML
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${_count}
              capabilities: ${_caps}
YAML
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
      1) _log_warn setup stage_invalid_format "display=$(_setup_msg stage invalid_format): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")" ;;
      2) _log_err setup stage_baseline_collision "display=$(_setup_msg stage baseline_collision): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")"; return 1 ;;
      3) _log_err setup stage_reserved_tag "display=$(_setup_msg stage reserved_tag): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")"; return 1 ;;
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
        _log_err setup stage_baseline_collision "display=$(_setup_msg stage baseline_collision): [stage:${_cs}]" "stage=${_cs}"
        return 1
        ;;
      latest|v[0-9]*)
        _log_err setup stage_reserved_tag "display=$(_setup_msg stage reserved_tag): [stage:${_cs}]" "stage=${_cs}"
        return 1
        ;;
      devel)
        _log_warn setup stage_devel_reserved "display=[stage:devel] is reserved; not applied in v1 (#220). Edit top-level sections to tune devel."
        continue
        ;;
    esac
    # Orphan check: stage is referenced but Dockerfile doesn't have it.
    local _is_emitted=0 _es
    for _es in "${_emit_stages[@]}"; do
      [[ "${_es}" == "${_cs}" ]] && _is_emitted=1 && break
    done
    if (( ! _is_emitted )); then
      _log_warn setup stage_unknown_referenced "display=$(_setup_msg stage unknown_referenced): [stage:${_cs}]" "stage=${_cs}"
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
    # #472: top-level name: so non-wrapper tools (lazydocker / docker compose
    # ps / IDE panels) resolve the same project name the wrapper pins via -p.
    # Literal vars -> compose interpolates from .env at parse time; matches
    # lib/compose.sh PROJECT_NAME. INSTANCE_SUFFIX is absent from .env so it
    # expands empty (base instance) for non-wrapper tools; the wrapper's -p
    # still wins for per-instance runs (compose precedence: -p > name:).
    cat <<'YAML'
name: ${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX:-}
YAML
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
    container_name: \${USER_NAME}-${_name}\${INSTANCE_SUFFIX:-}
    privileged: \${PRIVILEGED}
    ipc: \${IPC_MODE}
YAML
    # pid: only emitted for "host" — Docker rejects "private" as a
    # literal; omitting the key gives the same private-namespace default.
    if [[ "${_pid_mode}" == "host" ]]; then
      echo "    pid: \${PID_MODE}"
    fi
    cat <<YAML
    stdin_open: true
    tty: true
YAML
    # Workload overlay (#502): devel emits it; extends:devel stages inherit.
    _emit_env_file_block
    _emit_runtime_line
    _emit_restart_line
    # cap_add / cap_drop / security_opt + group_add (#410 shared emitters).
    _emit_caps_block
    _emit_group_add_block "${_gui}"
    if [[ -n "${_net_name}" ]]; then
      cat <<YAML
    networks:
      - ${_net_name}
YAML
    else
      echo "    network_mode: \${NETWORK_MODE}"
    fi
    # environment: merges GUI baseline (DISPLAY etc.) + user env_N entries
    # + #328 LOG_FILE_PATH when [logging] local_path is set for this svc
    # (consumed by .base/script/docker/_entrypoint_logging.sh helper to
    # tee container stdout/stderr to the bind-mounted host file).
    # _devel_llp resolved here -- the volumes block emit below reuses
    # this variable, but the env block needs to know about the mount
    # too, so we compute once and share.
    local _devel_llp=""
    _logging_svc_local_path_mount devel _devel_llp
    local _devel_log_file=""
    [[ -n "${_devel_llp}" ]] && _devel_log_file="/var/log/${_name}/devel.log"
    if [[ "${_gui}" == "true" ]] || [[ -n "${_env_str}" ]] || [[ -n "${_devel_log_file}" ]]; then
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
      [[ -n "${_devel_log_file}" ]] && echo "      - LOG_FILE_PATH=${_devel_log_file}"
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
    # setup.sh on first run and user-editable thereafter). #328 adds
    # the [logging] local_path bind mount when the per-service
    # resolution yields a non-empty host path -- _devel_llp was resolved
    # earlier (above the env block) so it could share with LOG_FILE_PATH.
    local _any_prop_device=false
    if [[ -n "${_devices_str}" ]]; then
      local _chk
      while IFS= read -r _chk; do
        [[ -z "${_chk}" ]] && continue
        if _device_has_propagation "${_chk}"; then _any_prop_device=true; break; fi
      done <<< "${_devices_str}"
    fi
    if [[ "${_gui}" == "true" ]] || (( ${#_gcy_extras[@]} > 0 )) || [[ -n "${_devel_llp}" ]] || [[ "${_any_prop_device}" == true ]]; then
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
      [[ -n "${_devel_llp}" ]] && echo "      - ${_devel_llp}"
      # #450: device entries with propagation redirect to volumes: long-form
      if [[ -n "${_devices_str}" ]]; then
        local _d
        while IFS= read -r _d; do
          [[ -z "${_d}" ]] && continue
          _device_has_propagation "${_d}" && _emit_device_as_volume "${_d}" "    "
        done <<< "${_devices_str}"
      fi
    fi
    # devices: from [devices] section (plain entries only, no propagation)
    if [[ -n "${_devices_str}" ]]; then
      local _has_plain=false _d
      while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        _device_has_propagation "${_d}" && continue
        if [[ "${_has_plain}" != true ]]; then
          echo "    devices:"
          _has_plain=true
        fi
        echo "      - ${_d}"
      done <<< "${_devices_str}"
    fi
    # device_cgroup_rules + tmpfs (#410 shared emitters).
    _emit_cgroup_rules_block
    _emit_tmpfs_block
    # shm_size: only emitted when ipc != host (otherwise Docker ignores it)
    if [[ -n "${_shm_size}" ]] && [[ "${_ipc_mode}" != "host" ]]; then
      echo "    shm_size: ${_shm_size}"
    fi
    _emit_gpu_deploy_block "${_gpu}" "${_gpu_count}" "${_caps_yaml}"
    _emit_logging_block devel

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

    # #482: accumulate named-volume references across devel + every stage so
    # the top-level `volumes:` declaration can be emitted once at the end
    # (compose requires every named volume a service references to be
    # declared). Bind mounts never enter this set. Per-stage volumes are
    # added inside the emit loop below as each stage's effective list resolves.
    local -A _named_vols=()
    _collect_named_volumes _named_vols "${_top_volumes_str}"

    local _emit_stage
    for _emit_stage in "${_emit_stages[@]}"; do
      # #493 (A1'-b): devel-test is emitted under the legacy service
      # name `test` (preserves `make exec -t test`, the `:test` image
      # tag, the `test` profile, and [logging.test] keying). All other
      # stages use their own name. build.target and the
      # [stage:<name>] override lookup stay on the real Dockerfile
      # stage name `_emit_stage` (= devel-test).
      local _svc="${_emit_stage}"
      [[ "${_emit_stage}" == "devel-test" ]] && _svc="test"
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
          _log_warn setup stage_override_key_not_allowed "display=$(_setup_msg stage override_key_not_allowed): $(printf '%q' "${_so_keys[_ki]}") (stage=${_emit_stage})" "key=$(printf '%q' "${_so_keys[_ki]}")" "stage=${_emit_stage}"
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

  ${_svc}:
    extends:
      service: devel
    build:
      context: .
      dockerfile: Dockerfile
      target: ${_emit_stage}
YAML
        _emit_additional_contexts_block
        cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_svc}
    container_name: \${USER_NAME}-${_name}-${_svc}\${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - ${_svc}
YAML
        # #328 / #367: per-stage LOG_FILE_PATH + volume mount when
        # [logging] / [logging.<stage>] local_path is set. compose's
        # `extends` merge inherits devel's `environment:` and
        # `volumes:` lists, then concatenates the child's entries on
        # top -- last-wins resolution at runtime means the per-stage
        # override here takes effect. Volume mount is duplicated
        # against devel's inherited mount but compose dedups
        # identical bind strings (#367 Option A: emit uniformly on
        # every service block, no extends-relationship detection).
        local _stage_llp=""
        _logging_svc_local_path_mount "${_svc}" _stage_llp
        if [[ -n "${_stage_llp}" ]]; then
          echo "    environment:"
          echo "      - LOG_FILE_PATH=/var/log/${_name}/${_svc}.log"
          echo "    volumes:"
          echo "      - ${_stage_llp}"
        fi
        # Per-stage [logging.<stage>] driver / rotation override
        # (if any). Without an override compose `extends: devel`
        # already covers logging:: compose extends merges mapping
        # sub-keys so devel's logging block carries over -- emit
        # only when the stage actually diverges from devel.
        if [[ -n "${_logging_per_svc_str}" ]] && \
           grep -qE "^${_svc}:" <<< "${_logging_per_svc_str}"; then
          _emit_logging_block "${_svc}"
        fi
        continue
      fi

      # Resolve effective per-stage docker flags through the single
      # shared resolution layer (#505). The deploy renderer (S6 #506)
      # calls the same _resolve_docker_flags for the runtime stage, so
      # the two renderers never drift. Modes (gui / gpu) inherit the
      # parent's already-resolved boolean unless the stage forces
      # off / force — no per-stage hardware re-detection. The resolved
      # record is unpacked into the existing _eff_* locals so the emit
      # blocks below stay untouched.
      local -A _dflags_parent=(
        [gui]="${_gui}"
        [gpu]="${_gpu}"
        [gpu_count]="${_gpu_count}"
        [gpu_caps]="${_gpu_caps}"
        [runtime]="${_runtime}"
        [net_mode]="${_net_mode}"
        [ipc_mode]="${_ipc_mode}"
        [pid_mode]="${_pid_mode}"
        [net_name]="${_net_name}"
        [volumes_top]="${_top_volumes_str}"
        [env_top]="${_env_str}"
        [ports_top]="${_ports_str}"
        [cap_add_top]="${_cap_add_str}"
        [cap_drop_top]="${_cap_drop_str}"
        [sec_opt_top]="${_sec_opt_str}"
      )
      local -A _dflags_eff=()
      _resolve_docker_flags _so_filtered_keys _so_filtered_values _dflags_parent _dflags_eff
      local _eff_gui="${_dflags_eff[gui]}"
      local _eff_gpu="${_dflags_eff[gpu]}"
      local _eff_gpu_count="${_dflags_eff[gpu_count]}"
      local _eff_gpu_caps="${_dflags_eff[gpu_caps]}"
      local _eff_runtime="${_dflags_eff[runtime]}"
      local _eff_net_mode="${_dflags_eff[net_mode]}"
      local _eff_ipc_mode="${_dflags_eff[ipc_mode]}"
      local _eff_pid_mode="${_dflags_eff[pid_mode]}"
      local _eff_net_name="${_dflags_eff[net_name]}"
      local _eff_privileged="${_dflags_eff[privileged]}"
      local _eff_volumes="${_dflags_eff[volumes]}"
      local _eff_environment="${_dflags_eff[environment]}"
      local _eff_ports="${_dflags_eff[ports]}"
      local _eff_cap_add="${_dflags_eff[cap_add]}"
      local _eff_cap_drop="${_dflags_eff[cap_drop]}"
      local _eff_sec_opt="${_dflags_eff[security_opt]}"
      # #482: pick up any named volumes this stage introduces (a per-stage
      # mount_* override may add one the top-level list lacks).
      _collect_named_volumes _named_vols "${_eff_volumes}"

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

  ${_svc}:
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
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_svc}
    container_name: \${USER_NAME}-${_name}-${_svc}\${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - ${_svc}
YAML
      # Workload overlay (#502): standalone block has no `extends: devel`
      # to inherit from, so re-emit env_file explicitly.
      _emit_env_file_block
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
      # pid: only emitted for "host" — Docker rejects "private" as literal.
      if [[ "${_eff_pid_mode}" == "host" ]]; then
        if [[ "${_eff_pid_mode}" != "${_pid_mode}" ]]; then
          echo "    pid: ${_eff_pid_mode}"
        else
          echo "    pid: \${PID_MODE}"
        fi
      fi
      # runtime: only when explicitly set non-empty / non-auto / non-off.
      if [[ -n "${_eff_runtime}" ]] && \
         [[ "${_eff_runtime}" != "off" ]] && \
         [[ "${_eff_runtime}" != "auto" ]]; then
        echo "    runtime: ${_eff_runtime}"
      fi
      # cap_add / cap_drop / security_opt: effective per-stage lists
      # (#526) — a stage can override / clear inherited caps via [stage:*]
      # security.cap_add_* / cap_drop_* / security_opt_* (+ *_inherit),
      # else inherits the top-level [security] block. group_add is gated
      # on the stage's effective gui. Shared emitter with devel (#410).
      _emit_caps_block "${_eff_cap_add}" "${_eff_cap_drop}" "${_eff_sec_opt}"
      _emit_group_add_block "${_eff_gui}"
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
      # environment: GUI baseline (effective gui) + effective env list
      # + #328 LOG_FILE_PATH for the per-stage tee target.
      local _stage_llp=""
      _logging_svc_local_path_mount "${_svc}" _stage_llp
      local _stage_log_file=""
      [[ -n "${_stage_llp}" ]] && _stage_log_file="/var/log/${_name}/${_svc}.log"
      if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_environment}" ]] || [[ -n "${_stage_log_file}" ]]; then
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
        [[ -n "${_stage_log_file}" ]] && echo "      - LOG_FILE_PATH=${_stage_log_file}"
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
      # volumes: GUI baseline (effective gui) + effective volume list
      # + #328 [logging] local_path per-stage bind mount. _stage_llp
      # was resolved above the env block; reuse it here.
      if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_volumes}" ]] || [[ -n "${_stage_llp}" ]] || [[ "${_any_prop_device}" == true ]]; then
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
        [[ -n "${_stage_llp}" ]] && echo "      - ${_stage_llp}"
        # #450: device entries with propagation redirect to volumes: long-form
        if [[ -n "${_devices_str}" ]]; then
          local _sd
          while IFS= read -r _sd; do
            [[ -z "${_sd}" ]] && continue
            _device_has_propagation "${_sd}" && _emit_device_as_volume "${_sd}" "    "
          done <<< "${_devices_str}"
        fi
      fi
      # devices: from top-level (plain entries only, no propagation).
      if [[ -n "${_devices_str}" ]]; then
        local _has_plain_sd=false _sd
        while IFS= read -r _sd; do
          [[ -z "${_sd}" ]] && continue
          _device_has_propagation "${_sd}" && continue
          if [[ "${_has_plain_sd}" != true ]]; then
            echo "    devices:"
            _has_plain_sd=true
          fi
          echo "      - ${_sd}"
        done <<< "${_devices_str}"
      fi
      # device_cgroup_rules + tmpfs from top-level (#410 shared emitters).
      _emit_cgroup_rules_block
      _emit_tmpfs_block
      # shm_size: depends on effective ipc (only emitted under
      # non-host ipc, mirroring devel).
      if [[ -n "${_shm_size}" ]] && [[ "${_eff_ipc_mode}" != "host" ]]; then
        echo "    shm_size: ${_shm_size}"
      fi
      # deploy / GPU block (#410 shared emitter): build the effective caps
      # YAML (per-stage resolution differs from devel), then emit.
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
        _emit_gpu_deploy_block "${_eff_gpu}" "${_eff_gpu_count}" "${_eff_caps_yaml}"
      fi
      # Stage emits a standalone block (no `extends: devel`), so it
      # carries no inherited logging — always emit the effective
      # logging block when [logging] or [logging.<stage>] is set.
      # Keyed by the service name (`_svc`) so devel-test's logging stays
      # under [logging.test] (#493).
      _emit_logging_block "${_svc}"
    done

    # #493 (A1'-b): the `test` service is no longer a hardcoded bare
    # block here — devel-test flows through the per-stage loop above
    # (emitted under the legacy service name `test` via `_svc`), so it
    # inherits devel by default and honours [stage:devel-test] overrides
    # like any other non-baseline stage.

    # #482: top-level volumes: declaration for any named volumes referenced
    # by devel or a stage. Emitted before networks: (top-level section order).
    # No-op (zero-diff) when only bind mounts are used.
    _emit_volumes_block _named_vols
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
#                  <network_mode> <ipc_mode> <pid_mode> <privileged>
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
  local _pid_mode="${1}"; shift
  local _privileged="${1}"; shift
  local _gpu_count="${1}"; shift
  local _gpu_caps="${1}"; shift
  local _gui_detected="${1}"; shift
  local _conf_hash="${1}"; shift
  local _dockerfile_hash="${1}"; shift
  local _network_name="${1:-}"; shift || true
  local _user_build_args="${1:-}"; shift || true
  local _target_arch="${1:-}"; shift || true
  local _build_network="${1:-}"; shift || true
  # SSH X11 forwarding cookie override (#321). Empty when not in an
  # SSH X11 session, in which case host's XAUTHORITY flows through to
  # compose unchanged.
  local _ssh_x11_xauth="${1:-}"

  local _comment=""
  _comment="$(_setup_msg env comment)"
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
PID_MODE=${_pid_mode}
PRIVILEGED=${_privileged}
GPU_COUNT=${_gpu_count}
GPU_CAPABILITIES="${_gpu_caps}"

# ── Setup metadata (drift detection — do not edit) ──
SETUP_CONF_HASH=${_conf_hash}
SETUP_DOCKERFILE_HASH=${_dockerfile_hash}
SETUP_GUI_DETECTED=${_gui_detected}
SETUP_TIMESTAMP=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')
EOF

  # ── SSH X11 forwarding cookie override (#321) ──
  # Set by apply flow when _is_ssh_x11 detects an SSH X11 session.
  # Compose reads .env via --env-file and uses the value here for
  # `${XAUTHORITY:-}` substitution in the GUI block. Without this,
  # libX11 inside the container looks up the cookie under the
  # container's hostname (a Docker-assigned random) and fails because
  # SSH wrote the cookie keyed to the host's hostname. The rewritten
  # cookie at .docker.xauth uses the `ffff` family code so the
  # hostname check is skipped.
  if [[ -n "${_ssh_x11_xauth:-}" ]]; then
    {
      printf '\n# ── SSH X11 forwarding cookie override (#321) ──\n'
      printf 'XAUTHORITY=%s\n' "${_ssh_x11_xauth}"
    } >> "${_env_file}"
  fi

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
# _scaffold_env_overlay <path>
#
# Create the hand-authored `.env` workload overlay with guidance
# comments if it does not exist (#502, A2 file roles). Idempotent:
# never overwrites an existing file -- the overlay is user-owned after
# its first creation, so setup.sh leaves it alone on every later apply.
# ════════════════════════════════════════════════════════════════════
_scaffold_env_overlay() {
  local _path="${1:?}"
  [[ -e "${_path}" ]] && return 0
  cat > "${_path}" << 'EOF'
# Workload overlay -- hand-authored, gitignored. setup.sh creates this
# file once and never edits it again. Put per-task / volatile env vars
# here as KEY=VALUE (e.g. ROS_DOMAIN_ID=42, LOG_LEVEL=debug, API tokens).
# They are injected into the container via `env_file: - .env` and take
# effect with only `make run` -- no regenerate, no SETUP_CONF_HASH drift,
# no git churn. Machine-bound / set-once params (GPU, privileged, mounts,
# IMAGE_NAME, APT mirror) belong in config/docker/setup.conf instead.
# See README "Where each parameter lives (env vs workload)".
EOF
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
  local _env_file="${_base}/.env.generated"
  [[ -f "${_env_file}" ]] || return 0

  # Read stored values from .env.generated without polluting caller's env
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
    _log_warn setup env_drift_detected "display=drift detected since last setup.sh run:"
    for _d in "${_drift[@]}"; do
      _log_warn setup env_drift_detail "display=  - ${_d}" "detail=${_d}"
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
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
    _log_warn setup conf_no_repo_conf "display=$(_setup_msg warnings no_repo_conf)"
  elif ! grep -qE '^[[:space:]]*\[[^]]+\]' "${_repo_conf}"; then
    _log_warn setup conf_empty_repo_conf "display=$(_setup_msg warnings empty_repo_conf)"
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
    image|build|deploy|lifecycle|gui|network|security|resources|environment|tmpfs|devices|volumes|additional_contexts|logging)
      return 0 ;;
    logging.?*)
      # Per-service override section [logging.<svc>] -- shape only;
      # `<svc>` must be non-empty (rejects `logging.` trailing-dot).
      # Caller decides whether <svc> matches a real Dockerfile stage.
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
    lifecycle.restart)
      # #478: 5 canonical docker restart policies. Empty allowed (= clear
      # key, falls back to template default `no`).
      [[ -z "${_value}" ]] && return 0
      _validate_restart "${_value}" ;;
    *)
      # [logging] + [logging.<svc>] share the same key validators —
      # docker daemon's `logging.driver` + `logging.options.*` shape.
      # Empty allowed = "clear key, fall through to template default".
      case "${_section}" in
        logging|logging.*)
          case "${_key}" in
            driver)
              [[ -z "${_value}" ]] && return 0
              _validate_log_driver "${_value}"
              return $? ;;
            max_size)
              [[ -z "${_value}" ]] && return 0
              _validate_log_max_size "${_value}"
              return $? ;;
            max_file)
              [[ -z "${_value}" ]] && return 0
              _validate_log_max_file "${_value}"
              return $? ;;
            compress)
              [[ -z "${_value}" ]] && return 0
              _validate_log_compress "${_value}"
              return $? ;;
            local_path)
              [[ -z "${_value}" ]] && return 0
              _validate_log_local_path "${_value}"
              return $? ;;
            *)
              return 0 ;;
          esac
          ;;
      esac
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
#                                           [--lang LANG] [-q|--quiet]
# ════════════════════════════════════════════════════════════════════
_setup_set() {
  local _base_path=""
  local _spec="" _value="" _have_value=0
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured the next bare arg is the value, even if
    # it starts with '-' (e.g. `set deploy.gpu_count -1` exercises an
    # invalid value path that the validator must reject — not a flag).
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
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
      -q|--quiet)
        _quiet=1
        shift
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage set >&2
    return 1
  fi

  # Split <section>.<key>; the first '.' is the separator. The only
  # sub-section pattern is [logging.<svc>] (per-service override), so
  # `logging.<svc>.<key>` is split as section=`logging.<svc>`,
  # key=`<key>` (rightmost-dot). All other shapes use first-dot.
  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage set >&2
    return 1
  fi
  local _section _key
  if [[ "${_spec}" == logging.*.* ]]; then
    _section="${_spec%.*}"
    _key="${_spec##*.}"
  else
    _section="${_spec%%.*}"
    _key="${_spec#*.}"
  fi
  if [[ -z "${_section}" || -z "${_key}" ]]; then
    _setup_msg usage set >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if ! _setup_validate_kv "${_section}" "${_key}" "${_value}"; then
    _log_err setup conf_invalid_value "display=$(_setup_msg errors invalid_value): ${_section}.${_key} = ${_value}" "section=${_section}" "key=${_key}" "value=${_value}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi

  # Writes target the per-repo override file (setup.conf). Bootstrap
  # as empty when missing — `set` records only the user's intent, never
  # copies template defaults wholesale.
  local _conf="${_base_path}/config/docker/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    : > "${_conf}"
  fi

  _upsert_conf_value "${_conf}" "${_section}" "${_key}" "${_value}"

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] set [%s] %s = %s\n' "${_section}" "${_key}" "${_value}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'make build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" ]]; then
    _setup_msg usage show >&2
    return 1
  fi

  local _section _key
  if [[ "${_spec}" == logging.*.* ]]; then
    # [logging.<svc>] sub-section: section is `logging.<svc>`, key is
    # the rightmost dot-delimited segment.
    _section="${_spec%.*}"
    _key="${_spec##*.}"
  elif [[ "${_spec}" == *.* ]]; then
    _section="${_spec%%.*}"
    _key="${_spec#*.}"
  else
    _section="${_spec}"
    _key=""
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi

  # show reads the merged view (template baseline ← repo override).
  # This is what `apply` would produce, so users see effective values
  # without having to re-run apply after every set/add/remove.
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
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
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_ns_key}" "key=${_ns_key}"
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
    _log_err setup conf_section_not_found "display=$(_setup_msg errors section_not_found): ${_section}" "section=${_section}"
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
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
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi

  # list reads the merged view (template ← repo override) — same
  # rationale as `show`. Reflects what `apply` would materialize.
  local _repo_conf="${_base_path}/config/docker/setup.conf"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
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
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    # Once <spec> is captured, the next bare arg is the value, even if
    # it begins with '-' (e.g. negative numbers shouldn't be parsed as
    # flags). Same shape as _setup_set.
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
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
      -q|--quiet)
        _quiet=1
        shift
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_have_value}" -eq 0 ]]; then
    _setup_msg usage add >&2
    return 1
  fi

  if [[ "${_spec}" != *.* ]]; then
    _setup_msg usage add >&2
    return 1
  fi
  local _section="${_spec%%.*}"
  local _list="${_spec#*.}"
  if [[ -z "${_section}" || -z "${_list}" ]]; then
    _setup_msg usage add >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
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
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
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
    _log_err setup conf_invalid_value "display=$(_setup_msg errors invalid_value): ${_section}.${_new_key} = ${_value}" "section=${_section}" "key=${_new_key}" "value=${_value}"
    return 2
  fi

  _upsert_conf_value "${_conf}" "${_section}" "${_new_key}" "${_value}"

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] add [%s] %s = %s\n' "${_section}" "${_new_key}" "${_value}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'make build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
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
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    if [[ -n "${_spec}" && "${_have_value}" -eq 0 ]]; then
      case "$1" in
        --base-path|--lang|-q|--quiet|-h|--help)
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
      -q|--quiet)
        _quiet=1
        shift
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
      *)
        if [[ -z "${_spec}" ]]; then
          _spec="$1"
        elif [[ "${_have_value}" -eq 0 ]]; then
          _value="$1"; _have_value=1
        else
          _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
          return 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "${_spec}" || "${_spec}" != *.* ]]; then
    _setup_msg usage remove >&2
    return 1
  fi
  local _section _rest
  if [[ "${_spec}" == logging.*.* ]]; then
    _section="${_spec%.*}"
    _rest="${_spec##*.}"
  else
    _section="${_spec%%.*}"
    _rest="${_spec#*.}"
  fi
  if [[ -z "${_section}" || -z "${_rest}" ]]; then
    _setup_msg usage remove >&2
    return 1
  fi

  if ! _setup_known_section "${_section}"; then
    _log_err setup conf_section_not_found "display=$(_setup_msg errors unknown_section): ${_section}" "section=${_section}"
    return 2
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi
  # remove only operates on the per-repo override. If setup.conf
  # doesn't exist, there's nothing to remove (template baseline isn't
  # a removable input).
  local _conf="${_base_path}/config/docker/setup.conf"
  if [[ ! -f "${_conf}" ]]; then
    _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
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
      _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_section}.${_rest} = ${_value}" "key=${_section}.${_rest}" "value=${_value}"
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
      _log_err setup conf_key_not_found "display=$(_setup_msg errors key_not_found): ${_spec}" "key=${_spec}"
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

  if [[ "${_quiet}" -eq 0 ]]; then
    printf '[setup] remove [%s] %s\n' "${_section}" "${_target_key}"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'make build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
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
  local _quiet=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -y|--yes)
        _yes=1
        shift
        ;;
      -q|--quiet)
        _quiet=1
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
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi

  # reset clears the per-repo override (setup.conf) so the next `apply`
  # rebuilds .env.generated + compose.yaml purely from the template
  # baseline. The workspace mount_1 is re-detected and re-written via the
  # bootstrap path on the next apply. The hand-authored .env workload
  # overlay is user-owned and intentionally left untouched by reset.
  local _conf="${_base_path}/config/docker/setup.conf"
  local _env="${_base_path}/.env.generated"
  local _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
  if [[ ! -f "${_tpl_conf}" ]]; then
    _log_err setup conf_template_missing "display=template setup.conf not found at ${_tpl_conf}" "path=${_tpl_conf}"
    return 1
  fi

  if (( ! _yes )); then
    if [[ ! -t 0 ]]; then
      _log_err setup conf_reset_needs_yes "display=$(_setup_msg reset needs_yes)"
      return 1
    fi
    printf "[setup] %s [y/N]: " "$(_setup_msg reset confirm)"
    local _ans=""
    read -r _ans
    case "${_ans}" in
      y|Y|yes|YES) ;;
      *)
        _log_warn setup conf_reset_aborted "display=$(_setup_msg reset aborted)"
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

  if [[ "${_quiet}" -eq 0 ]]; then
    _log_info setup conf_reset "display=$(_setup_msg reset "done")"
    printf '[setup] file: %s\n' "${_conf}"
    printf "[setup] next: run 'make build' (auto-applies) or './setup.sh apply' to regenerate .env + compose.yaml\n"
  fi
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
  local _quiet=0
  # #338: per-invocation overrides. Empty means "use setup.conf /
  # SETUP_GUI env / built-in default" per the documented resolution
  # order CLI > env > conf > default.
  local _gui_override=""        # --gui=auto|force|off
  local _no_x11_cookie=0        # --no-x11-cookie
  local _print_resolved=0       # --print-resolved

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
      -q|--quiet)
        _quiet=1
        shift
        ;;
      --gui)
        _gui_override="${2:?"--gui requires a value (auto|force|off)"}"
        shift 2
        ;;
      --gui=*)
        _gui_override="${1#--gui=}"
        shift
        ;;
      --no-x11-cookie)
        _no_x11_cookie=1
        shift
        ;;
      --print-resolved)
        _print_resolved=1
        shift
        ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  # Validate --gui value early so the user sees the error before we
  # spend cycles on detections.
  if [[ -n "${_gui_override}" ]]; then
    case "${_gui_override}" in
      auto|force|off) ;;
      *)
        _log_err setup gui_override_invalid "display=$(_setup_msg errors invalid_value): --gui = ${_gui_override} (expected auto|force|off)" "value=${_gui_override}"
        return 2
        ;;
    esac
  fi

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi

  _announce_template_default_fallback "${_base_path}"

  # A2 file roles (#502): .env.generated is the derived interpolation
  # cache written by setup.sh; .env is the hand-authored workload
  # overlay (never touched here after the first-apply scaffold).
  local _env_file="${_base_path}/.env.generated"
  local _overlay_file="${_base_path}/.env"

  # Migrate a pre-#502 layout where .env WAS the cache: if no
  # .env.generated exists yet but .env carries the setup.sh auto-gen
  # marker, it is a stale cache, not a user overlay. Back it up and
  # promote it to .env.generated so the prior-values source below still
  # resolves; write_env regenerates it and a fresh overlay is scaffolded.
  if [[ ! -f "${_env_file}" && -f "${_overlay_file}" ]] \
      && grep -q '^SETUP_CONF_HASH=' "${_overlay_file}" 2>/dev/null; then
    cp -- "${_overlay_file}" "${_overlay_file}.bak"
    mv -- "${_overlay_file}" "${_env_file}"
  fi

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
  # Only the sections apply still consumes directly are loaded here:
  # [build] (build args / target_arch), [volumes] (WS_PATH + extra_volumes),
  # [security] (the #450 propagation guard re-reads privileged), and
  # [additional_contexts]. Every docker/build scalar + list-string the
  # compose call needs (gpu / gui / network / devices / env / tmpfs /
  # ports / caps / shm / restart / dri / build_network) is resolved by the
  # shared _resolve_deploy_context below (S6b, #506), which loads its own
  # sections -- the same resolver the deploy generator uses, so the field
  # deploy can never drift from apply.
  local -a _build_k=() _build_v=() _vol_k=() _vol_v=() _sec_k=() _sec_v=()
  local -a _ac_k=() _ac_v=()
  _load_setup_conf "${_base_path}" "build"               _build_k _build_v
  _load_setup_conf "${_base_path}" "volumes"             _vol_k _vol_v
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
  # ── Resolve conf-derived docker/build params via the shared layer ──
  # S6b (#506): _resolve_deploy_context is the single conf resolution that
  # both apply and the deploy generator use, so the field deploy never
  # drifts from what apply produces for the same setup.conf. Its record is
  # unpacked into the existing locals below; the --gui / SETUP_GUI override,
  # the detection-dependent enabled booleans, the WS_PATH / mount_1
  # migration, and the #450 device/volume validation stay apply-side.
  local -A _dctx=()
  _resolve_deploy_context "${_base_path}" _dctx
  local build_network="${_dctx[build_network]}"
  local gpu_mode="${_dctx[gpu_mode]}"
  local gpu_count="${_dctx[gpu_count]}"
  local gpu_caps="${_dctx[gpu_caps]}"
  local gpu_runtime_mode="${_dctx[gpu_runtime_mode]}"
  local gui_mode="${_dctx[gui_mode]}"
  local net_mode="${_dctx[net_mode]}"
  local ipc_mode="${_dctx[ipc_mode]}"
  local pid_mode="${_dctx[pid_mode]}"
  local network_name="${_dctx[network_name]}"
  local privileged="${_dctx[privileged]}"
  local restart_policy="${_dctx[restart_policy]}"
  local dri_groups_str="${_dctx[dri_groups_str]}"

  # #338: resolution order CLI > env > conf > default. The shared resolver
  # returns the conf gui_mode; layer the --gui / SETUP_GUI override on top.
  if [[ -n "${_gui_override}" ]]; then
    gui_mode="${_gui_override}"
  elif [[ -n "${SETUP_GUI:-}" ]]; then
    case "${SETUP_GUI}" in
      auto|force|off) gui_mode="${SETUP_GUI}" ;;
    esac
  fi

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
    _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../config/docker/setup.conf"
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
      _log_warn setup conf_mount_stale_path "display=[volumes] mount_1 host path '${_mount_1_host}' does not exist on this machine. This is usually a stale absolute path committed from a different machine. Rewriting mount_1 to the portable '\${WS_PATH}:/home/\${USER_NAME}/work' form and re-detecting WS_PATH locally. Commit the updated setup.conf to share." "path=${_mount_1_host}"
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

  # S4 (#504): structured app-config channel. When the repo ships a
  # config/app/ dir, dev-bind it into the container at a fixed path so
  # structured runtime config (e.g. ros1_bridge bridge topics) is
  # editable on the host with edit + restart, no rebuild. Convention over
  # configuration: the directory's presence is the only switch (no
  # setup.conf knob). The deploy flow (S6) COPY-bakes the same dir into
  # the field image instead (immutable artifact, ADR-00000003 / #506).
  # Emitted through the regular mount path so per-stage mount_inherit and
  # the top-level volumes: classifier (#482, a ./ bind) apply uniformly.
  if [[ -d "${_base_path}/config/app" ]]; then
    extra_volumes+=("./config/app:/opt/app/config")
  fi

  # ── [devices] device_* + cgroup_rule_* (from the shared resolver) ──
  local _devices_str="${_dctx[devices_str]}"
  local _cgroup_rule_str="${_dctx[cgroup_rule_str]}"

  # ── #450 P2: propagation + privileged guard ──
  if [[ -n "${_devices_str}" ]]; then
    local _has_prop=false _d_check
    while IFS= read -r _d_check; do
      [[ -z "${_d_check}" ]] && continue
      if _device_has_propagation "${_d_check}"; then
        _has_prop=true
        break
      fi
    done <<< "${_devices_str}"
    if [[ "${_has_prop}" == true ]]; then
      local _priv_val=""
      _get_conf_value _sec_k _sec_v "privileged" "" _priv_val
      if [[ "${_priv_val}" != "true" ]]; then
        _log_warn setup conf_invalid_value \
          "display=device entry uses mount propagation but [security] privileged is not true. Device I/O may be blocked by cgroup."
      fi
    fi
  fi

  # ── #450 P4: duplicate device/volume target path detection ──
  if [[ -n "${_devices_str}" ]]; then
    local _d_dup
    while IFS= read -r _d_dup; do
      [[ -z "${_d_dup}" ]] && continue
      _device_has_propagation "${_d_dup}" || continue
      local -a _dup_parts=()
      IFS=':' read -ra _dup_parts <<< "${_d_dup}"
      local _dup_target="${_dup_parts[1]}"
      local _ev
      for _ev in "${extra_volumes[@]}"; do
        local -a _ev_parts=()
        IFS=':' read -ra _ev_parts <<< "${_ev}"
        if [[ "${_ev_parts[1]}" == "${_dup_target}" ]]; then
          _log_warn setup conf_invalid_value \
            "display=duplicate target path '${_dup_target}': appears in both [devices] (with propagation) and [volumes]. The [devices] entry with propagation takes precedence."
          break
        fi
      done
    done <<< "${_devices_str}"
  fi

  # ── [environment] env_*, [tmpfs] tmpfs_*, [network] port_* + [security]
  # cap_add_* / cap_drop_* / security_opt_* (template-fallback applied) and
  # [resources] shm_size all come from the shared resolver. ──
  local _env_str="${_dctx[env_str]}"
  local _tmpfs_str="${_dctx[tmpfs_str]}"
  local _ports_str="${_dctx[ports_str]}"
  local _cap_add_str="${_dctx[cap_add_str]}"
  local _cap_drop_str="${_dctx[cap_drop_str]}"
  local _sec_opt_str="${_dctx[sec_opt_str]}"

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
  local _shm_size="${_dctx[shm_size]}"

  # ── [logging] + [logging.<svc>] (#310) ──
  local _logging_global_str="" _logging_per_svc_str=""
  _collect_logging "${_base_path}" _logging_global_str _logging_per_svc_str

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

  # ── #338 `--print-resolved`: dump effective state, do not touch
  # .env / compose.yaml / .gitignore. Output is machine-readable
  # `key=value` lines (one pair per line). Subsumes the dry-run
  # piece of base#230's `setup_resolve` MCP plan.
  if (( _print_resolved )); then
    printf 'USER_NAME=%s\n' "${user_name}"
    printf 'USER_GROUP=%s\n' "${user_group}"
    printf 'USER_UID=%s\n' "${user_uid}"
    printf 'USER_GID=%s\n' "${user_gid}"
    printf 'HARDWARE=%s\n' "${hardware}"
    printf 'DOCKER_HUB_USER=%s\n' "${docker_hub_user}"
    printf 'IMAGE_NAME=%s\n' "${image_name}"
    printf 'WS_PATH=%s\n' "${ws_path}"
    printf 'APT_MIRROR_UBUNTU=%s\n' "${apt_mirror_ubuntu}"
    printf 'APT_MIRROR_DEBIAN=%s\n' "${apt_mirror_debian}"
    printf 'TZ=%s\n' "${tz}"
    printf 'GPU_DETECTED=%s\n' "${gpu_detected}"
    printf 'GPU_MODE=%s\n' "${gpu_mode}"
    printf 'GPU_ENABLED=%s\n' "${gpu_enabled_eff}"
    printf 'GPU_COUNT=%s\n' "${gpu_count}"
    printf 'GPU_CAPABILITIES=%s\n' "${gpu_caps}"
    printf 'RUNTIME=%s\n' "${gpu_runtime_mode}"
    printf 'GUI_DETECTED=%s\n' "${gui_detected}"
    printf 'GUI_MODE=%s\n' "${gui_mode}"
    printf 'GUI_ENABLED=%s\n' "${gui_enabled_eff}"
    printf 'NETWORK_MODE=%s\n' "${net_mode}"
    printf 'IPC_MODE=%s\n' "${ipc_mode}"
    printf 'PID_MODE=%s\n' "${pid_mode}"
    printf 'PRIVILEGED=%s\n' "${privileged}"
    printf 'NETWORK_NAME=%s\n' "${network_name}"
    printf 'TARGET_ARCH=%s\n' "${target_arch}"
    printf 'BUILD_NETWORK=%s\n' "${build_network}"
    printf 'SSH_X11=%s\n' "$(_is_ssh_x11 && echo true || echo false)"
    printf 'X11_COOKIE_SKIP=%s\n' "$(( _no_x11_cookie ))"
    return 0
  fi

  # ── SSH X11 forwarding cookie rewrite (#321) ──
  # When the user is on an SSH X11 forward (`ssh -X` / `ssh -Y`),
  # rewrite their per-session cookie so libX11 inside the container
  # accepts it regardless of hostname. Also warn when [network] mode
  # is non-host because `localhost:N` (which SSH writes into DISPLAY)
  # only reaches the host's SSH X11 listener via host networking.
  #
  # #338: `--no-x11-cookie` skips the rewrite for one invocation
  # (debug knob — `XAUTHORITY` stays at the host value the user's
  # SSH session already populated). GUI itself stays enabled per
  # `gui_enabled_eff`.
  local _ssh_x11_xauth=""
  if [[ "${gui_enabled_eff}" == "true" ]] && _is_ssh_x11 \
      && (( _no_x11_cookie == 0 )); then
    _ssh_x11_xauth="$(_setup_ssh_x11_cookie "${_base_path}")" || _ssh_x11_xauth=""
    if [[ "${net_mode}" != "host" ]]; then
      _log_warn setup ssh_x11_network_mismatch "display=SSH X11 forwarding detected but [network] mode = ${net_mode}; localhost:${DISPLAY##*:} from inside the container will not reach the host's SSH X11 listener. Set [network] mode = host in setup.conf to fix. See base#321." "mode=${net_mode}"
    fi
  fi

  # ── Generate artifacts ──
  write_env "${_env_file}" \
    "${user_name}" "${user_group}" "${user_uid}" "${user_gid}" \
    "${hardware}" "${docker_hub_user}" "${gpu_detected}" \
    "${image_name}" "${ws_path}" \
    "${apt_mirror_ubuntu}" "${apt_mirror_debian}" "${tz}" \
    "${net_mode}" "${ipc_mode}" "${pid_mode}" "${privileged}" \
    "${gpu_count}" "${gpu_caps}" \
    "${gui_detected}" "${conf_hash}" "${dockerfile_hash}" \
    "${network_name}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}" \
    "${_ssh_x11_xauth}"

  # Create the hand-authored .env workload overlay on first apply (#502).
  # Idempotent: never overwrites an existing user-owned overlay.
  _scaffold_env_overlay "${_overlay_file}"

  local runtime_resolved=""
  _resolve_runtime "${gpu_runtime_mode}" runtime_resolved

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
    "${_shm_size}" "${net_mode}" "${ipc_mode}" "${pid_mode}" \
    "${_cap_add_str}" "${_cap_drop_str}" "${_sec_opt_str}" \
    "${_cgroup_rule_str}" \
    "${_user_build_args_str}" \
    "${target_arch}" \
    "${build_network}" \
    "${runtime_resolved}" \
    "${_additional_contexts_str}" \
    "${_logging_global_str}" \
    "${_logging_per_svc_str}" \
    "${restart_policy}" \
    "${dri_groups_str}" \
    || return $?

  # S7 (#507): runtime.env (#462) retired. Under the A2 model its purpose
  # is superseded -- [environment] defaults are baked into the runtime
  # image as ENV (S3), and host-side standalone helpers source
  # .env.generated (resolved cache) + .env (overlay) instead.

  if [[ "${_quiet}" -eq 0 ]]; then
    _log_info setup env_regenerated "display=$(_setup_msg env "done")"
    printf "[setup] USER=%s (%s:%s)  GPU=%s/%s  GUI=%s/%s  IMAGE=%s  WS=%s\n" \
      "${user_name}" "${user_uid}" "${user_gid}" \
      "${gpu_enabled_eff}" "${gpu_mode}" \
      "${gui_enabled_eff}" "${gui_mode}" \
      "${image_name}" "${ws_path}"
  fi
}

# ════════════════════════════════════════════════════════════════════
# _setup_deploy [-h] [--base-path P] [--lang L] [--stage S]
#               [--output|-o F] [--dry-run] [-y|--yes] [-q|--quiet]
#
# S6d of #497 (#506): user-facing entry for the self-contained field
# deploy bundle. Previews the resolved field launcher (every inlined
# docker-level flag -- the per-parameter review), asks for confirmation,
# then calls _generate_deploy_bundle (S6c) to build the immutable image
# and write the tar.xz bundle. `--dry-run` prints the build plan without
# building (and skips the prompt); `-y` skips the prompt; a non-tty shell
# without `-y` refuses (mirrors `reset`). Default stage is `runtime`;
# default output is <base>/deploy/<name>-<stage>.tar.xz.
#
# Note: the graphical per-param TUI page (setup_tui.sh) is an optional
# fast-follow -- this plain-text preview already surfaces every resolved
# flag and is script / CI friendly (the issue invited the lighter flow).
# ════════════════════════════════════════════════════════════════════
_setup_deploy() {
  local _base_path="" _stage="runtime" _output="" _yes=0 _quiet=0 _dry=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)     usage ;;
      --base-path)   _base_path="${2:?"--base-path requires a value"}"; shift 2 ;;
      --lang)        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"; _sanitize_lang _LANG "setup"; shift 2 ;;
      --stage)       _stage="${2:?"--stage requires a value"}"; shift 2 ;;
      --stage=*)     _stage="${1#--stage=}"; shift ;;
      --output|-o)   _output="${2:?"--output requires a value"}"; shift 2 ;;
      --output=*)    _output="${1#--output=}"; shift ;;
      --dry-run)     _dry=1; shift ;;
      -y|--yes)      _yes=1; shift ;;
      -q|--quiet)    _quiet=1; shift ;;
      *)
        _log_err setup conf_unknown_arg "display=$(_setup_msg errors unknown_arg): $1" "arg=$1"
        return 1
        ;;
    esac
  done

  if [[ -z "${_base_path}" ]]; then
    _base_path="$(cd -- "${_SETUP_SCRIPT_DIR}/../../../.." && pwd -P)"
  fi
  if [[ ! -f "${_base_path}/Dockerfile" ]]; then
    _log_err setup deploy_no_dockerfile "display=[setup] deploy: no Dockerfile at ${_base_path}; cannot build the field image." "path=${_base_path}"
    return 1
  fi

  local _name=""
  BASE_PATH="${_base_path}" detect_image_name _name "${_base_path}"
  [[ -z "${_output}" ]] && _output="${_base_path}/deploy/${_name}-${_stage}.tar.xz"

  # Per-parameter review: generate the launcher to a temp file and print
  # it so the user sees every inlined docker-level flag before building.
  if (( ! _quiet )); then
    local _preview
    _preview="$(mktemp)"
    _generate_deploy_sh "${_base_path}" "${_stage}" "${_name}:${_stage}" "${_name}-${_stage}" "${_preview}"
    printf '[setup] deploy plan: stage=%s image=%s:%s bundle=%s\n' \
      "${_stage}" "${_name}" "${_stage}" "${_output}"
    printf '[setup] field launcher to be generated (review every flag):\n'
    sed 's/^/    /' "${_preview}"
    rm -f "${_preview}"
  fi

  # Confirmation: skipped on --dry-run / -y; a non-tty shell without -y
  # refuses rather than build silently (mirrors reset).
  if (( ! _dry )) && (( ! _yes )); then
    if [[ ! -t 0 ]]; then
      _log_err setup deploy_needs_yes "display=[setup] deploy: refusing to build without confirmation in a non-interactive shell; pass -y to proceed."
      return 1
    fi
    printf "[setup] build the field image and write %s? [y/N]: " "${_output}"
    local _ans=""
    read -r _ans
    case "${_ans}" in
      y|Y|yes|YES) ;;
      *)
        _log_warn setup deploy_aborted "display=[setup] deploy aborted."
        return 1
        ;;
    esac
  fi

  mkdir -p "$(dirname -- "${_output}")"
  local _rc=0
  if (( _dry )); then
    DRY_RUN=true _generate_deploy_bundle "${_base_path}" "${_stage}" "${_output}" || _rc=$?
  else
    _generate_deploy_bundle "${_base_path}" "${_stage}" "${_output}" || _rc=$?
  fi
  if (( _rc != 0 )); then
    _log_err setup deploy_failed "display=[setup] deploy: bundle generation failed (rc=${_rc})." "rc=${_rc}"
    return "${_rc}"
  fi

  if (( ! _quiet )) && (( ! _dry )); then
    _log_info setup deploy_done "display=[setup] deploy bundle written: ${_output}"
    printf "[setup] field flow: tar -xJf %s && docker load < image.tar && ./deploy.sh\n" \
      "$(basename -- "${_output}")"
  fi
  return 0
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
    apply|check-drift|set|show|list|add|remove|reset|deploy)
      _subcmd="$1"
      shift
      ;;
    *)
      _log_err setup conf_unknown_subcmd "display=$(_setup_msg errors unknown_subcmd): $1" "subcmd=$1"
      return 1
      ;;
  esac

  # #440: pre-setup hook fires before any subcommand runs. Skipped
  # under --dry-run. Captured here (not per-subcommand) so all
  # subcommands get uniform pre/post coverage.
  _run_pre_hook setup "$@" || exit $?

  case "${_subcmd}" in
    apply)        _setup_apply       "$@" ;;
    check-drift)  _setup_check_drift "$@" ;;
    set)          _setup_set         "$@" ;;
    show)         _setup_show        "$@" ;;
    list)         _setup_list        "$@" ;;
    add)          _setup_add         "$@" ;;
    remove)       _setup_remove      "$@" ;;
    reset)        _setup_reset       "$@" ;;
    deploy)       _setup_deploy      "$@" ;;
  esac
  local _rc=$?

  # #440: post-setup hook fires after the subcommand returns.
  _run_post_hook setup "$@" || exit $?
  return "${_rc}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
