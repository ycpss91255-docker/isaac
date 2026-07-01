# EXP-226: multi-joint coupling in a serial position-drive chain

Physics milestone, issue #226, ADR-0021.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_multijoint_coupling.py`) is the REPRODUCTION
harness: re-running it on a GPU box regenerates the numbers below for
re-verification.

## In plain terms

Picture a three-section telescoping lift, each section a 5 kg box stacked on
the one below, every joint held by a motor-style position controller (the
"L2.5" high-stiffness position drive). This experiment asks two everyday
questions about stacking such joints:

1. **Does droop add up?** A position-driven joint sags a little under the
   weight it holds, like a spring stretching (`sag = weight * g / stiffness`).
   In a stack the bottom joint holds the most (all three sections, 15 kg) so it
   sags most; measured 30 mm bottom, 20 mm middle, 10 mm top. The crucial part:
   the TIP of the lift droops by the SUM of all three (about 60 mm), because
   each section sits on an already-drooping one. So a multi-joint lift's tip
   error is the total of every joint's droop, not just the worst one. To make
   the tip precise you must stiffen every joint, the bottom one most of all.
2. **Do joints shove each other?** Moving one joint jolts the neighbours by up
   to 39 mm DURING the move, but they snap back to within 0.02 mm once things
   settle. So joints disturb each other only momentarily; they do not push each
   other permanently off target (unless you need a joint to stay precise WHILE
   another moves -- then that 39 mm transient is what matters).

The 15 kg here is just this toy's total weight, NOT a limit -- heavier loads
sag more, higher stiffness sags less; it is a precision-vs-stiffness trade-off,
not a weight ceiling.

Note on levels (ADR-0021 D1a): the "L2.5" drive tested here and the compliant
"L3" drive are the SAME mechanism -- an articulation joint plus a position
controller -- differing ONLY in stiffness (gain). Both obey `sag = mg/k`, so
BOTH accumulate error down a chain exactly as measured here; L2.5 merely has
smaller per-joint droop because its gain is higher. The error accumulation is a
property of the shared drive architecture, not something unique to L3. Neither
ever becomes true-L2: true-L2 is a kinematic body that PhysX teleports to its
target ignoring forces (no drive, no stiffness, no sag) -- a categorically
different mechanism kept on a standalone body outside the articulation
(ADR-0021 D2).

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

Measured on the self-hosted GPU runner (marker lines from one runner
invocation; the 4-test suite passed on the same build).

Raw markers:

```
[CHAIN SUMMARY] stiffness_usd=5000 masses=5,5,5 target=0 \
  restings=-0.0303362,-0.0201502,-0.00980831 \
  sags=0.0303362,0.0201502,0.00980831 tip_error=0.0602947 \
  per_joint_pred=0.02943,0.01962,0.00981 sag_predicted_sum=0.05886
[COUPLING SUMMARY] step_target=0.5 j0_final=0.469613 \
  holds=-0.0201502,-0.00980831 peak_dev=0.039228,0.0197862 \
  residual=1.86134e-05,4.81866e-06 max_peak_dev=0.039228 max_residual=1.86134e-05
```

### Sag accumulation (k = 5000 N/m, 5 kg links, hold target 0.0 m)

| joint | borne mass (kg) | predicted `mg/k` (m) | measured sag (m) | measured / predicted |
|---|---|---|---|---|
| `lift0` (base) | 15 | 0.029430 | 0.030336 | 1.031 |
| `lift1` (mid)  | 10 | 0.019620 | 0.020150 | 1.027 |
| `lift2` (tip)  |  5 | 0.009810 | 0.009808 | 1.000 |
| **tip total**  | -- | **0.058860** | **0.060295** | **1.024** |

- Measured tip error `0.060295 m` vs summed prediction `0.058860 m` -- the tip
  error is the SUM of the local sags to within +2.4 %. Errors ACCUMULATE
  additively down the chain: base 30.3 mm + mid 20.2 mm + tip 9.8 mm = tip
  60.3 mm.
- Ordering base > mid > tip confirmed (30.3 > 20.2 > 9.8 mm): the base-most
  joint, bearing all three links (15 kg), dominates.
- The small +2.4 % excess over the point-mass `mg/k` line is expected -- each
  joint bears slightly more than an idealized point load (link geometry /
  distributed mass), so the linear model is a near-exact, mildly conservative
  predictor here, not the loose upper bound EXP-184 saw at very high stiffness.

### Cross-joint disturbance (step joint 0 -> 0.5 m, hold joints 1 and 2)

| held joint | peak transient deviation (m) | residual steady-state deviation (m) |
|---|---|---|
| `lift1` | 0.039228 (39.2 mm) | 1.86e-05 (0.019 mm) |
| `lift2` | 0.019786 (19.8 mm) | 4.82e-06 (0.005 mm) |
| **max** | 0.039228 (39.2 mm) | 1.86e-05 (0.019 mm) |

- Joint 0 reached 0.469613 m of the 0.5 m target (its own ~30 mm drive droop
  under the same k, consistent with the sag result).
- Residual is ~2000x smaller than the peak (0.019 mm vs 39.2 mm): the held
  joints are jolted up to 39 mm DURING joint 0's move but settle back to within
  0.02 mm -- the coupling is a transient, not a persistent offset.

## Findings (relation to ADR-0021)

- **Drive error COMPOUNDS additively down a chain (CONFIRMED).** Measured tip
  error `60.3 mm` = the sum of per-joint sags (`58.9 mm` predicted, +2.4 %).
  The L2.5 position-drive error is ADDITIVE down a serial chain -- a 3-joint
  lift accumulates roughly the sum of its per-joint droops, and the base-most
  joint dominates because it bears the most mass. Practical consequence: to hit
  a target TIP precision on a multi-joint lift you must budget stiffness across
  ALL joints (weighted by borne load), not just stiffen one; the base joint is
  where stiffness buys the most. This is the multi-joint generalization of
  EXP-184's single-joint `sag = mg/k`.

- **Cross-joint coupling is BOUNDED and transient (CONFIRMED).** A step-move of
  joint 0 disturbs the held joints by up to 39 mm during the transient (real
  reaction / inertial coupling through the PhysX articulation solver) but they
  settle back to a 0.019 mm residual -- ~2000x smaller than the peak. The
  articulation solver leaves NO permanent offset on held joints under
  neighbouring motion, so each joint's steady-state error can be treated as
  independent once motion settles (the multi-joint analogue of the #193 hold /
  #180 tracking results). Caveat: the ~39 mm transient is NOT negligible for a
  robot that moves joints simultaneously under a precision constraint -- if
  joints must stay on target WHILE others move, the transient (not the
  residual) is the number that matters, and coordinated control or motion
  sequencing would be needed.

- **Relation to the L2/L2.5/L3 continuum (ADR-0021 D1a).** This chain is a
  pure L2.5 (high-stiffness position-drive) probe. It does NOT revisit the
  true-L2 (standalone kinematic body) path -- articulation links cannot be
  kinematic (ADR-0021 D2), and a serial chain is necessarily an articulation.
  The experiment characterizes how the L2.5 approximation behaves when
  composed in series, which the single-DOF experiments could not show.

## Provenance

- Date: 2026-07-01
- Runner: self-hosted GPU (Isaac Sim devel-test image)
- Test: `test/integration/pytest/test_multijoint_coupling.py` (4 passed)
- Runner script: `test/integration/pytest/_multijoint_runner.py`
- Fixture: `test/fixtures/urdf/multi_joint_chain.urdf` (synthetic, NOT the
  real forklift)
- CI run: GitHub Actions run 28506899623 (`python-tests` GPU job, pass); the
  recorded marker numbers were captured from a direct runner invocation on the
  same self-hosted GPU box with identical arguments.
