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

# Shared wrapper preamble (#408 sub-task A): resolve FILE_PATH across the
# symlink / script-subfolder / direct / /lint layouts, honor -C/--chdir
# (accepted for muscle-memory consistency though prune is daemon-wide),
# and source _lib.sh -- all in lib/bootstrap.sh. See build.sh for the
# locator rationale. (Also unifies prune's stale flat `_lib.sh` fallback
# onto the post-#406 `lib/_lib.sh` path.)
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
  printf '[prune] ERROR: cannot find lib/bootstrap.sh (which sources _lib.sh) -- broken install?\n' >&2
  exit 1
fi
_bootstrap "$@"

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
用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all]
                  [--worktree-orphans [--workspace DIR] [--owner NAME] [--repo NAME]]
                  [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

清理本機 docker 垃圾（unused network / dangling image / buildx cache / volume）。
不會碰執行中的 container 或 active resource。

選項:
  -h, --help        顯示此說明
  -C, --chdir DIR   對 DIR 下的 repo 執行（不改變呼叫者 cwd），與其他 wrapper 對齊
  --networks        清未使用的 networks（預設 --filter until=10m）— 解決 docker 「address pool 滿了」
  --images          清 dangling images（預設 --filter until=24h）
  --volumes         清未使用的 volumes（**會刪資料**；預設需 -y 確認）
  --builder         清 buildx cache（預設 --filter until=24h）— 釋放大量磁碟
  --all             = --networks --images --builder（不含 --volumes，亦不含 --worktree-orphans）
  --worktree-orphans
                    清理由已移除 worktree 所遺留的 tagged image (#388)。對每個
                    `<owner>/<name>-<suffix>:<tag>` image 檢查
                    `<workspace>/worktree/<name>-<suffix>/` 是否存在 — 不存在則
                    視為 orphan。**安全閘**：只清 `<owner>` 等於當前 DOCKER_HUB_USER
                    的 image；無 prefix 的裸名與其他 user 的 image 永遠 SKIP。
  --workspace DIR   覆寫 workspace 目錄（預設讀 .env 的 WS_PATH）
  --owner NAME      覆寫 owner 比對值（預設讀 .env 的 DOCKER_HUB_USER；
                    .env 缺則 fallback 偵測 docker info / \$USER / id -un）
  --repo NAME       縮 scope，只考慮 `<owner>/<name>-*` image。可重複指定多次。
  --until DURATION  覆寫所有 prune 的 --filter until=<dur>（例：1h, 7d）
  -y, --yes         跳過 --volumes 及 --worktree-orphans 的互動確認
  --dry-run         只印出將執行的 docker 指令，不實際執行
  --lang LANG       設定訊息語言（en|zh-TW|zh-CN|ja；預設: en）

範例:
  ./prune.sh --networks           # 解 address pool 滿
  ./prune.sh --all                # 一鍵清網路 + image + builder cache
  ./prune.sh --volumes -y         # 清 volume（跳過確認）
  ./prune.sh --all --until 1h     # 把門檻拉嚴到 1 小時
  ./prune.sh --worktree-orphans --dry-run   # 看 worktree-orphan 候選
  ./prune.sh --worktree-orphans -y          # 實清，跳過確認
EOF
      ;;
    zh-CN)
      cat >&2 <<'EOF'
用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all]
                  [--worktree-orphans [--workspace DIR] [--owner NAME] [--repo NAME]]
                  [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

清理本机 docker 垃圾（unused network / dangling image / buildx cache / volume）。
不会碰运行中的 container 或 active resource。

选项:
  -h, --help        显示此说明
  -C, --chdir DIR   对 DIR 下的 repo 执行（不改变调用者 cwd），与其他 wrapper 对齐
  --networks        清未使用的 networks（默认 --filter until=10m）— 解决 docker "address pool 满了"
  --images          清 dangling images（默认 --filter until=24h）
  --volumes         清未使用的 volumes（**会删数据**；默认需 -y 确认）
  --builder         清 buildx cache（默认 --filter until=24h）— 释放大量磁盘
  --all             = --networks --images --builder（不含 --volumes，也不含 --worktree-orphans）
  --worktree-orphans
                    清理由已移除 worktree 遗留的 tagged image (#388)。对每个
                    `<owner>/<name>-<suffix>:<tag>` image 检查
                    `<workspace>/worktree/<name>-<suffix>/` 是否存在 — 不存在则
                    视为 orphan。**安全闸**：只清 `<owner>` 等于当前 DOCKER_HUB_USER
                    的 image；无 prefix 的裸名与其他 user 的 image 永远 SKIP。
  --workspace DIR   覆写 workspace 目录（默认读 .env 的 WS_PATH）
  --owner NAME      覆写 owner 比对值（默认读 .env 的 DOCKER_HUB_USER；
                    .env 缺则 fallback 检测 docker info / \$USER / id -un）
  --repo NAME       缩 scope，只考虑 `<owner>/<name>-*` image。可重复指定多次。
  --until DURATION  覆写所有 prune 的 --filter until=<dur>（例：1h, 7d）
  -y, --yes         跳过 --volumes 及 --worktree-orphans 的交互确认
  --dry-run         只打印将执行的 docker 命令，不实际执行
  --lang LANG       设置消息语言（en|zh-TW|zh-CN|ja；默认: en）

示例:
  ./prune.sh --networks           # 解 address pool 满
  ./prune.sh --all                # 一键清网络 + image + builder cache
  ./prune.sh --volumes -y         # 清 volume（跳过确认）
  ./prune.sh --all --until 1h     # 把门槛拉严到 1 小时
  ./prune.sh --worktree-orphans --dry-run   # 看 worktree-orphan 候选
  ./prune.sh --worktree-orphans -y          # 实清，跳过确认
EOF
      ;;
    ja)
      cat >&2 <<'EOF'
使用法: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all]
                   [--worktree-orphans [--workspace DIR] [--owner NAME] [--repo NAME]]
                   [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

ローカルの docker ガベージ（未使用 network / dangling image / buildx cache / volume）を整理します。
実行中のコンテナや active なリソースには手を出しません。

オプション:
  -h, --help        このヘルプを表示
  -C, --chdir DIR   DIR 配下の repo に対して実行（呼び出し側の cwd は変えない）
  --networks        未使用 network を整理（デフォルト --filter until=10m）— 「address pool 枯渇」解消
  --images          dangling image を整理（デフォルト --filter until=24h）
  --volumes         未使用 volume を整理（**データ削除**；デフォルト -y 確認必要）
  --builder         buildx cache を整理（デフォルト --filter until=24h）— ディスク大量解放
  --all             = --networks --images --builder（--volumes / --worktree-orphans は含まない）
  --worktree-orphans
                    削除済み worktree が残した tagged image を整理 (#388)。各
                    `<owner>/<name>-<suffix>:<tag>` image について
                    `<workspace>/worktree/<name>-<suffix>/` の存在を確認 —
                    存在しなければ orphan とみなす。**安全ガード**: `<owner>`
                    が現在の DOCKER_HUB_USER と一致する image のみを対象とし、
                    prefix のない裸名・他ユーザの image は常にスキップ。
  --workspace DIR   workspace ディレクトリを上書き（デフォルトは .env の WS_PATH）
  --owner NAME      owner 比較値を上書き（デフォルトは .env の DOCKER_HUB_USER；
                    .env 不在時は docker info / \$USER / id -un フォールバック）
  --repo NAME       scope を絞り、`<owner>/<name>-*` のみ候補化。複数指定可。
  --until DURATION  全 prune の --filter until=<dur> を上書き（例: 1h, 7d）
  -y, --yes         --volumes 及び --worktree-orphans の確認プロンプトをスキップ
  --dry-run         実行される docker コマンドを表示するのみ（実行はしない）
  --lang LANG       メッセージ言語を設定（en|zh-TW|zh-CN|ja；デフォルト: en）

例:
  ./prune.sh --networks           # address pool 枯渇を解消
  ./prune.sh --all                # network + image + builder cache 一括整理
  ./prune.sh --volumes -y         # volume 整理（確認スキップ）
  ./prune.sh --all --until 1h     # しきい値を 1 時間に厳しく
  ./prune.sh --worktree-orphans --dry-run   # worktree-orphan 候補を確認
  ./prune.sh --worktree-orphans -y          # 実削除（確認スキップ）
EOF
      ;;
    *)
      cat >&2 <<'EOF'
Usage: ./prune.sh [-h] [-C|--chdir DIR] [--networks] [--images] [--volumes] [--builder] [--all]
                  [--worktree-orphans [--workspace DIR] [--owner NAME] [--repo NAME]]
                  [--until DURATION] [-y|--yes] [--dry-run] [--lang LANG]

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
                    or --worktree-orphans (those require explicit opt-in).
  --worktree-orphans
                    Remove tagged images left behind by removed worktrees (#388).
                    For each image `<owner>/<name>-<suffix>:<tag>`, check if
                    `<workspace>/worktree/<name>-<suffix>/` still exists — if
                    not, the worktree is gone and the image is an orphan.
                    **Safety gates**: only acts on images whose `<owner>/`
                    prefix matches the current DOCKER_HUB_USER; bare-name
                    images (no prefix) and other-user images are ALWAYS
                    skipped. Refuses without explicit opt-in.
  --workspace DIR   Override workspace dir (default: WS_PATH from .env).
  --owner NAME      Override the owner match value (default: DOCKER_HUB_USER
                    from .env; falls back to docker info Username / \$USER /
                    id -un when .env is absent).
  --repo NAME       Narrow scope: only consider `<owner>/<name>-*` images.
                    Repeatable.
  --until DURATION  Override the per-target default --filter until=<dur>
                    (e.g. 1h, 7d). Applies to whichever targets are selected.
  -y, --yes         Skip the --volumes and --worktree-orphans prompts.
  --dry-run         Print the docker commands that would run, but do not execute.
  --lang LANG       Set message language (en|zh-TW|zh-CN|ja; default: en).

Examples:
  ./prune.sh --networks            # Fix "address pool exhausted" errors
  ./prune.sh --all                 # One-shot networks + images + builder cache
  ./prune.sh --volumes -y          # Prune volumes, skip confirmation
  ./prune.sh --all --until 1h      # Tighten threshold to 1 hour
  ./prune.sh --worktree-orphans --dry-run   # Preview worktree-orphan candidates
  ./prune.sh --worktree-orphans -y          # Actually clean, skip prompt
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
  _dry_run_cmd "${cmd[@]}"
}

# ── #388 worktree-orphans prune ───────────────────────────────────────────

# _ensure_env_loaded sources .env once per invocation if it exists. Used by
# both _resolve_workspace and _resolve_owner so they share the same loaded
# state. No-op when .env is absent (e.g. fresh sandbox); callers handle the
# missing-value fallback themselves.
_ensure_env_loaded() {
  if [[ "${_PRUNE_ENV_LOADED:-0}" == "1" ]]; then
    return 0
  fi
  _PRUNE_ENV_LOADED=1
  if [[ -f "${FILE_PATH}/.env.generated" ]]; then
    _load_env "${FILE_PATH}/.env.generated"
  fi
}

# _resolve_workspace sets _RESOLVED_WORKSPACE from (in order):
#   --workspace flag override, then $WS_PATH from .env (if .env exists).
# Exits 2 with a hint when neither resolves. Always loads .env so the
# subsequent _resolve_owner call inherits DOCKER_HUB_USER even when
# --workspace bypassed the WS_PATH lookup.
_resolve_workspace() {
  _ensure_env_loaded
  if [[ -n "${WORKSPACE_OVERRIDE:-}" ]]; then
    _RESOLVED_WORKSPACE="${WORKSPACE_OVERRIDE}"
    return 0
  fi
  if [[ -n "${WS_PATH:-}" ]]; then
    _RESOLVED_WORKSPACE="${WS_PATH}"
    return 0
  fi
  _log_err prune prune_no_workspace "display=cannot resolve workspace; pass --workspace <dir> or run from a repo with .env (no WS_PATH found)"
  exit 2
}

# _resolve_owner sets _RESOLVED_OWNER for the safety gate. Order:
#   --owner flag override → $DOCKER_HUB_USER from .env → inline detect
#   (mirrors setup.sh's detect_docker_hub_user: `docker info`
#   Username → $USER → `id -un`). Never empty — at minimum $USER /
#   id -un produce a value, so this function does not exit.
_resolve_owner() {
  _ensure_env_loaded
  if [[ -n "${OWNER_OVERRIDE:-}" ]]; then
    _RESOLVED_OWNER="${OWNER_OVERRIDE}"
    return 0
  fi
  if [[ -n "${DOCKER_HUB_USER:-}" ]]; then
    _RESOLVED_OWNER="${DOCKER_HUB_USER}"
    return 0
  fi
  local _name
  _name="$(docker info 2>/dev/null \
    | awk '/^[[:space:]]*Username:/{print $2}')" || true
  _RESOLVED_OWNER="${_name:-${USER:-$(id -un)}}"
}

# _matches_repo_filter checks <name> against the REPO_FILTERS array.
# Exit 0 when filters empty (no filter == all match) or any filter
# matches as either exact equality or a `<filter>-` prefix.
_matches_repo_filter() {
  local _name="${1:?_matches_repo_filter requires name}"
  if (( ${#REPO_FILTERS[@]} == 0 )); then
    return 0
  fi
  local _f
  for _f in "${REPO_FILTERS[@]}"; do
    if [[ "${_name}" == "${_f}" || "${_name}" == "${_f}-"* ]]; then
      return 0
    fi
  done
  return 1
}

# _run_worktree_orphans_prune enumerates tagged docker images and removes
# the ones whose source worktree dir is gone. Safety gates: only acts on
# images whose `<owner>/` prefix matches the resolved owner; bare-name
# and other-user images are skipped. See plan #388 for the algorithm.
_run_worktree_orphans_prune() {
  local _RESOLVED_WORKSPACE _RESOLVED_OWNER
  _resolve_workspace
  _resolve_owner
  local _worktree_root="${_RESOLVED_WORKSPACE%/}/worktree"

  _log_info prune prune_worktree_scan "display=Scanning worktree-orphan images (owner=${_RESOLVED_OWNER}, workspace=${_RESOLVED_WORKSPACE})..." "owner=${_RESOLVED_OWNER}" "workspace=${_RESOLVED_WORKSPACE}"

  # IFS read into array — `docker images` output is one tag per line.
  local -a _all_images=()
  local _line
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _all_images+=("${_line}")
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | grep -v ':<none>$' || true)

  local -a _candidates=()
  local -a _skipped_other_owner=()
  local -a _skipped_bare=()
  local _full _repo_part _tag _user _name
  for _full in "${_all_images[@]}"; do
    _tag="${_full##*:}"
    _repo_part="${_full%:*}"

    # Safety gate #1: bare names (no '/') — cannot prove ownership.
    if [[ "${_repo_part}" != */* ]]; then
      _name="${_repo_part}"
      # Only collect for the summary if it looks worktree-shaped
      # (contains a hyphen). Otherwise it is plainly a main checkout.
      if [[ "${_name}" == *-* ]]; then
        _skipped_bare+=("${_full}")
      fi
      continue
    fi

    _user="${_repo_part%%/*}"
    _name="${_repo_part#*/}"

    # Safety gate #2: owner mismatch — refuse to touch other-user images.
    if [[ "${_user}" != "${_RESOLVED_OWNER}" ]]; then
      if [[ "${_name}" == *-* ]]; then
        _skipped_other_owner+=("${_full}")
      fi
      continue
    fi

    # Main-checkout pattern (no worktree suffix marker) — never a candidate.
    if [[ "${_name}" != *-* ]]; then
      continue
    fi

    # --repo filter narrows by basename prefix or exact match.
    if ! _matches_repo_filter "${_name}"; then
      continue
    fi

    # Worktree directory still on disk → repo still alive, keep image.
    if [[ -d "${_worktree_root}/${_name}" ]]; then
      continue
    fi

    _candidates+=("${_full}")
  done

  # Always emit the safety summary so the user knows we deliberately
  # left other-user / bare-name images alone.
  if (( ${#_skipped_other_owner[@]} > 0 )); then
    _log_info prune prune_skip_other_owner "display=Skipping ${#_skipped_other_owner[@]} image(s) owned by another user (safety):" "count=${#_skipped_other_owner[@]}"
    printf '  %s\n' "${_skipped_other_owner[@]}" >&2
  fi
  if (( ${#_skipped_bare[@]} > 0 )); then
    _log_info prune prune_skip_bare "display=Skipping ${#_skipped_bare[@]} bare-name image(s) — ownership unknown:" "count=${#_skipped_bare[@]}"
    printf '  %s\n' "${_skipped_bare[@]}" >&2
  fi

  if (( ${#_candidates[@]} == 0 )); then
    _log_info prune prune_worktree_none "display=No worktree orphans found."
    return 0
  fi

  _log_info prune prune_worktree_candidates "display=Worktree-orphan candidates (${#_candidates[@]}):" "count=${#_candidates[@]}"
  printf '  %s\n' "${_candidates[@]}" >&2

  if [[ "${ASSUME_YES}" != true && "${DRY_RUN}" != true ]]; then
    printf '[prune] remove %d image(s)? [y/N] ' "${#_candidates[@]}" >&2
    local _reply
    read -r _reply
    case "${_reply}" in
      y|Y|yes|YES) ;;
      *)
        _log_info prune prune_aborted "display=aborted by user."
        return 1
        ;;
    esac
  fi

  local _img
  for _img in "${_candidates[@]}"; do
    _dry_run_cmd docker rmi "${_img}" || true
  done
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
  local DO_WORKTREE_ORPHANS=false
  local WORKSPACE_OVERRIDE=""
  local OWNER_OVERRIDE=""
  local -a REPO_FILTERS=()
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
        # Also excludes --worktree-orphans intentionally — that mode
        # requires workspace + filesystem context the daemon-wide
        # bulk prune does not have. Chain explicitly when needed:
        #   ./prune.sh --all --worktree-orphans
        DO_NETWORKS=true
        DO_IMAGES=true
        DO_BUILDER=true
        shift
        ;;
      --worktree-orphans)
        # #388: surgically remove tagged images whose source worktree
        # dir is gone. Always opt-in; safety-gated to the current
        # DOCKER_HUB_USER's images only.
        DO_WORKTREE_ORPHANS=true
        shift
        ;;
      --workspace)
        WORKSPACE_OVERRIDE="${2:?"--workspace requires a value"}"
        shift 2
        ;;
      --owner)
        OWNER_OVERRIDE="${2:?"--owner requires a value"}"
        shift 2
        ;;
      --repo)
        REPO_FILTERS+=("${2:?"--repo requires a value"}")
        shift 2
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
        _log_err prune prune_unknown_flag "display=unknown flag: $1" "flag=$1"
        exit 2
        ;;
    esac
  done
  export DRY_RUN

  # No target selected → print help-y error and exit 2 (not 0; caller likely
  # invoked us by mistake — avoid silent no-op).
  if [[ "${DO_NETWORKS}" != true && "${DO_IMAGES}" != true \
        && "${DO_VOLUMES}" != true && "${DO_BUILDER}" != true \
        && "${DO_WORKTREE_ORPHANS}" != true ]]; then
    _log_err prune prune_nothing_selected "display=$(_msg info nothing_selected)"
    exit 2
  fi

  # #440: pre-prune hook fires after arg parsing + target selection,
  # before any docker prune fires. Skipped under --dry-run.
  _run_pre_hook prune "$@" || exit $?

  # Resolve per-target until value: --until overrides the per-kind default.
  local _net_until="${UNTIL_OVERRIDE:-10m}"
  local _img_until="${UNTIL_OVERRIDE:-24h}"
  local _bldr_until="${UNTIL_OVERRIDE:-24h}"
  local _vol_until="${UNTIL_OVERRIDE}"  # default: no filter for volumes

  if [[ "${DO_NETWORKS}" == true ]]; then
    _log_info prune prune_networks "display=Pruning networks (until=${_net_until})..." "until=${_net_until}"
    _run_prune network "${_net_until}"
  fi

  if [[ "${DO_IMAGES}" == true ]]; then
    _log_info prune prune_images "display=Pruning dangling images (until=${_img_until})..." "until=${_img_until}"
    _run_prune image "${_img_until}"
  fi

  if [[ "${DO_BUILDER}" == true ]]; then
    _log_info prune prune_buildx "display=Pruning buildx cache (until=${_bldr_until})..." "until=${_bldr_until}"
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
          _log_info prune prune_volume_aborted "display=$(_msg info volume_aborted)"
          exit 1
          ;;
      esac
    fi
    _log_info prune prune_volumes "display=Pruning volumes (until=${_vol_until:-<none>})..." "until=${_vol_until:-<none>}"
    _run_prune volume "${_vol_until}"
  fi

  if [[ "${DO_WORKTREE_ORPHANS}" == true ]]; then
    _run_worktree_orphans_prune
  fi

  # #440: post-prune hook fires at end of main(), after all prune
  # targets complete.
  _run_post_hook prune "$@"
}

main "$@"
