"""OpenBase planar move at a fixed CMD_VX / CMD_VY / CMD_WZ -- standalone.

Same logic as the in-kit move_openbase_planar.py (Gazebo planar_move
equivalent: wheel physics is bypassed and the base_link linear / angular
velocity is overwritten every step), driven by SimulationApp + a main loop
instead of the Script Editor.

Isaac Sim 6.x removed omni.isaac.dynamic_control, which this script used
to drive the base; it now uses isaacsim.core.prims.SingleRigidPrim under
an isaacsim.core.api.World.

Usage (the container's working directory is the repo root, ~/work):

    just docker run -t headless -d
    just docker exec -t headless /isaac-sim/python.sh \\
        src/script/move_openbase_planar_standalone.py [--run-seconds N]

Change the target velocity by editing CMD_VX / CMD_VY / CMD_WZ (all 0.0
parks the base). Stop: SIGINT / SIGTERM to the Python process (README
"Stopping a standalone script") or --run-seconds N. Exit code 0 on a clean
stop, 1 on any error.

Notes:
    - gravity is disabled on base_link (planar_move semantics), so z stays
      at the spawn height;
    - the wheels do not turn in the viewport: their drives are freed;
    - the motion shows up in the printed pos.x / pos.y.
"""

import argparse
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import standalone_common  # noqa: E402

# Target base velocity (world frame).
CMD_VX = 0.5  # m/s
CMD_VY = 0.0  # m/s
CMD_WZ = 0.0  # rad/s

REPORT_EVERY = 60

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[planar] SIGINT/SIGTERM -- requesting shutdown", flush=True)
    _SHOULD_QUIT = True


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="OpenBase fixed planar move")
    parser.add_argument(
        "--run-seconds",
        type=float,
        default=0.0,
        help="stop after N seconds (default 0 = until signalled)",
    )
    return parser.parse_args(argv)


def main():
    args = _parse_args(sys.argv[1:])

    from isaacsim import SimulationApp

    app = SimulationApp(
        standalone_common.kit_config(os.environ.get("ISAAC_LIVESTREAM"))
    )
    signal.signal(signal.SIGINT, _signal_handler)
    signal.signal(signal.SIGTERM, _signal_handler)

    import numpy as np
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim

    standalone_common.setup_openbase_stage(
        app, standalone_common.openbase_usd_path()
    )
    world = World(stage_units_in_meters=1.0)
    world.reset()
    base = SingleRigidPrim(standalone_common.OPENBASE_BASE_LINK)
    deadline = None
    if args.run_seconds > 0:
        deadline = time.monotonic() + args.run_seconds

    print(
        f"[cmd]   target vel = ({CMD_VX:+.2f}, {CMD_VY:+.2f}, "
        f"w={CMD_WZ:+.2f}); SIGINT/SIGTERM stops it",
        flush=True,
    )
    step = 0
    while app.is_running() and not _SHOULD_QUIT:
        if deadline is not None and time.monotonic() >= deadline:
            break
        base.set_linear_velocity(np.array([CMD_VX, CMD_VY, 0.0]))
        base.set_angular_velocity(np.array([0.0, 0.0, CMD_WZ]))
        world.step(render=True)
        step += 1
        if step % REPORT_EVERY != 0:
            continue
        pos, _orn = base.get_world_pose()
        lin = base.get_linear_velocity()
        ang = base.get_angular_velocity()
        print(
            f"[tick {step:>5}] "
            f"cmd=({CMD_VX:+.2f},{CMD_VY:+.2f},w={CMD_WZ:+.2f}) "
            f"pos=({pos[0]:+.2f},{pos[1]:+.2f},{pos[2]:+.2f}) "
            f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
            f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})",
            flush=True,
        )
    print(f"[planar] stopped after {step} steps", flush=True)
    return 0


if __name__ == "__main__":
    standalone_common.run_and_exit(main)
