"""Kit-side runner: measure a position-driven prismatic joint's steady-state
droop under a payload, at a given drive stiffness (Physics milestone "L3
control verification", issue #184 / sub-issue #185).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177), converts the synthetic
``lift_payload.urdf`` fixture under that same live Kit with an import-time
joint drive at ``--stiffness``/``--damping``, then -- unlike the structural
``_joint_drive_runner.py`` -- actually STEPS physics:

  1. open the produced USD into the Kit context,
  2. ensure a gravity physics scene exists,
  3. play the timeline + ``app.update()`` to init PhysX,
  4. command the prismatic DOF to ``--target`` (dynamic_control, the proven
     stepped-physics read path from ``test_openbase_l2_stability.py``),
  5. step to settle, read the DOF's resting position.

The droop  sag = target - resting  is the measurement. A high stiffness
(L2.5) holds near the target (tiny droop); a low stiffness (L3) sags. The
analytic prediction for a linear/prismatic drive is  sag ~ m*g / stiffness
(no pi/180 scaling -- that is angular-only), so the runner also reports the
stiffness actually stored on the joint's ``UsdPhysics.DriveAPI("linear")``
and the predicted droop from it.

This DOES step physics. It uses the dynamic_control + ``omni.timeline`` +
``app.update()`` loop (the example/L2 path), NOT a ``SimulationContext``
(deferred #151, shutdown hang). ``app.close()`` in the finally is the same
teardown the L2 stability test uses.

Marker line::

    [SAG SUMMARY] stiffness_in=<f> stiffness_usd=<f> mass=<f> target=<f> \
        resting=<f> sag=<f> sag_predicted=<f>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _sag_runner.py --repo-root <repo> \\
        --out /tmp/lift.usd --stiffness 5000 --damping 200 --target 1.0
"""

import argparse
import sys
from pathlib import Path

# Payload mass declared in the fixture (test/fixtures/urdf/lift_payload.urdf).
PAYLOAD_MASS_KG = 10.0
GRAVITY = 9.81
# Ticks to let PhysX init after play, and to let the drive settle.
INIT_TICKS = 30
SETTLE_TICKS = 600


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


def _read_linear_drive_stiffness(stage):
    """Read the prismatic joint's linear DriveAPI stiffness, or nan."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.PrismaticJoint) or "Prismatic" in str(
            prim.GetTypeName()
        ):
            drive = UsdPhysics.DriveAPI(prim, "linear")
            if drive:
                attr = drive.GetStiffnessAttr()
                val = attr.Get() if attr else None
                if val is not None:
                    return float(val)
    return float("nan")


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stiffness", type=float, required=True)
    parser.add_argument("--damping", type=float, default=0.0)
    parser.add_argument("--target", type=float, default=1.0)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = repo_root / "test" / "fixtures" / "urdf" / "lift_payload.urdf"
    out_usd = Path(args.out).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaac_devkit import model_import
    from isaacsim import SimulationApp

    def _livestream_kwargs():
        """SimulationApp kwargs honoring ISAAC_LIVESTREAM so the scene is
        stream-viewable (mirrors framework parse_livestream_env): unset/"0"
        -> headless; "1"/"2" -> livestream. CI leaves it unset -> headless,
        so this is behavior-identical to the previous hardcoded boot."""
        import os

        value = os.environ.get("ISAAC_LIVESTREAM")
        if not value or value == "0":
            return {"headless": True}
        kwargs = {"headless": False, "livestream": int(value)}
        if value == "2":
            kwargs["renderer"] = "RaytracedLighting"
        return kwargs

    # Merge livestream kwargs INTO the importer-experience-pinned kwargs
    # (#177) so the 2.4.31 URDF importer experience is preserved AND the
    # scene honors ISAAC_LIVESTREAM. CI leaves it unset -> headless boot with
    # the experience pin, behavior-identical to before.
    app_kwargs = model_import._simulation_app_kwargs()
    app_kwargs.update(_livestream_kwargs())
    app = SimulationApp(app_kwargs)
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
        stiffness_usd = _read_linear_drive_stiffness(stage)
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

        iface.set_dof_position_target(dof, float(args.target))
        for _ in range(SETTLE_TICKS):
            app.update()
        # Two reads 120 ticks apart: drift = |late - early| is the settling /
        # stability witness (a high-gain drive that destabilizes keeps moving;
        # a settled one barely drifts).
        resting_early = float(iface.get_dof_position(dof))
        for _ in range(120):
            app.update()
        resting = float(iface.get_dof_position(dof))
        drift = abs(resting - resting_early)
        sag = float(args.target) - resting
        sag_pred = (
            PAYLOAD_MASS_KG * GRAVITY / stiffness_usd
            if stiffness_usd and stiffness_usd == stiffness_usd
            else float("nan")
        )
        print(
            f"[SAG SUMMARY] stiffness_in={args.stiffness:g} "
            f"stiffness_usd={stiffness_usd:g} mass={PAYLOAD_MASS_KG:g} "
            f"target={args.target:g} resting={resting:g} sag={sag:g} "
            f"sag_predicted={sag_pred:g} drift={drift:g}",
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
