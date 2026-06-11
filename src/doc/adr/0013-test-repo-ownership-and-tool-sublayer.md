# Test Ownership Boundary + `test/<category>/<tool>/` Layout

ADR-0011 split tests across two runner classes (hosted vs self-hosted GPU) but left two questions unresolved: which *repo* owns each test class, and how to colocate tests written for different runners (bats / pytest / future gtest) without breaking discovery. Both gaps surfaced concretely during local validation of `#46` + `ycpss91255-docker/isaac#63`: the workspace's `smoke-test.yaml` tried to reach across a submodule into the docker container, and the docker repo's `python-tests` job collected zero tests because the skip-check could not distinguish a directory of `.bats` files from a directory of pytest files.

**Decision**: (1) `ycpss91255-research/isaac` (this repo, transferred from `ycpss91255/isaac` on 2026-05-28 -- see ADR-0012) owns *unit* tests only; `ycpss91255-docker/isaac` owns *smoke* and *integration* tests. (2) Adopt the `test/<category>/<tool>/` sublayer in any repo whose `test/<category>/` contains tests from more than one tool/language.

## Considered Options — repo ownership

- **(a) Workspace owns all test categories; docker repo reused as image only.** Rejected: smoke + integration tests need the Isaac Sim + ROS 2 environment that lives in docker repo. Running them from workspace forces a cross-repo mount (compose mounts `.:/source` = docker dir, so workspace sees nothing inside the container by default); the workflow either grows a custom `docker run -v` chain that bypasses the wrapper scripts, or every `script/exec.sh` consumer learns extra mount flags. Both leak workspace details into the env layer.
- **(b) Docker repo owns all test categories; workspace owns only application code.** Rejected: unit tests for `import_model.py` / `material_setup.py` / `sensor_setup.py` / `scene_builder.py` are pure Python with zero Isaac Sim dependency. Moving them into docker repo (a) costs every contributor a container build to iterate on a 1-line change, and (b) inverts the natural locality — the test should sit next to the code it exercises.
- **(c) Workspace owns unit, docker repo owns smoke + integration** (**chosen**). Matches the natural dependency direction: unit tests have *no* env dependency and travel with the code; smoke and integration tests depend on the image entrypoint chain and travel with the image. Each repo's CI runs only what it owns.

## Considered Options — layout for multi-tool `test/<category>/`

- **(A) Flat with pattern filter.** `test/<category>/` mixes `*.bats`, `test_*.py`, `*_test.cpp`; each runner filters by pattern. Rejected: workflow skip-checks become tool-aware (`find test -name 'test_*.py' -print -quit`), which is exactly the surface that produced the `exit 5` failure in `#63`'s first iteration. Pattern knowledge leaks into every workflow and Makefile that wants to know "do we have pytest tests yet".
- **(B) Category-first, tool-second.** `test/unit/pytest/`, `test/unit/bats/`, `test/smoke/pytest/`, `test/smoke/bats/`. Skip-checks become `[ -d test/<category>/<tool> ]` and never look inside files. (**chosen**)
- **(C) Tool-first, category-second.** `test/pytest/unit/`, `test/bats/smoke/`. Rejected: breaks the TDD 4-axis mental model (`smoke / unit / integration / lint`) that `doc/test/TEST.md` and ADR-0011 are organized around; asking "what unit tests does this repo have" stops being a single directory walk. Tool is an implementation detail; category is the human-facing axis.

## Where this lives

`base#473` carries the org-wide convention so other downstream consumers (`seggpt`, `sam_manager`, future Isaac-ecosystem repos) follow the same pattern. `ycpss91255-docker/isaac#64` is the local adoption issue. Single-tool repos (e.g. `base` itself, all `.bats`) stay flat — the sublayer is opt-in when ambiguity appears, not a mandate.

## Concrete impact on in-flight work

- This PR (`#46`) drops `.github/workflows/smoke-test.yaml` and retargets `unit-test.yaml` at `test/unit/pytest/`. No workspace-owned smoke job remains.
- `ycpss91255-docker/isaac#63` adopts Layout B for repo-local bats (5 files moved to `test/smoke/bats/`) and rewrites the `python-tests` skip-check to inspect `test/<category>/pytest/`.
- The four implementation PRs (`#38` `#39` `#40` `#41`) move their unit tests from `test/unit/test_*.py` to `test/unit/pytest/test_*.py` and update the `parents[2]` → `parents[3]` `sys.path` climb. Done in the same change set per the `P` rollout choice (full migration now, not deferred).
- Future workspace smoke tests do *not* land in `ycpss91255-research/isaac/test/smoke/`; they are written against `ycpss91255-docker/isaac` and exercised by that repo's `python-tests` job once the runtime-test stage carries pytest (issue **#59** closed, PR **#60** merged).

## Cross-repo gating

Out of scope for this ADR. If we later want docker repo's smoke job to gate workspace merges, the `workflow_run` event + `repository_dispatch` are the tools; we revisit when the second downstream consumer of CoreSAM exists (Rule of Three).

## References

- ADR-0011 — CI architecture: hosted vs self-hosted runner split.
- ADR-0012 — `ycpss91255-research` org split + dual org-level GPU runners (the org-boundary decision this ADR's repo-ownership rule sits on top of).
- `ycpss91255-docker/base#473` — proposed org-wide `test/<category>/<tool>/` convention.
- `ycpss91255-docker/isaac#64` — local adoption tracking issue.
- `ycpss91255-docker/isaac#63` — first PR carrying the layout (bats moved + skip-check rewritten).
- `ycpss91255-research/isaac#46` — this PR (workspace CI workflows).
- `ycpss91255-research/isaac#38` / `#39` / `#40` / `#41` — implementation PRs migrating to `test/unit/pytest/`.

## Update (2026-06-11) -- re-derivation under the mount model (ADR-0017), not voiding

This ADR rejected "the docker repo owns all test categories" (Considered Option (b)) on two
grounds: (1) moving pure-Python unit tests into the docker repo costs every contributor a
container build to iterate on a one-line change, and (2) locality inversion -- tests should
sit next to the code they exercise, which lived in the research workspace.

Both premises have since changed, and re-deriving from this ADR's own principles now lands on
the opposite ownership:

- **The mount model voids (1).** Under ADR-0017 the framework is mounted into the container,
  not baked into the image; unit and import-safety tests run hosted, pure, with zero Isaac
  dependency and zero container build. The contributor cost this ADR was protecting against
  no longer exists.
- **The monorepo merge flips (2).** The research -> docker merge (`ycpss91255-docker/isaac#78`)
  moved the framework code into this repo, so "tests follow code" -- this ADR's own locality
  principle -- now points at the base repo, not away from it.

Framework tests (unit + import-safety, hosted) and the example end-to-end tests (integration,
GPU) living in this repo is therefore a **continuation** of this ADR's reasoning, not a
violation of it. The `test/<category>/<tool>/` sublayer decision is untouched and remains the
layout for the converged repo. See ADR-0017 ("Amendment: ADR-0013") for the successor
contract this re-derivation feeds.
