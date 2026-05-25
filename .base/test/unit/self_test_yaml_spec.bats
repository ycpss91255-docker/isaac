#!/usr/bin/env bats
#
# self_test_yaml_spec.bats — structural assertions for the
# `.github/workflows/self-test.yaml` workflow.
#
# Locks three cumulative invariants:
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
#
# 3. #337 ci-rollup aggregator: a single `ci-rollup` job aggregates
#    [actionlint, classify, test, integration-e2e, behavioural] under
#    `if: always()`, treating SKIPPED as pass-equivalent for the two
#    conditionally-gated jobs (integration-e2e + behavioural). Branch
#    protection requires only `ci-rollup`, so sub-jobs (#376
#    shellcheck/hadolint, #377 bats-unit/bats-integration) can join
#    its `needs:` without further branch-protection churn.

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

# ── Downstream jobs gate on actionlint + classify (#305 / #317 / #377) ─

@test "self-test.yaml: bats-unit job declares needs on actionlint AND classify (#377)" {
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: bats-integration job declares needs on actionlint AND classify (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
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

# ── Conditional gating (#317, #377) ───────────────────────────────────

@test "self-test.yaml: bats-unit job-level if: gates on code_changed (#377)" {
  # Post-#377 bats-unit replaces the always-running `test` job's
  # short-circuit pattern with a clean job-level skip. ci-rollup's
  # SKIPPED=pass rule (#337) keeps doc-only PRs merge-able.
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: bats-integration job-level if: gates on code_changed (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: no monolithic `test:` job remains after #377 split" {
  # Pre-#377 a `test` job ran shellcheck + bats sequentially. #376
  # peeled shellcheck out, #377 splits the rest into bats-unit
  # (matrix) + bats-integration. The old job is fully removed.
  run grep -E '^  test:' "${WF}"
  assert_failure
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

# ── buildx GHA cache on test-tools builds (#317, #377) ────────────────

@test "self-test.yaml: bats-unit job uses docker/build-push-action with GHA cache scope=test-tools (#377)" {
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: docker/build-push-action@v6'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

@test "self-test.yaml: bats-integration job uses docker/build-push-action with GHA cache scope=test-tools (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
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

@test "self-test.yaml: bats-unit job has Obtain step pulling :main with 3-layer fallback (#317 P2 + #377)" {
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain test-tools:local'
  assert_output --partial 'docker pull --platform linux/amd64'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'docker tag'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: bats-unit Build step is gated on steps.obtain.outputs.build_local == 'true' (#317 P2 + #377)" {
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "steps.obtain.outputs.build_local == 'true'"
}

@test "self-test.yaml: bats-integration job has Obtain step + 3-layer fallback (#317 P2 + #377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain test-tools:local'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
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

@test "self-test.yaml: Obtain step pre-fetches base ref before diff (#317 P2 + P1 gotcha-2 reuse, #377)" {
  # Same gotcha-2 mitigation as the classify job: fork PRs need an
  # explicit fetch of origin/<base_ref> before `git diff` can resolve
  # the merge base for `dockerfile/Dockerfile.test-tools`. Post-#377
  # the `test` job split into bats-unit + bats-integration so the
  # occurrence count grows: classify (1) + 4 jobs with Obtain steps
  # (bats-unit + bats-integration + integration-e2e + behavioural).
  run grep -c 'git fetch origin' "${WF}"
  assert_success
  assert_output '5'
}

# ── ci-rollup aggregator (#337) ───────────────────────────────────────

@test "self-test.yaml: declares ci-rollup job (#337)" {
  run grep -E '^  ci-rollup:' "${WF}"
  assert_success
}

@test "self-test.yaml: ci-rollup needs every sibling PR-check job (#337 + #376 + #377)" {
  # The aggregator waits on actionlint + classify + shellcheck +
  # hadolint + bats-unit + bats-integration + integration-e2e +
  # behavioural so its result reflects every PR check. `coverage` is
  # intentionally NOT in the list — it's a push-to-main metric, not a
  # PR gate; including it would block PR merges on a coverage hiccup.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify, shellcheck, hadolint, bats-unit, bats-integration, integration-e2e, behavioural]'
}

@test "self-test.yaml: ci-rollup does NOT need coverage (#377)" {
  # Coverage is push-to-main-only metric, not a PR gate.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  refute_output --partial 'needs.coverage.result'
  # The `needs:` line itself must not list coverage either. Negative
  # assertion via partial — the `needs: [...]` line above is the
  # canonical source.
  refute_output --partial ', coverage,'
  refute_output --partial ', coverage]'
}

@test "self-test.yaml: ci-rollup runs unconditionally via if: always() (#337)" {
  # Without `if: always()` the rollup would skip when any upstream
  # need failed, masking the failure as SKIPPED — branch protection
  # treats SKIPPED as missing, so the merge gate would lift falsely.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'if: always()'
}

@test "self-test.yaml: ci-rollup verify step consumes every needs result (#337 + #376 + #377)" {
  # The shell verifier must inspect each upstream's ${{ needs.<job>.result }}
  # to translate the parallel job graph into a single pass/fail signal.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.actionlint.result'
  assert_output --partial 'needs.classify.result'
  assert_output --partial 'needs.shellcheck.result'
  assert_output --partial 'needs.hadolint.result'
  assert_output --partial 'needs.bats-unit.result'
  assert_output --partial 'needs.bats-integration.result'
  assert_output --partial 'needs.integration-e2e.result'
  assert_output --partial 'needs.behavioural.result'
}

@test "self-test.yaml: ci-rollup treats SKIPPED as pass for conditionally-gated jobs (#337 + #377)" {
  # Post-#377 every PR-check job has a job-level `if:` gate that may
  # cause it to skip on doc-only / non-behavioural PRs (the old
  # always-running `test` job no longer exists). The rollup must
  # collapse SKIPPED into pass for those, otherwise doc-only PRs
  # cannot merge.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'skipped'
}

@test "self-test.yaml: ci-rollup requires hard-mandatory jobs to be success (#337 + #377)" {
  # Post-#377 only actionlint + classify are hard-mandatory (the old
  # always-running `test` job no longer exists). SKIPPED there
  # indicates a workflow bug, not an intentional gate. Verified
  # indirectly by asserting the success comparison appears.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'success'
}

# ── shellcheck + hadolint dedicated jobs (#376) ───────────────────────

@test "self-test.yaml: declares shellcheck job (#376)" {
  run grep -E '^  shellcheck:' "${WF}"
  assert_success
}

@test "self-test.yaml: shellcheck job needs actionlint + classify and gates on code_changed (#376)" {
  # Same upstream pattern as the test/integration-e2e jobs so the
  # actionlint workflow-validator gate still fires first, and the
  # doc-only short-circuit still skips lint runs.
  run awk '/^  shellcheck:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: shellcheck job runs ci.sh --shellcheck-only on plain ubuntu-latest (#376)" {
  # Goal: ~30s feedback on a shellcheck regression. Plain ubuntu-latest
  # ships shellcheck pre-installed so no apt-install / no buildx /
  # no test-tools image is needed — keeps the job cold-startup cost
  # near zero.
  run awk '/^  shellcheck:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'runs-on: ubuntu-latest'
  assert_output --partial './script/ci/ci.sh --shellcheck-only'
  # No buildx setup / no docker pull / no compose run in this job.
  refute_output --partial 'docker/setup-buildx-action'
  refute_output --partial 'docker pull'
}

@test "self-test.yaml: declares hadolint job (#376)" {
  run grep -E '^  hadolint:' "${WF}"
  assert_success
}

@test "self-test.yaml: hadolint job needs actionlint + classify and gates on code_changed (#376)" {
  run awk '/^  hadolint:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: hadolint lints both template-owned Dockerfiles (#376)" {
  # template owns Dockerfile.example (the new-repo scaffold copied by
  # init.sh) + Dockerfile.test-tools (the alpine test image consumed by
  # downstream Dockerfile.example `FROM ${TEST_TOOLS_IMAGE}`). A
  # regression to either should surface here before downstream CI
  # fans out.
  run awk '/^  hadolint:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'hadolint/hadolint-action'
  assert_output --partial 'dockerfile: dockerfile/Dockerfile.example'
  assert_output --partial 'dockerfile: dockerfile/Dockerfile.test-tools'
  assert_output --partial 'config: .hadolint.yaml'
}

@test "self-test.yaml: release job gates on shellcheck + hadolint + bats-* + integration-e2e + behavioural before publishing a tag (#376 + #377)" {
  # release fires on tag push only, but if any PR-check job fails the
  # tag should NOT produce a Release. Post-#377 the `test` job is
  # replaced by `bats-unit` + `bats-integration` in this chain.
  run awk '/^  release:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [shellcheck, hadolint, bats-unit, bats-integration, integration-e2e, behavioural]'
}

# ── bats-unit + bats-integration + coverage jobs (#377) ───────────────

@test "self-test.yaml: declares bats-unit job (#377)" {
  run grep -E '^  bats-unit:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-unit declares strategy.matrix.shard with 1/2 + 2/2 + fail-fast: false (#377)" {
  # Default N=2 per the issue body. Each shard runs in parallel; the
  # matrix rollup propagates to needs.bats-unit.result. fail-fast: false
  # so a shard 1 failure doesn't cancel shard 2 (the maintainer wants
  # to see both shards' results).
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'fail-fast: false'
  assert_output --partial "shard: ['1/2', '2/2']"
}

@test "self-test.yaml: bats-unit invokes ci.sh --bats-unit-shard \${{ matrix.shard }} (#377)" {
  run awk '/^  bats-unit:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/ci/ci.sh --bats-unit-shard ${{ matrix.shard }}'
}

@test "self-test.yaml: declares bats-integration job (#377)" {
  run grep -E '^  bats-integration:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-integration invokes ci.sh --bats-integration (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/ci/ci.sh --bats-integration'
}

@test "self-test.yaml: declares coverage job (#377)" {
  run grep -E '^  coverage:' "${WF}"
  assert_success
}

@test "self-test.yaml: coverage gates on push to main only — never on PRs or tags (#377)" {
  # Pre-#377 kcov was wired but never exercised on PRs (the 2-5x
  # slowdown was too expensive). #377 makes that implicit policy
  # explicit. Restricting to `push && ref == refs/heads/main` ensures
  # a tag push (which sets ref to refs/tags/v...) doesn't trigger it
  # either.
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
}

@test "self-test.yaml: coverage invokes ci.sh --coverage + uploads to Codecov (#377)" {
  # Codecov upload step migrated here from the old test job. Token
  # source unchanged (\${{ secrets.CODECOV_TOKEN }}).
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/ci/ci.sh --coverage'
  assert_output --partial 'codecov/codecov-action@v6'
  assert_output --partial 'token: ${{ secrets.CODECOV_TOKEN }}'
  assert_output --partial 'directory: ./coverage'
}
