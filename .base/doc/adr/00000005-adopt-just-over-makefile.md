# Adopt `just` over the Makefile wrapper

- **Date:** 2026-06-08
- **Status:** Accepted

## Context

RFC #330 introduced `script/docker/Makefile` as a single, discoverable
entry point: thin wrappers (`make build` / `make run` / `make exec` /
...) that forward 1:1 to `./script/*.sh`. The goal was discoverability
(`make help`) and one muscle-memory verb per operation.

The wrapper has not held that line. GNU make's argv handling collides
with the docker-native syntax the wrappers are supposed to expose, and
every new arg pattern that lands forces the Makefile to invent another
escape hatch:

- #414 -- `_check_overrides` inspects `MAKEOVERRIDES` to abort on
  `VAR=VALUE` tokens, because make silently swallows them otherwise.
- #448 -- a mandatory `--` separator before flags, because `--target`
  and friends collide with the wrapper's own `-t/--target`.
- #469 -- an `EXEC_ARGS` env-var passthrough, because `=`-bearing
  tokens get caught by `MAKEOVERRIDES`.

Each hole patched begets the next: a new docker-native token hits
another make-level restriction, the wrapper drifts further from the
docker CLI it is meant to mirror, and users now have to remember which
case takes which escape hatch. The Makefile no longer reads as "thin
forwarder" -- a new reader cannot tell at a glance why it is this
complex.

This was raised right after #469 shipped, while the pain is fresh: the
wrapper's usage keeps getting further from how docker itself works.
The unwind cost is still low (we have not extended into more wrappers
or a third-party runner yet), and all 13 downstream repos symlink this
one Makefile, so any breaking change requires a batch fanout -- the
earlier we decide, the cheaper.

The triggering issue (#475) only captured the decision and the
alternative landscape; it did not pick a direction. This ADR records
the chosen direction and its rationale. The implementation is tracked
in follow-up issues.

## Decision

**Adopt `just` (a `justfile`) as the user-facing entry point**, in
place of the GNU make wrapper.

The root cause is GNU make treating `VAR=VALUE` tokens as variable
overrides and consuming `--`/`-flag` argv for itself. `just` does not:
recipe arguments and trailing arguments pass through cleanly to the
underlying `./script/*.sh`, so the #414 / #448 / #469 workarounds
disappear rather than accreting further. A recipe like

```just
run *args:
    ./script/docker/run.sh {{args}}
```

forwards `just run -t headless --gpus all` verbatim -- no
`MAKEOVERRIDES` guard, no mandatory `--` separator, no `EXEC_ARGS`
shim.

**Rollout is additive first, retirement second**, split so the
breaking change is deliberate:

1. **Additive `justfile` introduction.** Land the `justfile` in
   `base` alongside the existing Makefile. Both work; users and CI can
   migrate on their own schedule. No downstream break.
2. **Makefile retirement + downstream fanout.** Once the `justfile` is
   proven, remove the Makefile wrapper and roll the removal to all 13
   downstream repos via the batch base-tag fanout. The retirement is
   *bound to* that fanout -- it does not ship until the migration path
   is wired -- because the Makefile is symlinked, not copied, so a
   `base` removal would otherwise break every downstream simultaneously.

**External dependency is accepted.** `just` is a third-party runner
that downstream users must install. It is bundled into the CI images,
so the gated path (CI, the docker_harness self-test loop) carries it
without per-user action. For interactive dev hosts, installation is a
one-line documented step. The smaller community vs. make is judged an
acceptable cost against make's structural argv mismatch.

## Open questions (resolved)

- **Is "single entry point" a hard requirement?** Nice-to-have, not
  hard. `just` happens to preserve it (one verb per op, same as
  `make`), but the decision did not hinge on it -- if it had been a
  hard requirement it would only have ruled out option A
  (raw scripts), and `just` keeps the single-entry property regardless.
- **What replaces `make help` discoverability?** `just --list`, which
  enumerates recipes with their doc comments natively -- no
  hand-maintained `help` target.
- **How do the 13 downstream repos migrate?** Via the batch base-tag
  fanout (`/batch-base-upgrade` + `/batch-pr`), bound to the
  Makefile-retirement step above; not a per-repo deprecation grace
  period.
- **Are there `make build` / `make test` callsites in CI / GHA?** Yes,
  assumed -- a grep-and-update sweep across `.github/workflows/` (and
  any helper scripts) is part of the retirement step.
- **Do IDE / editor task configs hardcode `make`?** Where present
  (`.vscode/tasks.json` etc.), they are caught by the same
  grep-and-update sweep and re-pointed at `just`.
- **`Makefile.ci`?** Out of scope (per #475). It is a dev-loop / CI
  lint+test wrapper, not a user-facing container-ops wrapper, and its
  argv surface does not hit the same make restrictions.

## Alternatives

- **A -- retire to raw `./script/*.sh` directly** (`./build.sh test`,
  `./run.sh -t headless`). Most docker-native and lowest ongoing
  maintenance, and it sidesteps make's argv problem entirely. Rejected
  because it drops the single discoverable entry point and the
  `make help`-style listing, and forces every user to re-learn paths
  and per-script flags. The discoverability win of a runner verb was
  judged worth one external dependency.
- **B -- custom single-dispatcher CLI** (`./bs build`, `./bs run -t
  headless`): one binary that routes to the wrappers with full argv
  control. Keeps single-entry + discoverability and solves the argv
  problem. Rejected because it reinvents exactly the recipe-runner
  parts that `just` already provides as a tested, documented tool --
  new surface to build and maintain, with fresh implementation-bug
  risk, for no capability `just` lacks.
- **D -- keep the Makefile, keep patching.** Cheapest short-term, zero
  migration. Rejected because it is the status quo whose cost this ADR
  exists to stop: every workaround is mental tax, the divergence from
  the docker CLI keeps widening, and each patched hole begets the next.
  The accumulated #414 / #448 / #469 pattern is the evidence that this
  does not converge.

## Consequences

- The #414 / #448 / #469 workarounds are retired with the Makefile, not
  carried forward: clean recipe + trailing-args passthrough replaces
  the `MAKEOVERRIDES` guard, the mandatory `--` separator, and the
  `EXEC_ARGS` shim. (Per #475 these are removed *with* the wrapper, not
  reverted in isolation.)
- An external dependency (`just`) enters the dev-host toolchain. CI
  images bundle it; interactive hosts install it via a documented
  one-liner.
- `make help` is replaced by `just --list` (recipe doc comments),
  removing the hand-maintained help target.
- Two-phase rollout, tracked as two follow-up implementation issues:
  (1) additive `justfile` introduction in `base`; (2) Makefile
  retirement + 13-repo batch fanout. The retirement is gated on the
  fanout because downstream repos symlink the Makefile.
- A grep-and-update sweep is required across CI / GHA workflows and IDE
  task configs (`.vscode/tasks.json` etc.) to re-point `make` callsites
  at `just`.
- Doc churn: README + `README.zh-TW.md` + CHANGELOG across `base` and
  downstream, plus user muscle memory (`make X` -> `just X`).
- `Makefile.ci` is unaffected (out of scope); the CI lint/test entry
  stays on make.

