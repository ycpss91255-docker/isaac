# Onboarding agent-proxy gate (M5, isaac#135)

This is the runbook for the **M5 onboarding gate** -- the MVP completion
point. The success criterion (PRD "Testing & Acceptance", M5 metric) is:

> A newcomer or a fresh agent, given **only** `example/` + its README, can
> scaffold -> run -> swap a robot -> swap a sensor **without asking anyone
> and without reading framework source** (`framework/isaac_devkit/*`).

The gate is the agent-proxy for that newcomer, plus one human dry-run
before the v1.0.0 tag as final acceptance.

## What "pass" means

The proxy must complete all three tasks, framework source untouched:

1. **First topic** -- scaffold a workspace and reach the live camera topic
   `/camera_bot/camera/color/image_raw` (M1 time-to-first-topic).
2. **URDF swap** -- swap `camera_bot` for a different minimal robot/link
   (edit `example/sim/model/` + `example/sim/scene/robot.yaml`).
3. **In-scope sensor swap** -- change resolution / fps / topic override, or
   add a second camera, by editing `example/sim/config/sensor/custom.yaml`.

The **lidar / imu `NotImplementedError`** boundary is the documented
out-of-scope edge (see `example/README.md` "Out of scope / not yet
implemented"); the proxy is NOT asked to cross it.

## Enforcement level (honest)

Per the issue DoD, the PRD allows three enforcement tiers. What this
harness actually achieves:

| Tier | Achievable here? |
|---|---|
| Make `framework/` unreadable mid-run (mechanical, hard block) | **No** -- the sub-agent shares the read-only filesystem; we cannot `chmod` the mounted tree. |
| Audit the tool-call log for framework reads (mechanical, post-hoc) | **Yes** -- `agent_proxy_gate.sh --audit <log>` greps the proxy's tool-call log for any `framework/isaac_devkit/` access and fails the gate if found. |
| Downgrade to advisory; human dry-run is the real backstop | **Yes, and we do.** The audit is post-hoc, so nothing physically blocks a read at the instant it happens. |

**Net**: enforcement is **mechanical-via-audit, advisory at the moment of
access**. The structure precondition (below) is fully mechanical and
repeatable; the framework-read prohibition is enforced by auditing the
proxy's log after the run. The **pre-1.0.0 human dry-run (step 4) is the
real backstop** and stays OPEN until a human runs it.

## Running the gate

### Step 1 -- structure precondition (mechanical, repeatable)

Assert that `example/` + README are self-sufficient for the three tasks
BEFORE spending a proxy run. Hosted, no Isaac / GPU / network:

```bash
test/onboarding/agent_proxy_gate.sh
```

It checks: the 4-lang example README exists, documents all three tasks,
carries the lidar/imu out-of-scope callout, and the URDF + sensor swap
surfaces are present. Exit 0 + `STRUCTURE PASS`. The same assertions run in
CI as `test/unit/pytest/test_onboarding_gate.py` (in the hosted-unit
baseline, ratcheted).

### Step 2 -- spawn the proxy (fresh agent)

Spawn a fresh general-purpose sub-agent whose instructions give it **only**
the `example/` + README context and the three tasks, explicitly forbidding
it from reading `framework/isaac_devkit/*`. The proxy may boot for real on
a GPU box (`script/run.sh -t test`) for a true first-topic, or -- if a full
GPU boot is too heavy -- assert through the scaffold structure-check +
a dry/headless path and document that scope. Prefer a real first-topic.

Capture the proxy's tool-call log (the list of files it read / edited) as
`<log>`.

### Step 3 -- audit the proxy (mechanical)

```bash
test/onboarding/agent_proxy_gate.sh --audit <log>
```

Fails if the log references `framework/isaac_devkit/`. Exit 0 +
`AUDIT PASS` means the framework-source prohibition held.

Record the outcome (did it reach first-topic? swap URDF? swap sensor?
framework untouched?) as the gate evidence (see "Run log" below).

### Step 4 -- pre-1.0.0 human dry-run (OPEN, the real backstop)

**This step cannot be executed by an agent. It is deferred to a human and
remains OPEN until done.**

Before tagging `v1.0.0`, one human who has not built this repo must, using
only `example/` + README:

- [ ] scaffold a workspace and reach the camera topic;
- [ ] swap the URDF for a different minimal robot;
- [ ] do one in-scope sensor swap (resolution / fps / topic / second cam);
- [ ] confirm they never needed to open `framework/` source;
- [ ] file follow-up issues for any friction (out of scope for this gate --
      fixing the gaps is separate work, per issue #135 "Out of scope").

**Status: OPEN.** The v1.0.0 tag is blocked on this checkbox. Record the
human's name, date, and outcome here when done.

## Run log

| Date | Proxy | First topic | URDF swap | Sensor swap | Framework untouched | Enforcement |
|---|---|---|---|---|---|---|
| 2026-06-11 | self-driven (the #135 executor, framework-blind role-play) | reasoned to camera topic via README + scaffold | yes (robot.yaml + model) | yes (custom.yaml resolution/fps) | yes (audited, no framework read) | mechanical-via-audit |
| 2026-06-12 | **genuinely independent fresh agent** (clean context, zero framework knowledge) | reached (scaffold + structural; expected `/camera_bot/camera/color/image_raw`) | yes (`box_bot.urdf` + robot.yaml) | yes (custom.yaml 1280x720/30 -> 640x480/15) | yes (transcript audited: only example/ + README + new-workspace.sh --help + onboarding doc; zero framework/src/test access) | mechanical-via-audit |

The first run (2026-06-11) was self-driven by the agent that built #135 --
it role-played being framework-blind, but already had the framework in its
context, so it proved the harness, not self-sufficiency. The second run
(2026-06-12) is the credible proof: a **separately spawned fresh agent**
started with a clean context (no framework knowledge), given only
`example/` + README, completed all three tasks and its full tool-call
transcript was audited -- it touched only `example/`, the example READMEs,
`script/new-workspace.sh --help`, this onboarding doc, and its own
throwaway `/tmp` workspace; it never opened `framework/`, `src/`, `test/`,
or any ADR. The GPU first-topic itself is covered by
`test/integration/pytest/test_scaffold_smoke.py` on the RTX 5090.

The independent proxy surfaced three non-blocking onboarding rough edges
(follow-up issue candidates, out of scope for this gate per #135):

1. **Discovery gap** -- the repo-root README does not point at
   `example/README.md` or `script/new-workspace.sh`; a newcomer landing at
   the root can miss the onboarding path.
2. **Opaque `just` targets** -- `just setup/build/run/import-model` are
   invoked by name but defined in `.base/justfile`; a `just --list` pointer
   or one-line descriptions in the example README would help.
3. **GPU-bound steps** -- fully closing first-topic and the URDF swap needs
   one GPU boot (`just import-model` for the new USD, `just run` for the
   live frame); the hosted-only path scaffolds, edits, and validates
   structure but cannot produce the actual frame / USD. The onboarding doc
   already acknowledges this.

The pre-1.0.0 human dry-run (step 4) remains the real backstop and is still
OPEN.
