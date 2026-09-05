#!/usr/bin/env bats
#
# self_test_yaml_spec.bats — structural assertions for the
# `.github/workflows/self-test.yaml` workflow.
#
# Locks three cumulative invariants:
#
# 1. actionlint gate (original): an `actionlint` job runs
#    rhysd/actionlint via Docker against the workflows tree, and the
#    downstream jobs (test / acceptance / system) declare
#    `needs:` on actionlint so they cannot start until actionlint
#    passes.
#
# 2. P1 classifier + buildx GHA cache: a `classify` job emits
#    `code_changed` + `system_relevant` outputs based on PR diff
#    against the doc-only allow-list and system block-list; the
#    `test` job always runs (required check) but short-circuits to
#    SUCCESS on doc-only PRs; `acceptance` + `system` gate
#    via job-level `if:`. All three test-tools image builds use
#    docker/build-push-action with shared `scope=test-tools` GHA cache.
#
# 3. ci-rollup aggregator: a single `ci-rollup` job aggregates
#    [actionlint, classify, test, acceptance, system] under
#    `if: always`, treating SKIPPED as pass-equivalent for the two
#    conditionally-gated jobs (acceptance + system). Branch
#    protection requires only `ci-rollup`, so sub-jobs
#    shellcheck/hadolint, bats-unit/bats-integration) can join
#    its `needs:` without further branch-protection churn.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/self-test.yaml"
  [[ -f "${WF}" ]] || skip "self-test.yaml not at expected path"
}

# _render_run_names <run_id> <run_attempt>
#
# Prints the workflow-level `env:` block as `KEY: VALUE` lines with the
# run-identity expressions resolved to the given identity. This is what
# lets a spec compare TWO runs of the same commit -- the thing a
# single-tenant GitHub-hosted runner can never exhibit, because nothing
# there shares a machine. Comment lines and blank lines are dropped so the
# comparison is over values only.
_render_run_names() {
  local _run_id="${1}" _attempt="${2}"
  awk '/^env:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag' "${WF}" \
    | grep -E '^  [A-Za-z_][A-Za-z0-9_]*:' \
    | sed -e "s/\${{ *github\.run_id *}}/${_run_id}/g" \
          -e "s/\${{ *github\.run_attempt *}}/${_attempt}/g"
}

# ── actionlint job declared ────────────────────────────────────

@test "self-test.yaml: declares actionlint job" {
  run grep -E '^  actionlint:' "${WF}"
  assert_success
}

@test "self-test.yaml: actionlint job runs rhysd/actionlint via Docker with pinned tag" {
  run grep -E 'rhysd/actionlint:[0-9]+\.[0-9]+\.[0-9]+' "${WF}"
  assert_success
}

# ── classify job declared with both outputs ────────────────────

@test "self-test.yaml: declares classify job (#317)" {
  run grep -E '^  classify:' "${WF}"
  assert_success
}

@test "self-test.yaml: classify job declares code_changed output (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'code_changed: ${{ steps.diff.outputs.code_changed }}'
}

@test "self-test.yaml: classify job declares system_relevant output (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'system_relevant: ${{ steps.diff.outputs.system_relevant }}'
}

@test "self-test.yaml: classify uses doc-only allow-list 'doc/**' + 'README.md' + 'LICENSE' + 'CONTEXT.md' (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "':!doc/**'"
  assert_output --partial "':!README.md'"
  assert_output --partial "':!LICENSE'"
  # CONTEXT.md is tracked at the repo root (domain glossary, pure docs) but is
  # not under doc/, so without this it would trip code_changed=true and run the
  # full suite for a glossary-only change.
  assert_output --partial "':!CONTEXT.md'"
}

@test "self-test.yaml: classify uses system block-list entrypoint + compose + Dockerfile + wrappers + init/upgrade + workflows (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "'script/entrypoint.sh'"
  assert_output --partial "'compose.yaml'"
  assert_output --partial "'dist/dockerfile/Dockerfile'"
  assert_output --partial "'dockerfile/Dockerfile.test-tools'"
  assert_output --partial "'dist/script/docker/wrapper/build.sh'"
  assert_output --partial "'dist/script/docker/wrapper/run.sh'"
  assert_output --partial "'dist/script/docker/wrapper/exec.sh'"
  assert_output --partial "'dist/script/docker/wrapper/stop.sh'"
  assert_output --partial "'test/bats/system/**'"
  assert_output --partial "'dist/script/base/init.sh'"
  assert_output --partial "'dist/script/base/upgrade.sh'"
  assert_output --partial "'.github/workflows/**'"
}

@test "self-test.yaml: classify defaults code_changed/system_relevant to true on non-PR events (#317)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  # Both outputs branch to 'true' when EVENT_NAME != pull_request
  assert_output --partial '!= "pull_request"'
  assert_output --partial 'code_changed=true'
  assert_output --partial 'system_relevant=true'
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

# ── Downstream jobs gate on actionlint + classify ─

@test "self-test.yaml: bats-fragile job declares needs on actionlint AND classify (#677)" {
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: bats-integration job declares needs on actionlint AND classify (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: acceptance job declares needs on actionlint AND classify (#317)" {
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

@test "self-test.yaml: acceptance drives the container via just, not raw script/*.sh (#579)" {
  # A3: exercise the documented `just` entry points so a broken
  # container-ops justfile is caught (the user entry is just).
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'just docker build'
  assert_output --partial 'just docker run -d'
  assert_output --partial 'just docker exec'
  assert_output --partial 'just docker stop'
  refute_output --partial './script/build.sh'
  refute_output --partial './script/run.sh'
  refute_output --partial './script/stop.sh'
}

@test "self-test.yaml: acceptance asserts the runnability contract (#579)" {
  # A1: the job must ASSERT results, not just run steps. Covers the
  # five-point contract: configured user (not initial/root), container
  # still running, wired ENTRYPOINT, usable ~/work mount, and full
  # teardown (container + project network) on stop.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'USER_NAME'
  assert_output --partial '/entrypoint.sh'
  assert_output --partial '~/work'
  assert_output --partial '_default'
}

@test "self-test.yaml: acceptance exercises the remaining downstream just commands for real (#769)" {
  # Beyond the build/run -d/exec/stop core, the e2e must run each remaining
  # downstream verb with REAL execution (not --dry-run): the foreground run
  # variant, start (build + run), a real prune, an explicit setup re-run,
  # the base update check, and the base completions installer.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'just docker run id -un'
  assert_output --partial 'just docker start'
  assert_output --partial 'just docker prune --networks'
  assert_output --partial 'just docker setup apply'
  assert_output --partial 'just base update'
  assert_output --partial 'just base completions install'
}

@test "self-test.yaml: acceptance drives `just template new` end-to-end and asserts the consumer artifact (#785)" {
  # Coverage gap: new.sh is unit-tested in isolation,
  # but the `just template new <name>` RECIPE -- the template module
  # wiring + the consumer symlink chain that resolves it -- is exercised
  # nowhere. The acceptance job drives the REAL recipe in the scaffolded
  # consumer and asserts the produced consumer artifact
  # (script/local/<name>/ + its registration), i.e. from the consumer's
  # chair (UAT). Placed here, not as a bats spec, because a faithful
  # exercise needs the init.sh-scaffolded consumer this job already builds.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'just template new'
  assert_output --partial 'script/local/'
}

@test "self-test.yaml: acceptance documents setup-tui as intentionally out of scope (#769)" {
  # setup-tui is interactive (TUI); it stays covered by tui_spec and is
  # NOT driven for real in the e2e. The job must say so, and must not try
  # to invoke it.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'setup-tui'
  refute_output --partial 'just docker setup-tui'
}

@test "self-test.yaml: acceptance runs as a native-runner matrix over amd64 + arm64 (#603)" {
  # A2: verify the runnability contract on BOTH arches via native
  # runners (no QEMU), mirroring the platform->runner convention in
  # build-worker / publish-worker / release-test-tools.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'fail-fast: false'
  assert_output --partial 'linux/amd64'
  assert_output --partial 'ubuntu-latest'
  assert_output --partial 'linux/arm64'
  assert_output --partial 'ubuntu-24.04-arm'
}

@test "self-test.yaml: acceptance shards run on the matrix runner (#603)" {
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'runs-on: ${{ matrix.runner }}'
}

@test "self-test.yaml: acceptance Obtain step pulls the matrix platform, not a hardcoded amd64 (#603)" {
  # On the arm64 shard the test-tools:main pull must fetch the arm64
  # variant (test-tools is multi-arch); a hardcoded
  # linux/amd64 would resolve the wrong arch for the downstream
  # FROM ${TEST_TOOLS_IMAGE} build.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'docker pull --platform ${{ matrix.platform }}'
  refute_output --partial 'docker pull --platform linux/amd64'
}

@test "self-test.yaml: system job declares needs on actionlint AND classify (#317)" {
  run awk '/^  system:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
}

# ── Conditional gating ───────────────────────────────────

@test "self-test.yaml: bats-fragile job-level if: gates on code_changed (#677)" {
  # bats-fragile replaces the bats-unit matrix; same job-level skip so
  # ci-rollup's SKIPPED=pass rule keeps doc-only PRs merge-able.
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: bats-integration job-level if: gates on code_changed (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: no monolithic `test:` job remains after #377 split" {
  # a `test` job ran shellcheck + bats sequentially.
  # peeled shellcheck out, splits the rest into bats-unit
  # (matrix) + bats-integration. The old job is fully removed.
  run grep -E '^  test:' "${WF}"
  assert_failure
}

@test "self-test.yaml: acceptance job-level if: gates on code_changed (#317)" {
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: system job-level if: gates on system_relevant (#317 P3)" {
  # P1 shipped this with `code_changed` while the system_relevant
  # output was emitted-but-unused; P3 tightens to the narrower output so
  # PRs that change pure lint / unit-test paths (already covered by
  # `test`) don't burn the docker.sock-mounted compose run.
  run awk '/^  system:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.system_relevant == 'true'"
  refute_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: classify system block-list extends to setup.sh + i18n.sh + lib/** + prune.sh (#317 P3 gotcha-5)" {
  # setup.sh / lib/** drive .env + compose.yaml generation; i18n.sh
  # gates wrapper message output (smoke regressions surface in compose
  # logs); prune.sh is part of the wrapper family. All four indirectly
  # affect what the docker.sock-mounted compose service does, so they
  # must invalidate the system-skip optimization.
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "'dist/script/docker/wrapper/setup.sh'"
  assert_output --partial "'dist/script/docker/lib/i18n.sh'"
  assert_output --partial "'dist/script/docker/lib/**'"
  assert_output --partial "'dist/script/docker/wrapper/prune.sh'"
}

@test "self-test.yaml: classify system block-list covers the build_worker scripts + self-test fixture (#802)" {
  # The worker-selftest job consumes script/ci/build_worker/** (its YAML
  # plumbing / output contract) and builds test/fixtures/build-worker/**, so
  # a PR touching ONLY those -- without a .github/workflows/** change -- must
  # still flip system_relevant=true and re-run the System self-test instead
  # of skipping it.
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "'script/ci/build_worker/**'"
  assert_output --partial "'test/fixtures/build-worker/**'"
}

# ── buildx GHA cache on test-tools builds ────────────────

@test "self-test.yaml: bats-fragile job uses docker/build-push-action with GHA cache scope=test-tools (#677)" {
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
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

@test "self-test.yaml: system job uses docker/build-push-action with GHA cache scope=test-tools (#317)" {
  run awk '/^  system:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: docker/build-push-action@v6'
  assert_output --partial 'cache-from: type=gha,scope=test-tools'
  assert_output --partial 'cache-to: type=gha,scope=test-tools,mode=max'
}

# ── P2: Obtain step + rolling tag fallback ──────────────────────

@test "self-test.yaml: bats-fragile job has Obtain step pulling :main with 3-layer fallback (#317 P2 + #677)" {
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'docker pull --platform linux/amd64'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'docker tag'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: bats-fragile Build step is gated on steps.obtain.outputs.build_local == 'true' (#317 P2 + #677)" {
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "steps.obtain.outputs.build_local == 'true'"
}

@test "self-test.yaml: bats-integration job has Obtain step + 3-layer fallback (#317 P2 + #377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

@test "self-test.yaml: acceptance job has Obtain step + TEST_TOOLS_IMAGE env passthrough (#317 P2)" {
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  # The value itself now comes from the workflow-level env block every job
  # inherits, so build.sh still skips its internal test-tools build
  # without the job restating a literal tag of its own.
  assert_output --partial '${TEST_TOOLS_IMAGE}'
}

@test "self-test.yaml: acceptance job keeps buildx driver: docker for host-daemon visibility (#317 P2)" {
  # `./build.sh test` -> `docker compose build` whose `FROM
  # ${TEST_TOOLS_IMAGE}` resolves against the host docker daemon, not
  # against buildx's docker-container store. Keep the docker driver
  # so `docker pull :main` + `docker tag` land where the subsequent
  # build can see them. Trade-off: layer-3 fallback rebuild here is
  # uncached (GHA cache requires docker-container), accepted because
  # the hot path is `docker pull :main` and the cold path matches
  # pre-P2 cost.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'driver: docker'
}

@test "self-test.yaml: system job has Obtain step with 3-layer fallback (#317 P2)" {
  run awk '/^  system:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'Obtain the run-scoped test-tools image'
  assert_output --partial 'ghcr.io/ycpss91255-docker/test-tools:main'
  assert_output --partial 'build_local=true'
  assert_output --partial 'build_local=false'
}

# ── Probe-and-rebuild against a stale / racing :main ────────────

@test "self-test.yaml: bats-fragile Obtain probes the pulled :main for kcov and rebuilds on a missing tool (#697)" {
  # release-test-tools republishes :main on a Dockerfile.test-tools change
  # concurrently with this run, so a freshly-baked tool (kcov) can be
  # absent from the :main we just pulled. After the pull+tag, the obtain
  # step must PROBE for the required tools (kcov at minimum) and, on a
  # miss, fall back to building locally (build_local=true) instead of
  # running the suite against a stale image.
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'REQUIRED_TOOLS'
  assert_output --partial 'kcov'
  assert_output --partial 'command -v ${_tool}'
  assert_output --partial 'docker run --rm "${TEST_TOOLS_IMAGE}"'
}

@test "self-test.yaml: coverage Obtain probes the pulled :main for kcov and rebuilds on a missing tool (#697)" {
  # The coverage shards are the ones that actually race (kcov-not-found
  # fast-fail). Same probe-and-rebuild guard as bats-unit so a stale
  # :main self-corrects to a local rebuild.
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'REQUIRED_TOOLS'
  assert_output --partial 'kcov'
  assert_output --partial 'command -v ${_tool}'
  assert_output --partial 'docker run --rm "${TEST_TOOLS_IMAGE}"'
}

@test "self-test.yaml: probe REQUIRED_TOOLS list is easy to extend with the tools each run needs (#697)" {
  # The probe drives off a single REQUIRED_TOOLS list so a new baked
  # tool is covered by adding one word, not editing loop logic. kcov is
  # the racing one; bats / shellcheck / hadolint are also asserted.
  run grep 'REQUIRED_TOOLS=' "${WF}"
  assert_success
  assert_output --partial 'kcov'
  assert_output --partial 'bats'
  assert_output --partial 'shellcheck'
  assert_output --partial 'hadolint'
}

@test "self-test.yaml: every :main-pulling Obtain step carries the probe-and-rebuild guard (#697)" {
  # All five build_local-pattern obtain steps (hadolint, bats-fragile,
  # bats-integration, coverage, system) pull the same :main tag and
  # so race identically; each must probe + rebuild on a miss. One
  # REQUIRED_TOOLS line per such job.
  run grep -c 'REQUIRED_TOOLS=' "${WF}"
  assert_success
  assert_output '5'
}

@test "self-test.yaml: only classify fetches the base ref; image jobs read its testtools_changed output (#734)" {
  # The "PR changed Dockerfile.test-tools" decision is computed ONCE in
  # classify (its checkout is fetch-depth: 0, so the three-dot merge-base
  # resolves). The 6 image jobs (hadolint, bats-fragile, bats-integration,
  # coverage, acceptance, system) used to repeat that diff on a
  # shallow (fetch-depth: 1) checkout where no merge-base is reachable, so it
  # reported every file as changed and rebuilt the image on EVERY PR. They now
  # read needs.classify.outputs.testtools_changed instead -- so `git fetch
  # origin` appears exactly once (classify).
  run grep -c 'git fetch origin' "${WF}"
  assert_success
  assert_output '1'
}

@test "self-test.yaml: classify emits testtools_changed from a full-history diff (#734)" {
  run awk '/^  classify:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'testtools_changed:'
  assert_output --partial "-- 'dockerfile/Dockerfile.test-tools'"
}

@test "self-test.yaml: image jobs gate the rebuild on classify's testtools_changed (#734)" {
  # Every job that rebuilds test-tools keys off the single classify output,
  # not its own shallow-checkout diff. One env wiring per image job (6).
  run grep -c 'TESTTOOLS_CHANGED: ${{ needs.classify.outputs.testtools_changed }}' "${WF}"
  assert_success
  assert_output '6'
}

# ── self-maintaining shard-weights cache (time-balanced partition) ──

@test "self-test.yaml: coverage shards restore the shard-weights cache before partitioning (#733)" {
  # The greedy-LPT partition weights specs by recorded kcov seconds; each
  # shard restores the cached weights to the in-repo path _spec_weight reads
  # by default, so every shard computes the identical (exhaustive + disjoint)
  # partition. A cache miss degrades to the @test-count fallback.
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'actions/cache/restore'
  assert_output --partial 'test/bats/.shard-weights'
  assert_output --partial 'shard-weights-'
}

@test "self-test.yaml: coverage-gate merges shard timings into the weights file (#733)" {
  # coverage-gate already downloads every shard artifact (cobertura), which
  # now also carries each shard's timings.tsv; it merges them into one
  # weights file via the gate driver's --merge-timings subcommand.
  run awk '/^  coverage-gate:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial '--merge-timings'
  assert_output --partial 'timings.tsv'
}

@test "self-test.yaml: coverage-gate saves the shard-weights cache only on push (#733)" {
  # Only authoritative main-push runs refresh the cache (stable runners);
  # PR runs read-only so PR-runner noise never poisons the shared weights.
  run awk '/^  coverage-gate:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'actions/cache/save'
  assert_output --partial "github.event_name == 'push'"
}

# ── ci-rollup aggregator ───────────────────────────────────────

@test "self-test.yaml: declares ci-rollup job (#337)" {
  run grep -E '^  ci-rollup:' "${WF}"
  assert_success
}

@test "self-test.yaml: ci-rollup needs every sibling PR-check job incl coverage (#337 + #376 + #377 + #615 + #677)" {
  # The aggregator waits on actionlint + classify + shellcheck +
  # hadolint + bats-fragile + bats-integration + coverage + acceptance
  # + system so its result reflects every PR check. (ADR-8)
  # adds `coverage` to the list — it is now the primary unit gate (a
  # sharded kcov PR gate), so a kcov failure must block PR merge; the
  # bats-unit matrix is replaced with a single bats-fragile job.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify, shellcheck, doc-counts, lint-static, hadolint, bats-fragile, bats-integration, coverage, coverage-gate, acceptance, system, worker-selftest]'
}

@test "self-test.yaml: ci-rollup DOES need coverage now (#615 amends #377)" {
  # kept coverage out of the rollup (main-only metric); (ADR-8)
  # reverses that — the sharded kcov gate joins the rollup so a kcov
  # failure blocks merge. ci-rollup's SKIPPED=pass rule keeps doc-only
  # PRs merge-able even though coverage is now in `needs:`.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.coverage.result'
  assert_output --partial ', coverage,'
}

@test "self-test.yaml: ci-rollup runs unconditionally via if: always() (#337)" {
  # Without `if: always` the rollup would skip when any upstream
  # need failed, masking the failure as SKIPPED — branch protection
  # treats SKIPPED as missing, so the merge gate would lift falsely.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'if: always()'
}

@test "self-test.yaml: ci-rollup verify step consumes every needs result incl coverage (#337 + #376 + #377 + #615)" {
  # The shell verifier must inspect each upstream's ${{ needs.<job>.result }}
  # to translate the parallel job graph into a single pass/fail signal.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.actionlint.result'
  assert_output --partial 'needs.classify.result'
  assert_output --partial 'needs.shellcheck.result'
  assert_output --partial 'needs.hadolint.result'
  assert_output --partial 'needs.bats-fragile.result'
  assert_output --partial 'needs.bats-integration.result'
  assert_output --partial 'needs.coverage.result'
  assert_output --partial 'needs.coverage-gate.result'
  assert_output --partial 'needs.acceptance.result'
  assert_output --partial 'needs.system.result'
}

@test "self-test.yaml: ci-rollup treats SKIPPED as pass for conditionally-gated jobs (#337 + #377)" {
  # every PR-check job has a job-level `if:` gate that may
  # cause it to skip on doc-only / non-system PRs (the old
  # always-running `test` job no longer exists). The rollup must
  # collapse SKIPPED into pass for those, otherwise doc-only PRs
  # cannot merge.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'skipped'
}

@test "self-test.yaml: ci-rollup requires hard-mandatory jobs to be success (#337 + #377)" {
  # only actionlint + classify are hard-mandatory (the old
  # always-running `test` job no longer exists). SKIPPED there
  # indicates a workflow bug, not an intentional gate. Verified
  # indirectly by asserting the success comparison appears.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'success'
}

# ── System-level build-worker self-test ────────────────────────

@test "self-test.yaml: declares worker-selftest job that really invokes the shared build worker (#802)" {
  # System level (ADR-00000018): actually run base's OWN build-gate
  # (build-worker.yaml) end-to-end via a local reusable-workflow call, so a
  # semantic break in the worker turns this job red instead of surfacing
  # only when a downstream runs it in production. The `uses:` is the LOCAL
  # reusable-workflow reference (must stay actionlint-clean).
  run grep -E '^  worker-selftest:' "${WF}"
  assert_success
  run awk '/^  worker-selftest:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'uses: ./.github/workflows/build-worker.yaml'
}

@test "self-test.yaml: worker-selftest drives the worker with a minimal fixture repo (#802)" {
  # The point is to exercise the orchestration, not build a real image: the
  # worker is pointed at the trivial alpine fixture
  # (test/fixtures/build-worker/Dockerfile) via context_path, with the
  # required image_name input supplied.
  run awk '/^  worker-selftest:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'image_name: worker-selftest'
  assert_output --partial 'context_path: test/fixtures/build-worker'
}

@test "self-test.yaml: worker-selftest needs actionlint + classify and gates on system_relevant (#802)" {
  # Same upstream pattern as the system job: actionlint fires first, and the
  # narrower system_relevant output skips it on pure lint / unit / doc PRs
  # (any change to .github/workflows/** re-runs it via the block-list).
  run awk '/^  worker-selftest:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.system_relevant == 'true'"
}

@test "self-test.yaml: ci-rollup consumes worker-selftest as a SKIPPED-tolerant gate (#802)" {
  # The System self-test joins the aggregator branch protection keys on, in
  # the success-or-skipped bucket (it skips on non-system PRs). ci-rollup
  # must list it in needs: and inspect its result.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.worker-selftest.result'
  assert_output --partial ', worker-selftest]'
}

@test "self-test.yaml: release gate requires worker-selftest before publishing a tag (#802)" {
  # Acceptance criterion: the System job is part of the required gate before
  # a tag. release fires on tag push only; if the worker self-test fails the
  # tag must NOT produce a Release.
  run awk '/^  release:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'worker-selftest]'
}

# ── shellcheck + hadolint dedicated jobs ───────────────────────

@test "self-test.yaml: declares shellcheck job (#376)" {
  run grep -E '^  shellcheck:' "${WF}"
  assert_success
}

@test "self-test.yaml: shellcheck job needs actionlint + classify and gates on code_changed (#376)" {
  # Same upstream pattern as the test/acceptance jobs so the
  # actionlint workflow-validator gate still fires first, and the
  # doc-only short-circuit still skips lint runs.
  run awk '/^  shellcheck:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
}

@test "self-test.yaml: shellcheck job runs test.sh --shellcheck-only on plain ubuntu-latest (#376)" {
  # Goal: ~30s feedback on a shellcheck regression. Plain ubuntu-latest
  # ships shellcheck pre-installed so no apt-install / no buildx /
  # no test-tools image is needed — keeps the job cold-startup cost
  # near zero.
  run awk '/^  shellcheck:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'runs-on: ubuntu-latest'
  assert_output --partial './script/test/test.sh --shellcheck-only'
  # No buildx setup / no docker pull / no compose run in this job.
  refute_output --partial 'docker/setup-buildx-action'
  refute_output --partial 'docker pull'
}

@test "self-test.yaml: declares doc-counts job (#864)" {
  run grep -E '^  doc-counts:' "${WF}"
  assert_success
}

@test "self-test.yaml: doc-counts job runs test.sh --doc-counts-only on plain ubuntu-latest (#864)" {
  # The generated doc/test catalogue has a gate, and it lives in the
  # `just test` lint phase -- which NO CI job runs: the lint jobs narrow to
  # one tool and every bats job sets BATS_ONLY=1. This job is the CI half.
  # Pure bash + diff, so no buildx / test-tools image, same cold-start cost
  # as the shellcheck job.
  run awk '/^  doc-counts:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial 'runs-on: ubuntu-latest'
  assert_output --partial './script/test/test.sh --doc-counts-only'
  refute_output --partial 'docker/setup-buildx-action'
}

@test "self-test.yaml: doc-counts carries NO code_changed gate (#864)" {
  # Deliberately ungated, unlike its sibling lint jobs: the catalogue can
  # be broken by hand-editing doc/test/*.md, which classify scores as a
  # doc-only change. A code_changed gate would skip the gate on exactly
  # the PR that hand-edited a count.
  run awk '/^  doc-counts:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  # Non-vacuity: an absent job yields an empty block, against which the
  # refute below would pass while asserting nothing.
  assert_output --partial './script/test/test.sh --doc-counts-only'
  # The gate form its sibling lint jobs use. Matching on that rather than
  # the bare word keeps the job's own comment (which explains WHY it is
  # ungated, and so names the gate) from satisfying the refutation.
  refute_output --partial 'if: needs.classify.outputs'
}

@test "self-test.yaml: ci-rollup treats doc-counts as hard-mandatory, not SKIPPED-tolerant (#864)" {
  # It has no `if:` gate, so SKIPPED means a workflow bug. It must sit in
  # the success-only loop with actionlint / classify, never in the
  # skipped-tolerated one. The success-only loop is the one whose body
  # compares against "success" alone; grep the two lines following the
  # ACTIONLINT/CLASSIFY loop header to see what else it iterates.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.doc-counts.result'

  run grep -A2 'for r in "${ACTIONLINT_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'DOC_COUNTS_RESULT'
}

# ── lint-static matrix (the rest of the lint phase) ────────────

@test "self-test.yaml: declares lint-static job (#866)" {
  run grep -E '^  lint-static:' "${WF}"
  assert_success
}

@test "self-test.yaml: lint-static runs one matrix entry per host-direct lint on a plain runner (#866)" {
  # The lint phase runs the static lints no CI job ran: the issue-ref
  # comment lint, the ADR-numbering lint, the stale
  # config/docker/setup.conf path lint, the localized README sync lint and
  # the hardcoded home path lint.
  # Each is pure bash over the checkout, so a plain ubuntu-latest runner
  # can call it host-direct -- no buildx, no test-tools image. One matrix
  # entry each so the checks list names WHICH lint failed.
  run awk '/^  lint-static:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [actionlint, classify]'
  assert_output --partial 'runs-on: ubuntu-latest'
  # fail-fast off: one failing lint must not cancel the sibling entries,
  # or a branch fixes them one round-trip at a time.
  assert_output --partial 'fail-fast: false'
  assert_output --partial '- issueref'
  assert_output --partial '- adr-numbering'
  assert_output --partial '- stale-setup-conf'
  assert_output --partial '- readme-sync'
  # The hardcoded-home-path lint joined the same matrix: it reads the
  # shipped image tree, so a plain runner can call it host-direct too.
  assert_output --partial '- home-literal'
  # Same for the unguarded-BASH_SOURCE lint: pure bash over dist/ + script/.
  assert_output --partial '- bash-source-guard'
  # And for the early-closing-reader pipeline lint, same trees, same shape.
  assert_output --partial '- early-close-reader'
  assert_output --partial './script/test/test.sh'
  refute_output --partial 'docker/setup-buildx-action'
  refute_output --partial 'docker pull'
}

@test "self-test.yaml: lint-static carries NO code_changed gate (#866)" {
  # Ungated on purpose, like doc-counts. Two of the matrix entries
  # are breakable by a change classify scores as doc-only: the
  # ADR-numbering lint reads doc/adr/ filenames, and the localized README
  # sync lint reads README.md + doc/readme/**. Gating on code_changed
  # would skip them on exactly the PR they exist to catch. A matrix
  # shares ONE job-level `if:`, so the gate would be all-or-nothing
  # anyway.
  run awk '/^  lint-static:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  # Non-vacuity: an absent job yields an empty block, against which the
  # refute below would pass while asserting nothing.
  assert_output --partial '- readme-sync'
  refute_output --partial 'if: needs.classify.outputs'
}

@test "self-test.yaml: ci-rollup treats lint-static as hard-mandatory, not SKIPPED-tolerant (#866)" {
  # No `if:` gate, so SKIPPED means a workflow bug -- same contract as
  # doc-counts. It must sit in the success-only loop, never the
  # skipped-tolerated one.
  run awk '/^  ci-rollup:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs.lint-static.result'

  run grep -A2 'for r in "${ACTIONLINT_RESULT}"' "${WF}"
  assert_success
  assert_output --partial 'LINT_STATIC_RESULT'
}

@test "self-test.yaml: every lint the just test lint phase runs has a CI join (#866)" {
  # The anti-rot guard, and the answer to "which lints are CI-enforced":
  # script/test/test.sh's _LINT_TOOLS table is the one list of tools the
  # lint phase runs, and every entry in it must be named by a CI job --
  # a host-direct primitive (--<tool>-only), the in-container hadolint
  # job (--lint --hadolint), or a lint-static matrix entry (- <tool>).
  # Adding a lint to the phase without giving it a CI join fails HERE,
  # instead of quietly shipping a local-only rule.
  #
  # The claim is STATIC -- a table literal in one file versus job names
  # in another -- so the table is PARSED, never sourced. Sourcing
  # test.sh dragged in the whole lib chain, which reads BASH_SOURCE
  # unguarded; under the kcov-instrumented bash of the coverage shard
  # BASH_SOURCE is not populated for a sourced file, so the source
  # aborted and its stderr got parsed as if it were a lint name (the
  # same failure that hit setup_tui.sh). Parsing keeps the guard
  # running under coverage instead of skipping it there.
  local _test_sh="/source/script/test/test.sh"
  [[ -f "${_test_sh}" ]] || skip "test.sh not at expected path"
  run awk '
    /^readonly _LINT_TOOLS=\(/ { inside = 1; next }
    inside && /^\)/            { inside = 0 }
    inside {
      sub(/#.*/, "")
      gsub(/[[:space:]]+/, "")
      if ($0 != "") print
    }
  ' "${_test_sh}"
  assert_success

  local -a _tools=()
  mapfile -t _tools <<<"${output}"
  # Non-vacuity: an empty / truncated table would make the loop below
  # assert nothing at all, which is the exact failure mode this test
  # exists to prevent. Pin both the size and the four lints this issue
  # wired.
  [ "${#_tools[@]}" -ge 11 ] \
    || fail "_LINT_TOOLS yielded ${#_tools[@]} entries; the table did not parse"
  local _t
  for _t in issueref adr-numbering stale-setup-conf readme-sync home-literal \
    bash-source-guard i18n-orphan early-close-reader; do
    printf '%s\n' "${_tools[@]}" | grep -qx -- "${_t}" \
      || fail "_LINT_TOOLS does not list '${_t}'"
  done

  for _t in "${_tools[@]}"; do
    grep -qE -- "--${_t}-only|--lint --${_t}|^ +- ${_t}\$" "${WF}" \
      || fail "lint '${_t}' runs in the just test lint phase but NO job in self-test.yaml runs it -- it would gate nothing on a PR"
  done
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

@test "self-test.yaml: hadolint job runs the driver, not the hadolint-action (#650)" {
  # ADR-00000011 local==CI single source: the hadolint job no
  # longer calls hadolint/hadolint-action with an inline Dockerfile +
  # config list (which would drift from what `just test` lints). It runs
  # the SAME driver (script/test/drivers/hadolint.sh via `test.sh --lint
  # --hadolint`) inside the test-tools image, so the Dockerfile list +
  # config live in ONE place (the driver) for both local + CI.
  run awk '/^  hadolint:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/test/test.sh --lint --hadolint'
  # The driver image (test-tools) is obtained like the bats jobs.
  assert_output --partial 'Obtain the run-scoped test-tools image'
  # The inline action + its file/config args are gone (driver owns them).
  refute_output --partial 'hadolint/hadolint-action'
}

@test "self-test.yaml: release job gates on shellcheck + hadolint + bats-fragile + bats-integration + coverage + acceptance + system before publishing a tag (#376 + #377 + #677)" {
  # release fires on tag push only, but if any PR-check job fails the
  # tag should NOT produce a Release. The bats-unit matrix is replaced
  # with `bats-fragile` and `coverage` (now the primary unit gate) joins
  # the release chain.
  run awk '/^  release:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [shellcheck, doc-counts, lint-static, hadolint, bats-fragile, bats-integration, coverage, acceptance, system, worker-selftest]'
}

# ── bats-unit + bats-integration + coverage jobs ───────────────

@test "self-test.yaml: declares bats-fragile job (#677)" {
  run grep -E '^  bats-fragile:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-fragile is a single job (no shard matrix) (#677)" {
  # The 4-shard bats-unit matrix (which double-ran the same specs the
  # coverage matrix runs) is replaced with ONE plain job running only the
  # kcov-fragile specs the coverage matrix skips. No strategy.matrix here.
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  refute_output --partial 'strategy:'
  refute_output --partial 'matrix:'
  refute_output --partial 'shard:'
}

@test "self-test.yaml: bats-fragile invokes test.sh --bats-fragile (#677)" {
  run awk '/^  bats-fragile:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/test/test.sh --bats-fragile'
}

@test "self-test.yaml: no bats-unit shard matrix remains after #677" {
  # The double-run bats-unit matrix is fully removed; coverage is the
  # primary unit gate and bats-fragile covers the kcov-skipped delta.
  run grep -E '^  bats-unit:' "${WF}"
  assert_failure
}

@test "self-test.yaml: declares bats-integration job (#377)" {
  run grep -E '^  bats-integration:' "${WF}"
  assert_success
}

@test "self-test.yaml: bats-integration invokes test.sh --bats-integration (#377)" {
  run awk '/^  bats-integration:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/test/test.sh --bats-integration'
}

@test "self-test.yaml: declares coverage job (#377)" {
  run grep -E '^  coverage:' "${WF}"
  assert_success
}

@test "self-test.yaml: coverage now runs on PRs (gated on code_changed), not main-only (#615 amends #377)" {
  # restricted kcov to push-to-main (the serial 8-12min job was too
  # expensive for PRs). shards it so a PR shard is in the bats-unit
  # ballpark, and gates it on the same `code_changed` output as the other
  # PR-check jobs so PR coverage data exists for the gate. The old
  # push&&main-only `if:` is gone.
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
  refute_output --partial "if: github.event_name == 'push' && github.ref == 'refs/heads/main'"
}

@test "self-test.yaml: coverage runs as the primary kcov unit gate over a DYNAMIC shard matrix (#615 + #677 + #725)" {
  # Sharded kcov is the PRIMARY unit gate. The shard TOTAL is dynamic:
  # the matrix is built from compute-shards' JSON output via fromJSON, not a
  # hardcoded 1/4..4/4 list. fail-fast: false so one shard's failure doesn't
  # cancel the rest.
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'fail-fast: false'
  assert_output --partial 'shard: ${{ fromJSON(needs.compute-shards.outputs.shards) }}'
  refute_output --partial "shard: ['1/4', '2/4', '3/4', '4/4']"
  assert_output --partial 'compute-shards'
}

@test "self-test.yaml: compute-shards job emits a dynamic shard array from vars.CI_SHARDS (default 8, clamped) (#725)" {
  run awk '/^  compute-shards:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'shards: ${{ steps.gen.outputs.shards }}'
  assert_output --partial 'CI_SHARDS: ${{ vars.CI_SHARDS }}'
  assert_output --partial 'n="${CI_SHARDS:-8}"'
  assert_output --partial 'n > 12'
  assert_output --partial 'GITHUB_OUTPUT'
}

@test "self-test.yaml: coverage invokes test.sh --coverage-shard + uploads each shard report as a CI artifact (#710)" {
  # The kcov run is per-shard (--coverage-shard); each shard uploads its
  # kcov output (HTML + cobertura) as a CI artifact keyed by the shard
  # index, for the self-hosted coverage-gate to merge locally. No external
  # coverage-SaaS upload (the SaaS path is superseded by coverage_gate.sh).
  run awk '/^  coverage:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial './script/test/test.sh --coverage-shard ${{ matrix.shard }}'
  assert_output --partial 'actions/upload-artifact@v7'
  assert_output --partial 'name: coverage-shard-${{ strategy.job-index }}'
  assert_output --partial 'path: ./coverage'
}

@test "self-test.yaml: NO codecov reference anywhere in the workflow (#710)" {
  # The whole Codecov path (action, token, directory, per-shard flag) is
  # removed; coverage merge + gate is now self-hosted via coverage_gate.sh.
  run grep -i 'codecov' "${WF}"
  assert_failure
}

@test "self-test.yaml: declares a coverage-gate job that runs the self-hosted floor gate (#710)" {
  # The self-hosted coverage-floor gate: downloads every shard artifact
  # and runs coverage_gate.sh to merge the per-shard cobertura reports
  # into one line-weighted project rate, failing below COVERAGE_MIN. Joins
  # ci-rollup so the floor gates merge with no external SaaS.
  run grep -E '^  coverage-gate:' "${WF}"
  assert_success
  run awk '/^  coverage-gate:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'needs: [classify, coverage]'
  assert_output --partial "if: needs.classify.outputs.code_changed == 'true'"
  assert_output --partial 'actions/download-artifact@v8'
  assert_output --partial 'pattern: coverage-shard-*'
  assert_output --partial 'script/test/drivers/coverage_gate.sh'
}

@test "self-test.yaml: the system job supplies HOST_UID / HOST_GID to its bare compose run (#895)" {
  # The system job is the only one that drives `docker compose run`
  # directly instead of through test.sh, so it is the only one that has to
  # put the runner's ids in the environment compose interpolates. Without
  # them the service definition refuses to resolve.
  run awk '/^  system:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'HOST_UID="$(id -u)"'
  assert_output --partial 'HOST_GID="$(id -g)"'
  assert_output --partial 'docker compose run --rm ci-system'
}

# ── Run-scoped names ───────────────────────────────────────────
#
# The assertions below are made against the NAMING, not against an
# environment. `runs-on: ubuntu-latest` gives every job a fresh
# single-tenant VM, so no CI run can currently exhibit the collision these
# lock out; a test that passed only because jobs are isolated would prove
# nothing. Two renderings that differ ONLY by run identity are compared
# instead: if any name comes out equal, two jobs sharing a host share it.

@test "self-test.yaml: declares a workflow-level env block carrying the run identity (#900)" {
  run awk '/^env:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'github.run_id'
  assert_output --partial 'github.run_attempt'
}

@test "self-test.yaml: every name the workflow creates differs between two concurrent runs (#900)" {
  local -a _a=() _b=()
  mapfile -t _a < <(_render_run_names 1001 1)
  mapfile -t _b < <(_render_run_names 1002 1)
  # test-tools tag + compose project + the key itself, at minimum.
  [ "${#_a[@]}" -ge 3 ] \
    || fail "expected at least 3 run-scoped names in the workflow env block, got ${#_a[@]}"
  [ "${#_a[@]}" -eq "${#_b[@]}" ]
  local _i
  for _i in "${!_a[@]}"; do
    [ "${_a[${_i}]}" != "${_b[${_i}]}" ] \
      || fail "name is CONSTANT across concurrent runs: ${_a[${_i}]}"
  done
}

@test "self-test.yaml: every name also differs between two attempts of ONE run (#900)" {
  # A re-run repeats the commit SHA and the checkout path, so a name keyed
  # to either is identical to the attempt that just left the leftovers
  # behind -- exactly when a stale artifact would be reused. run_attempt is
  # what separates them.
  local -a _a=() _b=()
  mapfile -t _a < <(_render_run_names 1001 1)
  mapfile -t _b < <(_render_run_names 1001 2)
  [ "${#_a[@]}" -ge 3 ]
  local _i
  for _i in "${!_a[@]}"; do
    [ "${_a[${_i}]}" != "${_b[${_i}]}" ] \
      || fail "name is CONSTANT across a re-run: ${_a[${_i}]}"
  done
}

@test "self-test.yaml: run identity is not a timestamp and not the commit SHA (#900)" {
  # A timestamp collides for two jobs that start in the same second and
  # cannot be traced back to a run; github.sha is shared by every job of a
  # run AND identical across re-runs. run_id + run_attempt are both in the
  # Actions UI, so a leftover names the run that made it.
  run awk '/^env:/{flag=1; next} /^[a-zA-Z]/{flag=0} flag' "${WF}"
  assert_success
  refute_output --partial 'github.sha'
  refute_output --partial 'date +'
}

@test "self-test.yaml: the run-scoped names come from ONE place, not per job (#900)" {
  # The fixed `test-tools:local` literal is what two jobs on one host used
  # to write over each other. No job may reintroduce it, and no job may
  # spell its own variant of the run-scoped tag either -- the workflow-level
  # env block is the single source every job inherits.
  run grep -n 'test-tools:local' "${WF}"
  assert_failure
  run grep -cE '^ +TEST_TOOLS_IMAGE:' "${WF}"
  assert_output '1'
  run grep -cE '^ +COMPOSE_PROJECT_NAME:' "${WF}"
  assert_output '1'
}

@test "self-test.yaml: the test-tools image every job builds carries the ownership label (#900)" {
  # The loaded test-tools image is the one artifact compose does not own,
  # so cleanup cannot ask compose "whose is this". Every path that puts it
  # in the runner's daemon -- the cached build, the inline build, the
  # pulled-and-retagged hot path -- stamps the run identity on it.
  run grep -c 'base.ci.run' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected the ownership label on every test-tools provisioning path, found ${output}"
}

@test "self-test.yaml: the acceptance scaffold is keyed to the run (#900)" {
  # The scaffolded consumer's directory basename becomes IMAGE_NAME, which
  # is what the image tag, the container name and the compose project are
  # all built from -- so one unique directory name makes all three unique.
  run awk '/^  acceptance:/{flag=1; next} /^  [a-z]/{flag=0} flag' "${WF}"
  assert_success
  assert_output --partial 'REPO_NAME="e2e_test-ci-${CI_RUN_KEY}"'
  # The throwaway probe network `just docker prune` is asserted against is
  # created by name: two concurrent runs creating one fixed name is a hard
  # failure ("network with name ... already exists"), not a silent share.
  # The `ci-` infix is not decoration -- it is the marker the age-based
  # backstop matches on, so every CI-created name has to carry it.
  assert_output --partial 'e2e_prune_probe-ci-${CI_RUN_KEY}'
  # Every leftover assertion is scoped to THIS run's artifacts; grepping
  # the bare `e2e_test` would read a concurrent run's container as this
  # run's leak.
  refute_output --partial "grep -q 'e2e_test'"
}

# ── Run-scoped cleanup ─────────────────────────────────────────
#
# A unique name per run means leftovers ACCUMULATE on a long-lived host
# instead of dying with the VM. Two layers cover each other: an exact
# per-run teardown that cannot run when the runner is killed, and an
# age-based sweep that cannot be precise. Both are ownership-scoped --
# the naive `docker system prune -a` would destroy a concurrent job's
# in-flight cache, which is the very thing the unique naming protects.

@test "self-test.yaml: every job that puts an image in the host daemon tears it down (#900)" {
  # The six docker-using jobs: hadolint, bats-fragile, bats-integration,
  # coverage, acceptance, system. Each one loads a test-tools image into
  # the runner's daemon, so each one has to hand it back.
  run grep -c 'script/ci/reclaim.sh' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected a reclaim step in every docker-using job, found ${output}"
  # Every reclaim step names the run it is allowed to remove.
  run grep -c -- '--run "\${CI_RUN_KEY}"' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected every reclaim step to be scoped to CI_RUN_KEY, found ${output}"
}

@test "self-test.yaml: teardown runs on failure too, not just on success (#900)" {
  # A job that fails halfway is the job most likely to have left something
  # behind, so the teardown cannot be conditional on the job passing.
  run grep -B2 'script/ci/reclaim.sh' "${WF}"
  assert_success
  assert_output --partial 'if: always()'
}

@test "self-test.yaml: cleanup is ownership-scoped, never a blanket prune (#900)" {
  # On a shared host `docker system prune -a` destroys a CONCURRENT job's
  # build cache and images. The naive fix for the leftover problem breaks
  # the thing the uniqueness was protecting.
  #
  # Comment lines are stripped first: the prohibition is on the command a
  # job RUNS, and the rationale for it necessarily names the command it
  # rules out.
  run bash -c "grep -vE '^[[:space:]]*#' '${WF}' \
    | grep -E 'docker system prune|image prune -a|docker volume prune'"
  assert_failure
}

@test "self-test.yaml: the age-based backstop uses a CI window, not the local defaults (#900)" {
  # prune.sh's defaults (networks 10m, images 24h) are tuned to a laptop.
  # A CI window has a hard floor instead: an artifact belonging to a LIVE
  # run can be as old as the longest a job may run, so anything shorter
  # than that ceiling deletes work in flight.
  run grep -c -- '--stale 12h' "${WF}"
  assert_success
  [ "${output}" -ge 6 ] \
    || fail "expected the CI-specific stale window on every reclaim step, found ${output}"
}
