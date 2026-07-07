"""Kit-side runner: measure a position-driven prismatic joint's L3 drive
LIMITATIONS -- effort saturation and joint-limit clamp (Physics milestone
"L3 control verification", issue #188).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177), converts the synthetic
``lift_capped.urdf`` fixture (a fixed base + one prismatic Z lift + a 5 kg
payload, joint ``<limit effort="30" lower="0" upper="1">``) under that same
live Kit with an import-time joint drive, then STEPS physics (the proven
``_sag_runner.py`` / ``test_openbase_l2_stability.py`` stepped path:
dynamic_control + ``omni.timeline`` + ``app.update()``, NOT a
``SimulationContext`` -- the #151 hang surface).

Two limitation modes, selected by ``--mode``:

  * ``saturate`` -- drive HIGH stiffness UP to ``--target`` (above the
    travel) with the DOF effort cap at ``--effort`` (default 30 N, BELOW the
    payload weight m*g = 49 N). The drive saturates: it cannot output enough
    force to hold the weight, so the payload sits FAR below the target. Then
    the runner RAISES the effort cap (``--effort-raised``, default 500 N,
    above m*g) via ``dc.set_dof_properties`` and re-settles -- now the same
    high-stiffness command reaches the target. The CONTRAST (huge gap when
    capped, small gap when uncapped, SAME stiffness) is the saturation proof.

  * ``clamp`` -- with the effort cap RAISED above m*g (so the drive can move
    freely), command the joint WAY past its ``upper`` mechanical limit
    (``--target`` 5.0 m vs upper 1.0 m). The joint clamps at the limit; the
    resting position lands at ~upper, NOT at the commanded target.

The DOF effort cap is overridden at runtime with ``dc.set_dof_properties``
(its ``max_effort`` field) rather than regenerating the URDF -- cleaner and
keeps a single import per run. The joint travel limits (lower/upper) are read
off the prim's ``UsdPhysics.PrismaticJoint`` for the clamp reference.

Marker lines::

    [LIMITS SUMMARY] mode=saturate mass=<f> weight_n=<f> effort_cap=<f> \
        effort_raised=<f> target=<f> resting_capped=<f> resting_uncapped=<f> \
        gap_capped=<f> gap_uncapped=<f> drift=<f>
    [LIMITS SUMMARY] mode=clamp mass=<f> weight_n=<f> effort_cap=<f> \
        target=<f> upper_limit=<f> lower_limit=<f> resting=<f> \
        clamp_overshoot=<f> drift=<f>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _l3_limits_runner.py --repo-root <repo> \\
        --out /tmp/lift_capped.usd --mode saturate --stiffness 50000 \\
        --target 0.8 --effort 30 --effort-raised 500
"""

import argparse
import sys
from pathlib import Path

# Payload mass declared in the fixture (test/fixtures/urdf/lift_capped.urdf).
PAYLOAD_MASS_KG = 5.0
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
    carries ArticulationRootAPI (a fix_base UrdfConverter puts the API on a
    fixed ``root_joint`` dc cannot resolve). Try the stage defaultPrim first,
    then any ArticulationRootAPI prim, then the rigid-body links -- the first
    that yields a valid handle wins.
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


def _read_prismatic_limits(stage):
    """Read the prismatic joint's (lower, upper) travel limits, or (nan, nan)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.PrismaticJoint) or "Prismatic" in str(
            prim.GetTypeName()
        ):
            joint = UsdPhysics.PrismaticJoint(prim)
            lo = joint.GetLowerLimitAttr().Get() if joint else None
            hi = joint.GetUpperLimitAttr().Get() if joint else None
            if lo is not None and hi is not None:
                return float(lo), float(hi)
    return float("nan"), float("nan")


def _resolve_dof(app):
    """Resolve the single articulation DOF via dynamic_control."""
    import omni.usd

    import omni.isaac.dynamic_control._dynamic_control as dc

    stage = omni.usd.get_context().get_stage()
    candidates = _candidate_articulation_paths(stage)
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
    return iface, art, iface.get_articulation_dof(art, 0)


def _set_effort_cap(iface, dof, effort_cap):
    """Override the DOF's max effort (force limit) at runtime.

    dc.set_dof_properties takes a DofProperties struct; only max_effort is
    changed (the URDF-imported value is otherwise preserved). This is how the
    experiment toggles the saturation regime without regenerating the URDF.
    """
    props = iface.get_dof_properties(dof)
    props.max_effort = float(effort_cap)
    iface.set_dof_properties(dof, props)


def _settle(iface, dof, target, app):
    """Command the DOF to target, settle, return (resting, drift)."""
    iface.set_dof_position_target(dof, float(target))
    for _ in range(SETTLE_TICKS):
        app.update()
    resting_early = float(iface.get_dof_position(dof))
    for _ in range(120):
        app.update()
    resting = float(iface.get_dof_position(dof))
    return resting, abs(resting - resting_early)


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument(
        "--mode", choices=("saturate", "clamp"), required=True
    )
    parser.add_argument("--stiffness", type=float, default=50000.0)
    parser.add_argument("--damping", type=float, default=0.0)
    parser.add_argument("--target", type=float, default=0.8)
    parser.add_argument("--effort", type=float, default=30.0)
    parser.add_argument("--effort-raised", type=float, default=500.0)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = repo_root / "test" / "fixtures" / "urdf" / "lift_capped.urdf"
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
        lower_limit, upper_limit = _read_prismatic_limits(stage)

        timeline = omni.timeline.get_timeline_interface()
        timeline.play()
        for _ in range(INIT_TICKS):
            app.update()

        iface, _art, dof = _resolve_dof(app)
        weight_n = PAYLOAD_MASS_KG * GRAVITY

        if args.mode == "saturate":
            # Capped: effort cap BELOW the payload weight -> drive saturates.
            _set_effort_cap(iface, dof, args.effort)
            resting_capped, drift_c = _settle(iface, dof, args.target, app)
            gap_capped = float(args.target) - resting_capped
            # Uncapped: raise the cap ABOVE the weight -> same command reaches.
            _set_effort_cap(iface, dof, args.effort_raised)
            resting_uncapped, drift_u = _settle(iface, dof, args.target, app)
            gap_uncapped = float(args.target) - resting_uncapped
            print(
                f"[LIMITS SUMMARY] mode=saturate mass={PAYLOAD_MASS_KG:g} "
                f"weight_n={weight_n:g} effort_cap={args.effort:g} "
                f"effort_raised={args.effort_raised:g} target={args.target:g} "
                f"resting_capped={resting_capped:g} "
                f"resting_uncapped={resting_uncapped:g} "
                f"gap_capped={gap_capped:g} gap_uncapped={gap_uncapped:g} "
                f"drift={max(drift_c, drift_u):g}",
                flush=True,
            )
        else:  # clamp
            # Raise the effort cap so the drive moves freely; the LIMIT, not
            # saturation, governs the resting position.
            _set_effort_cap(iface, dof, args.effort_raised)
            resting, drift = _settle(iface, dof, args.target, app)
            # Positive overshoot past the upper limit means it did NOT clamp.
            clamp_overshoot = resting - upper_limit
            print(
                f"[LIMITS SUMMARY] mode=clamp mass={PAYLOAD_MASS_KG:g} "
                f"weight_n={weight_n:g} effort_cap={args.effort_raised:g} "
                f"target={args.target:g} upper_limit={upper_limit:g} "
                f"lower_limit={lower_limit:g} resting={resting:g} "
                f"clamp_overshoot={clamp_overshoot:g} drift={drift:g}",
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
