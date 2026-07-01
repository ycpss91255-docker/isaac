# EXP-201 -- kinematic carry speed limit

> Milestone: "Physics: L2 true-kinematic + hybrid" (pre-v1.0.0). Issue #201
> (exp(L2): kinematic part pushing/grasping an independent dynamic object) and
> its carry-speed sub-issue. ADR-0008, ADR-0021 D1 / D2. Follow-up to EXP-193
> (PR #215, true-L2 zero-error HOLD under load).

## In plain terms

Picture carrying a full coffee cup on a tray: lift the tray gently and the cup
rides along, but yank it up too fast and the cup gets left behind or flips off.
The key finding: through the contact-respecting path the kinematic mover carries
its 10 kg payload at every ramp speed tested, and the payload sits cleanly on
top (ending at z=1.20) all the way up to 0.05 m per tick -- but at 0.2 m per
tick the fast motion flings it to z=5.19 m, so the clean-carry speed limit lies
between 0.05 and 0.2 m per tick. The separate teleport path (`global_pose`)
never carries at all: the payload is left at z=0.70 at every speed. So this is a
speed trade-off, not a hard "kinematic bodies cannot carry" wall -- stay under
the limit and use the right write path and it carries fine.

Note on levels (ADR-0021 D2): a true-L2 body is kinematic -- PhysX holds it
exactly on target no matter the load, with no motor, no stiffness, and no sag,
which is why its own hold error is essentially zero. That is a different
mechanism from the L2.5/L3 position drive, which is a motorized joint that sags
under load (sag = mg/k). The kinematic body pays for that perfect hold with its
own limits: when it is teleported it ignores contact entirely, and even on the
contact-respecting path moving it too far in one tick outruns the contact solver
and launches whatever it carries -- the carry-speed limit measured here.

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

Measured sweeps (CI run `28174325301`, 10 kg payload). Both write paths swept
across the same per-tick steps. The mover reaches z=1.0 in every case; the
payload Z and the carried flag (payload_z > 1.05) tell the story.

`global_pose` (teleport, negative control) -- never carries:

```
      write_mode    ramp_step_m    mover_z    payload_z   carried
  global_pose             0.001     1.0000       0.7000     False
  global_pose             0.003     1.0000       0.7000     False
  global_pose              0.01     1.0000       0.7000     False
  global_pose              0.05     1.0000       0.7000     False
  global_pose               0.2     1.0000       0.7000     False
```

`kinematic_target` (contact path, USD xform on this build) -- always carries,
clean rest at slow steps, LAUNCH at the fastest:

```
        write_mode    ramp_step_m    mover_z    payload_z   carried
  kinematic_target          0.001     1.0000       1.2000      True
  kinematic_target          0.003     1.0000       1.2000      True
  kinematic_target           0.01     1.0000       1.2000      True
  kinematic_target           0.05     1.0000       1.2000      True
  kinematic_target            0.2     1.0000       5.1872      True
```

- `global_pose` carries at: **no step** (the teleport never carries; payload
  left at its start z=0.70 at every step).
- `kinematic_target` carries at: **every step** (payload_z > 1.05 throughout).
- `kinematic_target` clean rest (payload seated at ~1.20) up to and including
  **0.05** m/tick; **0.2** m/tick LAUNCHES the payload to **5.19** m.
- The clean-carry speed limit lies between **0.05** and **0.2** m/tick.

## Findings

- **The teleport never carries (ADR-0008).** Under `dc.set_rigid_body_pose`
  (`setGlobalPose`) the payload is left at its start (z=0.70) at EVERY swept
  step, even the slowest -- the global-pose write bypasses the contact
  integrator entirely, so the kinematic mover passes straight through the
  resting dynamic payload. This is the negative control that isolates the carry
  mechanism to contact. (`dc.set_kinematic_target` is absent from this Isaac
  build's dynamic_control interface, as the openbase L2 smoke test already
  guards; the contact path therefore uses a USD `xformOp:translate` write while
  physics plays, which PhysX reads as the kinematic target.)
- **The contact path always carries -- the speed limit is seat vs LAUNCH, not
  carry vs drop.** Writing the kinematic target through the contact solver
  carries the payload at every swept step (it is never left behind). But the
  carry OUTCOME changes with speed: up to 0.05 m/tick the payload settles
  cleanly on the mover top (payload_z = 1.20), while at 0.2 m/tick the contact
  impulse from the fast kinematic motion FLINGS the payload to z=5.19 -- ~4 m
  above the mover. So the effective per-tick speed limit is a CLEAN-carry limit
  (between 0.05 and 0.2 m/tick here): below it the payload rides quietly; above
  it the kinematic motion launches it off the mover.
- **Root cause is the write-path semantics, not "kinematic bodies cannot
  carry".** A kinematic body DOES carry a dynamic object -- but only via the
  contact-respecting kinematic TARGET write (`set_kinematic_target` or a
  while-playing USD xform write), never via the `setGlobalPose` teleport. This
  is exactly why EXP-193 was scoped to HOLD-under-load (zero per-tick
  displacement) rather than lift/carry.
- **Implication for the hybrid path.** Any future kinematic carry/push motion
  (forklift tine lifting a load) must use the contact-respecting kinematic
  target (NOT `set_rigid_body_pose`) AND cap its per-tick displacement below the
  clean-carry limit, or the load is flung off. The HOLD case (EXP-193) is
  unaffected.

## Provenance

- Data measured on the self-hosted GPU runner, CI run `28174325301`; proven
  green at the run id noted in the PR after the final iteration.
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
