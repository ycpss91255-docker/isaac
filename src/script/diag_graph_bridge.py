"""Diagnostic: SimulationApp + open USD + ROS2SubscribeTwist via OmniGraph,
NO Python `import rclpy`. Validates whether bridge-via-graph avoids the
crash combo we found in cmd_vel_planar_standalone.py.

Bisection so far:
  USD only (diag_usd_loop)    OK 90s
  USD + dc (move_openbase)     OK 90s
  USD + dc + rclpy (cmd_vel)   crash ~+2s after bridge ext
  USD + graph (this)           ?

Run:
    ./exec.sh -t standalone /isaac-sim/python.sh \\
        /home/yunchien/work/src/script/diag_graph_bridge.py
"""

import os
import signal
import sys

from isaacsim import SimulationApp

APP = SimulationApp({"headless": True, "renderer": "RaytracedLighting"})

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[diag] SIGINT/SIGTERM", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# Enable bridge extension (loads ros2 libs into kit) WITHOUT importing
# rclpy in Python — this is the key bisection point.
from isaacsim.core.utils.extensions import enable_extension  # noqa: E402
enable_extension("isaacsim.ros2.bridge")

import omni.graph.core as og  # noqa: E402
import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402

USD_PATH = "/home/yunchien/work/src/model/usd/robot/openbase/openbase.usda"


def main():
    if not os.path.exists(USD_PATH):
        raise FileNotFoundError(USD_PATH)
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        raise RuntimeError(f"open_stage False: {USD_PATH}")
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        APP.update()
    else:
        raise RuntimeError("stage never OPENED")
    print(f"[diag] stage opened: {USD_PATH}", flush=True)

    # Add minimal graph: OnPlaybackTick -> ROS2SubscribeTwist
    # Goal here is just to validate bridge-via-graph path stays alive;
    # we don't wire outputs yet. If this 90s survives, real cmd_vel
    # setup_cmd_vel_graph.py is safe to author.
    graph_path = "/World/CmdVelGraph"
    og.Controller.edit(
        {"graph_path": graph_path, "evaluator_name": "execution"},
        {
            og.Controller.Keys.CREATE_NODES: [
                ("OnTick", "omni.graph.action.OnPlaybackTick"),
                ("SubTwist", "isaacsim.ros2.bridge.ROS2SubscribeTwist"),
            ],
            og.Controller.Keys.SET_VALUES: [
                ("SubTwist.inputs:topicName", "/cmd_vel"),
            ],
            og.Controller.Keys.CONNECT: [
                ("OnTick.outputs:tick", "SubTwist.inputs:execIn"),
            ],
        },
    )
    print("[diag] graph built: OnPlaybackTick -> ROS2SubscribeTwist", flush=True)

    omni.timeline.get_timeline_interface().play()
    print("[diag] timeline playing; entering update loop", flush=True)

    step = 0
    try:
        while APP.is_running() and not _SHOULD_QUIT:
            APP.update()
            step += 1
            if step % 60 == 0:
                print(f"[diag] tick {step}", flush=True)
    except KeyboardInterrupt:
        print("[diag] KeyboardInterrupt", flush=True)
    finally:
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
