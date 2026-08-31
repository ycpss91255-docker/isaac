#!/usr/bin/env bash
#
# cd-guard.sh - CD-side pre-deploy guard (ADR-00000023).
#
# The deploy tool (`just setup deploy`) labels honestly and NEVER blocks: it
# stamps a `-dirty` / short-commit version so a user-review deploy of any
# tree state is possible. This guard is the opposite policy for automated
# CD: refuse to deploy unless the tree is clean AND sits on a tag, so a
# shipped field bundle is always traceable to a released version.
#
# Usage (from the repo root, before `just setup deploy --stage <stage>`):
#   ./.base/dist/deploy/cd-guard.sh
# Exits 0 when clean + tagged; non-zero (with a reason) otherwise.
set -euo pipefail

main() {
  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${repo_root}" ]]; then
    printf 'cd-guard: not inside a git repository -- refusing to deploy.\n' >&2
    return 1
  fi

  if [[ -n "$(git -C "${repo_root}" status --porcelain)" ]]; then
    printf 'cd-guard: working tree is dirty -- commit or stash before deploying.\n' >&2
    return 1
  fi

  if ! git -C "${repo_root}" describe --tags --exact-match >/dev/null 2>&1; then
    printf 'cd-guard: HEAD is not on a tag -- tag a release before deploying.\n' >&2
    return 1
  fi

  printf 'cd-guard: clean tree on tag %s -- ok to deploy.\n' \
    "$(git -C "${repo_root}" describe --tags --exact-match)"
  return 0
}

main "$@"
