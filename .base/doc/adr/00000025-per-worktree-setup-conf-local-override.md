# Per-worktree `.setup.conf.local` override, and one resolved project name

> Serves: PRD invariant 9 (runtime-name divergence comes from an explicit,
> file-recorded override) -- established by this decision; also invariant 2
> (never fail silently: the shadowed-write warning, the deploy refusal, the
> config-summary row) and invariant 8 (dev/field separation: the field
> refusal).

- **Date:** 2026-08-05
- **Status:** Accepted
- **Relates to:** issue #893 (this decision), #891 / #892 (the same
  collision on the test path, fixed there), #600 (removal of
  `--instance` / `INSTANCE_SUFFIX` / `config/instances/` -- NOT reversed
  here, see sec. 6), #201 (removal of the earlier committed
  `setup.conf.local` -- sec. 2), #879 (retired the leftover `.gitignore`
  line -- sec. 7), #875 (one question, several answerers -- sec. 4);
  ADR-00000001 (setup.conf is the main path), ADR-00000003 (env vs
  workload boundary), ADR-00000011 (naming convention / `dist` layout),
  **ADR-00000022** (compose<->multi_run overlay contract -- amended
  in-file with a pointer to sec. 5's division of labour),
  ADR-00000023 (config field-override + field-deploy contract -- sec. 8
  extends its dev/field split to an untracked config layer).

## Context

Two worktrees of one repo could not be run at the same time, and there was
no way to make them differ.

This is verified rather than assumed. `run.sh` loads `.env.generated` and
then calls `_compute_project_name`, which assigned unconditionally:

```bash
PROJECT_NAME="${DOCKER_HUB_USER:-local}-${IMAGE_NAME:-$(basename -- "${FILE_PATH:-${PWD}}")}"
```

There was no `${PROJECT_NAME:-...}`, so exporting `PROJECT_NAME` was
overwritten. `COMPOSE_PROJECT_NAME` was ignored because `_compose_project`
passes `-p` explicitly and an explicit `-p` beats the environment. And
`.env.local` was never loaded on that path. The only lever left was
`IMAGE_NAME` or `DOCKER_HUB_USER` -- which also moves the **image tag**,
coupling two things that should be independent: which containers a run
owns, and which image it built.

Underneath the missing lever sat a second problem. The compose emitter
wrote `name: ${DOCKER_HUB_USER}-${IMAGE_NAME}` into `compose.yaml` while
the wrapper assembled the same string in bash, and the CLI `-p` silently
won over the file. Two independent answerers to one question that happened
to agree -- the #875 shape.

## Decision

### 1. A gitignored `<repo>/.setup.conf.local`, overriding any section

The conf chain becomes three files, lowest precedence first:

| Layer | Tracked | Whose | Serves |
|---|---|---|---|
| `<template>/.setup.conf` | shipped in `.base` | base's | the default |
| `<repo>/.setup.conf` | committed | the repo's | what CI and every checkout use |
| `<repo>/.setup.conf.local` | gitignored | the operator's | this worktree, this machine |

The repo's own file-naming convention already says this: the standard name
is ours (shipped or generated, replaced on update, never hand-edited per
instance); a suffix marks the operator's local variant, never touched by
tooling. `.setup.conf.local` is exactly that shape, and it is the same
relationship `.env.local` has to `.env`.

It may override **any** section, not a whitelist. multi_run-era work is
expected to need many per-worktree variations, and adding them one section
at a time is churn with no safety benefit -- the layer is already
operator-owned and machine-local.

### 2. Why this is not a relapse into what #201 removed

#201 deleted a **committed** `setup.conf.local` that sat inside a redundant
three-file chain whose third file was a derived snapshot nobody read. Its
stated complaint was that the `.local` suffix *looked* gitignored while it
was not. The convention adopted since makes `.local` mean precisely what
#201 said it did not, and the file is now genuinely gitignored (sec. 7).
The chain is also two layers of real config plus this one, not a config
file plus a stale snapshot of itself.

### 3. Section-replace, matching the layer below

Not per-key merge. The decisive reason is structural rather than
aesthetic: **eight of the fifteen sections are `<prefix>_N` ordered
lists** (`[image] rule_N`, `[build] arg_N`, `[network] port_N`,
`[security] cap_add_N` / `security_opt_N`, `[devices] device_N`,
`[volumes] mount_N`, `[tmpfs]`, `[additional_contexts]`). A per-key merge
over an ordered list is not merely inconsistent, it is broken:

- overriding `rule_2` alone yields the repo's `rule_1` + the local
  `rule_2` + the repo's `rule_3` -- one ordered list assembled out of two
  layers, describing a configuration neither layer wrote;
- an item cannot be **removed** at all;
- adding one requires knowing the highest `N` in a layer the author of the
  upper layer cannot see.

Keys within a section also gate each other -- `[network] mode` decides
whether `port_N` is emitted at all, `[deploy] gpu_mode` gates the rest of
the GPU keys -- so a partial override produces incoherent combinations.

The layer below already worked this way. One rule for the whole chain.

### 4. `[project] name`, and one resolved project name

`[project]` is a real section of the shipped template with one key,
`name`, and it **ships empty**, meaning "derive as before". Upgrading
therefore changes nothing for any existing repo.

It must exist in `.setup.conf` and not only in `.setup.conf.local`:
`.setup.conf.local` is the local *variant* of `.setup.conf` and shares its
grammar. A section that appeared only in `.local` would be a second schema.

The resolution has exactly one producer, `_resolve_project_name` in
`lib/compose.sh`. `setup apply` calls it once and records the result in
`.env.generated` as `PROJECT_NAME`; **both** consumers then read that one
value:

- the wrapper's `-p`, via `_load_env`;
- the emitted `compose.yaml`'s `name: ${PROJECT_NAME}`, interpolated from
  the same `--env-file`.

`template_spec` fails if any other shipped file assembles a project name.
The emitted form stays an interpolation, not the resolved literal, so
ADR-00000022's overlay contract for project `name:` continues to hold
(its guard is unchanged).

Two names remain deliberately distinct. The **image tag**
(`<hub>/<image>:<stage>`) is a separate axis -- that separation is the
whole reason moving `IMAGE_NAME` was the wrong lever. And the **field
bundle's** project stays `<name>-<stage>` per ADR-00000023: it is a
different artifact, on a different host, deliberately stage-qualified.

### 5. Division of labour with the ADR-00000022 overlay

These are different stages of the pipeline and neither substitutes for the
other:

| | `.setup.conf.local` (this ADR) | ADR-00000022 `.env` overlay |
|---|---|---|
| serves | a developer's worktree | multi_run's Nth instance |
| acts | **before** `compose.yaml` is generated | at interpolation time on an already-generated one |
| `compose.yaml` count | one per worktree | one, shared |

Recording this is part of the decision. Without it a future reader
reasonably assumes this is how multi_run isolates instances -- and it
cannot be, because multi_run runs N instances off **one** generated
`compose.yaml`, which a per-worktree config layer by construction does not
produce. multi_run overriding `PROJECT_NAME` in its runtime overlay
continues to work unchanged; that is ADR-00000022's table row.

### 6. Why this is not a reversal of #600

#600 removed `--instance` / `INSTANCE_SUFFIX` / `config/instances/<name>`
from base on layering grounds: base is `docker` (single instance),
multi_run is `docker compose` (orchestration). That stands. A **named
project override is configuration** -- one name, for this checkout,
recorded in a file, resolved by the same machinery as every other key --
not a multi-instance orchestration surface. base still emits one project
per checkout; it simply no longer forces every checkout to pick the same
name.

### 7. `.setup.conf.local` is canonically gitignored

#879 moved the leftover `.gitignore` line to the RETIRED list, which does
not merely stop emitting it -- it actively **prunes** it from every
downstream `.gitignore` on each sync. That was correct while nothing read
the file. It is now exactly wrong, so the entry is canonical again and the
retired list is empty.

Both halves had to move in one edit: an entry present in *both* lists is
retracted and re-appended on every sync, forever, in every downstream at
once. A standing spec now asserts the two lists are disjoint. That
retirement was also **unreleased** (it sat in the commits after
`v0.42.0-rc3`), so no downstream ever saw the line disappear.

`.dockerignore` shares the canonical list and gains the entry too:
untracked machine-local config inside a build context is how an
unversioned value ends up baked into an image.

### 8. Writes: `--local`, warned-not-refused, and the field refusal

`set` / `add` / `remove` keep writing the committed `.setup.conf`.
`--local` targets `.setup.conf.local`.

Writing the committed file while `.setup.conf.local` defines that section
is **warned, not refused**, and the asymmetry is the decision. Under
section-replace the write is provably inert *on this machine*, so the
warning is stated as a certainty rather than a possibility, names the
shadowing section, and points at `--local`. But the value is still the
committed, shared setting that CI and every other checkout use, so
refusing would block a legitimate write on the grounds that one machine
cannot observe its effect. This is the failure mode the earlier committed
`setup.conf.local` died of -- a write landing where the read path does not
look -- which is why it is a hard requirement and not a nicety.

`setup deploy` **refuses** while `.setup.conf.local` exists, before the
preview and before any build side effect, so even `--dry-run` reports the
refusal rather than previewing a plan that would not be allowed to run.
`--allow-local-override` is the escape hatch, and the bundle's own README
records which untracked sections it was built from -- written by the
bundle *generator*, so the record travels with the artifact and reaches
the person in the field, who is not the person who chose to bypass the
gate.

### 9. `SETUP_CONF` is removed

`SETUP_CONF` was an undocumented env var that replaced the **whole**
config resolution with one path ("only read from it, no merge"). It was
introduced as a test seam -- its own first comment said
`SETUP_CONF env var (test override)` -- and then spread by five mechanical
refactors that each copied it verbatim, including its inconsistent
existence-checking: the two `setup_conf.sh` readers did **not** check the
file existed (a typo'd path silently yielded an EMPTY config), while
`conf_logging.sh` and `stage.sh` did, and degraded differently. It was
also folded into the drift hash by *concatenation* with the template and
repo files even though resolution used it alone, so `SETUP_CONF_HASH` did
not describe the config that was actually resolved.

Nothing but one spec set it, and roughly 120 spec `setup()` bodies
explicitly `unset` it -- the suite already treated an ambient value as a
hazard. Users are not meant to relocate the conf: the fixed pair
`<repo>/.setup.conf` + `<repo>/.setup.conf.local` is the whole surface.
The specs that used it as a fixture now drive real files at the paths the
resolver reads.

## Alternatives

- **A `PROJECT_NAME` / `COMPOSE_PROJECT_NAME` environment variable.**
  Rejected, and it is what PRD invariant 9 forbids: an ambient value is
  invisible to anyone reading the repo, does not survive a new terminal,
  and cannot be reviewed. Divergence in runtime naming between two
  checkouts has to be *recorded in a file*.
- **Deriving the project name from the checkout path.** Rejected for the
  same reason #892 stopped `docker compose` doing it on the test path: a
  name that changes when a directory is renamed or moved is an accident,
  not a decision, and two checkouts that happen to share a basename
  silently share containers.
- **Per-key merge for the local layer.** Rejected on the ordered-list
  argument in sec. 3. Someone will propose it again; the answer is that
  eight of the fifteen sections cannot express a removal or a
  well-defined insertion under it.
- **A whitelist of overridable sections.** Rejected: the layer is
  operator-owned and machine-local, so a whitelist adds churn (a PR per
  new key) without adding a safety property that the deploy refusal does
  not already provide.
- **Refusing a shadowed write instead of warning.** Rejected in sec. 8.
- **Reusing the ADR-00000022 `.env` overlay for worktree isolation.**
  Rejected as a category error (sec. 5): the overlay acts on an
  already-generated `compose.yaml` and cannot change what gets generated.

## Consequences

- Two worktrees of one repo run concurrently after
  `./setup.sh set --local project.name <x>` in one of them, through the
  wrappers alone -- no hand-edited derived artifact, no environment
  variable.
- With no `.setup.conf.local` present, behaviour is unchanged: the
  resolved project name is the same `<hub>-<image>` string as before, and
  the template's new `[project] name` ships empty.
- `.env.generated` gains `PROJECT_NAME`; `compose.yaml`'s `name:` changes
  from `${DOCKER_HUB_USER}-${IMAGE_NAME}` to `${PROJECT_NAME}`. Downstream
  repos pick both up on their next regenerate, which the conf-hash drift
  check triggers automatically because the template gained a section.
- An `.env.generated` written before this change carries no
  `PROJECT_NAME`; the wrapper says so and derives one for that run rather
  than silently inventing a name whose source the user cannot trace.
- Adding a fifteenth section pulls in `SCHEMA_SECTIONS`, a
  `SCHEMA_VALIDATOR` (`_validate_project_name`: docker compose's own rule
  -- lowercase letters, digits, `-`, `_`, beginning with a letter or a
  digit; deliberately tighter than the network-name rule, which permits
  uppercase and dots) and a `SCHEMA_I18N` row. That row is the explicit
  no-editor opt-out: the TUI edits the *committed* `.setup.conf`, while a
  per-worktree name belongs in `.setup.conf.local`, so a menu row would
  edit the wrong file by default.
- `SETUP_CONF` no longer exists. Any out-of-tree script that set it was
  silently replacing the whole config; it now has no effect at all, which
  is the intended outcome.
