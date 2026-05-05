#!/usr/bin/env bash
# build.sh - Build Docker container images

set -euo pipefail

FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly FILE_PATH
# _lib.sh lives at template/script/docker/_lib.sh in normal consumer
# repos, OR alongside build.sh when the Dockerfile `test` stage COPYs
# scripts + helpers into /lint/. Issue #104 deduplicated the previously
# inlined fallback `_detect_lang`; we now always have i18n.sh via
# _lib.sh's sibling load.
if [[ -f "${FILE_PATH}/template/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/template/script/docker/_lib.sh"
elif [[ -f "${FILE_PATH}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/_lib.sh"
else
  printf "[build] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/template/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

_msg() {
  local _key="${1:?}"
  case "${_LANG}:${_key}" in
    zh-TW:bootstrap_info)  echo "[build] 資訊：首次執行 — 初始化中..." ;;
    zh-CN:bootstrap_info)  echo "[build] 信息：首次运行 — 初始化中..." ;;
    ja:bootstrap_info)     echo "[build] 情報: 初回実行 — ブートストラップ中..." ;;
    *:bootstrap_info)      echo "[build] INFO: First run — bootstrapping..." ;;
    zh-TW:drift_regen)     echo "[build] 重新產生 .env / compose.yaml（setup.conf 已變更）" ;;
    zh-CN:drift_regen)     echo "[build] 重新生成 .env / compose.yaml（setup.conf 已变更）" ;;
    ja:drift_regen)        echo "[build] .env / compose.yaml を再生成中（setup.conf が変更されました）" ;;
    *:drift_regen)         echo "[build] regenerating .env / compose.yaml (setup.conf drifted)" ;;
    zh-TW:err_no_env)      echo "[build] 錯誤：setup 未產生 .env。" ;;
    zh-CN:err_no_env)      echo "[build] 错误：setup 未生成 .env。" ;;
    ja:err_no_env)         echo "[build] エラー: setup が .env を生成しませんでした。" ;;
    *:err_no_env)          echo "[build] ERROR: setup did not produce .env." ;;
    zh-TW:err_rerun_setup) echo "[build] 請改以 './build.sh --setup' 重新執行以開啟編輯器。" ;;
    zh-CN:err_rerun_setup) echo "[build] 请改以 './build.sh --setup' 重新运行以打开编辑器。" ;;
    ja:err_rerun_setup)    echo "[build] './build.sh --setup' で再実行してエディタを開いてください。" ;;
    *:err_rerun_setup)     echo "[build] Re-run with './build.sh --setup' to open the editor." ;;
  esac
}

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

選項:
  -h, --help     顯示此說明
  -s, --setup    強制重跑 setup.sh 重新生成 .env + compose.yaml
                 （預設：.env 不存在時自動 bootstrap；存在時僅印 drift warning）
  --reset-conf   用 template 預設值覆蓋 setup.conf（先備份到 setup.conf.bak
                 + .env.bak；需確認，可用 -y 跳過）。之後會自動重跑 setup。
  -y, --yes      略過 --reset-conf 的互動確認
  --no-cache     強制不使用 cache 重建
  --clean-tools  build 結束後移除 test-tools:local image（預設保留以加速下次 build）
  --dry-run      只印出將執行的 docker 指令，不實際執行
  --lang LANG    設定訊息語言（預設: en）

目標:
  devel    開發環境（預設）
  test     執行 smoke test
  runtime  最小化 runtime 映像
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./build.sh [-h] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

选项:
  -h, --help     显示此说明
  -s, --setup    强制重跑 setup.sh 重新生成 .env + compose.yaml
                 （默认：.env 不存在时自动 bootstrap；存在时仅打印 drift warning）
  --reset-conf   用 template 默认值覆盖 setup.conf（先备份到 setup.conf.bak
                 + .env.bak；需确认，可用 -y 跳过）。之后会自动重跑 setup。
  -y, --yes      跳过 --reset-conf 的交互确认
  --no-cache     强制不使用 cache 重建
  --clean-tools  build 结束后移除 test-tools:local image（默认保留以加速下次 build）
  --dry-run      只打印将执行的 docker 命令，不实际执行
  --lang LANG    设置消息语言（默认: en）

目标:
  devel    开发环境（默认）
  test     运行 smoke test
  runtime  最小化 runtime 镜像
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./build.sh [-h] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

オプション:
  -h, --help     このヘルプを表示
  -s, --setup    setup.sh を強制実行して .env + compose.yaml を再生成
                 （デフォルト：.env が無ければ自動 bootstrap、あれば drift warning のみ）
  --reset-conf   setup.conf をテンプレのデフォルトで上書き（setup.conf.bak
                 + .env.bak にバックアップ；確認プロンプト、-y でスキップ）。
                 その後 setup を再実行。
  -y, --yes      --reset-conf の確認プロンプトをスキップ
  --no-cache     キャッシュを使わず強制リビルド
  --clean-tools  build 終了後に test-tools:local image を削除（デフォルトは保持）
  --dry-run      実行される docker コマンドを表示するのみ（実行はしない）
  --lang LANG    メッセージ言語を設定（デフォルト: en）

ターゲット:
  devel    開発環境（デフォルト）
  test     smoke test を実行
  runtime  最小化ランタイムイメージ
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./build.sh [-h] [-s|--setup] [--reset-conf] [-y|--yes] [--no-cache] [--clean-tools] [--dry-run] [--lang <en|zh-TW|zh-CN|ja>] [TARGET]

Options:
  -h, --help     Show this help
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
  --lang LANG    Set message language (default: en)

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
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "build"
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
    local _conf="${FILE_PATH}/setup.conf"
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
      printf "[dry-run] %s/template/init.sh --gen-conf --force\n" "${FILE_PATH}"
    else
      bash "${FILE_PATH}/template/init.sh" --gen-conf --force
    fi
    # Force a fresh setup.sh run so .env + compose.yaml follow the new conf.
    RUN_SETUP=true
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
  # Bootstrap MUST stay non-interactive: compose.yaml is gitignored
  # since v0.9.0, so every fresh clone hits the bootstrap path. If we
  # dispatched through _run_interactive, a TTY user who cancelled the
  # TUI (Esc / Ctrl+C) would end up with no .env and the next step
  # would die inside _load_env with a cryptic "No such file" error.
  # Direct setup.sh guarantees .env + compose.yaml are generated.
  if [[ "${RUN_SETUP}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${FILE_PATH}/.env" ]] \
      || [[ ! -f "${FILE_PATH}/setup.conf" ]] \
      || [[ ! -f "${FILE_PATH}/compose.yaml" ]]; then
    printf "%s\n" "$(_msg bootstrap_info)"
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
      printf "%s\n" "$(_msg drift_regen)"
      "${_setup}" apply --base-path "${FILE_PATH}" --lang "${_LANG}"
    fi
  fi

  # Defensive: setup above should always produce .env. If it didn't
  # (user cancelled an interactive TUI, setup.sh crashed, ...), surface
  # a useful error instead of letting _load_env fail on a missing file.
  if [[ ! -f "${FILE_PATH}/.env" ]]; then
    printf "%s\n" "$(_msg err_no_env)" >&2
    printf "%s\n" "$(_msg err_rerun_setup)" >&2
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

  # Build test-tools image if Dockerfile exists
  local _tools_dockerfile="${FILE_PATH}/template/dockerfile/Dockerfile.test-tools"
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
  if [[ -f "${_tools_dockerfile}" ]]; then
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
