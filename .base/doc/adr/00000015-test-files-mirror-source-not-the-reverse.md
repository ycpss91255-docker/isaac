# Test files mirror source files; source structure never follows tests

> Serves: PRD invariant 7 (rigorous test bar) -- test files mirror
> source; mechanism.

- **Date:** 2026-06-27
- **Status:** Accepted
- **Relates to:** ADR-00000012 (tool-first `test/<tool>/<category>/`
  layout -- this ADR governs file granularity *within* a category dir),
  ADR-00000008 (sharded coverage PR gate -- the per-file shard floor this
  convention helps lower), ADR-00000014 (the setup.sh decomposition that
  produced the libs these specs now mirror)

## Context

ADR-00000012 fixed *where* test files live (`test/<tool>/<category>/`).
It did not fix *how a test file maps to the source it covers*. After the
setup.sh decomposition (ADR-00000014) split one god-source into nine
subsystem libs, the tests still sat in a handful of god-test-files
(`setup_spec` 146 tests, `setup_emit_spec`, `compose_gen_spec`, ...) that
each spanned several libs. Two forces converged on needing a rule:

1. **Navigability / locality.** A reader looking for `resolve.sh`'s tests
   had to grep inside `setup_spec.bats`; a lib and its spec had no name
   correspondence.
2. **The coverage shard floor.** kcov instruments each spec **file** as
   one atomic unit, so a file cannot be split across shards. The longest
   single spec file is therefore the hard floor on the slowest coverage
   shard regardless of shard count (measured: `deploy_spec` 97s set the
   floor; the slowest shard was ~170s = that floor plus packed
   neighbours). Finer, source-aligned files give the partitioner smaller,
   more balanceable units.

The tempting shortcut -- when one source file needs more than one test
file (for granularity or to test distinct sub-units) -- is to split the
**source** so each spec gets a 1:1 source file. That lets tests dictate
source structure. We reject it.

## Decision

**Test files mirror source files. Source structure is decided by design,
never by the number or shape of test files.**

Concretely, within a `test/<tool>/<category>/` directory:

- **One source file (lib) maps to one spec by default**, with name
  correspondence: `lib/<name>.sh` <-> `<name>_spec.bats` (flat, mirroring
  the flat `lib/`).
- **A lib that genuinely needs multiple sub-unit specs gets a `<name>/`
  folder** named after the source file; the sub-specs live inside it
  (`<name>/<subunit>_spec.bats`). The folder -- not a renamed flat file --
  is what restores alignment when a single source file has several test
  units. The folder's *presence* signals "this lib has multiple test
  units"; single-spec libs stay flat (no over-structuring), exactly as
  pytest / RSpec only foliate a module when it has multiple test files.
- **Never split a source `.sh` to achieve 1:1 test alignment.** Source
  structure follows the deep-module principle (a small interface over its
  private implementation helpers; see the architecture LANGUAGE). Splitting
  a generator's private `_emit_*` helpers into their own file just to give
  them their own spec exposes implementation across a file seam and makes
  the module shallower -- the tail wagging the dog.
- **Integration / end-to-end tests live with the orchestrator they
  exercise, not with a leaf lib.** A test that drives a whole pipeline
  (e.g. `setup apply`: detect -> resolve -> write_env -> drift) belongs in
  the orchestrator's spec (`setup_spec`), because that *is* what it tests.
  Only isolated single-unit tests move out to the leaf lib's spec.

The shard partitioner globs specs recursively (`test/<tool>/<cat>/**/*_spec.bats`)
so foldered sub-specs are first-class shard units -- a `<lib>/` folder
costs nothing for balancing; each file inside is still its own kcov unit.

## Consequences

- Every subsystem lib has a name-corresponding spec (or `<lib>/` folder),
  so "where are X's tests" is answerable from the lib name alone.
- The coverage shard floor drops as god-test-files split into
  source-aligned units; foldering (not source-splitting) handles libs that
  need several specs, so coverage granularity never pressures source
  cohesion.
- A mild asymmetry remains -- most libs have a flat `<lib>_spec.bats`, a
  few have a `<lib>/` folder. This is intentional and meaningful (folder ==
  multiple test units), matching the pytest / RSpec norm.
- Future test work, in base and downstream, must align to this rule. A
  lint check that flags a spec whose name matches no source file (or a
  source file with no spec) is a natural follow-up enforcement.

## Alternatives

- **Split the source file so every spec is 1:1 with a `.sh`.** Rejected:
  lets test-file count drive source structure, exposing private
  implementation helpers across file seams and shallowing deep modules.
  Industry frameworks (pytest, RSpec) explicitly do not require 1:1
  source<->test and instead foliate a module into a folder of specs when
  needed -- which is the accepted form of this ADR.
- **Keep multi-concern god-test-files, balance shards by count/time
  only.** Rejected: a single oversized file is an irreducible shard floor
  under kcov's per-file atomicity (ADR-00000008), and the files stay
  un-navigable (no lib<->spec correspondence). Better partitioning cannot
  beat the longest-single-file floor.
- **Always foliate every lib into a `<lib>/` folder for uniformity.**
  Rejected: over-structuring -- most libs have one cohesive test unit and a
  flat `<lib>_spec.bats` is clearer. Folder only when multiplicity is real.
