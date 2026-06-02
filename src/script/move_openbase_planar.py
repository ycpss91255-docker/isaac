"""OpenBase 2D 平面移動測試（Gazebo planar_move 等價 — Script Editor in-kit）

跳過輪子物理，每 frame 直接覆寫 base_link 的 linear / angular velocity。
車身仍是 dynamic body（保留 mass + collision），但輪子 drive 全關，不對車身
施力。等價於 Gazebo 的 libgazebo_ros_planar_move plugin。

用法:
  Script Editor → File → Open → Run
  改 CMD_VX / CMD_VY / CMD_WZ 後重 Run 即可換目標速度（不需重開 Isaac）。
  停車: 把 3 個都設 0.0 重 Run。

注意:
  - base 仍受重力 / 接觸支撐力，所以 z 方向自然停在地板上
  - 輪子在 viewport 看起來不轉是預期 — 它們已經被 disable
  - 真的位移會在 base.pos.x / pos.y 看到變化
"""

import math

import omni.kit.app
import omni.kit.commands
import omni.timeline
import omni.usd
from omni.isaac.dynamic_control import _dynamic_control as dc
from pxr import PhysxSchema, UsdLux, UsdPhysics


# ====== CONFIG =====================================================
# openbase_free.usda (OpenBase 專案 pre-built) 在 in-kit 跑 dc.set_rigid_body
# _linear_velocity 寫不進去（articulation 子 link handle 被 PhysX 覆蓋）。
# 換用 model/usd/robot/openbase/openbase.usda（standalone 已驗 root free rigid body
# 可寫）— 標準 SOP 也是這個。
USD_PATH = "/home/yunchien/work/src/model/usd/robot/openbase/openbase.usda"

# 目標 base velocity (世界坐標 / base 朝向 — 視 base 初始 yaw 而定)
CMD_VX  = 0.5    # m/s, +x
CMD_VY  = 0.0    # m/s, +y
CMD_WZ  = 0.0    # rad/s, yaw

REPORT_EVERY = 60
# ===================================================================


WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")

ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
print(f"[setup] opened {USD_PATH}")

# 加光 / 地板（缺才補）-----------------------------------------------
if not stage.GetPrimAtPath("/World/SunLight").IsValid():
    UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(3000.0)
    print("[setup] sunlight added")

# 先刪掉舊的（不管是 plain plane 還是 Isaac grid plane），再建 Isaac 內建有
# grid texture 的版本。這樣 script 重 Run 一定刷新成新版地板，不用 GUI 介入。
if stage.GetPrimAtPath("/World/GroundPlane").IsValid():
    omni.kit.commands.execute("DeletePrims", paths=["/World/GroundPlane"])
from isaacsim.core.api.objects.ground_plane import GroundPlane as IsaacGroundPlane
IsaacGroundPlane(prim_path="/World/GroundPlane", z_position=0, size=100)
print("[setup] ground plane added (Isaac grid texture)")

# 把所有輪子 drive 關死（避免它們對 base 施力）------------------------
for prim in stage.Traverse():
    if prim.GetName() in WHEELS:
        drive = UsdPhysics.DriveAPI.Get(prim, "angular")
        drive.GetStiffnessAttr().Set(0.0)
        drive.GetDampingAttr().Set(0.0)         # 關鍵：damping=0 = 完全自由旋轉
        drive.GetTargetVelocityAttr().Set(0.0)
        print(f"[setup] {prim.GetName()}: drive disabled")

# set_rigid_body_linear_velocity 每 tick 寫入時機在 PhysX step 之後，
# 期間 gravity 已累積 pos.z 下沉（standalone 版實測 -0.16 m/s 漂移）。
# disable gravity on base_link 是 Gazebo planar_move 等效的乾淨修法。
base_prim = stage.GetPrimAtPath("/open_base/base_link")
if base_prim.IsValid():
    physx_api = PhysxSchema.PhysxRigidBodyAPI.Apply(base_prim)
    physx_api.GetDisableGravityAttr().Set(True)
    print("[setup] base_link: gravity disabled")

# `openbase_minimal.urdf` 透過 import_urdf.py 產出後，base_link 只是空 Xform
# 沒 mesh child（package:// STL 路徑 import 沒解析到正確位置）。掛一個鮮紅
# debug cube 在 base_link 下，cube 會跟 base_link transform 一起動，viewport
# 內直接看到方塊在 grid 上滑動，純為視覺驗證。修 mesh import 是獨立任務。
from pxr import Gf, UsdGeom  # noqa: E402
cube_path = "/open_base/base_link/DebugCube"
if not stage.GetPrimAtPath(cube_path).IsValid():
    cube = UsdGeom.Cube.Define(stage, cube_path)
    cube.GetSizeAttr().Set(0.3)
    UsdGeom.Gprim(cube).GetDisplayColorAttr().Set([Gf.Vec3f(0.9, 0.15, 0.15)])
    print("[setup] debug cube (red) attached to base_link")

# Play -----------------------------------------------------------------
_tl = omni.timeline.get_timeline_interface()
_tl.set_end_time(1.0e9)
_tl.play()
print(f"[cmd]   target vel = ({CMD_VX:+.2f}, {CMD_VY:+.2f}, ω={CMD_WZ:+.2f})")

iface = dc.acquire_dynamic_control_interface()

# 註冊 update callback：每 frame 強制覆寫 base velocity ----------------
state = {"step": 0}

def _on_tick(_e):
    state["step"] += 1
    base = iface.get_rigid_body("/open_base/base_link")
    if base == dc.INVALID_HANDLE:
        return  # PhysX 還沒 init 完，下個 frame 再試
    iface.set_rigid_body_linear_velocity(base, (CMD_VX, CMD_VY, 0.0))
    iface.set_rigid_body_angular_velocity(base, (0.0, 0.0, CMD_WZ))

    if state["step"] % REPORT_EVERY != 0:
        return
    pose = iface.get_rigid_body_pose(base)
    lin  = iface.get_rigid_body_linear_velocity(base)
    ang  = iface.get_rigid_body_angular_velocity(base)
    print(
        f"[tick {state['step']:>5}] "
        f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
        f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
        f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})"
    )


# 退掉舊 subscription（重 Run 時）------------------------------------
_g = globals()
old = _g.get("_planar_tick_sub")
if old is not None:
    _g["_planar_tick_sub"] = None

sub = omni.kit.app.get_app().get_update_event_stream().create_subscription_to_pop(
    _on_tick, name="planar_move_tick"
)
_g["_planar_tick_sub"] = sub
print(f"[setup] tick subscription registered (every {REPORT_EVERY} ticks)")
print("[done] kit 持續 step；重 Run 此檔可改 CMD_VX/VY/WZ 不需重開 Isaac")
