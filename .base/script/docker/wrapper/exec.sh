#!/usr/bin/env bash
# exec.sh - Execute commands in a running container

set -euo pipefail

# Shared wrapper preamble (#408 sub-task A): resolve FILE_PATH across the
# symlink / script-subfolder / direct / /lint layouts, honor -C/--chdir,
# and source _lib.sh -- all in lib/bootstrap.sh. See build.sh for the
# locator rationale.
_bootstrap_self="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
for _bootstrap_cand in \
  "$(dirname -- "${_bootstrap_self}")/../lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/lib/bootstrap.sh" \
  "$(dirname -- "${_bootstrap_self}")/.base/script/docker/lib/bootstrap.sh"; do
  if [[ -f "${_bootstrap_cand}" ]]; then
    # shellcheck source=script/docker/lib/bootstrap.sh
    source "${_bootstrap_cand}"
    break
  fi
done
unset _bootstrap_self _bootstrap_cand
if ! declare -F _bootstrap >/dev/null 2>&1; then
  printf '[exec] ERROR: cannot find lib/bootstrap.sh (which sources _lib.sh) -- broken install?\n' >&2
  exit 1
fi
_bootstrap "$@"

# i18n message tables — split by semantic category (#278 PR-2).
# Each _msg_<category> returns plain i18n body only; tag + LEVEL keyword
# are added by the _log_* caller (English-only; level keyword no longer
# translated — see #283).
_msg_errors() {
  case "${_LANG}:${1:?}" in
    # %s expanded by printf -v at the callsite (container name).
    zh-TW:not_running)  echo "容器 '%s' 未在執行中。" ;;
    zh-CN:not_running)  echo "容器 '%s' 未在运行中。" ;;
    ja:not_running)     echo "コンテナ '%s' は実行されていません。" ;;
    *:not_running)      echo "Container '%s' is not running." ;;
  esac
}

_msg_hints() {
  case "${_LANG}:${1:?}" in
    # %s expanded at the callsite (instance name).
    zh-TW:start_instance)  echo "請先以 './run.sh --instance %s' 啟動。" ;;
    zh-CN:start_instance)  echo "请先以 './run.sh --instance %s' 启动。" ;;
    ja:start_instance)     echo "まず './run.sh --instance %s' で起動してください。" ;;
    *:start_instance)      echo "Start it first with './run.sh --instance %s'." ;;
    zh-TW:start_default)   echo "請先以 './run.sh' 啟動（或使用 './run.sh --instance NAME' 啟動並行實例）。" ;;
    zh-CN:start_default)   echo "请先以 './run.sh' 启动（或使用 './run.sh --instance NAME' 启动并行实例）。" ;;
    ja:start_default)      echo "まず './run.sh' で起動してください（または './run.sh --instance NAME' で並列インスタンスを起動）。" ;;
    *:start_default)       echo "Start it first with './run.sh' (or use './run.sh --instance NAME' for a parallel one)." ;;
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
用法: ./exec.sh [-h] [-C|--chdir DIR] [-t TARGET] [--instance NAME] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [-T|--no-tty] [-i|--tty] [--lang LANG] [--] [CMD...]

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C / make -C。
                    須在 CMD 之前指定。
  -t, --target T    服務名稱（預設: devel）
  --instance NAME   進入命名 instance（預設為 default instance）
  --lang LANG       設定訊息語言（預設: en）
  --dry-run         只印出將執行的 docker 指令，不實際執行
  -v, --verbose     設定 BUILDKIT_PROGRESS=plain（與其他 wrapper 對齊；docker exec
                    本身不會 build，但保持 flag 一致便於肌肉記憶）。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
  -T, --no-tty      強制不分配 TTY（傳 -T 給 docker compose exec）。用於 one-shot
                    指令，避免終端 escape sequence 洩漏到 output。對於
                    `bash|sh|dash|zsh|ash|ksh -c '...'` 已自動偵測；此 flag
                    用來涵蓋 heuristic 漏網的 case，如 `whoami`、`ls /foo`、
                    `env BAR=1 bash -c '...'`。
  -i, --tty         強制分配 TTY（覆蓋 auto-detect）。用於少數需要 TTY 但走
                    `bash -c '...'` 的 case（例：`-i bash -c 'tput cols'`）。
                    與 -T 為 last-wins。
  --                明確分隔 exec.sh 選項與 CMD（與 run.sh 對齊），讓 CMD 可以
                    用 dash 開頭（例：./exec.sh -- my-tool --version）

參數:
  CMD              要執行的指令（預設: bash）

範例:
  ./exec.sh                    # 以 bash 進入 devel 容器
  ./exec.sh htop               # 在 devel 容器中執行 htop
  ./exec.sh ls -la /home       # 在 devel 容器中執行 ls
  ./exec.sh -t runtime bash    # 進入 runtime 容器
  ./exec.sh bash -c 'ls'       # 自動偵測 → -T，無 escape 洩漏
  ./exec.sh -T whoami          # 強制 -T 涵蓋 heuristic 漏網 case
  ./exec.sh -- my-tool --version  # 用 -- 把 dash-開頭 CMD 傳進容器
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./exec.sh [-h] [-C|--chdir DIR] [-t TARGET] [--instance NAME] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [-T|--no-tty] [-i|--tty] [--lang LANG] [--] [CMD...]

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C / make -C。
                    须在 CMD 之前指定。
  -t, --target T    服务名称（默认: devel）
  --instance NAME   进入命名 instance（默认为 default instance）
  --lang LANG       设置消息语言（默认: en）
  --dry-run         只打印将执行的 docker 命令，不实际执行
  -v, --verbose     设置 BUILDKIT_PROGRESS=plain（与其他 wrapper 对齐；docker exec
                    本身不会 build，但保持 flag 一致便于肌肉记忆）。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
  -T, --no-tty      强制不分配 TTY（传 -T 给 docker compose exec）。用于 one-shot
                    命令，避免终端 escape sequence 泄漏到 output。对于
                    `bash|sh|dash|zsh|ash|ksh -c '...'` 已自动检测；此 flag
                    用来覆盖 heuristic 漏网的 case，如 `whoami`、`ls /foo`、
                    `env BAR=1 bash -c '...'`。
  -i, --tty         强制分配 TTY（覆盖 auto-detect）。用于少数需要 TTY 但走
                    `bash -c '...'` 的 case（例：`-i bash -c 'tput cols'`）。
                    与 -T 为 last-wins。
  --                明确分隔 exec.sh 选项与 CMD（与 run.sh 对齐），让 CMD 可以
                    以 dash 开头（例：./exec.sh -- my-tool --version）

参数:
  CMD              要执行的命令（默认: bash）

示例:
  ./exec.sh                    # 以 bash 进入 devel 容器
  ./exec.sh htop               # 在 devel 容器中运行 htop
  ./exec.sh ls -la /home       # 在 devel 容器中运行 ls
  ./exec.sh -t runtime bash    # 进入 runtime 容器
  ./exec.sh bash -c 'ls'       # 自动检测 → -T，无 escape 泄漏
  ./exec.sh -T whoami          # 强制 -T 覆盖 heuristic 漏网 case
  ./exec.sh -- my-tool --version  # 用 -- 把 dash-开头 CMD 传入容器
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./exec.sh [-h] [-C|--chdir DIR] [-t TARGET] [--instance NAME] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [-T|--no-tty] [-i|--tty] [--lang LANG] [--] [CMD...]

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）。
                    git -C / make -C と同様。CMD の前に指定。
  -t, --target T    サービス名（デフォルト: devel）
  --instance NAME   名前付き instance に入る（デフォルトは default instance）
  --lang LANG       メッセージ言語を設定（デフォルト: en）
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose     BUILDKIT_PROGRESS=plain を設定（他の wrapper と整合；
                    docker exec 自体は build しないが、フラグの一貫性のため）。
  -vv, --very-verbose
                    -v に加え wrapper 自体の bash trace（set -x）。
  -T, --no-tty      TTY 割り当てを抑止（docker compose exec に -T を渡す）。
                    one-shot コマンドで端末の escape sequence が output に
                    漏れるのを防ぐ。`bash|sh|dash|zsh|ash|ksh -c '...'` は
                    自動検出される；本フラグは `whoami`、`ls /foo`、
                    `env BAR=1 bash -c '...'` など heuristic から外れた
                    case 用。
  -i, --tty         TTY 割り当てを強制（auto-detect を上書き）。`bash -c '...'`
                    だが TTY が必要な稀な case 用（例：`-i bash -c 'tput cols'`）。
                    -T とは last-wins。
  --                exec.sh のオプションと CMD を明示的に区切る（run.sh と整合）。
                    dash で始まる CMD を渡す場合に使う（例: ./exec.sh -- my-tool --version）

引数:
  CMD              実行するコマンド（デフォルト: bash）

例:
  ./exec.sh                    # bash で devel コンテナに接続
  ./exec.sh htop               # devel コンテナで htop を実行
  ./exec.sh ls -la /home       # devel コンテナで ls を実行
  ./exec.sh -t runtime bash    # runtime コンテナに接続
  ./exec.sh bash -c 'ls'       # 自動検出 → -T、escape 漏れなし
  ./exec.sh -T whoami          # 強制 -T で heuristic 漏れの case をカバー
  ./exec.sh -- my-tool --version  # -- で dash 始まりの CMD を渡す
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./exec.sh [-h] [-C|--chdir DIR] [-t TARGET] [--instance NAME] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [-T|--no-tty] [-i|--tty] [--lang LANG] [--] [CMD...]

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's
                    cwd. Mirrors git -C / make -C. Must come before the CMD.
  -t, --target T    Service name (default: devel)
  --instance NAME   Enter a named instance (default: default instance)
  --lang LANG       Set message language (default: en)
  --dry-run         Print the docker commands that would run, but do not execute
  -v, --verbose     Export BUILDKIT_PROGRESS=plain for parity with build/run/stop.
                    `docker exec` itself does not build, but keeping the flag
                    available across all four wrappers gives one muscle-memory
                    knob to reach for.
  -vv, --very-verbose
                    -v plus bash trace (set -x) on the wrapper itself.
  -T, --no-tty      Force no-TTY (pass -T to docker compose exec). Use for
                    one-shot commands so terminal escape sequences (focus-in,
                    bracketed-paste, …) do not leak into output. The forms
                    `bash|sh|dash|zsh|ash|ksh -c '...'` are auto-detected;
                    this flag covers the heuristic-misses case (`whoami`,
                    `ls /foo`, `env BAR=1 bash -c '...'`).
  -i, --tty         Force TTY (override auto-detect). Use for the rare case
                    where a `bash -c '...'` invocation genuinely wants a TTY
                    (e.g. `-i bash -c 'tput cols'`). Last-wins with -T.
  --                Explicit flag/CMD separator, mirroring run.sh. Lets the CMD
                    start with a dash (e.g. ./exec.sh -- my-tool --version).

Arguments:
  CMD              Command to execute (default: bash)

Examples:
  ./exec.sh                    # Enter devel container with bash
  ./exec.sh htop               # Run htop in devel container
  ./exec.sh ls -la /home       # Run ls in devel container
  ./exec.sh -t runtime bash    # Enter runtime container
  ./exec.sh bash -c 'ls'       # Auto-detect → -T, no escape leak
  ./exec.sh -T whoami          # Force -T to cover heuristic-misses case
  ./exec.sh -- my-tool --version  # Use -- to pass a dash-leading CMD
EOF
      ;;
  esac
  exit 0
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
      _sanitize_lang _LANG "exec"
      break
    fi
  done

  local TARGET="devel"
  local INSTANCE=""
  DRY_RUN=false
  # TTY mode resolution (#382): tracks the user's explicit choice with
  # last-wins precedence between -T (force no-tty) and -i (force tty).
  # Empty means no explicit choice; auto-detect runs below.
  local _tty_mode=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by the file-scope pre-pass that overrides
        # FILE_PATH; skip flag + value here.
        shift 2
        ;;
      -t|--target)
        TARGET="${2:?"--target requires a value"}"
        shift 2
        ;;
      --instance)
        INSTANCE="${2:?"--instance requires a value"}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # BUILDKIT_PROGRESS=plain — symmetry with build/run/stop (#311).
        # No-op for `docker exec` itself but harmless; useful for grep-
        # based discovery ("does this wrapper take -v? yes") and for the
        # rare case of `exec.sh` triggering a compose build via `--build`
        # in a future flag.
        export BUILDKIT_PROGRESS=plain
        shift
        ;;
      -vv|--very-verbose)
        export BUILDKIT_PROGRESS=plain
        set -x
        shift
        ;;
      -T|--no-tty)
        # Force no-TTY (#382). Use for one-shot CMDs the auto-detect
        # heuristic doesn't recognise (`whoami`, `ls /foo`,
        # `env BAR=1 bash -c '...'`) so terminal escape sequences
        # (focus-in, bracketed-paste, …) don't echo into output.
        _tty_mode="no-tty"
        shift
        ;;
      -i|--tty)
        # Force TTY (#382). Use to override the auto-detect heuristic
        # when a `bash -c '...'` invocation actually wants a TTY (rare;
        # e.g. `bash -c 'tput cols'`).
        _tty_mode="tty"
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "exec"
        shift 2
        ;;
      --)
        # Explicit flag/CMD separator, mirroring run.sh. Lets the user
        # send a CMD starting with a dash (e.g. `--version`) without it
        # being captured by exec.sh's own option parsing. Closes #289.
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done
  export DRY_RUN

  # Default to bash when no command is supplied. Using an array preserves
  # arguments containing whitespace, unlike the previous `${CMD}` splitting.
  if [[ $# -eq 0 ]]; then
    set -- bash
  fi

  # TTY mode resolution (#382, Option 1+2):
  # - explicit -T/-i (last-wins via _tty_mode set above) takes priority
  # - else auto-detect: positional CMD `bash|sh|dash|zsh|ash|ksh -c …`
  #   implies one-shot → no-TTY. Covers the 90% case where users wrap
  #   their command in `bash -c '…'`. Edge cases (`whoami`, prefixed
  #   `env BAR=1 bash -c …`) need explicit -T.
  # - else default: keep TTY (preserves `./exec.sh` / `./exec.sh htop`
  #   muscle memory).
  local _exec_extra_args=()
  if [[ "${_tty_mode}" == "no-tty" ]]; then
    _exec_extra_args+=(-T)
  elif [[ "${_tty_mode}" != "tty" ]]; then
    case "${1:-}" in
      bash|sh|dash|zsh|ash|ksh)
        if [[ "${2:-}" == "-c" ]]; then
          _exec_extra_args+=(-T)
        fi
        ;;
    esac
  fi

  # Load .env.generated, derive PROJECT_NAME (sets/exports INSTANCE_SUFFIX too).
  _load_env "${FILE_PATH}/.env.generated"
  _compute_project_name "${INSTANCE}"

  # Precheck: refuse with a friendly hint if the target container is not
  # running. Skipped under --dry-run since the user is asking what *would* run.
  # Container name mirrors compose.yaml's `container_name:`:
  #   - devel:           ${USER_NAME}-${IMAGE_NAME}${INSTANCE_SUFFIX}
  #   - non-devel stage: ${USER_NAME}-${IMAGE_NAME}-${TARGET}${INSTANCE_SUFFIX}
  # The ${USER_NAME} prefix landed in #322 (multi-user host
  # disambiguation); the per-stage ${TARGET} suffix is the convention
  # auto-emitted for headless / gui / test stages (#215). Refs #335 --
  # before this fix, the precheck always grepped for the devel-flavoured
  # name and aborted any ./exec.sh -t <non-devel> invocation.
  local _container_name="${USER_NAME}-${IMAGE_NAME}"
  if [[ "${TARGET}" != "devel" ]]; then
    _container_name="${_container_name}-${TARGET}"
  fi
  _container_name="${_container_name}${INSTANCE_SUFFIX}"
  if [[ "${DRY_RUN}" != true ]] \
      && ! docker ps --format '{{.Names}}' | grep -qx "${_container_name}"; then
    # Compose the error + matching hint into a single multi-line _log_err
    # block (the hint depends on whether INSTANCE was supplied).
    local _not_running _hint
    # shellcheck disable=SC2059
    printf -v _not_running "$(_msg errors not_running)" "${_container_name}"
    if [[ -n "${INSTANCE}" ]]; then
      # shellcheck disable=SC2059
      printf -v _hint "$(_msg hints start_instance)" "${INSTANCE}"
    else
      _hint="$(_msg hints start_default)"
    fi
    _log_err exec exec_not_running "display=${_not_running}
${_hint}"
    exit 1
  fi

  # #440: pre-exec hook fires after container-running check, before
  # the actual `compose exec`. Skipped under --dry-run.
  _run_pre_hook exec "$@" || exit $?

  _compose_project exec "${_exec_extra_args[@]}" "${TARGET}" "$@"
  local _exec_rc=$?

  # #440: post-exec hook fires after exec returns; container is still
  # running so the hook can `docker exec` for final reporting.
  _run_post_hook exec "$@" || exit $?
  return "${_exec_rc}"
}

main "$@"
