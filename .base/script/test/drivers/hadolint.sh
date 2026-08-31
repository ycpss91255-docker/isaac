#!/usr/bin/env bash
# drivers/hadolint.sh - Hadolint per-tool driver for the self-test
# dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_hadolint, the single source of truth for "which Dockerfiles +
# which config" the self-test lints (ADR-00000011).
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it -- that image bakes in the `hadolint` binary, so this driver
# never apt-installs it. References ${REPO_ROOT} (a global exported by
# test.sh). Follows drivers/shellcheck.sh conventions (sourced lib, uses
# ${REPO_ROOT}, _log_* / _die, no main).
#
# local==CI parity: self-test.yaml's dedicated hadolint job ran two
# hadolint/hadolint-action steps over dist/dockerfile/Dockerfile +
# dockerfile/Dockerfile.test-tools with config dist/.hadolint.yaml,
# but `just test` skipped hadolint entirely -- a Dockerfile change passed
# `just test` yet failed CI hadolint. Folding the SAME file list + config
# into a driver run by BOTH `just test` (here) and the CI job (via this
# driver) closes that blind spot: one source of truth, two callers.

# ── Hadolint ─────────────────────────────────────────────────────────────────

# The Dockerfiles linted + the shared config. Single source of truth: the
# self-test.yaml hadolint job invokes this driver, so the list lives here,
# not duplicated in YAML. Paths are repo-root-relative; resolved against
# ${REPO_ROOT} at call time.
readonly _HADOLINT_CONFIG="dist/.hadolint.yaml"
readonly _HADOLINT_DOCKERFILES=(
  "dist/dockerfile/Dockerfile"
  "dockerfile/Dockerfile.smoke"
  "dockerfile/Dockerfile.test-tools"
)

_run_hadolint() {
  echo "--- Running Hadolint ---"
  command -v hadolint >/dev/null 2>&1 \
    || _die ci_no_hadolint "hadolint not in PATH; run via the test-tools container ('just test' / 'just test lint'), which bakes it in (the host has no hadolint binary)."

  local _config="${REPO_ROOT}/${_HADOLINT_CONFIG}"
  local _dockerfile
  for _dockerfile in "${_HADOLINT_DOCKERFILES[@]}"; do
    echo "hadolint --config ${_HADOLINT_CONFIG} ${_dockerfile}"
    hadolint --config "${_config}" "${REPO_ROOT}/${_dockerfile}"
  done
}
