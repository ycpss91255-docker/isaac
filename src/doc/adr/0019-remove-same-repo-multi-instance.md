# Remove Same-Repo Multi-Instance Bring-up

isaac drops same-repo multi-instance entirely. The `--instance <name>` flow
adopted in ADR-0016 (per-instance compose overlays from
`config/instances/<name>.{yaml,env}`, the per-instance cache-dir pre-run hook,
and the per-instance web-viewer naming in the run/stop hooks) is removed. The
single-sim stream flow is the only supported flow: `just run -t stream -d`
brings up the default Isaac container plus one `owv` web-viewer.

This SUPERSEDES the multi-instance premise of ADR-0016. ADR-0016's other
decision -- adopting base's native wrapper-hook mechanism (base #440) for the
isaac-specific orchestration (host.yaml injection + web-viewer launch) -- still
stands; the hooks remain, only their per-instance dimension is dropped.

## Context

ADR-0016 moved multi-instance off three hand-rolled scripts onto base's
`run.sh --instance NAME` overlay (base #465) + wrapper hooks (base #440). That
removed the duplication, but it kept a capability whose only real driver does
not survive scrutiny.

The sole concrete driver for running several Isaac processes from the **same
repo checkout** was test-time **port-collision avoidance** -- opening more than
one Isaac at once on one machine without the WebRTC signaling / media / API /
viewer ports clashing. That is a test-harness convenience, not a product need.
Examined against the actual axes that might want concurrency:

- **Multiple robots** -> Isaac Lab RL multi-env (`InteractiveScene` `num_envs`
  cloning) inside ONE Isaac process, the direction ADR-0018 already aims at.
  Not multiple Isaac processes.
- **Different users** -> copy the repo. Per-user isolation is a checkout
  boundary, not an in-repo instance dimension.
- **Different scenarios** -> not run concurrently on one repo. A scenario is a
  driver run, executed one at a time; isaac here is single-scenario
  validation.

None of these wants same-repo concurrent Isaac instances. The multi-instance
surface (committed `config/instances/example.{yaml,env}` templates, the
per-instance cache pre-run hook, the `-${instance}` container/viewer suffixes,
the `--env-file` per-instance port overlay, and their bats specs) is therefore
pure carrying cost on a single-scenario validation repo.

base still provides the `--instance` primitive (base #465); isaac simply stops
USING it. We are not removing anything from base. The de-leak of `--instance`
from base itself (so the primitive does not advertise a capability isaac's
direction abandons) is tracked separately in base #600.

The full multi-instance design is not lost: it is preserved for future
non-isaac repos that genuinely need same-repo concurrency in multi_run#15.

## Decision

Remove same-repo multi-instance from isaac. Concretely:

- **`config/instances/example.{yaml,env}` deleted.** The committed per-instance
  templates go. (Local `b` / `warehouse` overlays were always gitignored.)
- **`script/hooks/pre/run.sh` reverts to a no-op stub**, matching its sibling
  hook stubs. Its only job was building the per-instance cache-dir tree; with
  no instances there is nothing to build (the default cache dirs are handled by
  `init_isaac_dirs.sh`).
- **`script/hooks/post/run.sh` de-instanced.** The `--instance` /
  `INSTANCE_SUFFIX` arg parsing and the per-instance
  `--env-file config/instances/<name>.env` viewer-port overlay are removed. The
  hook keeps everything else: the `target=stream` + `--detach` gate, the
  `.env.generated`-then-`.env` identity sourcing, the host.yaml validate +
  `docker cp` into the Isaac container, and the web-viewer launch -- but
  default-only. The Isaac container is `${USER_NAME}-${IMAGE_NAME}-stream` (no
  suffix), the viewer container is `owv` (no `-${instance}` suffix), the viewer
  ports are the literal `-e SIGNALING_PORT=49100 -e SERVE_PORT=5173` (the former
  fallback), with `-e VIEWER_UI_MODE=stream-only` and image
  `${DOCKER_HUB_USER:-local}/omniverse_web_viewer:runtime` unchanged.
- **`script/hooks/post/stop.sh` de-instanced.** The `--instance` parsing is
  removed; the viewer container to remove is `owv` (the same default name
  post/run now uses).
- **Specs updated.** `pre_run_hook_spec.bats` is deleted (the hook is now a
  no-op stub, and sibling no-op stubs carry no spec).
  `post_run_hook_spec.bats` / `post_stop_hook_spec.bats` are rewritten to the
  default-only behavior (no `--instance` / `--env-file` / per-instance
  assertions; the #121 `owv:runtime`-ban guard is kept).

The single-sim stream path already existed as the `instance=""` fallback in the
ADR-0016 hooks (`owv` default + literal `-e SIGNALING_PORT=49100`
`-e SERVE_PORT=5173`); this ADR makes that fallback the only path.

## Considered Options

- **(a) Keep multi-instance, deepen it** -- e.g. an auto port-assignment
  generator. Invests further in a capability with no product driver; rejected.
- **(b) Remove same-repo multi-instance, keep the single-sim flow** (**chosen**)
  -- deletes the carrying cost, leaves the only flow isaac actually validates
  against. base keeps the `--instance` primitive for repos that need it; the
  design is preserved in multi_run#15.
- **(c) Remove multi-instance from base too** -- out of scope and wrong: base
  is an org-wide template consumed by other repos; the primitive is legitimate
  there. isaac just stops using it (de-leak tracked in base #600).

## Consequences

- The supported flow is single-sim: `just run -t stream -d` ->
  `pre/run.sh` (no-op) -> compose up the default stream container ->
  `post/run.sh` (host.yaml cp + `owv` viewer on `49100` / `5173`). Launch Isaac
  Sim via an explicit `exec` step (driver per ADR-0005, or
  `runheadless-host-config.sh`), unchanged.
- Teardown is `just stop` -> `post/stop.sh` removes `owv`.
- Anyone who needs same-repo concurrency uses base's `--instance` primitive
  directly, or the preserved design in multi_run#15; it is no longer an isaac
  feature.
- `pre/run.sh` rejoins the no-op-stub set; the per-instance cache-ownership
  warning logic it carried is gone (the default cache dirs are
  `init_isaac_dirs.sh`'s responsibility).
- The bats smoke count drops (the 4 `pre_run_hook_spec` tests removed; the
  post-run / post-stop specs shrink to default-only).

## References

- ADR-0016 (base-native per-instance via `run.sh --instance` + hooks) --
  multi-instance premise SUPERSEDED here; its base-native hook adoption stands.
- ADR-0005 (standalone-with-livestream as default dev entrypoint) -- Isaac
  launch stays an explicit `exec` step.
- ADR-0014 (sim-runtime stage taxonomy: `headless` / `stream`).
- ADR-0018 (Isaac Lab spawn backend) -- multi-robot concurrency is Isaac Lab
  multi-env inside one process, not multiple Isaac processes.
- base #465 (the `--instance` primitive isaac stops using -- kept in base),
  base #440 (repo-local wrapper hooks -- kept), base #600 (de-leak `--instance`
  from base, tracked separately).
- multi_run#15 (the full same-repo multi-instance design, preserved for future
  non-isaac repos).
- `script/hooks/{pre,post}/{run,stop}.sh`, `script/runheadless-host-config.sh`.
