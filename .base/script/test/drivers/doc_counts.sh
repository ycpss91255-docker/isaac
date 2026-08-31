#!/usr/bin/env bash
# drivers/doc_counts.sh - "doc/test/*.md still matches the specs" per-tool
# driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_doc_counts, the dispatcher entry point for ../check_test_md_drift.sh
# -- the read-only twin of ../sync-doc-counts.sh, exactly the relationship
# drivers/readme_sync.sh has with ../sync-readme-hashes.sh: the generator
# writes the derived figures, this validates them and never writes.
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/stale_setup_conf.sh / drivers/readme_sync.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why this driver exists at all -- the gate predates it and already worked:
# it was reachable only through `just test sync-docs-check`, which a human
# has to remember, and an advisory PostToolUse hook in the harness repo,
# which fires only during an interactive editing session. Neither is on the
# path a branch must pass, so a branch could add a @test, leave the
# catalogue stale, pass the full local gate, pass CI, and merge -- which is
# the path every doc-count drift in the recent batch took. Making the
# catalogue generated removed the CAUSE of the rot; this driver is what
# NOTICES it when it rots anyway.
#
# Relationship to the harness hook (deliberate, not an accident): the
# harness repo's .claude/hooks/check_test_md_drift.sh calls the same
# ../check_test_md_drift.sh and now duplicates this gate. It is kept as the
# FAST INTERACTIVE signal -- it reports drift seconds after the Edit that
# caused it, whereas this driver reports it at `just test` / CI time. The
# hook is advisory (it never blocks) and holds no rule of its own: every
# rule lives in check_test_md_drift.sh, which both call. If the hook is ever
# removed, nothing is lost but latency; if it ever disagrees with this
# driver, the driver is authoritative because it is the one that can fail a
# branch.
#
# Scope: doc/test/*.md against the spec trees named by
# ../check_test_md_drift.sh (test/bats/**/*_spec.bats plus the shipped
# dist/test/bats/smoke/**). An unusable scan root -- missing, no doc/test/,
# no specs -- is an error there rather than a vacuous pass here.

_DOC_COUNTS_DRIVER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
readonly _DOC_COUNTS_DRIVER_DIR

# shellcheck source=script/test/check_test_md_drift.sh
source "${_DOC_COUNTS_DRIVER_DIR}/../check_test_md_drift.sh"

# ── doc/test count drift gate ────────────────────────────────────────────────

_run_doc_counts() {
  echo "--- Running doc/test count drift gate ---"

  # An ABSOLUTE root, always: _check_test_md_drift symlinks the spec trees
  # into a temp dir, so a relative root would be resolved against the temp
  # dir on that hop and every count would come back 0. ${REPO_ROOT} is
  # already absolute (test.sh derives it with `pwd -P`); passing it
  # explicitly keeps that a property of the call, not of the environment.
  if ! _check_test_md_drift "${REPO_ROOT}"; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_doc_counts \
      "doc/test count drift. The figures in doc/test/*.md are GENERATED from the specs -- run 'just test sync-docs' and commit the result; never hand-edit a count or a catalogue row. The offending unified diff is above."
    return 1
  fi
  echo "doc/test count drift gate: clean"
}
