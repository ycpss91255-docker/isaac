#!/usr/bin/env bats
#
# multi_distro_build_worker_yaml_spec.bats — structural assertions for
# `.github/workflows/multi-distro-build-worker.yaml` (#325 B-1 dispatcher
# extended to N-D matrix-mode via #344).
#
# The dispatcher is a two-job reusable workflow on top of
# build-worker.yaml:
#
# 1. `resolve-matrix` — pure-shell selector that emits a `matrix`
#    `include`-shape JSON array output based on `github.event_name`.
#    `pull_request` -> `pr_matrix` (subset); everything else (tag push,
#    main push, workflow_dispatch) -> `tag_matrix` (full release matrix).
#
# 2. `call-build` — strategy.matrix job invoking
#    `./.github/workflows/build-worker.yaml` per matrix cell. Each cell
#    MUST have `name` (used for image_name suffix + cache scope) and
#    `build_args` (forwarded verbatim to build-worker.yaml). Derives
#    per-shard `image_name` as `<image_name>-<matrix.name>` so GHCR tags
#    disambiguate across cells. Per-cell
#    `cache_variant: ${{ matrix.name }}` so buildx GHA cache shards by
#    cell name (matches #272's per-variant scope pattern).
#
# 3. `ci-passed` — rollup aggregating the matrix result for branch
#    protection. Matches the existing rollup naming used by
#    env/ros_distro / env/ros2_distro per CLAUDE.md's status-check
#    table, so downstream branch-protection contexts don't change when
#    adopting this dispatcher.
#
# BREAKING since v0.32.0 (#344): the 1D inputs `pr_distros` /
# `tag_distros` / `distro_input_name` / `extra_build_args` are removed;
# callers must use `pr_matrix` / `tag_matrix` (full JSON include-shape)
# instead.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/multi-distro-build-worker.yaml"
  [[ -f "${WF}" ]] || skip "multi-distro-build-worker.yaml not at expected path"
}

# ── workflow_call interface ─────────────────────────────────────────

@test "multi-distro-build-worker.yaml: declares workflow_call (#325 B-1)" {
  run grep -E '^\s+workflow_call:' "${WF}"
  assert_success
}

@test "multi-distro-build-worker.yaml: required inputs include pr_matrix + tag_matrix + image_name (#344 matrix-mode)" {
  run awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'pr_matrix:'
  assert_output --partial 'tag_matrix:'
  assert_output --partial 'image_name:'
}

@test "multi-distro-build-worker.yaml: legacy 1D inputs are gone (no pr_distros / tag_distros / distro_input_name / extra_build_args) (#344 BREAKING)" {
  run awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}"
  assert_success
  refute_output --partial 'pr_distros:'
  refute_output --partial 'tag_distros:'
  refute_output --partial 'distro_input_name:'
  refute_output --partial 'extra_build_args:'
}

@test "multi-distro-build-worker.yaml: pr_matrix description mentions required name + build_args fields per entry (#344)" {
  run awk '/^      pr_matrix:/{flag=1; next} /^      [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'name'
  assert_output --partial 'build_args'
}

@test "multi-distro-build-worker.yaml: tag_matrix description mentions required name + build_args fields per entry (#344)" {
  run awk '/^      tag_matrix:/{flag=1; next} /^      [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'name'
  assert_output --partial 'build_args'
}

@test "multi-distro-build-worker.yaml: passthrough inputs mirror build-worker (build_runtime / test_tools_version / platforms / context_path / dockerfile_path / build_contexts) (#325 B-1)" {
  run awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'build_runtime:'
  assert_output --partial 'test_tools_version:'
  assert_output --partial 'platforms:'
  assert_output --partial 'context_path:'
  assert_output --partial 'dockerfile_path:'
  assert_output --partial 'build_contexts:'
}

# ── resolve-matrix job ───────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: resolve-matrix job emits matrix output (#344 include-shape)" {
  run awk '/^  resolve-matrix:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'matrix: ${{ steps.r.outputs.matrix }}'
}

@test "multi-distro-build-worker.yaml: resolve-matrix branches on github.event_name == pull_request (#344)" {
  run awk '/^  resolve-matrix:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'EVENT_NAME: ${{ github.event_name }}'
  assert_output --partial '"${EVENT_NAME}" == "pull_request"'
  assert_output --partial 'matrix=${PR_MATRIX}'
  assert_output --partial 'matrix=${TAG_MATRIX}'
}

# ── call-build matrix job ────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: call-build uses local build-worker via ./.github/workflows/build-worker.yaml (#325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: ./.github/workflows/build-worker.yaml'
}

@test "multi-distro-build-worker.yaml: call-build matrix is include: fromJSON(needs.resolve-matrix.outputs.matrix) (#344 N-D)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'include: ${{ fromJSON(needs.resolve-matrix.outputs.matrix) }}'
}

@test "multi-distro-build-worker.yaml: call-build derives per-shard image_name as <image_name>-<matrix.name> (hyphen, #344)" {
  # Hyphen separator chosen to match the existing org pattern (e.g.
  # app/ros1_bridge's pre-dispatcher main.yaml shipped
  # `ros1_bridge-${distro}`). #339 v0.29.1 fix carried over.
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'image_name: ${{ inputs.image_name }}-${{ matrix.name }}'
  refute_output --partial 'image_name: ${{ inputs.image_name }}_${{ matrix.name }}'
}

@test "multi-distro-build-worker.yaml: call-build passes matrix.build_args verbatim as build_args (#344)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'build_args: ${{ matrix.build_args }}'
}

@test "multi-distro-build-worker.yaml: call-build splits buildx cache by name via cache_variant: matrix.name (#272 reuse, #344)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'cache_variant: ${{ matrix.name }}'
}

@test "multi-distro-build-worker.yaml: call-build has fail-fast: false so one shard's failure doesn't cancel siblings (#325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'fail-fast: false'
}

# ── ci-passed rollup ─────────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: ci-passed rollup job exists, depends on call-build, runs even if matrix failed (#325 B-1)" {
  run awk '/^  ci-passed:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: call-build'
  assert_output --partial 'if: ${{ always() }}'
  assert_output --partial 'NEEDS_RESULT'
  assert_output --partial 'needs.call-build.result'
}

@test "multi-distro-build-worker.yaml: ci-passed job has explicit name: ci-passed (matches existing multi-distro rollup contract) (#325 B-1)" {
  run awk '/^  ci-passed:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'name: ci-passed'
}
