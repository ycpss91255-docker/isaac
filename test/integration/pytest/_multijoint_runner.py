"""Kit-side runner: measure multi-joint coupling in a serial position-drive
chain (Physics milestone, issue #226; ADR-0021).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177), converts the synthetic
``multi_joint_chain.urdf`` fixture under that same live Kit with an
import-time position drive at ``--stiffness``/``--damping`` applied to every
prismatic joint, then STEPS physics (``omni.timeline.play()`` +
``app.update()``, dynamic_control -- NOT a ``SimulationContext``, #151) to
take two sub-measurements against the same live articulation:

  1. SAG ACCUMULATION -- command every joint to hold at ``--sag-target``, let
     the chain settle under gravity, and read each joint's resting position.
     The per-joint droop  sag_j = |target - resting_j|  should match the
     single-joint prediction  (mass above j) * g / k  (linear/prismatic
     drive, no pi/180), and the chain-TIP total error is the SUM of the three
     local sags.

  2. CROSS-JOINT DISTURBANCE -- record the held equilibrium of joints 1 and
     2, then STEP-move joint 0 to ``--step-target`` while joints 1 and 2 keep
     their hold targets. Track the PEAK deviation of the held joints during
     the transient, then settle and read the RESIDUAL steady-state deviation.
     A bounded coupling shows a transient peak that decays back (small
     residual); a permanent offset would leave a large residual.

Joints are addressed by NAME (``lift0`` base-most .. ``lift2`` tip-most) via
``dc.find_articulation_dof`` so the base->tip ordering is deterministic
regardless of the articulation's internal DOF index order; a positional
fallback is used only if the named lookup fails.

Marker lines::

    [CHAIN SUMMARY] stiffness_usd=<k> masses=<m0,m1,m2> target=<t> \
        restings=<r0,r1,r2> sags=<s0,s1,s2> tip_error=<sum|s|> \
        per_joint_pred=<p0,p1,p2> sag_predicted_sum=<sum p>
    [COUPLING SUMMARY] step_target=<st> j0_final=<f> holds=<h1,h2> \
        peak_dev=<pd1,pd2> residual=<rr1,rr2> max_peak_dev=<f> \
        max_residual=<f>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _multijoint_runner.py --repo-root <repo> \\
        --out /tmp/multi_joint_chain.usd --stiffness 5000 --damping 547.7 \\
        --sag-target 0.0 --step-target 0.5
"""

import argparse
import sys
from pathlib import Path

# Link masses declared in test/fixtures/urdf/multi_joint_chain.urdf, base to
# tip. Base-most joint lift0 bears m0+m1+m2; lift1 bears m1+m2; lift2 bears m2.
LINK_MASSES = (5.0, 5.0, 5.0)
GRAVITY = 9.81
# Joint names in the fixture, base-most first.
JOINT_NAMES = ("lift0", "lift1", "lift2")
# Ticks to let PhysX init after play, to settle the sag, to watch the
# transient after the step, and to settle the post-step steady state.
INIT_TICKS = 30
SETTLE_TICKS = 600
TRANSIENT_TICKS = 400
POST_SETTLE_TICKS = 700


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
    fixed ``root_joint``, which dc cannot resolve). Try the stage defaultPrim
    (the robot root) first, then any ArticulationRootAPI prim, then the
    rigid-body links -- the first that yields a valid handle wins.
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
    """Read a prismatic joint's linear DriveAPI stiffness, or nan.

    Every joint gets the same import-time drive, so the first prismatic
    joint's stiffness is representative of the whole chain.
    """
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


def _resolve_chain_dofs(iface, art, dc):
    """Return the chain DOF handles ordered base->tip (lift0, lift1, lift2).

    Address joints by NAME via find_articulation_dof for a deterministic
    ordering; fall back to positional DOF order only if a named lookup fails
    (the articulation's DOF index order then has to be trusted).
    """
    invalid = getattr(dc, "INVALID_DOF_HANDLE", dc.INVALID_HANDLE)
    dofs = []
    for name in JOINT_NAMES:
        handle = iface.find_articulation_dof(art, name)
        if not handle or handle == invalid:
            dofs = []
            break
        dofs.append(handle)
    if dofs:
        return dofs, "by_name"
    # Positional fallback: trust the DOF index order (base->tip).
    ndof = iface.get_articulation_dof_count(art)
    if ndof < len(JOINT_NAMES):
        raise RuntimeError(
            f"articulation has {ndof} DOFs, expected >= {len(JOINT_NAMES)}"
        )
    return [iface.get_articulation_dof(art, i) for i in range(len(JOINT_NAMES))], (
        "by_index"
    )


def _predicted_sags(stiffness):
    """Single-joint mg/k prediction per joint, base->tip.

    lift0 bears every link above it, lift1 bears all but the first, etc.
    """
    preds = []
    for j in range(len(LINK_MASSES)):
        borne = sum(LINK_MASSES[j:])
        preds.append(borne * GRAVITY / stiffness if stiffness else float("nan"))
    return preds


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stiffness", type=float, required=True)
    parser.add_argument("--damping", type=float, default=0.0)
    parser.add_argument("--sag-target", type=float, default=0.0)
    parser.add_argument("--step-target", type=float, default=0.5)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = repo_root / "test" / "fixtures" / "urdf" / "multi_joint_chain.urdf"
    out_usd = Path(args.out).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaac_devkit import model_import
    from isaacsim import SimulationApp

    def _livestream_kwargs():
        """SimulationApp kwargs honoring ISAAC_LIVESTREAM so the scene is
        stream-viewable (mirrors framework parse_livestream_env): unset/"0"
        -> headless; "1"/"2" -> livestream. CI leaves it unset -> headless."""
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
    # scene honors ISAAC_LIVESTREAM. CI leaves it unset -> headless boot.
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
        iface.wake_up_articulation(art)
        dofs, dof_source = _resolve_chain_dofs(iface, art, dc)
        print(f"[ARTICULATION] root={root_path} dof_source={dof_source}",
              flush=True)

        # --- sub-measurement 1: sag accumulation -------------------------
        # Command every joint to hold, settle under gravity, read restings.
        for dof in dofs:
            iface.set_dof_position_target(dof, float(args.sag_target))
        for _ in range(SETTLE_TICKS):
            app.update()
        restings = [float(iface.get_dof_position(dof)) for dof in dofs]
        sags = [abs(float(args.sag_target) - r) for r in restings]
        tip_error = sum(sags)
        preds = _predicted_sags(
            stiffness_usd if stiffness_usd == stiffness_usd else args.stiffness
        )
        pred_sum = sum(preds)
        print(
            "[CHAIN SUMMARY] "
            f"stiffness_usd={stiffness_usd:g} "
            f"masses={','.join(f'{m:g}' for m in LINK_MASSES)} "
            f"target={args.sag_target:g} "
            f"restings={','.join(f'{r:g}' for r in restings)} "
            f"sags={','.join(f'{s:g}' for s in sags)} "
            f"tip_error={tip_error:g} "
            f"per_joint_pred={','.join(f'{p:g}' for p in preds)} "
            f"sag_predicted_sum={pred_sum:g}",
            flush=True,
        )

        # --- sub-measurement 2: cross-joint disturbance ------------------
        # Held joints 1 and 2 keep their (already-settled) hold; step-move
        # joint 0 and watch the held joints' peak deviation, then settle and
        # read the residual.
        held = dofs[1:]
        holds = [float(iface.get_dof_position(dof)) for dof in held]
        iface.set_dof_position_target(dofs[0], float(args.step_target))
        peak_dev = [0.0 for _ in held]
        for _ in range(TRANSIENT_TICKS):
            app.update()
            for i, dof in enumerate(held):
                dev = abs(float(iface.get_dof_position(dof)) - holds[i])
                if dev > peak_dev[i]:
                    peak_dev[i] = dev
        for _ in range(POST_SETTLE_TICKS):
            app.update()
        residual = [
            abs(float(iface.get_dof_position(dof)) - holds[i])
            for i, dof in enumerate(held)
        ]
        j0_final = float(iface.get_dof_position(dofs[0]))
        print(
            "[COUPLING SUMMARY] "
            f"step_target={args.step_target:g} "
            f"j0_final={j0_final:g} "
            f"holds={','.join(f'{h:g}' for h in holds)} "
            f"peak_dev={','.join(f'{p:g}' for p in peak_dev)} "
            f"residual={','.join(f'{r:g}' for r in residual)} "
            f"max_peak_dev={max(peak_dev):g} "
            f"max_residual={max(residual):g}",
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
