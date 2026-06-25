# EXP-180: L3 joint-drive tracking precision (isolated, no contact)

Physics milestone "L3 control verification" (#180 / sub-issues #181 tracking
error / #182 steady-state / #183 repeatability), ADR-0021 D1.

This file is the durable RECORD of the measured results. The committed test
(`test/integration/pytest/test_l3_tracking.py`) is the REPRODUCTION harness:
re-running it on a GPU box regenerates the numbers below for re-verification.

## Question

What is an articulation (L3) joint drive's INTRINSIC tracking precision -- in
ISOLATION, with one actuated joint, NO contact and NO external payload? This is
the isolated-precision counterpart to the #184 droop-under-load experiment
(`test_l3_drive_sag.py`), which characterizes the same drive's steady-state
error UNDER a 10 kg payload (the `m*g/stiffness` sag). Here the moving link is
light and unloaded, so what remains is the drive's own ability to:

1. follow a smooth commanded trajectory (tracking error, #181),
2. hold a commanded position at rest (steady-state error, #182),
3. land at the same place run-to-run (repeatability, #183).

## Setup

- Fixture: `test/fixtures/urdf/single_joint_lift.urdf` -- a fixed base + ONE
  prismatic Z lift joint + a light **1 kg** moving link (primitive boxes, no
  external mesh, NO payload). Imported `fix_base=True` so the base is anchored
  and the joint holds the link against gravity.
- Drive: import-time `joint_drive` (`UrdfConverterCfg.joint_drive`) at
  stiffness **5000 N/m** with **critical damping `2*sqrt(k*m)` = ~141.4** so
  the position drive settles (the steady-state position is
  damping-independent; damping only governs the transient -- a zero/underdamped
  drive oscillates forever and corrupts the reading). A PRISMATIC (linear)
  joint stores stiffness in N/m, NOT scaled by `pi/180` (that is angular-only).
- Step target: commanded joint position **0.5 m** (#182).
- Trajectory (#181): a SMOOTH cosine-eased path through the waypoints
  `0.0 -> 0.3 -> 0.6 -> 0.3 -> -0.2 -> 0.0` m (zero velocity at each waypoint,
  no command step), 60 ticks per segment; commanded vs measured DOF recorded
  EACH step; the metrics are max and RMS of `|commanded - measured|`.
- Repeatability (#183): the whole step + trajectory is run **3** times, the
  DOF reset to home (0.0 m, settled) between cycles; the spread (max - min) of
  the per-cycle settled step position is the run-to-run determinism witness.
- Stepping: `dynamic_control` + `omni.timeline` + `app.update()` (the proven
  example / L2-stability path), **not** a `SimulationContext` (the #151
  shutdown-hang surface). 30 init ticks, 400 settle ticks per step.
- Steady-state floor: at rest the position drive balances gravity, so the
  error magnitude floor is `|deviation| = m*g / stiffness = 1*9.81/5000 =
  ~1.96 mm` (the light link, no payload). The asserted bands sit comfortably
  above this floor (settling + numerical slack) while still being "small".

## Reproduction

On a GPU host with the Isaac Sim / Isaac Lab devel-test image:

```bash
./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
    test/integration/pytest/test_l3_tracking.py -v
```

Or a single run by hand:

```bash
/isaac-sim/python.sh test/integration/pytest/_l3_tracking_runner.py \
    --repo-root "$(pwd)" --out /tmp/lift.usd \
    --stiffness 5000 --damping 141.42 --step-target 0.5 --reset-cycles 3
# -> [TRACKING SUMMARY] ... step_ss_err=... traj_max_err=... \
#      traj_rms_err=... repeat_spread=... cycles=3 npoints=6
```

## Results (stiffness 5000 N/m, 1 kg link, no payload, target 0.5 m)

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: CI run
<RUN_ID> (the recording run), 2026-06-25.

| metric | value | band asserted |
|---|---|---|
| steady-state floor `m*g/k` | 1.962 mm (analytic) | -- |
| step steady-state error (#182) | <SS_ERR> | < 10 mm AND <= 4x floor |
| trajectory max error (#181)    | <TRAJ_MAX> | < 80 mm |
| trajectory RMS error (#181)    | <TRAJ_RMS> | < 40 mm, <= max |
| repeatability spread (#183)    | <REPEAT_SPREAD> | < 1 mm |

<!-- FILL after the green CI run: replace the <...> placeholders with the
     parsed [TRACKING SUMMARY] numbers and the CI run id. -->

## Findings

<!-- FILL after the green CI run, mirroring exp-184's findings prose:
  - steady-state error sits near the m*g/stiffness floor (the unloaded drive
    holds tightly),
  - the smooth-trajectory tracking error is small (the critically-damped drive
    lags a smooth command only slightly),
  - repeatability is sub-mm / deterministic (PhysX position control is
    reproducible across resets).
  - contrast with #184: there the error is dominated by the 10 kg payload
    sag; here, unloaded, the same drive tracks to the link's own light floor.
-->

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l3_tracking.py`
- Runner script: `test/integration/pytest/_l3_tracking_runner.py`
- Fixture: `test/fixtures/urdf/single_joint_lift.urdf`
- CI run: <RUN_ID> (recording run; the table above is its measured output)
