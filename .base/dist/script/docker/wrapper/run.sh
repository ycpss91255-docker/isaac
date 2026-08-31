#!/usr/bin/env bash
# run.sh - Run Docker containers (interactive or detached)

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
  printf '[run] ERROR: cannot find lib/bootstrap.sh (which sources _lib.sh) -- broken install?\n' >&2
  exit 1
fi
# _bootstrap also sources the wrapper runtime (lib/wrapper.sh) after
# _lib.sh, so _msg / _wrapper_lang_prepass / _wrapper_setup_sync are in
# scope below.
_bootstrap "$@"

# i18n message tables — split by semantic category (PR-2).
# Each _msg_<category> returns plain i18n body only; tag + LEVEL keyword
# are added by the _log_* caller (English-only; level keyword no longer
# translated —).
_msg_bootstrap() {
  case "${_LANG}:${1:?}" in
    zh-TW:info)  echo "首次執行 — 初始化中..." ;;
    zh-CN:info)  echo "首次运行 — 初始化中..." ;;
    ja:info)     echo "初回実行 — ブートストラップ中..." ;;
    *:info)      echo "First run — bootstrapping..." ;;
  esac
}

_msg_drift() {
  case "${_LANG}:${1:?}" in
    zh-TW:regen)  echo "重新產生 .env.generated / compose.yaml（setup.conf 已變更）" ;;
    zh-CN:regen)  echo "重新生成 .env.generated / compose.yaml（setup.conf 已变更）" ;;
    ja:regen)     echo ".env.generated / compose.yaml を再生成中（setup.conf が変更されました）" ;;
    *:regen)      echo "regenerating .env.generated / compose.yaml (setup.conf drifted)" ;;
  esac
}

_msg_errors() {
  case "${_LANG}:${1:?}" in
    zh-TW:no_env)            echo "setup 未產生 .env.generated。" ;;
    zh-CN:no_env)            echo "setup 未生成 .env.generated。" ;;
    ja:no_env)               echo "setup が .env.generated を生成しませんでした。" ;;
    *:no_env)                echo "setup did not produce .env.generated." ;;
    zh-TW:rerun_setup)       echo "請改以 './run.sh --setup' 重新執行以開啟編輯器。" ;;
    zh-CN:rerun_setup)       echo "请改以 './run.sh --setup' 重新运行以打开编辑器。" ;;
    ja:rerun_setup)          echo "'./run.sh --setup' で再実行してエディタを開いてください。" ;;
    *:rerun_setup)           echo "Re-run with './run.sh --setup' to open the editor." ;;
    # %s expanded by printf -v at the callsite (container name).
    zh-TW:already_running)   echo "容器 '%s' 已在執行中。" ;;
    zh-CN:already_running)   echo "容器 '%s' 已在运行中。" ;;
    ja:already_running)      echo "コンテナ '%s' はすでに実行中です。" ;;
    *:already_running)       echo "Container '%s' is already running." ;;
  esac
}

_msg_hints() {
  case "${_LANG}:${1:?}" in
    zh-TW:stop_hint)      echo "請以 './stop.sh' 停止。" ;;
    zh-CN:stop_hint)      echo "请以 './stop.sh' 停止。" ;;
    ja:stop_hint)         echo "'./stop.sh' で停止してください。" ;;
    *:stop_hint)          echo "Stop it with './stop.sh'." ;;
  esac
}

# --build flow + first-run auto-delegate messages.
_msg_build() {
  case "${_LANG}:${1:?}" in
    zh-TW:invoking)      echo "正在執行 ./build.sh test（lint + smoke）..." ;;
    zh-CN:invoking)      echo "正在执行 ./build.sh test（lint + smoke）..." ;;
    ja:invoking)         echo "./build.sh test を実行中（lint + smoke）..." ;;
    *:invoking)          echo "Running ./build.sh test (lint + smoke) before compose up..." ;;
    zh-TW:image_missing) echo "本機尚無此 image" ;;
    zh-CN:image_missing) echo "本机尚无此 image" ;;
    ja:image_missing)    echo "ローカルに image なし" ;;
    *:image_missing)     echo "Image not found locally" ;;
    zh-TW:delegating)    echo "委派給 ./build.sh 建置..." ;;
    zh-CN:delegating)    echo "委派给 ./build.sh 构建..." ;;
    ja:delegating)       echo "./build.sh にビルドを委譲中..." ;;
    *:delegating)        echo "Delegating to ./build.sh..." ;;
  esac
}

# _msg dispatcher provided by lib/wrapper.sh.

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-C|--chdir DIR] [-d|--detach] [--no-rm] [-s|--setup]
              [--build] [--dry-run] [-v|--verbose] [-vv|--very-verbose]
              [--lang <en|zh-TW|zh-CN|ja>]
              [-t|--target TARGET] [CMD...]

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd）。須在 CMD 之前指定；
                    若 CMD 中需要字面 -C，可用 -- 分隔。類似 git -C。
  -t, --target T    Compose service 名稱（預設: devel；例: runtime）
  -d, --detach      背景執行（docker compose up -d，不接受 CMD）
  --no-rm           關閉 foreground 結束時的自動 compose down (#386)。預設前景
                    執行結束（含 Ctrl-C / signal）會自動清掉 container + project
                    default network；--no-rm 保留現有 container/network 供之後
                    ./exec.sh 重連或檢查 log。-d 本來就由使用者管理 lifecycle，
                    本旗標對 -d 無作用。
  -s, --setup       強制重跑 setup.sh（互動式 TTY 開 TUI，否則非互動式 apply）。
                    預設（無此旗標）：當 setup.conf / Dockerfile stages / GPU /
                    GUI / USER_UID 漂移時，.env.generated + compose.yaml 自動重新生成 (#88)。
  --build           在 compose up 前先跑 ./build.sh test（lint + smoke），
                    取得本機 / CI 一致驗證；預設行為依賴 compose auto-build
                    時會跳過 lint+smoke gate (#216)
  --dry-run         只印出將執行的 docker 指令，不實際執行
  -v, --verbose     詳細 docker 輸出（BUILDKIT_PROGRESS=plain）。compose 自動 build
                    卡住時用 — 顯示每個 RUN 步驟即時輸出，不再收斂成單行進度條。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
  --lang LANG       設定訊息語言（預設: en）

CMD: 啟動容器後要執行的指令，對齊 `docker run <image> [cmd]` 語意：
  無 CMD  → 跑 Dockerfile 的 CMD（例: devel=bash, runtime=auto-run service）
  有 CMD  → 覆蓋 Dockerfile CMD（例: ./run.sh -t runtime bash 進 runtime shell）
  --      → 分隔 run.sh 旗標與 CMD；-- 之後的全部參數視為 CMD，不再由 run.sh 解析。
            當 CMD 本身有 --target 等與 run.sh 衝突的旗標時必須使用。
            例: ./run.sh -t cli -- sdkmanager --target JETSON --flash

環境變數:
  QUIET=1  關閉 run 前印出的組態摘要（適合 piped / CI log）。與
           setup.sh 的 -q/--quiet 不同：那個管的是別的輸出。
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./run.sh [-h] [-C|--chdir DIR] [-d|--detach] [--no-rm] [-s|--setup]
              [--build] [--dry-run] [-v|--verbose] [-vv|--very-verbose]
              [--lang <en|zh-TW|zh-CN|ja>]
              [-t|--target TARGET] [CMD...]

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd）。须在 CMD 之前指定；
                    若 CMD 中需要字面 -C，可用 -- 分隔。类似 git -C。
  -t, --target T    Compose service 名称（默认: devel；例: runtime）
  -d, --detach      后台运行（docker compose up -d，不接受 CMD）
  --no-rm           关闭 foreground 结束时的自动 compose down (#386)。默认前台
                    执行结束（含 Ctrl-C / signal）会自动清掉 container + project
                    default network；--no-rm 保留现有 container/network 供之后
                    ./exec.sh 重连或检查 log。-d 本来就由使用者管理 lifecycle，
                    本旗标对 -d 无作用。
  -s, --setup       强制重跑 setup.sh（交互式 TTY 开 TUI，否则非交互式 apply）。
                    默认（无此旗标）：当 setup.conf / Dockerfile stages / GPU /
                    GUI / USER_UID 漂移时，.env.generated + compose.yaml 自动重新生成 (#88)。
  --build           在 compose up 前先跑 ./build.sh test（lint + smoke），
                    取得本机 / CI 一致验证；默认行为依赖 compose auto-build
                    时会跳过 lint+smoke gate (#216)
  --dry-run         只打印将执行的 docker 命令，不实际执行
  -v, --verbose     详细 docker 输出（BUILDKIT_PROGRESS=plain）。compose 自动 build
                    卡住时用 — 显示每个 RUN 步骤实时输出，不再收敛成单行进度条。
  -vv, --very-verbose
                    -v 再加 wrapper 本身的 bash trace（set -x）。
  --lang LANG       设置消息语言（默认: en）

CMD: 启动容器后要执行的指令，对齐 `docker run <image> [cmd]` 语义:
  无 CMD  → 跑 Dockerfile 的 CMD（例: devel=bash, runtime=auto-run service）
  有 CMD  → 覆盖 Dockerfile CMD（例: ./run.sh -t runtime bash 进 runtime shell）
  --      → 分隔 run.sh 旗标与 CMD；-- 之后的全部参数视为 CMD，不再由 run.sh 解析。
            当 CMD 本身有 --target 等与 run.sh 冲突的旗标时必须使用。
            例: ./run.sh -t cli -- sdkmanager --target JETSON --flash

环境变量:
  QUIET=1  关闭 run 前打印的配置摘要（适合 piped / CI log）。与
           setup.sh 的 -q/--quiet 不同：那个管的是别的输出。
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./run.sh [-h] [-C|--chdir DIR] [-d|--detach] [--no-rm] [-s|--setup]
               [--build] [--dry-run] [-v|--verbose] [-vv|--very-verbose]
               [--lang <en|zh-TW|zh-CN|ja>]
               [-t|--target TARGET] [CMD...]

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）。
                    CMD の前に指定。CMD に字面の -C が必要なら -- で区切る。
                    git -C と同様。
  -t, --target T    Compose サービス名（デフォルト: devel；例: runtime）
  -d, --detach      バックグラウンド実行（docker compose up -d、CMD は受け付けない）
  --no-rm           foreground 終了時の自動 compose down を無効化 (#386)。
                    デフォルトでは foreground 実行終了時（Ctrl-C / signal 含む）
                    に container + project default network を自動で削除します。
                    --no-rm は現状の container/network を残し、後で ./exec.sh
                    で再接続したりログを確認できるようにします。-d は本来
                    ユーザがライフサイクル管理する想定なので、この旗標は -d に
                    は影響しません。
  -s, --setup       setup.sh を強制実行（インタラクティブ TTY なら TUI、それ以外
                    は非インタラクティブ apply）。デフォルト（フラグ無し）：setup.conf
                    / Dockerfile stages / GPU / GUI / USER_UID が drift した時、
                    .env.generated + compose.yaml が自動再生成されます (#88)。
  --build           compose up の前に ./build.sh test（lint + smoke）を実行し、
                    ローカル / CI の検証を一致させます。デフォルト動作は
                    compose auto-build に依存しており、lint + smoke gate を
                    スキップします (#216)
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose     docker の詳細出力（BUILDKIT_PROGRESS=plain）。compose 自動
                    build がハングした時に使用 — 各 RUN ステップの stdout/stderr
                    をリアルタイム表示。
  -vv, --very-verbose
                    -v に加え wrapper 自体の bash trace（set -x）。
  --lang LANG       メッセージ言語を設定（デフォルト: en）

CMD: コンテナ起動後に実行するコマンド。`docker run <image> [cmd]` セマンティクス:
  CMD 無し → Dockerfile の CMD を実行（例: devel=bash, runtime=auto-run service）
  CMD あり → Dockerfile CMD を上書き（例: ./run.sh -t runtime bash で runtime shell）
  --      → run.sh フラグと CMD を分離。-- 以降の全引数は CMD として扱い、run.sh は
            解析しません。CMD 自体に --target 等 run.sh と衝突するフラグがある場合に
            使用。例: ./run.sh -t cli -- sdkmanager --target JETSON --flash

環境変数:
  QUIET=1  実行前に表示される設定サマリーを抑止（piped / CI ログ向け）。
           setup.sh の -q/--quiet とは別物で、対象が異なります。
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./run.sh [-h] [-C|--chdir DIR] [-d|--detach] [--no-rm] [-s|--setup]
               [--build] [--dry-run] [-v|--verbose] [-vv|--very-verbose]
               [--lang <en|zh-TW|zh-CN|ja>]
               [-t|--target TARGET] [CMD...]

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's
                    cwd. Must come before the CMD; use -- to separate if you
                    need a literal -C inside CMD. Mirrors git -C.
  -t, --target T    Compose service name (default: devel; e.g. runtime)
  -d, --detach      Run in background (docker compose up -d; no CMD accepted)
  --no-rm           Disable auto compose-down on foreground exit (#386).
                    By default, exiting a foreground run (including Ctrl-C
                    or signal) tears down the container + project default
                    network. Pass --no-rm to keep them around for later
                    ./exec.sh reattach or log inspection. -d already
                    leaves lifecycle to the user, so this flag is a no-op
                    in detached mode.
  -s, --setup       Force rerun setup.sh (opens the TUI on an interactive TTY,
                    otherwise non-interactive apply). Default (no flag):
                    auto-regenerate .env.generated + compose.yaml when setup.conf /
                    Dockerfile stages / GPU / GUI / USER_UID drift (#88).
  --build           Run ./build.sh test (lint + smoke) before compose up
                    so local matches CI; default path relies on Compose
                    auto-build which skips the lint + smoke gate (#216)
  --dry-run         Print the docker commands that would run, but do not execute
  -v, --verbose     Verbose docker output (BUILDKIT_PROGRESS=plain). Use when
                    compose's auto-build appears hung — surfaces each RUN
                    step's real-time stdout/stderr instead of the collapsed
                    single-line progress UI.
  -vv, --very-verbose
                    -v plus bash trace (set -x) on the wrapper itself.
  --lang LANG       Set message language (default: en)

CMD: Command to run after the container starts; mirrors `docker run <image> [cmd]`:
  no CMD  → run the Dockerfile CMD (e.g. devel=bash, runtime=auto-run service)
  with CMD → override the Dockerfile CMD (e.g. ./run.sh -t runtime bash to shell in)
  --      → separates run.sh flags from CMD; everything after -- is passed as CMD
            without further parsing by run.sh. Required when CMD has flags that
            collide with run.sh (e.g. --target).
            Example: ./run.sh -t cli -- sdkmanager --target JETSON --flash

Environment:
  QUIET=1  Mute the configuration summary printed before the run (for
           piped / CI logs). Distinct from setup.sh's -q/--quiet, which
           silences a different surface.
EOF
      ;;
  esac
  exit 0
}

# _app_cleanup tears down the project on shell exit so the container
# and its compose-project default network do not outlive the foreground
# `./run.sh` session. Installed via `trap ... EXIT` in foreground mode by
# default; covers normal exit, Ctrl-C, and signal termination.
#
# Mirrors stop.sh's _down_one teardown: `COMPOSE_PROFILES='*'` activates
# every profile-gated service and `--remove-orphans` catches the
# default network plus containers from prior compose.yaml shapes. The
# leak this prevents: worktree workflows where `git worktree remove`
# wipes the cwd before `./stop.sh` ever runs, leaving the
# `<projname>_default` network on the daemon forever.
#
# `down -t 0` skips the default 10s SIGTERM grace: the user already
# exited the interactive shell, so there is nothing to drain gracefully —
# without -t 0 the script appears to hang for ~10s after `exit`.
#
# stdout/stderr are silenced in real mode so the trap stays invisible
# after a clean foreground exit (compose down's "[+] Removing ..." chatter
# is noise once the user has already left the shell). Under DRY_RUN the
# redirect is dropped so the planned `[dry-run] docker compose ... down
# --remove-orphans` line is actually visible — same convention as the
# rest of `_compose` callers.
# _app_cleanup
#
# run.sh's EXIT trap handler. Runs post-run hook first (container is
# still alive at this point so the hook can `docker exec` into it),
# then tears the project down via `compose down`. Hook failure
# overrides the wrapper exit code but still lets cleanup run --
# matches the strict-with-cleanup policy decided for
#
# Renamed from _compose_cleanup in to reflect that the cleanup
# scope now covers both the post-hook and compose lifecycle, not
# just compose. Future expansion (metric flush, log close, etc.)
# also lands here.
_app_cleanup() {
  local _post_rc=0
  _run_post_hook run "${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}" || _post_rc=$?
  if [[ "${DRY_RUN:-false}" == true ]]; then
    COMPOSE_PROFILES='*' _compose_project down --remove-orphans -t 0 || true
  else
    COMPOSE_PROFILES='*' _compose_project down --remove-orphans -t 0 \
      >/dev/null 2>&1 || true
  fi
  if (( _post_rc != 0 )); then
    exit "${_post_rc}"
  fi
}

# _normalize_interactive_rc <rc>
#
# A no-CMD foreground session -- a devel attached shell, or a one-shot
# stage's foreground `compose up` -- carries out the exit status of the
# LAST command the user ran, not run.sh's own success. An interactive bash
# exits with $? of its last command, so a Ctrl-C-cleared line ($?=130 =
# 128 + SIGINT) rides out on the following Ctrl-D / exit. Treat a clean
# leave (normal exit 0, or 130) as success so `just run` does not flag a
# scary recipe failure on a perfectly normal exit. Any other code (e.g.
# 127) still propagates so genuine breakage surfaces. With a CMD (command
# mode, `just run <cmd>`) this is bypassed and the real exit code is
# propagated for scripting.
_normalize_interactive_rc() {
  case "${1:?}" in
    0|130) printf '0' ;;
    *)     printf '%s' "${1}" ;;
  esac
}

main() {
  _transcript_begin  # capture orchestration; interactive paths detach
  # keep the wrapper's original argv around so the EXIT trap
  # (which fires asynchronously and can no longer see main's local $@)
  # can forward identical "$@" to the post-run hook.
  ORIG_ARGV=("$@")

  # shared --lang pre-pass. See lib/wrapper.sh.
  _wrapper_lang_prepass run "$@"

  # RUN_SETUP is set here but read by _wrapper_setup_sync (lib/wrapper.sh,).
  # To the consumer devel-test stage's per-file `shellcheck -S warning` (no -x)
  # it looks unused; mark it exported (local -x) so shellcheck treats it as
  # used-externally (silences SC2034 across versions / assignment sites), while
  # the in-process sourced runtime still reads it.
  local -x RUN_SETUP=false
  local DETACH=false
  local NO_RM=false
  local PRE_BUILD=false
  local TARGET="devel"
  local -a CMD_ARGS=()
  local -a SETUP_FORWARD_ARGS=()
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by the file-scope pre-pass that overrides
        # FILE_PATH; skip flag + value here. Pre-pass already validated
        # DIR exists, so blind shift 2 is safe.
        shift 2
        ;;
      -d|--detach)
        DETACH=true
        shift
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --gui)
        # per-invocation [gui] mode override forwarded to setup.sh.
        SETUP_FORWARD_ARGS+=(--gui "${2:?--gui requires a value (auto|force|off)}")
        RUN_SETUP=true
        shift 2
        ;;
      --gui=*)
        SETUP_FORWARD_ARGS+=(--gui "${1#--gui=}")
        RUN_SETUP=true
        shift
        ;;
      --no-x11-cookie)
        # skip the SSH X11 cookie rewrite for this invocation.
        SETUP_FORWARD_ARGS+=(--no-x11-cookie)
        RUN_SETUP=true
        shift
        ;;
      --build)
        # opt-in lint+smoke pre-build via ./build.sh test before
        # `compose up`. Default path lets compose auto-build (which
        # skips the test stage entirely). Use this flag to get full
        # local CI parity on a fresh clone.
        PRE_BUILD=true
        shift
        ;;
      --no-rm)
        # opt out of the auto compose-down on foreground exit.
        # Default ON; this flag restores the "container/network
        # stays alive after exit" behavior — useful for re-attaching
        # via ./exec.sh later or inspecting logs post-mortem. -d already
        # implies no auto-down (background lifecycle is user-managed).
        NO_RM=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # BUILDKIT_PROGRESS=plain — verbose docker output. Use when
        # compose's auto-build appears hung
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
        CMD_ARGS+=("$@")
        break
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
    _log_err run run_detach_cmd_rejected "display=-d/--detach does not accept a CMD (got: ${CMD_ARGS[*]}). Use './exec.sh -t ${TARGET} ${CMD_ARGS[*]}' to run a command inside a detached container."
    exit 2
  fi

  # shared setup/drift orchestration (build + run). Same lifecycle
  # as build.sh: bootstrap vs drift-regen vs interactive setup, setup.sh
  # run as a subprocess (avoids the _msg shadow), exit 1 on missing
  # .env. Reads RUN_SETUP / SETUP_FORWARD_ARGS / FILE_PATH / _LANG.
  _wrapper_setup_sync run

  # Load .env, derive PROJECT_NAME.
  _load_env "${FILE_PATH}/.env.generated"
  _compute_project_name

  # Pre-run snapshot so the user can see which files + values this
  # invocation resolved to before the container replaces the shell.
  # Mute with QUIET=1 for piped / CI logs; documented in `--help` (all
  # four locales), not only here.
  [[ "${QUIET:-0}" != "1" ]] && _print_config_summary run

  # ──pre-run hook (after env prep, before build delegate) ──
  # Fires once env validation + drift resolution + config summary are
  # done but BEFORE the image-check / build delegate, so a hook that
  # needs to set up host state required by build (e.g. binfmt
  # registration for cross-arch images on jetson_sdk_manager) can do
  # its work before docker build runs. Skipped under --dry-run.
  _run_pre_hook run "${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}" || exit $?

  # ──auto-build gate ──
  # When the target image is missing locally, delegate to build.sh
  # instead of letting compose auto-build (which silently skips the
  # test stage). This makes the first `just run` equivalent to
  # `just build && just run` without requiring two commands.
  #
  # Behavior:
  #   - --build → invoke ./build.sh test BEFORE compose up (full
  #     local-CI parity). Always runs, even if image is cached.
  #   - default + image absent → auto-delegate to ./build.sh TARGET
  #     so the image is built via the proper build pipeline.
  #   - default + image present → silent (no build needed).
  #
  # Image inspect is per-target so ./run.sh -t headless checks
  # ${IMAGE_NAME}:headless (per auto-emit naming), not :devel.
  if [[ "${PRE_BUILD}" == true && "${DRY_RUN}" != true ]]; then
    local _build_sh="${FILE_PATH}/build.sh"
    if [[ -x "${_build_sh}" ]]; then
      _log_info run run_build_invoking "display=$(_msg build invoking)"
      "${_build_sh}" test
    fi
  elif [[ "${DRY_RUN}" != true ]]; then
    local _full_tag="${DOCKER_HUB_USER:-local}/${IMAGE_NAME}:${TARGET}"
    if ! docker image inspect "${_full_tag}" --format '{{.Id}}' \
         >/dev/null 2>&1; then
      local _build_sh="${FILE_PATH}/build.sh"
      if [[ -x "${_build_sh}" ]]; then
        _log_info run run_build_image_missing "display=$(_msg build image_missing): ${_full_tag}" "tag=${_full_tag}"
        _log_info run run_build_delegating "display=$(_msg build delegating)"
        "${_build_sh}" "${TARGET}"
      fi
    fi
  fi

  # Allow X11 forwarding (X11 or XWayland)
  if [[ "${XDG_SESSION_TYPE:-x11}" == "wayland" ]]; then
    xhost "+SI:localuser:${USER_NAME}" >/dev/null 2>&1 || true
  else
    xhost +local: >/dev/null 2>&1 || true
  fi

  # Container name mirrors compose.yaml's `container_name:`. Includes
  # ${USER_NAME} prefix to disambiguate per-OS-user on shared hosts
  # _load_env above already populated USER_NAME from .env.
  local CONTAINER_NAME="${USER_NAME}-${IMAGE_NAME}"

  # Refuse to start if the target container is already running.
  # (For -d mode, the existing `down` step handles restart, so collision is OK.)
  if [[ "${DETACH}" != true && "${TARGET}" == "devel" \
      && "${DRY_RUN}" != true ]]; then
    if _wrapper_container_running "${CONTAINER_NAME}"; then
      # Compose the multi-line body once (i18n template carries %s for the
      # container name) and emit via _log_err so the whole block gets the
      # ERROR colour / stderr routing.
      local _already _stop
      # shellcheck disable=SC2059
      printf -v _already "$(_msg errors already_running)" "${CONTAINER_NAME}"
      _stop="$(_msg hints stop_hint)"
      _log_err run run_already_running "display=${_already}
${_stop}"
      exit 1
    fi
  fi

  # foreground exit auto-down. Default ON for every foreground
  # target (devel + one-shot stages); opt out via --no-rm. The trap
  # tears the project down on shell exit, Ctrl-C, or signal — covers
  # the worktree-removed-before-stop leak case where the cwd that
  # `./stop.sh` would resolve from no longer exists. -d skips the trap
  # because background lifecycle is the user's responsibility. The
  # trap fires under --dry-run too so the "[dry-run] docker compose
  # ... down --remove-orphans" line is visible in the planned-action
  # output (no real teardown happens — _compose honors DRY_RUN).
  if [[ "${DETACH}" != true && "${NO_RM}" != true ]]; then
    # register via the transcript-owned atexit registry instead of
    # `trap ... EXIT`, which would clobber the transcript finalize.
    _atexit _app_cleanup
  fi

  if [[ "${DETACH}" == true ]]; then
    _compose_project down 2>/dev/null || true
    _compose_project up -d "${TARGET}"
    # detached installs no foreground EXIT trap, so the post-run hook
    # would never fire. Run it directly here -- the container is up,
    # so the hook can `docker exec` / `docker cp` into it. Decoupled from
    # `compose down`: the -d lifecycle is user-managed (no teardown). Hook
    # failure surfaces as a non-zero exit, matching the foreground trap.
    _run_post_hook run "${ORIG_ARGV[@]+"${ORIG_ARGV[@]}"}" || exit $?
  elif [[ "${TARGET}" == "devel" ]]; then
    # Foreground devel: `up -d` + `exec` so a second terminal can join via
    # `./exec.sh`. CMD_ARGS passthrough: empty → `bash` (matches
    # Dockerfile CMD for devel); non-empty → override
    # (e.g. `./run.sh ls /tmp`). Exit cleanup handled by the
    # centrally-registered `_atexit _app_cleanup` above.
    _compose_project up -d "${TARGET}"
    # container is up (orchestration captured) -- detach the
    # transcript before handing the terminal to the interactive session.
    _transcript_detach
    if (( ${#CMD_ARGS[@]} > 0 )); then
      # Command mode: propagate the real exit code for scripting.
      _compose_project exec "${TARGET}" "${CMD_ARGS[@]}"
    else
      # Interactive attached shell: normalize a clean leave to 0.
      local _rc=0
      _compose_project exec "${TARGET}" bash || _rc=$?
      return "$(_normalize_interactive_rc "${_rc}")"
    fi
  else
    # Other one-shot stages (runtime, test, ...). Empty CMD_ARGS →
    # foreground `up`, so the container_name: directive
    # takes effect and the Dockerfile CMD runs.
    #
    # Non-empty CMD_ARGS → `compose run --rm`, NOT the `up -d` +
    # `exec` pair. For a one-shot app target whose ENTRYPOINT sets
    # up the environment (e.g. ROS sourcing) and whose default CMD *is* the
    # app, `up -d` + `exec` was wrong twice over:
    #   1. `compose exec` bypasses the ENTRYPOINT (same root cause as the
    #      interactive-exec gap) → the env the entrypoint
    #      provides (e.g. ROS on PATH) is absent → `exec: ros2: not found`.
    #   2. `up -d` already started the default CMD as PID 1, so the exec'd
    #      command ran *alongside* it (double-launch / device contention)
    #      instead of replacing it.
    # `compose run --rm` runs the ENTRYPOINT (env set up) and REPLACES the
    # default CMD (no double-launch) — the correct override semantics.
    #
    # Container-name note: `compose run` ignores `container_name:` and
    # appends a `-run-<hash>` suffix (the concern). That is acceptable
    # here: the override container is ephemeral (`--rm`), foreground, and
    # nobody re-attaches to it by name, so a stable name buys nothing. The
    # stable-name path (devel join via `up -d` + `exec`) is unchanged.
    if (( ${#CMD_ARGS[@]} > 0 )); then
      # Command mode: propagate the real exit code for scripting.
      _transcript_detach  # detach before the foreground override run
      _compose_project run --rm "${TARGET}" "${CMD_ARGS[@]}"
    else
      # Foreground service: a clean Ctrl-C stop ($?=130) is not a failure;
      # normalize it (and 0) to 0.
      _transcript_detach  # detach before the foreground attach
      local _rc=0
      _compose_project up "${TARGET}" || _rc=$?
      return "$(_normalize_interactive_rc "${_rc}")"
    fi
  fi
}

main "$@"
