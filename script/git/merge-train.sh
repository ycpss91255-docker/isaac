#!/usr/bin/env bash
#
# Merge-train for isaac PRs under strict branch protection (#368).
#
# Usage: merge-train.sh <pr-number>...
#
# One PR at a time, in the given order:
#   - BEHIND                         -> `gh pr update-branch` (merge, not rebase)
#   - required checks green + CLEAN  -> merge with the repo's allowed method
#   - a required check failing       -> report FAIL and stop
#
# After a PR this script merged reaches MERGED, cleanup-merged-worktree.sh is
# called once for it; a SKIP there never changes the exit code. A PR that was
# already MERGED when the train reached it is not cleaned up (the owner or the
# web UI merged it; `just cleanup-merged` covers that case).
#
# Emits one line per state change; exits when all are merged or one fails.
#
# Environment:
#   REPO             OWNER/REPO (default ycpss91255-docker/isaac)
#   CLEANUP_SCRIPT   cleanup script (default: sibling cleanup-merged-worktree.sh)

set -uo pipefail

readonly REPO="${REPO:-ycpss91255-docker/isaac}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CLEANUP_SCRIPT="${CLEANUP_SCRIPT:-${SCRIPT_DIR}/cleanup-merged-worktree.sh}"
readonly REQUIRED_CHECKS=("call-docker-build / docker-build" "gpu-integration / gpu")

LAST=""

# Prints a status line unless it repeats the previous one.
say() {
  [[ "$1" != "${LAST}" ]] && echo "$1"
  LAST="$1"
}

# Prints the gh --jq program that reduces a PR to one
# "state|mergeStateStatus|required-checks|other-failed-checks" line.
view_jq() {
  local names="" n
  for n in "${REQUIRED_CHECKS[@]}"; do
    names+="${names:+,}\"${n}\""
  done
  printf '%s' "[.state, .mergeStateStatus,
    ([.statusCheckRollup[]? | select(.name | IN(${names}))
      | (if (.conclusion // \"\") == \"\" then .status else .conclusion end)]
      | join(\",\")),
    ([.statusCheckRollup[]?
      | select((.conclusion // \"\") | IN(\"FAILURE\",\"CANCELLED\",\"TIMED_OUT\"))
      | .name] | join(\",\"))] | join(\"|\")"
}

# Runs the cleanup script for PR $1; its outcome never affects the exit code.
cleanup() {
  local out
  out="$("${CLEANUP_SCRIPT}" "$1" 2>&1)" || true
  [[ -z "${out}" ]] || echo "PR$1: cleanup: ${out//$'\n'/ | }"
}

main() {
  local pr info state mss checks other method err attempted jq_prog
  jq_prog="$(view_jq)"

  for pr in "$@"; do
    attempted=0
    while true; do
      info="$(gh pr view "${pr}" --repo "${REPO}" --json \
        state,mergeStateStatus,statusCheckRollup --jq "${jq_prog}" 2>/dev/null)" \
        || { sleep 60; continue; }
      IFS='|' read -r state mss checks other <<<"${info}"

      if [[ "${state}" == "MERGED" ]]; then
        say "PR${pr}: MERGED"
        # Clean up only a PR this run merged (even if gh reported an error
        # after the merge went through, e.g. a local branch delete).
        ((attempted)) && cleanup "${pr}"
        break
      fi
      if [[ "${state}" == "CLOSED" ]]; then
        say "PR${pr}: CLOSED (skipped)"
        break
      fi
      if grep -qE 'FAILURE|CANCELLED|TIMED_OUT|ACTION_REQUIRED' <<<"${checks}"; then
        say "PR${pr}: FAIL checks=${checks}"
        exit 1
      fi
      # Any other failed check (e.g. hosted-unit) can skip the GPU job,
      # leaving the required check absent and the PR BLOCKED forever.
      if [[ -n "${other}" ]]; then
        say "PR${pr}: FAIL non-required checks=${other}"
        exit 1
      fi
      case "${mss}" in
        BEHIND)
          say "PR${pr}: behind main -> update-branch"
          gh pr update-branch "${pr}" --repo "${REPO}" >/dev/null 2>&1 \
            || say "PR${pr}: update-branch failed"
          sleep 90
          ;;
        CLEAN)
          if [[ "${checks}" == "SUCCESS,SUCCESS" ]]; then
            # Use the method the repo allows: squash when enabled, else a
            # merge commit.
            method="merge"
            if [[ "$(gh api "repos/${REPO}" -q .allow_squash_merge 2>/dev/null)" \
                == "true" ]]; then
              method="squash"
            fi
            attempted=1
            if err="$(gh pr merge "${pr}" --repo "${REPO}" "--${method}" \
                --delete-branch 2>&1)"; then
              # Loop once more: the next view reports MERGED and cleans up.
              say "PR${pr}: merge requested (${method})"
              continue
            fi
            say "PR${pr}: merge attempt failed (state=${mss}): ${err}"
          fi
          sleep 60
          ;;
        DIRTY)
          say "PR${pr}: CONFLICT -- needs manual resolution"
          exit 1
          ;;
        *)
          say "PR${pr}: ${mss} checks=${checks:-none}"
          sleep 60
          ;;
      esac
    done
  done
  echo "ALL_DONE"
}

main "$@"
