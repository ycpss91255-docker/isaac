#!/usr/bin/env bats
#
# Unit tests for template/script/docker/lib/gitignore.sh.
#
# Issue #172: init.sh / upgrade.sh need to sync a canonical .gitignore set
# (.env, .env.bak, compose.yaml, setup.conf.bak, coverage/,
# .Dockerfile.generated). The lib has three responsibilities:
#   1. Emit the canonical list (single source of truth).
#   2. Append-missing into a target .gitignore, idempotent, preserving
#      user-defined lines.
#   3. `git rm --cached` any canonical entry that's still tracked in the
#      repo (so 15 downstream repos that mis-track compose.yaml get
#      healed by the next batch-upgrade).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/script/docker/lib/gitignore.sh

  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _canonical_gitignore_entries
# ════════════════════════════════════════════════════════════════════

@test "_canonical_gitignore_entries: emits exactly the 7 canonical lines" {
  run _canonical_gitignore_entries
  assert_success
  assert_output - <<'EXPECTED'
.env
.env.bak
compose.yaml
setup.conf.bak
setup.conf.local
coverage/
.Dockerfile.generated
EXPECTED
}

@test "_canonical_gitignore_entries: list is stable order" {
  # Two calls must produce byte-identical output (consumers may diff).
  local _a _b
  _a="$(_canonical_gitignore_entries)"
  _b="$(_canonical_gitignore_entries)"
  assert_equal "${_a}" "${_b}"
}

# ════════════════════════════════════════════════════════════════════
# _sync_gitignore
# ════════════════════════════════════════════════════════════════════

@test "_sync_gitignore: creates the file when missing, with marker block + all entries" {
  local _f="${TMP_DIR}/.gitignore"
  run _sync_gitignore "${_f}"
  assert_success
  [[ -f "${_f}" ]]
  run cat "${_f}"
  assert_line --partial "managed by template"
  assert_line ".env"
  assert_line ".env.bak"
  assert_line "compose.yaml"
  assert_line "setup.conf.bak"
  assert_line "coverage/"
  assert_line ".Dockerfile.generated"
}

@test "_sync_gitignore: empty file gets marker block + all entries appended" {
  local _f="${TMP_DIR}/.gitignore"
  : > "${_f}"
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line --partial "managed by template"
  assert_line ".env"
  assert_line "compose.yaml"
}

@test "_sync_gitignore: file with all entries already present is a no-op" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
.env.bak
compose.yaml
setup.conf.bak
setup.conf.local
coverage/
.Dockerfile.generated
EOF
  local _before
  _before="$(cat "${_f}")"
  run _sync_gitignore "${_f}"
  assert_success
  local _after
  _after="$(cat "${_f}")"
  assert_equal "${_after}" "${_before}"
}

@test "_sync_gitignore: appends only missing entries when subset already present" {
  local _f="${TMP_DIR}/.gitignore"
  # Pre-existing partial set (the 15-repo state at the time #172 was filed)
  cat > "${_f}" <<'EOF'
.env
.claude/
EOF
  run _sync_gitignore "${_f}"
  assert_success
  # User entry preserved
  run grep -c '^\.claude/$' "${_f}"
  assert_output "1"
  # Existing canonical preserved (no duplicate)
  run grep -c '^\.env$' "${_f}"
  assert_output "1"
  # Missing canonical appended
  run grep -c '^compose\.yaml$' "${_f}"
  assert_output "1"
  run grep -c '^\.env\.bak$' "${_f}"
  assert_output "1"
  run grep -c '^coverage/$' "${_f}"
  assert_output "1"
}

@test "_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
.env.gpg
data/
bridge.yaml
.claude/
EOF
  run _sync_gitignore "${_f}"
  assert_success
  run cat "${_f}"
  assert_line ".env.gpg"
  assert_line "data/"
  assert_line "bridge.yaml"
  assert_line ".claude/"
}

@test "_sync_gitignore: idempotent — second invocation produces no further changes" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
.env
EOF
  _sync_gitignore "${_f}"
  local _after_first
  _after_first="$(cat "${_f}")"
  _sync_gitignore "${_f}"
  local _after_second
  _after_second="$(cat "${_f}")"
  assert_equal "${_after_second}" "${_after_first}"
}

@test "_sync_gitignore: no duplicate canonical lines after re-run" {
  local _f="${TMP_DIR}/.gitignore"
  cat > "${_f}" <<'EOF'
compose.yaml
EOF
  _sync_gitignore "${_f}"
  _sync_gitignore "${_f}"
  run grep -c '^compose\.yaml$' "${_f}"
  assert_output "1"
}

@test "_sync_gitignore: ends with newline so future appends start on their own line" {
  local _f="${TMP_DIR}/.gitignore"
  printf 'something' > "${_f}"   # NO trailing newline
  _sync_gitignore "${_f}"
  # Last byte must be a newline
  local _last
  _last="$(tail -c 1 "${_f}" | od -An -c | tr -d ' ')"
  assert_equal "${_last}" '\n'
}

# ════════════════════════════════════════════════════════════════════
# _untrack_canonical_in_repo
# ════════════════════════════════════════════════════════════════════

_init_repo_with_tracked() {
  local _repo="$1"; shift
  git -C "${_repo}" init -q -b main
  git -C "${_repo}" config user.email t@t
  git -C "${_repo}" config user.name t
  local _f
  for _f in "$@"; do
    case "${_f}" in
      */) mkdir -p "${_repo}/${_f}"; : > "${_repo}/${_f}placeholder" ;;
      *)  : > "${_repo}/${_f}" ;;
    esac
  done
  git -C "${_repo}" add -A
  git -C "${_repo}" commit -q -m "init" || true
}

@test "_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  # File still on disk
  [[ -f "${TMP_DIR}/compose.yaml" ]]
  # No longer in index
  run git -C "${TMP_DIR}" ls-files compose.yaml
  assert_output ""
}

@test "_untrack_canonical_in_repo: leaves untracked files alone" {
  git -C "${TMP_DIR}" init -q -b main
  git -C "${TMP_DIR}" config user.email t@t
  git -C "${TMP_DIR}" config user.name t
  : > "${TMP_DIR}/README"
  git -C "${TMP_DIR}" add -A
  git -C "${TMP_DIR}" commit -q -m "init"
  : > "${TMP_DIR}/compose.yaml"   # exists but never committed
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  [[ -f "${TMP_DIR}/compose.yaml" ]]
}

@test "_untrack_canonical_in_repo: no-op when no canonical files tracked" {
  _init_repo_with_tracked "${TMP_DIR}" README.md
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  # README still tracked
  run git -C "${TMP_DIR}" ls-files README.md
  assert_output "README.md"
}

@test "_untrack_canonical_in_repo: handles tracked coverage/ directory" {
  _init_repo_with_tracked "${TMP_DIR}" coverage/
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  [[ -d "${TMP_DIR}/coverage" ]]
  run git -C "${TMP_DIR}" ls-files coverage/
  assert_output ""
}

@test "_untrack_canonical_in_repo: idempotent — second run succeeds without error" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml .env
  _untrack_canonical_in_repo "${TMP_DIR}"
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
}

@test "_untrack_canonical_in_repo: untracks all canonical entries that match" {
  _init_repo_with_tracked "${TMP_DIR}" compose.yaml .env .env.bak setup.conf.bak
  run _untrack_canonical_in_repo "${TMP_DIR}"
  assert_success
  run git -C "${TMP_DIR}" ls-files compose.yaml .env .env.bak setup.conf.bak
  assert_output ""
}
