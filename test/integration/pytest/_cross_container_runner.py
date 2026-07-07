"""Isaac-side runner for the cross-container round-trip test (isaac#132).

Not a pytest test (leading underscore so pytest skips collection). Boots
the #131 ``ExampleDriver`` headless (no livestream -- bypasses
IsaacSim#228) and holds the live scene open as the Isaac endpoint of an
Isaac<->ament cross-container ROS 2 round-trip (PRD Pre-Publish item 1):

* outbound (sim -> ament): the framework camera OmniGraph chain publishes
  ``/camera_bot/camera/color/image_raw`` continuously while this runner
  ticks, so a sibling ``ros:humble`` container's ``camera_subscriber``
  node receives real sim frames.
* inbound (ament -> sim): the framework ``/cmd_vel`` OmniGraph Subscribe
  chain (``RosIo``) receives a Twist published by the sibling container's
  ``cmd_vel_publisher`` node; ``io.latest('/cmd_vel')`` echoes it, which
  this runner asserts and reports.

Unlike ``_example_headless_runner.py`` (which publishes ``/cmd_vel`` from
an in-process rclpy node to exercise the round-trip without a second
container), this runner publishes NOTHING on ``/cmd_vel``: every command
it observes must have crossed the container boundary from the sibling.

Marker lines (the host orchestrator / pytest layer assert on these)::

    [KIT LOG] path=...              Kit log file
    [CUDA OK] devices=N             libcuda cuInit + device count
    [BOOT OK]                       SimulationApp + scene built
    [CAMERA GRAPH OK] graph=...     camera OmniGraph publish chain built
    [XC READY] camera_topic=...     scene live; sibling may now connect
    [XC CMD_VEL RX] seq=N vx=.. vy=.. wz=..   sibling /cmd_vel received
    [XC CMD_VEL MISSING] ...        budget exhausted, no external /cmd_vel
    [EXIT CLEAN]                    lifecycle completed without raising
    [RAISED] ...                    exception escaped the lifecycle

CLI::

    /isaac-sim/python.sh _cross_container_runner.py \\
        --repo-root <repo> [--ready-hold-ticks N] [--cmd-vel-budget-ticks N]
"""

import argparse
import ctypes
import os
import sys
from pathlib import Path

# Default tick budgets. The runner keeps publishing the camera and
# polling for the external /cmd_vel for up to this many ticks after it
# announces readiness; the host orchestrator starts the sibling
# subscriber/publisher once it sees [XC READY]. Generous so a sibling
# container that is still pulling its image / sourcing the overlay has
# time to discover the participant and exchange messages.
_DEFAULT_READY_HOLD_TICKS = 60
_DEFAULT_CMD_VEL_BUDGET_TICKS = 3000
# After /cmd_vel is received, keep ticking (camera keeps publishing) so
# the sibling camera_subscriber -- which still has to colcon-build,
# discover the participant, and receive a frame -- gets its frame before
# this container is stopped. The host orchestrator stops this container as
# soon as the camera frame is harvested, so this budget only bounds an
# unattended run; it must comfortably exceed the host's full camera-window
# budget, including the bounded relaunch retry (isaac#224:
# CAMERA_MAX_ATTEMPTS x SIBLING_TIMEOUT_SEC), so the publisher is still
# live when a relaunched sibling discovers it.
_DEFAULT_LINGER_TICKS = 20000

_CMD_VEL_TOPIC = "/cmd_vel"


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
    parser.add_argument("--repo-root", required=True)
    parser.add_argument(
        "--ready-hold-ticks", type=int, default=_DEFAULT_READY_HOLD_TICKS
    )
    parser.add_argument(
        "--cmd-vel-budget-ticks",
        type=int,
        default=_DEFAULT_CMD_VEL_BUDGET_TICKS,
    )
    parser.add_argument(
        "--linger-ticks", type=int, default=_DEFAULT_LINGER_TICKS
    )
    args = parser.parse_args()

    # Headless, no livestream: ROS 2 bridge + livestream in one Kit
    # process segfaults randomly (IsaacSim#228). Forced here so the
    # result does not depend on inherited container env.
    os.environ["ISAAC_LIVESTREAM"] = "0"

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))
    example_dir = repo_root / "example" / "sim"
    if str(example_dir) not in sys.path:
        sys.path.insert(0, str(example_dir))

    ready_hold_ticks = args.ready_hold_ticks
    cmd_vel_budget_ticks = args.cmd_vel_budget_ticks
    linger_ticks = args.linger_ticks

    try:
        from example_driver import (  # noqa: E402
            ExampleDriver,
            _CMD_VEL_TOPIC as DRIVER_CMD_VEL_TOPIC,
            cmd_vel_to_planar_velocity,
        )

        class _CrossContainerDriver(ExampleDriver):
            """Hold the live example scene as the Isaac round-trip endpoint."""

            def setup(self, stage) -> None:
                import carb.settings

                log_path = carb.settings.get_settings().get("/log/file")
                print(f"[KIT LOG] path={log_path}", flush=True)
                print(f"[CUDA OK] devices={_cuda_device_count()}", flush=True)
                self._stage = stage
                print("[BOOT OK]", flush=True)

            def main(self) -> None:
                # latest() must be None before any external publish.
                pre = self.io.latest(_CMD_VEL_TOPIC)
                if pre is None:
                    print("[ROS_IO NONE OK]", flush=True)
                else:
                    print(
                        f"[ROS_IO NONE FAIL] unexpected pre-publish msg={pre}",
                        flush=True,
                    )

                camera_topic = getattr(self, "_camera_topic", "")

                # Warm the render + bridge a few ticks so the camera
                # publisher is live, then announce readiness so the host
                # orchestrator can start the sibling container.
                for _ in range(ready_hold_ticks):
                    if self._should_quit or not self._app.is_running():
                        break
                    self._app.update()
                print(f"[XC READY] camera_topic={camera_topic}", flush=True)

                # Keep ticking (camera keeps publishing) and poll the
                # /cmd_vel OmniGraph Subscribe attribute for a Twist that
                # crossed the container boundary from the sibling node.
                echoed = None
                ticks = 0
                while (
                    not self._should_quit
                    and self._app.is_running()
                    and ticks < cmd_vel_budget_ticks
                ):
                    self._app.update()
                    ticks += 1
                    msg = self.io.latest(_CMD_VEL_TOPIC)
                    if msg is not None:
                        echoed = msg
                        break

                if echoed is not None:
                    vx, vy, wz = cmd_vel_to_planar_velocity(
                        echoed.fields.get("linear", ()),
                        echoed.fields.get("angular", ()),
                    )
                    print(
                        f"[XC CMD_VEL RX] seq={echoed.seq} "
                        f"vx={vx} vy={vy} wz={wz}",
                        flush=True,
                    )
                else:
                    print(
                        f"[XC CMD_VEL MISSING] waited_ticks={ticks}",
                        flush=True,
                    )

                # The inbound (/cmd_vel) direction resolves fast, but the
                # outbound (camera) direction needs the sibling
                # camera_subscriber to colcon-build + discover + receive a
                # frame. Keep ticking (so the camera OmniGraph chain keeps
                # publishing) until the host orchestrator stops this
                # container (_should_quit via SIGTERM) or the linger
                # budget lapses -- otherwise shutdown would stop publishing
                # before the sibling gets a frame (isaac#132).
                linger = 0
                while (
                    not self._should_quit
                    and self._app.is_running()
                    and linger < linger_ticks
                ):
                    self._app.update()
                    linger += 1

            def shutdown(self) -> None:
                print("[EXIT CLEAN]", flush=True)

        # Guard against the example renaming the cmd_vel topic.
        assert DRIVER_CMD_VEL_TOPIC == _CMD_VEL_TOPIC

        _CrossContainerDriver().run()
    except Exception as exc:  # noqa: BLE001
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        raise


if __name__ == "__main__":
    _main()
