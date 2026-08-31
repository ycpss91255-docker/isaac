#!/usr/bin/env bash
# cache_scope.sh -- buildx cache-scope base-key resolver for the reusable
# Docker build worker (build-worker.yaml).
#
# Derives the per-(repo, variant, arch) buildx cache scope base
# `${image_name}[-${cache_variant}]-${hardware}` that the four build-push
# steps (and the extra_stages loop) suffix per target (-devel-cache,
# -devel-test-cache, ...). The optional cache_variant segment is present
# only for repos that call the worker multiple times with one image_name
# but different build_args (the env / ros2_distro pattern); single-call
# callers leave it empty and the key reduces to ${image_name}-${hardware},
# which is already per-(repo, arch).
#
# Pushed down out of build-worker.yaml's inline `Compute cache scope` step so
# the shape -- which carries a real cache-scope bug history (per-(repo,
# variant, arch) scoping, and the shared-scope manifest cascade that once
# invalidated sibling caches) -- is host-testable under `just test`
# (System-level logic -> Unit level, ADR-00000018); the workflow keeps only
# the thin GITHUB_OUTPUT plumbing around this script's stdout.
#
# Input : IMAGE_NAME / CACHE_VARIANT / HARDWARE env vars (CACHE_VARIANT may
#         be empty). Output: the base scope key on stdout. The logic is
#         CI-host-agnostic: only build-worker.yaml binds the env + stdout to
#         GitHub.

set -euo pipefail

main() {
  local base="${IMAGE_NAME:-}"
  if [[ -n "${CACHE_VARIANT:-}" ]]; then
    base="${base}-${CACHE_VARIANT}"
  fi
  printf '%s\n' "${base}-${HARDWARE:-}"
}

main "$@"
