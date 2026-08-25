# CI throughput ceiling (free + public) and the shard / runner strategy

> Serves: PRD invariant 7 (rigorous test bar) -- CI throughput / shard
> strategy; a swappable mechanism, not the invariant.

- **Date:** 2026-06-29
- **Status:** Accepted
- **Relates to:** ADR-00000008 (sharded coverage PR gate), ADR-00000016
  (coverage tooling kept as kcov), issue #758 (CI-squeeze work), issue #766
  (self-hosted same-repo guard)

## Context

The self-test PR critical path is ~3m. A throughput grill set out to "push CI
to the limit" and to decide how the coverage shard count should be managed
(today a static `vars.CI_SHARDS`, default 8). The investigation produced
hard, API-verified constraints that bound what is achievable, so they are
recorded here to stop the topic being re-litigated.

### Verified constraints (measured / API-checked, not assumed)

- **Plan = GitHub Free -> 20 concurrent jobs, org-wide** (shared across every
  repo in the org). Observed peak in one self-test run: 15 concurrent (8
  coverage shards + ~7 other jobs).
- **GitHub-hosted exposes NO capacity / idle / remaining-slot API.** Direct
  checks: `…/actions/runner-limits` -> 404 (the field-returning endpoint some
  blogs cite does not exist), `…/actions/hosted-runners` -> 404 "not supported
  for this organization" (that is the paid larger-runner feature),
  `…/settings/billing/actions` -> 410 Gone. The 20-cap is enforced
  server-side and cannot be queried at runtime.
- **kcov coverage is serial / single-threaded per process.** Measured: a full
  unsharded `just test coverage` on the org's 32-core self-hosted runner took
  **522s (~8.7 min)** for the same 2135 tests. Extra cores do not speed a
  serial kcov run. Therefore **sharding is not removable** -- dropping it
  returns CI to ~8.7 min (~3x slower than the sharded ~3 min).
- **The two co-equal poles.** Slowest coverage shard ~155s and native arm64
  `integration-e2e` ~154s run in parallel; total is bounded by the larger.
  Cutting only one pole does not move the total (the other still sits at
  ~155s) -- they must be cut together.
- **Self-hosted reality.** The org has ONE self-hosted runner (32-core, GPU,
  org-level, currently unused by CI). Self-hosted `status`/`busy` ARE
  queryable. base is a PUBLIC repo with `fork-pr-contributor-approval =
  all_external_contributors` and zero fork PRs in history.

## Decision

1. **Shard count is auto-derived by ONE mechanism, not a hand-maintained
   number and not per-environment parameters.** `compute-shards` emits a
   single N consumed by a single matrix:
   - GitHub-hosted: `N = concurrency_budget = cap (20) - reserved_other_jobs
     (~7) ~= 12`. A *derived constant* -- it does not float (the cap pins it),
     but no human tunes it; it only shifts if the cap or the job set changes.
   - Self-hosted: `N = idle-runner / core budget` -- genuinely dynamic and
     queryable.
   - `vars.CI_SHARDS` remains the SINGLE optional override (applies in any
     environment, highest precedence). Operators manage zero parameters by
     default, one at most. There is deliberately NOT a separate hosted vs
     self-hosted parameter -- the environment branch lives inside the one
     compute-shards mechanism.
   - Sharding itself stays (removing it -> 522s serial, per the measurement).

2. **The free + public PR-CI ceiling is ~135s and that is a platform limit,
   not a process defect.** Reaching it needs BOTH levers (shard count at the
   hosted budget AND the e2e build cached); the specific e2e-build-cache
   mechanism is decided separately. Below ~135s is not reachable on free +
   public because the 20-cap caps shard parallelism and kcov's per-line cost
   is irreducible (ADR-00000016).

3. **Self-hosted is the only escape from the 20-cap, but it is gated for a
   public repo and deferred.** Using the self-hosted runner for PR CI would
   let coverage shard as parallel processes across its 32 cores (est.
   ~35-50s) and dodge the 20-cap, but a public repo must first land the
   same-repo guard (#766) so fork-PR code never executes on the machine, and
   must accept single-machine SPOF + contention with the owner's other work.
   Not scheduled.

4. **No paid GitHub runners** (owner decision). The escape paths beyond the
   free ceiling are: self-hosted (per decision 3) or a third-party runner
   provider -- both separate budget/ops decisions, out of scope here.

## Consequences

- The shard count stops being a maintained magic number; it self-sizes to the
  environment, generalising cleanly when/if self-hosted runners are adopted.
- "Why is CI ~3m and not faster?" has a recorded, evidence-backed answer: the
  free + public 20-cap plus serial-kcov cost. Speed work below ~135s is
  explicitly a runner-budget decision, not a workflow-tuning one.
- The self-hosted escape is documented but blocked on #766 + the SPOF
  trade-off, so it cannot be adopted accidentally.

## Alternatives

- **Keep a hardcoded `CI_SHARDS`.** Rejected: a maintained magic number the
  owner has to remember to bump; the budget/idle derivation removes it.
- **Remove sharding entirely (one coverage job).** Rejected by measurement:
  522s serial even on a 32-core machine; ~3x slower.
- **Move CI to the existing self-hosted runner now.** Rejected for now:
  public-repo fork-PR code-execution risk (needs #766 first) and
  single-machine SPOF / owner-workstation contention. Left as a documented,
  gated future path.
- **Buy concurrency (GitHub Team/Enterprise or third-party runners).**
  Rejected for now (owner decision); recorded as the other escape path.

## Amendment (2026-06-29): two CI principles make ~185s the irreducible floor; e2e caching and self-hosted-for-speed are both retracted

The original decision floated "~135s with both levers (shards + e2e build cache)"
and a "self-hosted escape ~80s". Both presupposed caching the e2e build. Two
governing principles, made explicit after the fact, rule that out:

1. **CI must align with the real `just docker build` flow.** A real user's
   build caches via the local docker daemon, never via a CI-injected
   `cache_from`. Any CI-only cache wiring (e.g. ghcr `cache_from` spliced into
   the generated compose) diverges from what users actually run -- rejected
   (same reason the prebuilt `base-env` image was rejected: it changes the
   real build).
2. **Every CI run must be clean and reproducible.** No state is retained
   between runs -- on self-hosted runners too (they must be kept stateless to
   match GitHub-hosted, or a cached run stops matching a clean run and CI
   loses reproducibility).

Together these forbid caching the e2e build by ANY mechanism: a CI-only cache
violates (1); a retained daemon cache violates (2). Therefore:

- **The e2e build is a clean build every run on every platform.** It is
  apt/network-bound and sequential (sys -> devel-base -> devel), so it is
  ~platform-independent (~154s arm64); extra cores do not speed it. This is
  the binding pole.
- **Irreducible CI floor ~= e2e-arm64 clean (~154s) + serial pre/post chain
  (classify + compute-shards + gate + rollup, ~30s) ~= 185s**, on BOTH
  GitHub-hosted and self-hosted.
- **Self-hosted is NOT a speed lever** under principle 2: a stateless
  self-hosted run pays the same ~154s clean e2e, and although it could shard
  coverage across more cores (no 20-cap), coverage is already below the e2e
  floor, so total does not move. The "~80s self-hosted" figure is retracted.
  Self-hosted retains only the non-speed considerations (and #766 guard) and
  is not pursued for performance.
- **`CI_SHARDS` increase is not pursued**: total is e2e-bound, so cutting
  coverage below the e2e floor yields no total-time win. The existing shard
  count stays (it keeps coverage at/under the e2e pole; removing sharding
  returns to the 522s serial run).

**~185s is therefore the accepted floor -- a deliberate choice of fidelity +
reproducibility over raw speed, not a process defect.** Going below it would
require violating principle (1) or (2), or dropping covered work (e.g. the
arm64 e2e, which has real value since the org ships arm64). The CI-squeeze
effort's remaining scope is the quality wins (broader e2e command coverage,
stale-comment + dead-package cleanup), not speed.

## Sources / provenance (every figure above is reproducible)

All measured / queried on 2026-06-29 unless noted. Recorded so future
re-examination can re-derive, not trust, the numbers.

- **Plan = free; 20 concurrent-job cap.** `gh api orgs/ycpss91255-docker
  --jq .plan.name` -> `free`. The 20-job (5 macOS) concurrency limit is the
  documented GitHub Free tier limit (GitHub Docs: Actions limits).
- **No hosted capacity / idle API.** `gh api
  orgs/ycpss91255-docker/actions/runner-limits` -> HTTP 404;
  `.../actions/hosted-runners` -> HTTP 404 "GitHub hosted runners are not
  supported for this organization"; `.../settings/billing/actions` -> HTTP
  410 Gone.
- **Peak concurrency 15.** Job-overlap analysis over `gh api
  repos/ycpss91255-docker/base/actions/runs/28347066279/jobs` (max count of
  jobs whose [started_at, completed_at) span a common instant).
- **Serial (unsharded) coverage = 522s.** `just test coverage` (full kcov, no
  shard) run on the org self-hosted runner host `C01013328` (32 vCPU, 125 GiB,
  GPU; `nproc`=32), wall-clock 522s, 2135 ok / 0 not-ok. The runner identity:
  `gh api orgs/ycpss91255-docker/actions/runners` -> 1 runner
  `C01013328-ycpss91255-docker-org`, labels `self-hosted,Linux,X64,gpu`,
  `status=online busy=false`.
- **Per-job times (e2e arm64 ~154s, amd64 ~114s, slowest coverage shard
  ~155-170s, total ~197-200s).** `gh api .../actions/runs/<id>/jobs` job
  durations for self-test main-push runs: `28347066279` (commit 32d9847,
  post-P1), `28279526244` (390ef9e, pre-P1 baseline), `28282248067` (cd20b1e,
  P1a). e2e step breakdown ("Build test stage" 93s arm64) from the per-step
  timings of the `Integration E2E (linux/arm64)` job in run 28347066279.
- **Per-spec kcov seconds (e.g. deploy_spec ~97-107s).** Merged
  `coverage-shard-*/timings.tsv` artifacts (max-dedup per spec) downloaded
  from runs `28279526244` and `28347066279`.
- **kcov tax +50-60% and the DEBUG-trap mechanism.** Spike on
  `ghcr.io/ycpss91255-docker/test-tools:main` (kcov v43, Bats 1.13.0, bash
  5.2.37): `deploy_spec` plain 29.7s vs kcov 47.4s (+60%); `setup_detect_spec`
  15.5s vs 23.2s (+50%); kcov output carried `bash-helper-debug-trap.sh`.
  Recorded in ADR-00000016.
- **e2e build is a clean (uncached) build.** The `integration-e2e` job uses
  the docker driver and rebuilds the example image each run; verified in
  `.github/workflows/self-test.yaml` (the "Set up Docker Buildx (driver:
  docker)" + "Build test stage" steps) and the per-step timings above.
- **Public repo + fork-PR gating.** `gh api
  repos/ycpss91255-docker/base/actions/permissions/fork-pr-contributor-approval`
  -> `{"approval_policy":"all_external_contributors"}`; `gh repo view` ->
  `visibility=PUBLIC`; `gh pr list --state all` fork-origin count = 0.
