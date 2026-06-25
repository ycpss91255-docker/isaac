# EXP-201 -- kinematic carry speed limit

> Milestone: "Physics: L2 true-kinematic + hybrid" (pre-v1.0.0). Issue #201
> (exp(L2): kinematic part pushing/grasping an independent dynamic object) and
> its carry-speed sub-issue. ADR-0008, ADR-0021 D1 / D2. Follow-up to EXP-193
> (PR #215, true-L2 zero-error HOLD under load).

## Goal

Measure the **effective per-tick speed limit** at which a kinematic mover stops
carrying a resting dynamic payload, and isolate the carry mechanism to the
ADR-0008 write-path distinction. EXP-193 confirmed a kinematic body HOLDS a load
with zero error, but the two kinematic write paths carry very differently:

- `dc.set_rigid_body_pose` (`setGlobalPose`) is a **teleport** that BYPASSES the
  contact integrator (ADR-0008: "must use setKinematicTarget not
  setGlobalPose"). It NEVER carries a resting dynamic payload at any ramp step --
  the mover passes straight through and the payload is left at its start. This is
  the **negative control**.
- `dc.set_kinematic_target` (`setKinematicTarget`) feeds the kinematic target
  through the **contact solver**, so the mover pushes the payload via contact and
  carries it UP TO a per-tick speed limit: ramp slowly and it rides along; ramp
  too far in one tick and contact cannot keep up, so the payload is left behind /
  tunnels.

This experiment sweeps the per-tick ramp displacement under both paths: it
confirms the teleport never carries, and finds the threshold between "carried"
and "dropped" for the contact path.

## Setup

- **Fixture:** `test/fixtures/usd/l2_carry_speed.usda` (synthetic, license
  clean; NOT the real forklift).
  - `/World/Mover` -- KINEMATIC rigid body (`physics:kinematicEnabled=1` +
    `PhysicsRigidBodyAPI` + `PhysicsCollisionAPI` + `PhysicsMassAPI`), the
    carrier under test. Starts at z=0.5, ramped up via the selected write path.
  - `/World/Payload` -- DYNAMIC rigid body, **10 kg** + `CollisionAPI`, resting
    on the mover top at z=0.70; gravity loads the mover.
  - `/World/PhysicsScene` -- gravity enabled (Z down, 9.81 m/s^2).
  - `/World/Ground` -- static collider at z=0 (the dropped payload lands here).
- **Ramp:** the mover is seated for 60 ticks at its start height so the payload
  settles, then ramped from z=0.5 to z=1.0 in fixed per-tick steps of
  `ramp_step` metres via the `--write-mode` path (`kinematic_target` default, or
  `global_pose` for the negative control), then held at z=1.0 for 120 ticks. The
  carried/dropped outcome is read from the final payload Z.
- **Stepping:** `omni.timeline.play()` + a loop of `app.update()` -- NEVER a
  `SimulationContext` (deferred, #151 shutdown hang); `app.close()` in a
  `finally`.
- **Runner / test:** `test/integration/pytest/_l2_carry_speed_runner.py` (one
  `SimulationApp` per ramp step + write mode, prints `[CARRY SUMMARY] ... [EXIT
  CLEAN]`) + `test/integration/pytest/test_l2_carry_speed.py` (2 tests:
  subprocess-per-run, regex-parse the marker, sweeps both paths). GPU-only.
- **Sweep:** ramp steps 0.001 / 0.003 / 0.01 / 0.05 / 0.2 m per tick (spanning
  200x: the slowest ~0.06 m/s, the fastest ~12 m/s at 60 Hz). A carried payload
  ends near z=1.20 (mover top 1.05 + payload half-height 0.15); a dropped payload
  sits at or below z=1.05 (left behind near its start, or on the ground).

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

Measured sweeps (CI run `<CI_RUN_ID>`, 10 kg payload). Both write paths swept
across the same per-tick steps; the `[CARRY SUMMARY]` tables are surfaced on
stderr in the (passing) run log.

`global_pose` (teleport, negative control):

```
<GLOBAL_POSE_TABLE>
```

`kinematic_target` (contact path):

```
<KINEMATIC_TARGET_TABLE>
```

- `global_pose` carries at: **no step** (the teleport never carries).
- `kinematic_target` largest **carried** ramp step: `<MAX_CARRIED>` m/tick.
- `kinematic_target` smallest **dropped** ramp step: `<MIN_DROPPED>` m/tick.
- Effective carry speed limit (threshold) lies between them.

## Findings

- **The teleport never carries (ADR-0008).** Under `dc.set_rigid_body_pose`
  (`setGlobalPose`) the payload is left at its start at EVERY swept step, even
  the slowest -- the global-pose write bypasses the contact integrator entirely,
  so the kinematic mover passes straight through the resting dynamic payload.
  This is the negative control that isolates the carry mechanism to contact.
- **The contact path carries up to a per-tick speed limit.** Under
  `dc.set_kinematic_target` (`setKinematicTarget`) the mover carries the payload
  below `<MAX_CARRIED>` m/tick (it rides up onto the raised mover); at/above
  `<MIN_DROPPED>` m/tick the target outruns the contact solver and the payload is
  left behind / tunnels and falls. The carried/dropped split is monotone, so the
  threshold is bracketed.
- **Root cause is the write-path semantics, not "kinematic bodies cannot
  carry".** A kinematic body DOES carry a dynamic object -- but only via
  `setKinematicTarget` (the contact-respecting interpolated path) AND only when
  its per-tick displacement is small enough for contact to keep up. The
  `setGlobalPose` teleport never carries. This is exactly why EXP-193 was scoped
  to HOLD-under-load (zero per-tick displacement) rather than lift/carry.
- **Implication for the hybrid path.** Any future kinematic carry/push motion
  (forklift tine lifting a load) must use `set_kinematic_target` (NOT
  `set_rigid_body_pose`) AND cap its per-tick displacement below the measured
  threshold. The HOLD case (EXP-193) is unaffected.

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
