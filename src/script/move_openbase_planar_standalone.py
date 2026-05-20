"""OpenBase 2D 平面移動 — hardcoded CMD_VX/VY/WZ standalone 版

跟 move_openbase_planar.py 相同邏輯（Gazebo planar_move 等價：跳過輪子物理，
每 frame 直接覆寫 base_link 的 linear / angular velocity），但用 SimulationApp +
主迴圈，不依賴 Script Editor。透過 /isaac-sim/python.sh 直接啟動，Ctrl+C 乾淨退出。

用法（容器啟動 + 進容器跑）:
    ./run.sh -t standalone -d
    ./exec.sh -t standalone /isaac-sim/python.sh \\
        /home/yunchien/work/src/script/move_openbase_planar_standalone.py

換目標速度（與 in-kit 版本相同 pattern）:
    編輯本檔 CMD_VX / CMD_VY / CMD_WZ → 重 run 此 script 即可。
    停車：把 3 個都設 0.0 重 run。

注意:
    - base 仍受重力 / 接觸支撐力，所以 z 方向自然停在地板上
    - 輪子在 viewport 看起來不轉是預期 — 它們已經被 disable
    - 真的位移會在 base.pos.x / pos.y 看到變化
"""

import os
import signal
import sys

# SimulationApp must be the first instantiation — all kit / omni / pxr
# imports must come AFTER, otherwise modules resolve before kit's plugin
# manager registers them and binding errors result.
from isaacsim import SimulationApp


# livestream=2 → WebRTC streaming (Isaac Sim 5.1 default streaming proto);
# headless=False keeps the renderer alive so WebRTC client can connect to
# localhost:8211/streaming/webrtc-client.
APP = SimulationApp({
    "headless": False,
    "livestream": 2,
    "renderer": "RaytracedLighting",
})

# SimulationApp installs its own SIGINT handler that swallows Ctrl+C, so
# Python's KeyboardInterrupt never fires from the main while-loop.
# Override with our own flag-setting handler AFTER SimulationApp init —
# the main loop checks _SHOULD_QUIT each tick and breaks out cleanly.
_SHOULD_QUIT = False


def _signal_handler(_signum, _frame):
    global _SHOULD_QUIT
    print("[planar] SIGINT/SIGTERM — requesting shutdown", flush=True)
    _SHOULD_QUIT = True


signal.signal(signal.SIGINT, _signal_handler)
signal.signal(signal.SIGTERM, _signal_handler)


# Imports below depend on the kit app being alive.
import omni.kit.commands  # noqa: E402
import omni.timeline  # noqa: E402
import omni.usd  # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc  # noqa: E402
from pxr import PhysxSchema, UsdLux, UsdPhysics  # noqa: E402

# WebRTC viewport 不走 standalone — 已實測 `isaacsim.exp.base.python.kit`
# experience 即使 `enable_extension("omni.kit.livestream.webrtc")` 也起不
# 來完整 chain。要看畫面用 `./run.sh -t headless -d` (用
# `isaacsim.exp.full.streaming.kit`，內建 WebRTC + Script Editor)，
# 對應 in-kit 版 move_openbase_planar.py。Standalone 版定位是「跑邏輯看
# 終端輸出」的純驗證路徑。


# ====== CONFIG =====================================================
USD_PATH = "/home/yunchien/work/src/model/usd/openbase/openbase.usda"

# 目標 base velocity (世界坐標 / base 朝向 — 視 base 初始 yaw 而定)
CMD_VX = 0.5    # m/s, +x
CMD_VY = 0.0    # m/s, +y
CMD_WZ = 0.0    # rad/s, yaw

REPORT_EVERY = 60
# ===================================================================


WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")


def _stage_setup():
    # Fail fast on missing USD; spin OPENED with timeout. See
    # cmd_vel_planar_standalone._stage_setup for full reasoning.
    if not os.path.exists(USD_PATH):
        raise FileNotFoundError(
            f"USD not found: {USD_PATH}\nRun import_urdf.py to generate it."
        )
    ctx = omni.usd.get_context()
    if not ctx.open_stage(USD_PATH):
        raise RuntimeError(f"open_stage() returned False for {USD_PATH}")
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        APP.update()
    else:
        raise RuntimeError("stage did not transition to OPENED within 600 ticks")
    stage = ctx.get_stage()
    print(f"[setup] opened {USD_PATH}", flush=True)

    if not stage.GetPrimAtPath("/World/SunLight").IsValid():
        UsdLux.DistantLight.Define(
            stage, "/World/SunLight"
        ).GetIntensityAttr().Set(3000.0)
        print("[setup] sunlight added", flush=True)

    if not stage.GetPrimAtPath("/World/GroundPlane").IsValid():
        # Isaac 內建 GroundPlane 自帶 grid texture (淺灰深灰交錯方塊) +
        # CollisionAPI，比手工 plain plane 直觀。白地板看不到 base 平移時改這個。
        from isaacsim.core.api.objects.ground_plane import GroundPlane as IsaacGroundPlane
        IsaacGroundPlane(prim_path="/World/GroundPlane", z_position=0, size=100)
        print("[setup] ground plane added (Isaac grid texture)", flush=True)

    for prim in stage.Traverse():
        if prim.GetName() in WHEELS:
            drive = UsdPhysics.DriveAPI.Get(prim, "angular")
            drive.GetStiffnessAttr().Set(0.0)
            # 關鍵：damping=0 = 完全自由旋轉
            drive.GetDampingAttr().Set(0.0)
            drive.GetTargetVelocityAttr().Set(0.0)
            print(f"[setup] {prim.GetName()}: drive disabled", flush=True)

    # set_rigid_body_linear_velocity 每 tick 在 APP.update() 之後寫入；
    # PhysX 的 substep 已經把 gravity 累積到 pos.z (-0.16 m/s 觀察值)，
    # 才被 v.z=0 清掉。最乾淨的修法：disable gravity on base_link，
    # 維持「Gazebo planar_move 等效 = 整台車 SE(2) 平移、z 不變」語意。
    base_prim = stage.GetPrimAtPath("/open_base/base_link")
    if base_prim.IsValid():
        physx_api = PhysxSchema.PhysxRigidBodyAPI.Apply(base_prim)
        physx_api.GetDisableGravityAttr().Set(True)
        print("[setup] base_link: gravity disabled", flush=True)


def main():
    _stage_setup()

    iface = dc.acquire_dynamic_control_interface()

    tl = omni.timeline.get_timeline_interface()
    tl.set_end_time(1.0e9)
    tl.play()

    print(
        f"[cmd]   target vel = ({CMD_VX:+.2f}, {CMD_VY:+.2f}, "
        f"w={CMD_WZ:+.2f})",
        flush=True,
    )
    print(
        "[planar] standalone running; Ctrl+C 乾淨退出。"
        "改 CMD_VX/VY/WZ 後重 run 此 script 換目標速度",
        flush=True,
    )

    step = 0
    try:
        while APP.is_running() and not _SHOULD_QUIT:
            APP.update()
            step += 1

            base = iface.get_rigid_body("/open_base/base_link")
            if base == dc.INVALID_HANDLE:
                continue  # PhysX 還沒 init 完，下個 frame 再試

            iface.set_rigid_body_linear_velocity(base, (CMD_VX, CMD_VY, 0.0))
            iface.set_rigid_body_angular_velocity(base, (0.0, 0.0, CMD_WZ))

            if step % REPORT_EVERY != 0:
                continue
            pose = iface.get_rigid_body_pose(base)
            lin = iface.get_rigid_body_linear_velocity(base)
            ang = iface.get_rigid_body_angular_velocity(base)
            print(
                f"[tick {step:>5}] "
                f"cmd=({CMD_VX:+.2f},{CMD_VY:+.2f},w={CMD_WZ:+.2f}) "
                f"pos=({pose.p[0]:+.2f},{pose.p[1]:+.2f},{pose.p[2]:+.2f}) "
                f"lin=({lin[0]:+.2f},{lin[1]:+.2f},{lin[2]:+.2f}) "
                f"ang=({ang[0]:+.2f},{ang[1]:+.2f},{ang[2]:+.2f})",
                flush=True,
            )
    except KeyboardInterrupt:
        print("[planar] KeyboardInterrupt — shutting down", flush=True)
    finally:
        APP.close()


if __name__ == "__main__":
    sys.exit(main())
