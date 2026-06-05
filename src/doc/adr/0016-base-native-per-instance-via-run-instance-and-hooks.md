# Base-Native Per-Instance Bring-up via `run.sh --instance` + Wrapper Hooks

Multi-instance Isaac Sim bring-up moves from three hand-rolled scripts
(`init_instance.sh` / `run_instance.sh` / `stop_instance.sh`) plus the
`Makefile.local` `run-stream` / `stop-stream` targets onto the base-native
mechanisms shipped in `.base` v0.40.0: `run.sh --instance NAME` per-instance
compose overlays (base #465) and repo-local wrapper hooks (base #440). The
isaac-specific orchestration (host.yaml injection, web-viewer launch) now
lives in `script/hooks/{pre,post}/{run,stop}.sh`; per-instance ports + cache
live in `config/instances/<name>.{yaml,env}`.

## Context

The hand-rolled trio predated base's multi-instance support. `run_instance.sh`
was a raw `docker run` that bypassed the base wrappers entirely, and its
livestream Kit args, cache mounts, and viewer launch were duplicated against
`Makefile.local run-stream`. Concretely this produced three frictions:

1. **Port config drift.** The offset->port arithmetic lived in
   `init_instance.sh`, while `Makefile.local` hard-coded the offset-0 values
   (`49100` / `5173`) as literals. Changing a base port in one place silently
   diverged the other.
2. **Livestream-arg construction scattered.** The `--/app/livestream/*` Kit
   args were built in `run_instance.sh`, `runheadless-host-config.sh`, and
   `isaac-ros-env-wrapper.sh`; `Makefile.local` injected host.yaml via an
   unvalidated `docker cp` whose timing differed from `run_instance.sh`'s `-v`
   mount.
3. **Web-viewer launch duplicated** near-verbatim between
   `run_instance.sh:_start_web_viewer` and `Makefile.local run-stream`.

The repo had also begun migrating by hand: `config/docker/instances/` (old,
gitignored) coexisted with `config/instances/` (the base #465 convention).

base shipped, and CLOSED, the mechanisms for exactly this:

- **#465** `run.sh --instance NAME` auto-loads `config/instances/<name>.yaml`
  as a compose overlay (deep-merge) and `<name>.env` via `--env-file`. Its
  acceptance criteria names this repo: "downstream PR deletes isaac's
  init/run/stop_instance.sh in favor of this mechanism."
- **#440** each base wrapper runs repo-local `script/hooks/{pre,post}/<wrapper>.sh`
  with the wrapper's argv; the post-run hook runs in run.sh's EXIT trap while
  the container is still alive, so it can `docker exec` / `docker cp`.
- `stop.sh --instance NAME` tears down the compose (Isaac) containers.

## Decision

Adopt the base-native model. The streaming bring-up becomes:

```
./run.sh -t stream -d --instance <name>
  -> pre/run.sh   : create the instance's cache dir tree (salvaged from init_instance.sh)
  -> (compose up)  : config/instances/<name>.{yaml,env} deep-merged (ports + cache + env)
  -> post/run.sh  : validate + copy host.yaml into the Isaac container; start the web-viewer
```

Specifics:

- **`runheadless-host-config.sh` becomes the single livestream-arg builder.**
  It reads `ISAAC_SIGNAL_PORT` / `ISAAC_MEDIA_PORT` / `ISAAC_API_PORT` from the
  container env (delivered by the overlay) and `public_ip` from `/etc/host.yaml`,
  and emits the full `--/app/livestream/*` invocation. The args no longer live
  in any host-side script.
- **`post/run.sh` brings up infra, not Isaac.** It copies host.yaml and starts
  the viewer, but does NOT launch Isaac Sim. Launching Isaac stays an explicit
  `exec` step (a driver script per ADR-0005, or `runheadless-host-config.sh`
  for the no-driver case), avoiding a double-Kit conflict and keeping a clean
  `run` = infra / `exec` = workload split.
- **`post/stop.sh` stops the viewer**, which is started out-of-compose so
  `stop.sh` never sees it.
- **Per-instance overlays are hand-authored** from a committed
  `config/instances/example.{yaml,env}` template. No port-assignment generator:
  in practice instances run at offset 0, and conflicts are resolved by editing
  the copied overlay. The pre-run hook creates the cache tree at run time
  (idempotent), so the generator's only remaining job disappears.
- **Deleted:** `script/{init,run,stop}_instance.sh`, the `Makefile.local`
  `run-stream` / `stop-stream` targets (the file itself, vestigial once the
  targets are gone), `config/docker/instances/`, and the
  `run_instance_spec.bats` / `makefile_local_spec.bats` regression specs.

## Considered Options

- **(a) Keep the hand-rolled trio, deepen in place** — extract a shared ports
  module + a shared `start_web_viewer.sh`. Resolves the duplication but not the
  two-parallel-systems mess, and runs against base's stated direction (the trio
  is meant to be deleted). Rejected.
- **(b) Adopt base #465 + #440** (**chosen**) — eliminates all three frictions
  at once, removes the parallel `config/docker/instances/` system, and matches
  base's acceptance criteria. Requires understanding the overlay deep-merge and
  hook contracts but adds no new bespoke surface.
- **(c) Auto-launch Isaac in the post-run hook** (preserve run-stream's
  all-in-one behavior) — convenient one-liner, but conflicts with the documented
  driver-via-exec flow (ADR-0005) and risks two Kit processes. Rejected in favor
  of the run=infra / exec=workload split.

## Consequences

- The committed `config/instances/example.{yaml,env}` is the per-instance
  template; real overlays are gitignored (machine-specific ports / cache paths).
  Existing machine-local instances under `config/docker/instances/<name>.env`
  must be re-authored as `config/instances/<name>.{yaml,env}` (one-time, manual).
- The overlay relies on compose merging `volumes` by container (target) path so
  the per-instance cache mounts override the default `${WS_PATH}` ones while
  `work` / `pip` / `documents` stay shared. This is standard compose override
  behavior; it is exercised end-to-end on the GPU host.
- The web-viewer is launched and stopped by the run/stop hooks (out-of-compose,
  `owv:runtime` image, container `owv-<instance|default>`), not by compose.
- **Deferred to a base release + `.base` bump (Phase 2, tracked separately):**
  the `/dev:/dev` per-stage opt-out for tooling / non-stream stages (base #493,
  the `omniverse_web_viewer#26` root cause), the Makefile-wrapper retirement
  decision (base #475), and the env / runtime split (base #497 / #507).
- No real host address ships in this ADR or the template; remote config uses
  `config/host.yaml` (gitignored), placeholders use `127.0.0.1` / `<host-ip>`.

## References

- base #465 (per-instance compose overlay), #440 (repo-local wrapper hooks),
  #475 (Makefile wrapper retirement, open), #493 (tooling-stage runtime config).
- ADR-0005 (standalone-with-livestream as default dev entrypoint) — Isaac launch
  stays an explicit `exec` step; this ADR only changes bring-up of the
  surrounding infra.
- ADR-0014 (sim-runtime stage taxonomy: `headless` / `stream`).
- `config/instances/example.{yaml,env}`, `script/hooks/{pre,post}/{run,stop}.sh`,
  `script/runheadless-host-config.sh`.
