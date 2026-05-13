#!/usr/bin/env bash
# stop.sh - Stop and remove Docker containers

set -euo pipefail

# `-C <dir>` / `--chdir <dir>` pre-pass — see build.sh for the full
# rationale (refs docker_harness#53). Override FILE_PATH before _lib.sh
# is sourced so all path-dependent operations honor the target repo.
FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_chdir_i=1
while (( _chdir_i <= $# )); do
  case "${!_chdir_i}" in
    -C|--chdir)
      _chdir_next=$((_chdir_i + 1))
      if (( _chdir_next > $# )) || [[ -z "${!_chdir_next:-}" ]]; then
        printf '[stop] ERROR: -C/--chdir requires a value\n' >&2
        exit 2
      fi
      _chdir_arg="${!_chdir_next}"
      if [[ ! -d "${_chdir_arg}" ]]; then
        printf '[stop] ERROR: -C target is not a directory: %s\n' "${_chdir_arg}" >&2
        exit 2
      fi
      FILE_PATH="$(cd -- "${_chdir_arg}" && pwd -P)"
      _chdir_i=$((_chdir_next + 1))
      ;;
    *)
      _chdir_i=$((_chdir_i + 1))
      ;;
  esac
done
unset _chdir_i _chdir_next _chdir_arg
readonly FILE_PATH
# _lib.sh lookup: .base/script/docker/_lib.sh in consumer repos, or
# sibling _lib.sh in /lint/ (Dockerfile test stage). See build.sh.
if [[ -f "${FILE_PATH}/.base/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/.base/script/docker/_lib.sh"
elif [[ -f "${FILE_PATH}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/_lib.sh"
else
  printf "[stop] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/.base/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

# i18n message tables — split by semantic category (#278 PR-2).
# Each _msg_<category> returns plain i18n body only; tag + LEVEL keyword
# are added by the _log_* caller (English-only; level keyword no longer
# translated — see #283).
_msg_info() {
  case "${_LANG}:${1:?}" in
    # %s expanded at the callsite (image name).
    zh-TW:no_instances) echo "未找到 %s 的執行中實例" ;;
    zh-CN:no_instances) echo "未找到 %s 的运行中实例" ;;
    ja:no_instances)    echo "%s のインスタンスが見つかりません" ;;
    *:no_instances)     echo "No instances found for %s" ;;
  esac
}

# Dispatcher — keeps a single _msg call site shape across the script.
_msg() {
  local _category="${1:?_msg requires category}"
  local _key="${2:?_msg requires key}"
  "_msg_${_category}" "${_key}"
}

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止並移除容器。預設只停止 default instance。

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C / make -C
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（預設 + 全部命名 instance)
  --lang LANG       設定訊息語言（預設: en）
  --dry-run         只印出將執行的 docker 指令，不實際執行
  -v, --verbose     設定 BUILDKIT_PROGRESS=plain（與其他 wrapper 對齊；stop 本身
                    不會 build，但保持 flag 一致便於肌肉記憶）。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止并移除容器。默认只停止 default instance。

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C / make -C
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（默认 + 全部命名 instance)
  --lang LANG       设置消息语言（默认: en）
  --dry-run         只打印将执行的 docker 命令，不实际执行
  -v, --verbose     设置 BUILDKIT_PROGRESS=plain（与其他 wrapper 对齐；stop 本身
                    不会 build，但保持 flag 一致便于肌肉记忆）。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

コンテナを停止・削除します。デフォルトは default instance のみ。

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）
  --instance NAME   指定された名前付き instance のみ停止
  -a, --all         すべての instance を停止（デフォルト + 全名前付き instance）
  --lang LANG       メッセージ言語を設定（デフォルト: en）
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose     BUILDKIT_PROGRESS=plain を設定（他の wrapper と整合；
                    stop 自体は build しないが、フラグの一貫性のため）。
  -vv, --very-verbose
                    -v に加え wrapper 自体の bash trace（set -x）。
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

Stop and remove containers. Default: stop only the default instance.

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's cwd
                    (mirrors git -C / make -C)
  --instance NAME   Stop only the named instance
  -a, --all         Stop ALL instances (default + every named instance)
  --lang LANG       Set message language (default: en)
  --dry-run         Print the docker commands that would run, but do not execute
  -v, --verbose     Export BUILDKIT_PROGRESS=plain for parity with build/run/exec.
                    `docker compose down` itself does not build, but keeping the
                    flag available across all four wrappers gives one
                    muscle-memory knob to reach for.
  -vv, --very-verbose
                    -v plus bash trace (set -x) on the wrapper itself.
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
  # Pre-pass: scan for --lang so usage() (which exits via -h/--help)
  # runs in the requested locale even when --help is the first arg.
  # See build.sh's main() for the full rationale (#222).
  local _i
  for (( _i=1; _i<=$#; _i++ )); do
    if [[ "${!_i}" == "--lang" ]]; then
      local _next=$((_i+1))
      _LANG="${!_next:-}"
      _sanitize_lang _LANG "stop"
      break
    fi
  done

  local INSTANCE=""
  local ALL_INSTANCES=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by the file-scope pre-pass that overrides
        # FILE_PATH; skip flag + value here. Without this branch the
        # `*)` catch-all below would dump -C / DIR into PASSTHROUGH and
        # docker compose down would reject them.
        shift 2
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
      -v|--verbose)
        # BUILDKIT_PROGRESS=plain — symmetry with build/run/exec (#311).
        # No-op for `docker compose down` itself but harmless; keeps the
        # flag available across all four wrappers for muscle-memory
        # consistency.
        export BUILDKIT_PROGRESS=plain
        shift
        ;;
      -vv|--very-verbose)
        export BUILDKIT_PROGRESS=plain
        set -x
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
      local _no_inst
      # shellcheck disable=SC2059
      printf -v _no_inst "$(_msg info no_instances)" "${IMAGE_NAME}"
      _log_info stop "${_no_inst}"
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
