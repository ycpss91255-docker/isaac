"""Kit-side runner for the OutputHub GPU delivery test (isaac#365).

Not a pytest test (leading underscore; same pattern as
``_camera_headless_runner.py``). Run with Isaac's python:

    /isaac-sim/python.sh _output_hub_runner.py \\
        --repo-root <repo> --robot-usd <official jetbot.usd>

Builds a ground + the official Jetbot, adds a camera and an IMU prim,
calls ``setup_output`` in python mode, registers one callback per kind,
steps the app and prints marker lines (Kit's ``app.close`` calls
``_exit(0)``, so the test asserts on markers, not the exit code):

    [HUB RGB] count=N dtype=... shape=...
    [HUB DEPTH] count=N dtype=... shape=...
    [HUB JOINT] count=N names=K
    [HUB IMU] count=N orientation_len=4
    [HUB EXIT CLEAN]
    [HUB RAISED] <exception>
"""

import argparse
import os
import sys
import time
from pathlib import Path

_ROBOT = "/World/Robot"
_CHASSIS = f"{_ROBOT}/chassis"
_CAMERA = f"{_CHASSIS}/HubCam"
_IMU = f"{_CHASSIS}/HubImu"
_WIDTH, _HEIGHT = 640, 480
_STEPS = 300


def _build_stage(robot_usd):
    import omni.usd
    from pxr import Gf, UsdGeom, UsdLux, UsdPhysics

    omni.usd.get_context().new_stage()
    stage = omni.usd.get_context().get_stage()
    UsdGeom.Xform.Define(stage, "/World")
    UsdPhysics.Scene.Define(stage, "/World/PhysicsScene")
    UsdLux.DistantLight.Define(stage, "/World/Sun").GetIntensityAttr().Set(
        3000.0
    )
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    xf = UsdGeom.Xformable(ground.GetPrim())
    xf.AddTranslateOp().Set(Gf.Vec3d(0, 0, -0.5))
    xf.AddScaleOp().Set(Gf.Vec3f(20, 20, 1))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())
    stage.DefinePrim(_ROBOT).GetReferences().AddReference(robot_usd)
    cam = UsdGeom.Camera.Define(stage, _CAMERA)
    UsdGeom.Xformable(cam.GetPrim()).AddTranslateOp().Set(
        Gf.Vec3d(0.0, 0.0, 0.5)
    )


def _main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--robot-usd", required=True)
    args = parser.parse_args()

    os.environ["ISAAC_LIVESTREAM"] = "0"
    os.environ["ISAAC_OUTPUT_MODE"] = "python"
    sys.path.insert(0, str(Path(args.repo_root).resolve() / "framework"))
    from isaac_devkit.output import (
        CameraOutput,
        ImuOutput,
        JointOutput,
        setup_output,
    )

    sys.argv = ["runner", "--enable", "isaacsim.core.nodes",
                "--enable", "isaacsim.sensors.experimental.physics"]
    from isaaclab.app import AppLauncher

    try:
        app = AppLauncher({"headless": True, "enable_cameras": True}).app
        import omni.timeline
        from isaacsim.sensors.experimental.physics import IMU

        _build_stage(args.robot_usd)
        for _ in range(10):
            app.update()
        IMU.create(_IMU)

        out = setup_output(
            cameras=[
                CameraOutput("hub_rgb", _CAMERA, _WIDTH, _HEIGHT),
                CameraOutput("hub_depth", _CAMERA, _WIDTH, _HEIGHT, True),
            ],
            joint=JointOutput(_CHASSIS),
            imu=ImuOutput("hub_imu", _IMU),
        )
        frames = {"rgb": [], "depth": [], "joint_state": [], "imu": []}
        for kind, bucket in frames.items():
            out.register(bucket.append, kinds=[kind])
        omni.timeline.get_timeline_interface().play()
        for _ in range(_STEPS):
            app.update()
            out.step(time.monotonic())

        for tag, kind in (("RGB", "rgb"), ("DEPTH", "depth")):
            got = frames[kind]
            if got:
                d = got[-1].data
                print(f"[HUB {tag}] count={len(got)} dtype={d.dtype} "
                      f"shape={'x'.join(map(str, d.shape))}", flush=True)
            else:
                print(f"[HUB {tag}] count=0", flush=True)
        joint = frames["joint_state"]
        names = len(joint[-1].data["names"]) if joint else 0
        print(f"[HUB JOINT] count={len(joint)} names={names}", flush=True)
        imu = frames["imu"]
        olen = len(imu[-1].data["orientation"]) if imu else 0
        print(f"[HUB IMU] count={len(imu)} orientation_len={olen}",
              flush=True)
        print("[HUB EXIT CLEAN]", flush=True)
        app.close()
    except Exception as exc:  # noqa: BLE001 -- surfaced as a marker
        import traceback

        traceback.print_exc()
        print(f"[HUB RAISED] {type(exc).__name__}: {exc}", flush=True)


if __name__ == "__main__":
    _main()
