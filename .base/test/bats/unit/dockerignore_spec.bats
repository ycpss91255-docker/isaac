#!/usr/bin/env bats
#
# Unit tests for the .dockerignore canonical-sync helpers in
# .base/dist/script/docker/lib/gitignore.sh.
#
# Mirrors the .gitignore canonical-sync pattern: downstream repos
# accumulate derived artifacts (.env / compose.yaml / coverage/ ...) that
# should not be shipped in the Docker build context any more than they
# should be committed. base had no .dockerignore sync at all (the file
# existed only at base's own root, hand-maintained). These helpers give a
# single source of truth + an append-missing sync wired into init.sh.
#
# The derived-artifact set is shared with _canonical_gitignore_entries
# (anything not worth committing is not worth shipping in the build
# context), so the two never drift; per-repo build-context specifics
# (script/ test/ config/, .git, docs) stay hand-maintained above the
# managed block and are never touched by the sync.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf_logging.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/gitignore.sh
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _canonical_dockerignore_entries
# ════════════════════════════════════════════════════════════════════

@test "_canonical_dockerignore_entries: emits the derived-artifact set (#604)" {
  run _canonical_dockerignore_entries
  assert_success
  assert_line ".env"
  assert_line ".env.generated"
  assert_line ".env.bak"
  assert_line "compose.yaml"
  assert_line ".setup.conf.bak"
  # .setup.conf.local rides the shared list on purpose: the per-worktree
  # override is untracked machine-local config, and letting it into a build
  # context is exactly how an unversioned value would end up baked into an
  # image (PRD invariant 8's dev/field split).
  assert_line ".setup.conf.local"
  assert_line "coverage/"
  assert_line ".Dockerfile.generated"
  assert_line ".docker.xauth"
}

@test "_canonical_dockerignore_entries: shares the single canonical source with gitignore (no drift) (#604)" {
  # Derived artifacts excluded from the build context are exactly those
  # excluded from git; locking equality keeps the two from diverging.
  assert_equal "$(_canonical_dockerignore_entries)" "$(_canonical_gitignore_entries)"
}

@test "_canonical_dockerignore_entries: list is stable order (#604)" {
  assert_equal "$(_canonical_dockerignore_entries)" "$(_canonical_dockerignore_entries)"
}

@test "_canonical_dockerignore_entries: includes log/ via the shared canonical source (#606) (#604)" {
  # reserved log/ for; added it to _canonical_gitignore_entries
  # and it propagates here through the shared source (proving the delegation).
  run _canonical_dockerignore_entries
  assert_line "log/"
}

# ════════════════════════════════════════════════════════════════════
# _sync_dockerignore
# ════════════════════════════════════════════════════════════════════

@test "_sync_dockerignore: creates the file when missing, with marker + all entries (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  run _sync_dockerignore "${_f}"
  assert_success
  [[ -f "${_f}" ]]
  run cat "${_f}"
  assert_line --partial "managed by template"
  assert_line ".env"
  assert_line "compose.yaml"
  assert_line "coverage/"
}

@test "_sync_dockerignore: file with all entries already present is a no-op (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  _canonical_dockerignore_entries > "${_f}"
  local _before
  _before="$(cat "${_f}")"
  run _sync_dockerignore "${_f}"
  assert_success
  assert_equal "$(cat "${_f}")" "${_before}"
}

@test "_sync_dockerignore: appends only missing entries when subset present (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  printf '%s\n' '.env' 'script/' > "${_f}"
  run _sync_dockerignore "${_f}"
  assert_success
  run grep -c '^\.env$' "${_f}"
  assert_output "1"
  run grep -c '^script/$' "${_f}"
  assert_output "1"
  run grep -c '^compose\.yaml$' "${_f}"
  assert_output "1"
}

@test "_sync_dockerignore: preserves hand-maintained build-context lines (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  printf '%s\n' 'script/' 'test/' 'config/' '.git' > "${_f}"
  run _sync_dockerignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line "script/"
  assert_line "test/"
  assert_line "config/"
  assert_line ".git"
}

@test "_sync_dockerignore: idempotent — second run leaves the file unchanged (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  printf '%s\n' '.env' > "${_f}"
  _sync_dockerignore "${_f}"
  local _a
  _a="$(cat "${_f}")"
  _sync_dockerignore "${_f}"
  assert_equal "$(cat "${_f}")" "${_a}"
}

@test "_sync_dockerignore: marker added only once across re-syncs (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  _sync_dockerignore "${_f}"
  _sync_dockerignore "${_f}"
  run grep -c 'managed by template' "${_f}"
  assert_output "1"
}

@test "_sync_dockerignore: file without trailing newline gets one before append (#604)" {
  local _f="${TMP_DIR}/.dockerignore"
  printf 'script/' > "${_f}"
  _sync_dockerignore "${_f}"
  run grep -xF 'script/' "${_f}"
  assert_success
  run grep -xF '.env' "${_f}"
  assert_success
}
