#!/usr/bin/env bash
# run.sh - Run Docker containers (interactive or detached)

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
  printf "[run] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/template/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

_msg() {
  local _key="${1:?}"
  case "${_LANG}:${_key}" in
    zh-TW:bootstrap_info)     echo "[run] 資訊：首次執行 — 初始化中..." ;;
    zh-CN:bootstrap_info)     echo "[run] 信息：首次运行 — 初始化中..." ;;
    ja:bootstrap_info)        echo "[run] 情報: 初回実行 — ブートストラップ中..." ;;
    *:bootstrap_info)         echo "[run] INFO: First run — bootstrapping..." ;;
    zh-TW:drift_regen)        echo "[run] 重新產生 .env / compose.yaml（setup.conf 已變更）" ;;
    zh-CN:drift_regen)        echo "[run] 重新生成 .env / compose.yaml（setup.conf 已变更）" ;;
    ja:drift_regen)           echo "[run] .env / compose.yaml を再生成中（setup.conf が変更されました）" ;;
    *:drift_regen)            echo "[run] regenerating .env / compose.yaml (setup.conf drifted)" ;;
    zh-TW:err_no_env)         echo "[run] 錯誤：setup 未產生 .env。" ;;
    zh-CN:err_no_env)         echo "[run] 错误：setup 未生成 .env。" ;;
    ja:err_no_env)            echo "[run] エラー: setup が .env を生成しませんでした。" ;;
    *:err_no_env)             echo "[run] ERROR: setup did not produce .env." ;;
    zh-TW:err_rerun_setup)    echo "[run] 請改以 './run.sh --setup' 重新執行以開啟編輯器。" ;;
    zh-CN:err_rerun_setup)    echo "[run] 请改以 './run.sh --setup' 重新运行以打开编辑器。" ;;
    ja:err_rerun_setup)       echo "[run] './run.sh --setup' で再実行してエディタを開いてください。" ;;
    *:err_rerun_setup)        echo "[run] Re-run with './run.sh --setup' to open the editor." ;;
    zh-TW:err_already_running) echo "[run] 錯誤：容器 '%s' 已在執行中。" ;;
    zh-CN:err_already_running) echo "[run] 错误：容器 '%s' 已在运行中。" ;;
    ja:err_already_running)   echo "[run] エラー: コンテナ '%s' はすでに実行中です。" ;;
    *:err_already_running)    echo "[run] ERROR: Container '%s' is already running." ;;
    zh-TW:err_stop_hint)      echo "[run] 請以 './stop.sh%s' 停止" ;;
    zh-CN:err_stop_hint)      echo "[run] 请以 './stop.sh%s' 停止" ;;
    ja:err_stop_hint)         echo "[run] './stop.sh%s' で停止してください" ;;
    *:err_stop_hint)          echo "[run] Either stop it with './stop.sh%s'" ;;
    zh-TW:err_parallel_hint)  echo "[run] 或使用 './run.sh --instance NAME' 啟動並行實例。" ;;
    zh-CN:err_parallel_hint)  echo "[run] 或使用 './run.sh --instance NAME' 启动并行实例。" ;;
    ja:err_parallel_hint)     echo "[run] または './run.sh --instance NAME' で並列インスタンスを起動してください。" ;;
    *:err_parallel_hint)      echo "[run] or start a parallel instance with './run.sh --instance NAME'." ;;
    # #216: --build invokes ./build.sh test before compose up
    zh-TW:pre_build_invoking) echo "正在執行 ./build.sh test（lint + smoke）..." ;;
    zh-CN:pre_build_invoking) echo "正在执行 ./build.sh test（lint + smoke）..." ;;
    ja:pre_build_invoking)    echo "./build.sh test を実行中（lint + smoke）..." ;;
    *:pre_build_invoking)     echo "Running ./build.sh test (lint + smoke) before compose up..." ;;
    # #216: soft guard — image missing, compose will auto-build
    zh-TW:auto_build_image_missing) echo "本機尚無此 image" ;;
    zh-CN:auto_build_image_missing) echo "本机尚无此 image" ;;
    ja:auto_build_image_missing)    echo "ローカルに image なし" ;;
    *:auto_build_image_missing)     echo "Image not found locally" ;;
    zh-TW:auto_build_skips_lint)    echo "Compose 即將 auto-build 此 image — 但**不會**跑 ShellCheck / Hadolint / Bats smoke。" ;;
    zh-CN:auto_build_skips_lint)    echo "Compose 即将 auto-build 此 image — 但**不会**跑 ShellCheck / Hadolint / Bats smoke。" ;;
    ja:auto_build_skips_lint)       echo "Compose が auto-build しますが、ShellCheck / Hadolint / Bats smoke は**実行されません**。" ;;
    *:auto_build_skips_lint)        echo "Compose will auto-build this image — but it will skip ShellCheck / Hadolint / Bats smoke." ;;
    zh-TW:auto_build_full_hint)     echo "完整驗證請執行: ./build.sh test   (或 ./run.sh --build 由本指令呼叫)" ;;
    zh-CN:auto_build_full_hint)     echo "完整验证请执行: ./build.sh test   (或 ./run.sh --build 由本指令调用)" ;;
    ja:auto_build_full_hint)        echo "完全な検証は: ./build.sh test を実行してください（または ./run.sh --build で本コマンド経由）" ;;
    *:auto_build_full_hint)         echo "For full verification: ./build.sh test  (or ./run.sh --build to do it now)" ;;
  esac
}

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--build] [--dry-run]
              [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>]
              [-t|--target TARGET] [CMD...]

選項:
  -h, --help        顯示此說明
  -t, --target T    Compose service 名稱（預設: devel；例: runtime）
  -d, --detach      背景執行（docker compose up -d，不接受 CMD）
  -s, --setup       強制重跑 setup.sh 重新生成 .env + compose.yaml
                    （預設：.env 不存在時自動 bootstrap；存在時僅印 drift warning）
  --build           在 compose up 前先跑 ./build.sh test（lint + smoke），
                    取得本機 / CI 一致驗證；預設行為依賴 compose auto-build
                    時會跳過 lint+smoke gate (#216)
  --dry-run         只印出將執行的 docker 指令，不實際執行
  --instance NAME   啟動命名 instance（與預設並行,suffix=-NAME）
  --lang LANG       設定訊息語言（預設: en）

CMD: 啟動容器後要執行的指令，對齊 `docker run <image> [cmd]` 語意：
  無 CMD  → 跑 Dockerfile 的 CMD（例: devel=bash, runtime=auto-run service）
  有 CMD  → 覆蓋 Dockerfile CMD（例: ./run.sh -t runtime bash 進 runtime shell）
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--build] [--dry-run]
              [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>]
              [-t|--target TARGET] [CMD...]

选项:
  -h, --help        显示此说明
  -t, --target T    Compose service 名称（默认: devel；例: runtime）
  -d, --detach      后台运行（docker compose up -d，不接受 CMD）
  -s, --setup       强制重跑 setup.sh 重新生成 .env + compose.yaml
                    （默认：.env 不存在时自动 bootstrap；存在时仅打印 drift warning）
  --build           在 compose up 前先跑 ./build.sh test（lint + smoke），
                    取得本机 / CI 一致验证；默认行为依赖 compose auto-build
                    时会跳过 lint+smoke gate (#216)
  --dry-run         只打印将执行的 docker 命令，不实际执行
  --instance NAME   启动命名 instance（与默认并行,suffix=-NAME）
  --lang LANG       设置消息语言（默认: en）

CMD: 启动容器后要执行的指令，对齐 `docker run <image> [cmd]` 语义:
  无 CMD  → 跑 Dockerfile 的 CMD（例: devel=bash, runtime=auto-run service）
  有 CMD  → 覆盖 Dockerfile CMD（例: ./run.sh -t runtime bash 进 runtime shell）
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./run.sh [-h] [-d|--detach] [-s|--setup] [--build] [--dry-run]
               [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>]
               [-t|--target TARGET] [CMD...]

オプション:
  -h, --help        このヘルプを表示
  -t, --target T    Compose サービス名（デフォルト: devel；例: runtime）
  -d, --detach      バックグラウンド実行（docker compose up -d、CMD は受け付けない）
  -s, --setup       setup.sh を強制実行して .env + compose.yaml を再生成
                    （デフォルト：.env が無ければ自動 bootstrap、あれば drift warning のみ）
  --build           compose up の前に ./build.sh test（lint + smoke）を実行し、
                    ローカル / CI の検証を一致させます。デフォルト動作は
                    compose auto-build に依存しており、lint + smoke gate を
                    スキップします (#216)
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  --instance NAME   名前付き instance を起動（デフォルトと並行、suffix=-NAME）
  --lang LANG       メッセージ言語を設定（デフォルト: en）

CMD: コンテナ起動後に実行するコマンド。`docker run <image> [cmd]` セマンティクス:
  CMD 無し → Dockerfile の CMD を実行（例: devel=bash, runtime=auto-run service）
  CMD あり → Dockerfile CMD を上書き（例: ./run.sh -t runtime bash で runtime shell）
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./run.sh [-h] [-d|--detach] [-s|--setup] [--build] [--dry-run]
               [--instance NAME] [--lang <en|zh-TW|zh-CN|ja>]
               [-t|--target TARGET] [CMD...]

Options:
  -h, --help        Show this help
  -t, --target T    Compose service name (default: devel; e.g. runtime)
  -d, --detach      Run in background (docker compose up -d; no CMD accepted)
  -s, --setup       Force rerun setup.sh to regenerate .env + compose.yaml
                    (default: auto-bootstrap if .env missing; warn on drift if present)
  --build           Run ./build.sh test (lint + smoke) before compose up
                    so local matches CI; default path relies on Compose
                    auto-build which skips the lint + smoke gate (#216)
  --dry-run         Print the docker commands that would run, but do not execute
  --instance NAME   Start a named parallel instance (suffix=-NAME)
  --lang LANG       Set message language (default: en)

CMD: Command to run after the container starts; mirrors `docker run <image> [cmd]`:
  no CMD  → run the Dockerfile CMD (e.g. devel=bash, runtime=auto-run service)
  with CMD → override the Dockerfile CMD (e.g. ./run.sh -t runtime bash to shell in)
EOF
      ;;
  esac
  exit 0
}

# _devel_cleanup tears down the project on shell exit so the container does
# not outlive the foreground `./run.sh` session.
#
# `down -t 0` skips the default 10s SIGTERM grace period: the user already
# exited the interactive bash, so there is nothing to drain gracefully —
# without -t 0 the script appears to hang for ~10s after `exit`.
_devel_cleanup() {
  _compose_project down -t 0 >/dev/null 2>&1 || true
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
      _sanitize_lang _LANG "run"
      break
    fi
  done

  local RUN_SETUP=false
  local DETACH=false
  local PRE_BUILD=false
  local TARGET="devel"
  local INSTANCE=""
  local -a CMD_ARGS=()
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -d|--detach)
        DETACH=true
        shift
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --build)
        # #216: opt-in lint+smoke pre-build via ./build.sh test before
        # `compose up`. Default path lets compose auto-build (which
        # skips the test stage entirely). Use this flag to get full
        # local CI parity on a fresh clone.
        PRE_BUILD=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --instance)
        INSTANCE="${2:?"--instance requires a value"}"
        shift 2
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "run"
        shift 2
        ;;
      -t|--target)
        TARGET="${2:?"-t/--target requires a value (e.g. devel, runtime)"}"
        shift 2
        ;;
      --)
        shift
        CMD_ARGS+=("$@")
        break
        ;;
      *)
        # Positional from here on is the CMD to run inside the container,
        # mirroring `docker run <image> [cmd...]` semantics. Empty CMD_ARGS
        # means "use the Dockerfile CMD".
        CMD_ARGS+=("$1")
        shift
        ;;
    esac
  done
  export DRY_RUN

  # -d is background `compose up`, which starts the service with its
  # compose-level command (for devel: tty/stdin_open keep it alive; for
  # runtime: the Dockerfile CMD runs headless). `up` has no slot for an
  # override cmd, so -d + CMD is ambiguous — refuse rather than silently
  # drop the cmd.
  if [[ "${DETACH}" == true ]] && (( ${#CMD_ARGS[@]} > 0 )); then
    printf "[run] ERROR: -d/--detach does not accept a CMD (got: %s). " "${CMD_ARGS[*]}" >&2
    printf "Use './exec.sh -t %s %s' to run a command inside a detached container.\n" \
      "${TARGET}" "${CMD_ARGS[*]}" >&2
    exit 2
  fi

  local _setup="${FILE_PATH}/template/script/docker/setup.sh"
  local _tui="${FILE_PATH}/setup_tui.sh"

  # _run_interactive: prefer setup_tui.sh when an interactive TTY is
  # present and the symlink is executable; otherwise fall back to
  # non-interactive setup.sh. Keeps CI / non-TTY paths unchanged.
  _run_interactive() {
    if [[ -t 0 && -t 1 && -x "${_tui}" ]]; then
      "${_tui}" --lang "${_LANG}"
    else
      "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  }

  # Decide whether to run setup.sh / setup_tui.sh:
  #   - --setup flag                         → interactive (TUI on TTY, else setup.sh)
  #   - missing .env / setup.conf / compose.yaml → non-interactive bootstrap
  #   - otherwise                            → drift-check only
  #
  # Bootstrap stays non-interactive (see build.sh for the full rationale):
  # compose.yaml is gitignored since v0.9.0, every fresh clone lands here,
  # and dispatching through the TUI would leave cancelled sessions
  # without a .env.
  if [[ "${RUN_SETUP}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${FILE_PATH}/.env" ]] \
      || [[ ! -f "${FILE_PATH}/setup.conf" ]] \
      || [[ ! -f "${FILE_PATH}/compose.yaml" ]]; then
    printf "%s\n" "$(_msg bootstrap_info)"
    "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
  else
    # Drift → auto-regen via subprocess (see build.sh for the full
    # rationale; subprocess avoids the #101 _msg shadow class).
    if ! "${_setup}" check-drift --base-path "${FILE_PATH}" --lang "${_LANG}"; then
      printf "%s\n" "$(_msg drift_regen)"
      "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  fi

  # Defensive: bootstrap must leave .env in place. See build.sh.
  if [[ ! -f "${FILE_PATH}/.env" ]]; then
    printf "%s\n" "$(_msg err_no_env)" >&2
    printf "%s\n" "$(_msg err_rerun_setup)" >&2
    exit 1
  fi

  # Load .env, derive PROJECT_NAME (sets/exports INSTANCE_SUFFIX too).
  _load_env "${FILE_PATH}/.env"
  _compute_project_name "${INSTANCE}"

  # Pre-run snapshot so the user can see which files + values this
  # invocation resolved to before the container replaces the shell.
  # Mute with QUIET=1 for piped / CI logs.
  [[ "${QUIET:-0}" != "1" ]] && _print_config_summary run

  # ── #216: soft guard for the auto-build path ──
  # Compose's auto-build (when image is missing locally) only walks
  # `target: devel` (or whatever -t says) and silently skips the
  # `target: test` stage that runs ShellCheck / Hadolint / Bats smoke.
  # On a fresh clone this means new contributors who reach for
  # ./run.sh first land in a working dev container without ever
  # hitting the lint/smoke gates that ./build.sh test enforces.
  #
  # Behavior:
  #   - --build → invoke ./build.sh test BEFORE compose up (full
  #     local-CI parity). Always runs, even if image is cached.
  #   - default + image absent + interactive TTY → print INFO before
  #     compose up so user knows the auto-build will skip lint/smoke.
  #   - default + image absent + non-TTY → silent (CI / cron context).
  #   - default + image present → silent (no auto-build will fire).
  #
  # Image inspect is per-target so ./run.sh -t headless checks
  # ${IMAGE_NAME}:headless (per #215 auto-emit naming), not :devel.
  if [[ "${PRE_BUILD}" == true && "${DRY_RUN}" != true ]]; then
    local _build_sh="${FILE_PATH}/build.sh"
    if [[ -x "${_build_sh}" ]]; then
      printf "[run] %s\n" "$(_msg pre_build_invoking)"
      "${_build_sh}" test
    fi
  elif [[ "${DRY_RUN}" != true ]]; then
    local _full_tag="${DOCKER_HUB_USER:-local}/${IMAGE_NAME}:${TARGET}"
    if ! docker image inspect "${_full_tag}" --format '{{.Id}}' \
         >/dev/null 2>&1; then
      # `[[ -t 2 ]]` checks if stderr is connected to a terminal
      # (interactive). RUN_FORCE_TTY=1 is a test-only override so unit
      # tests can exercise the TTY branch without a real PTY.
      if [[ "${RUN_FORCE_TTY:-0}" == "1" ]] || [[ -t 2 ]]; then
        printf "[run] %s: %s\n" "$(_msg auto_build_image_missing)" "${_full_tag}" >&2
        printf "[run] %s\n"     "$(_msg auto_build_skips_lint)"   >&2
        printf "[run] %s\n"     "$(_msg auto_build_full_hint)"    >&2
      fi
    fi
  fi

  # Allow X11 forwarding (X11 or XWayland)
  if [[ "${XDG_SESSION_TYPE:-x11}" == "wayland" ]]; then
    xhost "+SI:localuser:${USER_NAME}" >/dev/null 2>&1 || true
  else
    xhost +local: >/dev/null 2>&1 || true
  fi

  # Container name mirrors compose.yaml's `container_name:`.
  local CONTAINER_NAME="${IMAGE_NAME}${INSTANCE_SUFFIX}"

  # Refuse to start if the target container is already running and user did
  # not explicitly opt into a parallel instance via --instance.
  # (For -d mode, the existing `down` step handles restart, so collision is OK.)
  if [[ "${DETACH}" != true && "${TARGET}" == "devel" \
      && "${DRY_RUN}" != true ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
      # shellcheck disable=SC2059
      printf "$(_msg err_already_running)\n" "${CONTAINER_NAME}" >&2
      # shellcheck disable=SC2059
      printf "$(_msg err_stop_hint)\n" \
        "$([[ -n "${INSTANCE}" ]] && printf ' --instance %s' "${INSTANCE}")" >&2
      printf "%s\n" "$(_msg err_parallel_hint)" >&2
      exit 1
    fi
  fi

  if [[ "${DETACH}" == true ]]; then
    _compose_project down 2>/dev/null || true
    _compose_project up -d "${TARGET}"
  elif [[ "${TARGET}" == "devel" ]]; then
    # Foreground devel: `up -d` + `exec` so a second terminal can join via
    # `./exec.sh`. Trap auto-`down` on exit to preserve the
    # "exit shell = container gone" semantic of the previous `compose run`.
    # CMD_ARGS passthrough: empty → `bash` (matches Dockerfile CMD for devel);
    # non-empty → override (e.g. `./run.sh ls /tmp`).
    trap _devel_cleanup EXIT
    _compose_project up -d "${TARGET}"
    if (( ${#CMD_ARGS[@]} > 0 )); then
      _compose_project exec "${TARGET}" "${CMD_ARGS[@]}"
    else
      _compose_project exec "${TARGET}" bash
    fi
  else
    # Other one-shot stages (runtime, test, ...): `compose run --rm` with
    # CMD passthrough. Empty CMD_ARGS → service's Dockerfile CMD runs
    # (e.g. runtime auto-boots parameter_bridge). Non-empty overrides
    # (e.g. `./run.sh -t runtime bash` to debug interactively).
    if (( ${#CMD_ARGS[@]} > 0 )); then
      _compose_project run --rm "${TARGET}" "${CMD_ARGS[@]}"
    else
      _compose_project run --rm "${TARGET}"
    fi
  fi
}

main "$@"
