# Layered `just` entry + base/downstream directory split

> Serves: PRD invariant 6 (base is a subtree; downstream a thin caller)
> -- established the `dist/` split + layered `just` entry.

- **Date:** 2026-06-22
- **Status:** Accepted
- **Amends:** ADR-00000006 (frozen `.base/` interior paths move; see below)
- **Builds on:** ADR-00000005 (`just` as the user-facing entry)
- **Amended:** 2026-07-15 by #831 -- the tool-managed `setup.conf` leaves
  the config-layer. It is `just setup`-managed, not hand-edited, so the
  per-repo override moves out of `<repo>/config/docker/setup.conf` to the
  repo-root dotfile `<repo>/.setup.conf` (template default
  `dist/config/docker/setup.conf` -> `dist/.setup.conf`). This makes the
  criterion explicit: `config/` is the HAND-EDITABLE surface (shell
  config) only; the tool-managed file is a root dotfile. Region B's
  drift-hash path re-points in the same lockstep slice (see the Region B
  note below), and `upgrade.sh` auto-migrates a legacy override.
  Reverses #262, which had nested it under `config/docker/` for layout
  uniformity.

## Context

Two problems converged:

1. **No extension point for repo-local recipes (#594).** The downstream
   user-facing entry is a single `justfile` symlinked to
   `.base/script/docker/justfile` with a fixed recipe set (`build` /
   `run` / `exec` / `stop` / `prune` / `setup` / `setup-tui` /
   `upgrade`). A repo that wants its own recipe (e.g. a deploy or
   per-repo orchestration command) has no clean path: editing the
   symlink target edits base (overwritten on subtree pull); committing a
   real `justfile` is clobbered back to the symlink by `init.sh`. So
   repo-specific commands fall back to `./script/*.sh`, off the
   `just --list` discovery path.

2. **base mixes two audiences in the same trees.** `script/docker/`,
   `config/`, `dockerfile/`, and `test/smoke/` each contain material that
   is *shipped to consumers* alongside material that is *base's own dev /
   CI tooling*, with no structural line between the two. base's own
   self-test entry (`justfile.ci`) sits at the repo root next to the
   downstream-facing `justfile`.

While designing the extension point, several `just` facts (verified on
`just` 1.52) constrained the solution:

- An `import` path inside a justfile reached **via symlink** resolves
  relative to the *symlink's location* (the repo root), not the symlink
  target's real directory.
- A **duplicate recipe name across `import` is a hard error** (not a
  shadow). So repo-local recipes cannot be imported top-level alongside
  the docker recipes -- a single `build:` collision would break *every*
  recipe.
- `mod?` gives a **sub-command namespace** (`just <ns> <recipe>`); a
  module recipe's default cwd is the module file's own directory.
- `mod?` lines living inside an *imported* file still create **top-level**
  namespaces, and their module paths resolve relative to that imported
  file's own directory.
- `import?` / `mod?` of a missing file is not an error.

## Decision

### 1. Layered entry, docker top-level, everything else namespaced

The downstream entry becomes a thin aggregator:

```just
import  'script/docker/justfile.docker'        # docker recipes -> TOP-LEVEL (just build/run/...)
mod?    ci        'script/ci/justfile.ci'      # just ci ...
mod?    cd        'script/cd/justfile.cd'      # just cd ...
mod?    template  'script/template/justfile.template'   # just template ... (help + new)
import? 'script/local/justfile.local'          # repo-owned registry of user groups
default:
    @just --list
```

Docker recipes stay top-level (`just build`); **every other group is a
`mod?` namespace** (`just ci|cd|template|<group> ...`). This is forced by
the duplicate-name hard error: namespacing via `mod?` is the only
collision-proof mechanism, and it doubles as the add-only guarantee
(`local` can never override `build`).

### 2. base/downstream directory split

Everything shipped to consumers lives under a base-root `dist/`
folder that **mirrors a consumer's layout**; base's own tooling stays in
base-root `script/` + `test/`. The `.base/` subtree carries both, but
consumer symlinks only ever point into `.base/dist/`.

base repo:

```
dist/                 # [SHIPS] consumer side = .base/dist/
  script/
    justfile                # the entry (no suffix)
    docker/   justfile.docker  lib/ runtime/ wrapper/
    ci/       justfile.ci  *.sh
    cd/       justfile.cd  *.sh
    template/ justfile.template  new.sh  skel/
  config/                   # default config layer (consumer overlays per-file)
  dockerfile/Dockerfile     # consumer Dockerfile template (was Dockerfile.example)
  test/smoke/
  .hadolint.yaml
script/                     # [BASE-OWN] dev / CI / release
  ci/  justfile.ci  ci.sh  lint_*.sh
  cd/  justfile.cd
test/  unit/ integration/ behavioural/
dockerfile/Dockerfile.test-tools
```

consumer (after init):

```
<repo>/
  justfile                SYMLINK -> script/justfile
  script/
    justfile              SYMLINK -> .base/dist/script/justfile   (identical to base; auto-flows)
    docker/  justfile.docker + build.sh ... setup_tui.sh   SYMLINK -> .base/dist/script/docker/...
    ci/ cd/ template/      SYMLINK -> .base/dist/script/...
    local/                # REPO-OWNED (seeded once, committed, never clobbered)
      justfile.local      #   registry; entry import?s it; `just template new` appends here
      <name>/ justfile.<name> <name>.sh
```

### 3. Ownership: symlink entry, repo-owned registry

`script/justfile` is a **pure symlink, byte-identical to base** (base
improvements auto-flow). It is never written. New groups register in the
**repo-owned** `script/local/justfile.local` (seeded once by `init.sh`,
committed, never clobbered), which the entry `import?`s. This resolves
the tension between "the entry should track base" and "new-group must
write somewhere persistent": the writable surface is `script/local/`, not
the entry.

### 4. `just template new <name>` scaffolding

`just template new <name>` creates `script/local/<name>/justfile.<name>`
+ `<name>.sh` from `dist/script/template/skel/` and appends a
`mod?` line to `script/local/justfile.local` (idempotent). Bare
`just template` prints help. The mechanism is discoverable out of the box
(a seeded example), replacing #594's original `import?` plan, which the
duplicate-name hard error makes unworkable for an add-only top-level
import.

### 5. Naming

- `Dockerfile` (was `Dockerfile.example`): `.example` only disambiguated
  it from `Dockerfile.test-tools` in a shared folder; the `dist/`
  location now disambiguates, and it maps 1:1 to the consumer
  `Dockerfile`.
- `Dockerfile.test-tools` keeps its suffix: it *names the image it
  builds*, not mere disambiguation.
- Group files align to the group name: `justfile.<name>` + `<name>.sh`.
- `ci` and `cd` are **separate** namespaces/folders (not merged
  `cicd`); CD pipeline *content* is deferred to a future issue, this only
  lays the `cd/` skeleton + wiring.

## Amendment to ADR-00000006

ADR-00000006 froze three `.base/` interior path regions that
`upgrade.sh` hard-codes. This refactor moves two of them, so per that
ADR's own discipline `upgrade.sh` is updated **in lockstep**, region by
region, in the slice that moves each path:

- **Region A (`.base/init.sh`)** -- unchanged. `init.sh` stays at the
  base root.
- **Region B (`config/` drift detection)** -- `config/` moves to
  `dist/config/`. The pre/post-pull snapshot paths
  (`HEAD:${TEMPLATE_REL}/config`,
  `.../config/docker/setup.conf`) move to
  `${TEMPLATE_REL}/dist/config[/docker/setup.conf]` in the same
  slice that relocates `config/`. *(Amended 2026-07-15 by #831: the
  setup.conf blob snapshot further moves to
  `${TEMPLATE_REL}/dist/.setup.conf` and the downstream override to
  `<repo>/.setup.conf`, as setup.conf leaves the config-layer; the
  `config/` tree hash keeps guarding the hand-editable shell config.)*
- **Region C (Dockerfile lint-stage auto-patch)** -- `script/docker/lib/`
  and the `script/docker/*.sh` umbrella loaders move under
  `dist/script/docker/`. The grep+sed source paths
  (`COPY .base/script/docker/lib`, the `script/*.sh` umbrella) move in
  the same slice that relocates `lib/` and the wrappers.

The frozen-path **list** in ADR-00000006 is hereby re-pointed to the
`dist/` locations; the contract (move only as a deliberate,
`upgrade.sh`-aware change) is unchanged and reaffirmed.

## Consequences

- **Breaking for consumers.** Wrappers move from flat `script/*.sh` to
  `script/docker/*.sh`; the entry becomes a symlink chain; `script/local/`
  is seeded. Every downstream repo must subtree-upgrade past this tag and
  re-init (the fanout slice). Direct `./script/build.sh` callers break;
  the `just`-first migration (ADR-00000005) covers this.
- **Subtree dead weight.** The `.base/` subtree carries base's own
  `script/` + `test/` into every consumer. Accepted: it is the subtree
  model's cost, and `dist/` makes the shipped-vs-own line legible.
- **Extensibility without a generator.** `just` has no glob import, so
  auto-discovery is impossible; the fixed base namespaces (`ci`/`cd`/
  `template`) are wired statically and user groups self-register in the
  repo-owned `script/local/justfile.local`. No generated aggregator, no
  re-generation step.
- The work lands as a tracked epic of thin vertical slices (base reorg ->
  justfile mechanism -> consumer fanout -> folded #607), each gated by
  the base self-test; `just`-fact regressions (symlink import resolution,
  duplicate-name) are locked with tests.

## Alternatives

- **`import? 'justfile.local'` top-level (the original #594 plan).**
  Rejected: a repo-local recipe colliding with a base recipe name is a
  hard error that breaks the whole `just`, not a shadow. Namespacing via
  `mod?` is required.
- **Modules with `local::` prefix for everything.** Rejected for the
  docker recipes (`just local::build` is worse UX than `just build`);
  kept only for the genuinely repo-local groups.
- **Keep the flat single justfile, add a second imported file.** Does not
  give the base/downstream audience split, and still hits the
  duplicate-name problem for top-level additions.
- **Path-manifest / glob discovery for upgrade.sh paths.** Already
  rejected in ADR-00000006; unchanged here -- the path move is a
  deliberate lockstep edit, exactly the discipline that ADR ratified.
