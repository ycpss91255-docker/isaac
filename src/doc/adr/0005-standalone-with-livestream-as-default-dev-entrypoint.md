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
- `script/forklift_blocky_driver_wip.py` was ported to this pattern in PR-B for #19. Future drivers (`cmd_vel_planar_*.py`, `move_openbase_planar_*.py`, the `diag_*` family) can be ported opportunistically; they continue to work under the in-kit Script Editor flow until ported.
- ADR-0002 keeps its original decision (use in-kit Script Editor + `rclpy` + `dc` velocity write) as the *historical* path; this ADR-0005 adds an addendum-style "Update" at the bottom of ADR-0002 pointing at this file.
- The new pattern is also LLM-friendly: Claude can run `./exec.sh -t headless /isaac-sim/python.sh <script>` directly, capture stdout, and time-bound the run via `timeout`. No browser interaction is required.

## Acceptance Snapshot

Verified during PR-A + PR-B of #19:

- `script/standalone_livestream_smoke.py` boots `SimulationApp` with `livestream: 2`, opens a tiny scene programmatically, spins ~5990 ticks in ~30 s, exits 0.
- `script/forklift_blocky_driver_wip.py` (ported) runs the existing 51 s demo cycle (approach → pickup → carry → drop → back away → fork spread → mast extend → return home → repeat) without behavioural drift from the previous in-kit Script Editor run.
- Both scripts shut down cleanly via `Ctrl-C` (SIGINT) and `timeout` (SIGTERM); Kit logs `Simulation App Shutting Down` before process exit.

## References

- Issue: `ycpss91255-docker/isaac#19` "Adopt standalone-with-livestream entrypoint (replace Script Editor Ctrl+Enter loop)"
- Isaac Sim manual livestream client: <https://docs.isaacsim.omniverse.nvidia.com/5.1.0/installation/manual_livestream_clients.html>
- Isaac Sim standalone application docs: <https://docs.isaacsim.omniverse.nvidia.com/5.1.0/python_scripting/standalone_application.html>
- Related ADRs: 0001 (Chassis SE(2) Slide), 0002 (cmd_vel teleop via in-kit Script Editor — superseded as entrypoint pattern by this ADR), 0003 (two-track simulation strategy), 0004 (Model A-hybrid forklift block model)
- SOP: `doc/standalone_livestream_workflow.md`
