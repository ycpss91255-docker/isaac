# EXP-193 -- true-L2 zero-error kinematic hold under load

> Milestone: "Physics: L2 true-kinematic + hybrid" (pre-v1.0.0). Issues #193
> (exp(L2): per-link true-kinematic substitution generality, isolated) / #194
> (leaf link -> standalone L2). ADR-0021 D1 / D1a / D2.

## In plain terms

Picture a magic shelf that you set to a height and it stays exactly there no
matter how much you pile on it -- it never sags a hair. The key finding: the
kinematic platform held its commanded 1.0 m height with essentially zero error
(`< 1e-4` m) while a full 10 kg load rested on it, whereas a spring-like L2.5
drive would visibly droop about 19.6 mm under that same load. That perfect hold
is a property of *how* it is held, not a stiffer version of a spring: it is a
teleport-to-target, not a spring being loaded.

Note on levels (ADR-0021 D2): a true-L2 body is kinematic -- PhysX simply moves
it to its commanded pose and holds it there regardless of gravity, forces, or
the load it bears, so it has no motor, no stiffness, and no sag, and its error
is essentially zero. That is a categorically different mechanism from the
L2.5/L3 position drive, which is a real motorized joint that always sags a
little under load (sag = mg/k). The kinematic body pays for its perfect hold
with its own separate limits: it has no physical dynamics of its own and it
ignores contact when it teleports, so moving it too fast per tick would leave
its payload behind -- but a pure hold (zero motion per tick) never trips that,
which is exactly why the error here is zero.

## Goal

Demonstrate the **true-L2 endpoint** of the L2 / L2.5 / L3 continuum (ADR-0021
D1a): a standalone **kinematic** rigid body commanded to a position holds that
position with **essentially zero** steady-state error **even under load** --
the direct contrast to EXP-184's L2.5 articulation drive, whose steady-state
error is the load/stiffness sag `m*g/stiffness` (19.4 mm at k=5000, 0.79 mm at
k=1e5, 18 um at k=1e6, for the same 10 kg payload).

PhysX moves a kinematic actor to its target "regardless of external forces,
gravity, collision" (ADR-0021 D1a), so the kinematic limit is `k -> infinity`:
no force concept, zero error. True-L2 cannot exist on an articulation **link**
(PhysX forbids kinematic articulation links, ADR-0021 D2), so it must be a
**standalone** rigid body -- which is exactly what this experiment exercises.

## Setup

- **Fixture:** `test/fixtures/usd/l2_kinematic_hold.usda` (synthetic, license
  clean; NOT the real forklift).
  - `/World/Platform` -- KINEMATIC rigid body (`physics:kinematicEnabled=1` +
    `PhysicsRigidBodyAPI` + `PhysicsCollisionAPI` + `PhysicsMassAPI`), the body
    under test. Commanded each tick via `dc.set_rigid_body_pose`.
  - `/World/Payload` -- DYNAMIC rigid body, **10 kg** mass + `CollisionAPI`,
    resting on the platform top; gravity loads the platform.
  - `/World/PhysicsScene` -- gravity enabled (Z down, 9.81 m/s^2).
  - `/World/Ground` -- static collider at z=0 (the payload never reaches it
    under correct kinematic behaviour).
- **Drive:** the platform is commanded to `target_z = 1.0` m each tick via the
  proven openbase L2 pattern (`dc.set_rigid_body_pose` on a `kinematicEnabled`
  body, `test/integration/test_openbase_l2_stability.py`), settled for 240
  ticks; the pose is read back with `dc.get_rigid_body_pose`.
- **Stepping:** `omni.timeline.play()` + a loop of `app.update()` -- NEVER a
  `SimulationContext` (deferred, #151 shutdown hang); `app.close()` in a
  `finally`.
- **Runner / test:** `test/integration/pytest/_l2_hold_runner.py` (one
  `SimulationApp`, prints `[L2HOLD SUMMARY] ... [EXIT CLEAN]`) +
  `test/integration/pytest/test_l2_kinematic_hold.py` (subprocess-per-run,
  regex-parse the marker). GPU-only.

## Reproduction

```bash
# inside the repo on a GPU host
./script/run.sh -t test -- \
  /isaac-sim/python.sh -m pytest -q \
  test/integration/pytest/test_l2_kinematic_hold.py
```

The full GPU gate (collected >= baseline + all green + aggregate) is
`./test/assert_pytest_baseline.sh --gpu`, wired into the `python-tests` CI job
on the self-hosted GPU runner.

## Results

L2.5 reference is the **model** `m*g/stiffness` (ADR-0021 D1a) re-evaluated for
the 10 kg payload; EXP-184 measured those values on an RTX 5090. The L2 row is
this experiment's measured kinematic hold error.

| Level | Mechanism | Error under 10 kg load | Source |
|---|---|---|---|
| L2.5 | articulation high-stiffness position drive, k=5000 | 19.4 mm (measured) ~ 19.6 mm (`m*g/k`) | EXP-184 |
| L2.5 | k=1e5 | 0.79 mm (measured) | EXP-184 |
| L2.5 | k=1e6 | 18 um (measured) | EXP-184 |
| **L2 (true)** | **standalone kinematic body, `dc.set_rigid_body_pose`** | **0.0 m** (exact; epsilon floor, `< 1e-4` m) | **this experiment (CI run 28170120845)** |

Measured `[L2HOLD SUMMARY]`: `target=1.000000`
`resting=1.000000` `error=0.000000e+00` `payload_mass=10.000`
`payload_z=1.200000` `payload_on_platform=True`
`l25_sag_mm_k5000=19.6200`.

The kinematic platform held `target_z=1.0` with `error=0.0` (exact, the epsilon
floor) while a 10 kg dynamic payload rested on it at `payload_z=1.20`
(`payload_on_platform=True`), confirming the load is genuinely borne.

## Findings

- **Kinematic hold is exact under load.** The platform's steady-state error is
  at the float/readback epsilon floor (`< 1e-4` m) while it carries the full
  10 kg payload -- not "small", but the zero-error endpoint. The payload rests
  on the *raised* platform (`payload_on_platform=True`), confirming the load is
  real and the kinematic body is genuinely bearing it, not ignoring contact.
- **L2 dwarfs L2.5 by orders of magnitude.** The kinematic error is `>= 100x`
  smaller than the L2.5 `m*g/k` sag at the lowest swept stiffness (k=5000,
  ~19.6 mm) -- in practice ~1e6x smaller. True-L2 has no load/stiffness floor;
  L2.5 always does (ADR-0021 D1a). This is the empirical confirmation of the
  "`error = 0` (command=position)" cell in the ADR-0021 D1 table.
- **Standalone is mandatory.** This works precisely because the platform is a
  standalone rigid body, not an articulation link (ADR-0021 D2). The hybrid
  topology (a kinematic part + an L3 articulation joined by a compliant
  rigid-body loop joint) is the follow-up (#194 leaf-link substitution and the
  hybrid-seam compliance question).

### Notes / lesson -- why this is HOLD, not lift/carry

This experiment is scoped to a **hold under load** (the platform starts at the
target height with the payload already resting on it), not a lift/carry. The
reason is `dc.set_rigid_body_pose`: it is a **teleport** (`setGlobalPose`) that
**bypasses the contact integrator** (ADR-0008: "must use setKinematicTarget not
setGlobalPose"). A kinematic body moved with `setGlobalPose` is placed at its
new pose without the contact solver interpolating the motion, so a dynamic
object resting on it does NOT come along -- if the body moves far per timestep
it is left behind / tunnels through. An early version of this runner LIFTED the
platform from z=0.5 to z=1.0 via `set_rigid_body_pose` and the payload stayed at
z=0.7 (`payload_on_platform=False`), exactly this teleport-vs-contact gap.

So a kinematic body **carrying or pushing** a dynamic object has an effective
**per-timestep speed limit**: move too far per tick and the dynamic object slips
off. The HOLD case (this experiment) is unaffected -- zero per-tick displacement
means contact is re-resolved every tick. The carry speed limit itself (and the
contact-respecting `set_kinematic_target` path that actually carries) is
measured in the Task-2 follow-up experiment, EXP-201 (#201 carry-speed
sub-issue, PR #218).

## Provenance

- Proven green on the self-hosted GPU runner, CI run `28170120845`.
- ADR-0021 (Physics-Level Realization on Articulation Models, L2 / L2.5 / L3),
  decisions D1 / D1a / D2.
- Pattern reuse: the proven kinematic pose-tracking approach from
  `test/integration/test_openbase_l2_stability.py` (0.0000 tracking error) and
  the subprocess-per-run + marker-line + regex-parse pattern from
  `test/integration/pytest/test_joint_drive_integration.py`.
- L2.5 contrast numbers: EXP-184 ("L3 control verification" milestone, 10 kg
  payload, RTX 5090), as recorded in ADR-0021 D1a.
