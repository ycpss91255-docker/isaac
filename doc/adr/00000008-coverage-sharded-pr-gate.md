# Shard kcov coverage + promote it to an enforced PR gate

> Serves: PRD invariant 7 (rigorous test bar) -- the coverage gate; a
> swappable mechanism, not the invariant.

- **Date:** 2026-06-24
- **Status:** Accepted
- **Amends:** #377 (which made coverage a non-gating, main-push-only
  metric)
- **Relates to:** #615, #613 (kcov env bugs fixed first so the gate is
  not flaky), ADR-00000004 / ADR-00000012 (test layout the shard
  partition walks)

## Context

#377 parallelised the normal test path (GNU `parallel --jobs N` inside
`_run_bats`; `bats-unit` split into a 1/N CI matrix) but left the
**coverage path fully serial**: a single
`kcov ... bats test/bats/unit/ test/bats/integration/` with no `--jobs`
and no matrix shard. The ~8-12 min coverage runtime was therefore
"serial x kcov" (kcov instruments every line and slows bats 2-5x), not
an inherent kcov floor.

#377 sidestepped that cost by making coverage **main-push-only** and
**explicitly non-gating** ("metric, not a gate"):

- `coverage` ran only on `push && ref == refs/heads/main`.
- It was deliberately kept out of `ci-rollup`'s `needs:`.
- Branch protection required only `ci-rollup`; the `codecov/project`
  status was not a required check; kcov never ran on PRs, so there was no
  PR coverage data to check.

Net effect: neither a coverage regression nor a kcov failure could block
any merge. #613 then found and fixed real kcov-env test bugs that had
been making the coverage job intermittently red — clearing the
precondition for letting coverage gate at all.

## Decision

### 1. Shard the kcov run across a CI matrix mirroring `bats-unit`

The `coverage` job becomes a `strategy.matrix` of kcov shards
(`shard: ['1/4', '2/4', '3/4', '4/4']`, `fail-fast: false`) that mirrors
the `bats-unit` matrix. Both matrices select their slice through one
shared primitive, `_shard_unit_files <n>/<total>` (round-robin over
`find test/bats/unit -name '*_spec.bats' | sort`), so coverage shard *k*
kcov's the **identical unit slice** the unit-test matrix runs. The 87
integration specs run on the **last shard only** (not every shard), so
no slice is kcov'd more than once.

Plumbing: a new `test.sh --coverage-shard N/T` flag sets coverage mode
and forwards `COVERAGE_SHARD` into the coverage container, where
`_run_coverage <n>/<total>` wraps kcov over that slice. Bare
`test.sh --coverage` (and `just test coverage`) keeps the full-suite path
for local / release use; `just test coverage 1/4` runs a single shard
locally. The coverage path also **skips the lint phase** unconditionally
(lint is measured by the dedicated lint jobs, so running it once per
coverage shard would be wasted work).

> Amendment (#686): the coverage container is no longer the upstream
> `kcov/kcov` Debian image — kcov is now source-built into the shared
> Alpine `test-tools` image, so the coverage matrix runs on the same
> pre-baked image as `bats-unit` (no per-shard apt-install). This is an
> environment change only; the sharded-matrix + `codecov/project` gate
> MECHANISM this ADR records is unchanged.

Per-shard wall-time lands in the `bats-unit` ballpark (~one shard,
~170s) and runs in parallel with `bats-unit`, so the added PR
critical-path cost is roughly one shard, not the old 8-12 min serial job.

### 2. Merge the shard reports via Codecov

Each shard uploads its partial report (`directory: ./coverage`) under a
distinct `flags: coverage-shard-<index>`. Codecov natively merges
multiple uploads for a commit ("Found N coverage files to report") into
one project coverage figure, so where a slice runs in the matrix does not
affect the merged total — only that every slice runs exactly once
(guaranteed by the exhaustive + disjoint round-robin partition).
`fail_ci_if_error: false` stays: an upload transport hiccup must not fail
a shard; the merge tolerates a missing shard and the *gate* is the
Codecov status, not the upload step.

### 3. Promote coverage to an enforced PR gate

- The `coverage` job now gates on
  `needs.classify.outputs.code_changed == 'true'` (the same output as the
  other PR-check jobs), so it **runs on PRs**, producing PR coverage
  data. The old `if: push && ref == refs/heads/main` is removed.
- `coverage` joins `ci-rollup`'s `needs:` (now 9 jobs), and the rollup
  verifier consumes `needs.coverage.result` with SKIPPED-as-pass for
  doc-only PRs. A **kcov test failure** therefore fails the matrix,
  fails `ci-rollup`, and blocks merge.
- A **coverage regression** is enforced via the `codecov/project` status
  configured in `.codecov.yaml` (`informational: false`), added as a
  required branch-protection check alongside `ci-rollup`.

### 4. Threshold choice

`.codecov.yaml`:

```yaml
coverage:
  status:
    project:
      default: { target: auto, threshold: 1%, informational: false }
    patch:
      default: { target: auto, threshold: 1%, informational: false }
```

- **project** `target: auto` compares against the PR base; `threshold:
  1%` absorbs kcov line-hit noise (the #613 fixes removed the spurious
  reds that previously plagued this path). `informational: false` makes
  the status fail on a real drop so branch protection can block.
- **patch** (new-code coverage) is decided explicitly as `target: auto`
  + `threshold: 1%` rather than a fixed percentage (e.g. 80%). The
  codebase has many intentionally-uncovered bash branches (`case ;;`
  arms, `/lint` fallback blocks, child-bash guards); a fixed patch target
  would make refactor PRs flaky — the exact #613-class brittleness this
  gate must avoid. `auto` keeps the patch status honest (new code should
  not be markedly less covered than the project) without false reds.

## Consequences

- A coverage regression or a kcov failure now blocks PR merge, raising
  merge confidence; this reverses #377's "coverage is a non-gating
  main-only metric" posture.
- GHA-minute cost rises: kcov now runs on every code-touching PR as a
  4-shard matrix instead of only on main push. Accepted — the per-shard
  wall-time is in the `bats-unit` ballpark and runs in parallel, so PR
  feedback latency barely moves while merge confidence improves.
- The coverage matrix and the unit matrix are now coupled through
  `_shard_unit_files`: changing one shard count without the other would
  desynchronise the slices. Documented in the helper; both default to 4.
- The gate's robustness depends on the #613 kcov-env fixes staying in
  place; if kcov flakiness returns, raise the project `threshold` before
  reverting the gate.

## Alternatives

- **Keep coverage main-only + non-gating (#377 status quo).** Rejected:
  it leaves coverage regressions and kcov breakage invisible until after
  merge; #613 already cleared the flakiness that justified the
  non-gating posture.
- **Single (un-sharded) coverage job on PRs.** Rejected: the 8-12 min
  serial kcov run would dominate PR wall-time, the cost #377 set out to
  avoid; sharding brings it down to ~one bats-unit shard.
- **A fixed patch target (e.g. 80%).** Rejected: the intentionally
  uncovered bash branches make a hard per-diff percentage flaky for
  refactor PRs; `target: auto` tracks the project rate instead.

## Amendment (#710): self-hosted, GitLab-portable gate; Codecov removed

- **Date:** 2026-06-25
- **Status:** Accepted (supersedes the Codecov merge + `codecov/project`
  status decided in sections 2 and 3 above)
- **Resolves:** #709 (`codecov/project` is Pro-only, so the project gate
  never worked on the free plan). **Relates:** #678 (no Codecov status to
  wire -- the gate moves into `ci-rollup` directly), #686, #677.

### Context

This repo is being imported into the company GitLab, where Codecov is
unavailable and uploading coverage to an external SaaS is data leakage.
Separately, #709 found `codecov/project` is a Pro-only status, so the
section-3 branch-protection gate never actually enforced anything on the
free plan. Both push the same way: drop Codecov entirely and enforce the
coverage floor locally, with a mechanism that ports to GitLab CI
unchanged.

### Decision

1. **Remove Codecov.** The `codecov/codecov-action` upload step, the
   `CODECOV_TOKEN` usage, the no-op `flags: coverage-shard-N`, and
   `.codecov.yaml` are deleted. No coverage data leaves CI.

2. **Self-hosted merge + floor gate.** kcov already writes a
   `cobertura.xml` per shard whose root `<coverage>` element carries
   `lines-covered` / `lines-valid`. A new CI-agnostic script,
   `script/test/drivers/coverage_gate.sh`, MERGES the per-shard reports
   into one project line-rate by SUMMING `covered` and `valid` across
   shards -- `SUM(covered) / SUM(valid)`, a line-weighted total -- and
   exits non-zero when it is below `COVERAGE_MIN`. It does NOT average the
   per-shard `line-rate` attributes: shards have different denominators
   (integration runs on the last shard only), so averaging would weight a
   small shard equally with a large one and report a wrong total. The
   script reads files and sets an exit code with no GitHub/GitLab
   coupling, so it gates identically under both.

3. **Threshold = v1 absolute floor.** `COVERAGE_MIN` defaults to **50**
   (percent, env-overridable), set just below the current measured
   project rate (~52.9%) so it does not false-fail today. It is meant to
   **ratchet up** as coverage improves. v2 (a follow-up, NOT built here)
   is regression-vs-main-baseline: store/fetch main's coverage % and fail
   on a drop beyond a threshold -- the original #615 intent. v1 keeps it
   simple with no baseline storage.

4. **Wired through `ci-rollup`.** Each coverage shard uploads its kcov
   report (HTML + cobertura) as a CI artifact (`actions/upload-artifact`,
   keyed by `strategy.job-index`). A new `coverage-gate` job downloads
   every shard artifact (`actions/download-artifact`, `pattern:
   coverage-shard-*`) and runs `coverage_gate.sh` over the merged set.
   `coverage-gate` joins `ci-rollup`'s `needs:` (which branch protection
   already requires), so a sub-floor rate blocks merge with **no
   branch-protection change** and no external SaaS.

5. **Visibility without SaaS.** kcov's HTML + cobertura are kept. On
   GitHub the gate appends a coverage summary table to
   `$GITHUB_STEP_SUMMARY` (built-in, free). Publishing the kcov HTML to
   GitHub Pages is a documented follow-up (deferred to keep this slice
   small).

### GitLab portability mapping (for the future move; mechanical)

The gate script stays CI-agnostic; only the job wrapper changes:

- **MR diff annotations:** point GitLab at kcov's cobertura via
  `artifacts: { reports: { coverage_report: { coverage_format:
  cobertura, path: coverage/**/cobertura.xml } } }`.
- **MR coverage % widget / badge:** add a `coverage:` regex on the
  coverage job, e.g. `coverage: '/merged line rate ([0-9.]+)%/'`, which
  matches the line `coverage_gate.sh` prints to stdout
  (`coverage_gate: merged line rate <N>% ...`).
- **The floor gate itself** is unchanged: GitLab runs the same
  `bash script/test/drivers/coverage_gate.sh coverage/**/cobertura.xml`;
  a non-zero exit fails the pipeline (the merge gate), exactly as the
  GitHub `coverage-gate` job does.

### Consequences (amendment)

- No coverage leaves CI; the gate is enforceable on any plan (the #709
  Pro-only blocker is gone) and ports to GitLab by editing the job
  wrapper, not the gate logic.
- The line-weighted merge is the load-bearing detail; it is unit-tested
  in `test/bats/unit/coverage_gate_spec.bats` (floor pass/fail, the
  sum-not-average math with unequal denominators, and missing/empty/
  malformed report handling).
- The section-2 Codecov merge and the section-3 `codecov/project` status
  are SUPERSEDED; the section-1 sharding and the "coverage is a gating PR
  check via `ci-rollup`" posture remain.

## Amendment (#724 / #725 / #730): shard count is dynamic, the partition is time-balanced, the merge is a per-line union

The section-1 sharding evolved to compress the PR critical path further
without weakening the gate (coverage stays a required PR check):

- **Dynamic shard count (#725).** The matrix is no longer the hardcoded
  `['1/4'..'4/4']`. A `compute-shards` job emits `["1/N",...,"N/N"]` from
  `vars.CI_SHARDS` (default 8, clamped [1,12]); the coverage matrix consumes
  it via `fromJSON`. The count is a repo variable because "shard to runner
  count" is not runtime-detectable on GitHub-hosted (parallelism is bounded
  by the plan's concurrent-job limit); it also generalises to self-hosted
  (set the var to the fleet size). `_shard_unit_files` / `--coverage-shard
  N/T` already accept any total T.

- **Time-balanced, integration-pooled partition (#724).** `_shard_unit_files`
  now partitions unit + integration specs in ONE pool (integration is no
  longer appended whole to the last shard, which made that shard the sole
  bottleneck -- measured 326s vs 87-192s for the others at 8 shards). The
  greedy-LPT weight moves from `@test` count to `_spec_weight` (recorded
  seconds from `SHARD_WEIGHTS_FILE`, else `@test` count as a graceful
  fallback). An automated timings source (so the seconds are real, not a
  count proxy) is a deliberate follow-up.

- **Per-line union merge (#730).** `coverage_gate.sh` now merges the shard
  cobertura reports by per-line UNION (a line is covered if ANY shard ran
  it; valid = distinct source lines), NOT `SUM(covered)/SUM(valid)` over the
  root counters. Every shard's kcov reports the whole tree, so source shared
  across shards was double-counted -- the SUM rate drifted DOWN with the
  shard count (4 shards ~52.9% passed; 8 shards 42.42% false-failed). The
  union is shard-count-invariant (real 8-shard data: 51.42%). This SUPERSEDES
  the section-"MERGE MATH" line-weighted SUM described above.

- **Self-maintaining real-runtime weights (#733).** The "automated timings
  source" the #724 bullet deferred. Each coverage shard runs `kcov ... bats
  --report-formatter junit`, and `_junit_to_timings` converts the per-file
  `<testsuite time=...>` entries into a `coverage/timings.tsv`
  (`<seconds> <basename>`) uploaded in the shard artifact. The coverage-gate
  job (which already downloads every shard artifact) merges them via
  `coverage_gate.sh --merge-timings` and, on main-branch pushes only,
  `actions/cache/save`s the result; every run `actions/cache/restore`s it to
  the in-repo `test/bats/.shard-weights` path `_spec_weight` reads by default,
  so the partition self-balances by REAL seconds. PR runs are read-only (PR-
  runner noise never poisons the shared weights); a cache miss or a brand-new
  spec degrades to the `@test`-count fallback. This is the established
  best-practice shape: runtime-weighted greedy-LPT with a self-maintaining
  cached durations file -- cf. CircleCI ("timings-based test splitting gives
  the most accurate split ... the most recent timings data is always used"),
  Knapsack Pro (balance by time so every node finishes together), and
  pytest-split's `least_duration` (largest-first into the lightest group) fed
  by a stored `.test_durations`. The greedy-LPT partition is provably near-
  optimal: Graham (1969, SIAM J. Appl. Math. 17(2):416-429) bounds LPT
  makespan at `(4/3 - 1/(3m))` x optimal. The hard floor is the single
  longest spec FILE (whole-file granularity); splitting a hot file by example
  is a future refinement, not built here.

The "coverage is a gating PR check via `ci-rollup`" posture is unchanged.

## Amendment (#853 / #855): the floor is re-based to 80

Section 3 set `COVERAGE_MIN` to **50**, "just below the current measured
project rate (~52.9%)", and said it was meant to ratchet up. It is now
**80**.

The ratchet is not the whole story: the measurement itself was wrong. The
per-line union key of the previous amendment was the RAW `<class
filename>` kcov emits, and kcov reports one source file under several
prefix-truncated aliases, so every alias re-counted that file's lines
into the denominator. #853 canonicalises the filename before it becomes
part of the key, which moved the SAME suite from ~51% to **84.72%**
(`5907/6972` lines on `main`, run `30814141976`) -- the project rate had
been understated by roughly 33 points, and a 50 floor against an 85%
reality left about 35 points of dead slack in a required check.

80 leaves **4.72 points** of margin below the measured rate: wide enough
that ordinary per-PR churn does not false-fail the gate, narrow enough
that a real regression trips it instead of being absorbed. The v1
absolute-floor posture is unchanged -- this re-bases the number, it does
not adopt the v2 regression-vs-main-baseline gate, which remains the
documented follow-up.
