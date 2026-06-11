# IsaacDriver Base Class: Lifecycle-Only Pattern

4 個 driver script 共享 ~60 行 boilerplate（SimulationApp init、signal handler、stage open、scene defaults、shutdown）。隨著 Docker stage 整合（ycpss91255-docker/isaac#28）引入 `ISAAC_LIVESTREAM` env var，需要一個共用入口讀取該 env var 並配置 `SimulationApp`。直接在 4 個 driver 各自 patch 是 copy-paste — 應該抽 base class。

**Decision**: 採 **Lifecycle-Only Pattern**（Pattern B）— base class 管 init/shutdown lifecycle，subclass 完全控制 main loop。

## Considered Options

- **(a) Template Method (Pattern A)** — base class 擁有 main loop，subclass override `tick()` hook，base class 每 tick 呼叫 `tick()` → `app.update()`
- **(b) Lifecycle-Only (Pattern B)** (**選此**) — base class 管 init（SimulationApp、signal、stage open、scene defaults、timeline）和 shutdown（`app.close()`），subclass override `main()` 完全控制 loop body

## Why (b)

業界調查：Isaac 生態系一致用 Pattern B。

| Framework | Pattern | Loop 誰控制 |
|---|---|---|
| IsaacLab `AppLauncher` | B | User 寫 `while app.is_running(): sim.step()` |
| Isaac Sim standalone examples | B | User 寫 `while app.is_running(): app.update()` |
| Gymnasium `Env` | B | User 寫 training loop |
| PyBullet | B | User 寫 physics loop |
| ROS 2 LifecycleNode | A | Framework executor 控制（有自己的 runtime） |
| Unity ML-Agents | A | Unity engine 控制（有自己的 runtime） |

Pattern A 適合有自己 runtime engine 的框架（ROS 2 executor、Unity engine）。Isaac Sim 沒有 — Kit 的 `app.update()` 是被動呼叫，不是 framework-driven event loop。

實際問題：4 個 driver 有兩種 update 模式（`app.update()` vs `world.step(render=True)`），Pattern A 的 base class 無法統一呼叫哪個 — 要嘛加 flag 區分，要嘛 subclass 繞過 base class 的 tick 順序。Pattern B 直接把 loop 交給 subclass，沒有這個問題。

## Key Sub-Decisions

### rclpy signal handler: helper method（不是 auto-flag）

Isaac Sim 5.1 的 3-way signal handler 衝突（Kit handler + driver handler + rclpy handler）會導致 segfault。Base class 提供 `init_rclpy()` 讓 subclass 在 `setup()` 中顯式呼叫，而非 `use_rclpy = True` auto-flag。理由：subclass 控制 init 時機（先 `init_rclpy()` 才能 `Node()`），顯式呼叫比隱式 flag 清楚。

### USD 路徑: repo-relative（不是絕對 hardcode）

現有 3/4 driver hardcode `/home/yunchien/work/src/model/...`，綁死容器 mount 點。改為 subclass 設 repo-relative path（如 `"model/usd/robot/camera_bot/camera_bot.usda"`），base class 從 `__file__` 推算 repo root 後 resolve。

### Scene defaults: base class 預設補建（opt-out）

3/4 driver 在 stage open 後補建 SunLight + GroundPlane。Base class 預設補建，先 `GetPrimAtPath().IsValid()` 檢查再建 — 已存在時 skip，對自帶 scene 的 USD（如 camera-bot example）無副作用。

### 模組位置: `script/isaac_driver.py`（flat）

跟現有 `camera_setup.py` 同級。當 `script/` 下 helper 超過 2 個時重構為 `script/lib/` 子目錄。

## Consequences

- 新 driver 只需 class + `USD` + `setup()` + `main()` 起步，不再複製 60 行 boilerplate
- `ISAAC_LIVESTREAM` 邏輯集中在 `create_sim_app()`，Docker stage 切換自動生效
- Signal handling / stage open / shutdown 的 bug fix 只改一處
- `main()` 提供預設實作（simple `app.update()` loop），但預期多數 driver 會 override

## Cross-references

- **ycpss91255-docker/isaac#28**: Docker stage 整合（headless / headless-stream），`ISAAC_LIVESTREAM` env var 來源
- **ycpss91255/isaac#23**: 實作 issue
- **ADR-0007**: custom streaming Kit experience（`isaacsim.exp.base.python.streaming.kit`），由 `create_sim_app()` 在 `ISAAC_LIVESTREAM=2` 時自動選用
- **ADR-0008**: L2/L3 physics level vocabulary — `cmd_vel_planar_standalone_l2.py` 是首個 L2 driver，將由 `IsaacDriver` 重構

## Editorial note (2026-06-11)

Incidental application-specific example names in this ADR were replaced with generic wording (camera-bot example) as part of the base-repo convergence (ADR-0017, #128). Decision content is unchanged (the `USD` class attr is replaced by `SCENE` per ADR-0017 section 9, recorded there); the original wording is preserved in git history.
