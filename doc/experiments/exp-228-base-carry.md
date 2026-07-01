# EXP-228: a kinematic base carries an articulation

Physics milestone (L2 true-kinematic + hybrid, pre-v1.0.0), issue #228,
ADR-0021.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_base_carry.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

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
[CARRY SUMMARY] base_disp=TBD (filled from GPU run) arm_disp=TBD ride_along_err=TBD ride_along_peak_err=TBD tracked=TBD
[BASE COUPLING SUMMARY] hold_target=0.0 equilibrium=TBD peak_dev=TBD residual=TBD base_disp=TBD base_accel=2.0 cruise_speed=1.0
```

### Ride-along (base ~1.5 m +X translate)

| quantity | value |
|---|---|
| base displacement (chassis world X) | TBD (filled from GPU run) |
| arm displacement (Anchor world X) | TBD (filled from GPU run) |
| ride-along error (final) | TBD (filled from GPU run) |
| ride-along peak error | TBD (filled from GPU run) |
| tracked (base moved and arm followed) | TBD (filled from GPU run) |

### Base-motion disturbance (held slide, accel/decel at 2 m/s^2)

| quantity | value |
|---|---|
| held-slide equilibrium (before base motion) | TBD (filled from GPU run) |
| peak deviation during accel/decel | TBD (filled from GPU run) |
| residual deviation after the base stops | TBD (filled from GPU run) |

## Findings (relation to ADR-0021)

- **Does topology (A) carry the articulation?** TBD (filled from GPU run). The
  ride-along error and the disturbance peak together place the run in one of
  the three regimes in the truth table above. If the arm is left behind
  (ride-along error ~ base displacement), topology (A) does NOT carry and a
  FixedJoint (topology B, the #221 seam) is forced for base carry -- a
  first-class finding, not a failure.

- **Is the base-motion disturbance bounded and transient?** TBD (filled from
  GPU run). A bounded coupling shows a peak during accel/decel that decays to
  a small residual once the base is at rest; a persistent offset would leave a
  large residual (the analogue of the #226 cross-joint result, here driven by
  the base's own acceleration rather than a neighbouring joint).

- **Relation to the L2/L2.5/L3 continuum (ADR-0021 D1a/D2).** This is the
  true-L2 base-MOVEMENT case: the base is a standalone kinematic body driven
  along a scripted path (no torque-driven drivetrain -- wheeled dynamics are
  out of scope, #228). It complements #193 (true-L2 kinematic HOLD under load)
  and #201 (the kinematic-carry speed limit for a dynamic payload) by asking
  the harder question -- can a kinematic base carry a whole ARTICULATION, not
  just a single rigid payload -- and whether the intended zero-seam topology
  (A) actually delivers it.

## Provenance

- Date: TBD (filled from GPU run)
- Runner: self-hosted GPU (Isaac Sim / Isaac Lab devel-test image)
- Test: `test/integration/pytest/test_base_carry.py` (3 tests)
- Runner script: `test/integration/pytest/_base_carry_runner.py`
- Fixture: `test/fixtures/usd/l2_base_carry.usda` (synthetic, NOT the real
  forklift)
- CI run: TBD (filled from GPU run)
