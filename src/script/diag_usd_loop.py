"""Diagnostic: SimulationApp + open USD + APP.update() loop, NO rclpy / dc.

Bisects standalone cmd_vel crash. If this survives 90s, the issue is in
rclpy / dc layer. If THIS crashes, the issue is USD/PhysX fundamental.

Run:
    ./exec.sh -t standalone /isaac-sim/python.sh \\
        /home/yunchien/work/src/script/diag_usd_loop.py
"""

import os
import signal
import sys

from isaacsim import SimulationApp

APP = SimulationApp({
    "headless": False,
    "livestream": 2,
    "renderer": "RaytracedLighting",
})

_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[diag] SIGINT/SIGTERM", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)

import omni.usd  # noqa: E402

USD_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase.usda"


def main():
    if not os.path.exists(USD_PATH):
        raise FileNotFoundError(USD_PATH)
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        raise RuntimeError(f"open_stage False for {USD_PATH}")
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        APP.update()
    else:
        raise RuntimeError("stage never OPENED")
    print(f"[diag] stage opened: {USD_PATH}", flush=True)

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
