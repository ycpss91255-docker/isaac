"""OpenBase 物理測試（Script Editor in-kit 版）

用法:
  Script Editor → File → Open 此檔 → Run
  改 CONFIG 區的值再 Run 即可重設（不需重開 Isaac）。
  停車: 把 VEL_LEFT/BACK/RIGHT 都改 0.0 再 Run。

CONFIG 區:
  USD_PATH      載哪份 USD
                  - openbase.usda      → fix_base=True，車身鎖死，輪子轉但車不動
                  - openbase_free.usda → fix_base=False，車身會隨輪子受力動
  VEL_*         每顆輪子個別速度 (rad/s)
                  - 同向同速 (+5,+5,+5)  → 自轉（yaw）
                  - 一輪反向 (+5,+5,-5)  → 平移 + 旋轉混合
                  - 一輪不動 (+5,0,0)    → 沿某方向移動 + 旋轉

Output (Script Editor 下方):
  [setup]   載 USD / 切 drive / 加光
  [vel]     設定每輪目標速度
  [tick N]  每 N steps 印一次 base pose / lin_vel / wheel actual
"""

import omni.kit.app
import omni.kit.commands
import omni.timeline
import omni.usd
from omni.isaac.dynamic_control import _dynamic_control as dc
from pxr import UsdLux, UsdPhysics


# ====== CONFIG ====================================================
USD_PATH = "/home/yunchien/work/src/OpenBase/openbase_free.usda"

VEL_LEFT  = 5.0
VEL_BACK  = 5.0
VEL_RIGHT = 5.0

REPORT_EVERY = 60   # 每 N kit ticks 印一次（kit 主 loop 60Hz 約等於秒級）
# ===================================================================


WHEELS = {
    "left_rim_joint":  VEL_LEFT,
    "back_rim_joint":  VEL_BACK,
    "right_rim_joint": VEL_RIGHT,
}

# 載 USD --------------------------------------------------------------
ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
print(f"[setup] opened {USD_PATH}")

# 加光（缺才補）------------------------------------------------------
if not stage.GetPrimAtPath("/World/SunLight").IsValid():
    UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(3000.0)
    print("[setup] sunlight added")

# 加地板 + collision（缺才補）— 沒地板車會 free-fall ----------------
if not stage.GetPrimAtPath("/World/GroundPlane").IsValid():
    omni.kit.commands.execute(
        "CreateMeshPrimWithDefaultXform",
        prim_type="Plane",
        prim_path="/World/GroundPlane",
    )
    g = stage.GetPrimAtPath("/World/GroundPlane")
    g.GetAttribute("xformOp:scale").Set((100, 100, 1))
    UsdPhysics.CollisionAPI.Apply(g)
    print("[setup] ground plane added (100x100 m, collision on)")

# 切 angular drive 到 velocity mode + 寫 target velocity 進 USD -------
# USD 角度 drive 的 targetVelocity 單位是 degrees/sec（OpenUSD 慣例），
# CONFIG 裡用 rad/s（直覺），這裡轉換。寫進 USD 比 dynamic_control 可靠 —
# 後者在 open_stage 後 call 會 race 到 PhysX 還沒 init articulation。
import math
RAD2DEG = 180.0 / math.pi
for prim in stage.Traverse():
    if prim.GetName() in WHEELS:
        drive = UsdPhysics.DriveAPI.Get(prim, "angular")
        drive.GetStiffnessAttr().Set(0.0)
        drive.GetDampingAttr().Set(1000.0)
        rad = WHEELS[prim.GetName()]
        drive.GetTargetVelocityAttr().Set(rad * RAD2DEG)
        print(
            f"[setup] {prim.GetName()}: velocity drive (k=0, c=1000) "
            f"target={rad:+.2f} rad/s ({rad * RAD2DEG:+.1f} deg/s)"
        )

# Play + 取 articulation ---------------------------------------------
# 預設 end_time 只 0.04s 會讓 sim 一 step 就停 — 設長一點才會持續跑物理
_tl = omni.timeline.get_timeline_interface()
_tl.set_end_time(1.0e9)
_tl.play()

iface = dc.acquire_dynamic_control_interface()
art = iface.get_articulation("/open_base/origin_link")
if art == dc.INVALID_HANDLE:
    art = iface.get_articulation("/open_base/base_link")
if art == dc.INVALID_HANDLE:
    print("[err] articulation not found — USD path 不對?")
else:
    iface.wake_up_articulation(art)

    # Drive target 已在前面 USD 層寫好；這裡只取 DOF handle 供監控讀取 -------
    dofs = {name: iface.find_articulation_dof(art, name) for name in WHEELS}

    # 註冊 update callback 印 pose ------------------------------------
    base_handle = iface.get_rigid_body("/open_base/base_link")
    state = {"step": 0, "sub": None}

    def _on_tick(_e):
        state["step"] += 1
        if state["step"] % REPORT_EVERY != 0:
            return
        wheel_now = "  ".join(
            f"{n[:5]}={iface.get_dof_velocity(dofs[n]):+.2f}" for n in WHEELS
        )
        if base_handle != dc.INVALID_HANDLE:
            pose = iface.get_rigid_body_pose(base_handle)
            lin  = iface.get_rigid_body_linear_velocity(base_handle)
            ang  = iface.get_rigid_body_angular_velocity(base_handle)
            print(
                f"[tick {state['step']:>5}] "
                f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
                f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
                f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})  {wheel_now}"
            )
        else:
            print(f"[tick {state['step']:>5}] {wheel_now}")

    # 退掉舊 subscription（如果之前 Run 過）-----------------------
    _g = globals()
    if "_openbase_tick_sub" in _g and _g["_openbase_tick_sub"] is not None:
        _g["_openbase_tick_sub"] = None

    sub = omni.kit.app.get_app().get_update_event_stream().create_subscription_to_pop(
        _on_tick, name="openbase_drive_tick"
    )
    _g["_openbase_tick_sub"] = sub
    print(f"[setup] tick subscription registered (every {REPORT_EVERY} ticks)")
    print("[done] kit 持續 step；重 Run 此檔可改速度，不需重開 Isaac")
