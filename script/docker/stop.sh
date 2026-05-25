#!/usr/bin/env bash
# stop.sh - Stop and remove Docker containers

set -euo pipefail

# `-C <dir>` / `--chdir <dir>` pre-pass — see build.sh for the full
# rationale (refs docker_harness#53). Override FILE_PATH before _lib.sh
# is sourced so all path-dependent operations honor the target repo.
# FILE_PATH detection covers root-symlink (pre-#330), script/-subfolder
# (post-#330), and direct invocation — see build.sh for the heuristic.
_FILE_PATH_INVOKE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -d "${_FILE_PATH_INVOKE_DIR}/.base" ]]; then
  FILE_PATH="${_FILE_PATH_INVOKE_DIR}"
elif [[ -d "${_FILE_PATH_INVOKE_DIR}/../.base" ]]; then
  FILE_PATH="$(cd -- "${_FILE_PATH_INVOKE_DIR}/.." && pwd -P)"
else
  FILE_PATH="${_FILE_PATH_INVOKE_DIR}"
fi
unset _FILE_PATH_INVOKE_DIR
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
用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止並移除容器。預設只停止 default instance。

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C / make -C
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（預設 + 全部命名 instance)
  --prune           stop 完後順手清 orphan networks (--filter until=10m) +
                    dangling images (--filter until=24h)。完整 prune（含
                    buildx cache / volumes）請用 ./prune.sh。
  --lang LANG       設定訊息語言（預設: en）
  --dry-run         只印出將執行的 docker 指令，不實際執行
  -v, --verbose     先列出該 compose project 下的 container（名稱 + 狀態），
                    再執行 down。讓 stop 流程的可見訊號跟 build/run/exec 對齊。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止并移除容器。默认只停止 default instance。

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C / make -C
  --instance NAME   只停止指定的命名 instance
  -a, --all         停止所有 instance（默认 + 全部命名 instance)
  --prune           stop 完后顺手清 orphan networks (--filter until=10m) +
                    dangling images (--filter until=24h)。完整 prune（含
                    buildx cache / volumes）请用 ./prune.sh。
  --lang LANG       设置消息语言（默认: en）
  --dry-run         只打印将执行的 docker 命令，不实际执行
  -v, --verbose     先列出该 compose project 下的 container（名称 + 状态），
                    再执行 down。让 stop 流程的可见信号跟 build/run/exec 对齐。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

コンテナを停止・削除します。デフォルトは default instance のみ。

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）
  --instance NAME   指定された名前付き instance のみ停止
  -a, --all         すべての instance を停止（デフォルト + 全名前付き instance）
  --prune           stop 完了後に orphan network (--filter until=10m) と
                    dangling image (--filter until=24h) も整理。完全 prune
                    （buildx cache / volume 含む）は ./prune.sh を使用。
  --lang LANG       メッセージ言語を設定（デフォルト: en）
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose     compose project 配下のコンテナ（名前と状態）を down の
                    前に出力。stop の可視シグナルを build/run/exec と揃える。
  -vv, --very-verbose
                    -v に加え wrapper 自体の bash trace（set -x）。
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./stop.sh [-h] [-C|--chdir DIR] [--instance NAME] [-a|--all] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

Stop and remove containers. Default: stop only the default instance.

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's cwd
                    (mirrors git -C / make -C)
  --instance NAME   Stop only the named instance
  -a, --all         Stop ALL instances (default + every named instance)
  --prune           After stopping, also reclaim orphan networks
                    (--filter until=10m) and dangling images
                    (--filter until=24h). For a richer clean (buildx
                    cache / volumes), use ./prune.sh.
  --lang LANG       Set message language (default: en)
  --dry-run         Print the docker commands that would run, but do not execute
  -v, --verbose     List the containers belonging to this compose project (name
                    + state) before tearing them down. Gives the stop flow a
                    real visible signal in parity with build/run/exec, instead
                    of the previous no-op BUILDKIT_PROGRESS=plain export.
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
# COMPOSE_PROFILES='*' (compose v2.32+ wildcard) activates every profile in
# compose.yaml so `compose down` actually visits profile-gated services
# (#215 auto-emitted headless / gui / test stages). Without this, profile-
# gated containers are silently skipped and remain running. --remove-orphans
# additionally catches containers from prior compose.yaml shapes that the
# current file no longer declares. Refs #341.
#
# -v / --verbose: list the containers belonging to the compose project
# before tearing them down. This gives the user a real signal instead of
# the previous no-op (the BUILDKIT_PROGRESS=plain env had zero effect on
# `compose down`, see #345).
#
# Args:
#   $1: instance name (empty for the default instance)
_down_one() {
  local instance="${1}"
  _compute_project_name "${instance}"
  if [[ "${VERBOSE:-}" == true ]]; then
    local _project_name
    _project_name="${PROJECT_NAME:-${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX}}"
    local _matches
    _matches="$(docker ps -a \
      --filter "label=com.docker.compose.project=${_project_name}" \
      --format '{{.Names}} ({{.State}})' 2>/dev/null || true)"
    if [[ -n "${_matches}" ]]; then
      _log_info stop "Tearing down containers in project ${_project_name}:"
      printf '%s\n' "${_matches}" | sed 's/^/  /' >&2
    else
      _log_info stop "No containers found for project ${_project_name}"
    fi
  fi
  COMPOSE_PROFILES='*' _compose_project down --remove-orphans "${PASSTHROUGH[@]}"
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
  local DO_PRUNE=false
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
      --prune)
        # Opt-in lightweight cleanup after compose down. Reclaims orphan
        # networks (10m grace, the common "address pool exhausted" fix)
        # and dangling images (24h grace). Volumes + buildx cache are
        # intentionally NOT covered here — use ./prune.sh for those.
        # Refs issue #319.
        DO_PRUNE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # Print the container list belonging to the compose project
        # before tearing it down. BUILDKIT_PROGRESS=plain (the old #311
        # behaviour) had zero effect on `docker compose down`; replaced
        # with real verbose output. Refs #345.
        VERBOSE=true
        export BUILDKIT_PROGRESS=plain
        shift
        ;;
      -vv|--very-verbose)
        VERBOSE=true
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
      # Still honor --prune even when no instance found, so a stale repo
      # with orphan networks/images from past runs gets cleaned.
      _maybe_prune
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

  _maybe_prune
}

# _maybe_prune runs the opt-in --prune cleanup after compose down has
# released the active networks/containers for this project. Lightweight
# fixed-grace prune (10m for networks, 24h for images); for richer
# control use ./prune.sh. No-op when --prune was not passed.
_maybe_prune() {
  [[ "${DO_PRUNE}" == true ]] || return 0
  local -a _net_cmd=(docker network prune -f --filter "until=10m")
  local -a _img_cmd=(docker image   prune -f --filter "until=24h")
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run]'; printf ' %q' "${_net_cmd[@]}"; printf '\n'
    printf '[dry-run]'; printf ' %q' "${_img_cmd[@]}"; printf '\n'
    return 0
  fi
  _log_info stop "Pruning orphan networks (until=10m)..."
  "${_net_cmd[@]}" || true
  _log_info stop "Pruning dangling images (until=24h)..."
  "${_img_cmd[@]}" || true
}

main "$@"
