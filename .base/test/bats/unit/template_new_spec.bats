#!/usr/bin/env bats
#
# Unit tests for the repo-local command-group scaffolder
# dist/script/template/new.sh (ADR-00000010). Runs new.sh
# directly (no `just` needed): it creates script/local/<name>/justfile.<name>
# + <name>.sh from skel/ and registers the group in
# script/local/justfile.local.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  # Mirror the shipped template tree so new.sh resolves skel/ relative to
  # itself, then run it with the sandbox as cwd (the [no-cd] recipe's cwd
  # is the repo root in production).
  mkdir -p "${SANDBOX}/script/template/skel" "${SANDBOX}/script/local" \
           "${SANDBOX}/script/docker/lib"
  cp /source/dist/script/template/new.sh "${SANDBOX}/script/template/new.sh"
  cp /source/dist/script/template/skel/justfile.skel "${SANDBOX}/script/template/skel/justfile.skel"
  cp /source/dist/script/template/skel/skel.sh "${SANDBOX}/script/template/skel/skel.sh"
  # new.sh sources ../docker/lib/i18n.sh for --lang; mirror it so the
  # source resolves relative to the copied new.sh.
  cp /source/dist/script/docker/lib/i18n.sh "${SANDBOX}/script/docker/lib/i18n.sh"
  chmod +x "${SANDBOX}/script/template/new.sh"
}

teardown() {
  if [[ -n "${SANDBOX:-}" ]]; then
    rm -rf "${SANDBOX}"
  fi
}

@test "new.sh scaffolds script/local/<name>/{justfile.<name>,<name>.sh} from skel" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  assert [ -f "${SANDBOX}/script/local/deploy/justfile.deploy" ]
  assert [ -f "${SANDBOX}/script/local/deploy/deploy.sh" ]
  assert [ -x "${SANDBOX}/script/local/deploy/deploy.sh" ]
}

@test "new.sh substitutes __NAME__ in the scaffolded files" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  run grep -F '__NAME__' "${SANDBOX}/script/local/deploy/justfile.deploy" "${SANDBOX}/script/local/deploy/deploy.sh"
  assert_failure
  run grep -F 'deploy' "${SANDBOX}/script/local/deploy/deploy.sh"
  assert_success
}

@test "new.sh registers the group in script/local/justfile.local (mod? line)" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  run grep -F "mod? deploy 'deploy/justfile.deploy'" "${SANDBOX}/script/local/justfile.local"
  assert_success
}

@test "new.sh refuses to clobber an existing group" {
  bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_failure
  assert_output --partial "already exists"
}

@test "new.sh does not duplicate the registry line on a second distinct group" {
  bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh backup"
  assert_success
  run grep -c '^mod? ' "${SANDBOX}/script/local/justfile.local"
  assert_output "2"
}

@test "new.sh rejects an invalid group name" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh 'Bad Name'"
  assert_failure
  assert_output --partial "invalid group name"
}

@test "new.sh errors with usage when no name given" {
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh"
  assert_failure
  assert_output --partial "usage"
}

@test "new.sh registers a real mod? line even when the seed registry only COMMENTS that name (#785)" {
  # Regression: init.sh seeds script/local/justfile.local with a
  # COMMENTED example `#   mod? deploy 'deploy/justfile.deploy'`. The
  # idempotency guard used `grep -qF` (substring), which matched that
  # comment line, so `just template new deploy` -- the literal documented
  # example name -- reported "already registered" and appended NO real
  # mod? line, leaving `just deploy` undispatchable. The guard must match
  # a whole real registration line, not a commented example.
  mkdir -p "${SANDBOX}/script/local"
  cat > "${SANDBOX}/script/local/justfile.local" <<'REG'
# Repo-local just command groups (registry).
#
#   mod? deploy 'deploy/justfile.deploy'
#
# then `just deploy <recipe>` runs it.
REG
  run bash -c "cd '${SANDBOX}' && ./script/template/new.sh deploy"
  assert_success
  # A real (line-start, non-commented) registration line must now exist.
  run grep -Ec "^mod\\? deploy 'deploy/justfile.deploy'\$" "${SANDBOX}/script/local/justfile.local"
  assert_output "1"
}

@test "new.sh source ships with the executable bit set (recipe invokes it directly) (#785)" {
  # Regression: the `template new` recipe runs
  # `script/template/new.sh {{name}}` DIRECTLY (not `bash script/...`), so
  # the shipped script must carry the executable bit. It was tracked 100644
  # and `just template new` failed with exit 126 (Permission denied) in
  # every real consumer; the unit sandbox masked it by chmod +x on copy.
  assert [ -x "/source/dist/script/template/new.sh" ]
}
