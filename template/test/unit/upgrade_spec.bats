#!/usr/bin/env bats
#
# Unit tests for upgrade.sh, focused on _warn_config_drift — the
# helper that tells the user when the upstream template/config/ tree
# moved during a subtree pull so they can reconcile their per-repo
# <repo>/config/ copy.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  UPGRADE="/source/upgrade.sh"

  # Build a self-contained test harness: a shell script that redefines
  # `_log` / `_error` (avoids pulling in upgrade.sh's top-level `cd
  # REPO_ROOT`) and extracts helpers from upgrade.sh by sed range so
  # tests exercise the real function bodies, not copies.
  TEMP_DIR="$(mktemp -d)"
  HARNESS="${TEMP_DIR}/harness.sh"
  cat > "${HARNESS}" <<'EOS'
_log() { printf '[upgrade] %s\n' "$*"; }
_error() { printf '[upgrade] ERROR: %s\n' "$*" >&2; exit 1; }
EOS
  sed -n '/^_warn_config_drift() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_git_identity() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_clean_merge_state() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_verify_subtree_intact() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_semver_cmp() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_check() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_get_latest_version() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── _warn_config_drift logic ────────────────────────────────────────────────

@test "_warn_config_drift silent when no template/config in HEAD" {
  local _git_dir="${TEMP_DIR}/empty"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift ''"
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift silent when pre and post hashes match" {
  local _git_dir="${TEMP_DIR}/same"
  mkdir -p "${_git_dir}/template/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "one" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _pre=\$(git rev-parse HEAD:template/config)
    _warn_config_drift \"\${_pre}\"
  "
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift prints WARNING + diff hint when hashes differ" {
  local _git_dir="${TEMP_DIR}/drift"
  mkdir -p "${_git_dir}/template/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "original" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD:template/config)"

  echo "updated" > "${_git_dir}/template/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c2

  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift '${_pre}'"
  assert_success
  assert_output --partial "WARNING: template/config/ changed"
  assert_output --partial "diff -ruN template/config config"
  assert_output --partial "git diff ${_pre:0:12}"
}

# ── upgrade.sh structural invariants ────────────────────────────────────────

@test "upgrade.sh defines _warn_config_drift" {
  run grep -F '_warn_config_drift()' "${UPGRADE}"
  assert_success
}

@test "upgrade.sh invokes _warn_config_drift after subtree pull" {
  # The helper existing without a call site is a bug; count references
  # so a refactor that drops the invocation trips this test.
  local _n
  _n="$(grep -Fc '_warn_config_drift' "${UPGRADE}")"
  (( _n >= 2 ))
}

@test "upgrade.sh captures pre-pull template/config tree hash" {
  # The WARNING only fires when we have both pre and post hashes —
  # guard against dropping the snapshot line.
  run grep -F 'HEAD:template/config' "${UPGRADE}"
  assert_success
}

# ── _require_git_identity ───────────────────────────────────────────────────

@test "_require_git_identity succeeds when name + email are set" {
  local _git_dir="${TEMP_DIR}/ident_ok"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.name "t"
  git -C "${_git_dir}" config user.email "t@t"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_git_identity"
  assert_success
}

@test "_require_git_identity fails when user.email is unset" {
  local _git_dir="${TEMP_DIR}/ident_noemail"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.name "t"
  # GIT_CONFIG_GLOBAL=/dev/null + HOME= isolates from inherited identity
  run bash -c "
    cd '${_git_dir}'
    export HOME='${TEMP_DIR}/ident_noemail' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    source '${HARNESS}'
    _require_git_identity
  "
  assert_failure
  assert_output --partial "git identity not configured"
}

@test "_require_git_identity fails when user.name is unset" {
  local _git_dir="${TEMP_DIR}/ident_noname"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  git -C "${_git_dir}" config user.email "t@t"
  run bash -c "
    cd '${_git_dir}'
    export HOME='${TEMP_DIR}/ident_noname' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    source '${HARNESS}'
    _require_git_identity
  "
  assert_failure
  assert_output --partial "git identity not configured"
}

# ── _require_clean_merge_state ──────────────────────────────────────────────

@test "_require_clean_merge_state succeeds in clean repo" {
  local _git_dir="${TEMP_DIR}/clean"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_success
}

@test "_require_clean_merge_state fails when MERGE_HEAD exists" {
  local _git_dir="${TEMP_DIR}/midmerge"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  touch "${_git_dir}/.git/MERGE_HEAD"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_failure
  assert_output --partial "MERGE_HEAD present"
}

@test "_require_clean_merge_state fails when rebase-merge dir exists" {
  local _git_dir="${TEMP_DIR}/midrebase"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  mkdir -p "${_git_dir}/.git/rebase-merge"
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _require_clean_merge_state"
  assert_failure
  assert_output --partial "rebase-merge present"
}

# ── _verify_subtree_intact ──────────────────────────────────────────────────

# Helper: build a minimal repo resembling a subtree consumer, then
# return its _pre_head so the test can call _verify_subtree_intact.
_mk_subtree_repo() {
  local _dir="$1"
  mkdir -p "${_dir}/template/script/docker"
  echo "v0.9.5" > "${_dir}/template/.version"
  echo "#!/usr/bin/env bash" > "${_dir}/template/init.sh"
  echo "#!/usr/bin/env bash" > "${_dir}/template/script/docker/setup.sh"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
  git -C "${_dir}" add -A
  git -C "${_dir}" commit -q -m "initial"
}

@test "_verify_subtree_intact succeeds when all markers present" {
  local _git_dir="${TEMP_DIR}/intact_ok"
  _mk_subtree_repo "${_git_dir}"
  run bash -c "
    cd '${_git_dir}'
    _pre=\$(git rev-parse HEAD)
    source '${HARNESS}'
    _verify_subtree_intact \"\${_pre}\"
  "
  assert_success
}

@test "_verify_subtree_intact rolls back when template/.version is missing" {
  local _git_dir="${TEMP_DIR}/intact_noversion"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  # Simulate the destructive FF: template/* moved up, template/.version gone.
  rm "${_git_dir}/template/.version"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}'
  "
  assert_failure
  assert_output --partial "integrity check failed"
  assert_output --partial "template/.version"
  # Post-condition: marker is restored by the rollback `git reset --hard`.
  [ -f "${_git_dir}/template/.version" ]
}

@test "_verify_subtree_intact rolls back when template/script/docker/setup.sh is missing" {
  local _git_dir="${TEMP_DIR}/intact_nosetup"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  rm "${_git_dir}/template/script/docker/setup.sh"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}'
  "
  assert_failure
  assert_output --partial "template/script/docker/setup.sh"
  [ -f "${_git_dir}/template/script/docker/setup.sh" ]
}

# ── upgrade.sh structural invariants (safety guards) ───────────────────────

@test "upgrade.sh calls _require_git_identity before subtree pull" {
  # Confirm both that the helper is called AND the ordering is correct.
  local _id_line _pull_line
  _id_line="$(grep -n '_require_git_identity$' "${UPGRADE}" | tail -1 | cut -d: -f1)"
  _pull_line="$(grep -n 'git subtree pull' "${UPGRADE}" | head -1 | cut -d: -f1)"
  [ -n "${_id_line}" ]
  [ -n "${_pull_line}" ]
  (( _id_line < _pull_line ))
}

@test "upgrade.sh calls _verify_subtree_intact after subtree pull" {
  local _pull_line _verify_line
  _pull_line="$(grep -n 'git subtree pull' "${UPGRADE}" | head -1 | cut -d: -f1)"
  _verify_line="$(grep -n '_verify_subtree_intact "\${_pre_head}"' "${UPGRADE}" | head -1 | cut -d: -f1)"
  [ -n "${_pull_line}" ]
  [ -n "${_verify_line}" ]
  (( _verify_line > _pull_line ))
}

@test "upgrade.sh snapshots pre-pull HEAD for rollback" {
  run grep -F 'git rev-parse HEAD' "${UPGRADE}"
  assert_success
}

# ── _semver_cmp (SemVer §11 ordering) ───────────────────────────────────────
#
# SemVer §11 says a pre-release version has LOWER precedence than the
# associated normal version (rc1 < final). GNU `sort -V` sorts the
# other way (final < rc1, treating `-` as "less than empty"), which is
# why upgrade.sh needs its own comparator: the wrong ordering causes
# `make upgrade-check` to mis-classify v0.12.0-rc1 vs released v0.12.0
# once the stable tag exists.
#
# Returns: 0 = equal, 1 = a < b, 2 = a > b.

@test "_semver_cmp: equal versions return 0" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.11.0 v0.11.0; echo \$?"
  assert_success
  assert_output "0"
}

@test "_semver_cmp: lower core returns 1" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.11.0 v0.12.0; echo \$?"
  assert_success
  assert_output "1"
}

@test "_semver_cmp: higher core returns 2" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0 v0.11.0; echo \$?"
  assert_success
  assert_output "2"
}

@test "_semver_cmp: pre-release < final at same core (rc1 < 0.12.0)" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0-rc1 v0.12.0; echo \$?"
  assert_success
  assert_output "1"
}

@test "_semver_cmp: final > pre-release at same core (0.12.0 > rc1)" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0 v0.12.0-rc1; echo \$?"
  assert_success
  assert_output "2"
}

@test "_semver_cmp: rc1 < rc2 (lex pre-release ordering)" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0-rc1 v0.12.0-rc2; echo \$?"
  assert_success
  assert_output "1"
}

@test "_semver_cmp: rc2 > rc1" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0-rc2 v0.12.0-rc1; echo \$?"
  assert_success
  assert_output "2"
}

@test "_semver_cmp: pre-release of newer beats older final (0.12.0-rc1 > 0.11.0)" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.12.0-rc1 v0.11.0; echo \$?"
  assert_success
  assert_output "2"
}

@test "_semver_cmp: older final < pre-release of newer (0.11.0 < 0.12.0-rc1)" {
  run bash -c "source '${HARNESS}'; _semver_cmp v0.11.0 v0.12.0-rc1; echo \$?"
  assert_success
  assert_output "1"
}

# ── _check (semver-aware) ────────────────────────────────────────────────────
#
# _check exits 0 when there's nothing to do (already current, or local
# is ahead of latest stable — typical for prerelease testers) and 1
# only when a real upgrade is available. This is the regression at the
# heart of issue #156: previously _check used `==` and reported any
# mismatch (including "running rc1, latest stable is older v0.11.0")
# as "needing downgrade" with exit 1.

@test "_check: equal versions report up-to-date and exit 0" {
  run bash -c "
    source '${HARNESS}'
    _get_local_version()  { echo v0.12.0; }
    _get_latest_version() { echo v0.12.0; }
    _check
  "
  assert_success
  assert_output --partial "Local:  v0.12.0"
  assert_output --partial "Latest: v0.12.0"
  assert_output --partial "Already up to date"
}

@test "_check: behind latest reports update available and exits 1" {
  run bash -c "
    source '${HARNESS}'
    _get_local_version()  { echo v0.11.0; }
    _get_latest_version() { echo v0.12.0; }
    _check
  "
  assert_failure
  assert_output --partial "Update available: v0.11.0 →v0.12.0"
}

@test "_check: prerelease ahead of latest stable exits 0 (issue #156 case)" {
  # Scenario from issue #156: user's downstream pinned to v0.12.0-rc1
  # while the org's latest stable tag is still v0.11.0. _check should
  # NOT advise a downgrade — it should say the local is ahead.
  run bash -c "
    source '${HARNESS}'
    _get_local_version()  { echo v0.12.0-rc1; }
    _get_latest_version() { echo v0.11.0; }
    _check
  "
  assert_success
  assert_output --partial "Local:  v0.12.0-rc1"
  assert_output --partial "Latest: v0.11.0"
  assert_output --partial "ahead"
  refute_output --partial "Update available"
}

@test "_check: stable later than latest stable exits 0 (defensive)" {
  # If local was hand-tagged to a future version not yet on the remote
  # (e.g. local-only release, or stale ls-remote), don't propose a
  # downgrade.
  run bash -c "
    source '${HARNESS}'
    _get_local_version()  { echo v0.13.0; }
    _get_latest_version() { echo v0.12.0; }
    _check
  "
  assert_success
  assert_output --partial "ahead"
}

@test "_check: prerelease behind latest stable proposes upgrade (rc1 →0.12.0)" {
  # Once v0.12.0 is published, a downstream still on v0.12.0-rc1
  # should be told to leave the prerelease and move to stable.
  run bash -c "
    source '${HARNESS}'
    _get_local_version()  { echo v0.12.0-rc1; }
    _get_latest_version() { echo v0.12.0; }
    _check
  "
  assert_failure
  assert_output --partial "Update available: v0.12.0-rc1 →v0.12.0"
}

# ── _get_latest_version: errexit / pipefail safety ──────────────────────────
#
# Bash 5.3 (alpine 3.23 — the test-tools image runner from #168)
# propagates non-zero command-substitution exits through the caller's
# `set -e`; bash 5.2 (debian bookworm — the previous kcov/kcov runner)
# does not. The pipe inside _get_latest_version uses `head -1` which
# closes stdin after one line, SIGPIPE'ing the upstream `grep -oP`;
# with `pipefail` set, the pipe inherits that non-zero exit. Without
# the `|| true` workaround, alpine consumers saw integration test #41
# (`upgrade.sh --check`) silently fail with empty output (~80% of
# runs) — script died at `latest_ver=$(...)` before the first _log
# line. Lock the workaround in place so a future refactor that drops
# the `|| true` is caught here, not in CI.

@test "_get_latest_version: returns 0 even when internal pipe fails (bash 5.3 set-e safety)" {
  run bash -c "
    set -euo pipefail
    source '${HARNESS}'
    TEMPLATE_REMOTE='fake'

    # Force a non-zero pipe exit by failing the inner-most stage. Same
    # shape as the SIGPIPE-from-head-1 scenario — pipefail catches the
    # non-zero exit either way.
    git()  { return 1; }

    _get_latest_version
    echo 'reached after _get_latest_version, rc=0'
  "
  assert_success
  assert_output --partial "reached after _get_latest_version, rc=0"
}

@test "_get_latest_version: empty result feeds _check's 'Could not fetch' guard" {
  # Sanity: when the function returns nothing, _check still surfaces
  # the genuine failure mode via the existing emptiness guard. Without
  # this companion check, the `|| true` could silently mask real
  # network outages.
  run bash -c "
    source '${HARNESS}'
    TEMPLATE_REMOTE='fake'

    _get_local_version() { echo v0.9.5; }
    _get_latest_version() { :; }
    _check
  "
  assert_failure
  assert_output --partial "Could not fetch latest version from fake"
}

# ── _upgrade refuses implicit downgrade ─────────────────────────────────────
#
# Calling `./template/upgrade.sh v0.11.0` from a v0.12.0-rc1 working
# tree should refuse and exit non-zero before touching the working
# tree. The user can still recover deliberately (e.g., set the version
# file by hand or rerun with a clear --force flag if we ever add one).

@test "_upgrade refuses to downgrade from a newer local version" {
  # Extract a minimal _upgrade by hand (the full body sources too many
  # external deps); we only need the entry-point downgrade guard. The
  # guard MUST fire before any subtree pull.
  run bash -c "
    source '${HARNESS}'
    sed -n '/^_upgrade() {\$/,/^}\$/p' '${UPGRADE}' > '${TEMP_DIR}/upgrade_fn.sh'
    source '${TEMP_DIR}/upgrade_fn.sh'

    _get_local_version()      { echo v0.12.0-rc1; }
    _require_git_identity()   { :; }
    _require_clean_merge_state(){ :; }
    git()                     { echo 'FATAL: git should not be called' >&2; exit 99; }

    _upgrade v0.11.0
  "
  assert_failure
  assert_output --partial "downgrade"
  refute_output --partial "FATAL"
}
