#!/usr/bin/env bash
#
# help.sh - language-aware `just <ns> help` renderer (i18n).
#
# base already ships a structured, per-key-colocated i18n model: i18n.sh
# (_detect_lang / _resolve_lang / _sanitize_lang) plus the `_msg
# <category> <key>` dispatcher the docker wrappers use, where every
# language of a key sits together (zh-TW / zh-CN / ja / * arms). This
# renderer rides that same model to print each namespace recipe's
# one-line summary in the caller's language: `_msg help <ns>.<recipe>`
# returns the summary for the current _LANG, colocated per recipe key.
#
# `just --list` (and bare `just <ns>`) stay English: just's native
# listing cannot be intercepted (ADR-00000011 sec.6). This renderer is
# the rich translated entry point wired into each namespace `help`
# recipe (docker / base / template -- the localised namespaces; test /
# release are English-only per ADR-00000011).
#
# Usage: help.sh <namespace> [--lang <en|zh-TW|zh-CN|ja>]

set -euo pipefail

# Self-locate: source the sibling i18n.sh (same lib/ dir) regardless of
# the caller's cwd. readlink -f follows the consumer-repo symlink chain
# (script/<ns>/justfile.<ns> -> .base/dist/...), so the lib is found from
# either the base-self tree or a consumer subtree.
_help_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
_help_lib_dir="$(dirname -- "${_help_self}")"
# shellcheck source=dist/script/docker/lib/i18n.sh
source "${_help_lib_dir}/i18n.sh"
unset _help_self _help_lib_dir

# _msg dispatcher -- identical call-site shape to the docker wrappers
# (lib/wrapper.sh): `_msg <category> <key>` -> `_msg_<category> <key>`.
_msg() {
  local _category="${1:?_msg requires category}"
  local _key="${2:?_msg requires key}"
  "_msg_${_category}" "${_key}"
}

# _msg_help <key> -- one-line help strings, colocated per key across
# en(*) / zh-TW / zh-CN / ja (mirrors build.sh's _msg_<category> tables).
# Keys: `_header` (a printf format with one %s = namespace), `_tip`, and
# `<ns>.<recipe>` for each recipe summary.
_msg_help() {
  case "${_LANG}:${1:?}" in
    # ── shared chrome ──────────────────────────────────────────────
    zh-TW:_header) printf '可用指令（%%s）：' ;;
    zh-CN:_header) printf '可用命令（%%s）：' ;;
    ja:_header)    printf '利用可能なコマンド（%%s）：' ;;
    *:_header)     printf 'Available recipes (%%s):' ;;

    zh-TW:_tip) echo "提示：'just --list' 顯示原生英文清單。" ;;
    zh-CN:_tip) echo "提示：'just --list' 显示原生英文清单。" ;;
    ja:_tip)    echo "ヒント：'just --list' はネイティブの英語一覧を表示します。" ;;
    *:_tip)     echo "Tip: 'just --list' shows the native English listing." ;;

    # ── docker namespace ───────────────────────────────────────────
    zh-TW:docker.build) echo "建置 devel 映像（just docker build test | --no-cache）" ;;
    zh-CN:docker.build) echo "构建 devel 镜像（just docker build test | --no-cache）" ;;
    ja:docker.build)    echo "devel イメージをビルド（just docker build test | --no-cache）" ;;
    *:docker.build)     echo "Build the devel image (just docker build test | --no-cache)" ;;

    zh-TW:docker.run) echo "互動式啟動容器（just docker run | -d）" ;;
    zh-CN:docker.run) echo "交互式启动容器（just docker run | -d）" ;;
    ja:docker.run)    echo "コンテナを対話的に起動（just docker run | -d）" ;;
    *:docker.run)     echo "Run the container interactively (just docker run | -d)" ;;

    zh-TW:docker.start) echo "一步完成建置並啟動（just docker start | --no-cache）" ;;
    zh-CN:docker.start) echo "一步完成构建并启动（just docker start | --no-cache）" ;;
    ja:docker.start)    echo "ビルドと起動を一括実行（just docker start | --no-cache）" ;;
    *:docker.start)     echo "Build then run in one step (just docker start | --no-cache)" ;;

    zh-TW:docker.exec) echo "進入執行中的容器（just docker exec -t <svc> bash）" ;;
    zh-CN:docker.exec) echo "进入运行中的容器（just docker exec -t <svc> bash）" ;;
    ja:docker.exec)    echo "実行中のコンテナに入る（just docker exec -t <svc> bash）" ;;
    *:docker.exec)     echo "Exec into a running container (just docker exec -t <svc> bash)" ;;

    zh-TW:docker.stop) echo "停止並移除容器" ;;
    zh-CN:docker.stop) echo "停止并移除容器" ;;
    ja:docker.stop)    echo "コンテナを停止して削除" ;;
    *:docker.stop)     echo "Stop and remove the containers" ;;

    zh-TW:docker.prune) echo "清理建置快取與懸空映像" ;;
    zh-CN:docker.prune) echo "清理构建缓存与悬空镜像" ;;
    ja:docker.prune)    echo "ビルドキャッシュ / 未使用イメージを削除" ;;
    *:docker.prune)     echo "Prune build cache / dangling images" ;;

    zh-TW:docker.setup) echo "依 setup.conf 重新產生 .env.generated 與 compose.yaml" ;;
    zh-CN:docker.setup) echo "依 setup.conf 重新生成 .env.generated 与 compose.yaml" ;;
    ja:docker.setup)    echo "setup.conf から .env.generated と compose.yaml を再生成" ;;
    *:docker.setup)     echo "Regenerate .env.generated + compose.yaml from setup.conf" ;;

    zh-TW:docker.setup-tui) echo "以互動式 TUI 編輯 setup.conf" ;;
    zh-CN:docker.setup-tui) echo "以交互式 TUI 编辑 setup.conf" ;;
    ja:docker.setup-tui)    echo "対話型 TUI で setup.conf を編集" ;;
    *:docker.setup-tui)     echo "Interactive TUI to edit setup.conf" ;;

    # ── base namespace ─────────────────────────────────────────────
    zh-TW:base.upgrade) echo "拉取 .base subtree（just base upgrade [vX.Y.Z]；留空 = 最新）" ;;
    zh-CN:base.upgrade) echo "拉取 .base subtree（just base upgrade [vX.Y.Z]；留空 = 最新）" ;;
    ja:base.upgrade)    echo ".base subtree を取得（just base upgrade [vX.Y.Z]；空 = 最新）" ;;
    *:base.upgrade)     echo "Pull the .base subtree (just base upgrade [vX.Y.Z]; empty = latest)" ;;

    zh-TW:base.update) echo "檢查是否有較新的 base 版本（apt 風格）" ;;
    zh-CN:base.update) echo "检查是否有较新的 base 版本（apt 风格）" ;;
    ja:base.update)    echo "より新しい base タグの有無を確認（apt 風）" ;;
    *:base.update)     echo "Report whether a newer base tag is available (apt-style)" ;;

    zh-TW:base.init) echo "（重新）建立 repo 符號連結與 .gitignore" ;;
    zh-CN:base.init) echo "（重新）建立 repo 符号链接与 .gitignore" ;;
    ja:base.init)    echo "repo のシンボリックリンクと .gitignore を（再）設定" ;;
    *:base.init)     echo "(Re-)wire repo symlinks + .gitignore" ;;

    zh-TW:base.completions) echo "安裝／解除 shell tab 補全（選用）" ;;
    zh-CN:base.completions) echo "安装／卸载 shell tab 补全（可选）" ;;
    ja:base.completions)    echo "シェルのタブ補完をインストール / アンインストール（任意）" ;;
    *:base.completions)     echo "Install / uninstall shell tab-completion (opt-in)" ;;

    # ── template namespace ─────────────────────────────────────────
    zh-TW:template.new) echo "在 script/local/<name>/ 建立 repo 專屬命令群組" ;;
    zh-CN:template.new) echo "在 script/local/<name>/ 建立 repo 专属命令组" ;;
    ja:template.new)    echo "script/local/<name>/ に repo ローカルのコマンドグループを生成" ;;
    *:template.new)     echo "Scaffold a repo-local command group at script/local/<name>/" ;;
  esac
}

# ── main ───────────────────────────────────────────────────────────────
_ns="${1:?help.sh requires a namespace}"
shift

# Recipe order per localised namespace (mirrors the module justfiles).
# Adding a recipe = one entry here + a `_msg_help` arm (the same
# maintenance model as adding a runtime message).
case "${_ns}" in
  docker)   _help_recipes=(build run start exec stop prune setup setup-tui) ;;
  base)     _help_recipes=(upgrade update init completions) ;;
  template) _help_recipes=(new) ;;
  *)
    printf 'help.sh: unknown or English-only namespace %q (localised: docker|base|template)\n' \
      "${_ns}" >&2
    exit 2
    ;;
esac

# Effective language: SETUP_LANG / $LANG (i18n.sh), overridable by --lang.
_resolve_lang _LANG
while (( $# )); do
  case "$1" in
    --lang)   _LANG="${2:-}"; _sanitize_lang _LANG "${_ns} help"; shift 2 ;;
    --lang=*) _LANG="${1#*=}"; _sanitize_lang _LANG "${_ns} help"; shift ;;
    *)        shift ;;
  esac
done

# Header (%s = namespace), aligned `just <ns> <recipe>` column, then tip.
# shellcheck disable=SC2059  # translated format string is code-owned
printf "$(_msg help _header)\n" "${_ns}"
for _help_r in "${_help_recipes[@]}"; do
  printf '  %-22s %s\n' "just ${_ns} ${_help_r}" "$(_msg help "${_ns}.${_help_r}")"
done
printf '%s\n' "$(_msg help _tip)"
