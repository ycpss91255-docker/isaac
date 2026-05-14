#!/usr/bin/env bats
#
# multi_distro_build_worker_yaml_spec.bats — structural assertions for
# `.github/workflows/multi-distro-build-worker.yaml` (#325 B-1 dispatcher).
#
# The dispatcher is a two-job reusable workflow on top of
# build-worker.yaml:
#
# 1. `resolve-matrix` — pure-shell selector that emits a `distros` JSON
#    array output based on `github.event_name`. `pull_request` ->
#    `pr_distros` (subset); everything else (tag push, main push,
#    workflow_dispatch) -> `tag_distros` (full release matrix).
#
# 2. `call-build` — strategy.matrix job invoking
#    `./.github/workflows/build-worker.yaml` per distro shard. Derives
#    per-shard `image_name` as `<image_name>_<distro>` so GHCR tags
#    disambiguate across distros, and passes
#    `<distro_input_name>=<distro>` as the first `build_args` line.
#    Per-distro `cache_variant: ${{ matrix.distro }}` so buildx GHA
#    cache shards by distro (matches #272's per-variant scope pattern).
#
# 3. `ci-passed` — rollup aggregating the matrix result for branch
#    protection. Matches the existing rollup naming used by
#    env/ros_distro / env/ros2_distro per CLAUDE.md's status-check
#    table, so downstream branch-protection contexts don't change when
#    adopting this dispatcher.

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

@test "multi-distro-build-worker.yaml: required inputs include pr_distros + tag_distros + distro_input_name + image_name (#325 B-1)" {
  run awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'pr_distros:'
  assert_output --partial 'tag_distros:'
  assert_output --partial 'distro_input_name:'
  assert_output --partial 'image_name:'
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

@test "multi-distro-build-worker.yaml: defines extra_build_args passthrough (caller can append KEY=VALUE after the dispatcher's distro arg) (#325 B-1)" {
  run awk '/^on:/{flag=1} /^jobs:/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'extra_build_args:'
}

# ── resolve-matrix job ───────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: resolve-matrix job emits distros output (#325 B-1)" {
  run awk '/^  resolve-matrix:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'distros: ${{ steps.r.outputs.distros }}'
}

@test "multi-distro-build-worker.yaml: resolve-matrix branches on github.event_name == pull_request (#325 B-1)" {
  run awk '/^  resolve-matrix:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'EVENT_NAME: ${{ github.event_name }}'
  assert_output --partial '"${EVENT_NAME}" == "pull_request"'
  assert_output --partial 'distros=${PR_DISTROS}'
  assert_output --partial 'distros=${TAG_DISTROS}'
}

# ── call-build matrix job ────────────────────────────────────────────

@test "multi-distro-build-worker.yaml: call-build uses local build-worker via ./.github/workflows/build-worker.yaml (#325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: ./.github/workflows/build-worker.yaml'
}

@test "multi-distro-build-worker.yaml: call-build matrix is fromJSON(needs.resolve-matrix.outputs.distros) (#325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'distro: ${{ fromJSON(needs.resolve-matrix.outputs.distros) }}'
}

@test "multi-distro-build-worker.yaml: call-build derives per-shard image_name as <image_name>-<distro> (hyphen, v0.29.1 fix matches org convention)" {
  # Hyphen separator chosen to match the existing org pattern (e.g.
  # app/ros1_bridge's pre-dispatcher main.yaml shipped
  # `ros1_bridge-${distro}`). Underscore was used in the v0.29.0
  # initial implementation but never adopted by any consumer; v0.29.1
  # corrects it before the first downstream migration lands.
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'image_name: ${{ inputs.image_name }}-${{ matrix.distro }}'
  refute_output --partial 'image_name: ${{ inputs.image_name }}_${{ matrix.distro }}'
}

@test "multi-distro-build-worker.yaml: call-build passes <distro_input_name>=<distro> as build_args (#325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial '${{ inputs.distro_input_name }}=${{ matrix.distro }}'
}

@test "multi-distro-build-worker.yaml: call-build splits buildx cache by distro via cache_variant: matrix.distro (#272 reuse, #325 B-1)" {
  run awk '/^  call-build:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'cache_variant: ${{ matrix.distro }}'
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
