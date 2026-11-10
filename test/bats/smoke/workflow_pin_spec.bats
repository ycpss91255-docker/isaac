#!/usr/bin/env bats
#
# Guard: every reusable-workflow reference to the org's gpu-self-hosted.yml
# must be pinned to a release tag, never @main.
#
# Motivation: when .github's main branch is broken even briefly, every isaac
# push/PR that reaches gpu-integration or stream-smoke fails with "workflow
# file issue" and 0 jobs (run 42776185240, 2026-11-10).  Pinning to a release
# tag insulates callers from upstream breakage.  Dependabot (github-actions
# ecosystem, weekly) creates bump PRs when a new tag is cut, so we still
# advance -- just deliberately.
#
# The base build-worker.yaml and release-worker.yaml references are already
# pinned (e.g. @v0.42.0); this spec covers gpu-self-hosted.yml.

bats_require_minimum_version 1.5.0

setup() {
  WORKFLOW_DIR="${BATS_TEST_DIRNAME}/../../../.github/workflows"
}

@test "no workflow references gpu-self-hosted.yml@main" {
  # Collect every 'uses:' line that references gpu-self-hosted.yml@main.
  local hits
  hits=$(grep -rn 'gpu-self-hosted\.yml@main' "${WORKFLOW_DIR}/" || true)
  if [ -n "${hits}" ]; then
    echo "Found unpinned gpu-self-hosted.yml@main references:"
    echo "${hits}"
    echo ""
    echo "Pin to a release tag (e.g. @v0.2.0) instead."
    return 1
  fi
}
