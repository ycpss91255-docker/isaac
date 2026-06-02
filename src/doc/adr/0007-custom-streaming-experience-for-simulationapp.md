# Custom Streaming Kit Experience for `SimulationApp`-Driven Workflows

`SimulationApp({"headless": True, "livestream": 2})` invoked via `./exec.sh -t standalone /isaac-sim/python.sh <driver.py>` is supposed to launch one Kit instance that publishes a WebRTC livestream the Isaac Sim Streaming Client can attach to (ADR-0005). In practice that flag is a no-op against `SimulationApp`'s default Kit experience: no streaming extensions are loaded, the WebRTC server never starts, the Streaming Client has nothing to connect to.

This ADR records why we ship a **custom Kit experience** — `isaacsim.exp.base.python.streaming.kit` — that layers the streaming extensions on top of the lightweight Python base, rather than reusing NVIDIA's bundled streaming experience or papering over the gap with env-var glue. The custom file lives in `ycpss91255-docker/isaac` (issue #21 fix-B); drivers in this repo opt in by passing `experience="/isaac-sim/apps/isaacsim.exp.base.python.streaming.kit"` to `SimulationApp(...)`.

## Context

NVIDIA ships three relevant Kit experiences (`/isaac-sim/apps/`):

- **`isaacsim.exp.base.python.kit`** — the experience `SimulationApp` falls back to when no `experience=` is passed. `[dependencies]` is `isaacsim.exp.base` only. **Has no livestream extensions.** Boots fast. Perfect for Python drivers that don't need a viewport.
- **`isaacsim.exp.full.streaming.kit`** — the experience `runheadless.sh` invokes via the `kit` binary. `[dependencies]` is `isaacsim.exp.full` + `omni.services.livestream.nvcf`. Inherits the full editor / sensors / Replicator bundle (~200 extensions). `[settings.app.livestream]` block is set. Streaming Client connects to this every time `runheadless.sh` runs.
- **`isaacsim.exp.base.python.kit` + `omni.kit.livestream.{core, webrtc}` overlaid as extra dependencies** — does not exist as a shipped file; this is the gap.

The forklift driver (and every future driver in this repo) is `SimulationApp`-driven. It needs the streaming server enabled, and it needs to *not* take down the rest of the entrypoint pattern with native crashes or surprise side effects from a heavy bundle.

## Considered Options

- **(a) Pass `experience="/isaac-sim/apps/isaacsim.exp.full.streaming.kit"` to `SimulationApp(...)`** — reuse what `runheadless.sh` uses. Tested live: WebRTC server *does* start (`Streaming server started.` in stdout), then the Kit native code segfaults shortly after, no Python traceback (`PythonTracebackStatus = ''`). Reproducible across both non-root (`yunchien`) and `docker exec -u 0` runs, with and without `WARP_CACHE_PATH` / `--portable-root` overrides. The full streaming experience is built around the `kit` binary's direct-launch path (note its `execFile = "isaac-sim.streaming"` and `--no-window` arg in `isaac-sim.streaming.sh`); something in the full bundle is incompatible with the `SimulationApp` Python launcher's stdin / process / signal model.
- **(b) Custom experience `isaacsim.exp.base.python.streaming.kit`** (**chosen**) — file is `isaacsim.exp.base.python.kit`'s structure (depends on `isaacsim.exp.base`, Python-friendly settings.app.* block, fast boot) with two added dependencies (`omni.kit.livestream.core`, `omni.kit.livestream.webrtc`) and a `[settings.app.livestream]` block lifted from `full.streaming.kit`. Shipped by `ycpss91255-docker/isaac` under `/isaac-sim/apps/`, COPY'd in the `devel` stage so all derived targets (headless, gui, standalone) see it.
- **(c) Env-var wrapper** — e.g. set `LIVESTREAM=2 + PUBLIC_IP=127.0.0.1` before `python.sh` (the pattern IsaacLab discussion #4361 mentions). Tested: the env vars are honored by experiences that already load the livestream extensions, but they do not *add* extensions to a Python base experience that doesn't have them. So this is orthogonal — would need to be combined with (a) or (b) to be useful, and on its own doesn't bridge the gap.
- **(d) Skip livestream entirely** — verify drivers via ROS 2 topics, give up the Streaming Client view. This was the actual state of the system from PR-A / PR-B of ADR-0005 onward, until live verification (Update section of ADR-0005) surfaced that the visual end-to-end never worked. Demoting the Streaming Client to "nice to have" loses the LLM-friendly view-on-demand premise of ADR-0005.

## Why (b)

Each rejected option fails on a different axis:

| Constraint | (a) full | (b) custom (chosen) | (c) env-only | (d) skip livestream |
|---|---|---|---|---|
| `SimulationApp` doesn't native-crash | **no** | yes | yes (but useless alone) | yes |
| Streaming Client sees driver's scene | n/a (crashes) | yes | no (no streaming exts) | no |
| Boot cost (extensions loaded) | ~200 | ~32 | base default | base default |
| Maintenance surface (custom file to keep in sync with NVIDIA) | 0 | 1 file (~50 lines) | 0 | 0 |
| Survives NVIDIA bumping ext / experience minor versions | yes | yes (extension names are stable) | yes | yes |

(b)'s only real cost is the 50-line `apps/isaacsim.exp.base.python.streaming.kit` file we have to keep co-evolved with NVIDIA's `base.python.kit` if/when they restructure. The cost is small; the diff is mechanical; the extension list is short. The IsaacLab project ships a similar pattern (`isaaclab.python.rendering.kit` — base + custom render extensions) so the precedent is established.

## Consequences

- **`script/forklift_blocky_driver_wip.py`** and **`script/standalone_livestream_smoke.py`** pin `experience=` to the custom file. Future drivers in this repo do the same.
- **`doc/standalone_livestream_workflow.md`** (the SOP) gains a "you must pass `experience=`" call-out in the skeleton template section. `-t headless` is removed from the SOP and replaced with `-t standalone`.
- **ADR-0005** gains the `Update (2026-05-21)` section that records the live-verification findings (target mismatch + experience mismatch) and points at this ADR.
- If NVIDIA ships a first-party `isaacsim.exp.base.python.streaming.kit` (or equivalent) in a future Isaac Sim minor release, this ADR can be deprecated and the driver call sites can switch back to the upstream file. Until then the custom file is the contract.

## Cross-references

- `ycpss91255-docker/isaac#21` — issue tracking the docker side fix (mount layout for kit/data + kit/logs + the custom kit experience).
- ADR-0005 — entrypoint pattern; Update section explains the live-verification findings.
- ADR-0002 — original in-kit Script Editor path, still valid as a Plan B.
- IsaacLab AppLauncher source (custom kit experience precedent): <https://github.com/isaac-sim/IsaacLab/blob/main/source/isaaclab/isaaclab/app/app_launcher.py>
- Isaac Sim livestream client docs: <https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html>
