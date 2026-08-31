#!/usr/bin/env bats
#
# publish_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/publish-worker.yaml` reusable workflow.
#
# publish-worker is the opt-in `call-publish` reusable workflow that
# foundational image repos (ros_distro / ros2_distro) reference to push
# their Dockerfile target stage to a registry on tag push. Downstream
# app repos consume the result via `FROM ${registry}/${owner}/<image>`.
#
# the original `publish` job was a per-platform matrix where every
# shard pushed the SAME computed tag(s) via `push: true` + `tags:`. With
# a 2-platform matrix the second shard's single-arch manifest overwrites
# the first at the tag — a last-shard-wins single-arch image, not a
# multi-arch manifest list (despite the docstring claiming otherwise).
# The fix mirrors the release-test-tools pattern: each shard pushes
# BY DIGEST (no tag), uploads its digest as an artifact, and a `merge`
# job assembles the tagged manifest list via
# `docker buildx imagetools create`. These guards lock that contract.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/publish-worker.yaml"
  [[ -f "${WF}" ]] || skip "publish-worker.yaml not at expected path"
}

# ── Reusable-workflow surface preserved ──────────────────────────────

@test "publish-worker.yaml: stays a reusable workflow_call workflow" {
  run grep -E '^\s+workflow_call:' "${WF}"
  assert_success
}

@test "publish-worker.yaml: preserves the registry-parameterised inputs" {
  for _in in image_name tag_suffix is_latest registry target build_args platforms context_path dockerfile_path build_contexts test_tools_version; do
    run grep -E "^      ${_in}:" "${WF}"
    assert_success
  done
}

# ── Native-runner matrix (shared with build/publishconvention) ─

@test "publish-worker.yaml: compute-matrix maps platforms to native runners" {
  run grep -E '^  compute-matrix:' "${WF}"
  assert_success
  run grep -F 'ubuntu-24.04-arm' "${WF}"
  assert_success
  run grep -F 'ubuntu-latest' "${WF}"
  assert_success
}

@test "publish-worker.yaml: build shards run on the matrix runner" {
  run grep -F 'runs-on: ${{ matrix.runner }}' "${WF}"
  assert_success
}

# ──push-by-digest per shard + manifest merge ──────────────────

@test "publish-worker.yaml: build shards push per-platform BY DIGEST (#602)" {
  run grep -F 'platforms: ${{ matrix.platform }}' "${WF}"
  assert_success
  run grep -F 'push-by-digest=true' "${WF}"
  assert_success
}

@test "publish-worker.yaml: shards do NOT push the same tag per shard (#602 regression guard)" {
  # The latent bug: every matrix shard ran `push: true` + a shared
  # `tags: ${{ steps.tags.outputs.tags }}`, overwriting the tag with a
  # single arch. After the fix tags are applied only by the merge job.
  run grep -F 'tags: ${{ steps.tags.outputs.tags }}' "${WF}"
  assert_failure
}

@test "publish-worker.yaml: each shard exports + uploads its digest as an artifact (#602)" {
  run grep -F 'actions/upload-artifact' "${WF}"
  assert_success
  run grep -F 'name: digests-${{ matrix.hardware }}' "${WF}"
  assert_success
}

@test "publish-worker.yaml: merge job assembles the multi-arch manifest via imagetools (#602)" {
  run grep -E '^  merge:' "${WF}"
  assert_success
  run grep -F 'actions/download-artifact' "${WF}"
  assert_success
  run grep -F 'docker buildx imagetools create' "${WF}"
  assert_success
}

@test "publish-worker.yaml: merge resolves tags from inputs (version + optional latest) once (#602)" {
  # The tag-resolution logic (github.ref_name + tag_suffix, plus
  # :latest${suffix} when is_latest) moved intact into the merge job so
  # tags are applied exactly once, at manifest-create time.
  run awk '/Resolve tags/{flag=1} flag' "${WF}"
  assert_success
  assert_output --partial 'latest'
  assert_output --partial 'SUFFIX'
}

@test "publish-worker.yaml: merge login uses the parameterised registry (not hardcoded ghcr.io)" {
  # publish-worker is registry-parameterised; the merge job must log in
  # to inputs.registry to push the manifest list.
  run awk '/^  merge:/{flag=1} flag' "${WF}"
  assert_success
  assert_output --partial 'registry: ${{ inputs.registry }}'
}

# ── GHCR push permission ─────────────────────────────────────────────

@test "publish-worker.yaml: declares packages: write on both push jobs" {
  # build (by-digest push) and merge (manifest push) each need it;
  # reusable-workflow permissions are per-job.
  run grep -cE '^\s+packages:\s+write' "${WF}"
  assert_success
  [ "${output}" -ge 2 ]
}
