# EXP-226: multi-joint coupling in a serial position-drive chain

Physics milestone, issue #226, ADR-0021.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_multijoint_coupling.py`) is the REPRODUCTION
harness: re-running it on a GPU box regenerates the numbers below for
re-verification.

## Question

The single-DOF experiments (EXP-184 sag, #180 tracking, #193 hold) each drive
ONE joint, so they cannot answer two multi-joint questions:

1. **Sag accumulation.** Does a position-drive's steady-state error COMPOUND
   down a serial chain? With N joints in series, the base-most joint bears all
   the links above it (sags most) and each child inherits its parent's sag, so
   the chain-TIP total error should be the SUM of the per-joint `mg/k` sags.
   Is the measured tip error the summed single-joint prediction?

2. **Cross-joint disturbance.** Step-move joint 0 while joints 1 and 2 hold.
   Does a held joint deviate during the transient (reaction / inertial
   coupling through the PhysX articulation solver), and does it settle back?
   How large is the peak transient deviation, and what residual steady-state
   error remains?

Both are PhysX articulation-solver properties, so a synthetic, license-clean
primitive-box chain is a faithful probe. This is NOT the real forklift model.

## Setup

- Fixture: `test/fixtures/urdf/multi_joint_chain.urdf` -- a fixed base + THREE
  prismatic +Z lift joints (`lift0` base-most .. `lift2` tip-most) each
  carrying a **5 kg** primitive-box link (no external mesh). Imported
  `fix_base=True`, `merge_fixed_joints=True` so all three prismatic joints
  survive and the base is anchored.
- Drive: import-time position drive (`_convert_urdf` `joint_drive_stiffness`/
  `joint_drive_damping`, applied to EVERY joint) at stiffness **5000 N/m**,
  **critical damping `2*sqrt(k*m)`** with `m` = the whole-chain mass (15 kg)
  so no joint is left underdamped (the steady-state position is
  damping-independent; damping only governs the transient).
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), **not** a `SimulationContext` (the #151
  shutdown-hang surface). Joints are addressed by NAME
  (`find_articulation_dof`) for a deterministic base->tip ordering. 30 init
  ticks, 600 sag-settle ticks, 400 transient-watch ticks, 700 post-step
  settle ticks.
- Load borne per joint (base->tip): `lift0` bears 15 kg, `lift1` bears 10 kg,
  `lift2` bears 5 kg. Single-joint model `sag_j = (mass above j) * g / k`
  (linear / prismatic drive, N/m stiffness, NOT scaled by pi/180 -- that is
  angular-only). `g = 9.81`.

### Sub-measurement 1: sag accumulation

Command every joint to hold at `--sag-target` (0.0), settle under gravity,
read each joint's resting position. Per-joint droop is `|target - resting|`;
the chain-tip total error is the SUM of the three local sags. Compare to the
summed single-joint prediction.

Analytic prediction at k = 5000 N/m (the recorded run's stiffness):

| joint | borne mass (kg) | predicted `mg/k` (m) |
|---|---|---|
| `lift0` (base) | 15 | 0.029430 (29.4 mm) |
| `lift1` (mid)  | 10 | 0.019620 (19.6 mm) |
| `lift2` (tip)  |  5 | 0.009810 (9.8 mm) |
| **tip total (sum)** | -- | **0.058860 (58.9 mm)** |

### Sub-measurement 2: cross-joint disturbance

Record the held equilibrium of joints 1 and 2, then step-move joint 0 to
`--step-target` (0.5 m) while joints 1 and 2 keep their hold targets. Track
the PEAK deviation of the held joints during the 400-tick transient, then
settle 700 ticks and read the RESIDUAL steady-state deviation. A bounded
coupling shows a transient peak that decays back to a small residual.

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_multijoint_coupling.py -v
```

Or the single runner invocation by hand (both marker lines in one run):

```bash
/isaac-sim/python.sh test/integration/pytest/_multijoint_runner.py \
    --repo-root "$(pwd)" --out /tmp/multi_joint_chain.usd \
    --stiffness 5000 --damping 547.7 --sag-target 0.0 --step-target 0.5
# -> [CHAIN SUMMARY] ... tip_error=... sag_predicted_sum=...
# -> [COUPLING SUMMARY] ... max_peak_dev=... max_residual=...
```

(`--damping 547.7` = `2*sqrt(5000*15)`, critical damping for the 15 kg
whole-chain reference mass.)

## Results

Measured on the self-hosted GPU runner. To be filled from the GPU run.

### Sag accumulation (k = 5000 N/m, 5 kg links, hold target 0.0 m)

| joint | borne mass (kg) | predicted `mg/k` (m) | measured sag (m) |
|---|---|---|---|
| `lift0` (base) | 15 | 0.029430 | TBD (filled from GPU run) |
| `lift1` (mid)  | 10 | 0.019620 | TBD (filled from GPU run) |
| `lift2` (tip)  |  5 | 0.009810 | TBD (filled from GPU run) |
| **tip total**  | -- | **0.058860** | TBD (filled from GPU run) |

- Measured tip error vs summed prediction (`tip_error` / `sag_predicted_sum`):
  TBD (filled from GPU run).
- Ordering base > mid > tip confirmed: TBD (filled from GPU run).

### Cross-joint disturbance (step joint 0 -> 0.5 m, hold joints 1 and 2)

| held joint | peak transient deviation (m) | residual steady-state deviation (m) |
|---|---|---|
| `lift1` | TBD (filled from GPU run) | TBD (filled from GPU run) |
| `lift2` | TBD (filled from GPU run) | TBD (filled from GPU run) |
| **max** | TBD (filled from GPU run) | TBD (filled from GPU run) |

- Joint 0 reached (final position, target 0.5 m): TBD (filled from GPU run).
- Residual `<=` peak (held joints settled back, not diverged): TBD (filled
  from GPU run).

## Findings (relation to ADR-0021)

To be completed once the GPU numbers land. The experiment is designed to
answer two ADR-0021 questions:

- **Does drive error COMPOUND down a chain?** If the measured tip error tracks
  the summed `mg/k` prediction (base sags most, each child inherits its
  parent's sag), then the L2.5 position-drive error is ADDITIVE down a serial
  chain -- a 3-joint lift accumulates roughly the sum of its per-joint droops,
  not a single joint's. This bounds how much stiffness a multi-joint lift
  needs for a target tip precision (the base-most joint dominates because it
  bears the most mass). Expected: measured tip error at or below the summed
  linear `mg/k` (the linear model is a conservative upper bound, per EXP-184).

- **Is cross-joint coupling BOUNDED?** If a step-move of joint 0 disturbs the
  held joints only transiently -- a peak deviation that decays to a small
  residual -- then the articulation solver keeps held joints on target under
  neighbouring motion (the coupling does not leave a permanent offset). This
  is the multi-joint analogue of the single-joint hold/tracking result (#193 /
  #180) and supports treating each joint's steady-state error as independent
  once motion settles. A large residual would instead mean cross-joint
  coupling injects a persistent error, forcing coordinated (not per-joint)
  control.

- **Relation to the L2/L2.5/L3 continuum (ADR-0021 D1a).** This chain is a
  pure L2.5 (high-stiffness position-drive) probe. It does NOT revisit the
  true-L2 (standalone kinematic body) path -- articulation links cannot be
  kinematic (ADR-0021 D2), and a serial chain is necessarily an articulation.
  The experiment characterizes how the L2.5 approximation behaves when
  composed in series, which the single-DOF experiments could not show.

## Provenance

- Date: TBD (filled from GPU run)
- Runner: self-hosted GPU
- Test: `test/integration/pytest/test_multijoint_coupling.py`
- Runner script: `test/integration/pytest/_multijoint_runner.py`
- Fixture: `test/fixtures/urdf/multi_joint_chain.urdf` (synthetic, NOT the
  real forklift)
- CI run: TBD (filled from GPU run)
