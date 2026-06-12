"""Kit-side runner for the camera -> ROS 2 headless smoke test (#127).

Not a pytest test (leading underscore so pytest skips collection).
Boots headless Isaac (no livestream -- bypasses IsaacSim#228), opens a
stub stage carrying custom.yaml's mount parent prim, builds the camera
publish chain via ``camera_setup.setup_camera`` (the `custom` dispatch:
local UsdGeom.Camera prims, no external assets), then subscribes
in-process (rclpy) to the color image topic and reports the first
received frame.

Prints canonical marker lines so the test layer can assert without
depending on the process exit code (Kit's ``app.close`` calls
``_exit(0)`` on the way out and swallows ``sys.exit``):

    [KIT LOG] path=...            Kit log file (CUDA/Vulkan init lines)
    [CUDA OK] devices=N           libcuda cuInit + device count
    [BOOT OK]                     SimulationApp + stage open completed
    [CAMERA GRAPH OK] graph=...   setup_camera built the OmniGraph chain
    [CAMERA FRAME OK] topic=... frame_id=... width=... height=... count=N
    [CAMERA FRAME MISSING] ...    budget exhausted without a frame
    [EXIT CLEAN]                  lifecycle completed without raising
    [RAISED] ...                  exception escaped the lifecycle

CLI:

    /isaac-sim/python.sh _camera_headless_runner.py \\
        --script-dir <repo>/src/script \\
        --camera-yaml <repo>/src/config/camera/custom.yaml \\
        --usd-path <absolute path to the stub .usda fixture>
"""

import argparse
import ctypes
import os
import sys
from pathlib import Path

# Ticks of app.update() to wait for the first frame after the graph is
# built. The render product + SDG pipeline warms up within a few dozen
# ticks once shaders are compiled; the budget covers first-run shader
# compilation stalls as well.
_FRAME_BUDGET_TICKS = 1800


def _cuda_device_count() -> int:
    """Functional CUDA probe via the driver API (no torch dependency)."""
    cuda = ctypes.CDLL("libcuda.so.1")
    rc = cuda.cuInit(0)
    if rc != 0:
        raise RuntimeError(f"cuInit failed: rc={rc}")
    count = ctypes.c_int(0)
    rc = cuda.cuDeviceGetCount(ctypes.byref(count))
    if rc != 0:
        raise RuntimeError(f"cuDeviceGetCount failed: rc={rc}")
    return count.value


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--camera-yaml", required=True)
    parser.add_argument("--usd-path", required=True)
    args = parser.parse_args()

    # Headless, no livestream: ROS2 bridge + livestream in one Kit
    # process segfaults randomly (IsaacSim#228). Forced here so the
    # smoke result does not depend on inherited container env.
    os.environ["ISAAC_LIVESTREAM"] = "0"

    # Self-resolve the sibling framework from the repo root so
    # ``import isaac_devkit`` (which isaac_driver re-exports from) works
    # regardless of the container mount layout. The base env_8 sets
    # PYTHONPATH=~/work/framework, but that does not resolve when the repo
    # is mounted as a NESTED worktree (its framework/ is not at
    # ~/work/framework) -- isaac#134. ``--script-dir`` is <repo>/src/script,
    # so its parents[1] is the repo root; mirror the #132 example runner's
    # self-resolution. The driver path stays first on sys.path.
    script_dir = Path(args.script_dir).resolve()
    framework_dir = script_dir.parents[1] / "framework"
    if framework_dir.is_dir() and str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))
    sys.path.insert(0, str(script_dir))

    try:
        from isaac_driver import IsaacDriver  # noqa: E402

        usd_path = args.usd_path
        camera_yaml = args.camera_yaml

        class _CameraSmokeDriver(IsaacDriver):
            USD = usd_path

            def setup(self, stage) -> None:
                import carb.settings

                log_path = carb.settings.get_settings().get("/log/file")
                print(f"[KIT LOG] path={log_path}", flush=True)
                print(f"[CUDA OK] devices={_cuda_device_count()}", flush=True)
                print("[BOOT OK]", flush=True)

                # Camera publish chain via the custom.yaml path. This
                # also enables the isaacsim.ros2.bridge extension, which
                # puts Isaac's bundled rclpy on the python path.
                from camera_setup import load_config, setup_camera

                cfg = load_config(camera_yaml)
                graph_path = setup_camera(cfg, stage)
                print(f"[CAMERA GRAPH OK] graph={graph_path}", flush=True)

                self._topic = (
                    cfg["ros"]["topic_prefix"].rstrip("/")
                    + "/color/image_raw"
                )
                self._frames = 0
                self._first_frame = None

                self.init_rclpy()
                import rclpy
                from rclpy.qos import (
                    HistoryPolicy,
                    QoSProfile,
                    ReliabilityPolicy,
                )
                from sensor_msgs.msg import Image

                self._node = rclpy.create_node("camera_headless_smoke_probe")

                def _on_image(msg) -> None:
                    self._frames += 1
                    if self._first_frame is None:
                        self._first_frame = (
                            msg.header.frame_id, msg.width, msg.height,
                        )

                # BEST_EFFORT matches either publisher reliability
                # (a reliable publisher still delivers to a best-effort
                # subscriber; the reverse pairing would not).
                self._sub = self._node.create_subscription(
                    Image,
                    self._topic,
                    _on_image,
                    QoSProfile(
                        depth=1,
                        history=HistoryPolicy.KEEP_LAST,
                        reliability=ReliabilityPolicy.BEST_EFFORT,
                    ),
                )

            def main(self) -> None:
                import rclpy

                ticks = 0
                while (
                    not self._should_quit
                    and self._app.is_running()
                    and ticks < _FRAME_BUDGET_TICKS
                ):
                    self._app.update()
                    rclpy.spin_once(self._node, timeout_sec=0.0)
                    ticks += 1
                    if self._frames >= 1:
                        break

                if self._first_frame is not None:
                    frame_id, width, height = self._first_frame
                    print(
                        f"[CAMERA FRAME OK] topic={self._topic} "
                        f"frame_id={frame_id} width={width} "
                        f"height={height} count={self._frames}",
                        flush=True,
                    )
                else:
                    print(
                        f"[CAMERA FRAME MISSING] waited_ticks={ticks}",
                        flush=True,
                    )

            def shutdown(self) -> None:
                try:
                    if getattr(self, "_node", None) is not None:
                        self._node.destroy_node()
                    import rclpy

                    rclpy.try_shutdown()
                finally:
                    print("[EXIT CLEAN]", flush=True)

        _CameraSmokeDriver().run()
    except Exception as exc:  # noqa: BLE001
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        raise


if __name__ == "__main__":
    _main()
