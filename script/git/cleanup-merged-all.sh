#!/usr/bin/env bash
#
# Run cleanup-merged-worktree.sh for every worktree whose branch has a MERGED
# pull request (#368). This is what `just cleanup-merged` runs; it covers PRs
# merged outside merge-train.sh (e.g. in the web UI).
#
# Usage: cleanup-merged-all.sh [--dry-run] [--fix-owner] [--repo OWNER/REPO]
#
# Each worktree (the main checkout is excluded) is handled independently: a
# failure in one never aborts the batch, it counts as skipped. Prints one line
# per worktree and a final summary:
#
#   removed=N skipped=M            (with --dry-run: removed=0, and the number
#                                   that would be removed is on WOULD-REMOVE
#                                   lines)
#
# Environment:
#   CLEANUP_SCRIPT  per-PR cleanup script
#                   (default: sibling cleanup-merged-worktree.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-${SCRIPT_DIR}/cleanup-merged-worktree.sh}"

usage() {
  echo "Usage: ${0##*/} [--dry-run] [--fix-owner] [--repo OWNER/REPO]" >&2
}

main() {
  local passthru=() repo_args=() dry_run=0
  while (($# > 0)); do
    case "$1" in
      --dry-run) dry_run=1; passthru+=(--dry-run) ;;
      --fix-owner) passthru+=(--fix-owner) ;;
      --repo)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        repo_args=(--repo "$2")
        passthru+=(--repo "$2")
        shift
        ;;
      -h | --help) usage; exit 0 ;;
      *) usage; exit 2 ;;
    esac
    shift
  done

  # Collect "path<TAB>branch" for every non-main worktree on a branch.
  local entries=() line cur="" idx=0
  while IFS= read -r line; do
    case "${line}" in
      "worktree "*)
        cur="${line#worktree }"
        idx=$((idx + 1))
        ;;
      "branch refs/heads/"*)
        # Record 1 is the main checkout.
        if ((idx > 1)); then
          entries+=("${cur}"$'\t'"${line#branch refs/heads/}")
        fi
        ;;
      *) ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  local removed=0 skipped=0 entry branch pr out rc first_line
  for entry in "${entries[@]}"; do
    branch="${entry#*$'\t'}"
    pr="$(gh pr list "${repo_args[@]}" --head "${branch}" --state merged \
      --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)" || pr=""
    if [[ -z "${pr}" ]]; then
      echo "SKIP ${branch}: no merged PR"
      skipped=$((skipped + 1))
      continue
    fi
    out="$("${CLEANUP_SCRIPT}" "${passthru[@]}" "${pr}" 2>&1)"
    rc=$?
    first_line="${out%%$'\n'*}"
    if ((rc != 0)); then
      echo "SKIP ${branch} (PR ${pr}): cleanup failed rc=${rc}: ${first_line}"
      skipped=$((skipped + 1))
      continue
    fi
    case "${first_line}" in
      REMOVED*)
        echo "PR ${pr}: ${first_line}"
        removed=$((removed + 1))
        ;;
      WOULD-REMOVE*)
        echo "PR ${pr}: ${first_line}"
        ;;
      *)
        echo "PR ${pr}: ${first_line:-SKIP no-output} (${branch})"
        skipped=$((skipped + 1))
        ;;
    esac
  done
  ((dry_run)) && echo "(dry-run: nothing was removed)"
  echo "removed=${removed} skipped=${skipped}"
}

main "$@"
