#!/usr/bin/env bash
#
# Remove the worktree and local branch of a MERGED pull request (#368).
#
# Usage:
#   cleanup-merged-worktree.sh [--fix-owner] [--dry-run] [--repo OWNER/REPO] <pr-number>
#
# A pull request merged on GitHub triggers no local git event, so nothing
# cleans up after it. This script does, but only when it is provably safe:
#
#   1. the PR is MERGED;
#   2. a worktree has the PR's head branch checked out;
#   3. that worktree is under the worktree root and is not the main checkout;
#   4. the branch is not the default branch;
#   5. the worktree is clean (untracked files count as dirty);
#   6. the local HEAD equals the PR's headRefOid (nothing unpushed).
#
# Only then is `git worktree remove` (never --force) and `git branch -D` run.
# Every other outcome prints one `SKIP <reason>` line and exits 0, so callers
# (merge-train.sh, `just cleanup-merged`) are never failed by a skip.
#
# Root-owned files (e.g. left by a container) make the removal fail; that
# prints `SKIP root-owned files` plus the fix command. `--fix-owner` runs that
# fix in a throwaway container and retries once.
#
# `--dry-run` runs every check and prints `WOULD-REMOVE <path> (<branch>)`
# instead of removing anything.
#
# Environment:
#   WORKTREE_ROOT  Directory that must contain the worktree
#                  (default: <main checkout>/../worktree).
#
# Output on success: `REMOVED <path> (<branch>)` then `removed=1`.

set -uo pipefail

# Prints the usage text to stderr.
usage() {
  echo "Usage: ${0##*/} [--fix-owner] [--dry-run] [--repo OWNER/REPO] <pr-number>" >&2
}

# Prints "SKIP <reason>" and exits 0.
skip() {
  echo "SKIP $*"
  exit 0
}

# Prints the fix command for root-owned files under $1.
fix_command() {
  printf 'docker run --rm -v "%s:/x" busybox:1 chown -R "%s:%s" /x' \
    "$1" "$(id -u)" "$(id -g)"
}

main() {
  local fix_owner=0 dry_run=0 repo="" pr=""
  while (($# > 0)); do
    case "$1" in
      --fix-owner) fix_owner=1 ;;
      --dry-run) dry_run=1 ;;
      --repo)
        [[ $# -ge 2 ]] || { usage; exit 2; }
        repo="$2"
        shift
        ;;
      -h | --help) usage; exit 0 ;;
      -*) usage; exit 2 ;;
      *) [[ -z "${pr}" ]] || { usage; exit 2; }; pr="$1" ;;
    esac
    shift
  done
  [[ "${pr}" =~ ^[0-9]+$ ]] || { usage; exit 2; }

  local gh_args=(pr view "${pr}")
  [[ -z "${repo}" ]] || gh_args+=(--repo "${repo}")
  gh_args+=(--json "state,headRefName,headRefOid"
            --jq '[.state,.headRefName,.headRefOid] | @tsv')

  local info state branch oid
  info="$(gh "${gh_args[@]}" 2>/dev/null)" || skip "gh-failed"
  IFS=$'\t' read -r state branch oid <<<"${info}"

  [[ "${state}" == "MERGED" ]] || skip "not-merged"
  [[ -n "${branch}" && -n "${oid}" ]] || skip "gh-incomplete"

  # The first entry of `git worktree list` is the main checkout.
  local main_checkout=""
  main_checkout="$(git worktree list --porcelain 2>/dev/null \
    | sed -n '1s/^worktree //p')"
  [[ -n "${main_checkout}" ]] || skip "not-a-git-repo"

  # Find the worktree that has the head branch checked out.
  local wt="" line cur=""
  while IFS= read -r line; do
    case "${line}" in
      "worktree "*) cur="${line#worktree }" ;;
      "branch refs/heads/${branch}") wt="${cur}" ;;
      *) ;;
    esac
  done < <(git -C "${main_checkout}" worktree list --porcelain)
  [[ -n "${wt}" ]] || skip "no-worktree"

  local root="${WORKTREE_ROOT:-$(dirname "${main_checkout}")/worktree}"
  root="$(cd "${root}" 2>/dev/null && pwd -P)" || skip "outside-worktree-root"
  local wt_real
  wt_real="$(cd "${wt}" 2>/dev/null && pwd -P)" || skip "no-worktree"
  [[ "${wt_real}" != "$(cd "${main_checkout}" && pwd -P)" ]] \
    || skip "main-checkout"
  [[ "${wt_real}" == "${root}"/* ]] || skip "outside-worktree-root"

  local default_branch
  default_branch="$(git -C "${main_checkout}" symbolic-ref --short \
    refs/remotes/origin/HEAD 2>/dev/null)"
  default_branch="${default_branch#origin/}"
  [[ "${branch}" != "${default_branch:-main}" ]] || skip "default-branch"

  [[ -z "$(git -C "${wt_real}" status --porcelain 2>/dev/null)" ]] \
    || skip "dirty"

  local head
  head="$(git -C "${wt_real}" rev-parse HEAD 2>/dev/null)" || skip "no-head"
  if [[ "${head}" != "${oid}" ]]; then
    if git -C "${wt_real}" merge-base --is-ancestor "${oid}" "${head}" \
        2>/dev/null; then
      skip "unpushed"
    fi
    skip "head-mismatch"
  fi

  if ((dry_run)); then
    echo "WOULD-REMOVE ${wt_real} (${branch})"
    exit 0
  fi

  local err
  if ! err="$(git -C "${main_checkout}" worktree remove "${wt_real}" 2>&1)"; then
    if [[ "${err}" == *"Permission denied"* ]]; then
      if ((fix_owner)); then
        docker run --rm -v "${wt_real}:/x" busybox:1 \
          chown -R "$(id -u):$(id -g)" /x >/dev/null 2>&1 \
          || skip "fix-owner-failed"
        err="$(git -C "${main_checkout}" worktree remove "${wt_real}" 2>&1)" \
          || skip "remove-failed: ${err%%$'\n'*}"
      else
        echo "SKIP root-owned files"
        echo "  fix: $(fix_command "${wt_real}")"
        echo "  or re-run with --fix-owner"
        exit 0
      fi
    else
      skip "remove-failed: ${err%%$'\n'*}"
    fi
  fi

  git -C "${main_checkout}" branch -D "${branch}" >/dev/null 2>&1 \
    || skip "branch-delete-failed"
  echo "REMOVED ${wt_real} (${branch})"
  echo "removed=1"
}

main "$@"
