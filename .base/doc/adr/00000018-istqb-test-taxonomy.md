# ISTQB-aligned test taxonomy (levels / types / static analysis)

> Serves: PRD invariant 7 (rigorous, industry-aligned test bar) --
> established the commitment via the ISTQB-aligned taxonomy.

- **Date:** 2026-06-30
- **Status:** Accepted
- **Amends:** ADR-00000012 (supersedes only its category vocabulary
  `{smoke, unit, integration, behavioural}`; keeps its tool-first
  `test/<tool>/<category>/` + `test/lint/<tool>/` decision)
- **Relates to:** ADR-00000011 §5 (the generic test runner / per-tool
  driver model that walks this layout), ADR-00000015 (test files mirror
  source), issue #780 (epic), issue #781 (this ADR + the 12 amendment)

## Context

The test taxonomy was self-defined and mixed incompatible axes:

- The "4-category" matrix (base / docker_harness CONTEXT) is **Smoke /
  Unit / Integration / Lint**. That list mixes three different axes:
  Unit and Integration are *levels* (scope), Smoke is a *type*
  (purpose), and Lint is *static analysis* (not a dynamic test at all).
- base's `doc/test/TEST.md` "by type" index used a *different* 4-tuple:
  **unit / integration / behavioural / smoke** (Lint absent because it
  is not bats; `behavioural` present).
- So there were two "4"s that did not match, plus orphans: `behavioural`
  is not in any standard taxonomy, the full-image `integration-e2e` work
  had no category home, and smoke was misclassified as a level.

The mixed model left real gaps -- no Acceptance level, no clear home for
end-to-end -- and produced the QA defects that triggered this work
(broken downstream completion, empty `base/` dir, hardcoded/stale
`TEST.md` counts: all consumer-facing failures that no acceptance-level
test guards).

## Decision

Re-baseline to the industry-standard model -- ISTQB test levels plus the
Test Pyramid -- kept lightweight: take the spine of levels, the few
types actually used, and static analysis, not the whole certification
body. The taxonomy has three orthogonal axes.

### Axis 1 -- Static analysis (static testing)

Lint: ShellCheck (`.sh`) + Hadolint (Dockerfile). Not a dynamic test
level. Lives at `test/lint/<tool>/` (established by ADR-00000012, which
this ADR keeps).

### Axis 2 -- Levels (scope ladder)

| Level | Scope | Verifies against |
|-------|-------|------------------|
| **Unit** (Component) | one function / script in isolation | technical |
| **Integration** | several scripts / components together (init, upgrade, dispatch) | technical |
| **System** | the whole built image end-to-end (build to run to exec to stop); the build-gate mechanism | technical specs |
| **Acceptance** | what the downstream consumer receives -- the scaffolded framework + its UX (just commands, help, completion, generated layout), from the consumer's chair | user/operator expectations (UAT + OAT) |

Top level is **System** (ISTQB). "End-to-end" is a *type* performed at
the System / Acceptance level, not a level name.

### Axis 3 -- Types (purpose; applied at a level)

- **Smoke** -- build-verification: the critical "does it even come up"
  subset, run at build time inside each `-test` Dockerfile stage.
- **End-to-end** -- a complete workflow start to finish.
- **Regression** -- guards a previously-fixed defect (e.g. the
  build-gate-fires check, formerly `behavioural`).
- **Reserved (non-functional)** -- Performance / Security / Usability /
  Reliability: kept as empty placeholders in the framework, filled
  per-project when needed.

### Baseline + Extension model

The framework fixes the axes (the vocabulary). Each project = framework
**baseline** (provided / required) + project **extension** (its own
specs at each level / type). Unused slots are *reserved* (empty dirs +
`.gitkeep`) so the structure is complete and self-documenting without
reading this ADR.

### Key reclassifications (current -> standard)

- `behavioural` (drives buildx to prove the smoke gate fires) ->
  **System level + Regression type**. The non-standard term
  `behavioural` is retired.
- `e2e` as a *level* label -> **System** (e2e demoted to a type).
- `Lint` as the 4th "category" -> **Static analysis** axis (no longer a
  peer of the dynamic levels).
- **Acceptance** -> new explicit level (consumer framework + UX; UAT +
  OAT).
- Smoke -> a *type*, but keeps its own category directory because it is
  shipped + build-time.

### Directory layout (base and dist mirror 1:1, tool-first, zero exception)

```
test/bats/
  unit/          integration/
  system/        # was test/bats/behavioural/ (gate = Regression type) + image e2e
  acceptance/    # new: scaffold downstream + UX (UAT/OAT)
  smoke/         # build-time type, per Dockerfile -test stage
    shared/  devel-test/  runtime-test/
test/lint/{shellcheck,hadolint}/
```

- dist ships a 1:1 mirror:
  `dist/test/bats/smoke/{shared,devel-test,runtime-test}/` (replaces the
  tool-layer-skipping `dist/test/smoke/`).
- Each `-test` Dockerfile stage uses explicit selective COPY (only
  `shared/` + its own `<stage>/`, from both `.base/dist/...` and the
  repo) + `RUN bats /smoke_test/`. Adding a stage = a folder + that COPY
  block. Keeps the `-test` image small (only that stage's specs).
- Reserved / unused level or type slots: created as empty dirs with
  `.gitkeep` (not ADR-only), so the full taxonomy is visible in the tree.

## Consequences

- The taxonomy is now industry-standard and explainable by reference
  (ISTQB + Test Pyramid) instead of by repo lore. New contributors can
  place a test by its level and type without reading repo-specific
  category definitions.
- A new **Acceptance** level gives the consumer-facing checks (scaffold
  downstream, just / UX, generated layout) an explicit home -- the gap
  that produced the triggering QA defects.
- `behavioural` is retired across the codebase: the CI job, the runner
  driver, the doc catalogs, and `dist` all move to `system`. This is a
  rename with downstream reach, sequenced in the #780 sub-issues (this
  ADR is doc-only; no code / dir changes land here).
- The tool-first decision (ADR-00000012) is unchanged: `test/<tool>/`
  stays the unit of driver ownership, and `test/lint/<tool>/` keeps the
  linter configs. Only the *category vocabulary inside* `test/<tool>/`
  changes (`behavioural` -> `system`, `+ acceptance`, smoke kept as a
  shipped build-time type dir).
- The structure is self-documenting: reserved empty slots make the full
  level x type grid visible in the filesystem, so a missing
  non-functional or acceptance test is an obvious gap, not a silent one.

## Alternatives

- **Keep the self-defined 4-category model.** Rejected: it mixes three
  axes (level / type / static), has two non-matching "4"s, leaves
  `behavioural` and full-image e2e homeless, and has no Acceptance level
  -- the exact gaps behind the triggering QA defects.
- **Adopt the full ISTQB body (all levels, all functional /
  non-functional types, formal test-design techniques).** Rejected as
  too heavy for a container-template framework: only the level spine,
  three real types, and static analysis are used; the rest are kept as
  reserved placeholders rather than mandated.
- **Treat end-to-end as its own top level.** Rejected: ISTQB models
  end-to-end as a *type* run at the System / Acceptance level, so it is
  classified as a type, with System as the top level.

## Sources

- ISTQB test levels (Component / Integration / System / Acceptance):
  https://astqb.org/what-are-the-levels-of-testing/
- ISTQB Glossary -- acceptance / system / end-to-end testing:
  https://glossary.istqb.org/en_US/term/acceptance-testing/1 ,
  https://glossary.istqb.org/en_US/term/system-testing-3-2 ,
  https://glossary.istqb.org/en_US/term/end-to-end-testing
- Test Pyramid (Fowler):
  https://martinfowler.com/articles/practical-test-pyramid.html
- Acceptance sub-types incl. OAT / UAT:
  https://en.wikipedia.org/wiki/Acceptance_testing
