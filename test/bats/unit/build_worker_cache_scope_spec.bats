#!/usr/bin/env bats
#
# build_worker_cache_scope_spec.bats -- unit tests for
# script/ci/build_worker/cache_scope.sh, the buildx cache-scope base-key
# resolver extracted out of build-worker.yaml's inline `Compute cache
# scope` step.
#
# The scope key shape carries a real cache-scope bug history (per-(repo,
# variant, arch) scoping, and the shared-scope manifest cascade that once
# invalidated sibling caches), yet the derivation lived as inline shell
# reachable only in production. Pushing it down to a pure-shell script
# (System-level logic
# -> Unit level, ADR-00000018) makes the shape -- including the optional
# cache_variant segment single-call callers omit -- runnable locally under
# `just test`.
#
# The script reads image_name / cache_variant / matrix.hardware from env
# (mirroring build-worker.yaml's `env:` pre-expansion convention) and
# prints the base key `${image_name}[-${cache_variant}]-${hardware}`; the
# per-target suffix (-devel-cache, ...) is still appended at each use site,
# and the GITHUB_OUTPUT plumbing stays thin in the YAML.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  SCRIPT="/source/script/ci/build_worker/cache_scope.sh"
  [[ -f "${SCRIPT}" ]] || skip "cache_scope.sh not at expected path"
}

@test "cache_scope: single-call caller (no cache_variant) -> image-hardware key" {
  IMAGE_NAME="ai_agent" CACHE_VARIANT="" HARDWARE="x86_64" run bash "${SCRIPT}"
  assert_success
  assert_output "ai_agent-x86_64"
}

@test "cache_scope: aarch64 hardware threads through unchanged" {
  IMAGE_NAME="ai_agent" CACHE_VARIANT="" HARDWARE="aarch64" run bash "${SCRIPT}"
  assert_success
  assert_output "ai_agent-aarch64"
}

@test "cache_scope: cache_variant is inserted between image and hardware (#272)" {
  IMAGE_NAME="ros2_distro" CACHE_VARIANT="humble-desktop-full" HARDWARE="x86_64" \
    run bash "${SCRIPT}"
  assert_success
  assert_output "ros2_distro-humble-desktop-full-x86_64"
}

@test "cache_scope: distro-in-image_name repos need no variant (per-scope already unique)" {
  IMAGE_NAME="ros1_bridge-humble" CACHE_VARIANT="" HARDWARE="x86_64" run bash "${SCRIPT}"
  assert_success
  assert_output "ros1_bridge-humble-x86_64"
}
