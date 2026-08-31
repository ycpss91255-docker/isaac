#!/usr/bin/env bats
#
# Behavioural tests for dist/deploy/cd-guard.sh -- the shipped, consumer-facing
# CD pre-deploy gate (ADR-00000023). The guard has four outcomes and every one
# of them is a REFUSAL policy, so each is asserted on BOTH axes: the exit status
# an automated CD pipeline branches on, AND the specific reason it prints. A
# status-only assertion would pass with the conditions inverted (dirty tree
# reported as "not on a tag" and vice versa), so the message is what pins each
# branch to its own condition.
#
# Pure git + filesystem, no docker: Unit level (ADR-00000018).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # The shipped artifact under test, at its real path so kcov attributes the
  # coverage to it.
  _CD_GUARD=/source/dist/deploy/cd-guard.sh

  TEMP_DIR="$(mktemp -d)"

  # Deterministic identity + branch name so the fixtures do not depend on the
  # container's git config (CI images ship none, and `git commit` refuses
  # without an author).
  export GIT_AUTHOR_NAME=cd-guard-spec
  export GIT_AUTHOR_EMAIL=cd-guard-spec@example.invalid
  export GIT_COMMITTER_NAME="${GIT_AUTHOR_NAME}"
  export GIT_COMMITTER_EMAIL="${GIT_AUTHOR_EMAIL}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── fixtures ────────────────────────────────────────────────────────────────

# _fixture_non_repo <out_var>
#
# A plain directory with no git metadata anywhere above it. mktemp roots at
# /tmp, which is never inside a work tree, so `git rev-parse --show-toplevel`
# genuinely fails here rather than resolving to an enclosing repo.
_fixture_non_repo() {
  local -n _out="${1}"
  _out="${TEMP_DIR}/non-repo"
  mkdir -p "${_out}"
}

# _fixture_repo <out_var> [--tag <name>] [--dirty]
#
# An initialised repo with one commit; optionally tagged, optionally left with
# an uncommitted file so `git status --porcelain` is non-empty.
_fixture_repo() {
  local -n _out="${1}"; shift
  local _tag="" _dirty=false
  while (( $# > 0 )); do
    case "${1}" in
      --tag)   _tag="${2}"; shift 2 ;;
      --dirty) _dirty=true; shift ;;
      *)       printf '_fixture_repo: unknown arg %s\n' "${1}" >&2; return 2 ;;
    esac
  done

  _out="${TEMP_DIR}/repo-${RANDOM}"
  mkdir -p "${_out}"
  git -C "${_out}" init -q
  printf 'seed\n' > "${_out}/README"
  git -C "${_out}" add README
  git -C "${_out}" commit -qm 'seed'
  [[ -n "${_tag}" ]] && git -C "${_out}" tag "${_tag}"
  [[ "${_dirty}" == true ]] && printf 'uncommitted\n' > "${_out}/scratch"
  return 0
}

# _run_guard <dir> -- invoke the shipped guard with <dir> as cwd.
_run_guard() {
  run bash -c "cd '${1}' && '${_CD_GUARD}'"
}

# ── delivery contract ───────────────────────────────────────────────────────

@test "cd-guard: ships executable, so the documented ./.base/... invocation works" {
  # Every test below invokes the guard the way its own usage block and the
  # READMEs tell operators to -- as a program, not as `bash <path>` -- so the
  # mode bit is part of the shipped contract, not incidental. Asserted
  # separately as well, because a lost +x otherwise surfaces as six identical
  # 'status 126' failures with no named cause.
  assert [ -x "${_CD_GUARD}" ]
}

# ── outcome 1: not a git repository ─────────────────────────────────────────

@test "cd-guard: refuses outside a git repository (exit 1 + 'not inside a git repository')" {
  local _d; _fixture_non_repo _d
  _run_guard "${_d}"
  assert_failure 1
  assert_output --partial 'not inside a git repository'
  refute_output --partial 'ok to deploy'
}

# ── outcome 2: dirty working tree ───────────────────────────────────────────

@test "cd-guard: refuses a dirty tree even when HEAD is on a tag (exit 1 + 'working tree is dirty')" {
  # Tagged AND dirty: the tag check would pass, so this pins the refusal to the
  # porcelain test specifically. Dropping the dirty branch would let this
  # fixture through as 'ok to deploy'.
  local _d; _fixture_repo _d --tag v1.0.0 --dirty
  _run_guard "${_d}"
  assert_failure 1
  assert_output --partial 'working tree is dirty'
  refute_output --partial 'ok to deploy'
}

# ── outcome 3: HEAD not on a tag ────────────────────────────────────────────

@test "cd-guard: refuses an untagged HEAD on a clean tree (exit 1 + 'HEAD is not on a tag')" {
  # Clean AND untagged: the dirty check passes, so this pins the refusal to the
  # `git describe --exact-match` test. An inverted `if !` would report success.
  local _d; _fixture_repo _d
  _run_guard "${_d}"
  assert_failure 1
  assert_output --partial 'HEAD is not on a tag'
  refute_output --partial 'ok to deploy'
}

@test "cd-guard: a tag that does not point at HEAD is still an untagged HEAD" {
  # `git describe --tags` alone (without --exact-match) resolves to the nearest
  # reachable tag, so a repo with ANY tag in its history would pass. Only the
  # exact-match form refuses here.
  local _d; _fixture_repo _d --tag v1.0.0
  printf 'second\n' > "${_d}/second"
  git -C "${_d}" add second
  git -C "${_d}" commit -qm 'past the tag'
  _run_guard "${_d}"
  assert_failure 1
  assert_output --partial 'HEAD is not on a tag'
}

# ── outcome 4: clean tree on a tag ──────────────────────────────────────────

@test "cd-guard: accepts a clean tree on a tag (exit 0 + names the tag)" {
  local _d; _fixture_repo _d --tag v1.2.3
  _run_guard "${_d}"
  assert_success
  assert_output --partial 'clean tree on tag v1.2.3'
  assert_output --partial 'ok to deploy'
}

@test "cd-guard: the accept path reports the tag on stdout, refusals on stderr" {
  # CD pipelines tee stderr to the failure surface; asserting the split keeps a
  # refusal reason from being swallowed as ordinary progress output.
  local _ok _bad
  _fixture_repo _ok --tag v9.9.9
  _fixture_repo _bad

  run bash -c "cd '${_ok}' && '${_CD_GUARD}' 2>/dev/null"
  assert_success
  assert_output --partial 'ok to deploy'

  run bash -c "cd '${_bad}' && '${_CD_GUARD}' 2>/dev/null"
  assert_failure 1
  assert_output ''
}
