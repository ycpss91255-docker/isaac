#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/lib/template_guard.sh
# (_assert_not_template_source) -- the init/upgrade self-run guard.
#
# init.sh / upgrade.sh self-locate the subtree root by walking up to the
# dir carrying `.version` + `dist/` (ADR-00000011 sec.8). A real `.base/`
# subtree never carries `.git` (the consumer's `.git` lives at the repo
# root, not inside the subtree). The standalone base checkout / worktree,
# by contrast, has `.git` AT the subtree root -- so `.git` at the resolved
# root means "this is the base template source itself", and running init /
# upgrade there would scaffold / subtree-pull into base's PARENT dir. The
# guard refuses that.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
  LIB="/source/dist/script/docker/lib/_lib.sh"
  GUARD="/source/dist/script/docker/lib/template_guard.sh"
}

@test "_assert_not_template_source: refuses when the subtree root carries .git (base self)" {
  local root
  root="$(mktemp -d)"
  mkdir -p "${root}/.git"
  run bash -c "source '${LIB}'; source '${GUARD}'; _assert_not_template_source '${root}'"
  rm -rf "${root}"
  assert_failure
  assert_output --partial "template source"
}

@test "_assert_not_template_source: passes when the subtree root has no .git (vendored subtree)" {
  local root
  root="$(mktemp -d)"
  # a real .base/ subtree carries .version + dist/ but never .git
  echo "v0.0.0-test" > "${root}/.version"
  mkdir -p "${root}/dist"
  run bash -c "source '${LIB}'; source '${GUARD}'; _assert_not_template_source '${root}'"
  rm -rf "${root}"
  assert_success
  refute_output --partial "template source"
}
