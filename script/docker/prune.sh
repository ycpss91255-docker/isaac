#!/usr/bin/env bash
# prune.sh - Clean up local Docker garbage (networks / images / volumes / builder)
#
# Sibling wrapper to build.sh / run.sh / exec.sh / stop.sh. Provides
# atomic prune flags backed by `docker {network,image,volume,builder}
# prune` with conservative default `--filter until=<duration>` so live
# / recently-stopped projects are NOT swept up by accident.
#
# Default filter values:
#   --networks → until=10m   (network address-pool reclaim, the common case)
#   --images   → until=24h   (dangling images from aborted builds)
#   --builder  → until=24h   (buildx cache, large disk reclaim)
#   --volumes  → no filter   (volume prune ignores --filter on most engines;
#                              we still pass it for forward-compat, and we
#                              prompt for confirmation since volumes hold
#                              user state)
#
# Refs issue #319.

set -euo pipefail

# `-C <dir>` / `--chdir <dir>` pre-pass — mirrors build.sh / run.sh /
# exec.sh / stop.sh. prune.sh itself is daemon-wide so cwd does not
# affect what gets pruned, but the flag is accepted for muscle-memory
# consistency across all 5 wrappers.
FILE_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_chdir_i=1
while (( _chdir_i <= $# )); do
  case "${!_chdir_i}" in
    -C|--chdir)
      _chdir_next=$((_chdir_i + 1))
      if (( _chdir_next > $# )) || [[ -z "${!_chdir_next:-}" ]]; then
        printf '[prune] ERROR: -C/--chdir requires a value\n' >&2
        exit 2
      fi
      _chdir_arg="${!_chdir_next}"
      if [[ ! -d "${_chdir_arg}" ]]; then
        printf '[prune] ERROR: -C target is not a directory: %s\n' "${_chdir_arg}" >&2
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
# sibling _lib.sh in /lint/ (Dockerfile test stage).
if [[ -f "${FILE_PATH}/.base/script/docker/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/.base/script/docker/_lib.sh"
elif [[ -f "${FILE_PATH}/_lib.sh" ]]; then
  # shellcheck disable=SC1091
  source "${FILE_PATH}/_lib.sh"
else
  printf "[prune] ERROR: cannot find _lib.sh — expected one of:\n" >&2
  printf "  %s\n" "${FILE_PATH}/.base/script/docker/_lib.sh" >&2
  printf "  %s\n" "${FILE_PATH}/_lib.sh" >&2
  exit 1
fi

# i18n message tables — split by category, same pattern as build/run/stop.
_msg_info() {
  case "${_LANG}:${1:?}" in
    zh-TW:nothing_selected) echo "未指定任何 prune 目標。使用 --networks / --images / --volumes / --builder 或 --all。" ;;
    zh-CN:nothing_selected) echo "未指定任何 prune 目标。使用 --networks / --images / --volumes / --builder 或 --all。" ;;
    ja:nothing_selected)    echo "prune 対象が指定されていません。--networks / --images / --volumes / --builder または --all を指定してください。" ;;
    *:nothing_selected)     echo "No prune target selected. Pass --networks / --images / --volumes / --builder or --all." ;;
    zh-TW:volume_prompt)    echo "即將執行 docker volume prune（會永久刪除未使用的 volume 與其資料）。確定？[y/N]" ;;
    zh-CN:volume_prompt)    echo "即将执行 docker volume prune（会永久删除未使用的 volume 与其数据）。确定？[y/N]" ;;
    ja:volume_prompt)       echo "docker volume prune を実行します（未使用 volume とそのデータを永久に削除）。続行しますか？[y/N]" ;;
    *:volume_prompt)        echo "About to run docker volume prune (permanently removes unused volumes AND their data). Proceed? [y/N]" ;;
    zh-TW:volume_aborted)   echo "已中止 volume prune。" ;;
    zh-CN:volume_aborted)   echo "已中止 volume prune。" ;;
    ja:volume_aborted)      echo "volume prune を中止しました。" ;;
    *:volume_aborted)       echo "Aborted volume prune." ;;
  esac
}

_msg() {
  local _category="${1:?_msg requires category}"
  local _key="${2:?_msg requires key}"
  "_msg_${_category}" "${_key}"
}

usage() {
  case "${_LANG}" in
    zh-TW)
      cat >&2 <<'EOF'
用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all] [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

清理本機 docker 垃圾（unused network / dangling image / buildx cache / volume）。
不會碰執行中的 container 或 active resource。

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），與其他 wrapper 對齊
  --networks        清未使用的 networks（預設 --filter until=10m）— 解決 docker 「address pool 滿了」
  --images          清 dangling images（預設 --filter until=24h）
  --volumes         清未使用的 volumes（**會刪資料**；預設需 -y 確認）
  --builder         清 buildx cache（預設 --filter until=24h）— 釋放大量磁碟
  --all             = --networks --images --builder（不含 --volumes，避免誤刪資料）
  --until DURATION  覆寫所有 prune 的 --filter until=<dur>（例：1h, 7d）
  -y, --yes         跳過 --volumes 的互動確認
  --dry-run         只印出將執行的 docker 指令，不實際執行
  --lang LANG       設定訊息語言（en|zh-TW|zh-CN|ja；預設: en）

範例:
  ./prune.sh --networks           # 解 address pool 滿
  ./prune.sh --all                # 一鍵清網路 + image + builder cache
  ./prune.sh --volumes -y         # 清 volume（跳過確認）
  ./prune.sh --all --until 1h     # 把門檻拉嚴到 1 小時
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all] [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

清理本机 docker 垃圾（unused network / dangling image / buildx cache / volume）。
不会碰运行中的 container 或 active resource。

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），与其他 wrapper 对齐
  --networks        清未使用的 networks（默认 --filter until=10m）— 解决 docker "address pool 满了"
  --images          清 dangling images（默认 --filter until=24h）
  --volumes         清未使用的 volumes（**会删数据**；默认需 -y 确认）
  --builder         清 buildx cache（默认 --filter until=24h）— 释放大量磁盘
  --all             = --networks --images --builder（不含 --volumes，避免误删数据）
  --until DURATION  覆写所有 prune 的 --filter until=<dur>（例：1h, 7d）
  -y, --yes         跳过 --volumes 的交互确认
  --dry-run         只打印将执行的 docker 命令，不实际执行
  --lang LANG       设置消息语言（en|zh-TW|zh-CN|ja；默认: en）

示例:
  ./prune.sh --networks           # 解 address pool 满
  ./prune.sh --all                # 一键清网络 + image + builder cache
  ./prune.sh --volumes -y         # 清 volume（跳过确认）
  ./prune.sh --all --until 1h     # 把门槛拉严到 1 小时
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all] [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

ローカルの docker ガベージ（未使用 network / dangling image / buildx cache / volume）を整理します。
実行中のコンテナや active なリソースには手を出しません。

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）
  --networks        未使用 network を整理（デフォルト --filter until=10m）— 「address pool 枯渇」解消
  --images          dangling image を整理（デフォルト --filter until=24h）
  --volumes         未使用 volume を整理（**データ削除**；デフォルト -y 確認必要）
  --builder         buildx cache を整理（デフォルト --filter until=24h）— ディスク大量解放
  --all             = --networks --images --builder（--volumes は含まない、データ誤削除回避）
  --until DURATION  全 prune の --filter until=<dur> を上書き（例: 1h, 7d）
  -y, --yes         --volumes の確認プロンプトをスキップ
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  --lang LANG       メッセージ言語を設定（en|zh-TW|zh-CN|ja；デフォルト: en）

例:
  ./prune.sh --networks           # address pool 枯渇を解消
  ./prune.sh --all                # network + image + builder cache 一括整理
  ./prune.sh --volumes -y         # volume 整理（確認スキップ）
  ./prune.sh --all --until 1h     # しきい値を 1 時間に厳しく
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all] [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

Clean up local docker garbage (unused networks / dangling images / buildx cache / volumes).
Does NOT touch running containers or active resources.

Options:
  -h, --help        Show this help
  -C, --chdir DIR   Operate on the repo at DIR without changing the caller's cwd
                    (mirrors git -C / make -C; flag accepted for parity with the
                    other 4 wrappers; prune itself is daemon-wide).
  --networks        Prune unused networks (default --filter until=10m). Use when
                    docker complains "all predefined address pools have been
                    fully subnetted" — orphan networks from sibling projects.
  --images          Prune dangling images (default --filter until=24h).
  --volumes         Prune unused volumes (**WILL delete volume data**; prompts
                    unless -y).
  --builder         Prune buildx cache (default --filter until=24h). Significant
                    disk reclaim.
  --all             = --networks --images --builder. Does NOT include --volumes
                    to avoid accidental data loss.
  --until DURATION  Override the per-target default --filter until=<dur>
                    (e.g. 1h, 7d). Applies to whichever targets are selected.
  -y, --yes         Skip the --volumes confirmation prompt.
  --dry-run         Print the docker commands that would run, but do not execute.
  --lang LANG       Set message language (en|zh-TW|zh-CN|ja; default: en).

Examples:
  ./prune.sh --networks            # Fix "address pool exhausted" errors
  ./prune.sh --all                 # One-shot networks + images + builder cache
  ./prune.sh --volumes -y          # Prune volumes, skip confirmation
  ./prune.sh --all --until 1h      # Tighten threshold to 1 hour
EOF
      ;;
  esac
  exit 0
}

# _run_prune <kind> <until>
#   kind:  network | image | volume | builder
#   until: filter value (e.g. "10m"); empty string disables --filter
_run_prune() {
  local kind="${1:?_run_prune requires kind}"
  local until_val="${2-}"
  local -a cmd=(docker "${kind}" prune -f)
  if [[ -n "${until_val}" && "${kind}" != "volume" ]]; then
    # docker volume prune does not honor --filter until= on most engines.
    # Skipping the flag avoids a "filter until is unsupported" warning.
    cmd+=(--filter "until=${until_val}")
  fi
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run]'
    printf ' %q' "${cmd[@]}"
    printf '\n'
  else
    "${cmd[@]}"
  fi
}

main() {
  # Pre-pass for --lang so usage() runs in requested locale even when
  # --help is first. See build.sh for full rationale (#222).
  local _i
  for (( _i=1; _i<=$#; _i++ )); do
    if [[ "${!_i}" == "--lang" ]]; then
      local _next=$((_i+1))
      _LANG="${!_next:-}"
      _sanitize_lang _LANG "prune"
      break
    fi
  done

  local DO_NETWORKS=false
  local DO_IMAGES=false
  local DO_VOLUMES=false
  local DO_BUILDER=false
  local UNTIL_OVERRIDE=""
  local ASSUME_YES=false
  DRY_RUN=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        ;;
      -C|--chdir)
        # Already consumed by file-scope pre-pass; skip flag + value.
        shift 2
        ;;
      --networks)
        DO_NETWORKS=true
        shift
        ;;
      --images)
        DO_IMAGES=true
        shift
        ;;
      --volumes)
        DO_VOLUMES=true
        shift
        ;;
      --builder)
        DO_BUILDER=true
        shift
        ;;
      --all)
        # Excludes --volumes intentionally (see usage / issue #319).
        DO_NETWORKS=true
        DO_IMAGES=true
        DO_BUILDER=true
        shift
        ;;
      --until)
        UNTIL_OVERRIDE="${2:?"--until requires a value (e.g. 1h, 7d)"}"
        shift 2
        ;;
      -y|--yes)
        ASSUME_YES=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "prune"
        shift 2
        ;;
      *)
        _log_err prune "unknown flag: $1"
        exit 2
        ;;
    esac
  done
  export DRY_RUN

  # No target selected → print help-y error and exit 2 (not 0; caller likely
  # invoked us by mistake — avoid silent no-op).
  if [[ "${DO_NETWORKS}" != true && "${DO_IMAGES}" != true \
        && "${DO_VOLUMES}" != true && "${DO_BUILDER}" != true ]]; then
    _log_err prune "$(_msg info nothing_selected)"
    exit 2
  fi

  # Resolve per-target until value: --until overrides the per-kind default.
  local _net_until="${UNTIL_OVERRIDE:-10m}"
  local _img_until="${UNTIL_OVERRIDE:-24h}"
  local _bldr_until="${UNTIL_OVERRIDE:-24h}"
  local _vol_until="${UNTIL_OVERRIDE}"  # default: no filter for volumes

  if [[ "${DO_NETWORKS}" == true ]]; then
    _log_info prune "Pruning networks (until=${_net_until})..."
    _run_prune network "${_net_until}"
  fi

  if [[ "${DO_IMAGES}" == true ]]; then
    _log_info prune "Pruning dangling images (until=${_img_until})..."
    _run_prune image "${_img_until}"
  fi

  if [[ "${DO_BUILDER}" == true ]]; then
    _log_info prune "Pruning buildx cache (until=${_bldr_until})..."
    _run_prune builder "${_bldr_until}"
  fi

  if [[ "${DO_VOLUMES}" == true ]]; then
    # Volume prune deletes data permanently. Prompt unless -y or --dry-run.
    if [[ "${ASSUME_YES}" != true && "${DRY_RUN}" != true ]]; then
      printf '[prune] %s ' "$(_msg info volume_prompt)" >&2
      local _reply
      read -r _reply
      case "${_reply}" in
        y|Y|yes|YES) ;;
        *)
          _log_info prune "$(_msg info volume_aborted)"
          exit 1
          ;;
      esac
    fi
    _log_info prune "Pruning volumes (until=${_vol_until:-<none>})..."
    _run_prune volume "${_vol_until}"
  fi
}

main "$@"
