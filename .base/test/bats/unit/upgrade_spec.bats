#!/usr/bin/env bats
#
# Unit tests for upgrade.sh, focused on _warn_config_drift — the
# helper that tells the user when the upstream .base/dist/config/ tree
# moved during a subtree pull so they can reconcile their per-repo
# <repo>/config/ copy.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  UPGRADE="/source/dist/script/base/upgrade.sh"

  # Build a self-contained test harness: a shell script that redefines
  # `_log` / `_error` (avoids pulling in upgrade.sh's top-level `cd
  # REPO_ROOT`) and extracts helpers from upgrade.sh by sed range so
  # tests exercise the real function bodies, not copies.
  TEMP_DIR="$(mktemp -d)"
  HARNESS="${TEMP_DIR}/harness.sh"
  cat > "${HARNESS}" <<'EOS'
# Pin TEMPLATE_REL for tests. Production upgrade.sh derives it via
# `basename ${SCRIPT_DIR}` at the top of the file, but the test
# harness sources only function bodies (sed-extracted), so the
# top-level derivation never runs — the tests pin the conventional
# subtree prefix to make the assertions deterministic.
TEMPLATE_REL=".base"
# Stub the _log_* helpers. Real upgrade.sh sources _lib.sh and
# routes _log / _error through _log_info / _log_err; this harness
# extracts function bodies via sed so we re-stub the surface those
# bodies call.
_log_info() { printf '[%s] INFO: %s\n' "$1" "${*:2}"; }
_log_warn() { printf '[%s] WARNING: %s\n' "$1" "${*:2}" >&2; }
_log_err()  { printf '[%s] ERROR: %s\n' "$1" "${*:2}" >&2; }
_log()    { _log_info upgrade "$*"; }
_error()  { _log_err upgrade "$*"; exit 1; }
EOS
  sed -n '/^_warn_config_drift() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_git_identity() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_require_clean_merge_state() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_verify_subtree_intact() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_rollback_subtree_pull() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_semver_cmp() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_check() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_get_latest_version() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_migrate_lifecycle_restart_default() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_trim_ws() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
  sed -n '/^_lifecycle_restart_is() {$/,/^}$/p' "${UPGRADE}" >> "${HARNESS}"
}

# _seed_restart_repo <dir> <vendored_template_restart> <repo_restart_block...>
#   A downstream git repo carrying a vendored template `.setup.conf`
#   (the pre-pull baseline the migration reads to decide whether this
#   upgrade crosses the rescope) plus its own committed `.setup.conf`.
_seed_restart_repo() {
  local _dir="$1" _tpl_restart="$2"; shift 2
  mkdir -p "${_dir}/.base/dist"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
  printf '[lifecycle]\n%s\n' "${_tpl_restart}" > "${_dir}/.base/dist/.setup.conf"
  printf '%s\n' "$@" > "${_dir}/.setup.conf"
  git -C "${_dir}" add -A
  git -C "${_dir}" commit -q -m seed
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── _warn_config_drift logic ────────────────────────────────────────────────

@test "_warn_config_drift silent when no .base/dist/config in HEAD" {
  local _git_dir="${TEMP_DIR}/empty"
  mkdir -p "${_git_dir}"
  git -C "${_git_dir}" init -q
  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift ''"
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift silent when pre and post hashes match" {
  local _git_dir="${TEMP_DIR}/same"
  mkdir -p "${_git_dir}/.base/dist/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "one" > "${_git_dir}/.base/dist/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _pre=\$(git rev-parse HEAD:.base/dist/config)
    _warn_config_drift \"\${_pre}\"
  "
  assert_success
  refute_output --partial "WARNING"
}

@test "_warn_config_drift prints WARNING + diff hint when hashes differ" {
  local _git_dir="${TEMP_DIR}/drift"
  mkdir -p "${_git_dir}/.base/dist/config"
  git -C "${_git_dir}" init -q -b main
  git -C "${_git_dir}" config user.email t@t
  git -C "${_git_dir}" config user.name t
  echo "original" > "${_git_dir}/.base/dist/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c1
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD:.base/dist/config)"

  echo "updated" > "${_git_dir}/.base/dist/config/bashrc"
  git -C "${_git_dir}" add -A
  git -C "${_git_dir}" commit -q -m c2

  run bash -c "cd '${_git_dir}' && source '${HARNESS}' && _warn_config_drift '${_pre}'"
  assert_success
  assert_output --partial "WARNING: .base/dist/config/ changed"
  assert_output --partial "diff -ruN .base/dist/config config"
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

@test "upgrade.sh captures pre-pull <subtree-prefix>/config tree hash" {
  # The WARNING only fires when we have both pre and post hashes —
  # guard against dropping the snapshot line. Path is parameterised
  # via TEMPLATE_REL post-v0.25.0 so the `.base/` -> `.base/`
  # rename keeps the snapshot working.
  run grep -F 'HEAD:${TEMPLATE_REL}/dist/config' "${UPGRADE}"
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
  mkdir -p "${_dir}/.base/dist/script/docker/wrapper" \
           "${_dir}/.base/dist/script/base"
  echo "v0.9.5" > "${_dir}/.base/.version"
  echo "#!/usr/bin/env bash" > "${_dir}/.base/dist/script/base/init.sh"
  echo "#!/usr/bin/env bash" > "${_dir}/.base/dist/script/docker/wrapper/setup.sh"
  git -C "${_dir}" init -q -b main
  git -C "${_dir}" config user.email t@t
  git -C "${_dir}" config user.name t
  git -C "${_dir}" add -A
  git -C "${_dir}" commit -q -m "initial"
}

@test "_verify_subtree_intact succeeds when subtree dir + version match target (#477 happy path)" {
  local _git_dir="${TEMP_DIR}/intact_ok"
  _mk_subtree_repo "${_git_dir}"  # writes .version=v0.9.5
  run bash -c "
    cd '${_git_dir}'
    _pre=\$(git rev-parse HEAD)
    source '${HARNESS}'
    _verify_subtree_intact \"\${_pre}\" 'v0.9.5'
  "
  assert_success
}

@test "_verify_subtree_intact rolls back when .base/.version is missing" {
  local _git_dir="${TEMP_DIR}/intact_noversion"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  # Simulate the destructive FF: .base/* moved up, .base/.version gone.
  rm "${_git_dir}/.base/.version"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}' 'v0.9.5'
  "
  assert_failure
  assert_output --partial "integrity check failed"
  assert_output --partial ".base/.version"
  # Post-condition: marker is restored by the rollback `git reset --hard`.
  [ -f "${_git_dir}/.base/.version" ]
}

@test "_verify_subtree_intact rolls back when .base/ dir is missing (#477 destructive-FF detector)" {
  local _git_dir="${TEMP_DIR}/intact_nodir"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  rm -rf "${_git_dir}/.base"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}' 'v0.9.5'
  "
  assert_failure
  assert_output --partial "subtree dir missing"
  # Post-condition: rollback restored the dir.
  [ -d "${_git_dir}/.base" ]
}

@test "_verify_subtree_intact rolls back when .base/ dir is empty (#477)" {
  local _git_dir="${TEMP_DIR}/intact_emptydir"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  # Empty the dir but keep it as a directory.
  rm -rf "${_git_dir}/.base"/* "${_git_dir}/.base"/.[!.]*

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}' 'v0.9.5'
  "
  assert_failure
  assert_output --partial "subtree dir is empty"
  # Post-condition: contents restored.
  [ -f "${_git_dir}/.base/.version" ]
}

@test "_verify_subtree_intact rolls back when .version content is not semver (#477)" {
  local _git_dir="${TEMP_DIR}/intact_notsemver"
  _mk_subtree_repo "${_git_dir}"
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"
  # Corrupt .version with non-semver content.
  echo "garbage-not-a-version" > "${_git_dir}/.base/.version"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}' 'v0.9.5'
  "
  assert_failure
  assert_output --partial "not semver"
  assert_output --partial "garbage-not-a-version"
  # Post-condition: original .version content restored.
  run cat "${_git_dir}/.base/.version"
  assert_output "v0.9.5"
}

@test "_verify_subtree_intact rolls back when .version does not match target (#477 wrong-tag detector)" {
  local _git_dir="${TEMP_DIR}/intact_wrongtag"
  _mk_subtree_repo "${_git_dir}"  # writes v0.9.5
  local _pre
  _pre="$(git -C "${_git_dir}" rev-parse HEAD)"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _verify_subtree_intact '${_pre}' 'v0.8.0'
  "
  assert_failure
  assert_output --partial "v0.9.5"
  assert_output --partial "v0.8.0"
}

@test "_rollback_subtree_pull surfaces a failed reset instead of falsely reporting 'restored' (#700)" {
  # The rollback exists to rescue a tree the destructive subtree FF
  # already mangled. If the rescue `git reset --hard` itself fails
  # (corrupt / gc'd / bogus pre_head), the old `|| true` swallowed the
  # failure and still printed 'repo restored to pre-upgrade state' -- a
  # reassuring lie over a still-broken tree. Drive it with an
  # unresolvable pre_head and assert the failure is surfaced, not masked.
  local _git_dir="${TEMP_DIR}/rollback_failed_reset"
  _mk_subtree_repo "${_git_dir}"

  run bash -c "
    cd '${_git_dir}'
    source '${HARNESS}'
    _rollback_subtree_pull 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
  "
  assert_failure
  # A distinct, honest failure message -- NOT the success-implying line.
  assert_output --partial "rollback FAILED"
  assert_output --partial "manual recovery required"
  refute_output --partial "restored to pre-upgrade state"
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

@test "upgrade.sh calls _verify_subtree_intact after subtree pull with target version (#477)" {
  local _pull_line _verify_line
  _pull_line="$(grep -n 'git subtree pull' "${UPGRADE}" | head -1 | cut -d: -f1)"
  # Caller must pass both _pre_head AND target_ver so the wrong-tag
  # detector (R1+) is armed in production, not just in tests.
  _verify_line="$(grep -n '_verify_subtree_intact "\${_pre_head}" "\${target_ver}"' "${UPGRADE}" | head -1 | cut -d: -f1)"
  [ -n "${_pull_line}" ]
  [ -n "${_verify_line}" ]
  (( _verify_line > _pull_line ))
}

@test "upgrade.sh snapshots pre-pull HEAD for rollback" {
  run grep -F 'git rev-parse HEAD' "${UPGRADE}"
  assert_success
}

# ── self-run guard wiring (ADR-00000011 sec.8) ──────────────────────────────
#
# upgrade.sh has the same walk-up as init.sh (SUBTREE_ROOT -> parent as
# REPO_ROOT, basename as the subtree prefix used directly in
# `git subtree pull --prefix=`). Run raw inside the base template source
# it would attempt a nonsensical subtree pull into base's PARENT dir.
# The shared guard _assert_not_template_source (lib/template_guard.sh,
# added in the init.sh guard change) refuses that; init.sh already sources
# and calls it. Lock the same wiring into upgrade.sh.

@test "upgrade.sh sources lib/template_guard.sh" {
  # _lib.sh does NOT pull in template_guard.sh, so upgrade.sh must source
  # it explicitly (mirroring init.sh) for _assert_not_template_source to
  # be defined.
  run grep -F 'lib/template_guard.sh' "${UPGRADE}"
  assert_success
}

@test "upgrade.sh calls _assert_not_template_source with the resolved subtree root" {
  # Lock the call site (with the `upgrade` service tag and SUBTREE_ROOT
  # argument). Runtime ordering — the guard fires before any mutation —
  # is covered by the integration test (which asserts refusal leaves
  # .version untouched); a textual line-order check would be wrong here
  # because _upgrade (holding the `git subtree pull`) is defined ABOVE
  # main(), where the guard call lives.
  run grep -F '_assert_not_template_source "${SUBTREE_ROOT}" upgrade' "${UPGRADE}"
  assert_success
}

# ── _semver_cmp (SemVer §11 ordering) ───────────────────────────────────────
#
# SemVer §11 says a pre-release version has LOWER precedence than the
# associated normal version (rc1 < final). GNU `sort -V` sorts the
# other way (final < rc1, treating `-` as "less than empty"), which is
# why upgrade.sh needs its own comparator: the wrong ordering causes
# `just upgrade-check` to mis-classify v0.12.0-rc1 vs released v0.12.0
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
# heart ofpreviously _check used `==` and reported any
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
  # Scenario fromuser's downstream pinned to v0.12.0-rc1
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
# An unreachable remote must leave _get_latest_version returning 0 with an
# empty result, so _check's emptiness guard is what reports it -- named
# remote, one clear message -- rather than the caller dying at the
# assignment with nothing printed at all.
#
# The original spelling piped `grep -oP` into `head -1`, and alpine
# consumers saw `upgrade.sh --check` die silently in ~80% of runs: `head`
# stops reading after one line, the grep still writing takes SIGPIPE,
# `pipefail` inherits the 141, and bash 5.3 propagates that failed
# command-substitution exit through the caller's `set -e` (bash 5.2 did
# not, which is why it looked runner-specific). That was answered with
# `|| true`, which stopped the abort by discarding the status.
#
# The pipeline is gone now, so there is no status to discard and nothing
# for `|| true` to hide. This case still pins the contract it always
# pinned -- rc=0 and an empty answer on a dead remote -- but no longer
# locks in the workaround as the mechanism.

@test "_get_latest_version: returns 0 with an empty result when the remote is unreachable" {
  # Strict shell as a script FILE, never `bash -c '...'`: under kcov the
  # xtrace PS4 expands ${BASH_SOURCE}, and at the top level of a `bash -c`
  # string that array is EMPTY, so `set -u` killed the harness before the
  # function ran. This case used to skip under COVERAGE for exactly that
  # reason; a script file populates BASH_SOURCE[0], so it now runs in the
  # coverage shard too -- which is the environment where the SIGPIPE
  # defect actually reproduces.
  local _runner="${TEMP_DIR}/unreachable_strict.sh"
  cat > "${_runner}" <<'EOS'
set -euo pipefail
source "${HARNESS_PATH}"
TEMPLATE_REMOTE='fake'

# A remote that cannot be reached: git fails outright.
git() { return 1; }

printf 'latest=[%s]\n' "$(_get_latest_version)"
printf 'reached after _get_latest_version, rc=0\n'
EOS

  run env HARNESS_PATH="${HARNESS}" bash "${_runner}"
  assert_success
  assert_line "latest=[]"
  assert_line "reached after _get_latest_version, rc=0"
}

@test "_get_latest_version: an early-closing reader cannot empty the tag scan (#905)" {
  # `git ls-remote | grep -oP | head -1 | sed` pipes into a reader that
  # stops reading. `head -1` leaves after one line, the `grep -oP` still
  # writing takes SIGPIPE and exits 141, and `pipefail` makes 141 the
  # pipeline's status -- which under `set -e` killed the script at the
  # assignment, before _check printed anything. The `|| true` this
  # function grew stops the abort but throws the status away with it, so
  # the surviving failure mode is a silently EMPTY answer: "there is no
  # newer release" when there is one.
  #
  # `head` is shimmed to leave without reading and `git` to keep writing
  # after it has gone. A scan that parses the stream in-shell execs
  # neither, so the newest tag still comes back.
  local _shim="${TEMP_DIR}/shim"
  shim_early_closing_reader "${_shim}" head
  shim_late_writer "${_shim}" git \
    "def456	refs/tags/v0.7.2" \
    "abc123	refs/tags/v0.7.0"

  # Strict shell as a script FILE, never `bash -c '...'`: under kcov the
  # xtrace PS4 expands ${BASH_SOURCE}, which is EMPTY at the top level of
  # a `bash -c` string, so `set -u` aborts the harness before the function
  # runs. A file populates BASH_SOURCE[0].
  local _runner="${TEMP_DIR}/get_latest_strict.sh"
  cat > "${_runner}" <<'EOS'
set -euo pipefail
source "${HARNESS_PATH}"
TEMPLATE_REMOTE='fake'
PATH="${SHIM_DIR}:${PATH}"
printf 'latest=%s\n' "$(_get_latest_version)"
EOS

  run env HARNESS_PATH="${HARNESS}" SHIM_DIR="${_shim}" bash "${_runner}"
  assert_success
  assert_output "latest=v0.7.2"
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
# Calling `./.base/upgrade.sh v0.11.0` from a v0.12.0-rc1 working
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

# ── _migrate_lifecycle_restart_default ──────────────────────────────────────
#
# `[lifecycle] restart` was devel-scoped and shipped as a literal
# `restart = no`; init.sh --gen-conf copies the WHOLE template, so every
# downstream repo carries that literal. The key is now deploy-scoped with a
# shipped default of `unless-stopped`, which makes the copied `no` stale by
# construction -- left alone it silently denies the field bundle its
# auto-start on host reboot.

@test "_migrate_lifecycle_restart_default rewrites the stale template default, loudly" {
  local _r="${TEMP_DIR}/stale"
  _seed_restart_repo "${_r}" "restart = no" "[lifecycle]" "restart = no" "init = true"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  assert_output --partial "MIGRATION"
  assert_output --partial "restart = unless-stopped"

  run grep -Fx "restart = unless-stopped" "${_r}/.setup.conf"
  assert_success
  # Unrelated keys survive untouched.
  run grep -Fx "init = true" "${_r}/.setup.conf"
  assert_success
  # The rewrite is committed, so the subsequent subtree pull sees a clean tree.
  run git -C "${_r}" status --porcelain
  assert_output ""
}

@test "_migrate_lifecycle_restart_default leaves a deliberately chosen policy alone" {
  local _r="${TEMP_DIR}/chosen"
  _seed_restart_repo "${_r}" "restart = no" "[lifecycle]" "restart = on-failure:5"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  refute_output --partial "MIGRATION"
  run grep -Fx "restart = on-failure:5" "${_r}/.setup.conf"
  assert_success
}

@test "_migrate_lifecycle_restart_default is inert once the vendored template ships the new default" {
  # Post-rescope the repo owns its `no`; a later deliberate choice of `no`
  # must never be rewritten again.
  local _r="${TEMP_DIR}/post"
  _seed_restart_repo "${_r}" "restart = unless-stopped" "[lifecycle]" "restart = no"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  refute_output --partial "MIGRATION"
  run grep -Fx "restart = no" "${_r}/.setup.conf"
  assert_success
}

@test "_migrate_lifecycle_restart_default ignores a restart key outside [lifecycle]" {
  local _r="${TEMP_DIR}/othersection"
  _seed_restart_repo "${_r}" "restart = no" "[stage:runtime]" "restart = no"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  refute_output --partial "MIGRATION"
  run grep -Fx "restart = no" "${_r}/.setup.conf"
  assert_success
}

@test "_migrate_lifecycle_restart_default is a no-op without a repo .setup.conf" {
  local _r="${TEMP_DIR}/noconf"
  mkdir -p "${_r}/.base/dist"
  printf '[lifecycle]\nrestart = no\n' > "${_r}/.base/dist/.setup.conf"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  assert_output ""
}

@test "_migrate_lifecycle_restart_default is a no-op without a vendored template baseline" {
  # Cannot tell whether this upgrade crosses the rescope -> touch nothing.
  local _r="${TEMP_DIR}/notpl"
  mkdir -p "${_r}"
  printf '[lifecycle]\nrestart = no\n' > "${_r}/.setup.conf"

  run bash -c "source '${HARNESS}' && _migrate_lifecycle_restart_default '${_r}'"
  assert_success
  refute_output --partial "MIGRATION"
  run grep -Fx "restart = no" "${_r}/.setup.conf"
  assert_success
}
