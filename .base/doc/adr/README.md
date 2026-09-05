# ADR index + PRD audit

This is the index of base's Architecture Decision Records **and** the
audit that maps each ADR onto [`doc/PRD.md`](../PRD.md) -- base's north
star. Every ADR now carries a one-line `> Serves:` back-reference to the
PRD invariant (1-9), goal, or scope item it upholds; this table is the
consolidated view.

**The filesystem is the ADR registry.** There is no database and no
manually-curated master list of numbers -- the set of `doc/adr/NNNNNNNN-<slug>.md`
files *is* the registry. The ADR-numbering lint
(`script/test/drivers/adr_numbering.sh`, wired into `just test`; landed
with the PRD work under #808 / #823) guards it: a duplicate ADR number or
a malformed filename **fails** CI, while a numbering **gap** is warned,
not failed. This `README.md` is deliberately *not* an ADR file (its name
does not match `NNNNNNNN-<slug>.md`), so it does not perturb that lint.

## Anomalies (resolved)

- **`00000009` is an intentional gap.** There is no ADR-9 and none will
  be back-filled; the number was skipped. The numbering lint warns on it
  and passes. Do not invent a `00000009`.
- **`ADR-00000020` is a single canonical record.** A parallel-authoring
  incident once produced two files both numbered `ADR-00000020` (the very
  case the #823 numbering lint now catches). The canonical
  `00000020-base-owns-single-service-lifecycle.md` is the foundational
  "base owns the single-service lifecycle" axiom; the separate
  init-default-toggle content was **folded into** it (init defaults ON is
  ADR-20's two-branch-rule example, see its Consequences). There is no
  second ADR-20.

## Verdict vocabulary

| Verdict | Meaning |
|---|---|
| `keep` | Accurate as written; no change needed (inline amendments, where present, are already recorded in the file). |
| `amend` | A factual detail is now stale and should be refreshed (tracked as a follow-up, not edited here). |
| `supersede` | Replaced by a later ADR (named). |
| `merge` | Overlaps another ADR and could be consolidated (named). |
| `elevates-invariant` | Established a PRD Core Invariant (named 1-8). |

The nine PRD Core Invariants: **1** one container = one service / base
owns the single-service lifecycle; **2** never fail silently; **3**
multi_run-expandable by construction; **4** fail-safe defaults; **5** the
two-branch default rule; **6** base is a subtree / downstream a thin
caller; **7** rigorous, industry-aligned test bar; **8** development and
field are cleanly separated, provisioned by opposite means; **9** identity
and naming are resolved once, from a file. ADRs that are
pure *mechanisms* serve a goal but map to no invariant -- the table says
so explicitly.

## Audit table

| ADR | Verdict | Serves | Note |
|---|---|---|---|
| 00000001 -- setup.conf vs compose-native boundary | keep | mechanism (config-resolution boundary; serves the one-source-render goal), no invariant | The escape-hatch/`--env-file` case was refined into a primary path by ADR-00000003. |
| 00000002 -- no `latest` tag for base | keep | invariant 6 (subtree / propagation) -- mechanism | Immutable version pinning of subtree + workflow refs keeps propagation reproducible. Dated example `v0.39.0` is self-dating. |
| 00000003 -- env vs workload boundary + field delivery | keep (amended by 00000023) | invariant 3 (axis-A `.env` overlay model) + goal (one source -> many render; field delivery); also invariant 8 (its env-row override generalizes to config files) | Foundational to the PRD Product Shape; refines ADR-00000001; the overlay model is the seed ADR-00000022 later elevates. **Amended 2026-07-15 (ADR-00000023):** its structured-config Field cell gains a mount-wins `-v` override and "compose does not travel" is refined to "a resolved compose travels" (in-file amendment note). |
| 00000004 -- category-first test layout | supersede (by 00000012) | invariant 7 (test bar) -- mechanism | Category-first reversed to tool-first; Status already records the supersession. |
| 00000005 -- adopt `just` over the Makefile | keep | invariant 6 (thin-caller entrypoint) -- mechanism | The single discoverable user entry ADR-00000010/00000011 build on. Dated `13 downstream repos` / `v0.39.0` are self-dating. |
| 00000006 -- upgrade.sh path contract | keep | invariant 6 (subtree upgrade path) -- mechanism | Frozen interior paths; already carries forward-pointers to ADR-00000010/00000011's `dist/` moves. |
| 00000007 -- log TTY cache + transcript layering | keep | mechanism (wrapper log/transcript single-sink fidelity), no invariant | Ensures a transcript tee cannot silently flip terminal output format. |
| 00000008 -- sharded coverage PR gate | keep | invariant 7 (coverage gate -- a *swappable* mechanism, not the invariant) | Heavily amended inline (Codecov removed, dynamic shards, per-line union merge); all recorded in-file. |
| 00000010 -- layered `just` entry + base/downstream split | elevates-invariant (6) | invariant 6 (subtree / thin caller) | Established the `dist/` split + layered entry. Its docker-top-level decision was superseded-in-part by ADR-00000011 sec.1 -- recommend a forward-pointer (follow-up). |
| 00000011 -- zero-special-case `just` command model | elevates-invariant (6) | invariant 6 (subtree / thin caller) | The current command model + generic test runner; amends ADR-00000010 and ADR-00000006. |
| 00000012 -- tool-first test layout | keep (supersedes 00000004) | invariant 7 (test bar) -- mechanism | Its category *vocabulary* was later amended by ADR-00000018; forward-pointer already present. |
| 00000013 -- strip transient issue refs from comments | keep | invariant 2 (never fail silently) -- the issue-ref lint | PRD invariant 2 names the issue-ref lint as one of its enforcing guards. |
| 00000014 -- decompose setup.sh into subsystem libs | keep | mechanism (source architecture / testability), no invariant | Deep-module decomposition; underpins invariant 7's testability but is an architecture decision. |
| 00000015 -- test files mirror source | keep | invariant 7 (test bar) -- mechanism | Lowers the per-file coverage shard floor; complements ADR-00000008/00000012. |
| 00000016 -- coverage tooling evaluation | keep | invariant 7 (swappable coverage mechanism) | Status is **Rejected**: the spike disproved the "kcov = heavy ptrace" premise; kcov stays. Accurate record. |
| 00000017 -- CI throughput ceiling + shard strategy | keep | invariant 7 (swappable CI/shard mechanism) | PRD explicitly lists this as a swappable mechanism under invariant 7. |
| 00000018 -- ISTQB test taxonomy | elevates-invariant (7) | invariant 7 (rigorous, industry-aligned test bar) | The *commitment* establisher; supersedes only ADR-00000012's category vocabulary. |
| 00000019 -- network host default, bridge opt-in | elevates-invariant (4) | invariant 4 (fail-safe defaults) | The general principle's instance; a sibling lifecycle-defaults decision to ADR-00000020. |
| 00000020 -- base owns the single-service lifecycle | elevates-invariant (1) | invariant 1 (single-service lifecycle); also invariant 5 (two-branch default rule) | Canonical single ADR-20; init-toggle content folded in (see Anomalies). |
| 00000021 -- per-start container logs + shared logrotate | keep | invariant 1 (single-service lifecycle) -- mechanism | The #805 log-persistence lifecycle capability realising invariant 1. |
| 00000022 -- compose<->multi_run overlay contract | keep (amended by 00000025) | invariant 3 (multi_run-expandable by construction); also invariant 2 (the overlay guard) | The overlay contract + `overlay_guard_spec.bats`; PRD names it under both invariants 2 and 3. **Amended 2026-08-05 (ADR-00000025):** the project `name:` row's emitted form is now `${PROJECT_NAME}` (still an interpolation, so the forward invariant and its guard are untouched), plus an explicit statement that a per-worktree `.setup.conf.local` is NOT this contract's mechanism -- it acts before `compose.yaml` is generated (in-file amendment note). |
| 00000023 -- config field-override + self-contained field-deploy contract | elevates-invariant (8) | invariant 8 (dev/field separation, provisioned by opposite means) -- established with ADR-00000003 | The git-tracked provisioning axis, baked-default + mount-wins `-v` override (file analog of ADR-3's env `-e`), deploy-as-resolved-self-contained-compose (amends ADR-3's "compose does not travel"), the deployable-stage rule, and the `config/<component>/deploy.manifest` tunability channel. Reconciled with ADR-00000022 (single-file config `-v` != general volume topology). Mechanism in #831 / #832 / #833. **Amended twice in-file (#874):** sec. 2 now states the mount-override is read-only by default with an explicit `rw` opt-in (#870), and sec. 4's `deployable = not devel and not *-test` is restated as what `_is_deployable_stage` actually enforces (it also rejects `sys` / `devel-base` and the legacy aliases). |
| 00000024 -- bake self-built artifacts at `/opt`, not `$HOME` | keep | invariant 8 (dev/field separation) -- mechanism; also invariant 2 via the `home-literal` lint | `ENV HOME` resolves at BUILD time, so anything baked under `$HOME` is coupled to the build-time `USER_NAME` and breaks on a rebuild / GHCR pull / `docker save`+`load` under a different user. Artifacts go to absolute `/opt`; `~/x -> /opt/x` is a discoverability symlink nothing sources. Its mechanical rule (no concrete username in a path) is gated by the `home-literal` lint. |
| 00000025 -- per-worktree `.setup.conf.local` override + one resolved project name | elevates-invariant (9) | invariant 9 (runtime-name divergence is a file-recorded override) -- established; also invariant 2 (shadowed-write warning, deploy refusal, config-summary row) and invariant 8 (the field refusal) | Third conf layer (`.setup.conf.local`, gitignored, section-replace like the two below it), `[project] name` shipped empty, and `_resolve_project_name` as the single producer both `-p` and compose's `name:` read via `.env.generated`. Un-retires the `.gitignore` entry #879 retired. Removes `SETUP_CONF`. Explicitly NOT a reversal of #600 (configuration, not orchestration) and NOT ADR-00000022's channel (acts before compose.yaml is generated) -- **amends ADR-00000022 in-file** with that division of labour and the `${PROJECT_NAME}` row. |

## Audit conclusion

- **keep:** 15 (00000001, 00000002, 00000003, 00000005, 00000006,
  00000007, 00000008, 00000012, 00000013, 00000014, 00000015, 00000016,
  00000017, 00000021, 00000024) -- 00000003 is `keep (amended by
  00000023)`, the amendment recorded inline in-file. 00000024 postdates
  the audit itself and is listed for index completeness.
- **supersede:** 1 (00000004, by 00000012 -- already recorded)
- **elevates-invariant:** 8 (00000010, 00000011 -> inv 6; 00000018 -> inv
  7; 00000019 -> inv 4; 00000020 -> inv 1; 00000022 -> inv 3; 00000023 ->
  inv 8; 00000025 -> inv 9)
- **amend:** 0 in the verdict column; 1 recommended follow-up (a
  forward-pointer on 00000010 -- see below)
- **merge:** 0

The decision log is already internally coherent: every ADR that was
reversed or refined by a later one carries its own inline
amendment/supersession note. The audit's net additions are the per-ADR
`> Serves:` invariant back-references and this index. The only structural
gap found is that ADR-00000010's now-reversed "docker top-level" decision
has no forward-pointer to ADR-00000011; it is listed as a follow-up for a
maintainer to close, not edited here (per the "no technical-content edits
in this slice" rule).
</content>
</invoke>
