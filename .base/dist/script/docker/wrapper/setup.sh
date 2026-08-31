#!/usr/bin/env bash
# setup.sh - Auto-detect system parameters and generate .env.generated +
# compose.yaml
#
# Reads the per-repo <repo>/.setup.conf override (falling back to the
# .base/dist/.setup.conf template default) for the repo's runtime
# configuration ([image] rules, [build] apt_mirror, [deploy] GPU,
# [gui], [network], [volumes]), runs system detection (UID/GID, hardware,
# docker hub user, GPU, GUI, workspace path), then emits:
#   - <repo>/.env.generated (variable values + SETUP_* metadata for drift
#                          detection; the hand-authored <repo>/.env overlay
#                          is scaffolded once and never rewritten)
#   - <repo>/compose.yaml  (full compose with baseline + conditional blocks)
#
# Both output files are derived artifacts (gitignored). Source of truth is
# setup.conf + system detection. WS_PATH is detected once and written back
# to <repo>/.setup.conf [volumes] mount_1; subsequent runs read mount_1.
#
# Usage: setup.sh [-h|--help] [--base-path <path>] [--lang en|zh-TW|zh-CN|ja]

# ── i18n messages ──────────────────────────────────────────────
# Resolve the symlink (<repo>/setup.sh → .base/dist/script/docker/setup.sh)
# so sibling sources (i18n.sh / _tui_conf.sh) are located in the
# template directory regardless of how the script was invoked.
_SETUP_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
_SETUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${_SETUP_SELF}")" && pwd -P)"
_SETUP_LIB_DIR="$(cd -- "${_SETUP_SCRIPT_DIR}/../lib" && pwd -P)"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/i18n.sh"
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_tui_conf.sh"
# setup.sh sources _lib.sh directly (not via _bootstrap), so set the
# verb here for transcript.sh's classification before the source.
export _WRAPPER_VERB=setup
# shellcheck disable=SC1091
source "${_SETUP_LIB_DIR}/_lib.sh"

# Part B: i18n.sh no longer seeds _LANG at source time -- resolve it
# explicitly so the _setup_msg_* tables work before --lang parsing (which
# overrides _LANG later via _sanitize_lang).
_resolve_lang _LANG

# i18n message table, split per category and routed through _log_*
# Renamed from a monolithic `_msg` to `_setup_msg`
# so sourcing this file from build.sh / run.sh doesn't
# silently shadow their own top-level `_msg`. The category split
# mirrors PR-2 (which did the same for build/run/exec/stop):
# each _setup_msg_<category> returns plain i18n body only; tag +
# LEVEL keyword are added by the _log_* caller (English-only; level
# keyword no longer translated —).

_setup_msg_env() {
  case "${_LANG}:${1:?}" in
    zh-TW:done)     echo ".env.generated 與 compose.yaml 更新完成" ;;
    zh-CN:done)     echo ".env.generated 与 compose.yaml 更新完成" ;;
    ja:done)        echo ".env.generated と compose.yaml 更新完了" ;;
    *:done)         echo ".env.generated + compose.yaml updated" ;;
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
    zh-TW:set)    echo "用法: setup.sh set <section>.<key> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:set)    echo "用法: setup.sh set <section>.<key> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    ja:set)       echo "使い方: setup.sh set <section>.<key> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    *:set)        echo "Usage: setup.sh set <section>.<key> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:show)   echo "用法: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    ja:show)      echo "使い方: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    *:show)       echo "Usage: setup.sh show <section>[.<key>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:list)   echo "用法: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    ja:list)      echo "使い方: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    *:list)       echo "Usage: setup.sh list [<section>] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:add)    echo "用法: setup.sh add <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:add)    echo "用法: setup.sh add <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    ja:add)       echo "使い方: setup.sh add <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    *:add)        echo "Usage: setup.sh add <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    zh-TW:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    zh-CN:remove) echo "用法: setup.sh remove <section>.<key> | <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    ja:remove)    echo "使い方: setup.sh remove <section>.<key> | <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
    *:remove)     echo "Usage: setup.sh remove <section>.<key> | <section>.<list> <value> [--local] [--base-path PATH] [--lang LANG]" ;;
  esac
}

_setup_msg_reset() {
  case "${_LANG}:${1:?}" in
    zh-TW:confirm)   echo "將以模板預設值覆寫 setup.conf（舊檔備份為 .setup.conf.bak / .env.bak）。繼續嗎？" ;;
    zh-CN:confirm)   echo "将以模板默认值覆写 setup.conf（旧文件备份为 .setup.conf.bak / .env.bak）。继续吗？" ;;
    ja:confirm)      echo "テンプレートのデフォルト値で setup.conf を上書きします（旧ファイルは .setup.conf.bak / .env.bak にバックアップ）。続行しますか？" ;;
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

_setup_msg_network() {
  case "${_LANG}:${1:?}" in
    zh-TW:ports_inert) echo "[network] 已設定 port_*，但生效的 mode 不是 bridge —— compose 只有在 mode = bridge 時才會發布 ports，因此該映射會被丟棄" ;;
    zh-CN:ports_inert) echo "[network] 已设置 port_*，但生效的 mode 不是 bridge —— compose 仅在 mode = bridge 时才会发布 ports，因此该映射会被丢弃" ;;
    ja:ports_inert)    echo "[network] に port_* が設定されていますが、有効な mode が bridge ではありません —— compose は mode = bridge のときだけ ports を公開するため、このマッピングは破棄されます" ;;
    *:ports_inert)     echo "[network] port_* is configured but the effective mode is not bridge -- compose publishes ports only under mode = bridge, so the mapping is dropped" ;;
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

Regenerate .env.generated + compose.yaml from setup.conf + system
detection. `.env` is the hand-authored workload overlay: apply scaffolds
it once and never rewrites it, so hand edits there are safe.
Normally invoked indirectly via `./build.sh --setup` or `./setup_tui.sh`
Save; run directly for non-interactive / scripted / CI use.

Subcommands:
  apply         (default) Regenerate .env.generated + compose.yaml. No-arg
                invocation falls back to apply for backward compat.
  check-drift   Compare current system / setup.conf against
                .env.generated's SETUP_* metadata. Exit 0 when in sync,
                exit 1 (with drift descriptions on stderr) when a regen
                is needed.
                Used by build.sh / run.sh to decide auto-regen.
  set <section>.<key> <value> [--local]
                Write a single value into <base-path>/.setup.conf
                (creates the section / key if missing). Validates
                known typed keys (deploy.gpu_count / volumes.mount_*
                / devices.cgroup_rule_* / network.port_* /
                environment.env_* / resources.shm_size). Does NOT
                regenerate .env.generated — run `apply` afterwards if
                needed.
                --local writes <base-path>/.setup.conf.local instead:
                the gitignored per-worktree layer, whose sections
                REPLACE the committed file's on this machine only.
                Without --local, a write to a section .setup.conf.local
                already defines is warned about by name -- it is still
                the value CI and other checkouts use, but it will not
                change anything here.
  show <section>[.<key>]
                Print the value of a single key, or all key=value
                pairs in a section (in on-disk order). Exits non-zero
                when the section / key is absent.
  list [<section>]
                Without an arg: print every section header + key in
                setup.conf. With an arg: equivalent to `show <section>`.
  add <section>.<list> <value> [--local]
                Append a value to a list-style section. Picks the next
                free numeric suffix (max+1) and writes `<list>_N = <value>`.
                e.g. `add volumes.mount /foo:/bar` lands in `mount_<next>`.
                Same validators, same --local target, as `set`.
  remove <section>.<key> [--local]            Delete the exact key.
  remove <section>.<list> <value> [--local]   Delete the first key under
                the section matching `<list>_*` whose value equals <value>.
                --local operates on .setup.conf.local instead.
  reset [-y|--yes]
                Overwrite setup.conf with the template default. Prior
                setup.conf / .env are saved to .setup.conf.bak / .env.bak.
                Without --yes, prompts for confirmation; non-tty
                without --yes refuses to proceed.
  deploy [--stage S] [--output D] [--dry-run] [-y|--yes]
         [--allow-local-override]
                Ships an image to the field. This is
                NOT the [deploy] section of setup.conf, which configures
                GPU reservation only and is named after Compose's
                `deploy:` key -- edit that with `./setup_tui.sh gpu`
                (`deploy` there is a kept alias).
                Build a self-contained field-deploy FOLDER for stage S
                (default runtime): docker build --target S tagged
                <name>:<stage>-<version>, docker save | xz, a fully-
                resolved self-contained compose.yaml (no variable
                interpolation, no setup.conf/.env dep, dev-host binds
                stripped, restart added, tunable-manifest config bound),
                a thin up/down/logs deploy.sh, editable config/, and a
                README. Previews the resolved compose (every resolved
                param) and prompts before building; --dry-run prints the
                plan only; -y skips the prompt. Default output is
                <base-path>/deploy/<name>-<stage>-<version>/. Field flow:
                copy the folder to the target, ./deploy.sh up.
                REFUSES while <base-path>/.setup.conf.local exists: that
                file is gitignored, so a bundle built from it cannot be
                reproduced from a clean checkout.
                --allow-local-override builds anyway and records the
                sections it took from that file in the bundle's README.

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

Host-detection overrides (env vars):
  These force a host-detection result instead of probing the host, so
  the matching auto modes (deploy.gpu_runtime/build.network = auto, and
  deploy.dri_groups = auto) resolve as if the host had that property.
  Behaviour is otherwise unchanged.
  SETUP_DETECT_JETSON=true|false
                        Force the Jetson check (normally tests for
                        /etc/nv_tegra_release). Set true to simulate a
                        Jetson on non-Jetson hardware, or false to pin
                        a non-Jetson result. Drives gpu_runtime=nvidia
                        and build network=host under `auto`.
  SETUP_DETECT_DRI_GROUPS="<gid> <gid> ..."
                        Force the /dev/dri owner GIDs granted via
                        group_add (normally stat'd from /dev/dri). Use
                        on containerised / CI hosts whose render-group
                        GIDs differ from the build host, or to pin them.
                        Empty string means "no /dev/dri groups".

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
  _transcript_begin  # capture this run's output (no-op if disabled)
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

  # pre-setup hook fires before any subcommand runs. Skipped
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

  # post-setup hook fires after the subcommand returns.
  _run_post_hook setup "$@" || exit $?
  return "${_rc}"
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
