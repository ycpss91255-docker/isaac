# Tool-first `test/<tool>/<category>/` layout + per-tool test runner

> Serves: PRD invariant 7 (rigorous test bar) -- tool-first test layout;
> supersedes ADR-00000004.

- **Date:** 2026-06-23
- **Status:** Accepted (category vocabulary amended -- see below)
- **Supersedes:** ADR-00000004 (category-first `test/<category>/<tool>/`)
- **Relates to:** ADR-00000011 §5 (the generic test runner that consumes
  this layout)

> **Amendment (2026-06-30):** The *category vocabulary* used below
> (`{smoke, unit, integration, behavioural}`) is superseded by
> ADR-00000018 (ISTQB-aligned taxonomy): `behavioural` -> `system`, a new
> `acceptance` level is added, and `smoke` is reclassified as a build-time
> *type* (it keeps its own directory). The **tool-first** decision of this
> ADR -- `test/<tool>/<category>/` for specs and `test/lint/<tool>/` for
> linters, one driver per tool subtree -- **still stands**; only the set of
> category names *inside* `test/<tool>/` changes. Read the directory
> examples below as `unit / integration / system / acceptance / smoke`.

## Context

ADR-00000004 chose a **category-first** test layout
(`test/<category>/<tool>/`, e.g. `test/unit/bats/`) and explicitly
rejected tool-first, to keep the TDD four-axis view (smoke / unit /
integration / lint) a single directory walk and let `TEST.md` organise by
category.

ADR-00000011 reworks the test entry into a **dispatcher + one driver per
tool** (`script/test/drivers/{bats,shellcheck,hadolint,...}.sh`). With
that structure the natural unit of ownership is the *tool*: each driver
wants one subtree it owns end-to-end. Category-first fragments every
tool's files across the category directories, so a driver must walk every
category to collect its own specs, and the base/consumer shapes diverge
(single-tool repos stay flat, multi-tool repos sublayer). The layout and
the runner pulled in opposite directions.

## Decision

Lay `test/` out **tool-first**: `test/<tool>/<category>/` for specs and
`test/lint/<tool>/` for linters. The tool layer is always present, so base
and consumer shapes match.

```
test/
  bats/
    smoke/  unit/  integration/  behavioural/
  pytest/                 # only if the repo uses it
    smoke/  unit/  ...
  lint/                   # lint group, per-tool
    shellcheck/  .shellcheckrc / scope
    hadolint/    .hadolint.yaml
```

- **One driver, one subtree.** `script/test/drivers/<tool>.sh` owns
  `test/<tool>/` (or `test/lint/<tool>/`), 1:1. Adding a tool = a driver +
  a folder; the dispatcher is untouched.
- **Execution environment is decided by the category, not the tool**
  (per ADR-00000011 §5): `smoke` runs inside the built `*-test` image
  stage (it tests the real image); `unit` / `integration` / `behavioural`
  run in the test-tools toolchain container.
- **Lint is per-tool too.** Each linter has `test/lint/<tool>/` holding
  its config; `just test lint` runs all, `just test lint --shellcheck
  [<level>] | --hadolint` runs one. Lint configs move under
  `test/lint/<tool>/` -- notably `.hadolint.yaml` leaves
  `dist/.hadolint.yaml`, and the consumer Dockerfile lint-stage
  COPY, `self-test.yaml`'s hadolint `config:`, and any init/upgrade
  references update in lockstep.
- **base migrates** `test/{unit,integration,behavioural}` ->
  `test/bats/{unit,integration,behavioural}`.

## Consequences

- The "what unit tests exist" query is now a walk across every tool
  (`test/*/unit`), and `TEST.md` reassembles the category view across
  tools -- the exact cost ADR-00000004 set out to avoid. Accepted: the
  per-tool driver model is the dominant organising force now, and the
  category view is recoverable by a glob.
- base/consumer test trees share one shape (tool layer always present),
  removing ADR-00000004's flat-vs-sublayer divergence.
- `lint_mixed_test_layout.sh` (#495), which warned when a
  `test/<category>/` mixed runner families, is repurposed/retired: under
  tool-first a category dir never holds two tools (the tool is the parent),
  so the mixing it guarded against cannot occur.

## Alternatives

- **Keep category-first (ADR-00000004).** Rejected: it fights the per-tool
  driver model, forcing every driver to walk all categories and keeping
  base/consumer shapes divergent.
- **Linters as top-level tool dirs (`test/shellcheck/`, `test/hadolint/`)
  instead of a `test/lint/` group.** Rejected: grouping the linters under
  `test/lint/` keeps the TDD "lint" axis legible as one place while still
  separating per tool inside it.
