#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/stale_setup_conf.sh -- the
# "no stale config/docker/setup.conf path in runtime shell code" lint.
# The per-repo override and the template default now live at the repo-root
# .setup.conf dotfile, so a hardcoded config/docker/setup.conf in dist/
# runtime code reads a path that no longer exists and silently ignores the
# repo's knobs. The legacy-migration block in dist/script/base/upgrade.sh is
# the one legitimate consumer and opts out via explicit allow-begin /
# allow-end markers. Detection runs against a controlled temp REPO_ROOT so
# the spec is independent of the live tree's contents; a final case drives
# the REAL dist/ to prove it passes today.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree. Mirrors
  # issueref_lint_spec.bats.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/stale_setup_conf.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/script/docker/lib" "${SCRATCH}/dist/script/base"
  REPO_ROOT="${SCRATCH}"

  # The literal the lint hunts for, assembled at runtime so this spec file
  # never carries the stale path as a plain token of its own.
  STALE="config/docker/${_STALE_SETUP_CONF_BASENAME}"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a dist/ fixture script.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_stale_setup_conf: FAILS on a stale path in a dist/ script, naming file and line (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    '#!/usr/bin/env bash' \
    "_conf=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/script/docker/lib/sample.sh:2"* ]]
}

@test "_run_stale_setup_conf: names the replacement path in the failure message (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    "_conf=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *".setup.conf"* ]]
}

@test "_run_stale_setup_conf: FAILS on a stale path inside a comment too (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    "# read the override from ${STALE}"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:1"* ]]
}

@test "_run_stale_setup_conf: FAILS on a stale path AFTER an allow-end (region does not leak) (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\"" \
    "# ${_STALE_SETUP_CONF_ALLOW_END}" \
    "_other=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"sample.sh:4"* ]]
  [[ "${output}" != *"sample.sh:2"* ]]
}

@test "_run_stale_setup_conf: FAILS on an unterminated allow-begin region (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\""
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_stale_setup_conf: FAILS on an allow-end with no matching allow-begin (#845)" {
  _write "dist/script/base/sample.sh" \
    '#!/usr/bin/env bash' \
    "# ${_STALE_SETUP_CONF_ALLOW_END}"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: exemptions and clean trees
# ════════════════════════════════════════════════════════════════════

@test "_run_stale_setup_conf: EXEMPTS a stale path inside an allow-begin/allow-end region (#845)" {
  _write "dist/script/base/sample.sh" \
    "# ${_STALE_SETUP_CONF_ALLOW_BEGIN} legacy migration" \
    "_legacy=\"\${_root}/${STALE}\"" \
    "# ${_STALE_SETUP_CONF_ALLOW_END}"
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_stale_setup_conf: PASSES a dist/ tree that uses the repo-root dotfile (#845)" {
  _write "dist/script/docker/lib/sample.sh" \
    '#!/usr/bin/env bash' \
    '_conf="${_root}/.setup.conf"'
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_stale_setup_conf: ignores non-.sh files under dist/ (#845)" {
  mkdir -p "${SCRATCH}/dist/doc"
  printf '%s\n' "the override used to live at ${STALE}" \
    > "${SCRATCH}/dist/doc/notes.md"
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: scan-root guard
# ════════════════════════════════════════════════════════════════════

@test "_run_stale_setup_conf: FAILS when the dist/ scan root is missing (no vacuous pass) (#845)" {
  # An empty find root passes vacuously, silently disabling the lint if
  # dist/ is ever relocated. Fail loudly on a missing scan root instead.
  rm -rf "${SCRATCH}/dist"
  run _run_stale_setup_conf
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_stale_setup_conf: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_stale_setup_conf: the REAL dist/ passes today (migration block allowlisted) (#845)" {
  REPO_ROOT="/source"
  run _run_stale_setup_conf
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
