# Sim-Runtime Stage Taxonomy: `stream` (viewer) vs `headless` (no viewer)

`#28` (in `ycpss91255-docker/isaac`) consolidated four Docker stages (`standalone` / `gui` / old `headless`) down to two (`headless` / `headless-stream`), driven by an `ISAAC_LIVESTREAM` env var and following the Gazebo gzserver/gzclient model (one container = one Kit process). That consolidation **reused the name `headless`** for the *no-stream* variant, which drifted the vocabulary: the original "headless server you observe through a browser" mental model now maps to `headless-stream`, and ADR-0005 / ADR-0007 still reference the now-deleted `standalone` / `gui` / old-`headless` names. Separately, a pure-inference / CI need was scoped as a brand-new `infer` stage in `ycpss91255-docker/isaac#69` -- but investigation showed the existing no-stream stage already provides that capability byte-for-byte (no streaming, no web-viewer, GPU reserved, no X11), so a new stage would have been a pure duplicate.

**Decision**: (1) Keep exactly two sim-runtime stages, distinguished solely by web-viewer presence, and rename for clarity: `stream` (WebRTC web-viewer; the devel observation path) and `headless` (no viewer; pure inference / batch). `headless-stream` is renamed to `stream`; the no-viewer stage keeps the name `headless` (now consistent with the Gazebo "headless = no display" convention). (2) Do not add a separate `infer` stage -- `headless` is it; `ycpss91255-docker/isaac#69` is rescoped from "add infer stage" to this rename. (3) The no-viewer path splits by purpose into two distinct stages: `headless` for human-driven runtime inference (run a driver, observe via ROS 2 topics + logs + output files), and `devel-test` for CI-automated pytest (smoke / integration, per ADR-0011).

## Local vs remote devel is one stage, not two

WebRTC streaming is identical whether the browser is local or remote -- the only difference is whether ICE candidates need the host LAN IP. That is a *runtime* config (`PUBLIC_IP` injected from `config/host.yaml` via `runheadless-host-config.sh`; empty = localhost-only), not a build-time stage difference. So "remote devel" and "local devel" both resolve to the single `stream` stage; they are not separate targets.

## Considered Options

- **(a) Add a new `infer` Dockerfile stage.** Rejected: `FROM devel AS infer` with `ENV ISAAC_LIVESTREAM=0` builds a byte-identical image to the existing no-stream stage, and that stage's compose service already has no X11, no web-viewer, and a GPU reservation. This is the same duplication ADR-0005 rejected when it declined a separate `gui` stage ("duplicate of an existing capability"), and it violates Rule of Three.
- **(b) Keep the current names (`headless` / `headless-stream`), document the mapping only.** Rejected: leaves the counter-intuitive state where `headless` has *no* viewer but `headless-stream` does, permanently. `headless-stream` is also self-contradictory as a name (headless, yet streaming a view).
- **(c) Rename to `stream` / `headless`** (**chosen**). A clean binary split (viewer vs not), consistent with the Gazebo convention `#28` already adopted, and aligned with the original mental model. Cost: one breaking rename (~53 references in the docker repo + the `omniverse_web_viewer` sub-repo).

## Earlier ADRs reference superseded stage names

ADR-0005 and ADR-0007 predate `#28` and this ADR; their `-t standalone` / `-t headless` / `gui` references are stale. Those ADRs are **not edited** (the historical record stands); this table is the authoritative mapping:

| Name in ADR-0005 / 0007 | After `#28` | After this ADR (0014) |
|---|---|---|
| `standalone` (idle + exec, no stream) | absorbed into `headless` | `headless` |
| old `headless` (`runheadless.sh`, auto WebRTC) | `headless-stream` | `stream` |
| `gui` (X11) | removed | removed (use `stream` + WebRTC client) |

The entrypoint *pattern* those ADRs establish (Python-driven `SimulationApp`, livestream-on-demand via the custom `isaacsim.exp.base.python.streaming.kit` experience) is unchanged -- only the target name it lands on moves to `stream`.

## GPU for CI tests is blocked upstream

ADR-0011 routes Smoke + Integration (GPU-requiring) pytest to the `devel-test` stage. But `devel-test` is a base-template *baseline* stage, and `ycpss91255-docker/base`'s `setup.sh` emits its `test` compose service as a bare block with no `deploy` GPU reservation and no per-stage override entry point (baseline stages are excluded from the `#220` per-stage override mechanism). So GPU pytest in `devel-test` currently cannot run; it is latent only because no pytest tests have landed yet. This gap is filed upstream as `ycpss91255-docker/base#493` (test/tooling stages need a sane, controllable runtime-config surface). The isaac-side enablement is blocked on that and tracked in `ycpss91255-docker/isaac#74`.

## Consequences

- The rename touches ~53 references in `ycpss91255-docker/isaac` (Dockerfile, `config/docker/setup.conf`, `Makefile.local`, `script/*.sh`, README x4, CHANGELOG, TEST.md) plus the `omniverse_web_viewer` sub-repo (README x4, compose). Implementation is tracked in `ycpss91255-docker/isaac#69` (rescoped).
- The docker repo also adds `[stage:test-tools-stage] gui.mode = off` + GPU-off override as an interim, since `test-tools-stage` (lint binaries only) inherits GPU / devices / X11 via `extends: devel` until `base#493` fixes the default.
- ADR-0005 / 0007 remain unedited; readers reconcile stage names via the mapping table above.

## References

- `ycpss91255-docker/isaac#28` -- 4->2 stage consolidation (the rename's starting point).
- ADR-0005 -- standalone-with-livestream entrypoint pattern (stage names superseded; see mapping).
- ADR-0007 -- custom streaming Kit experience for `SimulationApp` (stage names superseded; see mapping).
- ADR-0011 -- CI architecture; routes GPU Smoke / Integration to `devel-test`.
- `ycpss91255-docker/isaac#69` -- "infer stage" issue, rescoped to this rename.
- `ycpss91255-docker/base#493` -- upstream: `-test` / tooling stages need controllable runtime config.
- `ycpss91255-docker/isaac#74` -- isaac-side GPU-on-`devel-test` enablement, blocked on `base#493`.
