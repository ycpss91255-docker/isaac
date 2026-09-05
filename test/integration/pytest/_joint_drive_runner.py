"""Kit-side runner: configure a joint drive at import and at runtime, then
report the joint prim's DriveAPI gains (#168, ADR-0020 decision 3).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177) and converts the two-link
revolute fixture under that same live Kit, so the produced stage can be
opened (and, in runtime-apply mode, modified) with the USD plugins loaded.
Two modes (one ``SimulationApp`` per process -- it is a process-global
singleton):

  ``--mode import-drive``  converts with an import-time
    ``UrdfConverterCfg.joint_drive`` (stiffness/damping forwarded to
    ``model_import._convert_urdf``), then reports the revolute joint's
    ``UsdPhysics.DriveAPI("angular")`` stiffness/damping.

  ``--mode runtime-apply``  converts with NO drive, then calls the runtime
    helper ``model_import.apply_joint_drive`` (Isaac Lab's
    ``modify_joint_drive_properties``, stage-only -- no Articulation, no
    SimulationContext) on the imported joint prim, and reports the DriveAPI
    gains the helper wrote.

Either way the assertion is STRUCTURAL: the DriveAPI is present on the joint
with the configured gains. "The joint physically reaches / holds a commanded
target" needs stepped physics (a ``SimulationContext``, deferred #151) and is
NOT exercised here.

Marker line::

    [DRIVE SUMMARY] mode=<mode> joint=<path> has_drive=<bool> \
        stiffness=<f> damping=<f>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _joint_drive_runner.py \\
        --repo-root <repo> --mode import-drive --out /tmp/arm.usd \\
        --stiffness 800 --damping 40
"""

import argparse
import sys
from pathlib import Path


def _find_revolute_joint(stage):
    """Return the path of the first revolute joint prim, or None."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.RevoluteJoint):
            return str(prim.GetPath())
    # Fallback: a prim whose type name carries "Revolute" (importer naming).
    for prim in stage.Traverse():
        if "Revolute" in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _read_angular_drive(stage, joint_path):
    """Read (has_drive, stiffness, damping) from a joint's angular DriveAPI."""
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI(prim, "angular")
    if not drive:
        return (False, float("nan"), float("nan"))
    stiffness_attr = drive.GetStiffnessAttr()
    damping_attr = drive.GetDampingAttr()
    stiffness = stiffness_attr.Get() if stiffness_attr else None
    damping = damping_attr.Get() if damping_attr else None
    return (
        True,
        float(stiffness) if stiffness is not None else float("nan"),
        float(damping) if damping is not None else float("nan"),
    )


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument(
        "--mode", required=True,
        choices=("import-drive", "runtime-apply"),
    )
    parser.add_argument("--out", required=True)
    parser.add_argument("--stiffness", type=float, default=800.0)
    parser.add_argument("--damping", type=float, default=40.0)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = (
        repo_root / "test" / "fixtures" / "urdf" / "two_link_revolute.urdf"
    )
    out_usd = Path(args.out).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaac_devkit import model_import

    # One live Kit for convert + inspect (+ runtime-apply). The #177
    # experience pin loads the 2.4.31 importer; model_import keeps its Isaac
    # imports function-local, so we own the SimulationApp here.
    from isaacsim import SimulationApp

    app = SimulationApp(model_import._simulation_app_kwargs())
    try:
        from pxr import Usd

        if args.mode == "import-drive":
            produced = model_import._convert_urdf(
                urdf,
                out_usd,
                fix_base=True,
                merge_fixed_joints=True,
                joint_drive_stiffness=args.stiffness,
                joint_drive_damping=args.damping,
            )
        else:
            produced = model_import._convert_urdf(
                urdf, out_usd, fix_base=True, merge_fixed_joints=True
            )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        stage = Usd.Stage.Open(str(produced))
        joint_path = _find_revolute_joint(stage)
        if joint_path is None:
            raise RuntimeError("no revolute joint prim in produced USD")

        if args.mode == "runtime-apply":
            # Stage-only per-joint drive application (no SimulationContext).
            # apply_joint_drive resolves the current stage via Isaac Lab's
            # modify_joint_drive_properties; make the produced stage current.
            import omni.usd

            omni.usd.get_context().open_stage(str(produced))
            applied = model_import.apply_joint_drive(
                joint_path, args.stiffness, args.damping
            )
            if not applied:
                raise RuntimeError(
                    f"apply_joint_drive returned falsy for {joint_path}"
                )
            stage = omni.usd.get_context().get_stage()

        has_drive, stiffness, damping = _read_angular_drive(stage, joint_path)
        print(
            f"[DRIVE SUMMARY] mode={args.mode} joint={joint_path} "
            f"has_drive={has_drive} stiffness={stiffness:g} "
            f"damping={damping:g}",
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
