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
`<RUN_ID>`, commit `<COMMIT>`, 2026-06-25.

| stiffness (N/m) | predicted `m*g/k` (m) | measured deviation (m) | drift (m) | settled |
|---|---|---|---|---|
| 5 000   | 0.01962  | _pending_ | _pending_ | _pending_ |
| 25 000  | 0.003924 | _pending_ | _pending_ | _pending_ |
| 100 000 | 0.000981 | _pending_ | _pending_ | _pending_ |
| 1 000 000 | 0.0000981 | _pending_ | _pending_ | _pending_ |

Anchor points already observed during bring-up (earlier runs): k=5000 ->
deviation ~0.0188-0.0196 m (matches prediction within ~4%); k=200 (L3
reference, not in the sweep) -> deviation ~0.49 m (matches `98.1/200`).

## Findings

- _To be finalized from the sweep table above._ Expected per PhysX 5.4 and the
  bring-up data: the error tracks `m*g/stiffness` across the whole sweep with
  no early precision floor, and the implicit drive stays settled (small drift)
  even at very high gain -- i.e. **Isaac's L2.5 precision is bounded by the
  stiffness you can stably apply, not by an intrinsic floor**, and sub-mm
  steady-state error is reachable at high stiffness.
- True-L2 (a standalone kinematic body) remains the only path to a HARD
  zero-error guarantee (articulation links cannot be kinematic, ADR-0021 D2);
  this experiment characterizes how close the L2.5 approximation gets.

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l3_drive_sag.py` (`test_l25_precision_limit_sweep`)
- Runner script: `test/integration/pytest/_sag_runner.py`
- CI run: `<RUN_ID>` (filled on the recording commit)
