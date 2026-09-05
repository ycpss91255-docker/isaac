"""Forklift blocky Model A-hybrid driver (standalone-with-livestream).

TEST-ONLY / WIP fixture -- NOT a v1.0.0 reference (ADR-0021). This drives the
hand-authored standalone-kinematic ``forklift_blocky`` asset, which is not the
v1.0.0 direction (that is the URDF -> UrdfConverter articulation pipeline,
L2 / L2.5 / L3). Full migration out to isaac-forklift is tracked by #136 (M3).

Forklift cubes are kinematic rigid bodies — driver writes pose via
dc.set_kinematic_target each tick (PhysX honors as kinematic update,
collision still active so forks interact with dynamic pallet).
Environment (ground, pallet) is dynamic + collision (real physics).
Pallet falls under gravity, gets lifted by fork collision push + friction.

Demo cycle (51s): approach pallet -> insert forks -> lift -> carry back ->
drop pallet -> back away -> fork spread -> mast extension -> return home -> repeat.

Run inside the standalone container (NOT headless — the headless target
auto-starts runheadless.sh which would race this driver's SimulationApp
for the WebRTC streaming port; see ADR-0005 Update 2026-05-21):

    cd isaac_ws/src/docker
    ./run.sh -t standalone -d
    ./exec.sh -t standalone /isaac-sim/python.sh \
        /home/yunchien/work/src/script/forklift_blocky_driver_wip.py

Optional --config (repeatable) attaches one or more sim cameras and
publishes their topics. See doc/adr/0006-per-sensor-yaml-camera-config.md.

    ./exec.sh -t standalone /isaac-sim/python.sh \
        /home/yunchien/work/src/script/forklift_blocky_driver_wip.py \
        --config /home/yunchien/work/src/config/camera/realsense.yaml

The demo loops until Ctrl-C (or SIGTERM). Connect the Isaac Sim WebRTC
Streaming Client app to 127.0.0.1 to view the scene. Streaming Client
disconnect does not stop the sim; only Ctrl-C does.
"""

import argparse
import os
import signal
import sys
import time
from pathlib import Path

# Container's /home/yunchien/.cache/ is root-owned (host bind only covers
# specific sub-dirs); warp's default cache dir at .cache/warp is not
# writable, which breaks omni.replicator.core startup and downstream
# SDG / ROS publish. Redirect to /tmp before any Isaac Sim import.
os.environ.setdefault("WARP_CACHE_PATH", "/tmp/warp")
os.environ.setdefault("WARP_CACHE_DIR", "/tmp/warp")

_parser = argparse.ArgumentParser(add_help=False)
_parser.add_argument(
    "--config",
    action="append",
    default=[],
    help="Path to a sim camera YAML config (repeatable for multi-camera setups).",
)
_args, _ = _parser.parse_known_args()
camera_config_paths = [Path(c).expanduser().resolve() for c in _args.config]

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
USD_PATH = str(REPO_ROOT / "model" / "usd" / "robot" / "forklift_blocky" / "forklift_blocky.usda")
LOG_PATH = str(SCRIPT_DIR / "forklift_status.log")

# Rest poses (matches USD initial translate). Driver overlays state on these.
# carriage/forks rest LOWERED to 0.075 (fork-insertion height for blocky pallet
# with 10cm fork-window gap from z=0.03 to 0.13).
REST = {
    "body":       (0.00, 0.00, 0.50),
    "mast_lower": (0.85, 0.00, 1.40),
    "mast_upper": (0.85, 0.00, 1.30),
    "carriage":   (0.95, 0.00, 0.075),
    "left_fork":  (1.50, 0.20, 0.075),
    "right_fork": (1.50, -0.20, 0.075),
}

PRIM_PATHS = {
    "body":       "/World/Forklift/body",
    "mast_lower": "/World/Forklift/mast_lower",
    "mast_upper": "/World/Forklift/mast_upper",
    "carriage":   "/World/Forklift/carriage",
    "left_fork":  "/World/Forklift/left_fork",
    "right_fork": "/World/Forklift/right_fork",
}

FORK_NARROW = 0.20
FORK_WIDE = 0.40

# Pickup thresholds
PICKUP_LIFT_THRESHOLD = 0.05
DROP_LIFT_THRESHOLD = 0.05
FORK_REACH_OVER_PALLET = 0.3


def _log(msg):
    print(msg, flush=True)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


try:
    open(LOG_PATH, "w").close()
except Exception:
    pass

_log("[forklift-Ah] starting (Model A-hybrid: kinematic forklift + dynamic env)")
_log(f"[forklift-Ah] USD: {USD_PATH}")
_log(f"[forklift-Ah] LOG: {LOG_PATH}")

from isaacsim import SimulationApp  # noqa: E402

# Pin the kit experience to the custom isaacsim.exp.base.python.streaming.kit
# shipped by ycpss91255-docker/isaac. SimulationApp's default experience
# (isaacsim.exp.base.python.kit) lacks WebRTC livestream extensions, so
# `livestream: 2` alone is a no-op — the streaming server never starts.
# See ADR-0007 for the rationale.
sim_app = SimulationApp(
    {"headless": True, "livestream": 2},
    experience="/isaac-sim/apps/isaacsim.exp.base.python.streaming.kit",
)

# SimulationApp headless=True auto-injects --/app/window/hideUi=1 which
# hides the editor UI in the Streaming Client. Override post-boot + load
# the Isaac Sim default window layout (Stage right, Console bottom, etc.)
# from isaacsim.app.setup/layouts/default.json via QuickLayout.
import carb.settings  # noqa: E402
carb.settings.get_settings().set("/app/window/hideUi", False)
sim_app.update()

from omni.kit.quicklayout import QuickLayout  # noqa: E402
QuickLayout.load_file(
    "/isaac-sim/exts/isaacsim.app.setup/layouts/default.json",
    keep_windows_open=False,
)
for _ in range(5):
    sim_app.update()

# Kit-side imports must come after SimulationApp boot.
import omni.kit.app  # noqa: E402
import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
from pxr import Gf  # noqa: E402

stop_requested = False


def _handle_signal(_signum, _frame):
    global stop_requested
    stop_requested = True
    _log("[forklift-Ah] signal received — requesting clean exit")


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)

ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
_log("[forklift-Ah] stage opened")

# Camera setup runs AFTER stage open so parent_prim resolution works.
if camera_config_paths:
    if str(SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(SCRIPT_DIR))
    from camera_setup import load_config, setup_camera  # noqa: E402

    _loaded_camera_configs = [load_config(p) for p in camera_config_paths]
    _seen_topics, _seen_frames = set(), set()
    for _cfg in _loaded_camera_configs:
        _tp = _cfg["ros"]["topic_prefix"]
        _fp = _cfg["ros"]["frame_id_prefix"]
        if _tp in _seen_topics:
            raise ValueError(f"duplicate ros.topic_prefix across configs: {_tp}")
        if _fp in _seen_frames:
            raise ValueError(f"duplicate ros.frame_id_prefix across configs: {_fp}")
        _seen_topics.add(_tp)
        _seen_frames.add(_fp)
    for _cfg in _loaded_camera_configs:
        _log(
            f"[forklift-Ah] camera setup: {_cfg['_source']} "
            f"(sensor.type={_cfg['sensor']['type']})"
        )
        _graph = setup_camera(_cfg, stage)
        _log(f"[forklift-Ah] camera graph created at {_graph}")

iface = dc.acquire_dynamic_control_interface()

state = {
    "step": 0,
    "t0": time.time(),
    "last_log_t": 0.0,
    "handles": {},
    "handles_done": False,
    "carrying": False,
    "attach_dx": 0.0,
    "attach_dy": 0.0,
    "paused_t": 0.0,
    "last_pause_check": time.time(),
}

_tl = omni.timeline.get_timeline_interface()


def _resolve_handles():
    if state["handles_done"]:
        return True
    state["xform_attrs"] = {}
    for key, path in PRIM_PATHS.items():
        h = iface.get_rigid_body(path)
        if h == dc.INVALID_HANDLE:
            return False
        state["handles"][key] = h
        prim = stage.GetPrimAtPath(path)
        if prim.IsValid():
            state["xform_attrs"][key] = prim.GetAttribute("xformOp:translate")
    p_h = iface.get_rigid_body("/World/Pallet")
    if p_h != dc.INVALID_HANDLE:
        state["handles"]["pallet"] = p_h
        _log("[forklift-Ah] pallet handle ok (collision shapes baked at x=3.5)")
    state["handles_done"] = True
    _log(f"[forklift-Ah] handles resolved: {list(state['handles'].keys())}")
    return True


def _set_pose(key, x, y, z):
    h = state["handles"].get(key)
    if h is None:
        return
    target = dc.Transform()
    target.p = (float(x), float(y), float(z))
    target.r = (0.0, 0.0, 0.0, 1.0)
    # Kinematic bodies: PhysX-honored kinematic update.
    if hasattr(iface, "set_kinematic_target"):
        iface.set_kinematic_target(h, target)
    else:
        iface.set_rigid_body_pose(h, target)
    # Also write USD xformOp:translate so Hydra render sees the change.
    # Some Isaac Sim 5.1 configs don't auto-sync kinematic body pose to USD
    # for viewport rendering — explicit USD write closes the gap.
    attr = state.get("xform_attrs", {}).get(key)
    if attr is not None:
        attr.Set(Gf.Vec3d(float(x), float(y), float(z)))


def _apply_state(chassis_x, chassis_y, mast_lift, carriage_lift, fork_spread):
    bx, by, bz = REST["body"]
    _set_pose("body", bx + chassis_x, by + chassis_y, bz)
    mlx, mly, mlz = REST["mast_lower"]
    _set_pose("mast_lower", mlx + chassis_x, mly + chassis_y, mlz)
    mux, muy, muz = REST["mast_upper"]
    _set_pose("mast_upper", mux + chassis_x, muy + chassis_y, muz + mast_lift)
    cx, cy, cz = REST["carriage"]
    _set_pose("carriage", cx + chassis_x, cy + chassis_y, cz + mast_lift + carriage_lift)
    lx, _ly, lz = REST["left_fork"]
    _set_pose("left_fork", lx + chassis_x, chassis_y + fork_spread, lz + mast_lift + carriage_lift)
    rx, _ry, rz = REST["right_fork"]
    _set_pose("right_fork", rx + chassis_x, chassis_y - fork_spread, rz + mast_lift + carriage_lift)


def _pickup_targets(t):
    """51s extended demo cycle.
    Pallet at world x=3.5. Forks at fork tip x=2.0 (rest, with chassis=0).

    Phases:
     0-3   : init
     3-10  : approach (chassis 0 -> 1.5)
    10-14  : lift pallet (carriage 0 -> 0.4)
    14-22  : carry back (chassis 1.5 -> -0.5)
    22-26  : drop (carriage 0.4 -> 0)
    26-31  : back away further (chassis -0.5 -> -2.5) — forks safely clear pallet
    31-36  : fork open/close at chassis=-2.5
    36-42  : combined extend mast 0->1.2 + carriage 0->2.0
    42-42.5: HOLD at top
    42.5-47.5: retract
    47.5-51 : return home (chassis -2.5 -> 0)
    """
    t = t % 51.0
    if t < 3.0:
        return 0.0, 0.0, 0.0, 0.0, FORK_NARROW
    if t < 10.0:
        return 1.5 * (t - 3.0) / 7.0, 0.0, 0.0, 0.0, FORK_NARROW
    if t < 14.0:
        return 1.5, 0.0, 0.0, 0.4 * (t - 10.0) / 4.0, FORK_NARROW
    if t < 22.0:
        x = 1.5 + (-0.5 - 1.5) * (t - 14.0) / 8.0
        return x, 0.0, 0.0, 0.4, FORK_NARROW
    if t < 26.0:
        return -0.5, 0.0, 0.0, 0.4 * (1.0 - (t - 22.0) / 4.0), FORK_NARROW
    if t < 31.0:
        x = -0.5 + (-2.5 - -0.5) * (t - 26.0) / 5.0
        return x, 0.0, 0.0, 0.0, FORK_NARROW
    if t < 36.0:
        u = (t - 31.0) / 5.0
        if u < 0.5:
            sp = FORK_NARROW + (FORK_WIDE - FORK_NARROW) * (u * 2)
        else:
            sp = FORK_WIDE - (FORK_WIDE - FORK_NARROW) * ((u - 0.5) * 2)
        return -2.5, 0.0, 0.0, 0.0, sp
    if t < 42.0:
        u = (t - 36.0) / 6.0
        return -2.5, 0.0, 1.2 * u, 2.0 * u, FORK_NARROW
    if t < 42.5:
        return -2.5, 0.0, 1.2, 2.0, FORK_NARROW
    if t < 47.5:
        u = (t - 42.5) / 5.0
        return -2.5, 0.0, 1.2 * (1.0 - u), 2.0 * (1.0 - u), FORK_NARROW
    return -2.5 + 2.5 * (t - 47.5) / 3.5, 0.0, 0.0, 0.0, FORK_NARROW


def _update_pickup(chassis_x, chassis_y, mast_lift, carriage_lift):
    """State machine: idle <-> carrying.

    idle -> carrying: forks under pallet (x overlap) + carriage_lift > threshold
    carrying -> idle: carriage_lift < threshold (drop command)

    During carrying: pallet pose teleported each tick to follow fork; physics
    velocity zeroed so gravity doesn't drag pallet down.
    """
    p_h = state["handles"].get("pallet")
    if p_h is None:
        return
    fork_x = chassis_x + 1.5
    fork_z = 0.075 + mast_lift + carriage_lift

    p_pose = iface.get_rigid_body_pose(p_h)
    p_x, p_y, p_z = p_pose.p

    if not state["carrying"]:
        fork_tip = fork_x + 0.5
        pallet_front = p_x - 0.6
        if (fork_tip - pallet_front >= FORK_REACH_OVER_PALLET
                and carriage_lift > PICKUP_LIFT_THRESHOLD
                and abs(p_y - chassis_y) < 0.3):
            state["carrying"] = True
            state["attach_dx"] = p_x - fork_x
            state["attach_dy"] = p_y - chassis_y
            _log(
                f"[forklift-Ah] PICKUP attached: dx={state['attach_dx']:+.2f} "
                f"dy={state['attach_dy']:+.2f}"
            )
    else:
        if carriage_lift < DROP_LIFT_THRESHOLD:
            state["carrying"] = False
            _log("[forklift-Ah] DROP — pallet returns to physics")
            return
        target = dc.Transform()
        target.p = (
            fork_x + state["attach_dx"],
            chassis_y + state["attach_dy"],
            fork_z - 0.030,
        )
        target.r = (0.0, 0.0, 0.0, 1.0)
        iface.set_rigid_body_pose(p_h, target)
        iface.set_rigid_body_linear_velocity(p_h, (0.0, 0.0, 0.0))
        iface.set_rigid_body_angular_velocity(p_h, (0.0, 0.0, 0.0))


def _tick():
    state["step"] += 1
    if not _resolve_handles():
        return
    # Respect timeline pause: when paused, freeze demo time (no driver writes,
    # no t advance). Re-sync t0 on resume so unpausing doesn't jump forward.
    now = time.time()
    if not _tl.is_playing():
        state["paused_t"] += now - state["last_pause_check"]
        state["last_pause_check"] = now
        return
    state["last_pause_check"] = now
    t = now - state["t0"] - state["paused_t"]
    cx, cy, m, c, sp = _pickup_targets(t)
    _apply_state(cx, cy, m, c, sp)
    _update_pickup(cx, cy, m, c)
    if t - state["last_log_t"] < 0.5:
        return
    state["last_log_t"] = t
    body_h = state["handles"].get("body")
    if body_h is not None:
        b_pose = iface.get_rigid_body_pose(body_h)
        body_x = b_pose.p[0]
    else:
        body_x = -999
    p_h = state["handles"].get("pallet")
    if p_h is not None:
        p_pose = iface.get_rigid_body_pose(p_h)
        _log(
            f"[forklift-Ah] t={t:5.1f}s  cmd_x={cx:+.2f}  body_x={body_x:+.2f}  "
            f"carr={c:.2f}  pallet=({p_pose.p[0]:+.2f},{p_pose.p[1]:+.2f},{p_pose.p[2]:+.2f})"
        )
    else:
        _log(f"[forklift-Ah] t={t:5.1f}s  cmd_x={cx:+.2f}  body_x={body_x:+.2f}  carr={c:.2f}  pallet=N/A")


# PhysX needs the timeline playing for pallet gravity + kinematic-dynamic
# collision response. set_end_time large so the timeline does not auto-stop.
_tl.set_end_time(1.0e9)
_tl.play()

_log("[forklift-Ah] entering spin loop — Ctrl-C to exit (browser close does not stop sim)")
_log("[forklift-Ah] WebRTC: http://localhost:8011/streaming/webrtc-client")

exit_code = 0
try:
    while sim_app.is_running():
        if stop_requested:
            _log("[forklift-Ah] stop requested — breaking loop")
            break
        _tick()
        sim_app.update()
except Exception as exc:
    _log(f"[forklift-Ah] FATAL: {exc!r}")
    exit_code = 1
finally:
    _log("[forklift-Ah] shutting down")
    sim_app.close()

sys.exit(exit_code)
