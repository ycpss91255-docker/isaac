"""OpenBase 2D 平面移動 — /cmd_vel 訂閱版（Script Editor in-kit）

跳過輪子物理，每 frame 直接覆寫 base_link 的 linear / angular velocity。
與 move_openbase_planar.py 同等價於 Gazebo libgazebo_ros_planar_move plugin，
差別在目標速度從模組常數改為從 ROS 2 /cmd_vel (geometry_msgs/Twist) 取得，
可在容器外用 sibling docker container live 推送。

用法:
  Script Editor → File → Open → Run；按 timeline ▶。
  容器外推 cmd_vel:

    docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 \\
        -v /home/yunchien/work/src/docker/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \\
        -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \\
        ros:humble bash -c 'source /opt/ros/humble/setup.bash &&
                            ros2 topic pub /cmd_vel geometry_msgs/Twist \\
                                "{linear: {x: 0.5}, angular: {z: 0.0}}" -r 10'

  停車: pub `{linear: {x: 0.0}, angular: {z: 0.0}}` 一次即可。

Re-Run-safe: 重 Run 時退掉舊 node + 舊 tick subscription 再建新的。
"""

import omni.kit.app
import omni.kit.commands
import omni.timeline
import omni.usd
import rclpy
from geometry_msgs.msg import Twist
from omni.isaac.dynamic_control import _dynamic_control as dc
from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics
from rclpy.node import Node


# ====== CONFIG =====================================================
# openbase_free.usda (OpenBase 專案 pre-built) 走 articulation root，
# dc.set_rigid_body_linear_velocity 寫不進去（已驗）。換 model/usd/openbase/
# openbase.usda (root free rigid body，move_openbase_planar 已驗可動)。
USD_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase.usda"
TOPIC = "/cmd_vel"
NODE_NAME = "cmd_vel_planar_subscriber"
REPORT_EVERY = 60
# 開頭多少 ticks 讓 gravity 自然 drop cube 落地，之後 disable + cmd_vel 接管。
# 180 ticks ≈ 3s @ 60Hz — 自由落體 0.27s 落地 + PhysX restitution 反彈震盪
# 需要 ~2s 被 linear/angular damping 衰減完，3s 留 1s 安全 margin。
WARMUP_TICKS = 180
# ===================================================================


WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")


def _make_node(state):
    if not rclpy.ok():
        rclpy.init()
    node = Node(NODE_NAME)

    def _cb(msg):
        state["cmd_vel"]["vx"] = float(msg.linear.x)
        state["cmd_vel"]["vy"] = float(msg.linear.y)
        state["cmd_vel"]["wz"] = float(msg.angular.z)

    sub = node.create_subscription(Twist, TOPIC, _cb, 10)
    return node, sub


# Stage setup（USD load / light / ground / wheel drive disable）
ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
stage = ctx.get_stage()
print(f"[setup] opened {USD_PATH}")

if not stage.GetPrimAtPath("/World/SunLight").IsValid():
    UsdLux.DistantLight.Define(stage, "/World/SunLight").GetIntensityAttr().Set(3000.0)
    print("[setup] sunlight added")

# Isaac 內建 GroundPlane 自帶 grid texture，白地板 vs base 直觀；先刪舊
# (不管 plain plane / Isaac grid) 再建，確保 script 重 Run 一定刷新成新版。
if stage.GetPrimAtPath("/World/GroundPlane").IsValid():
    omni.kit.commands.execute("DeletePrims", paths=["/World/GroundPlane"])
from isaacsim.core.api.objects.ground_plane import GroundPlane as IsaacGroundPlane
IsaacGroundPlane(prim_path="/World/GroundPlane", z_position=0, size=100)
print("[setup] ground plane added (Isaac grid texture)")

for prim in stage.Traverse():
    if prim.GetName() in WHEELS:
        drive = UsdPhysics.DriveAPI.Get(prim, "angular")
        drive.GetStiffnessAttr().Set(0.0)
        drive.GetDampingAttr().Set(0.0)
        drive.GetTargetVelocityAttr().Set(0.0)
        print(f"[setup] {prim.GetName()}: drive disabled")

# Gravity 處理改成 warmup-then-disable：setup 階段先讓 gravity ENABLE，
# 讓 base_link (+ DebugCube child collider) 自然落地展示物理；tick callback
# 內等 WARMUP_TICKS 後 (~1s) 再 disable，接管 cmd_vel velocity control。
# 這樣首次 demo 看到 cube 從 z=0.5 自然掉到地板上，之後不再 drift。
base_prim = stage.GetPrimAtPath("/open_base/base_link")
if base_prim.IsValid():
    physx_api = PhysxSchema.PhysxRigidBodyAPI.Apply(base_prim)
    physx_api.GetDisableGravityAttr().Set(False)  # warmup 階段先 ENABLE
    # 高 damping 讓落地反彈的震盪能量快速被吃掉。LinearDamping=1.0 大約
    # 1/sec 衰減 → 0.5m 自由落體後 1-2 秒內彈跳衰減 < 1cm 視覺不可察。
    # AngularDamping=5.0 殺掉落地時的歪斜旋轉。cmd_vel 階段 velocity 是
    # 直接覆寫，damping 對 cmd_vel 控制無影響。
    physx_api.CreateLinearDampingAttr().Set(1.0)
    physx_api.CreateAngularDampingAttr().Set(5.0)
    print("[setup] base_link: gravity ENABLED for warmup drop, damping set")

cube_path = "/open_base/base_link/DebugCube"
# 刪舊再建，確保重 Run 一定刷新（含 CollisionAPI）
if stage.GetPrimAtPath(cube_path).IsValid():
    omni.kit.commands.execute("DeletePrims", paths=[cube_path])
cube = UsdGeom.Cube.Define(stage, cube_path)
cube.GetSizeAttr().Set(0.3)
# 初始放在 z=+0.5（cube 底面 z=0.35，離地板 35cm）。配合 setup 階段
# gravity ENABLED + tick callback warmup phase，cube 會自然落體到地板上
# 再 PhysX 接觸停住，~1s 後 tick == WARMUP_TICKS disable gravity 鎖 z，
# 之後 cmd_vel 接管 velocity control。
cube.AddTranslateOp().Set(Gf.Vec3f(0.0, 0.0, 0.5))
UsdGeom.Gprim(cube).GetDisplayColorAttr().Set([Gf.Vec3f(0.9, 0.15, 0.15)])
# base_link import_urdf.py 沒 import 進 STL collision，base_link 是空 Xform
# 沒 collider。加 CollisionAPI 在 DebugCube 上，讓它兼任「base 物理外殼 +
# 視覺代理」— base_link 移動帶著 DebugCube 跟其他剛體做接觸。同時保留
# RigidBodyAPI 不放（cube 不是獨立 rigid body，它的 transform 跟 parent
# base_link 連動）。
UsdPhysics.CollisionAPI.Apply(stage.GetPrimAtPath(cube_path))
print("[setup] debug cube (red) attached to base_link with CollisionAPI")

# Task #56 collision verification — 在 base 路徑上放一個 1kg 藍色障礙物 cube
# (有 RigidBodyAPI + CollisionAPI + MassAPI)，每次 Run 刷新位置到 x=3.0。
# 預期：base 推 cmd_vel +0.5 m/s 移到 x≈3 時撞到 → 障礙物被推走 → 證明
# Model A 設定下 base_link 的 collider 仍然活躍能跟其他 rigid body 物理互動。
obstacle_path = "/World/CollisionObstacle"
if stage.GetPrimAtPath(obstacle_path).IsValid():
    omni.kit.commands.execute("DeletePrims", paths=[obstacle_path])
obstacle = UsdGeom.Cube.Define(stage, obstacle_path)
obstacle.GetSizeAttr().Set(0.3)
obstacle.AddTranslateOp().Set(Gf.Vec3f(3.0, 0.0, 0.15))
UsdGeom.Gprim(obstacle).GetDisplayColorAttr().Set([Gf.Vec3f(0.15, 0.4, 0.9)])
obstacle_prim = stage.GetPrimAtPath(obstacle_path)
UsdPhysics.RigidBodyAPI.Apply(obstacle_prim)
UsdPhysics.CollisionAPI.Apply(obstacle_prim)
mass_api = UsdPhysics.MassAPI.Apply(obstacle_prim)
# base_link 從 openbase_minimal.urdf 帶來的 mass 只有 0.0786 kg；
# 藍 cube 設 1kg 時 base momentum 不足以突破地面靜摩擦門檻，cube 推不動。
# 設 0.05kg (50g) 比 base 還輕，碰撞會直接推飛它。
mass_api.GetMassAttr().Set(0.05)
print("[setup] collision obstacle (blue cube, 50g dynamic) added at x=3.0")


# Retire previous node + tick subscription (rerun-safe)
_g = globals()

old_state = _g.get("_cmd_vel_state")
if old_state is not None:
    try:
        old_state["node"].destroy_node()
    except Exception as exc:
        print(f"[cmd_vel] previous node destroy ignored: {exc}")
    _g["_cmd_vel_state"] = None

old_tick = _g.get("_cmd_vel_tick_sub")
if old_tick is not None:
    _g["_cmd_vel_tick_sub"] = None


# Prefixed dict name so co-loading sibling smoke scripts in the same
# Script Editor namespace cannot clobber state — the tick callback
# below looks `_cmd_vel_state` up via globals on every fire.
_cmd_vel_state = {
    "node": None,
    "sub": None,
    "cmd_vel": {"vx": 0.0, "vy": 0.0, "wz": 0.0},
    "step": 0,
}
_node, _sub = _make_node(_cmd_vel_state)
_cmd_vel_state["node"] = _node
_cmd_vel_state["sub"] = _sub


_iface = dc.acquire_dynamic_control_interface()


def _on_cmd_vel_tick(_event):
    s = _cmd_vel_state
    s["step"] += 1
    rclpy.spin_once(s["node"], timeout_sec=0.0)

    base = _iface.get_rigid_body("/open_base/base_link")
    if base == dc.INVALID_HANDLE:
        return  # PhysX 還沒 init 完

    # Warmup 階段：前 WARMUP_TICKS frames 不覆寫 velocity，讓 gravity 自然
    # 把 base + DebugCube collider 掉到地板上，PhysX collision response 接住。
    if s["step"] < WARMUP_TICKS:
        return

    # 剛走完 warmup → disable gravity 鎖住 z，後續 cmd_vel velocity 接管
    if s["step"] == WARMUP_TICKS:
        bp = stage.GetPrimAtPath("/open_base/base_link")
        if bp.IsValid():
            PhysxSchema.PhysxRigidBodyAPI.Apply(bp).GetDisableGravityAttr().Set(True)
            print(f"[warmup] tick {s['step']}: gravity disabled, cmd_vel control active")

    cv = s["cmd_vel"]
    _iface.set_rigid_body_linear_velocity(base, (cv["vx"], cv["vy"], 0.0))
    _iface.set_rigid_body_angular_velocity(base, (0.0, 0.0, cv["wz"]))

    if s["step"] % REPORT_EVERY != 0:
        return
    pose = _iface.get_rigid_body_pose(base)
    lin = _iface.get_rigid_body_linear_velocity(base)
    ang = _iface.get_rigid_body_angular_velocity(base)
    print(
        f"[tick {s['step']:>5}] "
        f"cmd=({cv['vx']:+.2f},{cv['vy']:+.2f},w={cv['wz']:+.2f}) "
        f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
        f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
        f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})"
    )


_tick = (
    omni.kit.app.get_app()
    .get_post_update_event_stream()
    .create_subscription_to_pop(_on_cmd_vel_tick, name="cmd_vel_planar_tick")
)
_g["_cmd_vel_tick_sub"] = _tick
_g["_cmd_vel_state"] = _cmd_vel_state


_tl = omni.timeline.get_timeline_interface()
_tl.set_end_time(1.0e9)
_tl.play()

print(f"[cmd_vel] subscribed {TOPIC}; initial cmd = (0.0, 0.0, w=0.0) — base 不會動，直到推 /cmd_vel")
print("[cmd_vel] drive from sibling container:")
print("  docker run --rm --net=host --ipc=host -e ROS_DOMAIN_ID=0 \\")
print("      -v /home/yunchien/work/src/docker/config/ros2/fastdds.xml:/isaac-sim/fastdds.xml:ro \\")
print("      -e FASTRTPS_DEFAULT_PROFILES_FILE=/isaac-sim/fastdds.xml \\")
print("      ros:humble bash -c 'source /opt/ros/humble/setup.bash && \\")
print("                          ros2 topic pub /cmd_vel geometry_msgs/Twist \\")
print("                              \"{linear: {x: 0.5}}\" -r 10'")
