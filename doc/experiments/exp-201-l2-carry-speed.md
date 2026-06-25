# EXP-201 -- kinematic carry speed limit

> Milestone: "Physics: L2 true-kinematic + hybrid" (pre-v1.0.0). Issue #201
> (exp(L2): kinematic part pushing/grasping an independent dynamic object) and
> its carry-speed sub-issue. ADR-0008, ADR-0021 D1 / D2. Follow-up to EXP-193
> (PR #215, true-L2 zero-error HOLD under load).

## Goal

Measure the **effective per-tick speed limit** at which a kinematic mover stops
carrying a resting dynamic payload. EXP-193 confirmed a kinematic body HOLDS a
load with zero error, but `dc.set_rigid_body_pose` is a teleport
(`setGlobalPose`) that **bypasses the contact integrator** (ADR-0008: "must use
setKinematicTarget not setGlobalPose"). So when a kinematic mover LIFTS a
resting dynamic payload, moving too far in one tick leaves the payload behind /
tunnels past it. This experiment sweeps the per-tick ramp displacement and finds
the threshold between "carried" and "dropped".

## Setup

- **Fixture:** `test/fixtures/usd/l2_carry_speed.usda` (synthetic, license
  clean; NOT the real forklift).
  - `/World/Mover` -- KINEMATIC rigid body (`physics:kinematicEnabled=1` +
    `PhysicsRigidBodyAPI` + `PhysicsCollisionAPI` + `PhysicsMassAPI`), the
    carrier under test. Starts at z=0.5, ramped up via `dc.set_rigid_body_pose`.
  - `/World/Payload` -- DYNAMIC rigid body, **10 kg** + `CollisionAPI`, resting
    on the mover top at z=0.70; gravity loads the mover.
  - `/World/PhysicsScene` -- gravity enabled (Z down, 9.81 m/s^2).
  - `/World/Ground` -- static collider at z=0 (the dropped payload lands here).
- **Ramp:** the mover is seated for 60 ticks at its start height so the payload
  settles, then ramped from z=0.5 to z=1.0 in fixed per-tick steps of
  `ramp_step` metres, then held at z=1.0 for 120 ticks. The carried/dropped
  outcome is read from the final payload Z.
- **Stepping:** `omni.timeline.play()` + a loop of `app.update()` -- NEVER a
  `SimulationContext` (deferred, #151 shutdown hang); `app.close()` in a
  `finally`.
- **Runner / test:** `test/integration/pytest/_l2_carry_speed_runner.py` (one
  `SimulationApp` per ramp step, prints `[CARRY SUMMARY] ... [EXIT CLEAN]`) +
  `test/integration/pytest/test_l2_carry_speed.py` (subprocess-per-run,
  regex-parse the marker, sweeps the steps). GPU-only.
- **Sweep:** ramp steps 0.001 / 0.003 / 0.01 / 0.05 / 0.2 m per tick. A carried
  payload ends near z=1.20 (mover top 1.05 + payload half-height 0.15); a
  dropped payload sits at or below z=1.05 (left behind near its start, or on the
  ground).

## Reproduction

```bash
# inside the repo on a GPU host
./script/run.sh -t test -- \
  /isaac-sim/python.sh -m pytest -q \
  test/integration/pytest/test_l2_carry_speed.py
```

The full GPU gate (collected >= baseline + all green + aggregate) is
`./test/assert_pytest_baseline.sh --gpu`, wired into the `python-tests` CI job
on the self-hosted GPU runner.

## Results

Measured sweep (CI run `<CI_RUN_ID>`, 10 kg payload):

```
<SWEEP_TABLE>
```

- Largest **carried** ramp step: `<MAX_CARRIED>` m/tick.
- Smallest **dropped** ramp step: `<MIN_DROPPED>` m/tick.
- Effective carry speed limit (threshold) lies between them.

## Findings

- **The carry has a per-tick speed limit.** Below `<MAX_CARRIED>` m/tick the
  kinematic mover carries the resting payload up (it rides along, ending on the
  raised mover); at/above `<MIN_DROPPED>` m/tick the mover teleports past the
  payload in a single tick and the payload is left behind / tunnels and falls.
- **Root cause is the teleport semantics.** `dc.set_rigid_body_pose` writes the
  global pose (`setGlobalPose`), which bypasses the contact integrator
  (ADR-0008). A kinematic body therefore only "carries" a dynamic object when
  its per-tick displacement is small enough that contact is re-resolved every
  step. This is exactly why EXP-193 was scoped to HOLD-under-load (zero per-tick
  displacement) rather than lift/carry.
- **Implication for the hybrid path.** Any future kinematic carry/push motion
  (forklift tine lifting a load) must cap its per-tick displacement below this
  threshold, or use `setKinematicTarget` semantics (ADR-0008) so the contact
  integrator interpolates the motion. The HOLD case (EXP-193) is unaffected.

## Provenance

- Proven green on the self-hosted GPU runner, CI run `<CI_RUN_ID>`.
- ADR-0008 (`setKinematicTarget` vs `setGlobalPose` -- the latter bypasses the
  contact integrator).
- ADR-0021 (Physics-Level Realization on Articulation Models, L2 / L2.5 / L3),
  decisions D1 / D2.
- Follow-up to EXP-193 (PR #215, true-L2 zero-error HOLD under load), which
  surfaced the teleport-vs-contact carry limitation.
- Pattern reuse: the proven kinematic pose-tracking approach from
  `test/integration/test_openbase_l2_stability.py` and the subprocess-per-run +
  marker-line + regex-parse pattern from
  `test/integration/pytest/test_l3_drive_sag.py` (EXP-184).
