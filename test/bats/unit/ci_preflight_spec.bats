#!/usr/bin/env bats
#
# ci_preflight_spec.bats -- unit tests for script/ci/preflight.sh, the
# caller-contract validator the reusable build/release workers run before
# doing any real work.
#
# The validator is a pure shell engine: it reads a declared requirement
# manifest (the explicit list of what a caller must provide) and checks
# each entry against an environment variable the worker populates from the
# real inputs / permission probes. Any missing item -> a plain-language,
# early, non-zero failure that names exactly what to add to main.yaml.
#
# Pushing the logic here (host-testable under `just test`) keeps the GHA
# wiring in build-worker.yaml / release-worker.yaml thin: the workflow only
# exports the env and calls this script.

bats_require_minimum_version 1.5.0

PREFLIGHT="/source/script/ci/preflight.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  MANIFEST="$(mktemp)"
}

teardown() {
  rm -f "${MANIFEST}"
}

@test "preflight: passes when a required input is present" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name to your build-worker.yaml call
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: fails when a required input is empty, naming the input" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add `image_name:` under the `with:` block in your main.yaml
EOF
  PREFLIGHT_INPUT_IMAGE_NAME="" run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  # Names the missing requirement and quotes the fix hint verbatim.
  assert_output --partial 'image_name'
  assert_output --partial 'with:'
  assert_output --partial 'main.yaml'
}

@test "preflight: passes when a permission probe reports granted" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  PREFLIGHT_PERM_PACKAGES=granted run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: fails when a permission probe reports missing" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  PREFLIGHT_PERM_PACKAGES=missing run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
  assert_output --partial 'permissions:'
}

@test "preflight: an unset permission probe env fails (never silently green)" {
  cat > "${MANIFEST}" <<'EOF'
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:` in your main.yaml
EOF
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
}

@test "preflight: reports every unmet requirement in one pass" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add `image_name:` under `with:`
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant `packages: write` under `permissions:`
EOF
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  # Both gaps surface together, not fail-on-first.
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
}

@test "preflight --list: prints the requirement list and exits 0 (self-describing)" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR login / packages permission|grant packages
EOF
  run bash "${PREFLIGHT}" --list "${MANIFEST}"
  assert_success
  assert_output --partial 'image_name'
  assert_output --partial 'packages'
  assert_output --partial 'the container image name'
}

@test "preflight: comment and blank lines in the manifest are ignored" {
  cat > "${MANIFEST}" <<'EOF'
# this is a comment

input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ai_agent run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: missing manifest file is a usage error (exit 2)" {
  run bash "${PREFLIGHT}" /no/such/manifest
  assert_failure
  assert_equal "${status}" 2
}

@test "preflight: an unknown manifest kind fails loudly, naming the offending kind (never silently green)" {
  # A typo in the kind column (`permision`) must not slip through as a
  # silent pass -- that would contradict the whole never-silent thesis.
  cat > "${MANIFEST}" <<'EOF'
permision|packages|PREFLIGHT_PERM_PACKAGES|typo'd kind column|grant packages
EOF
  PREFLIGHT_PERM_PACKAGES=granted run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'permision'
  assert_output --partial 'kind'
}

@test "preflight: an unknown manifest kind is a config error (exit 2)" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|ok|add image_name
boguskind|x|Y|z|fix
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_equal "${status}" 2
  assert_output --partial 'boguskind'
}

@test "preflight: an empty manifest is a usage error (exit 2), never silently green" {
  : > "${MANIFEST}"
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_equal "${status}" 2
  assert_output --partial 'no requirements'
}

@test "preflight: an all-comment manifest is a usage error (exit 2)" {
  cat > "${MANIFEST}" <<'EOF'
# only comments here

# nothing to validate
EOF
  run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_equal "${status}" 2
  assert_output --partial 'no requirements'
}

# ── conditional requirements ─────────────────────────────────────────
#
# A requirement may carry an optional 6th field `<condvar>=<value>`: it is
# only enforced when env `<condvar>` equals `<value>`, otherwise it is
# declared-but-not-applicable and skipped. This lets one static manifest
# gate the registry-cache backend's `packages: write` requirement on the
# caller's `cache_backend` selection without special-casing the engine per
# worker.

@test "preflight: a conditional requirement is skipped when its guard env does not match (#801)" {
  # cache_backend != registry -> the packages requirement does not apply,
  # so a missing permission does not fail the caller (backward compatible).
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR packages: write|grant `packages: write`|PREFLIGHT_CACHE_BACKEND=registry
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=gha \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight: a conditional requirement is enforced when its guard env matches (#801)" {
  # cache_backend == registry -> the packages requirement applies; a
  # caller that did not grant `packages: write` fails early with the fix.
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR packages: write|grant `packages: write` under `permissions:`|PREFLIGHT_CACHE_BACKEND=registry
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=registry \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_output --partial 'packages'
  assert_output --partial 'permissions:'
  # The guard field must not leak into the human-facing hint text.
  refute_output --partial 'PREFLIGHT_CACHE_BACKEND=registry'
}

@test "preflight: a matched conditional requirement passes when it is satisfied (#801)" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR packages: write|grant `packages: write`|PREFLIGHT_CACHE_BACKEND=registry
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_CACHE_BACKEND=registry \
  PREFLIGHT_PERM_PACKAGES=granted \
    run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_success
}

@test "preflight --list: annotates a conditional requirement with its guard (#801)" {
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR packages: write|grant packages|PREFLIGHT_CACHE_BACKEND=registry
EOF
  run bash "${PREFLIGHT}" --list "${MANIFEST}"
  assert_success
  assert_output --partial 'packages'
  # The list self-describes that packages is only required conditionally.
  assert_output --partial 'when PREFLIGHT_CACHE_BACKEND=registry'
}

@test "preflight: a malformed conditional guard (no '=') fails loudly as a config error (exit 2), never silently skipped (#801)" {
  # A guard field lacking `=` (e.g. `FOO` instead of `FOO=bar`) must not
  # fail open -- silently skipping the requirement would contradict the
  # never-silent thesis, same class as the unknown-`kind` guard. It is a
  # config error (exit 2) naming the offending guard + line.
  cat > "${MANIFEST}" <<'EOF'
input|image_name|PREFLIGHT_INPUT_IMAGE_NAME|the container image name|add image_name
permission|packages|PREFLIGHT_PERM_PACKAGES|GHCR packages: write|grant packages|BOGUSGUARD
EOF
  PREFLIGHT_INPUT_IMAGE_NAME=ros_noetic \
  PREFLIGHT_PERM_PACKAGES=missing \
    run bash "${PREFLIGHT}" "${MANIFEST}"
  assert_failure
  assert_equal "${status}" 2
  assert_output --partial 'BOGUSGUARD'
  assert_output --partial 'guard'
}

