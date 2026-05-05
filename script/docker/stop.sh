#!/usr/bin/env bash
# stop.sh - Stop and remove Docker containers

set -euo pipefail

FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH
# _lib.sh lookup: template/script/docker/_lib.sh in consumer repos, or
# sibling _lib.sh in /lint/ (Dockerfile test stage). See build.sh.
if [[ -f "${FILE_PATH}/template/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/template/script/docker/_lib.sh"
elif [[ -f "${FILE_PATH}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/_lib.sh"
else
  printf "[stop] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/template/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

_msg() {
  local _key="${1:?}"
  case "${_LANG}:${_key}" in
    zh-TW:no_instances) echo "[stop] 未找到 %s 的執行中實例" ;;
    zh-CN:no_instances) echo "[stop] 未找到 %s 的运行中实例" ;;
    ja:no_instances)    echo "[stop] %s のインスタンスが見つかりません" ;;
    *:no_instances)     echo "[stop] No instances found for %s" ;;
  esac
}

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [--instance NAME] [-a|--all] [--dry-run] [--lang LANG]

停止並移除容器。預設只停止 default instance。

選項:
  -h, --help        顯示此說明
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（預設 + 全部命名 instance)
  --lang LANG       設定訊息語言（預設: en）
  --dry-run         只印出將執行的 docker 指令，不實際執行
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [--instance NAME] [-a|--all] [--dry-run] [--lang LANG]

停止并移除容器。默认只停止 default instance。

选项:
  -h, --help        显示此说明
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（默认 + 全部命名 instance)
  --lang LANG       设置消息语言（默认: en）
  --dry-run         只打印将执行的 docker 命令，不实际执行
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./stop.sh [-h] [--instance NAME] [-a|--all] [--dry-run] [--lang LANG]

コンテナを停止・削除します。デフォルトは default instance のみ。

オプション:
  -h, --help        このヘルプを表示
  --instance NAME   指定された名前付き instance のみ停止
  -a, --all         すべての instance を停止（デフォルト + 全名前付き instance）
  --lang LANG       メッセージ言語を設定（デフォルト: en）
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./stop.sh [-h] [--instance NAME] [-a|--all] [--dry-run] [--lang LANG]

Stop and remove containers. Default: stop only the default instance.

Options:
  -h, --help        Show this help
  --instance NAME   Stop only the named instance
  -a, --all         Stop ALL instances (default + every named instance)
  --lang LANG       Set message language (default: en)
  --dry-run         Print the docker commands that would run, but do not execute
EOF
      ;;
  esac
  exit 0
}

PASSTHROUGH=()

# _down_one tears down a single instance. _compute_project_name sets and
# exports INSTANCE_SUFFIX so compose.yaml resolves the matching container_name.
#
# Args:
#   $1: instance name (empty for the default instance)
_down_one() {
  local instance="${1}"
  _compute_project_name "${instance}"
  _compose_project down "${PASSTHROUGH[@]}"
}

main() {
  local INSTANCE=""
  local ALL_INSTANCES=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      --instance)
        INSTANCE="${2:?"--instance requires a value"}"
        shift 2
        ;;
      -a|--all)
        ALL_INSTANCES=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "stop"
        shift 2
        ;;
      *)
        PASSTHROUGH+=("$1")
        shift
        ;;
    esac
  done
  export DRY_RUN

  # Load .env so DOCKER_HUB_USER / IMAGE_NAME are available below.
  _load_env "${FILE_PATH}/.env"

  if [[ "${ALL_INSTANCES}" == true ]]; then
    # Find all docker compose projects whose name starts with our prefix.
    local _prefix="${DOCKER_HUB_USER}-${IMAGE_NAME}"
    local _projects
    mapfile -t _projects < <(
      docker ps -a --format '{{.Label "com.docker.compose.project"}}' \
        | sort -u | grep -E "^${_prefix}(\$|-)" || true
    )
    if [[ ${#_projects[@]} -eq 0 ]]; then
      # shellcheck disable=SC2059
      printf "$(_msg no_instances)\n" "${IMAGE_NAME}" >&2
      exit 0
    fi
    local _proj _suffix
    for _proj in "${_projects[@]}"; do
      _suffix="${_proj#"${_prefix}"}"
      # _suffix is "" or "-name"; _down_one expects bare instance, strip dash.
      _down_one "${_suffix#-}"
    done
  elif [[ -n "${INSTANCE}" ]]; then
    _down_one "${INSTANCE}"
  else
    _down_one ""
  fi
}

main "$@"
