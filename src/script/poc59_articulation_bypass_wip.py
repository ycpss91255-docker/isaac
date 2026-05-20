"""Task #59 PoC — 完整 articulation USD (openbase_free.usda) 上 dc.velocity bypass 嘗試

目標：驗證能否讓 dc.set_rigid_body_linear_velocity 在完整 mecanum articulation USD
上真的把 base_link 推動（之前 cmd_vel_planar_move.py 試過 lin=0 表示不通）。

用法：
    Script Editor → File → Open → 改下面 MODE → Ctrl+Enter
    觀察 [poc59-X] tick N pos.x — pos.x 是否從 0 線性增加。

四個 MODE：
    "A": 只關 wheel drive + base_link disableGravity (= cmd_vel_planar_move 同設定，預期 fail)
    "B": A + disable articulation root (PhysxArticulationAPI:articulationEnabled=False)
    "C": isaacsim.core.api.World + SingleRigidPrim (新 NVIDIA API)
    "D": B 同樣 disable articulation,但用 dc.set_rigid_body_pose 直接 teleport (繞過 PhysX integration)
"""

# ====== 改這裡切換路徑 =====================================================
MODE = "D"   # "A" / "B" / "C"
# ============================================================================

USD_PATH = "/home/yunchien/work/src/OpenBase/openbase_free.usda"
TARGET_VX = 0.5
WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")

import omni.kit.app
import omni.timeline
import omni.usd
from pxr import PhysxSchema, UsdLux, UsdPhysics


print(f"[poc59-{MODE}] starting; USD={USD_PATH}")

# 退掉之前在 Script Editor 跑過的 cmd_vel_planar_move / move_openbase_planar
# 留下的 subscription + rclpy node — 不然他們的 tick callback 還會持續
# overwrite base velocity 蓋掉本 PoC 寫的值。
#
# cmd_vel_planar_move.py 把同一個 carb subscription 同時存到 `_tick` 與
# `_cmd_vel_tick_sub` 兩個 global,只 set 一個成 None GC 不掉,舊 callback 還會
# fire — 所以兩個名字都要清,且優先 call .unsubscribe() 明確解綁。
_g = globals()
for name in (
    "_cmd_vel_tick_sub",
    "_tick",
    "_planar_tick_sub",
    "_poc59_tick_sub",
):
    sub = _g.get(name)
    if sub is None:
        continue
    try:
        if hasattr(sub, "unsubscribe"):
            sub.unsubscribe()
    except Exception as exc:
        print(f"[poc59-{MODE}] unsubscribe {name} ignored: {exc}")
    _g[name] = None
    print(f"[poc59-{MODE}] retired old subscription: {name}")
_cv_state = _g.get("_cmd_vel_state")
if _cv_state is not None and _cv_state.get("node") is not None:
    try:
        _cv_state["node"].destroy_node()
        print("[poc59] destroyed old cmd_vel rclpy node")
    except Exception as exc:
        print(f"[poc59] destroy_node ignored: {exc}")
    _g["_cmd_vel_state"] = None

ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
print(f"[poc59-{MODE}] opened stage")

# 加燈
if not stage.GetPrimAtPath("/World/SunLight").IsValid():
    UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(3000.0)

# 共用：wheel drive 全關 + base_link disableGravity
for prim in stage.Traverse():
    if prim.GetName() in WHEELS:
        drive = UsdPhysics.DriveAPI.Get(prim, "angular")
        drive.GetStiffnessAttr().Set(0.0)
        drive.GetDampingAttr().Set(0.0)
        drive.GetTargetVelocityAttr().Set(0.0)

base_prim = stage.GetPrimAtPath("/open_base/base_link")
if base_prim.IsValid():
    PhysxSchema.PhysxRigidBodyAPI.Apply(base_prim).GetDisableGravityAttr().Set(True)
    print(f"[poc59-{MODE}] base_link gravity disabled")


# === MODE-specific setup ===================================================
if MODE in ("B", "D"):
    # 找 articulation root,disable articulation。MODE B 用 velocity 寫入 (失敗:
    # disable articulation = PhysX 不再 integrate body,velocity 設了沒人推);
    # MODE D 改用 dc.set_rigid_body_pose teleport,bypass integration。
    found_root_BD = False
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            art_api = PhysxSchema.PhysxArticulationAPI.Apply(prim)
            attr = art_api.GetArticulationEnabledAttr()
            if not attr.IsValid():
                attr = art_api.CreateArticulationEnabledAttr()
            attr.Set(False)
            print(f"[poc59-{MODE}] articulation root {prim.GetPath()} disabled")
            found_root_BD = True
    if not found_root_BD:
        print(f"[poc59-{MODE}] WARN no articulation root via UsdPhysics.ArticulationRootAPI")

# === Velocity write loop ===================================================
if MODE in ("A", "B"):
    from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
    iface = dc.acquire_dynamic_control_interface()

    state = {"step": 0}

    def _tick(_e):
        state["step"] += 1
        base = iface.get_rigid_body("/open_base/base_link")
        if base == dc.INVALID_HANDLE:
            return
        iface.set_rigid_body_linear_velocity(base, (TARGET_VX, 0.0, 0.0))
        iface.set_rigid_body_angular_velocity(base, (0.0, 0.0, 0.0))
        if state["step"] % 60 != 0:
            return
        pose = iface.get_rigid_body_pose(base)
        lin = iface.get_rigid_body_linear_velocity(base)
        print(
            f"[poc59-{MODE}] tick {state['step']:>5} "
            f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
            f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f})"
        )

elif MODE == "C":
    import numpy as np  # noqa: E402
    from isaacsim.core.api import World  # noqa: E402
    from isaacsim.core.prims import SingleRigidPrim  # noqa: E402

    # World 初始化（in-kit 用法，timeline.play 由它管）
    world = World()
    world.reset()
    base_obj = SingleRigidPrim("/open_base/base_link")

    state = {"step": 0}

    def _tick(_e):
        state["step"] += 1
        try:
            base_obj.set_linear_velocity(np.array([TARGET_VX, 0.0, 0.0]))
            base_obj.set_angular_velocity(np.array([0.0, 0.0, 0.0]))
        except Exception as exc:
            if state["step"] == 1:
                print(f"[poc59-C] set_linear_velocity raised: {exc}")
            return
        if state["step"] % 60 != 0:
            return
        pos, _orn = base_obj.get_world_pose()
        lin = base_obj.get_linear_velocity()
        print(
            f"[poc59-C] tick {state['step']:>5} "
            f"pos=({pos[0]:+.2f},{pos[1]:+.2f},{pos[2]:+.2f}) "
            f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f})"
        )

elif MODE == "D":
    # MODE D: B 的 articulation disable 已在上面 ("B","D") 區塊跑過。這裡不用
    # velocity API,改 dc.set_rigid_body_pose 每 tick 直接 teleport。
    # 假設 60 FPS — 用 step/60 當經過時間 s。pos.x = init_x + TARGET_VX * t。
    from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
    iface = dc.acquire_dynamic_control_interface()

    state = {"step": 0, "init_p": None}

    def _tick(_e):
        state["step"] += 1
        base = iface.get_rigid_body("/open_base/base_link")
        if base == dc.INVALID_HANDLE:
            return
        if state["init_p"] is None:
            p0 = iface.get_rigid_body_pose(base)
            state["init_p"] = (p0.p[0], p0.p[1], p0.p[2])
            print(
                f"[poc59-D] init pose captured: "
                f"({state['init_p'][0]:+.2f},{state['init_p'][1]:+.2f},{state['init_p'][2]:+.2f})"
            )
        t = state["step"] / 60.0
        ix, iy, iz = state["init_p"]
        target = dc.Transform()
        target.p = (ix + TARGET_VX * t, iy, iz)
        target.r = (0.0, 0.0, 0.0, 1.0)  # identity quat xyzw
        iface.set_rigid_body_pose(base, target)
        if state["step"] % 60 != 0:
            return
        pose = iface.get_rigid_body_pose(base)
        print(
            f"[poc59-D] tick {state['step']:>5} "
            f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
            f"t={t:.2f}s expect_x={ix + TARGET_VX * t:+.2f}"
        )

else:
    raise ValueError(f"unknown MODE: {MODE}")


# Re-Run safe — 退掉舊 subscription
_g = globals()
old = _g.get("_poc59_tick_sub")
if old is not None:
    _g["_poc59_tick_sub"] = None

_sub = (
    omni.kit.app.get_app()
    .get_post_update_event_stream()
    .create_subscription_to_pop(_tick, name=f"poc59_{MODE}_tick")
)
_g["_poc59_tick_sub"] = _sub

if MODE != "C":  # World() 已自己 play
    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()

print(f"[poc59-{MODE}] tick subscription registered; observe pos.x for next 5+ seconds")
print(f"[poc59-{MODE}] PASS = pos.x linear increase ~{TARGET_VX} m/s; FAIL = pos.x stays 0")



