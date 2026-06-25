# EXP-184: L3 drive precision / L2.5 limit (drive droop under load)

Physics milestone "L3 control verification" (#184 / sub-issue #185), ADR-0021 D1.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l3_drive_sag.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## Question

Not "is it good enough for CoreSAM" -- this records **Isaac's own limit**: how
small does a position drive's steady-state error get as stiffness rises, and
does the implicit articulation drive stay stable at very high gain? (PhysX 5.4
claims the implicit drive "can handle very large gains without instability".)

## Setup

- Fixture: `test/fixtures/urdf/lift_payload.urdf` -- a fixed base + ONE
  prismatic Z lift joint + a **10 kg** payload link (primitive boxes, no
  external mesh). Imported `fix_base=True` so the base is anchored and the
  joint holds the payload against gravity.
- Drive: import-time `joint_drive` (`UrdfConverterCfg.joint_drive`) at the
  swept stiffness; **critical damping `2*sqrt(k*m)`** per point so the drive
  settles (the steady-state position is damping-independent; damping only
  governs the transient -- a zero/underdamped drive oscillates forever and
  corrupts the reading).
- Target: commanded joint position **1.0 m**.
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), **not** a `SimulationContext` (the #151
  shutdown-hang surface). 30 init ticks, 600 settle ticks, then two reads 120
  ticks apart (`drift` = settling/stability witness).
- Steady-state model: at equilibrium the drive force balances gravity, so the
  position error magnitude is `|deviation| = m*g / stiffness` (a linear /
  prismatic drive stores stiffness in N/m, NOT scaled by pi/180 -- that
  scaling is angular-only). `m*g = 10 * 9.81 = 98.1 N`.
- The measured deviation can settle slightly PAST the target (the converted
  prismatic axis may point -Z) -- a USD axis-convention artifact; what is
  recorded is the sign-independent magnitude `|target - resting|`.

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_l3_drive_sag.py -v
```

Or a single sweep point by hand:

```bash
/isaac-sim/python.sh test/integration/pytest/_sag_runner.py \
    --repo-root "$(pwd)" --out /tmp/lift.usd \
    --stiffness 25000 --damping 1000 --target 1.0
# -> [SAG SUMMARY] ... resting=... sag=... sag_predicted=... drift=...
```

## Results (L2.5 stiffness sweep, 10 kg payload, target 1.0 m)

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: CI run
28161075519 (the recording run), 2026-06-25.

| stiffness (N/m) | predicted `m*g/k` (m) | measured deviation (m) | drift (m) | settled |
|---|---|---|---|---|
| 5 000     | 0.01962   | 0.0193987  (19.4 mm)   | 0 | yes |
| 25 000    | 0.003924  | 0.00371057 (3.71 mm)   | 0 | yes |
| 100 000   | 0.000981  | 0.000791013 (0.79 mm)  | 0 | yes |
| 1 000 000 | 0.0000981 | 0.0000180006 (0.018 mm = 18 um) | 0 | yes |

(L3 reference outside the sweep: k=200 -> deviation ~0.49 m, matches
`98.1/200` -- the compliant end of the same curve.)

## Findings

- **No instability at high gain.** Drift is **0 at every point up to 1e6**:
  the implicit articulation drive reaches a perfectly settled steady state
  even at extreme stiffness. PhysX 5.4's "can handle very large gains without
  instability" is confirmed empirically. (The ceiling was not reached at 1e6;
  it could go higher.)
- **No precision floor up to 1e6.** The error decreases monotonically
  19.4 mm -> 3.71 mm -> 0.79 mm -> 0.018 mm as stiffness rises; it keeps
  improving, it does not plateau.
- **The linear `m*g/stiffness` model is a conservative UPPER BOUND.** Up to
  ~1e5 the measured error tracks `m*g/k` within ~20%; at 1e6 the measured
  error (~18 um) is FAR BELOW the linear prediction (~98 um) -- the error
  drops faster than 1/k at high gain. The drive meets or beats the linear
  model everywhere.
- **Practical takeaway (Isaac limit):** the L2.5 steady-state error is bounded
  by the stiffness you choose, not by an intrinsic Isaac floor; **sub-mm is
  easy (>= 1e5) and ~tens of microns is reachable (1e6)**, all perfectly
  settled.
- True-L2 (a standalone kinematic body) remains the only path to a HARD
  zero-error guarantee (articulation links cannot be kinematic, ADR-0021 D2);
  this experiment shows the L2.5 approximation gets to the micron scale before
  that distinction matters.

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l3_drive_sag.py` (`test_l25_precision_limit_sweep`)
- Runner script: `test/integration/pytest/_sag_runner.py`
- CI run: 28161075519 (recording run; the table above is its measured output)
