#!/usr/bin/env bats
#
# self_test_yaml_spec.bats — structural assertions for the
# `.github/workflows/self-test.yaml` workflow.
#
# Locks the #305 actionlint gate: a new `actionlint` job runs
# rhysd/actionlint via Docker against the workflows tree, and the
# three downstream jobs (test / integration-e2e / behavioural)
# declare `needs: actionlint` so they cannot start until actionlint
# passes. Catches GHA workflow-validator semantic regressions (the
# class behind the v0.26.0-rc1 wedge, fixed in #297) before bats /
# docker matrix burns CI minutes.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/self-test.yaml"
  [[ -f "${WF}" ]] || skip "self-test.yaml not at expected path"
}

# ── actionlint job declared (#305) ────────────────────────────────────

@test "self-test.yaml: declares actionlint job" {
  run grep -E '^  actionlint:' "${WF}"
  assert_success
}

@test "self-test.yaml: actionlint job runs rhysd/actionlint via Docker with pinned tag" {
  run grep -E 'rhysd/actionlint:[0-9]+\.[0-9]+\.[0-9]+' "${WF}"
  assert_success
}

# ── Downstream jobs gate on actionlint (#305) ─────────────────────────

@test "self-test.yaml: test job declares needs: actionlint" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: actionlint'
}

@test "self-test.yaml: integration-e2e job declares needs: actionlint" {
  run awk '/^  integration-e2e:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: actionlint'
}

@test "self-test.yaml: behavioural job declares needs: actionlint" {
  run awk '/^  behavioural:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: actionlint'
}
