#!/usr/bin/env python3
"""Drive the imported OpenBase robot forward (long-running, WebRTC stream).

All three rim joints are switched to velocity drive and held at the same
target so they spin in the same direction. Loops forever and prints the base
pose + linear velocity every N steps so you can confirm whether the chassis
is actually translating; Ctrl+C to exit.

Run inside Isaac Sim 5.1 container, after stopping any other ``runheadless.sh``
(port 8011 / 49100 collision otherwise):

    /isaac-sim/python.sh drive_openbase.py \\
        /home/yunchien/work/src/OpenBase/openbase.usda

Connect with Isaac Sim WebRTC Streaming Client (no port suffix) to watch.

Note: the chassis only translates when the USD was imported with
``--no-fix-base``. With the default fixed-base USD wheels spin in place and
``base=`` X/Y stay constant — that is the diagnostic for whether you need to
re-import. Re-import command::

    /isaac-sim/python.sh import_urdf.py <urdf> <out.usda> --no-fix-base
"""

import argparse
import signal
import sys

WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")


def emit(msg: str) -> None:
    print(msg, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("usd", help="USD file (inside container).")
    parser.add_argument(
        "--vel",
        type=float,
        default=5.0,
        help="Wheel angular velocity rad/s; positive = same direction on all 3.",
    )
    parser.add_argument(
        "--report-every", type=int, default=60, help="Print pose every N steps."
    )
    parser.add_argument(
        "--no-livestream",
        action="store_true",
        help="Truly headless; default hosts WebRTC server.",
    )
    args = parser.parse_args()

    from isaacsim import SimulationApp

    sim_cfg = {"headless": True}
    if not args.no_livestream:
        sim_cfg["livestream"] = 2
    app = SimulationApp(sim_cfg)

    import omni.timeline
    import omni.usd
    from omni.isaac.dynamic_control import _dynamic_control as dc
    from pxr import UsdLux, UsdPhysics

    ctx = omni.usd.get_context()
    if not ctx.open_stage(args.usd):
        emit(f"[err] open failed: {args.usd}")
        app.close()
        return 1
    stage = ctx.get_stage()

    if not stage.GetPrimAtPath("/World/SunLight").IsValid():
        UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(
            3000.0
        )
        emit("[scene] sunlight added")

    for prim in stage.Traverse():
        if prim.GetName() in WHEELS:
            drive = UsdPhysics.DriveAPI.Get(prim, "angular")
            drive.GetStiffnessAttr().Set(0.0)
            drive.GetDampingAttr().Set(1000.0)
            emit(f"[drive] {prim.GetName()}: velocity mode")

    omni.timeline.get_timeline_interface().play()
    app.update()

    iface = dc.acquire_dynamic_control_interface()
    art = iface.get_articulation("/open_base/origin_link")
    if art == dc.INVALID_HANDLE:
        art = iface.get_articulation("/open_base/base_link")
    if art == dc.INVALID_HANDLE:
        emit("[err] articulation not found")
        app.close()
        return 1
    iface.wake_up_articulation(art)

    dofs = {w: iface.find_articulation_dof(art, w) for w in WHEELS}
    base_handle = iface.get_rigid_body("/open_base/base_link")

    emit(f"[drive] target vel = {args.vel} rad/s on {WHEELS}")
    emit("[loop] running; Ctrl+C to stop")

    stop = {"flag": False}

    def _on_signal(*_args: object) -> None:
        stop["flag"] = True

    signal.signal(signal.SIGINT, _on_signal)
    signal.signal(signal.SIGTERM, _on_signal)

    step = 0
    while not stop["flag"]:
        for d in dofs.values():
            iface.set_dof_velocity_target(d, args.vel)
        app.update()

        if step % args.report_every == 0:
            wheel_vel = "  ".join(
                f"{w[:5]}={iface.get_dof_velocity(d):+.2f}" for w, d in dofs.items()
            )
            if base_handle != dc.INVALID_HANDLE:
                pose = iface.get_rigid_body_pose(base_handle)
                lin = iface.get_rigid_body_linear_velocity(base_handle)
                emit(
                    f"[step {step:>5}] base=({pose.p[0]:+.3f},{pose.p[1]:+.3f},{pose.p[2]:+.3f}) "
                    f"vel=({lin[0]:+.3f},{lin[1]:+.3f},{lin[2]:+.3f})  {wheel_vel}"
                )
            else:
                emit(f"[step {step:>5}] {wheel_vel}")
        step += 1

    emit("[exit] stopping timeline")
    omni.timeline.get_timeline_interface().stop()
    app.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
