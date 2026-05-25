"""L2 kinematic stability test for openbase (issue #23, unblocks #16).

Four-item stability check on the L2-migrated openbase:
1. Pose tracking accuracy (set target, verify arrival)
2. No z-drift over sustained motion (kinematic body ignores gravity)
3. No NaN / inf in pose readback
4. Multi-target sequence (move to A, then B, then C — no accumulated error)

Runs headless, no ROS 2 dependency (pure dc pose write).

Run inside the standalone container:
    cd docker
    make exec -- -t headless /isaac-sim/python.sh \
        /home/yunchien/work/src/test/integration/test_openbase_l2_stability.py
"""

import math
import os
import sys

from isaacsim import SimulationApp

app = SimulationApp({"headless": True})

import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402

USD_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase_l2.usda"
BASE_PRIM = "/open_base/base_link"
SETTLE_TICKS = 60
POS_TOL = 0.05
Z_DRIFT_TOL = 0.01


def _open_stage():
    if not os.path.exists(USD_PATH):
        print(f"[FAIL] USD not found: {USD_PATH}", flush=True)
        return None
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        print(f"[FAIL] open_stage returned False", flush=True)
        return None
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    else:
        print("[FAIL] stage did not reach OPENED", flush=True)
        return None
    return ctx.get_stage()


def _get_handle(iface):
    handle = iface.get_rigid_body(BASE_PRIM)
    if handle == dc.INVALID_HANDLE:
        print(f"[FAIL] dc.get_rigid_body({BASE_PRIM}) INVALID_HANDLE", flush=True)
        return None
    return handle


def _move_and_settle(iface, handle, target_pos, ticks):
    target = dc.Transform()
    target.p = target_pos
    target.r = (0.0, 0.0, 0.0, 1.0)
    for _ in range(ticks):
        iface.set_rigid_body_pose(handle, target)
        app.update()
    return iface.get_rigid_body_pose(handle)


def _check_pose(label, pose, expected, tol):
    dx = abs(pose.p[0] - expected[0])
    dy = abs(pose.p[1] - expected[1])
    dz = abs(pose.p[2] - expected[2])
    err = max(dx, dy, dz)
    ok = err <= tol
    status = "ok" if ok else "FAIL"
    print(
        f"  [{status}] {label}: pos=({pose.p[0]:+.4f},{pose.p[1]:+.4f},{pose.p[2]:+.4f})"
        f" expect={expected} err={err:.4f} tol={tol}",
        flush=True,
    )
    return ok


def _check_finite(label, pose):
    vals = [pose.p[0], pose.p[1], pose.p[2], pose.r[0], pose.r[1], pose.r[2], pose.r[3]]
    ok = all(math.isfinite(v) for v in vals)
    if not ok:
        print(f"  [FAIL] {label}: NaN/inf detected in pose {vals}", flush=True)
    else:
        print(f"  [ok] {label}: all values finite", flush=True)
    return ok


def main():
    stage = _open_stage()
    if stage is None:
        return 1

    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()
    for _ in range(10):
        app.update()

    iface = dc.acquire_dynamic_control_interface()
    handle = _get_handle(iface)
    if handle is None:
        return 1

    init_pose = iface.get_rigid_body_pose(handle)
    init_z = float(init_pose.p[2])
    passed = True

    print("[test 1/4] pose tracking accuracy", flush=True)
    target_1 = (2.0, 1.0, init_z)
    pose_1 = _move_and_settle(iface, handle, target_1, SETTLE_TICKS)
    if not _check_pose("single target", pose_1, target_1, POS_TOL):
        passed = False

    print("[test 2/4] z-drift over sustained motion (600 ticks)", flush=True)
    target_2 = (5.0, 3.0, init_z)
    pose_2 = _move_and_settle(iface, handle, target_2, 600)
    z_drift = abs(pose_2.p[2] - init_z)
    if z_drift > Z_DRIFT_TOL:
        print(f"  [FAIL] z-drift: {z_drift:.4f} > {Z_DRIFT_TOL}", flush=True)
        passed = False
    else:
        print(f"  [ok] z-drift: {z_drift:.4f} <= {Z_DRIFT_TOL}", flush=True)
    if not _check_pose("sustained target", pose_2, target_2, POS_TOL):
        passed = False

    print("[test 3/4] NaN/inf check after sustained motion", flush=True)
    if not _check_finite("after 600 ticks", pose_2):
        passed = False

    print("[test 4/4] multi-target sequence (no accumulated error)", flush=True)
    waypoints = [
        (-3.0, 2.0, init_z),
        (0.0, -4.0, init_z),
        (7.0, 7.0, init_z),
    ]
    for i, wp in enumerate(waypoints):
        pose_wp = _move_and_settle(iface, handle, wp, SETTLE_TICKS)
        if not _check_pose(f"waypoint {i}", pose_wp, wp, POS_TOL):
            passed = False
        if not _check_finite(f"waypoint {i}", pose_wp):
            passed = False

    if passed:
        print("[PASS] all 4 stability checks passed", flush=True)
        return 0
    else:
        print("[FAIL] one or more stability checks failed", flush=True)
        return 1


if __name__ == "__main__":
    rc = main()
    app.close()
    sys.exit(rc)
