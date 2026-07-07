# EXP-201: L2 kinematic pushes a dynamic object (momentum transfer + squish)

Physics milestone "L2 true-kinematic + hybrid" (#201), ADR-0008.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l2_push.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## In plain terms

Picture a snowplow pushing a box across a floor: the plow shoves the box ahead
of it, and because the plow is heavy and engine-driven it just keeps to its
lane no matter how hard the box pushes back. The key finding: the kinematic
mover pushed the dynamic box forward through contact (box moved more than 0.2 m
in the push case, more than 0.4 m in the squish case) while the mover itself
stayed on its commanded path within sub-centimetre (tracking error under
0.02 m) -- it never got shoved off course by the box's reaction. When the box
was driven into a static wall it pinned just short of it (stopping between
x=0.7 and the wall at x=1.2) and stayed stable, no blow-up.

Note on levels (ADR-0021 D2): a true-L2 body is kinematic -- to the physics
solver it is effectively infinitely heavy, so PhysX holds it exactly on its
commanded path regardless of the forces pushing back on it, with no motor, no
stiffness, and no sag. That is a different mechanism from the L2.5/L3 position
drive, which is a motorized joint that would give and sag under load
(sag = mg/k). The kinematic mover pays for that unshakable path with its own
limits: it ignores contact when teleported, and it can only push cleanly if
each per-tick step stays under the carry-speed limit -- move it too far in one
tick and it outruns the contact solver and flings the object instead of pushing
it.

## Question

The carry-speed experiment (#201) showed a kinematic mover carries a resting
dynamic payload only through the contact-respecting write path
(`dc.set_kinematic_target`, not the `dc.set_rigid_body_pose` teleport). This
records the complementary INTERACTION case: a true-L2 kinematic mover driven
into a SEPARATE dynamic object.

1. **Momentum transfer** -- does the kinematic mover push the dynamic box
   ahead of it, and does the mover hold its COMMANDED path (a kinematic body
   ignores the reaction force)?
2. **Squish / limit** -- pushed into a static wall, is the box trapped between
   the mover and the wall (stops at the wall, stays finite / settled)?

## Setup

- Fixture: `test/fixtures/usd/l2_push.usda` -- a KINEMATIC mover at x=-1.0 + a
  DYNAMIC 5 kg box in its path at x=0.0 (resting on the ground) + a static
  ground + a static wall at x=+1.2 + a gravity `PhysicsScene`. Primitive cubes,
  no external mesh.
- Drive: the mover is driven HORIZONTALLY along +X via the contact-respecting
  kinematic TARGET write each tick (`--ramp-step` 0.005 m, ~0.3 m/s at 60 Hz):
  `dc.set_kinematic_target` (`setKinematicTarget`) where the dc build exposes
  it, else a USD `xformOp:translate` write on the kinematicEnabled prim WHILE
  physics plays. Both feed the kinematic target through the contact solver, so
  the mover pushes the box. This Isaac Sim build's dynamic_control does NOT
  ship `set_kinematic_target`, so the USD-translate path is used -- the proven
  #201 carry-speed mechanism (PR #218, green on the GPU runner). A plain
  `dc.set_rigid_body_pose` teleport (`setGlobalPose`) bypasses contact and does
  NOT push, so it is not used; a single large step outruns the contact solver
  (the same carry-speed caveat as the #201 carry experiment).
- Horizontal push is deliberately chosen over a vertical carry: it does not
  fight gravity through the contact, so it is far less sensitive to the
  per-tick speed limit.
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), NOT a `SimulationContext` (the #151
  shutdown-hang surface). 60 seat ticks, ramp, 180 settle ticks.

Two modes:

- **push**: drive the mover to x=0.5 (short of the wall). The box is pushed
  ahead; the mover lands on its commanded path.
- **squish**: drive the mover to x=0.85 so the box (half-extent 0.15) is pinned
  against the wall (left face at 1.15, box centre ~1.0).

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_l2_push.py -v
```

Or a single mode by hand:

```bash
/isaac-sim/python.sh test/integration/pytest/_l2_push_runner.py \
    --usd test/fixtures/usd/l2_push.usda --mode push \
    --ramp-step 0.005 --target-x 0.5
# -> [PUSH SUMMARY] mode=push ... box_disp=... mover_err=...
```

## Results

Measured on the self-hosted GPU runner (RTX 5090 reference), 2026-06-25 (CI run
28178185983, `test_l2_push.py` PASSED). The exact `[PUSH SUMMARY]` field values
below were captured from a direct runner invocation on the runner box
(2026-07-07) with identical arguments.

Raw markers:

```
[PUSH SUMMARY] mode=push drive=usd_translate ramp_step=0.005 target_x=0.5 mover_x=0.5 box_x0=-0.000001 box_x=0.806913 box_disp=0.806914 mover_err=0.0 box_finite=True wall_x=1.2
[PUSH SUMMARY] mode=squish drive=usd_translate ramp_step=0.005 target_x=0.85 mover_x=0.85 box_x0=-0.000001 box_x=1.000376 box_disp=1.000377 mover_err=0.0 box_finite=True wall_x=1.2
```

### Momentum transfer (push, ramp-step 0.005 m, mover commanded x=0.5)

| quantity | measured |
|---|---|
| mover final x | 0.500 (exactly on the commanded path) |
| box displacement | **0.807 m** -- pushed forward PAST the mover (momentum carries it) |
| mover tracking error | **0.000 m** -- the box reaction did not perturb the mover |

The mover is commanded to x=0.5 and lands exactly there; the box is pushed to
0.807 m -- FARTHER than the mover, because the transferred momentum carries the
dynamic box ahead after contact. The kinematic mover ignores the reaction force
entirely (tracking error 0.000 m).

### Squish / limit (squish, mover commanded x=0.85, wall at x=1.2)

| quantity | measured |
|---|---|
| mover final x | 0.850 (exactly on the commanded path) |
| box displacement | **1.000 m** (box at x=1.000) -- pinned short of the wall at 1.2 |
| mover tracking error | **0.000 m** -- held its path while pinning the box |

The box is driven to x=1.000, pinned short of the static backstop (wall at 1.2,
left face ~1.15): it does not tunnel through, stays finite/settled, and the
kinematic mover still holds its commanded path exactly (0.000 m error) while
pinning it.

## Findings

- **Momentum transfers through contact.** Driven into the box with the
  contact-respecting `set_kinematic_target` path at small per-tick steps, the
  kinematic mover pushes the dynamic box ahead of it -- the box moves, the
  mover does not. This is the positive interaction the carry-speed experiment's
  negative control (`set_rigid_body_pose` teleport) lacks.
- **The kinematic mover is unaffected by the reaction.** A kinematic body is
  infinitely massive to the solver: the box's contact reaction does not perturb
  the mover's commanded path (tracking error sub-cm). This is the L2 guarantee
  -- a kinematic part follows its command exactly, while still interacting with
  dynamics.
- **Squish is stable.** Pinned between the advancing mover and the static wall,
  the box stops at the wall and stays finite / settled -- no NaN/inf blow-up
  under the constraint. The mover continues to hold its commanded path even
  while pinning the box.
- **Practical takeaway (Isaac limit):** an L2 kinematic part can push and pin
  separate dynamic objects through contact, provided the contact-respecting
  write path and a per-tick step within the carry-speed limit are used.
  Horizontal pushes are the robust case; the per-tick speed limit (the
  carry-speed experiment) is the caveat to respect.

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l2_push.py` (both tests PASSED)
- Runner script: `test/integration/pytest/_l2_push_runner.py`
- Fixture: `test/fixtures/usd/l2_push.usda`
- CI run: 28178185983 (`python-tests` job; the asserted properties above all
  held -- GPU aggregate 33 collected, 33 passed counting the host xc leg, no
  failures)
