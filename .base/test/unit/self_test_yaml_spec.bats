#!/usr/bin/env bats
#
# self_test_yaml_spec.bats — structural assertions for the
# `.github/workflows/self-test.yaml` workflow.
#
# Locks two cumulative invariants:
#
# 1. #305 actionlint gate (original): an `actionlint` job runs
#    rhysd/actionlint via Docker against the workflows tree, and the
#    downstream jobs (test / integration-e2e / behavioural) declare
#    `needs:` on actionlint so they cannot start until actionlint
#    passes.
#
# 2. #317 P1 classifier + buildx GHA cache: a `classify` job emits
#    `code_changed` + `behavioural_relevant` outputs based on PR diff
#    against the doc-only allow-list and behavioural block-list; the
#    `test` job always runs (required check) but short-circuits to
#    SUCCESS on doc-only PRs; `integration-e2e` + `behavioural` gate
#    via job-level `if:`. All three test-tools image builds use
#    docker/build-push-action with shared `scope=test-tools` GHA cache.

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

# ── classify job declared with both outputs (#317) ────────────────────

@test "self-test.yaml: declares classify job (#317)" {
  run grep -E '^  classify:' "${WF}"
  assert_success
}

@test "self-test.yaml: classify job declares code_changed output (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'code_changed: ${{ steps.diff.outputs.code_changed }}'
}

@test "self-test.yaml: classify job declares behavioural_relevant output (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'behavioural_relevant: ${{ steps.diff.outputs.behavioural_relevant }}'
}

@test "self-test.yaml: classify uses doc-only allow-list 'doc/**' + 'README.md' + 'LICENSE' (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "':!doc/**'"
  assert_output --partial "':!README.md'"
  assert_output --partial "':!LICENSE'"
}

@test "self-test.yaml: classify uses behavioural block-list entrypoint + compose + Dockerfile + wrappers + init/upgrade + workflows (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "'script/entrypoint.sh'"
  assert_output --partial "'compose.yaml'"
  assert_output --partial "'dockerfile/Dockerfile.example'"
  assert_output --partial "'dockerfile/Dockerfile.test-tools'"
  assert_output --partial "'script/docker/build.sh'"
  assert_output --partial "'script/docker/run.sh'"
  assert_output --partial "'script/docker/exec.sh'"
  assert_output --partial "'script/docker/stop.sh'"
  assert_output --partial "'test/behavioural/**'"
  assert_output --partial "'init.sh' 'upgrade.sh'"
  assert_output --partial "'.github/workflows/**'"
}

@test "self-test.yaml: classify defaults code_changed/behavioural_relevant to true on non-PR events (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  # Both outputs branch to 'true' when EVENT_NAME != pull_request
  assert_output --partial '!= "pull_request"'
  assert_output --partial 'code_changed=true'
  assert_output --partial 'behavioural_relevant=true'
}

@test "self-test.yaml: classify omits set -e to fail-open on diff errors (#317 gotcha-1)" {
  # The classifier must not abort the job on diff/fetch failure — the
  # `test` job needs classify as a gate, and aborting here would block all
  # PR merges (Q4 fail-closed chain). Verify `set -e` is not in effect by
  # asserting `set -uo pipefail` (not `set -euo pipefail`) is used.
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'set -uo pipefail'
  refute_output --partial 'set -euo pipefail'
}

@test "self-test.yaml: classify pre-fetches base ref before diff (#317 gotcha-2)" {
  # actions/checkout `fetch-depth: 0` fetches the head branch's full
  # history but NOT the base ref. Fork PRs (and some squash-merged
  # histories) start without `origin/<base>` present locally; the
  # classifier must pre-fetch it explicitly, with failure being non-fatal
  # so the diff fall-through can still take over.
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'git fetch origin'
  assert_output --partial '"${BASE_REF}:refs/remotes/origin/${BASE_REF}"'
  assert_output --partial '|| true'
}

# ── Downstream jobs gate on actionlint + classify (#305 / #317) ───────

@test "self-test.yaml: test job declares needs on actionlint AND classify (#317)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: integration-e2e job declares needs on actionlint AND classify (#317)" {
  run awk '/^  integration-e2e:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: behavioural job declares needs on actionlint AND classify (#317)" {
  run awk '/^  behavioural:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

# ── Doc-only short-circuit + conditional gating (#317) ────────────────

@test "self-test.yaml: test job has doc-only short-circuit step (#317)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "needs.classify.outputs.code_changed == 'false'"
  assert_output --partial "Doc-only short-circuit"
}

@test "self-test.yaml: test job real steps gated by code_changed == 'true' (#317)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  # At least one step should be gated by the positive branch
  assert_output --partial "needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: integration-e2e job-level if: gates on code_changed (#317)" {
  run awk '/^  integration-e2e:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: behavioural job-level if: gates on behavioural_relevant (#317 P3)" {
  # P1 shipped this with `code_changed` while the behavioural_relevant
  # output was emitted-but-unused; P3 tightens to the narrower output so
  # PRs that change pure lint / unit-test paths (already covered by
  # `test`) don't burn the docker.sock-mounted compose run.
  run awk '/^  behavioural:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.behavioural_relevant == 'true'"
  refute_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: classify behavioural block-list extends to setup.sh + i18n.sh + lib/** + prune.sh (#317 P3 gotcha-5)" {
  # setup.sh / lib/** drive .env + compose.yaml generation; i18n.sh
  # gates wrapper message output (smoke regressions surface in compose
  # logs); prune.sh is part of the wrapper family. All four indirectly
  # affect what the docker.sock-mounted compose service does, so they
  # must invalidate the behavioural-skip optimization.
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "'script/docker/setup.sh'"
  assert_output --partial "'script/docker/i18n.sh'"
  assert_output --partial "'script/docker/lib/**'"
  assert_output --partial "'script/docker/prune.sh'"
}

# ── buildx GHA cache on test-tools builds (#317) ──────────────────────

@test "self-test.yaml: test job uses docker/build-push-action with GHA cache scope=test-tools (#317)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: docker/build-push-action@v6'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

@test "self-test.yaml: behavioural job uses docker/build-push-action with GHA cache scope=test-tools (#317)" {
  run awk '/^  behavioural:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: docker/build-push-action@v6'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

# ── #317 P2: Obtain step + rolling tag fallback ──────────────────────

@test "self-test.yaml: test job has Obtain step pulling :main with 3-layer fallback (#317 P2)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain test-tools:local'
  assert_output --partial 'docker pull --platform linux/amd64'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'docker tag'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: test job Build step is gated on steps.obtain.outputs.build_local == 'true' (#317 P2)" {
  run awk '/^  test:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "steps.obtain.outputs.build_local == 'true'"
}

@test "self-test.yaml: integration-e2e job has Obtain step + TEST_TOOLS_IMAGE env passthrough (#317 P2)" {
  run awk '/^  integration-e2e:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain test-tools:local'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'TEST_TOOLS_IMAGE: test-tools:local'
}

@test "self-test.yaml: integration-e2e job keeps buildx driver: docker for host-daemon visibility (#317 P2)" {
  # `./build.sh test` -> `docker compose build` whose `FROM
  # ${TEST_TOOLS_IMAGE}` resolves against the host docker daemon, not
  # against buildx's docker-container store. Keep the docker driver
  # so `docker pull :main` + `docker tag` land where the subsequent
  # build can see them. Trade-off: layer-3 fallback rebuild here is
  # uncached (GHA cache requires docker-container), accepted because
  # the hot path is `docker pull :main` and the cold path matches
  # pre-P2 cost.
  run awk '/^  integration-e2e:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'driver: docker'
}

@test "self-test.yaml: behavioural job has Obtain step with 3-layer fallback (#317 P2)" {
  run awk '/^  behavioural:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain test-tools:local'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: Obtain step pre-fetches base ref before diff (#317 P2 + P1 gotcha-2 reuse)" {
  # Same gotcha-2 mitigation as the classify job: fork PRs need an
  # explicit fetch of origin/<base_ref> before `git diff` can resolve
  # the merge base for `dockerfile/Dockerfile.test-tools`. 4 expected
  # occurrences: classify job (1) + Obtain step in 3 jobs (3).
  run grep -c 'git fetch origin' "${WF}"
  assert_success
  assert_output '4'
}
