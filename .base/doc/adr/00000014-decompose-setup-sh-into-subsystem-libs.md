# Decompose setup.sh into subsystem libs (relocate-first, tracer-bullet order)

> Serves: mechanism -- setup.sh decomposition into subsystem libs
> (architecture / testability); no invariant.

- **Date:** 2026-06-27
- **Status:** Accepted
- **Relates to:** epic #745 (slices #746 deploy, #747 compose, #748
  subcommands, #749 infra cleanup); the test-layout audit that surfaced it;
  ADR-00000012 (tool-first test layout); #565 (lib/wrapper.sh extraction
  precedent); #568 (explicit lib load-order)

## Context

`dist/script/docker/wrapper/setup.sh` had grown to 5133 lines and ~90
functions spanning ~10 distinct concerns: host detection, conf access,
name/path resolution, value resolvers, dockerfile/stage handling, the deploy
generator, compose emission, env writing, drift checks, and the user-facing
`set/show/list/add/remove/reset/apply/deploy` subcommands. It is sourced by
every container-ops wrapper.

A 2026-06-27 test-file granularity audit (informed by cross-ecosystem
convention research: Go/pytest/Jest/JUnit/RSpec/bats) found setup.sh is the
ROOT of the suite's structural problems: it is tested by 11 spec files
(~614 tests), produces a name/unit mismatch (`deploy_spec.bats` tests deploy
code that has no `deploy.sh`), and seeds several of the 8 oversized
"god-test-files". A perf symptom landed the same week: `_resolve_deploy_context`
re-parsed the conf 10x per call (#742) -- the kind of issue a god-source hides.

The research consensus: test-file granularity should mirror the UNIT under
test, and when the source is a god-file the principled fix is to split the
SOURCE first (with the existing tests as the safety net); the test split then
falls out one-to-one.

## Decision

Decompose setup.sh into cohesive subsystem libs so it becomes a thin
orchestrator, under these rules:

1. **Relocate into existing libs first; create new libs only for the
   homeless.** `lib/compose.sh`, `lib/conf.sh`, `lib/dockerfile_migrate.sh`,
   and `lib/schema.sh` are already the established seams; the matching code
   that leaked into setup.sh belongs there. New files are created only for
   blocks with no existing home -- `lib/deploy.sh` (deploy generator) and
   `lib/setup_cmd.sh` (subcommands). We do NOT introduce a parallel
   `setup_*.sh` namespace that duplicates seams that already exist.

2. **Tracer-bullet order.** deploy generator first (smallest cohesive block,
   homeless so the cleanest extraction, just-touched in #742, and it fixes the
   deploy_spec name/unit mismatch), then compose emission, then subcommands,
   then a final shared-infra cleanup. The first slice proves the mechanics
   (load-order, spec re-source, this ADR) before the larger, riskier blocks.

3. **One slice = one issue = one PR; behaviour stays identical.** Each slice is
   a pure relocation guarded by the existing specs as a regression net; no
   behaviour change. The spec file follows its source (re-source / rename to
   mirror the new lib). Cross-file function calls resolve at runtime via the
   established load-order (#568), so a moved block does not need to re-source
   its still-resident dependencies; isolated unit specs source the deps they
   need explicitly.

## Consequences

- setup.sh shrinks toward a thin `main` + wiring; each concern gains locality
  (its change/bug/knowledge concentrate in one lib) and a one-to-one mirroring
  spec, shrinking the god-test-files.
- The 11-spec sprawl over setup.sh resolves as the source moves out.
- Short-term churn: several PRs touching a core file; mitigated by the
  one-slice-per-PR discipline and the existing test net.
- Risk: setup.sh is sourced by all wrappers; a botched relocation could break
  every container op. Mitigated by behaviour-identical relocation + full
  `just test` (incl. kcov) green per slice.

## Alternatives considered

- **All-new `setup_*.sh` namespace** (ignore existing libs): rejected -- it
  duplicates seams (`lib/compose.sh` etc. already exist) and fights the #565
  direction.
- **Big-bang single PR**: rejected -- too risky on a core file; no incremental
  proof; unreviewable diff.
- **Split the test files only, leave setup.sh**: rejected -- mirrors the
  physical file, not the units; leaves the god-source (and its perf/locality
  costs) in place. The research is explicit that splitting the source is the
  principled fix when the source is the god-file.
- **Leave setup.sh as-is**: rejected -- it is the measured root of the suite's
  granularity problems and a recurring perf/locality hazard.

## Amendment (#747): compose emission -> lib/compose_emit.sh, not lib/compose.sh

The compose slice found that `lib/compose.sh` is the `docker compose`
INVOCATION wrapper + project naming (`_compose` / `_compose_project` /
`_compute_project_name`), a distinct concern from compose.yaml GENERATION. The
~1200-line emission block (`_emit_*`, `generate_compose_yaml`, the volume/device
classifiers) therefore landed in a NEW `lib/compose_emit.sh` rather than being
merged into the invocation wrapper. This is consistent with the
"new lib only for the homeless" rule -- emission had no existing home, since
compose.sh's home is invocation -- it just refines the slice's earlier
"into lib/compose.sh" wording.

## Amendment (#749): the infra-cleanup slice was delivered as four sub-PRs

The "shared base / infra cleanup" slice (#749) was too large to land as one PR
(it carried setup.sh from ~1949 lines to a thin orchestrator), so it shipped as
four behaviour-identical relocation sub-PRs, each its own issue-less `Refs #749`
PR with the existing specs as the regression net; the last closes #749:

- **749a** -> `lib/setup_detect.sh` (host detection + name/path resolution)
- **749b** -> `lib/setup_conf.sh` (the setup.conf accessors)
- **749c** -> `lib/stage.sh` (multi-stage Dockerfile + per-stage overrides)
- **749d** -> `lib/resolve.sh` (mode+detection resolvers + conf hash),
  `lib/env_emit.sh` (.env generation), `lib/drift.sh` (drift detection)

Two refinements to the original plan, both consistent with the #747 precedent:

- **.env generation -> `lib/env_emit.sh`, not `lib/env.sh`.** `lib/env.sh` is
  the runtime `.env` READER (`_load_env`) every wrapper sources; `write_env` /
  `_scaffold_env_overlay` are the GENERATORS, used only at setup time. Same
  emission-vs-invocation split as compose_emit.sh vs compose.sh -- the
  generators land in a new `lib/env_emit.sh` rather than polluting the reader.
- **setup.sh's final shape.** After 749d it retains only the `_setup_msg*`
  message catalog, `usage`, and `main` (the subcommand dispatcher) -- a thin
  orchestrator over the subsystem libs, exactly the decomposition's goal.
