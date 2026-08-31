#!/usr/bin/env bats
#
# The `deploy` word means two unrelated things one keystroke apart.
#
#   ./setup.sh     deploy   builds a self-contained field-deploy bundle
#   ./setup_tui.sh deploy   opens the [deploy] section editor, which is GPU
#                           reservation only -- the section is named after
#                           Compose's `deploy:` key, not after deployment
#
# The section name follows Compose and is out of scope to rename, and the
# subcommand is the documented field-deploy entry point (ADR-00000023) with a
# preview + confirmation in front of it. What is fixable is the collision
# itself: the TUI editor gains `gpu` as its unambiguous primary spelling,
# `deploy` keeps working as an alias, and reaching the editor through the
# ambiguous word says which of the two things the user just got.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  export SETUP_LANG=en
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup_tui.sh
  TUI_SH="/source/dist/script/docker/wrapper/setup_tui.sh"
  SETUP_SH="/source/dist/script/docker/wrapper/setup.sh"
}

# ════════════════════════════════════════════════════════════════════
# `gpu`: the unambiguous name for the [deploy] section editor
# ════════════════════════════════════════════════════════════════════

@test "setup_tui accepts gpu as a subcommand (#879)" {
  run _tui_known_subcommand gpu
  assert_success
}

@test "setup_tui still accepts deploy as a subcommand (alias kept) (#879)" {
  run _tui_known_subcommand deploy
  assert_success
}

@test "gpu canonicalises to the deploy section editor (#879)" {
  run _tui_canonical_section gpu
  assert_success
  assert_output "deploy"
}

@test "a non-aliased section canonicalises to itself (#879)" {
  run _tui_canonical_section network
  assert_success
  assert_output "network"
}

@test "an unknown word is still rejected (#879)" {
  run _tui_known_subcommand nonsense
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Reaching the editor through the ambiguous word says which one it is
# ════════════════════════════════════════════════════════════════════

@test "the deploy spelling explains it is the GPU editor, not the bundle (#879)" {
  _tui_msgbox() { printf '%s\n%s\n' "${1}" "${2}"; }
  run _warn_if_deploy_word_ambiguous deploy
  assert_success
  assert_output --partial "GPU"
  assert_output --partial "setup.sh deploy"
  assert_output --partial "setup-tui gpu"
}

@test "the gpu spelling is silent -- the alias is the way out of the notice (#879)" {
  _tui_msgbox() { printf '%s\n%s\n' "${1}" "${2}"; }
  run _warn_if_deploy_word_ambiguous gpu
  assert_success
  assert_output ""
}

@test "no subcommand at all is silent (#879)" {
  _tui_msgbox() { printf '%s\n%s\n' "${1}" "${2}"; }
  run _warn_if_deploy_word_ambiguous ""
  assert_success
  assert_output ""
}

@test "the disambiguation notice is translated in all four locales (#879)" {
  local _lang _upper
  for _lang in EN ZH_TW ZH_CN JA; do
    _upper="_TUI_MSG_${_lang}"
    local -n _tbl="${_upper}"
    [[ -n "${_tbl[deploy.ambiguous.title]:-}" ]]
    [[ -n "${_tbl[deploy.ambiguous.body]:-}" ]]
    unset -n _tbl
  done
}

# ════════════════════════════════════════════════════════════════════
# Both usage screens name the distinction
# ════════════════════════════════════════════════════════════════════

@test "setup_tui --help lists gpu and denies the field-bundle reading (#879)" {
  run bash "${TUI_SH}" --help
  assert_success
  assert_output --partial "gpu"
  assert_output --partial "./setup.sh deploy"
}

@test "setup_tui --help names the distinction in all four locales (#879)" {
  local _lang
  for _lang in en zh-TW zh-CN ja; do
    run bash "${TUI_SH}" --help --lang "${_lang}"
    assert_success
    assert_output --partial "gpu"
    assert_output --partial "./setup.sh deploy"
  done
}

@test "setup.sh --help distinguishes the deploy subcommand from the section (#879)" {
  run bash "${SETUP_SH}" --help
  assert_success
  assert_output --partial "NOT the [deploy] section of setup.conf"
}
