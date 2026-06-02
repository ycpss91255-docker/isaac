"""OpenBase 物理 / drive 狀態診斷（Script Editor in-kit 版）

用法: Script Editor → File → Open 此檔 → Run。
讀目前 stage 內的 articulation / drive / ground / base 狀態，不改任何東西。
跑完後可刪。
"""

import omni.timeline
import omni.usd
from omni.isaac.dynamic_control import _dynamic_control as dc
from pxr import UsdPhysics


WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")

stage = omni.usd.get_context().get_stage()
tl = omni.timeline.get_timeline_interface()
print(
    f"[tl]    playing={tl.is_playing()}  "
    f"time={tl.get_current_time():.2f}  "
    f"end={tl.get_end_time():.2f}"
)

iface = dc.acquire_dynamic_control_interface()
art = dc.INVALID_HANDLE
for path in ("/open_base/origin_link", "/open_base/base_link"):
    h = iface.get_articulation(path)
    flag = "VALID" if h != dc.INVALID_HANDLE else "INVALID"
    print(f"[art]   {path} -> {flag}")
    if h != dc.INVALID_HANDLE and art == dc.INVALID_HANDLE:
        art = h

if art != dc.INVALID_HANDLE:
    n = iface.get_articulation_dof_count(art)
    print(f"[art]   active handle DOFs={n}")
    for w in WHEELS:
        d = iface.find_articulation_dof(art, w)
        if d == dc.INVALID_HANDLE:
            print(f"[dof]   {w}: NOT FOUND in articulation")
            continue
        print(
            f"[dof]   {w}: pos={iface.get_dof_position(d):+.3f}  "
            f"vel={iface.get_dof_velocity(d):+.3f}"
        )

# Drive type per wheel ------------------------------------------------
for prim in stage.Traverse():
    if prim.GetName() in WHEELS:
        drv = UsdPhysics.DriveAPI.Get(prim, "angular")
        if not drv:
            print(f"[drv]   {prim.GetName()}: NO angular DriveAPI")
            continue
        stiff = drv.GetStiffnessAttr().Get()
        damp = drv.GetDampingAttr().Get()
        target = drv.GetTargetVelocityAttr().Get()
        mode = (
            "VELOCITY (k=0)" if stiff == 0
            else "POSITION (k>0)" if stiff and stiff > 0
            else "UNKNOWN"
        )
        print(
            f"[drv]   {prim.GetName()}: stiff={stiff}  damp={damp}  "
            f"target_vel={target}  mode={mode}"
        )

# Ground --------------------------------------------------------------
g = stage.GetPrimAtPath("/World/GroundPlane")
if not g.IsValid():
    print("[ground] /World/GroundPlane: NOT FOUND")
else:
    coll = UsdPhysics.CollisionAPI(g)
    enabled = coll.GetCollisionEnabledAttr().Get() if coll else None
    print(f"[ground] /World/GroundPlane: present  collision_enabled={enabled}")

# Base rigid body / fix_base ------------------------------------------
b = stage.GetPrimAtPath("/open_base/base_link")
if not b.IsValid():
    print("[base]  /open_base/base_link: NOT FOUND")
else:
    rb = UsdPhysics.RigidBodyAPI(b)
    if not rb:
        print("[base]  base_link has NO RigidBodyAPI (= fix_base style, body cannot move)")
    else:
        kin = rb.GetKinematicEnabledAttr().Get()
        en = rb.GetRigidBodyEnabledAttr().Get()
        print(f"[base]  rigid_body_enabled={en}  kinematic={kin}")

# 列出 stage 上層 prim 看 articulation 真實 root --------------------
print("[stage] top-level prims:")
for prim in stage.GetPseudoRoot().GetChildren():
    print(f"        {prim.GetPath()}  ({prim.GetTypeName()})")
