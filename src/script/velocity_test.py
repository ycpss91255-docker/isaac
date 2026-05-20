#!/usr/bin/env python3
"""Velocity drive test for the imported OpenBase USD.

Loads the USD, adds a ground plane + sunlight, switches the 3 rim joints from
position to velocity drive, then steps the simulation while streaming over
WebRTC. Connect with Isaac Sim WebRTC Streaming Client (no port suffix) to
watch.

Run inside the Isaac Sim 5.1 container, after stopping the existing
``runheadless.sh`` session (otherwise port 49100/8011 collide):

    /isaac-sim/python.sh velocity_test.py \\
        /home/yunchien/work/src/OpenBase/openbase.usda

Pass ``--no-fix-base`` only if the USD itself was imported with the root link
free (so the base can translate). With the default fixed-base USD the wheels
spin in place; that is expected.
"""

import argparse
import sys

WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("usd", help="USD file to load (inside container).")
    parser.add_argument(
        "--vel", type=float, default=5.0, help="Wheel velocity target rad/s."
    )
    parser.add_argument(
        "--steps", type=int, default=400, help="Simulation steps to run."
    )
    parser.add_argument(
        "--report-every", type=int, default=20, help="Print every N steps."
    )
    parser.add_argument(
        "--no-livestream",
        action="store_true",
        help="Run truly headless (no WebRTC). Default streams over WebRTC.",
    )
    args = parser.parse_args()

    from isaacsim import SimulationApp

    config = {"headless": True}
    if not args.no_livestream:
        config["livestream"] = 2
    app = SimulationApp(config)

    import omni.kit.commands
    import omni.timeline
    import omni.usd
    from omni.isaac.dynamic_control import _dynamic_control as dc
    from pxr import UsdLux, UsdPhysics

    ctx = omni.usd.get_context()
    if not ctx.open_stage(args.usd):
        print(f"Failed to open {args.usd}", file=sys.stderr)
        app.close()
        return 1
    stage = ctx.get_stage()

    omni.kit.commands.execute(
        "CreateMeshPrimWithDefaultXform",
        prim_type="Plane",
        prim_path="/World/GroundPlane",
    )
    ground = stage.GetPrimAtPath("/World/GroundPlane")
    ground.GetAttribute("xformOp:scale").Set((100, 100, 1))
    UsdPhysics.CollisionAPI.Apply(ground)
    UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(
        3000.0
    )

    name_to_path = {p.GetName(): p.GetPath() for p in stage.Traverse()}
    for wheel in WHEELS:
        prim = stage.GetPrimAtPath(name_to_path[wheel])
        drive = UsdPhysics.DriveAPI.Get(prim, "angular")
        drive.GetStiffnessAttr().Set(0.0)
        drive.GetDampingAttr().Set(1000.0)

    omni.timeline.get_timeline_interface().play()
    app.update()

    iface = dc.acquire_dynamic_control_interface()
    art = iface.get_articulation("/open_base/origin_link")
    if art == dc.INVALID_HANDLE:
        art = iface.get_articulation("/open_base/base_link")
    if art == dc.INVALID_HANDLE:
        print("No articulation found", file=sys.stderr)
        app.close()
        return 1
    iface.wake_up_articulation(art)

    dofs = {w: iface.find_articulation_dof(art, w) for w in WHEELS}
    for w, d in dofs.items():
        iface.set_dof_velocity_target(d, args.vel)
    print(f"target vel = {args.vel} rad/s on {WHEELS}")

    for i in range(args.steps):
        app.update()
        if i % args.report_every == 0:
            row = "  ".join(
                f"{w}={iface.get_dof_velocity(d):+.2f}" for w, d in dofs.items()
            )
            print(f"[step {i:>4}] {row}")

    app.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
