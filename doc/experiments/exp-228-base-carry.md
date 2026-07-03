# EXP-228: a kinematic base carries an articulation

Physics milestone (L2 true-kinematic + hybrid, pre-v1.0.0), issue #228,
ADR-0021.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_base_carry.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## In plain terms

The everyday case: a robot base drives across the floor on a scripted path
(a true-L2 kinematic move -- you command where it goes and it goes there
exactly) with an arm sitting on top. The question: does the arm come along for
the ride if you just set the arm on the base and move the base?

This experiment tried the simplest "just set it on top" approach -- put both
the moving base and the arm under one parent in the scene graph and slide the
parent. The result is a clear NO: the base moved exactly as commanded (1.500 m)
but the arm did NOT come with it -- it slid off and drifted to 2.369 m, a 0.87 m
miss (`tracked=False`). Think of standing a loose toy on a book and yanking the
book sideways: the book (the kinematic base) goes where you push it, but the
toy (the physics-simulated arm) does not ride along cleanly -- it topples and
skids. The scene-graph parent moves the kinematic base, but the physics engine
does not carry a simulated arm the same way.

The practical lesson: to carry an arm on a moving base you must ATTACH them --
bolt the arm to the base with a joint (a slightly springy connection, measured
in exp-197), or build the base as part of the same articulated robot. You
cannot get a free rigid ride just by nesting them in the scene. One reassuring
sub-result: the arm's OWN joint held its position well (2.3 mm wobble during
the base's accel, settling to 1.5 mm) -- so the arm's motor control is fine;
the problem is purely how the arm is attached to the base.

## Question

The MOST COMMON true-L2 use case: a KINEMATIC base that MOVES on the floor (a
scripted / command=position path, true L2 per ADR-0021 D2) while an
ARTICULATION (an arm / mast) rides ON TOP of it. This is a distinct topology
from the two experiments already done:

- NOT #226 (a serial articulation chain -- all links inside ONE articulation).
- NOT #221 (a kinematic anchor joined to a separate dynamic body by a
  maximal-coordinate FixedJoint -- a soft seam).

Two things the base-movement case raises:

1. **Ride-along.** When the kinematic base translates, does the whole arm
   articulation follow (its world pose tracks the base), or does it lag /
   detach? Measure the ride-along tracking error.

2. **Base-motion disturbance.** While the base accelerates and decelerates,
   does an arm joint commanded to HOLD deviate (inertial / reaction coupling
   from the base's acceleration), and does it settle back after the base
   stops? Measure the held joint's PEAK deviation during accel/decel and the
   RESIDUAL once the base is at rest again.

Both are PhysX properties, so a synthetic, license-clean primitive fixture is
a faithful probe. This is NOT the real forklift model.

## The topology decision (the real uncertainty)

A PhysX articulation LINK cannot be kinematic (ADR-0021 D2), so the moving
base cannot be a link of the arm's articulation. Two ways to attach the arm to
a kinematic base:

- **(A) USD-hierarchy parent** -- the arm articulation prim is a CHILD of the
  kinematic base prim in the USD stage, so it rides along via the transform
  hierarchy (no joint, no seam). This is the CLEAN carry and the intended
  topology for this experiment.
- **(B) FixedJoint** -- join the base and the arm root with a
  maximal-coordinate joint. That is the #221 soft-seam case and is explicitly
  NOT what we want here.

**This experiment builds topology (A) and MEASURES whether the articulation
actually tracks a kinematic parent that moves while physics plays.** A subtlety
forces the exact shape of (A): a rigid body cannot nest inside another rigid
body, so the arm cannot literally be a child of the kinematic *chassis rigid
body*. Instead a plain `/World/Base` Xform (the "base group") parents BOTH the
kinematic chassis (`/World/Base/Chassis`) AND the arm articulation
(`/World/Base/Arm`) as siblings -- no rigid body nests inside another -- and
the base is moved by writing the GROUP's `xformOp:translate` each tick. That
is the faithful "move the parent, expect the children to ride" form of (A).

**Whether topology (A) carries the articulation is the OPEN QUESTION this GPU
run answers.** The two markers together discriminate the regime:

| regime | ride-along error | base-motion disturbance (peak) |
|---|---|---|
| rigid hierarchy carry | ~0 (arm tracks base) | ~0 (arm teleports rigidly, no accel felt) |
| contact-drag carry | small but non-zero (slip) | non-zero (base accel transmitted via contact) |
| no carry (arm left behind) | ~ base displacement | ~0 (base motion never reaches the arm) |

If (A) does not carry (ride-along error ~ base displacement), a FixedJoint
(topology B, the #221 seam) is forced for base carry -- itself the finding.

## Setup

- Fixture: `test/fixtures/usd/l2_base_carry.usda` -- synthetic primitives, NOT
  the real forklift:
  - `/World/PhysicsScene` -- gravity (Z down, 9.81 m/s^2).
  - `/World/Ground` -- static collider slab at z=0.
  - `/World/Base` -- plain Xform (the base group); the runner writes its
    `xformOp:translate` to move the base.
  - `/World/Base/Chassis` -- KINEMATIC rigid body box (50 kg,
    `physics:kinematicEnabled=1`), bottom on the ground, top at z=0.30.
  - `/World/Base/Arm` -- articulation ROOT (a floating-base 1-DOF arm),
    child of the base group, resting on the chassis top.
  - `/World/Base/Arm/Anchor` -- arm root link (2 kg), rests on the chassis top.
  - `/World/Base/Arm/Slider` -- arm mass link (3 kg), joined to Anchor by a
    single PRISMATIC (+X) joint `arm_slide`, held at 0 by a linear position
    drive (stiffness 5000 N/m, damping ~245 = `2*sqrt(k*m)` for the 3 kg
    slider, limits +/- 1 m). The slide axis is +X, so a base +X acceleration
    is exactly what the held slide feels as an inertial disturbance.
  Links are UNSCALED Xforms (rigid body + mass on the Xform) with a child Cube
  for collision geometry, so the prismatic joint local frames are plain metres.
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), **not** a `SimulationContext` (the #151
  shutdown-hang surface). 10 init ticks, 120 seat/hold ticks before motion,
  the 120-tick base profile, then 150 settle ticks.
- Base translate profile (accel -> cruise -> decel -> stop, along +X):
  `--accel 2.0` m/s^2, `--cruise-speed 1.0` m/s, `--cruise-ticks 60`,
  `--dt 1/60` s. That is 30 accel ticks (~0.25 m to reach 1 m/s) + 60 cruise
  ticks (~1.0 m) + 30 decel ticks (~0.25 m) = **120 ticks, ~1.5 m total
  displacement**. The base group's `xformOp:translate` is written each tick.

### Measurement 1: ride-along (`[CARRY SUMMARY]`)

Read the chassis's ACTUAL world-X displacement (`base_disp`, the ground truth
for how far the base really went) and the arm Anchor's world-X displacement
(`arm_disp`) across the profile. `ride_along_err = |arm_disp - base_disp|`
(final); `ride_along_peak_err` is the worst value across the profile. The
`tracked` flag records whether the base moved (> 0.05 m) AND the arm followed
to within half the base displacement.

### Measurement 2: base-motion disturbance (`[BASE COUPLING SUMMARY]`)

The arm slide is commanded to HOLD at 0; its settled equilibrium is recorded
before the base moves. During the accel/decel phases (the only phases with
non-zero base acceleration) the held slide's PEAK deviation from equilibrium
is tracked; after the base stops and settles, the RESIDUAL deviation is read.

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_base_carry.py -v
```

Or the single runner invocation by hand (both marker lines in one run):

```bash
/isaac-sim/python.sh test/integration/pytest/_base_carry_runner.py \
    --usd test/fixtures/usd/l2_base_carry.usda \
    --accel 2.0 --cruise-speed 1.0 --cruise-ticks 60 --dt 0.016666667
# -> [CARRY SUMMARY] base_disp=... arm_disp=... ride_along_err=... tracked=...
# -> [BASE COUPLING SUMMARY] ... peak_dev=... residual=...
```

## Results

Measured on the self-hosted GPU runner (marker lines from one runner
invocation).

Raw markers:

```
[ARTICULATION] root=/World/Base/Arm
[CARRY SUMMARY] base_disp=1.500003 arm_disp=2.368574 ride_along_err=8.685706e-01 ride_along_peak_err=8.851512e-01 tracked=False
[BASE COUPLING SUMMARY] hold_target=0.000000 equilibrium=4.514487e-07 peak_dev=2.316115e-03 residual=1.530231e-03 base_disp=1.500003 base_accel=2.000000 cruise_speed=1.000000
```

### Ride-along (base ~1.5 m +X translate)

| quantity | value |
|---|---|
| base displacement (chassis world X) | 1.500003 m (commanded ~1.5 m -- kinematic chassis followed the group exactly) |
| arm displacement (Anchor world X) | 2.368574 m (DIVERGED -- moved farther than the base) |
| ride-along error (final) | 0.868571 m |
| ride-along peak error | 0.885151 m |
| tracked (base moved and arm followed) | **False** |

### Base-motion disturbance (held slide, accel/decel at 2 m/s^2)

| quantity | value |
|---|---|
| held-slide equilibrium (before base motion) | 4.51e-07 m (~0) |
| peak deviation during accel/decel | 2.32e-03 m (2.3 mm) |
| residual deviation after the base stops | 1.53e-03 m (1.5 mm) |

## Findings (relation to ADR-0021)

- **Does topology (A) carry the articulation? NO (CONFIRMED negative result).**
  `tracked=False`. The kinematic chassis followed the group xform EXACTLY
  (1.500 m of the commanded 1.5 m), but the floating arm articulation did NOT
  ride along rigidly -- it DIVERGED to 2.369 m, a 0.869 m final error (0.885 m
  peak). Mechanism: the arm rests on the chassis by CONTACT only (no joint,
  floating base, by design of topology A). Writing the parent group's
  `xformOp:translate` each tick moves the KINEMATIC chassis (a kinematic body
  honors pose writes) but does NOT rigidly move the PhysX-simulated floating
  articulation -- the per-tick parent-transform write injects spurious velocity
  into the articulation root, and it overshoots. So USD-hierarchy parenting
  does NOT carry a physically-simulated articulation: the kinematic sibling
  follows, the articulation sibling does not. For a moving base to carry an
  arm you must ATTACH them -- a FixedJoint from base to arm root (topology B,
  the #221 compliant seam; exp-197 measured that seam follows at ~1.0 ratio),
  OR make the base a driven LINK of one articulation (a mobile-base
  articulation), OR drive the arm root kinematically too. The zero-seam
  USD-parent shortcut is NOT a valid base-carry topology.

- **Is the base-motion disturbance bounded and transient? YES.** The arm's
  INTERNAL prismatic joint, commanded to hold at 0, deviated only 2.3 mm at
  peak during the 2 m/s^2 accel/decel and settled to a 1.5 mm residual -- the
  drive held its target well even while the whole arm was being dragged. So the
  failure above is NOT the arm's internal control (that is fine, the #226 /
  #193 result holds); it is specifically the base-to-arm ATTACHMENT. Note this
  disturbance number is measured relative to the arm's own base, so it stays
  meaningful even though the arm did not track the chassis.

- **Relation to the L2/L2.5/L3 continuum (ADR-0021 D1a/D2).** This is the
  true-L2 base-MOVEMENT case: the base is a standalone kinematic body driven
  along a scripted path (no torque-driven drivetrain -- wheeled dynamics are
  out of scope, #228). It complements #193 (true-L2 kinematic HOLD under load)
  and #201 (the kinematic-carry speed limit for a dynamic payload) by asking
  the harder question -- can a kinematic base carry a whole ARTICULATION, not
  just a single rigid payload -- and whether the intended zero-seam topology
  (A) actually delivers it.

## Provenance

- Date: 2026-07-03
- Runner: self-hosted GPU (Isaac Sim devel-test image); numbers captured from a
  direct runner invocation on the runner box (`--accel 2.0 --cruise-speed 1.0
  --cruise-ticks 60 --dt 1/60`); the 3-test suite passed on the same build.
- Test: `test/integration/pytest/test_base_carry.py` (3 tests)
- Runner script: `test/integration/pytest/_base_carry_runner.py`
- Fixture: `test/fixtures/usd/l2_base_carry.usda` (synthetic, NOT the real
  forklift)
- CI run: GitHub Actions Main CI/CD on branch `exp/base-carry` (GPU
  `python-tests` job, pass).
