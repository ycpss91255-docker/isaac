# EXP-188: L3 drive limitations -- effort saturation + joint limit

Physics milestone "L3 control verification" (#188), ADR-0021 D1.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l3_limits.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## In plain terms

The earlier sag test (#184) showed that a stiffer motor droops less -- but this
one records two walls that NO amount of stiffness can push through. First, a
motor has a maximum force it can push, like a person who simply cannot lift
something heavier than they are strong. Here a 5 kg box weighs 49 N but the
joint's force budget is capped at 30 N, so the drive is overloaded and the box
sits stuck more than 0.2 m below the target -- and cranking the stiffness does
nothing, because the residual droop at this stiffness is under 1 mm (0.98 mm),
so the whole gap is the drive running out of force. Raise the force cap to
500 N (comfortably above the 49 N weight) and, with the stiffness unchanged,
the same command reaches the target with only that sub-millimetre droop left.
Second, a joint has mechanical end-stops, like a drawer that stops at its rail
however hard you pull: commanded all the way to 5.0 m against a 1.0 m upper
stop, the joint just rests at 1.0 m and never chases the 5.0 m. The takeaway:
size the motor's force above the worst-case load and keep the target inside the
travel -- these are modelling preconditions the gain cannot fix, separate from
the precision-vs-stiffness trade in #184.

Note on levels (ADR-0021 D1a): the "L2.5" stiff drive and the softer "L3"
compliant drive are the SAME mechanism -- one articulation joint plus a
position controller, differing ONLY in stiffness (gain), both leaving a droop
of weight * g / stiffness. Stiffness only shrinks that droop; it does nothing
about the force cap or the end-stops shown here, because those are limits of
the joint itself, not of the gain. And neither drive becomes true-L2 -- a
kinematic body PhysX teleports to the target while ignoring forces (ADR-0021
D2). Notably a true-L2 body would blow straight through the effort cap (it
ignores forces), but it would still respect a joint travel limit, which is
geometry rather than force.

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

Measured on the self-hosted GPU runner (RTX 5090 reference), 2026-06-25 (CI run
28173329257, `test_l3_limits.py` PASSED). The exact `[LIMITS SUMMARY]` field
values below were captured from a direct runner invocation on the runner box
(2026-07-07) with identical arguments.

Raw markers:

```
[LIMITS SUMMARY] mode=saturate mass=5 weight_n=49.05 effort_cap=30 effort_raised=500 target=0.8 resting_capped=1.04773e-11 resting_uncapped=0.799209 gap_capped=0.8 gap_uncapped=0.000791001 drift=0
[LIMITS SUMMARY] mode=clamp mass=5 weight_n=49.05 effort_cap=500 target=5 upper_limit=1 lower_limit=0 resting=1 clamp_overshoot=0 drift=0
```

### Effort saturation (5 kg payload, target 0.8 m, stiffness 50 000 N/m)

| effort cap (N) | payload weight (N) | resting (m) | gap to target (m) |
|---|---|---|---|
| 30 (saturated) | 49.05 | 1.05e-11 (~0, stuck at the bottom) | **0.800** (full gap -- never lifts) |
| 500 (raised)   | 49.05 | 0.799209 | **0.000791 (0.79 mm)** -- reaches target, only `m*g/k` droop |

The 30 N cap cannot lift the 49 N weight at all: the payload sits at ~0 with the
FULL 0.8 m gap. Raising the cap to 500 N lets the SAME command reach the target
with only 0.79 mm residual -- so the capped gap dwarfs the uncapped by ~1000x at
IDENTICAL stiffness. The error is set by the force limit, not the gain
(`m*g/k = 49.05 / 50000 = 0.98 mm`, and the measured uncapped 0.79 mm sits below
that linear bound). Drift 0 (settled).

### Joint-limit clamp (cap raised to 500 N, target 5.0 m, upper limit 1.0 m)

| commanded target (m) | upper limit (m) | resting (m) | overshoot (m) |
|---|---|---|---|
| 5.0 | 1.0 | **1.000** | **0** |

Commanded 5.0 m, the joint rests EXACTLY at the 1.0 m mechanical stop with zero
overshoot -- it did not chase 5.0 m. Drift 0. The drive moves freely (cap above
the weight) but cannot pass the limit.

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
