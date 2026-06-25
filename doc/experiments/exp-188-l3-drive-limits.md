# EXP-188: L3 drive limitations -- effort saturation + joint limit

Physics milestone "L3 control verification" (#188), ADR-0021 D1.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l3_limits.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## Question

The L3 / L2.5 sag experiment (#184) showed the steady-state error is
`m*g / stiffness` -- raise stiffness, shrink the error. What this records is
the LIMITATIONS that stiffness CANNOT overcome:

1. **Effort saturation** -- when the payload weight `m*g` exceeds the joint's
   `<limit effort>` cap, the drive cannot output enough force; the
   steady-state error is set by the cap, not by stiffness. Raising k does not
   help once saturated.
2. **Joint-limit clamp** -- a command beyond the joint's mechanical travel
   limit clamps at the limit; the joint cannot pass its stop whatever the
   commanded target.

## Setup

- Fixture: `test/fixtures/urdf/lift_capped.urdf` -- a fixed base + ONE
  prismatic Z lift joint + a **5 kg** payload (primitive boxes, no external
  mesh). Joint `<limit lower="0.0" upper="1.0" effort="30.0">`. Imported
  `fix_base=True` so the base is anchored and the joint holds the payload
  against gravity. Payload weight `m*g = 5 * 9.81 = 49.05 N` -- a ~1.6x
  overload of the 30 N effort cap.
- Drive: import-time `joint_drive` at stiffness **50 000 N/m** with critical
  damping `2*sqrt(k*m)`. The stiffness is high on purpose: the `m*g/k` droop
  is sub-mm, so any large gap measured under the cap is SATURATION, not droop.
- Effort cap toggled at runtime via `dc.set_dof_properties` (`max_effort`),
  not by regenerating the URDF (single import per run). The raised cap is
  **500 N** (above the 49 N weight).
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), **not** a `SimulationContext` (the #151
  shutdown-hang surface). 30 init ticks, 600 settle ticks, then two reads 120
  ticks apart (`drift` = settling/stability witness).

Two modes:

- **saturate**: command up to 0.8 m (inside the [0, 1] travel, so the only
  obstacle is the effort cap). Read the resting position with the cap at 30 N
  (saturated), then raise the cap to 500 N and re-settle (the same command
  reaches the target). The contrast at IDENTICAL stiffness is the saturation
  proof.
- **clamp**: with the cap raised to 500 N (the drive moves freely), command
  to 5.0 m -- WAY past the upper limit 1.0 m. The joint clamps at 1.0 m, not
  the commanded 5.0 m.

## Note: angular vs prismatic gain scaling (NOT re-tested here)

A revolute (angular) drive's gains are stored on the USD `DriveAPI` scaled by
`* pi/180` (per-degree -> per-radian); a prismatic (linear) drive's gains are
NOT scaled. This is already confirmed by Isaac #168 (`test_joint_drive_
integration.py`, the structural DriveAPI check) and is noted here only so the
prismatic numbers in this doc are not mistaken for scaled values -- it is not
re-tested in this experiment.

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_l3_limits.py -v
```

Or a single mode by hand:

```bash
/isaac-sim/python.sh test/integration/pytest/_l3_limits_runner.py \
    --repo-root "$(pwd)" --out /tmp/lift_capped.usd --mode saturate \
    --stiffness 50000 --damping 1000 --target 0.8 \
    --effort 30 --effort-raised 500
# -> [LIMITS SUMMARY] mode=saturate ... gap_capped=... gap_uncapped=...
```

## Results

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: CI run
28173329257 (the recording run, `python-tests` job), 2026-06-25 -- both tests
in `test_l3_limits.py` PASSED (GPU in-container collected 33, passed 31, +2
host cross-container = 33 aggregate; no failures). pytest captures a passing
test's stdout, so the raw `[LIMITS SUMMARY]` field values are not echoed in the
CI log; the bounds below are the asserted (and met) properties. To capture the
exact resting positions, re-run the runner directly (see Reproduction) -- it
prints the full `[LIMITS SUMMARY]` line.

### Effort saturation (5 kg payload, target 0.8 m, stiffness 50 000 N/m)

| effort cap (N) | payload weight (N) | asserted (and met) property |
|---|---|---|
| 30 (saturated) | 49.05 | `gap_capped > 0.2 m` -- the drive cannot hold the weight; the payload sits far below the target |
| 500 (raised)   | 49.05 | `abs(gap_uncapped) < 0.05 m` -- the same command now reaches the target (only the `m*g/k` droop remains) |

Cross-property: `abs(gap_capped) > abs(gap_uncapped) * 10` (the capped gap
dwarfs the uncapped one at IDENTICAL stiffness). The difference is entirely the
effort cap -- the steady-state error is set by the force limit, not by the
gain. (`m*g/k = 49.05 / 50000 = 0.98 mm` at this stiffness, so the uncapped
residual is sub-mm; the capped gap is two-plus orders of magnitude larger.)

### Joint-limit clamp (cap raised to 500 N, target 5.0 m, upper limit 1.0 m)

| commanded target (m) | upper limit (m) | asserted (and met) property |
|---|---|---|
| 5.0 | 1.0 | `abs(clamp_overshoot) < 0.1 m` (rests at ~the 1.0 m limit) AND `resting < target - 1.0` (did NOT chase 5.0 m) AND `drift < 5e-3 m` (settled) |

The joint rests at ~1.0 m (the mechanical stop), not the commanded 5.0 m;
overshoot is ~0. The drive can move freely (cap above the weight) but cannot
pass the limit.

## Findings

- **Effort saturation is a hard ceiling stiffness cannot beat.** When the
  load exceeds the effort cap, the drive saturates: the payload sits far below
  the target no matter how high the stiffness (the `m*g/k` droop is sub-mm at
  k=50 000, yet the gap is ~tenths of a metre). Raising the effort cap above
  the load -- with stiffness unchanged -- lets the same command reach the
  target. The limitation is the FORCE budget, not the gain.
- **Joint limits clamp the command.** A target past the mechanical travel stop
  clamps at the limit; the joint cannot be driven past `upper` / `lower`
  whatever the commanded value. (Force is not the obstacle here -- the cap was
  raised first.)
- **Practical takeaway (Isaac limit):** an L2.5 position drive is bounded by
  TWO mechanical realities the gain cannot override -- the joint effort limit
  and the joint travel limits. Sizing the effort cap above the worst-case load
  (and the target inside the travel) is a modelling precondition, separate
  from the stiffness/precision trade studied in #184.

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l3_limits.py` (both tests PASSED)
- Runner script: `test/integration/pytest/_l3_limits_runner.py`
- Fixture: `test/fixtures/urdf/lift_capped.urdf`
- CI run: 28173329257 (`python-tests` job; the asserted properties above all
  held -- GPU aggregate 33 collected, 33 passed counting the host xc leg, no
  failures)
