#!/usr/bin/env bash
# build.sh - Build Docker container images

set -euo pipefail

# Default FILE_PATH = the directory the wrapper symlink lives in (i.e.
# the repo root in normal usage). `-C <dir>` / `--chdir <dir>` overrides
# it so the wrapper operates on a different repo without changing the
# caller's cwd. Critical for Claude Code's sandbox `excludedCommands`
# matching: top-level command stays `./build.sh ...` rather than
# `(cd <dir> && ...)` or `bash -c "cd <dir> && ..."`, neither of which
# the bash AST parser unwraps into the `./build.sh *` prefix
# (refs docker_harness#53). The pre-pass runs before _lib.sh is sourced
# so all path-dependent operations (including the _lib.sh lookup) honor
# the override.
FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_chdir_i=1
while (( _chdir_i <= $# )); do
  case "${!_chdir_i}" in
    -C|--chdir)
      _chdir_next=$((_chdir_i + 1))
      if (( _chdir_next > $# )) || [[ -z "${!_chdir_next:-}" ]]; then
        printf '[build] ERROR: -C/--chdir requires a value\n' >&2
        exit 2
      fi
      _chdir_arg="${!_chdir_next}"
      if [[ ! -d "${_chdir_arg}" ]]; then
        printf '[build] ERROR: -C target is not a directory: %s\n' "${_chdir_arg}" >&2
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
# _lib.sh lives at .base/script/docker/_lib.sh in normal consumer
# repos, OR alongside build.sh when the Dockerfile `test` stage COPYs
# scripts + helpers into /lint/. Issue #104 deduplicated the previously
# inlined fallback `_detect_lang`; we now always have i18n.sh via
# _lib.sh's sibling load.
if [[ -f "${FILE_PATH}/.base/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/.base/script/docker/_lib.sh"
elif [[ -f "${FILE_PATH}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/_lib.sh"
else
  printf "[build] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/.base/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

# i18n message tables — split by semantic category (#278 PR-2).
# Each _msg_<category> returns plain i18n body only; tag + LEVEL keyword
# are added by the _log_* caller (English-only; level keyword no longer
# translated — see #283).
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
    zh-TW:regen)  echo "重新產生 .env / compose.yaml（setup.conf 已變更）" ;;
    zh-CN:regen)  echo "重新生成 .env / compose.yaml（setup.conf 已变更）" ;;
    ja:regen)     echo ".env / compose.yaml を再生成中（setup.conf が変更されました）" ;;
    *:regen)      echo "regenerating .env / compose.yaml (setup.conf drifted)" ;;
  esac
}

_msg_errors() {
  case "${_LANG}:${1:?}" in
    zh-TW:no_env)       echo "setup 未產生 .env。" ;;
    zh-CN:no_env)       echo "setup 未生成 .env。" ;;
    ja:no_env)          echo "setup が .env を生成しませんでした。" ;;
    *:no_env)           echo "setup did not produce .env." ;;
    zh-TW:rerun_setup)  echo "請改以 './build.sh --setup' 重新執行以開啟編輯器。" ;;
    zh-CN:rerun_setup)  echo "请改以 './build.sh --setup' 重新运行以打开编辑器。" ;;
    ja:rerun_setup)     echo "'./build.sh --setup' で再実行してエディタを開いてください。" ;;
    *:rerun_setup)      echo "Re-run with './build.sh --setup' to open the editor." ;;
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
用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

選項:
  -h, --help     顯示此說明
  -C, --chdir DIR
                 對 DIR 下的 repo 執行（不改變呼叫者 cwd），類似 git -C / make -C。
                 須在其他選項與 TARGET 之前指定。
  -s, --setup    強制重跑 setup.sh 重新生成 .env + compose.yaml
                 （預設：.env 不存在時自動 bootstrap；存在時僅印 drift warning）
  --reset-conf   用 template 預設值覆蓋 setup.conf（先備份到 setup.conf.bak
                 + .env.bak；需確認，可用 -y 跳過）。之後會自動重跑 setup。
  -y, --yes      略過 --reset-conf 的互動確認
  --no-cache     強制不使用 cache 重建
  --clean-tools  build 結束後移除 test-tools:local image（預設保留以加速下次 build）
  --dry-run      只印出將執行的 docker 指令，不實際執行
  -v, --verbose  詳細 docker 輸出（BUILDKIT_PROGRESS=plain）。build 卡住時用 —
                 即時顯示每個 RUN 步驟的 stdout/stderr，不再收斂成單行進度條。
  -vv, --very-verbose
                 -v 再加 wrapper 本身的 bash trace（set -x），用於除錯 wrapper
                 邏輯（少用；通常 -v 就夠了）。
  --lang LANG    設定訊息語言（預設: en）
  -t, --target TARGET
                 指定建置目標（等同於位置參數 [TARGET]，與 run.sh -t 對齊）。
                 兩種寫法同時存在時最後一個生效。

目標:
  devel    開發環境（預設）
  test     執行 smoke test
  runtime  最小化 runtime 映像
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

选项:
  -h, --help     显示此说明
  -C, --chdir DIR
                 对 DIR 下的 repo 执行（不改变调用者 cwd），类似 git -C / make -C。
                 须在其他选项与 TARGET 之前指定。
  -s, --setup    强制重跑 setup.sh 重新生成 .env + compose.yaml
                 （默认：.env 不存在时自动 bootstrap；存在时仅打印 drift warning）
  --reset-conf   用 template 默认值覆盖 setup.conf（先备份到 setup.conf.bak
                 + .env.bak；需确认，可用 -y 跳过）。之后会自动重跑 setup。
  -y, --yes      跳过 --reset-conf 的交互确认
  --no-cache     强制不使用 cache 重建
  --clean-tools  build 结束后移除 test-tools:local image（默认保留以加速下次 build）
  --dry-run      只打印将执行的 docker 命令，不实际执行
  -v, --verbose  详细 docker 输出（BUILDKIT_PROGRESS=plain）。build 卡住时用 —
                 实时显示每个 RUN 步骤的 stdout/stderr，不再收敛成单行进度条。
  -vv, --very-verbose
                 -v 再加 wrapper 本身的 bash trace（set -x），用于调试 wrapper
                 逻辑（少用；通常 -v 就够了）。
  --lang LANG    设置消息语言（默认: en）
  -t, --target TARGET
                 指定构建目标（等同于位置参数 [TARGET]，与 run.sh -t 对齐）。
                 两种写法同时存在时最后一个生效。

目标:
  devel    开发环境（默认）
  test     运行 smoke test
  runtime  最小化 runtime 镜像
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

オプション:
  -h, --help     このヘルプを表示
  -C, --chdir DIR
                 DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）。
                 git -C / make -C と同様。他のオプションや TARGET より前に指定。
  -s, --setup    setup.sh を強制実行して .env + compose.yaml を再生成
                 （デフォルト：.env が無ければ自動 bootstrap、あれば drift warning のみ）
  --reset-conf   setup.conf をテンプレのデフォルトで上書き（setup.conf.bak
                 + .env.bak にバックアップ；確認プロンプト、-y でスキップ）。
                 その後 setup を再実行。
  -y, --yes      --reset-conf の確認プロンプトをスキップ
  --no-cache     キャッシュを使わず強制リビルド
  --clean-tools  build 終了後に test-tools:local image を削除（デフォルトは保持）
  --dry-run      実行される docker コマンドを表示するのみ（実行はしない）
  -v, --verbose  docker の詳細出力（BUILDKIT_PROGRESS=plain）。build がハング
                 した時に使用 — 各 RUN ステップの stdout/stderr をリアルタイム
                 表示し、単一行プログレスバーに畳まれません。
  -vv, --very-verbose
                 -v に加え wrapper 自体の bash trace（set -x）。wrapper ロジック
                 のデバッグ用（稀；通常は -v で十分）。
  --lang LANG    メッセージ言語を設定（デフォルト: en）
  -t, --target TARGET
                 ビルドターゲットを指定（位置引数 [TARGET] と同義、run.sh -t と整合）。
                 両方の形式が指定された場合は最後に指定したものが有効。

ターゲット:
  devel    開発環境（デフォルト）
  test     smoke test を実行
  runtime  最小化ランタイムイメージ
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./build.sh [-h] [-C|--chdir DIR] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [-v|--verbose] [-vv|--very-verbose] [--lang <en|zh-TW|zh-CN|ja>] [-t|--target TARGET] [TARGET]

Options:
  -h, --help     Show this help
  -C, --chdir DIR
                 Operate on the repo at DIR without changing the caller's cwd.
                 Mirrors git -C / make -C. Must come before other options and
                 the TARGET.
  -s, --setup    Force rerun setup.sh to regenerate .env + compose.yaml
                 (default: auto-bootstrap if .env missing; warn on drift if present)
  --reset-conf   Overwrite setup.conf with template defaults (backs up the
                 existing setup.conf → setup.conf.bak and .env → .env.bak
                 first). Prompts for confirmation; pass -y to skip. Triggers
                 a setup.sh rerun afterward so .env + compose.yaml follow
                 the fresh conf.
  -y, --yes      Skip the --reset-conf confirmation prompt
  --no-cache     Force rebuild without cache
  --clean-tools  Remove test-tools:local image after build (default: keep for faster next build)
  --dry-run      Print the docker commands that would run, but do not execute
  -v, --verbose  Verbose docker output (BUILDKIT_PROGRESS=plain). Use when a
                 build appears hung — surfaces every RUN step's real-time
                 stdout/stderr instead of the collapsed single-line progress
                 UI.
  -vv, --very-verbose
                 -v plus bash trace (set -x) on the wrapper itself. For
                 debugging the wrapper's own logic (rare; -v is usually
                 enough).
  --lang LANG    Set message language (default: en)
  -t, --target TARGET
                 Build target (alias for the positional [TARGET], mirrors
                 run.sh -t). When both forms are given, last wins.

Targets:
  devel    Development environment (default)
  test     Run smoke tests
  runtime  Minimal runtime image
EOF
      ;;
  esac
  exit 0
}

main() {
  # Pre-pass: scan for --lang so usage() (which exits via -h/--help)
  # runs in the requested locale even when --help is the first arg.
  # Issue #222 — without this, `build.sh --help --lang zh-TW` falls
  # through usage() before the main loop reaches --lang and prints
  # the default-locale usage. The main parse loop below stays
  # unchanged so --lang's other side-effects (validation, error on
  # missing value) still run on the canonical path.
  local _i
  for (( _i=1; _i<=$#; _i++ )); do
    if [[ "${!_i}" == "--lang" ]]; then
      local _next=$((_i+1))
      _LANG="${!_next:-}"
      _sanitize_lang _LANG "build"
      break
    fi
  done

  local RUN_SETUP=false
  local RESET_CONF=false
  local ASSUME_YES=false
  local NO_CACHE=false
  local CLEAN_TOOLS=false
  local TARGET="devel"
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by the file-scope pre-pass that overrides
        # FILE_PATH; skip flag + value here. The pre-pass already
        # validated DIR exists and "-C" has a value, so we can shift
        # blindly.
        shift 2
        ;;
      -s|--setup)
        RUN_SETUP=true
        shift
        ;;
      --reset-conf)
        RESET_CONF=true
        shift
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      --no-cache)
        NO_CACHE=true
        shift
        ;;
      --clean-tools)
        CLEAN_TOOLS=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        # Surface every RUN step's real-time stdout/stderr in docker
        # build, instead of the collapsed BuildKit progress UI.
        # https://docs.docker.com/build/building/variables/#progress
        # Use when a build appears hung to distinguish "still doing
        # work" from "waiting on network / something else". Closes #311.
        export BUILDKIT_PROGRESS=plain
        shift
        ;;
      -vv|--very-verbose)
        # -v plus bash trace on the wrapper itself. For debugging the
        # wrapper's own option parsing / branching (rare; -v is enough
        # for diagnosing a hung docker build).
        export BUILDKIT_PROGRESS=plain
        set -x
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "build"
        shift 2
        ;;
      -t|--target)
        # Alias for the positional [TARGET], matching run.sh's -t.
        # When both forms are passed, last wins — same semantics as
        # repeating either form alone. Closes #280.
        TARGET="${2:?"-t/--target requires a value (e.g. devel, test, runtime)"}"
        shift 2
        ;;
      *)
        TARGET="$1"
        shift
        ;;
    esac
  done
  export DRY_RUN

  # --reset-conf: delegate to init.sh --gen-conf --force. Confirms unless
  # -y/--yes is passed. Backs up the existing setup.conf + .env to
  # *.bak siblings (git-ignored) before overwriting, so the reset is
  # recoverable. Runs before the normal bootstrap/drift flow below so
  # subsequent setup.sh invocation regenerates .env + compose.yaml from
  # the fresh conf.
  if [[ "${RESET_CONF}" == true ]]; then
    local _conf="${FILE_PATH}/config/docker/setup.conf"
    local _env="${FILE_PATH}/.env"
    if [[ -f "${_conf}" || -f "${_env}" ]]; then
      if [[ "${ASSUME_YES}" != true && "${DRY_RUN}" != true ]]; then
        printf "[build] --reset-conf will overwrite:\n" >&2
        [[ -f "${_conf}" ]] && printf "  %s (backup → %s.bak)\n" "${_conf}" "${_conf}" >&2
        [[ -f "${_env}"  ]] && printf "  %s (backup → %s.bak)\n" "${_env}" "${_env}" >&2
        printf "[build] proceed? [y/N] " >&2
        local _reply
        read -r _reply
        case "${_reply}" in
          y|Y|yes|YES) ;;
          *) printf "[build] aborted.\n" >&2; exit 1 ;;
        esac
      fi
    fi
    if [[ "${DRY_RUN}" == true ]]; then
      printf "[dry-run] %s/.base/init.sh --gen-conf --force\n" "${FILE_PATH}"
    else
      bash "${FILE_PATH}/.base/init.sh" --gen-conf --force
    fi
    # Force a fresh setup.sh run so .env + compose.yaml follow the new conf.
    RUN_SETUP=true
  fi

  local _setup="${FILE_PATH}/.base/script/docker/setup.sh"
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
  # Bootstrap MUST stay non-interactive: compose.yaml is gitignored
  # since v0.9.0, so every fresh clone hits the bootstrap path. If we
  # dispatched through _run_interactive, a TTY user who cancelled the
  # TUI (Esc / Ctrl+C) would end up with no .env and the next step
  # would die inside _load_env with a cryptic "No such file" error.
  # Direct setup.sh guarantees .env + compose.yaml are generated.
  if [[ "${RUN_SETUP}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${FILE_PATH}/.env" ]] \
      || [[ ! -f "${FILE_PATH}/config/docker/setup.conf" ]] \
      || [[ ! -f "${FILE_PATH}/compose.yaml" ]]; then
    _log_info build "$(_msg bootstrap info)"
    "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
  else
    # Drift-check path. When setup.conf / GPU / GUI / USER_UID changed
    # since .env was last generated (e.g. after `git pull` or a manual
    # edit) we regenerate .env + compose.yaml automatically — they are
    # derived artifacts with no user-owned data to preserve, so
    # re-running setup.sh is always safe and saves the user from having
    # to remember `./build.sh --setup`.
    #
    # Subprocess invocation (instead of `source`) keeps setup.sh's
    # internal helpers from leaking into build.sh's namespace. Closes
    # the class of bug behind #101 — sourcing setup.sh used to shadow
    # build.sh's _msg() and silently blank out drift_regen / err_no_env
    # status lines.
    if ! "${_setup}" check-drift --base-path "${FILE_PATH}" --lang "${_LANG}"; then
      _log_info build "$(_msg drift regen)"
      "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  fi

  # Defensive: setup above should always produce .env. If it didn't
  # (user cancelled an interactive TUI, setup.sh crashed, ...), surface
  # a useful error instead of letting _load_env fail on a missing file.
  if [[ ! -f "${FILE_PATH}/.env" ]]; then
    _log_err  build "$(_msg errors no_env)"
    _log_info build "$(_msg errors rerun_setup)"
    exit 1
  fi

  # Load .env for project name
  _load_env "${FILE_PATH}/.env"
  _compute_project_name ""

  # Pre-build snapshot so first-time users see which files drove this
  # run and the effective image/network/GPU/GUI/TZ before docker takes
  # over the terminal. --dry-run keeps it (still useful); can be muted
  # with QUIET=1 if someone pipes this into their own CI log.
  [[ "${QUIET:-0}" != "1" ]] && _print_config_summary build

  # Build test-tools image if Dockerfile exists AND caller hasn't
  # signalled it has its own test-tools provisioning via TEST_TOOLS_IMAGE.
  #
  # The downstream Dockerfile.example consumes TEST_TOOLS_IMAGE as a
  # build-arg (default `test-tools:local`) and `FROM ${TEST_TOOLS_IMAGE}`
  # for its lint/test stage. If the caller pre-builds or pulls the image
  # outside build.sh (CI workflows do this for cache-share / rolling-tag
  # reasons, see #317 P2), the internal `docker build` here is wasted
  # work — skip it. The caller is responsible for ensuring the value of
  # TEST_TOOLS_IMAGE resolves to a runnable image (either a locally tagged
  # `test-tools:local` or a registry-addressable tag the docker daemon
  # can pull on demand).
  local _tools_dockerfile="${FILE_PATH}/.base/dockerfile/Dockerfile.test-tools"
  local _tools_args=()
  [[ "${NO_CACHE}" == true ]] && _tools_args+=(--no-cache)
  # Forward user's TARGETARCH override when set. Empty = leave unset so
  # BuildKit auto-fills from host/--platform (no --build-arg passed).
  if [[ -n "${TARGET_ARCH:-}" ]]; then
    _tools_args+=(--build-arg "TARGETARCH=${TARGET_ARCH}")
  fi
  # Forward [build] network when set. Empty = docker default (bridge).
  # Needed on hosts whose bridge NAT is unusable (Jetson L4T without
  # iptable_raw, daemon.json with iptables: false, firewall-locked CI).
  if [[ -n "${BUILD_NETWORK:-}" ]]; then
    _tools_args+=(--network "${BUILD_NETWORK}")
  fi
  if [[ -z "${TEST_TOOLS_IMAGE:-}" ]] && [[ -f "${_tools_dockerfile}" ]]; then
    if [[ "${DRY_RUN}" == true ]]; then
      printf '[dry-run] docker build'
      printf ' %q' "${_tools_args[@]}" -t test-tools:local \
        -f "${_tools_dockerfile}" "${FILE_PATH}" -q
      printf '\n'
    else
      docker build "${_tools_args[@]}" \
        -t test-tools:local \
        -f "${_tools_dockerfile}" \
        "${FILE_PATH}" -q >/dev/null
    fi
  fi

  if [[ "${CLEAN_TOOLS}" == true ]]; then
    _cleanup() { docker rmi test-tools:local 2>/dev/null || true; }
    trap _cleanup EXIT
  fi

  local _compose_args=()
  [[ "${NO_CACHE}" == true ]] && _compose_args+=(--no-cache)

  _compose_project build "${_compose_args[@]}" "${TARGET}"
}

main "$@"
