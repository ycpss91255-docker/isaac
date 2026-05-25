"""Pre-flight smoke: verify set_kinematic_target writability on openbase.

PhysX rule: "links inside an articulation tree cannot be kinematic."
openbase.usda loads an articulation tree (Robot variant). If base_link
is an articulation root or child link, setting kinematicEnabled=True and
calling set_kinematic_target may be silently refused by PhysX.

This smoke test gates all subsequent L2 migration work (issue #23).
If it fails, stop and evaluate fallback paths listed in the issue.

Run inside the standalone container:
    ./exec.sh -t standalone /isaac-sim/python.sh \
        /home/yunchien/work/test/integration/test_openbase_l2_smoke.py
"""

import os
import sys

from isaacsim import SimulationApp

app = SimulationApp({"headless": True})

import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
from pxr import PhysxSchema, Usd, UsdPhysics  # noqa: E402

OVERRIDE_PATH = os.path.join(
    os.path.dirname(__file__),
    "..", "..", "model", "usd", "openbase", "openbase_l2.usda",
)
FALLBACK_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase.usda"

TARGET_PRIM = "/open_base/base_link"
TARGET_POS = (1.0, 0.0, 0.1)
SETTLE_TICKS = 300
POS_TOLERANCE = 0.05


def _find_usd():
    resolved = os.path.normpath(OVERRIDE_PATH)
    if os.path.exists(resolved):
        return resolved
    if os.path.exists(FALLBACK_PATH):
        return FALLBACK_PATH
    return None


def _dump_articulation_info(stage):
    """Print articulation root info for debugging if smoke fails."""
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            print(f"  [info] ArticulationRootAPI on: {prim.GetPath()}", flush=True)
        if prim.HasAPI(PhysxSchema.PhysxArticulationAPI):
            print(f"  [info] PhysxArticulationAPI on: {prim.GetPath()}", flush=True)


def _apply_l2_override(stage):
    """Apply kinematicEnabled on base_link, return True if attr was set."""
    prim = stage.GetPrimAtPath(TARGET_PRIM)
    if not prim.IsValid():
        print(f"[FAIL] prim {TARGET_PRIM} not found in stage", flush=True)
        return False
    rb_api = UsdPhysics.RigidBodyAPI(prim)
    if not rb_api:
        rb_api = UsdPhysics.RigidBodyAPI.Apply(prim)
    rb_api.GetKinematicEnabledAttr().Set(True)
    physx_api = PhysxSchema.PhysxRigidBodyAPI.Apply(prim)
    physx_api.GetDisableGravityAttr().Set(True)
    print(f"[smoke] kinematicEnabled=True set on {TARGET_PRIM}", flush=True)
    return True


def main():
    usd_path = _find_usd()
    if not usd_path:
        print("[FAIL] no openbase USD found", flush=True)
        return 1

    print(f"[smoke] loading {usd_path}", flush=True)
    ctx = omni.usd.get_context()
    if not ctx.open_stage(usd_path):
        print(f"[FAIL] open_stage returned False for {usd_path}", flush=True)
        return 1

    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    else:
        print("[FAIL] stage did not reach OPENED", flush=True)
        return 1

    stage = ctx.get_stage()
    print("[smoke] stage opened, dumping prim tree + articulation info:", flush=True)
    base_prim = stage.GetPrimAtPath(TARGET_PRIM)
    if base_prim.IsValid():
        apis = base_prim.GetAppliedSchemas()
        print(f"  [info] {TARGET_PRIM} applied schemas: {list(apis)}", flush=True)
        kin_attr = base_prim.GetAttribute("physics:kinematicEnabled")
        if kin_attr.IsValid():
            print(f"  [info] physics:kinematicEnabled = {kin_attr.Get()}", flush=True)
        else:
            print(f"  [info] physics:kinematicEnabled attr not found", flush=True)
    else:
        print(f"  [info] {TARGET_PRIM} NOT VALID in stage", flush=True)
    _dump_articulation_info(stage)

    if usd_path == FALLBACK_PATH:
        if not _apply_l2_override(stage):
            return 1

    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()

    for _ in range(10):
        app.update()

    iface = dc.acquire_dynamic_control_interface()
    handle = iface.get_rigid_body(TARGET_PRIM)
    if handle == dc.INVALID_HANDLE:
        print(f"[FAIL] dc.get_rigid_body({TARGET_PRIM}) returned INVALID_HANDLE", flush=True)
        return 1

    target = dc.Transform()
    target.p = TARGET_POS
    target.r = (0.0, 0.0, 0.0, 1.0)
    if hasattr(iface, "set_kinematic_target"):
        iface.set_kinematic_target(handle, target)
        print(f"[smoke] set_kinematic_target({TARGET_POS}) called", flush=True)
    else:
        iface.set_rigid_body_pose(handle, target)
        print(f"[smoke] set_rigid_body_pose({TARGET_POS}) called (fallback)", flush=True)

    for tick in range(SETTLE_TICKS):
        app.update()
        if tick % 60 == 0:
            pose = iface.get_rigid_body_pose(handle)
            print(
                f"  [tick {tick:>3}] pos=({pose.p[0]:+.3f}, {pose.p[1]:+.3f}, {pose.p[2]:+.3f})",
                flush=True,
            )

    final_pose = iface.get_rigid_body_pose(handle)
    dx = abs(final_pose.p[0] - TARGET_POS[0])
    dy = abs(final_pose.p[1] - TARGET_POS[1])
    dz = abs(final_pose.p[2] - TARGET_POS[2])
    max_err = max(dx, dy, dz)

    print(
        f"[smoke] final pos=({final_pose.p[0]:+.3f}, {final_pose.p[1]:+.3f}, {final_pose.p[2]:+.3f})"
        f" target={TARGET_POS} max_err={max_err:.4f}",
        flush=True,
    )

    if max_err > POS_TOLERANCE:
        print(
            f"[FAIL] position error {max_err:.4f} > tolerance {POS_TOLERANCE}. "
            "set_kinematic_target likely rejected by PhysX articulation constraint.",
            flush=True,
        )
        print("[FAIL] Evaluate fallback paths in issue #23 before proceeding.", flush=True)
        return 1

    print("[PASS] set_kinematic_target works on openbase base_link", flush=True)
    return 0


if __name__ == "__main__":
    rc = main()
    app.close()
    sys.exit(rc)
