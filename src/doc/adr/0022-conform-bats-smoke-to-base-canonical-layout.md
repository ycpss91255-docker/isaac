# Conform the bats smoke layer to base's canonical `test/bats/` layout

The base v0.41.0 -> v0.42.0 subtree upgrade (isaac#246) pulls in base's
tool-first test layout (base ADR-00000012, base#650 / base#835): the
shipped smoke templates now live under `.base/dist/test/bats/smoke/`
(`shared/`, `devel-test/`, `runtime-test/`), and `release-worker.yaml`'s
release-archive keep-list hard-expects the consumer's repo-local smoke
specs at `test/bats/smoke/`. isaac had its repo-local bats smoke specs at
`test/smoke/bats/` -- the **category-first** sublayer ADR-0013 chose
(Layout B) and ADR-0017 declared "untouched". Under v0.42.0 that path no
longer matches what base ships next to or what the release archive globs,
so keeping it would mean a per-upgrade reconciliation seam (the `cp -r`
in the release job fails on the missing `test/bats/smoke/`, exactly the
class of breakage that reddened the v0.0.1 release run).

**Decision**: move isaac's repo-local bats smoke specs from
`test/smoke/bats/` to **`test/bats/smoke/`** (base's canonical tool-first
location), reversing ADR-0013's Layout-B choice **for the bats smoke
layer only**. The pytest layers (`test/unit/pytest/`,
`test/integration/pytest/`) stay category-first per ADR-0013 -- this ADR
does not touch them.

The governing principle this lands on:

> **Conform to upstream where upstream ships or owns the layer; keep the
> local convention where it does not.**

- The **bats smoke** layer is *co-owned* with base: base ships the shared
  + stage baseline specs into it (`.base/dist/test/bats/smoke/{shared,
  devel-test}/`, COPY'd alongside the repo's own specs into `/smoke_test/`),
  and `release-worker.yaml` archives it by a fixed path. base's canonical
  tool-first location therefore governs -> `test/bats/smoke/`.
- The **pytest unit / integration** layers are *purely isaac-owned*: base
  ships no pytest tests and dictates no sublayer for them. ADR-0013's
  category-first ergonomics (a single `test/<category>/` walk answers
  "what unit tests does this repo have") stand where base does not
  override -> `test/unit/pytest/`, `test/integration/pytest/` unchanged.

The resulting tree is intentionally asymmetric (`test/bats/smoke/`
tool-first next to `test/unit/pytest/` category-first). That asymmetry is
not an oversight: each layer's sublayer is decided by who owns it, not by
a single repo-wide rule.

## Considered Options

- **(a) Move only the bats smoke layer to `test/bats/smoke/`** (**chosen**).
  Minimal reversal: conform exactly the layer base ships + archives, keep
  0013 Layout B everywhere base is silent. No churn to the pytest gate
  (`assert_pytest_baseline.sh` still points at `test/unit/pytest/` +
  `test/integration/pytest/`), so the M1/M2 baseline ratchets are
  untouched. Cost: the tree is not uniformly tool-first.
- **(b) Go fully tool-first** (`test/bats/smoke/`, `test/pytest/unit/`,
  `test/pytest/integration/`). Rejected for this migration: it reverses
  0013 wholesale for zero upstream-conformance benefit (base ships no
  pytest tests, so nothing external expects `test/pytest/`), while forcing
  edits to `assert_pytest_baseline.sh`, its `*_isolation_spec.bats`, the
  baseline file, and every `sys.path` climb -- a large, risk-bearing diff
  bolted onto an already-large subtree upgrade. If a future base release
  ever ships pytest templates under `test/pytest/`, revisit then (Rule of
  Three).
- **(c) Keep `test/smoke/bats/`, patch base to accept it.** Rejected:
  isaac is a downstream *consumer* of the base subtree; the canonical
  layout is base's to define (isaac#246 decision -- "base is upstream, we
  conform"). Asking base to carry a per-consumer path override inverts the
  dependency and burdens every other base consumer.

## Relationship to prior ADRs

- **ADR-0013** ("Test Ownership Boundary + `test/<category>/<tool>/`
  Layout") chose Layout B (category-first) and *rejected* Layout C
  (tool-first) on the grounds that "tool is an implementation detail;
  category is the human-facing axis." That reasoning still holds for
  isaac-owned layers; this ADR overrides it only for the base-co-owned
  bats smoke layer, where upstream-conformance outranks the local
  ergonomic preference. **Superseded in part** (bats smoke sublocation
  only); the ownership boundary and the pytest sublayer are unchanged.
- **ADR-0017** ("isaac base-repo convergence contract") appended the
  amendment "The `test/<category>/<tool>/` sublayer decision is untouched
  and remains the layout for the converged repo." That clause is now
  **narrowed**: the sublayer is untouched for pytest layers, but the bats
  smoke layer follows base's canonical `test/bats/smoke/` as of the
  v0.42.0 subtree.

## Concrete impact

- `test/smoke/bats/*.bats` -> `test/bats/smoke/*.bats` (12 specs).
- `Dockerfile` devel-test stage COPYs `test/bats/smoke/` into
  `/smoke_test/` alongside `.base/dist/test/bats/smoke/{shared,devel-test}/`.
- `doc/test/TEST.md` bats path + counts synced to the new location.
- No change to `test/unit/pytest/` (15 specs) or `test/integration/pytest/`
  (11 specs) or the pytest baseline gate.

## References

- ADR-0013 -- test ownership + `test/<category>/<tool>/` sublayer (Layout B
  chosen; superseded in part here).
- ADR-0017 -- isaac base-repo convergence contract (sublayer "untouched"
  clause narrowed here).
- ADR-0019 -- remove same-repo multi-instance (the `--instance` ->
  `PROJECT_NAME` axis of the same v0.42.0 migration; unrelated to layout).
- `ycpss91255-docker/isaac#246` -- the base v0.42.0 subtree upgrade PR
  carrying this move ("base is upstream, we conform").
- `ycpss91255-docker/base` ADR-00000012 -- base's tool-first canonical
  test layout.
- `ycpss91255-docker/base#650` / `#835` -- base's shipped smoke templates
  under `test/bats/smoke/` + `.setup.conf` relocation.
