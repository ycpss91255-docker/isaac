#!/usr/bin/env bats
#
# --help / --lang coverage across the backing scripts (ADR-00000011 §6).
#
# The locked mechanism (the grill comment): every recipe-backing script
# prints an English-baseline usage on -h/--help and exits 0; the human-facing
# namespaces (docker / base / template) additionally accept --lang <code> and
# honor SETUP_LANG / $LANG via i18n.sh; the machine/CI namespaces (test /
# release) stay English-only (no --lang). Namespace-level bare invocation +
# the `just`-driven forwarding live in justfile_user_spec.bats (they need a
# consumer tree + a real `just`); this file exercises the scripts directly so
# it runs in any test-tools image, with no `just` dependency.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # /source is the mounted repo root in the ci container.
  TEST_SH="/source/script/test/test.sh"
  INIT_SH="/source/dist/script/base/init.sh"
  UPGRADE_SH="/source/dist/script/base/upgrade.sh"
  COMPLETIONS_SH="/source/dist/script/base/completions.sh"
  NEW_SH="/source/dist/script/template/new.sh"
}

# ── recipe --help: English baseline, exits 0, prints usage ────────────────────

@test "test.sh --help exits 0 and prints usage" {
  run bash "${TEST_SH}" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "test.sh -h exits 0 and prints usage" {
  run bash "${TEST_SH}" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "init.sh --help exits 0 and prints usage" {
  run bash "${INIT_SH}" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "upgrade.sh --help exits 0 and prints usage" {
  run bash "${UPGRADE_SH}" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "completions.sh --help exits 0 and prints usage" {
  run bash "${COMPLETIONS_SH}" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "completions.sh -h exits 0 and prints usage" {
  run bash "${COMPLETIONS_SH}" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "new.sh --help exits 0 and prints usage (#655: gained -h/--help)" {
  run bash "${NEW_SH}" --help
  assert_success
  assert_output --partial "just template new"
}

@test "new.sh -h exits 0 and prints usage" {
  run bash "${NEW_SH}" -h
  assert_success
  assert_output --partial "just template new"
}

# ── i18n scope: human-facing base/template scripts accept --lang ──────────────

@test "init.sh --help advertises --lang (#655 i18n namespace)" {
  run bash "${INIT_SH}" --help
  assert_success
  assert_output --partial "--lang"
}

@test "upgrade.sh --help advertises --lang (#655 i18n namespace)" {
  run bash "${UPGRADE_SH}" --help
  assert_success
  assert_output --partial "--lang"
}

@test "completions.sh --help advertises --lang (#655 i18n namespace)" {
  run bash "${COMPLETIONS_SH}" --help
  assert_success
  assert_output --partial "--lang"
}

@test "new.sh --help advertises --lang (#655 i18n namespace)" {
  run bash "${NEW_SH}" --help
  assert_success
  assert_output --partial "--lang"
}

@test "init.sh accepts a valid --lang without error (flag is stripped)" {
  run bash "${INIT_SH}" --lang zh-TW --help
  assert_success
  assert_output --partial "Usage:"
}

@test "upgrade.sh accepts a valid --lang without error" {
  run bash "${UPGRADE_SH}" --lang ja --help
  assert_success
  assert_output --partial "Usage:"
}

@test "completions.sh accepts a valid --lang without error" {
  SANDBOX="$(mktemp -d)"
  run env HOME="${SANDBOX}/home" XDG_DATA_HOME="${SANDBOX}/data" \
    bash "${COMPLETIONS_SH}" install --shell bash --lang zh-CN
  assert_success
  rm -rf "${SANDBOX}"
}

@test "new.sh accepts a valid --lang and still scaffolds" {
  SANDBOX="$(mktemp -d)"
  mkdir -p "${SANDBOX}/script/template/skel" "${SANDBOX}/script/local" \
           "${SANDBOX}/script/docker/lib"
  cp /source/dist/script/template/new.sh "${SANDBOX}/script/template/new.sh"
  cp /source/dist/script/template/skel/justfile.skel "${SANDBOX}/script/template/skel/justfile.skel"
  cp /source/dist/script/template/skel/skel.sh "${SANDBOX}/script/template/skel/skel.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${SANDBOX}/script/docker/lib/i18n.sh"
  chmod +x "${SANDBOX}/script/template/new.sh"
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh --lang zh-TW deploy"
  assert_success
  assert [ -f "${SANDBOX}/script/local/deploy/justfile.deploy" ]
  rm -rf "${SANDBOX}"
}

# ── --lang validation: unsupported value warns + falls back (non-fatal) ────────

@test "init.sh --lang bogus warns and falls back to en (non-fatal)" {
  run bash "${INIT_SH}" --lang bogus --help
  assert_success
  assert_output --partial "unsupported --lang value"
}

@test "completions.sh --lang bogus warns and falls back to en (non-fatal)" {
  SANDBOX="$(mktemp -d)"
  run env HOME="${SANDBOX}/home" XDG_DATA_HOME="${SANDBOX}/data" \
    bash "${COMPLETIONS_SH}" install --shell bash --lang bogus
  assert_success
  assert_output --partial "unsupported --lang value"
  rm -rf "${SANDBOX}"
}

# ── test namespace is English-only: --lang is NOT a recognised option ─────────

@test "test.sh rejects --lang (test namespace is English-only, #655)" {
  run bash "${TEST_SH}" --lang zh-TW
  assert_failure
  assert_output --partial "Unknown option"
}
