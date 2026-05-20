"""Forklift blocky Model A-hybrid driver.

Forklift cubes are kinematic rigid bodies — driver writes pose via
dc.set_kinematic_target each tick (PhysX honors as kinematic update,
collision still active so forks interact with dynamic pallet).
Environment (ground, pallet) is dynamic + collision (real physics).
Pallet falls under gravity, gets lifted by fork collision push + friction.

Demo cycle (30s): approach pallet -> insert forks -> lift -> carry back ->
drop pallet -> return home -> repeat.
"""

USD_PATH = "/home/yunchien/work/src/model/usd/forklift_blocky/forklift_blocky.usda"
LOG_PATH = "/home/yunchien/work/src/script/forklift_status.log"

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

import time

import omni.kit.app
import omni.timeline
import omni.usd


def _log(msg):
    print(msg)
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

_g = globals()
for name in ("_forklift_tick_sub", "_tick", "_cmd_vel_tick_sub", "_poc59_tick_sub"):
    sub = _g.get(name)
    if sub is None:
        continue
    try:
        if hasattr(sub, "unsubscribe"):
            sub.unsubscribe()
    except Exception as exc:
        _log(f"[forklift-Ah] unsubscribe {name} ignored: {exc}")
    _g[name] = None
    _log(f"[forklift-Ah] retired {name}")

ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
_log("[forklift-Ah] stage opened")

from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
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
    "paused_t": 0.0,         # accumulated elapsed time while paused (subtracted from wall clock)
    "last_pause_check": time.time(),
}

_tl = omni.timeline.get_timeline_interface()

# Pickup thresholds
PICKUP_LIFT_THRESHOLD = 0.05   # carriage_lift > this enables pickup
DROP_LIFT_THRESHOLD = 0.05     # carriage_lift < this drops pallet
FORK_REACH_OVER_PALLET = 0.3   # fork tip needs to extend at least this far past pallet front


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
    # Pallet handle (dynamic body). Init pose is (0,0,0) — collision shapes
    # are baked at world position (3.5, 0, ...) in their local translate.
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
        from pxr import Gf
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
        # Back away further so fork open/close + mast extension don't hit pallet
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
        # HOLD at top for 0.5s
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
    fork_x = chassis_x + 1.5  # fork center x (rest fork x = 1.5)
    fork_z = 0.075 + mast_lift + carriage_lift  # fork center z

    p_pose = iface.get_rigid_body_pose(p_h)
    p_x, p_y, p_z = p_pose.p

    if not state["carrying"]:
        # Pickup condition: fork tip (fork_x + 0.5) extends past pallet front edge
        # (p_x - 0.6) by at least FORK_REACH_OVER_PALLET, AND lift threshold met
        fork_tip = fork_x + 0.5
        pallet_front = p_x - 0.6
        if (fork_tip - pallet_front >= FORK_REACH_OVER_PALLET
                and carriage_lift > PICKUP_LIFT_THRESHOLD
                and abs(p_y - chassis_y) < 0.3):
            state["carrying"] = True
            # Capture relative offset at attach moment
            state["attach_dx"] = p_x - fork_x
            state["attach_dy"] = p_y - chassis_y
            _log(
                f"[forklift-Ah] PICKUP attached: dx={state['attach_dx']:+.2f} "
                f"dy={state['attach_dy']:+.2f}"
            )
    else:
        # Drop condition
        if carriage_lift < DROP_LIFT_THRESHOLD:
            state["carrying"] = False
            _log("[forklift-Ah] DROP — pallet returns to physics")
            return
        # Lock pallet to fork pose
        # pallet_z = fork_z - 0.030 (deck bottom rests on fork top — see geometry)
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


def _tick(_e):
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
    # Readback: body pose (kinematic) AND pallet pose
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


_sub = (
    omni.kit.app.get_app()
    .get_post_update_event_stream()
    .create_subscription_to_pop(_tick, name="forklift_Ah_tick")
)
_g["_forklift_tick_sub"] = _sub

# Need timeline.play for PhysX simulation (pallet gravity, kinematic-dynamic
# collision response).
tl = omni.timeline.get_timeline_interface()
tl.set_end_time(1.0e9)
tl.play()

_log("[forklift-Ah] tick subscription registered; 30s pickup demo cycle")
