#!/usr/bin/env bats
#
# Unit guard for script/checkout_identity.sh and the pre build/run/stop hooks
# that call it.
#
# Why: every checkout of this repo on one host used to resolve the same image
# tag (${DOCKER_HUB_USER}/isaac:<stage>, from the committed
# `[image] rule_1 = string:isaac`) and therefore the same compose project
# (${DOCKER_HUB_USER}-isaac). base's build auto-prune then deleted another
# checkout's image, and `stop` / `run` tore down another checkout's
# containers (upstream: base#1550, base#1551). The isaac-side stopgap gives
# each checkout its own image name through base's per-checkout
# `.setup.conf.local` layer, and refuses build/run/stop while a checkout is
# still on the shared identity.
#
# Behavioral: the spec drives the real script and the real hooks against a
# throwaway repo dir in BATS_TEST_TMPDIR. No docker, no GPU.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="${BATS_TEST_DIRNAME}/checkout_identity.sh"
  export ISAAC_IDENTITY_LIB="${LIB}"
  REPO="${BATS_TEST_TMPDIR}/work/isaac"
  mkdir -p "${REPO}"
  export FILE_PATH="${REPO}"
  unset ISAAC_ALLOW_SHARED_IDENTITY
}

# _env_generated <image_name> <project_name>
_env_generated() {
  printf 'USER_NAME=alice\nDOCKER_HUB_USER=alice\nIMAGE_NAME=%s\nPROJECT_NAME=%s\n' \
    "$1" "$2" > "${REPO}/.env.generated"
}

@test "checkout_identity: script is baked into the test stage" {
  [ -f "${LIB}" ]
}

@test "checkout_identity: slug is deterministic for one path" {
  run bash "${LIB}" slug "${REPO}"
  assert_success
  local _first="${output}"
  run bash "${LIB}" slug "${REPO}"
  assert_success
  assert_output "${_first}"
}

@test "checkout_identity: two checkouts with the same basename get different slugs" {
  local _other="${BATS_TEST_TMPDIR}/elsewhere/isaac"
  mkdir -p "${_other}"
  run bash "${LIB}" slug "${REPO}"
  local _a="${output}"
  run bash "${LIB}" slug "${_other}"
  local _b="${output}"
  [ -n "${_a}" ]
  [ -n "${_b}" ]
  [ "${_a}" != "${_b}" ]
  # Neither may be the shared name every plain checkout used to resolve.
  [ "${_a}" != "isaac" ]
  [ "${_b}" != "isaac" ]
}

@test "checkout_identity: slug is a valid image name and compose project name" {
  local _odd="${BATS_TEST_TMPDIR}/My Repo__Copy (2)"
  mkdir -p "${_odd}"
  for _p in "${REPO}" "${_odd}"; do
    run bash "${LIB}" slug "${_p}"
    assert_success
    # docker image path component + compose project rule (lowercase,
    # starts with a letter/digit, no trailing separator).
    [[ "${output}" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] \
      || { echo "invalid slug: '${output}'" >&2; return 1; }
    [[ "${output}" == isaac-* ]]
  done
}

@test "checkout_identity: isolate writes a per-checkout [image] rule to .setup.conf.local" {
  run bash "${LIB}" isolate "${REPO}"
  assert_success
  local _slug
  _slug="$(bash "${LIB}" slug "${REPO}")"
  run cat "${REPO}/.setup.conf.local"
  assert_output --partial "[image]"
  assert_output --partial "rule_1 = string:${_slug}"
}

@test "checkout_identity: isolate is idempotent and keeps other local sections" {
  printf '[network]\nmode = host\n' > "${REPO}/.setup.conf.local"
  bash "${LIB}" isolate "${REPO}" >/dev/null
  bash "${LIB}" isolate "${REPO}" >/dev/null
  run grep -c '^\[image\]$' "${REPO}/.setup.conf.local"
  assert_output "1"
  run grep -c '^\[network\]$' "${REPO}/.setup.conf.local"
  assert_output "1"
}

@test "checkout_identity: isolate leaves an operator-written [image] section alone" {
  printf '[image]\nrule_1 = string:my-own-name\n' > "${REPO}/.setup.conf.local"
  run bash "${LIB}" isolate "${REPO}"
  assert_success
  run cat "${REPO}/.setup.conf.local"
  assert_output --partial "rule_1 = string:my-own-name"
  refute_output --partial "string:isaac-"
}

@test "guard: build refuses the shared isaac image tag" {
  _env_generated isaac alice-isaac
  run bash "${LIB}" guard build "${REPO}"
  assert_failure
  assert_output --partial "alice/isaac"
  assert_output --partial "checkout_identity.sh isolate"
}

@test "guard: build passes for a per-checkout image name" {
  _env_generated isaac-wt-1a2b3c alice-isaac-wt-1a2b3c
  run bash "${LIB}" guard build "${REPO}"
  assert_success
}

@test "guard: run and stop refuse the shared default project" {
  _env_generated isaac alice-isaac
  for _verb in run stop; do
    run bash "${LIB}" guard "${_verb}" "${REPO}"
    assert_failure
    assert_output --partial "alice-isaac"
  done
}

@test "guard: run and stop pass for a pinned distinct project (CI) on the shared image" {
  # CI keeps IMAGE_NAME=isaac but pins PROJECT_NAME per run in .env.generated
  # (assert_pytest_baseline.sh / stream_smoke.sh), which is already isolated.
  _env_generated isaac isaac-baseline-42-1
  for _verb in run stop; do
    run bash "${LIB}" guard "${_verb}" "${REPO}"
    assert_success
  done
}

@test "guard: ISAAC_ALLOW_SHARED_IDENTITY=1 bypasses with a warning" {
  _env_generated isaac alice-isaac
  ISAAC_ALLOW_SHARED_IDENTITY=1 run bash "${LIB}" guard build "${REPO}"
  assert_success
  assert_output --partial "WARN"
}

@test "guard: no .env.generated yet -> nothing to check, passes" {
  run bash "${LIB}" guard build "${REPO}"
  assert_success
}

@test "pre hooks: build/run/stop refuse a shared checkout and pass an isolated one" {
  for _verb in build run stop; do
    local _hook="${BATS_TEST_DIRNAME}/pre_${_verb}_hook.sh"
    [ -x "${_hook}" ] || { echo "hook not baked: ${_hook}" >&2; return 1; }
    _env_generated isaac alice-isaac
    run "${_hook}"
    assert_failure
    _env_generated isaac-wt-1a2b3c alice-isaac-wt-1a2b3c
    run "${_hook}"
    assert_success
  done
}
