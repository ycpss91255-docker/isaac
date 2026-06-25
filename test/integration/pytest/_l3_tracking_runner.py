"""Kit-side runner: measure a position-driven prismatic joint's INTRINSIC
tracking precision in isolation -- one actuated joint, NO contact, NO external
payload (Physics milestone "L3 control verification", issue #180 / sub-issues
#181 tracking error / #182 steady-state / #183 repeatability).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177), converts the synthetic
``single_joint_lift.urdf`` fixture under that same live Kit with an import-time
position drive at ``--stiffness``/``--damping``, then STEPS physics:

  1. open the produced USD into the Kit context,
  2. ensure a gravity physics scene exists,
  3. play the timeline + ``app.update()`` to init PhysX,
  4. resolve the articulation + its single prismatic DOF (dynamic_control,
     the proven stepped-physics read path from
     ``test_openbase_l2_stability.py`` / ``_sag_runner.py``),
  5. command a STEP to ``--step-target`` and let it settle (steady-state /
     #182),
  6. command a SMOOTH multi-point trajectory (a cosine ease between
     waypoints), recording commanded vs measured DOF EACH step (tracking
     error / #181),
  7. repeat the whole step+trajectory ``--reset-cycles`` times, resetting the
     DOF to home between cycles, to measure run-to-run repeatability (#183).

The drive is given CRITICAL damping ``2*sqrt(k*m)`` by the caller so a
position drive settles (a zero/underdamped drive oscillates forever). For a
PRISMATIC (linear) joint the gain is stored as-is (NOT scaled by pi/180 --
that is angular-only). The light, payload-free moving link means the
steady-state error is the drive's own ``m*g/stiffness`` floor (here m is just
the link mass), so tracking is tight and the metrics are small + deterministic.

This DOES step physics. It uses the dynamic_control + ``omni.timeline`` +
``app.update()`` loop (the example/L2 path), NOT a ``SimulationContext``
(deferred #151, shutdown hang). ``app.close()`` in the finally is the same
teardown the L2 stability test uses.

Marker line::

    [TRACKING SUMMARY] stiffness=<f> link_mass=<f> step_target=<f> \
        step_ss_err=<f> traj_max_err=<f> traj_rms_err=<f> \
        repeat_spread=<f> cycles=<n> npoints=<n>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _l3_tracking_runner.py --repo-root <repo> \\
        --out /tmp/lift.usd --stiffness 5000 --damping 141.4 \\
        --step-target 0.5 --reset-cycles 3
"""

import argparse
import math
import sys
from pathlib import Path

# Moving-link mass declared in the fixture
# (test/fixtures/urdf/single_joint_lift.urdf).
LINK_MASS_KG = 1.0
GRAVITY = 9.81
# Ticks to let PhysX init after play and to settle a step.
INIT_TICKS = 30
SETTLE_TICKS = 400
# Smooth multi-point trajectory: each segment between consecutive waypoints is
# resolved into SEGMENT_SAMPLES commanded micro-points (a cosine ease), and the
# command is held for TICKS_PER_SAMPLE physics ticks before the error is read.
# The point of a TRACKING test is to command a path SLOW ENOUGH that a
# well-tuned drive can follow it: a single tick per sample saturates the drive
# bandwidth (the measured lag at a sharp reversal is then a full segment, which
# measures bandwidth, not tracking). Holding each micro-point for several ticks
# makes the commanded slew rate small relative to the drive's settling, so the
# residual |commanded - measured| is the genuine tracking error.
SEGMENT_SAMPLES = 40
TICKS_PER_SAMPLE = 12
# Home position the DOF is reset to between repeatability cycles.
HOME = 0.0
# Smooth multi-point trajectory waypoints (the commanded path); a cosine ease
# is applied BETWEEN consecutive points so the command is smooth, not a stair.
TRAJ_WAYPOINTS = (0.0, 0.3, 0.6, 0.3, -0.2, 0.0)


def _wait_opened(ctx, app):
    """Pump app.update() until the stage reports OPENED (or give up)."""
    import omni.usd

    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            return True
        app.update()
    return False


def _ensure_gravity(stage):
    """Ensure a UsdPhysics.Scene with downward gravity exists on the stage."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.Scene):
            return str(prim.GetPath())
    scene = UsdPhysics.Scene.Define(stage, "/physicsScene")
    scene.CreateGravityDirectionAttr().Set((0.0, 0.0, -1.0))
    scene.CreateGravityMagnitudeAttr().Set(GRAVITY)
    return "/physicsScene"


def _candidate_articulation_paths(stage):
    """Ordered, de-duped candidate prim paths for dc.get_articulation.

    dc.get_articulation wants the articulation ROOT prim, not the joint that
    happens to carry ArticulationRootAPI (a fix_base UrdfConverter puts the
    API on a fixed ``root_joint``, which dc cannot resolve). Try the stage
    defaultPrim (the robot root) first, then any ArticulationRootAPI prim,
    then the rigid-body links -- the first that yields a valid handle wins.
    """
    from pxr import UsdPhysics

    paths = []
    dp = stage.GetDefaultPrim()
    if dp and dp.IsValid():
        paths.append(str(dp.GetPath()))
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            paths.append(str(prim.GetPath()))
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.RigidBodyAPI):
            paths.append(str(prim.GetPath()))
    return list(dict.fromkeys(paths))


def _cosine_ease(a, b, frac):
    """Smooth ease from a to b at fraction ``frac`` in [0, 1] (cosine S-curve;
    zero velocity at both endpoints so the commanded path has no step)."""
    smooth = 0.5 - 0.5 * math.cos(math.pi * max(0.0, min(1.0, frac)))
    return a + (b - a) * smooth


def _drive_to(iface, dof, app, target, ticks):
    """Command a position target and step ``ticks``; return the measured DOF."""
    iface.set_dof_position_target(dof, float(target))
    for _ in range(ticks):
        app.update()
    return float(iface.get_dof_position(dof))


def _run_trajectory(iface, dof, app):
    """Command the smooth multi-point trajectory, recording commanded vs
    measured each step. Returns (max_abs_err, rms_err, final_measured)."""
    errs = []
    measured = HOME
    for i in range(len(TRAJ_WAYPOINTS) - 1):
        a = TRAJ_WAYPOINTS[i]
        b = TRAJ_WAYPOINTS[i + 1]
        for s in range(1, SEGMENT_SAMPLES + 1):
            cmd = _cosine_ease(a, b, s / SEGMENT_SAMPLES)
            iface.set_dof_position_target(dof, float(cmd))
            # Hold each commanded micro-point for several ticks so the slew
            # rate stays within the drive's bandwidth; read the tracking error
            # at the END of the hold (the residual lag, not the single-tick
            # transient).
            for _ in range(TICKS_PER_SAMPLE):
                app.update()
            measured = float(iface.get_dof_position(dof))
            errs.append(abs(measured - cmd))
    max_err = max(errs) if errs else float("nan")
    rms_err = math.sqrt(sum(e * e for e in errs) / len(errs)) if errs else float(
        "nan"
    )
    return max_err, rms_err, measured


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stiffness", type=float, required=True)
    parser.add_argument("--damping", type=float, default=0.0)
    parser.add_argument("--step-target", type=float, default=0.5)
    parser.add_argument("--reset-cycles", type=int, default=3)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = repo_root / "test" / "fixtures" / "urdf" / "single_joint_lift.urdf"
    out_usd = Path(args.out).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaac_devkit import model_import
    from isaacsim import SimulationApp

    app = SimulationApp(model_import._simulation_app_kwargs())
    try:
        import omni.timeline
        import omni.usd
        from pxr import UsdPhysics  # noqa: F401  (plugin load)

        produced = model_import._convert_urdf(
            urdf,
            out_usd,
            fix_base=True,
            merge_fixed_joints=True,
            joint_drive_stiffness=args.stiffness,
            joint_drive_damping=args.damping,
        )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        ctx = omni.usd.get_context()
        if not ctx.open_stage(str(produced)):
            raise RuntimeError(f"open_stage False for {produced}")
        if not _wait_opened(ctx, app):
            raise RuntimeError("stage did not reach OPENED")
        stage = ctx.get_stage()

        _ensure_gravity(stage)
        candidates = _candidate_articulation_paths(stage)

        timeline = omni.timeline.get_timeline_interface()
        timeline.play()
        for _ in range(INIT_TICKS):
            app.update()

        import omni.isaac.dynamic_control._dynamic_control as dc

        iface = dc.acquire_dynamic_control_interface()
        art = dc.INVALID_HANDLE
        root_path = None
        for cand in candidates:
            handle = iface.get_articulation(cand)
            if handle != dc.INVALID_HANDLE:
                art, root_path = handle, cand
                break
        if art == dc.INVALID_HANDLE:
            raise RuntimeError(
                f"dc.get_articulation failed for all candidates: {candidates}"
            )
        print(f"[ARTICULATION] root={root_path}", flush=True)
        iface.wake_up_articulation(art)
        ndof = iface.get_articulation_dof_count(art)
        if ndof < 1:
            raise RuntimeError(f"articulation has {ndof} DOFs, expected >= 1")
        dof = iface.get_articulation_dof(art, 0)

        # Repeatability cycles (#183): each cycle resets to HOME, then runs the
        # SAME step + trajectory. The spread of the per-cycle step settled
        # position is the run-to-run determinism witness.
        cycles = max(1, args.reset_cycles)
        step_settled = []
        traj_max_errs = []
        traj_rms_errs = []
        for _c in range(cycles):
            # Reset to home and let it settle so each cycle starts identically.
            _drive_to(iface, dof, app, HOME, SETTLE_TICKS)
            # Step (#182 steady-state): command the step target, settle, read.
            settled = _drive_to(iface, dof, app, args.step_target, SETTLE_TICKS)
            step_settled.append(settled)
            # Smooth multi-point trajectory (#181 tracking error).
            max_err, rms_err, _final = _run_trajectory(iface, dof, app)
            traj_max_errs.append(max_err)
            traj_rms_errs.append(rms_err)

        # Steady-state error at rest = |target - settled| (averaged over
        # cycles; they should be near-identical).
        step_ss_err = sum(
            abs(args.step_target - s) for s in step_settled
        ) / len(step_settled)
        # Tracking error over the trajectory: worst max + worst RMS across
        # cycles (conservative).
        traj_max_err = max(traj_max_errs)
        traj_rms_err = max(traj_rms_errs)
        # Repeatability spread: max - min of the per-cycle step settled
        # positions (how far apart identical commands land run-to-run).
        repeat_spread = (
            max(step_settled) - min(step_settled) if len(step_settled) > 1
            else 0.0
        )

        print(
            f"[TRACKING SUMMARY] stiffness={args.stiffness:g} "
            f"link_mass={LINK_MASS_KG:g} step_target={args.step_target:g} "
            f"step_ss_err={step_ss_err:g} traj_max_err={traj_max_err:g} "
            f"traj_rms_err={traj_rms_err:g} repeat_spread={repeat_spread:g} "
            f"cycles={cycles} npoints={len(TRAJ_WAYPOINTS)}",
            flush=True,
        )
        print("[EXIT CLEAN]", flush=True)
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        raise
    finally:
        app.close()


if __name__ == "__main__":
    _main()
