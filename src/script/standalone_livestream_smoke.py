"""Standalone-with-livestream smoke driver.

Boots SimulationApp with WebRTC livestream on, builds a tiny scene
(one cube + ground + light) programmatically, spins for ~30 seconds,
then exits cleanly.

Run inside the headless container:

    cd isaac_ws/src/docker
    ./exec.sh -t headless /isaac-sim/python.sh \
        /home/yunchien/work/src/script/standalone_livestream_smoke.py

While the script is running, browse to:

    http://localhost:8011/streaming/webrtc-client

A clean run prints "[smoke] DONE" and exits with code 0. SIGINT exits
early but still cleanly. The acceptance contract for issue
ycpss91255-docker/isaac#19 is: this script boots SimulationApp with
livestream:2, the WebRTC client can connect during the spin loop, and
python.sh exits 0.
"""

import signal
import sys
import time
from pathlib import Path

from isaacsim import SimulationApp

SMOKE_DURATION_SEC = 30.0
TICK_LOG_EVERY = 60

SCRIPT_DIR = Path(__file__).resolve().parent
LOG_PATH = SCRIPT_DIR / "standalone_livestream_smoke.log"

sim_app = SimulationApp(
    {"headless": True, "livestream": 2},
    # SimulationApp's default experience (isaacsim.exp.base.python.kit) lacks
    # the WebRTC livestream extensions, so `livestream: 2` alone never starts
    # the streaming server. Pin to the custom kit experience shipped by
    # ycpss91255-docker/isaac (#21 fix-B). See ADR-0007.
    experience="/isaac-sim/apps/isaacsim.exp.base.python.streaming.kit",
)

# Imports below must come after SimulationApp() — they load Kit-side modules.
from pxr import Gf, UsdGeom, UsdLux  # noqa: E402
import omni.usd  # noqa: E402

stop_requested = False


def _log(msg: str) -> None:
    print(msg, flush=True)
    try:
        with LOG_PATH.open("a") as f:
            f.write(msg + "\n")
    except OSError:
        pass


def _handle_sigint(_signum, _frame) -> None:
    global stop_requested
    stop_requested = True
    _log("[smoke] SIGINT — requesting clean exit")


signal.signal(signal.SIGINT, _handle_sigint)
signal.signal(signal.SIGTERM, _handle_sigint)


def _build_scene() -> None:
    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)

    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.CreateSizeAttr(1.0)
    UsdGeom.Xformable(ground).AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, -0.05))
    UsdGeom.Xformable(ground).AddScaleOp().Set(Gf.Vec3f(10.0, 10.0, 0.1))

    cube = UsdGeom.Cube.Define(stage, "/World/Cube")
    cube.CreateSizeAttr(1.0)
    UsdGeom.Xformable(cube).AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, 0.5))

    light = UsdLux.DistantLight.Define(stage, "/World/Light")
    light.CreateIntensityAttr(3000.0)

    _log("[smoke] scene built: /World/Cube + /World/Ground + /World/Light")


def main() -> int:
    try:
        LOG_PATH.unlink()
    except FileNotFoundError:
        pass

    _log("[smoke] SimulationApp booted (headless=True, livestream=2)")
    _log("[smoke] WebRTC client: http://localhost:8011/streaming/webrtc-client")

    _build_scene()

    _log(f"[smoke] entering spin loop ({SMOKE_DURATION_SEC:.0f}s budget)")
    start = time.monotonic()
    ticks = 0
    while sim_app.is_running():
        if stop_requested:
            _log("[smoke] stop requested — breaking loop")
            break
        elapsed = time.monotonic() - start
        if elapsed >= SMOKE_DURATION_SEC:
            _log(f"[smoke] reached {SMOKE_DURATION_SEC:.0f}s budget — exiting")
            break
        sim_app.update()
        ticks += 1
        if ticks % TICK_LOG_EVERY == 0:
            _log(f"[smoke] tick {ticks} @ {elapsed:.1f}s")

    elapsed = time.monotonic() - start
    _log(f"[smoke] DONE — {ticks} ticks in {elapsed:.1f}s")
    return 0


exit_code = main()
sim_app.close()
sys.exit(exit_code)
