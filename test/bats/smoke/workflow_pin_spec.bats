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
  # Repo checkout: test/bats/smoke/ -> repo root.  devel-test image: the
  # Dockerfile bakes .github/workflows/ next to the specs (isaac#402).
  if [ -d "${BATS_TEST_DIRNAME}/../../../.github/workflows" ]; then
    WORKFLOW_DIR="${BATS_TEST_DIRNAME}/../../../.github/workflows"
  else
    WORKFLOW_DIR="${BATS_TEST_DIRNAME}/workflows"
  fi
  # A missing directory must fail, never pass vacuously.
  [ -d "${WORKFLOW_DIR}" ]
}

@test "no workflow references gpu-self-hosted.yml@main" {
  # Collect every 'uses:' line that references gpu-self-hosted.yml@main.
  local hits
  hits=$(grep -rn 'gpu-self-hosted\.yml@main' "${WORKFLOW_DIR}/" || true)
  if [ -n "${hits}" ]; then
    echo "Found unpinned gpu-self-hosted.yml@main references:"
    echo "${hits}"
    echo ""
    echo "Pin to a release tag (e.g. @v0.4.0) instead."
    return 1
  fi
}

@test "every gpu-self-hosted.yml caller is pinned to @v0.4.0" {
  local f
  for f in main.yaml stream-smoke.yaml publish-stream-source.yaml; do
    [ -f "${WORKFLOW_DIR}/${f}" ] || { echo "missing caller: ${f}"; return 1; }
    grep -q 'gpu-self-hosted\.yml@v0\.4\.0' "${WORKFLOW_DIR}/${f}" \
      || { echo "${f} is not pinned to gpu-self-hosted.yml@v0.4.0"; return 1; }
  done
  # No gpu-self-hosted.yml ref anywhere may be a tag other than v0.4.0.
  local other
  other=$(grep -rn 'gpu-self-hosted\.yml@' "${WORKFLOW_DIR}/" \
    | grep -v 'gpu-self-hosted\.yml@v0\.4\.0' || true)
  if [ -n "${other}" ]; then
    echo "gpu-self-hosted.yml refs not at @v0.4.0:"
    echo "${other}"
    return 1
  fi
}
