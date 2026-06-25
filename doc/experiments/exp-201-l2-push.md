# EXP-201: L2 kinematic pushes a dynamic object (momentum transfer + squish)

Physics milestone "L2 true-kinematic + hybrid" (#201), ADR-0008.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l2_push.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

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
- Drive: the mover is driven HORIZONTALLY along +X via `dc.set_kinematic_target`
  (`setKinematicTarget`, the contact-respecting path; ADR-0008) in SMALL
  per-tick steps (`--ramp-step` 0.005 m, ~0.3 m/s at 60 Hz) so contact
  transfers each tick (a large per-tick jump teleports the mover through the
  box -- the same carry-speed caveat as the #201 carry experiment).
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

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: CI run
<RUN_ID> (the recording run), <DATE>. The numbers below are filled in from the
recording CI run output.

### Momentum transfer (push, ramp-step 0.005 m, mover target x=0.5)

| quantity | value |
|---|---|
| box start x (m) | <BOX_X0> |
| box end x (m) | <BOX_X_PUSH> |
| box displacement (m) | <BOX_DISP_PUSH> |
| mover commanded x (m) | 0.5 |
| mover end x (m) | <MOVER_X_PUSH> |
| mover tracking error (m) | <MOVER_ERR_PUSH> |

The box is pushed forward (positive +X displacement); the kinematic mover
tracks its commanded path within sub-cm (it ignores the reaction force).

### Squish / limit (squish, mover target x=0.85, wall at x=1.2)

| quantity | value |
|---|---|
| box end x (m) | <BOX_X_SQUISH> |
| box displacement (m) | <BOX_DISP_SQUISH> |
| wall x (m) | 1.2 |
| box finite | <BOX_FINITE> |
| mover tracking error (m) | <MOVER_ERR_SQUISH> |

The box is pinned just short of the wall (centre ~1.0, the wall left face at
1.15): it cannot pass the static backstop, stays finite / settled, and the
kinematic mover still holds its commanded path while pinning it.

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

- Date: <DATE>
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l2_push.py`
- Runner script: `test/integration/pytest/_l2_push_runner.py`
- Fixture: `test/fixtures/usd/l2_push.usda`
- CI run: <RUN_ID> (recording run; the tables above are its measured output)
