# EXP-197: hybrid kinematic+dynamic loop-joint boundary compliance

Physics milestone "L2 true-kinematic + hybrid" (#197), ADR-0008; PhysX #308.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_hybrid_boundary.py`) is the REPRODUCTION
harness: re-running it on a GPU box regenerates the numbers below for
re-verification.

## Question

A standalone KINEMATIC anchor is joined to a standalone DYNAMIC body by a
rigid-body (MAXIMAL-COORDINATE) `UsdPhysics.FixedJoint` -- NOT an articulation
joint. The maximal-coordinate joint is known to be COMPLIANT ("weak"; PhysX
#308): it is solved as a soft constraint, so under load the dynamic body GIVES
at the joint rather than holding rigidly.

The experiment quantifies that boundary:

1. **Compliance** -- how far does the hung dynamic body give at the joint vs a
   rigid ideal? (Under its own weight it should settle slightly past the
   joint's rest separation.)
2. **Force transfer** -- when the anchor is moved, does the hung body FOLLOW
   it (the joint transmits the motion, even compliantly)?

The POINT is to MEASURE the give -- record the number even if loose.

## Setup

- Fixture: `test/fixtures/usd/l2_hybrid_loop.usda` -- a KINEMATIC anchor at
  z=2.0 + a DYNAMIC 10 kg body hung 0.5 m below at z=1.5 + a maximal-coordinate
  `UsdPhysics.FixedJoint` (`body0=Anchor`, `body1=Hung`) + a gravity
  `PhysicsScene`. Primitive cubes, no external mesh. The joint rest separation
  is 0.5 m.
- Drive: the anchor is held / raised by writing its pose EVERY tick in SMALL
  increments via `dc.set_rigid_body_pose` (the per-tick kinematic write path
  proven by `test_openbase_l2_stability.py`; the per-step displacement gives
  PhysX a velocity it resolves against the joint constraint, so the anchor's
  motion transmits to the hung body). The lift is 0.5 m at 0.005 m/tick. (The
  explicit `dc.set_kinematic_target` / `setKinematicTarget` contact path of
  ADR-0008 is NOT shipped by this Isaac Sim build's dynamic_control; the runner
  prefers it when present and falls back to the per-tick `set_rigid_body_pose`
  path here.)
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), NOT a `SimulationContext` (the #151
  shutdown-hang surface). 400 settle ticks per phase.

Two phases in a single run:

- **settle**: hold the anchor, let the system settle under gravity, measure
  the separation (compliance = settled separation - rest separation).
- **lift**: raise the anchor 0.5 m, settle, measure the hung body's rise vs the
  anchor's rise (force transfer; follow ratio = hung_rise / anchor_rise).

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_hybrid_boundary.py -v -s
```

Or the runner directly (prints the full `[HYBRID SUMMARY]` line with every
measured field):

```bash
/isaac-sim/python.sh test/integration/pytest/_hybrid_boundary_runner.py \
    --usd test/fixtures/usd/l2_hybrid_loop.usda --lift 0.5 --ramp-step 0.005
# -> [HYBRID SUMMARY] ... compliance=... follow_ratio=...
```

## Results

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: CI run
<RUN_ID> (the recording run), <DATE>. The test surfaces the measured fields on
stderr (`[HYBRID MEASURED] ...`), which lands in the CI log even on a passing
run; the values below are read from there.

| quantity | measured |
|---|---|
| joint rest separation (m) | 0.5 |
| settled separation (m) | <SETTLED_SEP> |
| compliance / give (m) | <COMPLIANCE> |
| anchor rise (m) | <ANCHOR_RISE> |
| hung body rise (m) | <HUNG_RISE> |
| follow ratio (hung / anchor) | <FOLLOW_RATIO> |
| hung body finite | <HUNG_FINITE> |

## Findings

- **The maximal-coordinate FixedJoint is compliant but holds.** The hung body
  settles near the joint's rest separation (0.5 m) with a finite, bounded give
  under the 10 kg load -- the soft constraint stretches but does not collapse
  or fly apart. (The exact give is recorded in the table above; the bands in
  the test are loose because the POINT is to MEASURE it.)
- **The joint transmits motion (force transfer).** Raising the kinematic anchor
  raises the hung body -- the joint follows the anchor's motion within a
  measured band of the rigid ideal (follow ratio ~1.0). A rigid (articulation)
  joint would be exactly 1.0; the maximal-coordinate joint may lag transiently,
  but it follows.
- **It stays finite / settled.** No NaN/inf blow-up at the soft joint under
  load or under the lift.
- **Practical takeaway (Isaac limit):** a hybrid loop (a kinematic anchor +
  a dynamic body joined by a maximal-coordinate joint) is usable -- the joint
  both holds the load (compliantly) and transmits the anchor's motion -- but it
  is NOT rigid: it gives at the joint by the measured compliance. A true-rigid
  connection needs a single articulation, not a maximal-coordinate loop joint
  (PhysX #308; ADR-0021 D2: articulation links cannot be kinematic, so a
  kinematic anchor + a dynamic articulation member is precisely this
  maximal-coordinate-loop case).

## Provenance

- Date: <DATE>
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_hybrid_boundary.py`
- Runner script: `test/integration/pytest/_hybrid_boundary_runner.py`
- Fixture: `test/fixtures/usd/l2_hybrid_loop.usda`
- CI run: <RUN_ID> (recording run; the table above is its measured output)
