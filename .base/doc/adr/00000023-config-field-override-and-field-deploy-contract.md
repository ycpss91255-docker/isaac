# Config field-override + self-contained field-deploy contract

> Serves: PRD invariant 8 (development and field are cleanly separated,
> and provisioned by opposite means) -- established (with ADR-00000003);
> also the one-source -> many-render / field-delivery goal.

- **Date:** 2026-07-15
- **Status:** Accepted
- **Relates to:** issue #830 (this decision, the epic anchor), the
  implementing issues #831 (relocate `setup.conf` out of `config/`), #832
  (self-contained resolved-compose deploy bundle), #833 (per-component
  tunable-config manifest + field override); the downstream conventions it
  governs, #826 / #827; ADR-00000003 (env vs workload parameter boundary +
  field delivery -- this ADR amends its structured-config Field cell and its
  "compose does not travel" constraint), ADR-00000001 (setup.conf is the main
  path, compose-native mechanisms are the escape hatch), ADR-00000011 /
  ADR-00000018 (the devel / runtime / `*-test` stage structure),
  ADR-00000022 (compose<->multi_run overlay contract -- reconciled below).

## Context

ADR-00000003 drew the env-var vs structured-config line and gave the **env-var**
row a field override channel (baked `ENV` default + optional `deploy.sh -e`),
but left the **structured-config** row (its routing-table line 115) **bake-only**:
in the field a config file was `COPY`-baked into the image with no override, so
adjusting it required a rebuild. That asymmetry is the concrete gap this ADR
closes, and the epic (#830) needs three related facts written down that were
never stated as a single contract:

- **Who provisions what, and how the dev and field environments stay apart.**
  base has a development environment (binds source, live-edit config, carries
  the toolchain) and a deployable/field environment (a self-contained image).
  The rule for which files a developer owns vs which an operator may edit, and
  the rule for which stages are even eligible to deploy, were unwritten.
- **What travels to the field.** ADR-00000003 said the host-side compose does
  *not* travel (only the image does), which pushed all field-launch config into
  `deploy.sh` `docker run` flags. A resolved compose that carries its own values
  is a cleaner field artifact than a hand-maintained `docker run` line.
- **How a per-component config is made field-tunable** without base having to
  know each downstream's config schema.

This is a doc-only decision (PRD invariant 8 + this ADR + the ADR-00000003
amendment); the mechanism lands in #831 / #832 / #833.

## Decision

### 1. The provisioning axis is git-tracking

The developer-vs-operator split follows a single, checkable axis -- **is the
file committed to the repo?**

- **Committed = the developer's default**, baked into the image at build
  (`COPY`). It is the working default a fresh deploy runs with.
- **Gitignored / not-in-repo / bundle-shipped = the operator overlay**, editable
  in the field. It is mounted over the baked default at launch.

This is the general axis ADR-00000003 made concrete only for env vars (committed
`[environment]` default vs gitignored `.env` overlay); this ADR names it as the
axis for **structured config files** too.

### 2. Baked default + optional mount-override (mount-wins)

A field config file is a **`COPY`-baked default** in a deployable stage, plus an
**optional field `-v` override** that mounts a file over it. When the operator
mounts a file, the mount wins; when they mount nothing, the baked default is
used. This is the exact file analog of ADR-00000003's env-row `deploy.sh -e`:
a self-contained default that a deployment can adjust **without a rebuild**,
restoring the symmetry between the two routing-table rows.

**Amendment (#870): the override mount is read-only by default, `rw` is
declared.** As first written this section said nothing about writability, and
the implementation defaulted to a writable bind. That default was wrong in
both directions. Nothing in "the operator retunes a value" requires the
*container* to write -- the operator edits the copy in the bundle on the host
and the container reads it -- and a writable bind quietly makes the mount
depend on the container's build-time user id matching whoever unpacked the
bundle on the field host: reads work under any id, writes fail, months later,
on the one machine that matters. So each `deploy.manifest` path mounts `:ro`
unless it declares `rw`, which makes the exception reviewable data rather than
a blanket grant, and an unrecognised token on a manifest line is a malformed
manifest that fails loud naming file and line -- never a silent skip, never a
silent downgrade. An absent access record can only tighten a mount, never
loosen one.

### 3. Deploy travels as a fully-resolved, self-contained compose

ADR-00000003 said "the compose does not travel" -- only the image did, and the
field launcher was a `docker run` (`deploy.sh`) with flags inlined. This ADR
**amends that**: a *fully-resolved, self-contained* compose **does** travel. The
deploy bundle (#832) ships a compose whose values are already resolved -- it has
**no dependency on `setup.conf` or `.env.generated`** (the host-side
generation inputs), so it runs on a field host that never had base's
detection / render toolchain. "Compose does not travel" was true of the
*generated, interpolation-dependent* compose; a resolved compose is a distinct,
self-contained artifact and is the field launcher.

### 4. `deployable = not devel and not *-test`

Only field-oriented stages are deploy targets. The **`devel` stage and any
`*-test` stage are never deploy targets** -- a devel image binds source and
carries the toolchain, and a test image exists to be tested, not shipped.
Formally, `deployable = not devel and not *-test`; every downstream repo binds
to this rule (it is the stage-eligibility half of PRD invariant 8, and the
convention #826 / #827 make downstream-explicit).

**Amendment (#841 / #874): the implementing predicate rejects two more
names.** `_is_deployable_stage` (`lib/stage.sh`) also rejects **`sys` and
`devel-base`** -- build intermediates with no runnable service, so a bundle
built from one is simply broken, not merely inadvisable -- alongside the
legacy aliases `base` / `test` the v0.21.x transition still accepts. The
formula above was the reasoning; the predicate is the rule, and PRD invariant
8 now states it in full so prose and predicate cannot disagree.

### 5. Per-stage tunability via `config/<component>/deploy.manifest`

A component declares which of its config files are field-tunable in a
`config/<component>/deploy.manifest`. **base delivers the files** named by the
manifest into the deploy bundle (as baked defaults + the mount-override hook of
§2); **the repo's entrypoint consumes them**. base does not need to understand
any downstream's config schema -- it moves the files the manifest lists and
wires the override hook; the semantics stay with the repo. This keeps base the
thin mechanism and the downstream the owner of its own config meaning
(consistent with invariant 6).

### 6. Reconciliation with ADR-00000022 (not a contradiction)

ADR-00000022 routes **writable-volume topology** through a **compose-merge
overlay** (a mount is a structured topology decision, not a flat scalar). This
ADR's §2 single-file config `-v` on the **field launcher** is a **distinct
concern** and does **not** reopen that: it is one config file overriding one
baked default on the deploy launcher, not a general volume-topology channel.
General writable-volume topology stays compose-merge per ADR-00000022; the
field-launcher config `-v` is a narrow, single-file override of a baked default.
Stated explicitly so the two `-v` uses do not read as a conflict.

## Alternatives

- **Keep structured config bake-only (status quo).** Rejected: it is the exact
  asymmetry that forces a rebuild to change one field value in the field, and it
  leaves the env row and the config row inconsistent for no principled reason.
- **Route field config through the `.env` overlay too.** Rejected: the `.env`
  overlay (ADR-00000003) carries flat `KEY=VALUE` env vars only; a structured
  config file (topics, pipeline lists, YAML) is not a flat scalar and belongs in
  its own file with its own mount-override, not smuggled through env.
- **Ship the generated, interpolation-dependent compose to the field.**
  Rejected: it depends on `setup.conf` / `.env.generated` being present on the
  field host, which is exactly what a field host does not have. A resolved,
  self-contained compose is the artifact that travels (§3).
- **Let each downstream hand-roll its own field-override wiring.** Rejected:
  duplicates the mechanism N times and drifts (the fat-caller anti-pattern of
  invariant 6). base delivers the files + hook once, driven by the per-component
  manifest (§5).

## Consequences

- The structured-config Field cell of ADR-00000003's routing table becomes
  symmetric with the env row: baked default + optional mount-wins `-v` (recorded
  as an amendment on ADR-00000003).
- A field deploy adjusts config without a rebuild (mount a file), and runs on a
  host with no base toolchain (the resolved compose is self-contained).
- The git-tracking axis becomes the single checkable rule for "developer default
  vs operator overlay" across both env vars (already) and config files (now).
- `deployable = not devel and not *-test` is a downstream-binding rule; #826 /
  #827 make it explicit in the downstream `config/<component>/` convention.
- Implemented by #831 (relocate `setup.conf` out of `config/`), #832
  (self-contained resolved-compose deploy bundle), #833 (per-component tunable
  `deploy.manifest` + field override). This ADR records the rationale; those
  issues carry the mechanism.
