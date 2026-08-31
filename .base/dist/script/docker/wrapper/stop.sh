#!/usr/bin/env bash
# stop.sh - Stop and remove Docker containers

set -euo pipefail

# Shared wrapper preamble (sub-task A): resolve FILE_PATH across the
# symlink / script-subfolder / direct / /lint layouts, honor -C/--chdir,
# and source _lib.sh -- all in lib/bootstrap.sh. See build.sh for the
# locator rationale.
_bootstrap_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
for _bootstrap_cand in \
  "$(dirname -- "${_bootstrap_self}")/../lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/.base/dist/script/docker/lib/bootstrap.sh"; do
  if [[ -f "${_bootstrap_cand}" ]]; then
    # shellcheck source=dist/script/docker/lib/bootstrap.sh
    source "${_bootstrap_cand}"
    break
  fi
done
unset _bootstrap_self _bootstrap_cand
if ! declare -F _bootstrap >/dev/null 2>&1; then
  printf '[stop] ERROR: cannot find lib/bootstrap.sh (which sources _lib.sh) -- broken install?\n' >&2
  exit 1
fi
# _bootstrap also sources the wrapper runtime (lib/wrapper.sh) after
# _lib.sh, so _wrapper_lang_prepass is in scope below.
_bootstrap "$@"

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./stop.sh [-h] [-C|--chdir DIR] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止並移除容器。

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C
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
用法: ./stop.sh [-h] [-C|--chdir DIR] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

停止并移除容器。

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C
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
使用法: ./stop.sh [-h] [-C|--chdir DIR] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

コンテナを停止・削除します。

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）
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
Usage: ./stop.sh [-h] [-C|--chdir DIR] [--prune] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang LANG]

Stop and remove containers.

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's cwd
                    (mirrors git -C)
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

# _down_project tears down the repo's single compose project. base is
# single-instance: one fixed-name project per repo.
#
# COMPOSE_PROFILES='*' (compose v2.32+ wildcard) activates every profile in
# compose.yaml so `compose down` actually visits profile-gated services
# (auto-emitted headless / gui / test stages). Without this, profile-
# gated containers are silently skipped and remain running. --remove-orphans
# additionally catches containers from prior compose.yaml shapes that the
# current file no longer declares.
#
# -v / --verbose: list the containers belonging to the compose project
# before tearing them down. This gives the user a real signal instead of
# the previous no-op (the BUILDKIT_PROGRESS=plain env had zero effect on
# `compose down`,).
_down_project() {
  _compute_project_name
  if [[ "${VERBOSE:-}" == true ]]; then
    # _compute_project_name above guarantees PROJECT_NAME. Re-deriving a
    # fallback here would be a second producer of the same name, and the
    # -p that follows would not necessarily use it.
    local _project_name="${PROJECT_NAME}"
    local _matches
    _matches="$(docker ps -a \
      --filter "label=com.docker.compose.project=${_project_name}" \
      --format '{{.Names}} ({{.State}})' 2>/dev/null || true)"
    if [[ -n "${_matches}" ]]; then
      _log_info stop stop_teardown "display=Tearing down containers in project ${_project_name}:" "project=${_project_name}"
      printf '%s\n' "${_matches}" | sed 's/^/  /' >&2
    else
      _log_info stop stop_no_containers "display=No containers found for project ${_project_name}" "project=${_project_name}"
    fi
  fi
  COMPOSE_PROFILES='*' _compose_project down --remove-orphans "${PASSTHROUGH[@]}"
}

main() {
  _transcript_begin  # capture this run's output (no-op if disabled)
  # shared --lang pre-pass. See lib/wrapper.sh.
  _wrapper_lang_prepass stop "$@"

  local DO_PRUNE=false
  # VERBOSE is declared here, like every other flag this parser owns, so
  # -v/--verbose is the ONE way to switch the listing on. Left undeclared it
  # was also readable from the environment -- an ambient input nobody
  # designed, documented or named privately. `local` is visible to
  # _down_project (bash scopes dynamically), which is the only reader.
  local VERBOSE=false
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
      --prune)
        # Opt-in lightweight cleanup after compose down. Reclaims orphan
        # networks (10m grace, the common "address pool exhausted" fix)
        # and dangling images (24h grace). Volumes + buildx cache are
        # intentionally NOT covered here — use ./prune.sh for those.
        # Refs
        DO_PRUNE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # Print the container list belonging to the compose project
        # before tearing it down. BUILDKIT_PROGRESS=plain (the old
        # behaviour) had zero effect on `docker compose down`; replaced
        # with real verbose output.
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

  # Load .env.generated so DOCKER_HUB_USER / IMAGE_NAME are available below.
  _load_env "${FILE_PATH}/.env.generated"

  # pre-stop hook fires after env load, before docker stop.
  # Skipped under --dry-run.
  _run_pre_hook stop "$@" || exit $?

  _down_project

  _maybe_prune

  # post-stop hook fires at end of main, after compose down +
  # opt-in prune are complete.
  _run_post_hook stop "$@"
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
    _dry_run_cmd "${_net_cmd[@]}"
    _dry_run_cmd "${_img_cmd[@]}"
    return 0
  fi
  _log_info stop stop_prune_networks "display=Pruning orphan networks (until=10m)..."
  "${_net_cmd[@]}" || true
  _log_info stop stop_prune_images "display=Pruning dangling images (until=24h)..."
  "${_img_cmd[@]}" || true
}

main "$@"
