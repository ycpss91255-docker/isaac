# Standalone-with-Livestream as Default Dev Entrypoint

Driver scripts in this repo are launched via the **standalone Python entrypoint with WebRTC livestream enabled** —
`SimulationApp({"headless": True, "livestream": 2})` invoked through `./exec.sh -t headless /isaac-sim/python.sh <script>`.
The earlier "open Kit GUI → load script in Script Editor → Ctrl+Enter" loop is retained only for quick interactive REPL experiments;
it is no longer the recommended way to run drivers, and is not the way Claude / other LLM agents drive the sim.

## Context

ADR-0002 captured the Isaac Sim 5.1 / 6.0-pre constraint that ruled out the Action Graph and embedded-Python paths and pushed `/cmd_vel` teleop into an **in-kit Script Editor** workflow. That choice solved the original problem (no daily trust dialog, no USD pollution) but created a different one:

1. The Script Editor lives inside the Kit GUI (WebRTC browser tab). Re-running a script after editing it requires a human Ctrl+Enter.
2. An LLM agent cannot trigger script runs, query stage state, or wait for sim events without a human operator clicking inside the browser.
3. The existing `headless` Docker stage runs `runheadless.sh -v` (a Kit experience that auto-loads the ROS 2 bridge), not a Python entrypoint that drives the sim from outside.
4. The existing `standalone` Docker stage exposes a Python entrypoint but has no WebRTC livestream, so the sim cannot be observed when desired.

Isaac Sim 5.1 ships first-class support for `SimulationApp({"livestream": 2})` — WebRTC livestream attached to a script-driven Kit process. PoC #15 / Issue #19 verified this works on the existing `headless` Docker stage (no new Dockerfile stage required).

## Considered Options

- **(a) Stay on in-kit Script Editor** (ADR-0002) — daily 1–2 minute GUI cost, blocks LLM driving, blocks CI-style automated runs. Re-edit cycle requires browser tab attention.
- **(b) Add a separate `gui` Docker stage with X11 / VNC** — heavier image, daily WebRTC client UX still preferred over X11 forwarding, ruled out as duplicate of an existing capability (`headless` stage already exposes WebRTC).
- **(c) Pure `standalone` stage, no livestream** — Python-driven but no observation path. Loses the ability to confirm "what is the sim actually rendering right now?".
- **(d) Standalone-with-livestream** (**chosen**) — `SimulationApp({"headless": True, "livestream": 2})` in the existing `headless` stage. Script is launched from host via `./exec.sh -t headless /isaac-sim/python.sh <script>`; an optional browser tab attaches to `http://localhost:8011/streaming/webrtc-client` for visual confirmation; closing the tab does not stop the sim.

## Why (d)

| Requirement | (a) in-kit Script Editor | (b) gui stage | (c) pure standalone | (d) standalone-with-livestream |
|---|---|---|---|---|
| LLM agent can launch the sim without a human in the browser | no | no | yes | yes |
| Human can observe the rendered scene when needed | yes | yes | no | yes |
| One Kit process, no cross-process state | yes | yes | yes | yes |
| Works on the existing `headless` Docker stage | partial (no Python entrypoint) | requires new stage | yes | yes |
| Re-edit / re-run cycle is fast for human iteration | medium (browser Ctrl+Enter) | medium | fast | fast |

The browser-close behaviour is intentional and load-bearing: the sim keeps running, so a reviewer can attach mid-run for spot-checks and detach without disturbing state.

## Consequences

- The new SOP `doc/standalone_livestream_workflow.md` is the operating procedure for all driver scripts written from #19 onward; the legacy `doc/cmd_vel_inkit_teleop.md` and `doc/action_graph_setup.md` SOPs are kept as historical reference but flagged as superseded at the top of each file.
- The application demo driver (the camera-bot example's predecessor) was ported to this pattern in PR-B for #19. Other legacy drivers (the planar-move and `diag_*` families) can be ported opportunistically; they continue to work under the in-kit Script Editor flow until ported.
- ADR-0002 keeps its original decision (use in-kit Script Editor + `rclpy` + `dc` velocity write) as the *historical* path; this ADR-0005 adds an addendum-style "Update" at the bottom of ADR-0002 pointing at this file.
- The new pattern is also LLM-friendly: Claude can run `./exec.sh -t headless /isaac-sim/python.sh <script>` directly, capture stdout, and time-bound the run via `timeout`. No browser interaction is required.

## Acceptance Snapshot

Verified during PR-A + PR-B of #19:

- `script/standalone_livestream_smoke.py` boots `SimulationApp` with `livestream: 2`, opens a tiny scene programmatically, spins ~5990 ticks in ~30 s, exits 0.
- The application demo driver (ported) runs its existing 51 s scripted demo cycle without behavioural drift from the previous in-kit Script Editor run.
- Both scripts shut down cleanly via `Ctrl-C` (SIGINT) and `timeout` (SIGTERM); Kit logs `Simulation App Shutting Down` before process exit.

## References

- Issue: `ycpss91255-docker/isaac#19` "Adopt standalone-with-livestream entrypoint (replace Script Editor Ctrl+Enter loop)"
- Isaac Sim manual livestream client: <https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html>
- Isaac Sim standalone application docs: <https://docs.isaacsim.omniverse.nvidia.com/5.1.0/python_scripting/standalone_application.html>
- Related ADRs: 0001 (Chassis SE(2) Slide), 0002 (cmd_vel teleop via in-kit Script Editor — superseded as entrypoint pattern by this ADR), 0003 (two-track simulation strategy), 0004 (Model A-hybrid block model), **0007 (custom streaming experience for SimulationApp)**
- SOP: `doc/standalone_livestream_workflow.md`

## Update (2026-05-21) — `-t headless` does not work for this pattern; switch to `-t standalone` + custom experience

Live verification of the original PR-A / PR-B Acceptance Snapshot above exposed two gaps that the issue body assumed away:

1. **`-t headless` container can't host a `SimulationApp` driver.** Its `ENTRYPOINT` is `runheadless.sh` which immediately starts a full Kit instance (`isaacsim.exp.full.streaming.kit`). When `./exec.sh -t headless /isaac-sim/python.sh <driver.py>` is then run, the driver's `SimulationApp({"livestream": 2})` boots a **second** Kit inside the same container; both Kits race for the WebRTC streaming port (8211) and the driver's Kit silently loses. The Streaming Client connects to the first Kit (empty default stage) — the driver's actual scene is never streamed. The PR-A / PR-B test only verified that the driver runs and emits ROS 2 topics (it does); it did not visually verify the Streaming Client view, which never worked end-to-end. Switch to **`-t standalone`** — that target's container is idle (`sleep infinity`) until `./exec.sh` lands a script, so the driver's Kit is the only Kit instance. `ycpss91255-docker/isaac` Dockerfile §standalone explicitly notes this trade-off in its inline comment, predating this finding.

2. **`SimulationApp({"livestream": 2})` does not start a streaming server by default.** `SimulationApp`'s default Kit experience is `isaacsim.exp.base.python.kit`, which has no WebRTC livestream extensions in its `[dependencies]` block. The `livestream: 2` flag is honored only by experiences that bundle `omni.kit.livestream.{core, webrtc}` — `isaacsim.exp.full.streaming.kit` does, but loading it via `SimulationApp` segfaults shortly after `Streaming server started` (incompatibility between the full experience and Python-driver launcher; native crash, no Python traceback). To get streaming under `SimulationApp` requires a **custom experience** that layers the two streaming extensions on top of `isaacsim.exp.base` without inheriting the rest of the full bundle. This custom experience is `isaacsim.exp.base.python.streaming.kit`, shipped by `ycpss91255-docker/isaac` (issue #21 fix-B) and bound to the driver via `experience=...` in this PR. Design rationale and trade-offs (vs the heavier full bundle, vs env-var wrapper) are pinned in **ADR-0007**.

**Updated canonical invocation**:

```bash
./run.sh -t standalone -d
./exec.sh -t standalone /isaac-sim/python.sh /home/yunchien/work/src/script/<driver>.py [--config ...]
```

with the driver passing:

```python
sim_app = SimulationApp(
    {"headless": True, "livestream": 2},
    experience="/isaac-sim/apps/isaacsim.exp.base.python.streaming.kit",
)
```

The Decision / Why / Considered Options in the body of this ADR all stand — the entrypoint *pattern* (Python-driven, livestream-on-demand) is correct. The two corrections above are about *which container target* and *which Kit experience* the pattern lands on inside `ycpss91255-docker/isaac`. The legacy `cmd_vel_inkit_teleop.md` / `action_graph_setup.md` Script Editor fallback paths in the body remain valid as a Plan B if the standalone path ever regresses.

## Editorial note (2026-06-11)

Incidental application-specific example names in this ADR were replaced with generic wording (camera-bot example) as part of the base-repo convergence (ADR-0017, #128). Decision content is unchanged; the original wording is preserved in git history.
