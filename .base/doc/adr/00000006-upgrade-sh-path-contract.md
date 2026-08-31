# upgrade.sh hard-coded paths are a protocol-stable contract

> Serves: PRD invariant 6 (base is a subtree; downstream a thin caller)
> -- the upgrade.sh frozen-path contract; mechanism.

- **Date:** 2026-06-08
- **Status:** Accepted
- **Amended:** 2026-06-24 by #654 / ADR-00000011 §8 -- Region A's frozen
  `.base/init.sh` root path is superseded. `init.sh` and `upgrade.sh` now
  live deep at `.base/dist/script/base/` and self-locate the subtree
  root via a walk-up (see the Region A note below); the lockstep discipline
  this ADR mandates is what governed that move.
- **Amended:** 2026-06-26 by #714 -- the shipped-tree directory was renamed
  `downstream/` -> `dist/`, so every frozen interior path moves from
  `.base/downstream/...` to `.base/dist/...` (this supersedes the
  `.base/downstream/` contract introduced by #625 / #654). The rename was a
  lockstep change exactly as this ADR mandates: `upgrade.sh` /
  `init.sh`'s subtree-root marker check, the Region B config-drift paths
  (`${TEMPLATE_REL}/dist/config[/docker/setup.conf]`), the Region A Step-3
  `init.sh` call, and the Region C `dockerfile_migrate` lib all moved in the
  same change. **Consumer migration:** an existing consumer on
  `.base/downstream/` that upgrades gets `.base/dist/` after the subtree
  pull, leaving its repo-level wrapper symlinks
  (`script/build.sh -> .base/downstream/...`) dangling; the upgrade->init
  resync heals them because `init.sh`'s `_symlink` helper `rm -f`s the stale
  link and re-`ln -sf`s it at `.base/dist/...` (so stale `.base/downstream/`
  symlinks are dropped and re-pointed). `dockerfile_migrate` migration 4 was
  widened to match `(downstream/|dist/)?` so a consumer Dockerfile on either
  historical path heals to the `dist/` target.
- **Amended:** 2026-07-15 by #831 -- `setup.conf` is `just setup`-managed,
  not hand-edited, so it left the hand-editable `config/` surface: the
  per-repo override moved from `<repo>/config/docker/setup.conf` to the
  repo-root dotfile `<repo>/.setup.conf`, and the template default from
  `${TEMPLATE_REL}/dist/config/docker/setup.conf` to
  `${TEMPLATE_REL}/dist/.setup.conf`. Per this ADR's discipline the move
  was lockstep: Region B's `_warn_setup_conf_drift` blob-hash path
  re-points to `dist/.setup.conf`, and a new `_migrate_legacy_setup_conf`
  step `git mv`s a legacy override to the root and warns loudly (never
  silently drops it). See the re-pointed frozen-path list note below.
  This reverses #262, which had nested setup.conf under `config/docker/`
  for layout uniformity.

## Context

`upgrade.sh` runs entirely from the downstream repo root and drives the
`.base/` subtree forward to a target tag. Most of its filesystem
references are derived from a single `TEMPLATE_REL` anchor (the basename
of the directory the script lives in, today `.base`), so renaming the
subtree prefix itself stays cheap. But three regions reach *into* the
subtree at hard-coded sub-paths that `TEMPLATE_REL` does not abstract
away. #477 already hit this wall once: `_verify_subtree_intact` asserted
specific files at fixed paths and broke on the v0.39.0
`script/docker/setup.sh` -> `wrapper/setup.sh` reorg; it was fixed with a
structural invariant (subtree dir non-empty + well-formed `.version` +
target-version match) that no longer names interior paths.

The #477 audit surfaced three *sibling* path-coupling regions in the same
file that were deliberately left out of the structural-invariant fix and
recorded as backlog in #492. Each would hit the same wall on the next
reorg that touches its paths:

- **Region A -- direct `init.sh` invocation.** `_main` Step 3 calls
  `"./${TEMPLATE_REL}/init.sh"` for the symlink / `.gitignore` resync,
  and the `--gen-conf` branch delegates to
  `"./${TEMPLATE_REL}/init.sh" --gen-conf`. If `init.sh` is renamed or
  relocated, Step 3 fails with `No such file or directory` *after* the
  subtree pull has already landed, and the pull is **not rolled back**
  (the rollback path only fires from `_verify_subtree_intact` in Step 2).
  The repo is left half-upgraded: subtree pulled, but symlinks /
  `main.yaml` `@tag` / `.gitignore` not resynced.

  > **Amended 2026-06-24 (#654, ADR-00000011 §8).** `init.sh` was
  > relocated out of the subtree root to
  > `.base/dist/script/base/init.sh` (with `upgrade.sh` alongside).
  > Per this ADR's lockstep discipline the move was done in one slice that
  > also updated Step 3's call to
  > `"./${TEMPLATE_REL}/dist/script/base/init.sh"` (both the resync
  > and `--gen-conf` invocations). Critically, `upgrade.sh` no longer
  > derives `TEMPLATE_REL` from its own directory's basename (which is now
  > `base`, the wrong prefix): it **walks up** from its location to the
  > subtree root -- the dir carrying the `.version` + `dist/` markers
  > -- and `basename`s THAT (`.base`), so the `git subtree pull --prefix=`
  > flag and every interior path stay correct regardless of nesting depth.
  > The new self-location walk-up IS the contract that replaces the frozen
  > `.base/init.sh` root path; an integration test asserts the resolved
  > `--prefix` is the subtree basename, not `base`.

- **Region B -- `config/` drift detection.** The pre-pull snapshot
  (`HEAD:${TEMPLATE_REL}/config` and
  `HEAD:${TEMPLATE_REL}/config/docker/setup.conf`) and the post-pull
  `_warn_config_drift` / `_warn_setup_conf_drift` family compare tree /
  blob hashes at those fixed paths. If `config/` or
  `config/docker/setup.conf` moves, `git rev-parse --verify` returns
  nothing, so the entire drift-warning module silently no-ops (or, if
  only one side moves, emits false positives). The user loses the
  "upstream baseline changed -- reconcile your override" signal with no
  error -- the most dangerous failure mode, because it is silent.

- **Region C -- Dockerfile lint-stage auto-patch.** Step 5 (and the
  sibling #399 wrapper-copy patch) `grep` + `sed` the downstream
  `Dockerfile` to inject `COPY .base/script/docker/lib /lint/lib` and to
  rewrite `COPY *.sh /lint/` -> `COPY script/*.sh /lint/`, healing the
  #284 `lib/` split and the #330 wrapper consolidation. These hard-code
  `.base/script/docker/lib/` and the `script/docker/*.sh` umbrella-loader
  location. If `lib/` is relocated or the umbrella loaders move, the
  sed-generated `COPY` points at a wrong source and the downstream build
  stage fails with `COPY source not found`.

#492 chose to defer the *fix* (no path has an active relocation plan) and
to label it `backlog`, with a trigger checklist requiring any future
reorg of these paths to cross-reference the issue. #492's own body lists
three future-direction options -- ADR-frozen contract, a path-manifest
file, or `find`/glob discovery -- and notes that if the ADR route is
taken, the issue can be closed with a link to it. This ADR is that route.

## Decision

Declare the following `.base/` interior paths **protocol-stable**: they
are part of the contract `upgrade.sh` depends on, and **must not be moved
or renamed without updating `upgrade.sh` in the same change** (and
re-checking #492's trigger checklist):

- `.base/init.sh` -- invoked directly by Region A. *(Superseded
  2026-06-24 by #654: now `.base/dist/script/base/init.sh`, located
  via `upgrade.sh`'s walk-up to the subtree root rather than frozen at the
  root; see the Region A amendment above.)*
- `.base/config/` and `.base/config/docker/setup.conf` -- hashed by
  Region B's drift detection. *(Re-pointed 2026-07-15 by #831: the
  setup.conf blob is now `.base/dist/.setup.conf` (template default) with
  the downstream override at the repo-root `<repo>/.setup.conf`; the
  `.base/dist/config/` tree hash still guards the hand-editable shell
  config. #714 first moved these under `dist/`.)*
- `.base/script/docker/lib/` and the `.base/script/docker/*.sh` umbrella
  loaders -- targeted by Region C's Dockerfile auto-patch.

"Protocol-stable" means: these are not free-to-refactor implementation
details. A reorg may still move them, but only as a deliberate,
`upgrade.sh`-aware change -- the same discipline `TEMPLATE_REL` already
gives the subtree prefix, extended by convention to these interior paths.
The break consequences recorded per region above are the contract's
teeth: A leaves a half-upgraded repo with no rollback, B fails silently,
C breaks the next downstream build.

This closes #492: the issue's "if a future decision freezes these paths
as permanent contract (e.g. via an ADR), this issue can be closed and
replaced with a link to that ADR" condition is now met.

## Alternatives

- **Path-manifest file** (`.base/.path-manifest.txt` listing the actual
  paths; `upgrade.sh` reads from it). Same shape as the R2 design floated
  in the #477 grill, but for path discovery rather than integrity. It
  would let paths move by editing one declarative file -- but it adds a
  new artifact that must itself be kept in sync, ships in every subtree
  pull, and introduces a parse/validation surface. Rejected: it trades a
  remembered convention for a new moving part, for paths that have no
  relocation pressure.
- **`find` / glob discovery** (locate `init.sh` / `config/setup.conf` /
  `lib/` dynamically within `.base/`). Removes the path dependency
  entirely, but makes `upgrade.sh` guess intent: a glob that matches two
  candidates, or zero, has to decide what to do at the worst possible
  moment (mid-upgrade, post-pull). It also masks accidental moves instead
  of surfacing them, which is the opposite of what the silent-failure
  Region B needs. Rejected as over-engineering for a non-problem.
- **Do nothing beyond the #492 backlog note.** Leaves the contract
  implicit -- discoverable only by reading `upgrade.sh` or stumbling onto
  the issue. Rejected: the contract is load-bearing across every
  downstream upgrade and deserves a durable, linkable home.

## Consequences

- The convention must be *remembered*. This ADR plus #492's trigger
  checklist are the memory: any reorg touching the frozen paths is
  expected to cross-reference both and update `upgrade.sh` in lockstep.
  This is the accepted cost of choosing a frozen contract over a manifest
  or discovery -- no new code, no new file, no new parse surface, in
  exchange for a discipline a human (or agent) must hold.
- No code changes. `upgrade.sh` keeps its current hard-coded paths; this
  ADR ratifies them as intentional rather than incidental.
- The three break modes are now documented in one place, so a future
  maintainer who *does* need to move one of these paths knows exactly
  what to repair (Region A: add rollback or move the call; Region B:
  update both pre- and post-pull path pairs; Region C: update the
  grep+sed source paths) rather than rediscovering it from a failed
  upgrade.
- Complements the #477 `_verify_subtree_intact` R1+ structural invariant:
  #477 made the *integrity check* path-agnostic; this ADR freezes the
  *remaining* interior paths that could not be made path-agnostic without
  a manifest or discovery. The two together define the full path-coupling
  posture of `upgrade.sh`.
- #492 is closed with a link to this ADR. Future relocation pressure on
  any frozen path reopens the design question (manifest vs discovery) at
  that time, against a concrete need, rather than speculatively now.

