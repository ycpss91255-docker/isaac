# TEST.md

Template self-tests: **2893 tests** total (2765 unit + 128 integration).

> "Self-test total" is the `just test` suite -- what runs in the
> `Self Test` CI job. System (12) and smoke (34) tests are tracked here
> too but are **not** in the 2893 figure: System specs need host docker
> access and are opt-in, and smoke specs are Dockerfile `test`-stage
> build-time assertions, not self-tests. Acceptance is a CI-only level (0
> bats specs by design): it drives a real scaffolded consumer + built
> image via the host-driven `acceptance` job, not the mounted-`/source`
> sandbox (see [acceptance.md](acceptance.md)).

This file is the index. The taxonomy is ISTQB-aligned (ADR-00000018):
the **levels** are Unit -> Integration -> System -> Acceptance, plus the
shipped build-time **Smoke** type. Per-category spec catalogs (each
carrying its own test count) live in the sibling docs below.

## Test Docs by Level / Type

| Doc | Scope | Count |
|-----|-------|-------|
| [unit.md](unit.md) | `test/bats/unit/` -- library, wrappers, generators, templates (Unit level) | 2765 |
| [integration.md](integration.md) | `test/bats/integration/` -- init / upgrade / dispatch across components (Integration level) | 128 |
| [system.md](system.md) | `test/bats/system/` -- opt-in `runtime-test` buildx specs, gate-fires Regression (System level, host docker) | 12 |
| [acceptance.md](acceptance.md) | `test/bats/acceptance/` -- consumer framework + UX, UAT/OAT (Acceptance level; CI-only via the `acceptance` job, #785) | 0 |
| [smoke.md](smoke.md) | `dist/test/bats/smoke/` -- shipped per-stage build-time smoke templates (Smoke type) | 34 |

Self-test grand total (unit + integration): **2893**.

## Running one spec under kcov: `just test coverage-path`

```bash
just test coverage-path test/bats/unit/lib_spec.bats
just test coverage-path test/bats/unit/lib_spec.bats --filter 'nounset'
just test coverage-path test/bats/integration/          # a directory works too
```

Some bugs are only visible under instrumentation: the spec is red under kcov
and green without it. kcov wraps every bash process it traces, sets its own
`PS4`, and perturbs a nested `set -u` shell, so a spec can depend on something
that only the coverage run disturbs -- which is precisely the class the
coverage matrix exists to catch, and the class that is hardest to iterate on.
The other two instrumented entries are the whole suite and a whole shard,
minutes each; this one runs the spec you name.

**It reports no coverage figure, deliberately.** The kcov report goes to a
throwaway directory inside the container and is removed on the way out, so
nothing this mode runs can write `coverage/cobertura.xml` -- which the
coverage-gate merges into the project line rate -- or `coverage/timings.tsv`,
which becomes the next partition's weights. One spec's covered lines over the
whole tree's denominator is not a project rate. Ask for a figure with
`just test coverage` (full suite) or `just test coverage <n>/<total>` (one
shard); ask for a RUN with this.

**It does not consult the shard partition, and that is load-bearing.** The
partition is greedy longest-processing-time bin-packing over per-spec weights
read from `test/bats/.shard-weights`. CI restores that file from cache; a
checkout does not have it, so `_spec_weight` falls back to `@test` counts and
the local partition is a genuinely different one. Shard `<n>/<total>` therefore
names different specs locally than it does in CI -- during #898 a spec sat in
CI's shard 1/8 and the local 4/8, and a local `just test coverage 1/8` never
ran the failing specs at all. Naming the path removes the question: the spec
you name is the spec that runs, in both places.

`--bats-path` (`just test` has no recipe for it; use
`./script/test/test.sh --bats-path <spec>`) remains the FAST loop -- no
ShellCheck, no kcov, on the `ci` service. It refuses `--coverage` and still
does: that combination is this recipe, on the `coverage` service, which is
where kcov lives.

## Static lints and where they are enforced

The `just test` lint phase runs the tools listed in `script/test/test.sh`'s
`_LINT_TOOLS` table. That table is the local gate; it is **not** the CI gate,
because no CI job runs the phase (the lint jobs narrow to one tool, and every
bats / coverage job sets `BATS_ONLY=1` / `COVERAGE=1`, which skip it). Each
tool therefore needs its own join to `.github/workflows/self-test.yaml`:

| Lint | Enforces | CI job | Gated? |
|------|----------|--------|--------|
| `shellcheck` | shell static analysis | `shellcheck` (`--shellcheck-only`) | `code_changed` |
| `hadolint` | Dockerfile static analysis | `hadolint` (`--lint --hadolint`, in the test-tools image) | `code_changed` |
| `issueref` | no transient `#NNN` in code comments (ADR-00000013) | `lint-static (issueref)` | ungated |
| `adr-numbering` | `doc/adr/` duplicate-free + well-formed | `lint-static (adr-numbering)` | ungated |
| `stale-setup-conf` | no legacy `config/docker/setup.conf` under `dist/` | `lint-static (stale-setup-conf)` | ungated |
| `readme-sync` | localized READMEs still match `README.md` | `lint-static (readme-sync)` | ungated |
| `doc-counts` | the figures / catalog rows below | `doc-counts` (`--doc-counts-only`) | ungated |
| `home-literal` | no concrete username in a home path under `dist/` or `dockerfile/` (ADR-00000024) | `lint-static (home-literal)` | ungated |
| `bash-source-guard` | no undefaulted `BASH_SOURCE` self-location read under `dist/` or `script/` | `lint-static (bash-source-guard)` | ungated |
| `early-close-reader` | no `\| head` / `\| grep -q` under `dist/` or `script/`, where an early-closing reader strands its writer and `pipefail` inverts the answer | `lint-static (early-close-reader)` | ungated |
| `derived-figures` | a figure a document repeats matches the code that defines it | `lint-static (derived-figures)` | ungated |
| `i18n-orphan` | no identifier-shaped token in a translation's code spans that `README.md` never names | `lint-static (i18n-orphan)` | ungated |

`lint-static` is a matrix so a red check names the lint that failed, and it is
ungated because two of its entries (`adr-numbering`, `readme-sync`) are
breakable by a change `classify` scores as doc-only -- a `code_changed` gate
would skip them on exactly the PR they exist to catch. Every entry but
`hadolint` runs host-direct on a plain runner via `test.sh --<tool>-only`; the
hadolint binary exists only in the test-tools image, so it keeps its own job.

Adding a lint to `_LINT_TOOLS` without giving it a CI job fails the
completeness guard in `test/bats/unit/self_test_yaml_spec.bats`. That guard,
not this table, is what keeps the list honest -- four lints shipped local-only
before it existed, and `home-literal` / `bash-source-guard` /
`early-close-reader` each joined the matrix in the same change that introduced
them.

## Maintaining these docs

Every figure and every catalog row in this directory is derived from the specs
themselves. Regenerate with `just test sync-docs`; validate without writing
with `just test sync-docs-check`. Never hand-edit a count or hand-add a row --
see [unit.md](unit.md) for the full contract.

**Where the check is enforced (one rule, three entry points).** All three run
the same `script/test/check_test_md_drift.sh`; they differ only in when they
speak and whether they can stop you:

| Entry point | When | Blocking? |
|-------------|------|-----------|
| `just test` lint phase (`just test lint --doc-counts`) | every local full gate | **yes** -- this is the gate |
| the `doc-counts` CI job (`test.sh --doc-counts-only`) | every CI run, ungated (a hand-edited count is a doc-only change) | **yes** -- same driver, hard-mandatory in `ci-rollup` |
| `just test sync-docs-check` | on demand | yes, but only if a human runs it |
| harness repo `.claude/hooks/check_test_md_drift.sh` (PostToolUse) | seconds after the Edit that caused the drift, in an interactive session only | no -- advisory |

The hook duplicates the gate deliberately: its value is latency, not
authority. It holds no rule of its own, so it cannot drift from the gate, and
if it is ever removed nothing is lost but the early warning. When the two
disagree, the lint phase is authoritative -- it is the one that can fail a
branch.

**Merging a branch into these files:** both sides bump the same generated
counters, so `doc/test/*.md` conflicts on almost every branch refresh. Do not
resolve it by hand and do not collapse it with an ad-hoc `awk`: run

```bash
just test resolve-docs
```

which collapses the markers, regenerates from the merged spec tree, verifies,
and stages -- and refuses loudly, staging nothing, when the two sides disagree
about something regeneration cannot settle (a catalog row each side describes
differently, or any hand-written prose that differs). A mechanical collapse
adopts whichever side it kept for exactly that content, which is how the
"System (N) and smoke (N)" line above shipped stale three times before the
generator learned to derive it.
