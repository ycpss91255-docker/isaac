# `test/<category>/<tool>/` subdir layout for multi-tool repos

- **Date:** 2026-06-05
- **Status:** Accepted

## Context

`base` itself is single-tool: every test under `test/` is a `.bats`
file, so `test/<category>/` (`smoke` / `unit` / `integration` /
`behavioural`) is unambiguous. But downstream repos that consume `base`
are increasingly multi-tool. Concrete example: `ycpss91255-docker/isaac`
keeps `.bats` smoke tests alongside Python entrypoints, so a
`test/smoke/test_foo.py` lands next to `test/smoke/*.bats`. Both a
`bats` runner and a `pytest` runner then see the same directory and
must pattern-filter to avoid collecting each other's files.

This bit real CI: `ycpss91255/isaac` PR #46 and
`ycpss91255-docker/isaac` PR #63 hit `pytest` collecting 0 tests from a
directory full of `.bats` -> exit 5 -> CI red, even though the workflow
had a skip-empty branch. Skip-checks that use `[ -d test/smoke ]` as
"do we have tests" become wrong the moment a second tool's files mix in.

There was no written convention for where a second tool's tests should
live, so each repo improvised.

## Decision

When a `test/<category>/` directory holds tests from **more than one**
tool/language, segregate by a `<tool>` subdirectory:

```
test/
├── unit/
│   ├── bats/        # *.bats
│   ├── pytest/      # test_*.py
│   └── gtest/       # *_test.cpp
├── smoke/
│   ├── bats/
│   └── pytest/
└── integration/
    └── ...
```

- **Category-first** (`test/unit/pytest/`, not `test/pytest/unit/`):
  keeps the TDD four-axis view (smoke / unit / integration / lint)
  intact so "what unit tests do we have" stays a single directory walk
  and `TEST.md` can organise by category without splitting across tools.
- **Single-tool repos stay flat.** `base` and any pure-bats / pure-pytest
  consumer do not migrate -- `test/unit/*_spec.bats` is fine. The
  sublayer is opt-in, appearing only when ambiguity does.

## Alternatives

- **Tool-first (`test/pytest/unit/`).** Rejected: fragments the
  category axis across tools, so the smoke/unit/integration view (and
  `TEST.md`) has to be reassembled per tool.
- **Flat with pattern-only filtering** (`test/unit/test_*.py` mixed with
  `test/unit/*_spec.bats`). Rejected: pushes tool-pattern knowledge into
  CI YAML skip-checks (`find test -name 'test_*.py' -print -quit`),
  which is easy to get wrong -- this is exactly the failure that
  prompted the convention.
- **Forcing the sublayer on single-tool repos.** Rejected: adds a layer
  of depth with zero benefit for `base` and other shell-only consumers.

## Consequences

- Downstream multi-tool repos have a documented target to migrate to;
  reference adoptions: `ycpss91255-docker/isaac#64`,
  `ycpss91255/isaac#38`/`#39`/`#40`/`#41`.
- `base` itself needs no layout migration; `init.sh` / new-repo
  scaffolding is unchanged.
- If `base` later adopts a `TEST.md` schema shared across downstream, it
  should accept either the flat `test/<category>/` or the sublayered
  `test/<category>/<tool>/` shape.
- An optional lint/hook to warn when a `test/<category>/` mixes runner
  file extensions is tracked separately as a backlog item (#495); it is
  not part of this convention.
- Out of scope: cross-tool shared fixtures (`test/_helpers/`),
  cross-tool coverage merging, and IDE discovery hints
  (`pyproject.toml`'s `[tool.pytest.ini_options].testpaths` handles the
  last per-repo). Defer until needed.
