# Coverage tooling: evaluate kcov alternatives to lift the per-file shard floor

> Serves: PRD invariant 7 (rigorous test bar) -- coverage tooling (a
> swappable mechanism); spike Rejected, kcov kept.

- **Date:** 2026-06-27
- **Decided:** 2026-06-29
- **Status:** Rejected (spike below disproved the premise)
- **Relates to:** ADR-00000008 (sharded coverage PR gate, built on kcov),
  ADR-00000015 (test files mirror source -- the symptom-level lever),
  issue #758 (lower the coverage critical path)

## Context

Coverage is an enforced PR gate run under **kcov** (ADR-00000008). kcov
collects coverage via **ptrace**, single-stepping the traced process. That
has two costs measured in this repo:

1. **Per-run overhead.** kcov roughly +60% wall-clock over plain bats
   (`deploy_spec` 57s plain -> 92s under kcov).
2. **Per-file atomicity for sharding.** Because each spec file is run as
   one kcov invocation (to amortise the ptrace launch cost), a file cannot
   be split across shards. The longest single spec file is the hard floor
   on the slowest coverage shard, which sits on the PR critical path.

The dynamic + time-weighted + cached shard work (#725/#724/#733) and the
conf parse-once perf (#742) halved the critical path (~409s -> ~208s total;
slowest shard ~381s -> ~176s). ADR-00000015 lowers the per-file floor by
splitting god-test-files into source-aligned units. Both treat the
**symptom**. The **root** is the tool: if coverage overhead were near
zero, coverage could fold back into the normal test pass and the whole
separate-sharded-coverage architecture could be retired.

## Candidate tools

| tool | mechanism | note |
|---|---|---|
| **kcov** (current) | ptrace | cobertura native; language-agnostic; the +60% / per-file constraint above |
| **bashcov** | bash xtrace (`DEBUG` trap / `PS4` via `BASH_XTRACEFD`), no ptrace | works with bats; auto-merges; SimpleCov-based, so cobertura needs `simplecov-cobertura`; DEBUG-trap has its own per-command overhead and known correctness edges around `set -e`, subshells |
| **DIY `PS4` + `BASH_XTRACEFD`** | own `DEBUG` trap recording line hits | lightest, fully in our control; must write our own report emitter |
| **ShellSpec** | own BDD framework with built-in parallelism | its coverage is itself kcov under the hood -- does not remove the root |

## Decision (pending -- this ADR is Proposed)

Before committing to any tool change, run a **time-boxed throwaway spike**
(the prototype workflow) measuring **bashcov** and a **DIY PS4** tracer
against kcov on 2-3 representative specs (the heavy `deploy_spec`, a light
one). The spike must answer three gating questions with numbers:

1. **Speed** -- is it materially faster than kcov's ptrace?
2. **Reporting** -- can it emit cobertura the existing gate / timings cache
   consume, or what replaces them?
3. **Fidelity** -- does it stay accurate under our `set -u`, subshells, and
   `local -n` patterns (no false coverage gaps / no crashes)?

Decide only on the spike's evidence:

- If a lighter tracer clears all three: adopt it, and re-evaluate whether
  the separate sharded-coverage job (ADR-00000008) can collapse into the
  normal test pass.
- If none clears the bar: keep kcov; ADR-00000015's source-aligned splits
  remain the available lever, and this ADR is marked Rejected with the
  spike numbers recorded.

This is intentionally sequenced **after** ADR-00000015's P1 (the
source-aligned re-split), which is low-regret regardless of the tool
outcome.

## Spike result (2026-06-29) -- REJECTED

Ran the time-boxed spike. It disproved the ADR's central premise.

**Environment / versions compared** (the baked `test-tools:main` image):

- image: `ghcr.io/ycpss91255-docker/test-tools:main`
- `kcov v43`, `Bats 1.13.0`, `GNU bash 5.2.37(1)` (x86_64-alpine-linux-musl)
- bashcov / DIY-PS4 not benchmarked: the image has **no ruby/gem**, and the
  mechanism finding below made the benchmark moot.

**Method.** Same test set both ways (`COVERAGE=1` so identical tests run),
kcov invoked exactly as `_run_coverage` does (`--include-path=<repo>`, the
same `--exclude-path` set). Single run per cell. plain = `bats --recursive
<spec>`; kcov = `kcov ... bats --recursive <spec>`.

**Data (kcov tax per spec):**

| spec | plain bats | kcov | overhead |
|---|---|---|---|
| `deploy_spec.bats` | 29.7s | 47.4s | **+60%** |
| `setup_detect_spec.bats` | 15.5s | 23.2s | **+50%** |

- Reporting: `cobertura.xml` is produced fine (Q2 satisfied -- but moot).
- **Key finding (Q1 answer):** kcov's output dir contained
  `bash-helper-debug-trap.sh` / `bash-helper.sh` -- **kcov v43 already
  instruments bash via a `DEBUG` trap, not ptrace.** That is the *same*
  mechanism bashcov and the DIY-PS4 tracer use. The ADR's framing ("kcov =
  heavy ptrace, bashcov = light xtrace") is wrong for the bash case.

**Conclusion.** The +50-60% is the intrinsic cost of per-line bash coverage
(a trap firing on every command), not a kcov-specific ptrace penalty. A
DEBUG-trap-based alternative (bashcov) runs the same mechanism, would not
materially beat it, and would add a ruby dependency to the test-tools image
-- net negative. A DIY-PS4 tracer shares the mechanism and would need a
hand-written cobertura emitter for single-digit-percent upside -- not worth
it. **Coverage is at its structural floor; kcov stays.** The remaining
total-CI lever is the arm64 `integration-e2e` QEMU pole (native runners,
refs #587/#579), not the coverage tool.

## Consequences (if adopted)

- A coverage tool swap touches the test-tools image (currently bakes
  kcov), the gate's cobertura parser, and the `.shard-weights` timings
  cache -- an ADR-00000008-level change, hence the spike-first gate.
- A near-zero-overhead tracer could remove the dedicated coverage shards
  entirely, simplifying `self-test.yaml` and erasing the per-file floor as
  a concern -- the largest available structural win, but the riskiest.

## Alternatives

- **Do nothing; live with kcov.** Viable -- the symptom-level levers
  (sharding + ADR-00000015) already keep the gate within budget. This ADR
  exists because the user asked whether the constraint can be removed at
  the root, not because the gate is currently failing.
- **Skip the spike, swap to bashcov directly.** Rejected: bashcov's
  DEBUG-trap overhead and `set -e`/subshell fidelity are unproven for our
  code; swapping blind risks a slower or less accurate gate.
