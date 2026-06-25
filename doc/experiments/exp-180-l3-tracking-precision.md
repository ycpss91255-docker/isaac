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

Measured on the self-hosted GPU runner (RTX 5090 reference). Source: green CI
run 28168300524 (the recording run; the identical numbers were surfaced into
the log by the temporary-assert run 28169534455 on the same commit-equivalent
paced runner), 2026-06-25.

| metric | value | band asserted |
|---|---|---|
| steady-state floor `m*g/k` | 1.962 mm (analytic) | -- |
| step steady-state error (#182) | 1.757 mm (0.00175706 m) | < 10 mm AND <= 4x floor |
| trajectory max error (#181)    | 4.600 mm (0.0046001 m)  | < 80 mm |
| trajectory RMS error (#181)    | 1.783 mm (0.00178267 m) | < 40 mm, <= max |
| repeatability spread (#183)    | 0 um (0 m)              | < 1 mm |

(Note: an earlier failing iteration -- before the trajectory was paced within
the drive bandwidth -- measured `traj_max_err = 498 mm` at the same stiffness.
That number was a single-tick BANDWIDTH-saturation artifact: the runner then
commanded ONE physics tick per trajectory sample, so the worst instantaneous
lag at a sharp waypoint reversal was a full segment. Holding each commanded
micro-point for several ticks -- i.e. commanding the path within the drive's
bandwidth -- collapses the peak to 4.6 mm, which is the genuine tracking error.
The honest RMS even of the unpaced run was already only 56.7 mm.)

## Findings

- **Steady-state error sits right at the analytic floor.** The rest error
  after a step is 1.757 mm, essentially the `m*g/stiffness = 1.962 mm` floor
  for the light 1 kg link (no payload). The unloaded L2.5 drive holds the
  commanded position to ~1.8 mm at stiffness 5000 -- confirming ADR-0021 D1's
  picture that the steady-state error is load/stiffness, here dominated by the
  link's own weight.
- **Trajectory tracking is tight when the command is within the drive
  bandwidth.** Over the smooth cosine-eased multi-waypoint path, the max
  `|commanded - measured|` is 4.6 mm and the RMS is 1.78 mm -- both of the
  order of the steady-state floor. A critically-damped position drive follows a
  smooth, properly-paced command with only millimetre-scale lag. (The earlier
  498 mm peak was a pacing artifact, not a tracking limit -- see the note
  above.)
- **Repeatability is exact to the measurement floor.** Commanding the same
  step after a reset-to-home lands the joint at the SAME settled position
  across all 3 cycles -- the spread is 0 um. PhysX position control is
  deterministic; there is no run-to-run drift.
- **Contrast with #184 (droop under load).** There the steady-state error is
  dominated by a 10 kg payload sag (~19 mm at this same stiffness 5000);
  HERE, unloaded, the same drive tracks to the link's own light ~1.8 mm floor.
  The two experiments bound the L2.5 approximation from both sides: the error
  is `m*g/stiffness`, and `m` is whatever the joint actually carries.
- **Practical takeaway:** an isolated, contact-free articulation joint drive at
  a moderate stiffness tracks both a step and a smooth trajectory to a few
  millimetres and resets deterministically -- the drive's INTRINSIC precision
  is not the limiting factor; load and stiffness are (ADR-0021 D1).

## Provenance

- Date: 2026-06-25
- Runner: self-hosted GPU (RTX 5090 reference)
- Test: `test/integration/pytest/test_l3_tracking.py`
- Runner script: `test/integration/pytest/_l3_tracking_runner.py`
- Fixture: `test/fixtures/urdf/single_joint_lift.urdf`
- CI run: 28168300524 (green recording run; the table above is its measured
  output, surfaced into the log by the temporary-assert run 28169534455 on the
  same paced runner)
