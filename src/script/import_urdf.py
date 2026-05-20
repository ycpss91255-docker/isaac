#!/usr/bin/env python3
"""Import a URDF file into Isaac Sim and write it out as USD.

Run inside the Isaac Sim 5.1 container:

    /isaac-sim/python.sh import_urdf.py \\
        /home/yunchien/work/src/model/urdf/openbase/openbase_minimal.urdf \\
        /tmp/openbase_generated.usda

Note: the curated ``model/usd/openbase/openbase.usda`` is already tracked in
this repo, so most users do not need to regenerate. Use this script when you
want to (re)convert a URDF — e.g. you added a new robot under
``model/urdf/<robot>/`` and need its initial USD. Output to ``/tmp`` (or
another non-tracked path) to avoid clobbering the in-repo USDs.

``package://<pkg>/...`` mesh URIs are resolved relative to the URDF file's
parent directory (so ``package://open_base/mesh/base.stl`` becomes
``<urdf_dir>/../mesh/base.stl``). The ``model/urdf/openbase/`` layout
already matches this convention.
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("urdf", help="Path to URDF file (inside container).")
    parser.add_argument("output", help="Output USD path; prefer .usda for diff.")
    parser.add_argument(
        "--no-fix-base",
        action="store_true",
        help="Allow root link to free-fall (default: fix to world).",
    )
    parser.add_argument(
        "--no-merge-fixed",
        action="store_true",
        help="Keep fixed-joint links separate (default: merge into rigid body).",
    )
    args = parser.parse_args()

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    import omni.kit.commands
    from isaacsim.asset.importer.urdf import _urdf as urdf_loader

    config = urdf_loader.ImportConfig()
    config.merge_fixed_joints = not args.no_merge_fixed
    config.fix_base = not args.no_fix_base
    config.import_inertia_tensor = True
    config.distance_scale = 1.0
    config.density = 0.0
    config.default_drive_strength = 1e7
    config.default_position_drive_damping = 1e5

    status, robot = omni.kit.commands.execute(
        "URDFParseFile", urdf_path=args.urdf, import_config=config
    )
    if not status:
        print(f"URDF parse failed: {args.urdf}", file=sys.stderr)
        app.close()
        return 1

    status, stage_path = omni.kit.commands.execute(
        "URDFImportRobot",
        urdf_path=args.urdf,
        urdf_robot=robot,
        dest_path=args.output,
        import_config=config,
    )
    if not status:
        print("URDF import failed", file=sys.stderr)
        app.close()
        return 1

    print(f"OK: {args.urdf} -> {args.output} (stage_path={stage_path})")
    app.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
