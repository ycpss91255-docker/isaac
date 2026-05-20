# Standalone-with-Livestream Workflow

> 跑 driver script 的日常流程。`SimulationApp({"headless": True, "livestream": 2})` 從 host CLI 起 Kit + 開 WebRTC livestream;瀏覽器隨開隨關,不影響 sim;Ctrl-C 乾淨退場。
>
> Driver 走這條的代表:`script/forklift_blocky_driver_wip.py`(Model A-hybrid demo)+ `script/standalone_livestream_smoke.py`(最小 sanity check)。
>
> 為什麼選這條 vs 過去的 in-kit Script Editor:見 `adr/0005-standalone-with-livestream-as-default-dev-entrypoint.md`。
> 過去 in-kit Script Editor 日常 SOP 留在 `cmd_vel_inkit_teleop.md` 當歷史參考(已標 legacy)。

---

## 前置條件

### 1. `ycpss91255-docker/isaac` image 已 build

```bash
cd isaac_ws/src/docker
./build.sh                # 第一次或改 Dockerfile 後
```

### 2. 把 `headless` container 起來(porting:host 8011 → container WebRTC)

```bash
./run.sh -t headless -d
docker ps --filter name=yunchien-isaac-headless --format '{{.Names}} {{.Status}}'
```

預期看到 `yunchien-isaac-headless Up ...`。

### 3.(可選)用 smoke driver 驗 livestream 通了

```bash
./exec.sh -t headless /isaac-sim/python.sh \
    /home/yunchien/work/src/script/standalone_livestream_smoke.py
```

預期:30 秒內印 `[smoke] tick ...`、最後 `[smoke] DONE`、`Simulation App Shutting Down`,exit 0。
這段期間瀏覽器開 `http://localhost:8011/streaming/webrtc-client` 應看得到一個 cube + ground plane + light。

---

## 跑 driver

### 一般流程

```bash
cd isaac_ws/src/docker
./exec.sh -t headless /isaac-sim/python.sh \
    /home/yunchien/work/src/script/forklift_blocky_driver_wip.py
```

- Kit 起動約 5–10 秒(看到 `[forklift-Ah] stage opened` 表示 USD 載完)。
- 之後 driver 進入 spin loop,每 tick 寫一次 `sim_app.update()`,印 demo cycle 進度。
- 要看畫面:瀏覽器開 `http://localhost:8011/streaming/webrtc-client`。連線 / 關閉 / 重連 都不影響 driver。
- 要結束:該 terminal `Ctrl-C` 一下。Driver 攔 SIGINT,印 `signal received — requesting clean exit`,接 `Simulation App Shutting Down`,exit 0。

### 背景跑(放著掛機看 demo cycle)

```bash
nohup ./exec.sh -t headless /isaac-sim/python.sh \
    /home/yunchien/work/src/script/forklift_blocky_driver_wip.py \
    > /tmp/forklift.out 2>&1 &
echo $! > /tmp/forklift.pid
```

收掉:`kill $(cat /tmp/forklift.pid)` — SIGTERM,同樣攔到走乾淨 shutdown。

### 限時跑(自動驗證 / CI 用)

```bash
timeout 75 ./exec.sh -t headless /isaac-sim/python.sh \
    /home/yunchien/work/src/script/forklift_blocky_driver_wip.py
```

`timeout` 到時送 SIGTERM,driver 同樣攔到 → 乾淨退場。exit code 124(timeout)或 143(SIGTERM)都算 "timeout 結束",不代表 fail。

---

## 寫新 driver 的 skeleton

```python
"""<short description>."""

import signal
import sys
import time
from pathlib import Path

# All "static config" before SimulationApp boot — file paths, constants,
# the _log helper. Anything that needs Kit-side modules must come after.

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT  = SCRIPT_DIR.parent
USD_PATH   = str(REPO_ROOT / "model" / "usd" / "<robot>" / "<robot>.usda")
LOG_PATH   = str(SCRIPT_DIR / "<name>.log")


def _log(msg):
    print(msg, flush=True)
    try:
        with open(LOG_PATH, "a") as f:
            f.write(msg + "\n")
    except Exception:
        pass


from isaacsim import SimulationApp  # noqa: E402

sim_app = SimulationApp({"headless": True, "livestream": 2})

# Kit-side imports go after SimulationApp() — they load Kit modules.
import omni.usd                                                    # noqa: E402
import omni.timeline                                                # noqa: E402
from omni.isaac.dynamic_control import _dynamic_control as dc      # noqa: E402

stop_requested = False


def _handle_signal(_signum, _frame):
    global stop_requested
    stop_requested = True
    _log("[driver] signal received — requesting clean exit")


signal.signal(signal.SIGINT,  _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)

# ---- driver setup (open stage, resolve handles, etc.) ----
ctx = omni.usd.get_context()
ctx.open_stage(USD_PATH)
# ... your setup ...

tl = omni.timeline.get_timeline_interface()
tl.set_end_time(1.0e9)
tl.play()                     # only if PhysX simulation is needed

# ---- main loop ----
exit_code = 0
try:
    while sim_app.is_running():
        if stop_requested:
            break
        # ... per-tick driver work ...
        sim_app.update()
except Exception as exc:
    _log(f"[driver] FATAL: {exc!r}")
    exit_code = 1
finally:
    _log("[driver] shutting down")
    sim_app.close()

sys.exit(exit_code)
```

關鍵點:

- `SimulationApp(...)` **一定要先於**任何 `omni.*` / `pxr.*` import。
- 所有 path 用 `Path(__file__).resolve().parent` 推算,**不要硬編** `/home/yunchien/work/src/...`。容器 mount 路徑、host 路徑、worktree 路徑都可能不同。
- SIGINT / SIGTERM handler **必裝**,否則 `Ctrl-C` 會半路死掉,Kit 留半開檔。
- `tl.play()` 只在要 PhysX 模擬時呼叫。純 visual demo 可以不呼叫,sim_app.update() 仍會 tick render。

---

## 常見問題

### `ModuleNotFoundError: No module named 'isaacsim'`

漏寫 `from isaacsim import SimulationApp` 或寫在 `omni.*` import 之後。SimulationApp 一定 import + 呼叫於最前。

### `[Warning] [carb.scenerenderer-rtx.plugin] Failed to create NGX context`

無害。headless container 沒 NGX driver feature,livestream 仍能跑。

### 瀏覽器看到一片黑

通常是 livestream 連上去太早,Kit 還在初始化。等 10 秒重新整理一下。或先 `./exec.sh ... smoke.py` 跑 smoke 確認 livestream 真的開了。

### `set_kinematic_target` AttributeError

`omni.isaac.dynamic_control` 在某些 Isaac 版本沒有 `set_kinematic_target`。Driver 應該 fallback:

```python
if hasattr(iface, "set_kinematic_target"):
    iface.set_kinematic_target(h, target)
else:
    iface.set_rigid_body_pose(h, target)
```

也建議同時寫一次 `xformOp:translate`(USD attr),Hydra 不一定 auto-sync kinematic body 到 USD 給 viewport。

### Driver 卡住沒 print,瀏覽器看 sim 動但 stdout 沒東西

通常是 `print()` 沒 `flush=True`。改用 `print(msg, flush=True)` 或上面 skeleton 的 `_log` helper(內建 flush)。

---

## 跟舊 in-kit Script Editor 流程的對照

| 步驟 | 舊 in-kit | 新 standalone-livestream |
|---|---|---|
| 起 Kit | `./run.sh -t headless -d` + 瀏覽器開 `localhost:8011` 看 Kit GUI | `./run.sh -t headless -d` |
| 載 driver | 瀏覽器 GUI 開 Script Editor 拖 `.py` 進去 | `./exec.sh -t headless /isaac-sim/python.sh <script>` |
| 跑 | Ctrl+Enter on Script Editor | enter 在 terminal |
| 看畫面 | 同一個 Kit GUI 瀏覽器 tab | 瀏覽器開 `localhost:8011/streaming/webrtc-client`(可關可開) |
| 改完重跑 | 編輯 → Script Editor 重 Ctrl+Enter | 編輯 → terminal 重跑 command |
| LLM agent 可驅動 | 否(要人手點 Ctrl+Enter) | 是(`./exec.sh` 是 docker exec,LLM 可呼叫) |

舊流程沒被移除 — `cmd_vel_inkit_teleop.md` 保留當歷史參考。但**新 driver 不要再走舊路**,除非有非寫不可的理由(例如:driver 要在 stage 已開的 GUI session 裡做互動式偵錯)。

---

## 相關文件

- `adr/0005-standalone-with-livestream-as-default-dev-entrypoint.md` — 這條路徑的決策依據
- `adr/0002-cmd-vel-teleop-via-in-kit-script-editor.md` — 舊 in-kit 流程的決策依據(2026-05-20 之後僅為歷史)
- `cmd_vel_inkit_teleop.md` — 舊 in-kit 日常 SOP(legacy)
- `action_graph_setup.md` — 更早期 Action Graph 一次性 GUI SOP(deprecated)
- `script/standalone_livestream_smoke.py` — 最小 sanity driver(`SimulationApp + livestream:2` 開合 / 30s spin / exit 0)
- `script/forklift_blocky_driver_wip.py` — Model A-hybrid 完整 demo(51s pickup cycle)
