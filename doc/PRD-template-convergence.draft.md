# PRD (DRAFT — local only, not published): `ycpss91255-docker/isaac` 收斂為 Isaac 機器人模擬 base repo

> 狀態：local draft，三輪 grill-me + 三角色 review（資深 RD / PM / QA）已 fold 進。
> Publish 前 pending：(1) `-docker/base` 調整定案後 double-check（消費機制 subtree vs submodule、目錄慣例、versioning、test 執行機制 base#493/isaac#74）、(2) demo checkpoint（camera→ROS2 topic headless smoke）通過後才執行。
> Triage label（送出時）：`ready-for-agent`。送 GitHub 前依雙語規約翻英文 + `--body-file`。

## Problem Statement

`ycpss91255-docker/isaac` 是 research→docker merge 後的 monorepo：env（Dockerfile/.base/compose）+ Dev Kit 框架 + forklift/coreSAM 應用內容全混在 `src/`。想用這套環境快速展開新機器人模擬的 developer，一 clone 就背一堆 coreSAM 後推式貨架專屬的 model/scene/driver，分不清哪些是可重用框架、哪些是別人的應用，也沒有清楚的「我該在哪寫自己的東西」入口。框架程式碼散在 `src/script/` 與 forklift WIP 混雜，無法當 library 乾淨 import。「ROS2 by default」這個預設對接介面也沒在結構上體現。

## Solution

收斂成 Isaac 機器人模擬的 **base repo**（角色對標 `ycpss91255-docker/base`：內含 example 但主要任務是當下游情景 repo 的基底）：env + `isaac_devkit` Python 框架（**mount 進容器、非 baked**）+ 一個體現 ROS2-by-default 的雙邊 example；應用內容搬去 `-research/isaac-forklift`。消費者用父 workspace + `src/docker`（submodule 指向本 base）+ `src/isaac`（自己的 robot 內容）並列，整包掛進容器。`new-workspace.sh` 一鍵搭好。

## Goals / Non-Goals / Success Metrics

### Goals
- G-1 任何「會 ROS2、初學 Isaac」的人能照 README 從零長出一個會發 ROS2 camera topic 的新 robot workspace，不需問人。
- G-2 框架（`isaac_devkit`）是可重用、可測、可被多情景 repo 共用的乾淨 library；bug fix 透過 bump submodule 傳播。
- G-3 base repo 不含任何應用特定（forklift/coreSAM）內容。
- G-4 ROS2-by-default 雙邊拓樸（Isaac 端 driver + ROS2 端 ament pkg）在結構上體現且 example 可 demo。

### Non-Goals
- 對「陌生外部 developer」的零基礎 onboarding 做專門優化（受眾假設見下；但文件仍寫到 newcomer 看得懂）。
- forklift/coreSAM 應用邏輯開發（只搬遷）。
- 一次做滿所有 sensor 類型的 Isaac-side 實作（schema 形狀鎖死、實作漸進）。

### Success Metrics（數字為 draft，calibrate 於指定 GPU runner）
| # | 指標 | 量測 / 門檻 |
|---|---|---|
| M1 | Time-to-first-topic | cached image 下 `new-workspace.sh`→`make run`→`ros2 topic echo` 出第一筆 camera frame **< 30s（warm）**；cold `make build` 另計（分鐘級）。綁定指定 GPU runner spec。 |
| M2 | Example 可重現 | example 端到端 integration 連跑 3 次 100% 綠、無 flake。 |
| M3 | base repo 純淨度 | CI lint：`grep -iE 'forklift|coresam|pallet|pushback|openbase'`（排除 ADR stub）= 0 命中。 |
| M4 | 框架可獨立 import | hosted（無 Isaac）import 全部 `isaac_devkit.*` 後 `sys.modules` 不含 `omni`/`pxr`/`isaacsim`。 |
| M5 | Onboarding 成功率 | 1–2 名未碰過此 repo 的人照 README 走完「跑起來→換 URDF→換 sensor」無需問人。 |
| M6 | Coverage gate | framework pure 表面 line cov ≥ 80% 起步，每 PR 不低於 baseline（ratchet）；100% aspirational 非 merge gate。 |
| M7 | 遷移無回歸 | isaac-forklift 搬完後其 driver 至少能 boot（smoke 綠）。 |
| M8 | Bug-fix 傳播 | demo：base 修 framework bug → bump submodule → 消費端拿到修正（mount 下免 rebuild）。 |
| M9 | 文件對齊 | 4 語言 README + CHANGELOG + TEST.md + ADR stub 全同步（CLAUDE.md 規約）。 |
| M10 | 每階段 DoD | 見「MVP / Phasing」每 slice 一行完成定義。 |

## Audience & Assumptions

- **主要受眾**：內部 + 未來情景 owner（你 + CoreSAM/Isaac scenario teams）。
- **baseline 假設**：使用者**會 ROS2、初學 Isaac**。
- **文件深度**：因無法保證他人熟練度，README / example i18n 文件寫到**任何新手都看得懂**（step-by-step、可複製貼上、解釋每步在做什麼）。4 語言 README 因 hook 硬規約一律維持。

## User Stories

（沿用前版 32 條：scaffold 一鍵、30 秒看到 topic、i18n 教學、`import isaac_devkit`、mount 即時生效、URDF→USD 走 L1、SDF-like sensor YAML、三檔 scene、mobility、sensor 巢狀+link、catalog 完整參數、overrides、custom.yaml 預設、雙邊 ROS2、ament py+cmake 範本、base 純淨、bump 傳播、ADR 分類、框架 package 化、pure/Isaac+import-safety、example 當 integration 對象、4 層斷言、coverage ratchet、mount 即時迭代、lint 零容忍、forklift 搬遷、ADR 跟搬、未來情景共用、stub 指向、successor ADR、修文件、CI 分流。完整列表見 git 歷史前版。）

## Implementation Decisions

**身分**：Isaac 機器人模擬 **base repo**（對標 `-docker/base`）。

**框架安裝 = mount（非 baked，G1 修正）**：`framework/isaac_devkit/` 隨整包 `${WS_PATH}` mount 進容器 `~/work/src/docker/framework`，加進 `PYTHONPATH` 即可 `import isaac_devkit`。**無 Dockerfile pip install、無 baked、無 version=image**——框架版本 = submodule pin 的 git commit；改框架即時生效（mount），bump submodule 就更新、免 rebuild。「baked / 無 live 模式 / bump+rebuild」等衍生決策全作廢。

**模組（deep modules，每個拆 pure / Isaac 兩半）**：`model_import`(L1) / `materials`(L2，variant single owner) / `sensors`(L3) / `ros_io`(ROS2 輸入) / `scene`(三檔組裝) / `driver`(L4 lifecycle)。`__init__.py` curated surface。

**schema 形狀鎖死、實作漸進（決策 C）**：三檔 scene + catalog/placement + `link` + `overrides:` + `mobility` + SDF-like 命名的**全貌寫進 successor ADR 當 committed 契約**（consumer 一開始就 code against 最終形狀）；框架**先實作 example 用到的子集**（camera + base_link mount + topic override + cmd_vel 輸入），lidar/imu/zed/multi-instance auto-namespace/link 存在性驗證等 raise `NotImplementedError`，等真用到再補。介面不 churn、實作慢慢長滿。

**ROS2 by default 雙邊**：Isaac 端 driver（`python.sh`，受 Isaac python 限制不能是 ament）跑 Isaac 容器；app 端 ament package 跑 sibling ROS2 Humble 容器。框架做雙向 bridge wiring，controller logic 留子類。

**搬遷**：forklift 內容 + ADR 0001/0003/0004 → 新 `-research/isaac-forklift`（依 base 對齊 + submodule base）。base 留 ADR 0002/0005-0011/0014-0016（原號 + 搬走 stub）。successor ADR **作廢 0013、修訂 0012**，記錄 base 化 / mount / isaac_devkit / 三檔 scene / sensor catalog / ROS2 雙向 bridge / 新 test 契約。

## Architecture

### A1. Package pure/Isaac 切分 + import-safety
每層單檔，pure 函式在 module 層（Isaac-free），Isaac import 一律 **function-local**。**import-safety enforcement**（hosted、無 Isaac）：迴圈 `importlib.import_module("isaac_devkit.<each>")`（含 `__init__` re-export surface），斷言 import 後 `sys.modules` **不含** `omni`/`pxr`/`isaacsim`（光「import 成功」不夠）；再加一條 ruff/AST 規則禁 module-top `import omni|isaacsim|pxr`（擋 try/except 偽裝）。invariant 寫進 successor ADR。

### A2. IsaacDriver lifecycle
driver 用 `SCENE`（三檔 scene 路徑）class attr 取代單 `USD`。
```
run():
  SimulationApp(parse_livestream_env(ISAAC_LIVESTREAM))   # 必須最先
  install signal handlers（蓋 Kit SIGINT）
  stage = load_scene(SCENE)          # L1+組裝：add_reference + pose + variant
  setup_sensors(stage, SCENE)        # L3: OmniGraph → ROS2 publish
  setup_ros2_io(stage, SCENE)        # ROS2 輸入：OmniGraph Subscribe node（非 rclpy executor）
  ensure_scene_defaults(stage)       # SunLight
  play_timeline()
  setup(stage)                       # 子類 hook
  main()                             # 子類 loop：self.io.latest("/cmd_vel") → controller → 驅動
  shutdown(); app.close()
```
`ros_io` 用 **OmniGraph ROS2 Subscribe node 寫進 graph attribute**（不開 rclpy executor）→ 規避 rclpy/Kit signal init 順序衝突；`latest(topic)` 讀 attr，**無訊息回 None、不阻塞**。lifecycle 順序（load_scene→setup_sensors→setup_ros2_io→setup→main）可用 pure-side spy 驗呼叫序（hosted 免 GPU）。

### A3. 三檔 scene
`scene.yaml`（環境 + import 另兩檔）/ `robot.yaml`（可自主移動，巢狀 sensors）/ `object.yaml`（被動，每筆 `mobility: dynamic|static`）。各檔自帶 xyzrpy placement。

### A4. Sensor（catalog / 解析 / override / link）
- **catalog（層1，完整 sensor spec、不含 mount）**：暴露所有 Isaac 可調參數（camera 解析度/fps/fov/光圈/焦距/clipping/projection、lidar profile/custom config、imu rate/filter）。SDF 有對應用 SDF 名，Isaac 獨有照 Isaac 名。內部 per-stream 覆寫鍵改名 `stream_overrides:`（避開 placement `overrides:` 衝突）。
- **placement（層2，robot/object.yaml 巢狀 sensors）**：兩區塊——(1) mount：`sensor`(name) + `link`(URDF link，選填，預設 base_link) + `xyz`/`rpy`；(2) `overrides:` deep-merge 蓋 catalog。
- **解析切面（誠實標）**：**pure** = 讀 yaml/驗 schema/deep-merge/依命名規則**算出預期 prim path 字串**（可測）；**Isaac** = 驗 link prim 真的存在 + 掛接（需 live stage）。
- **two-tier**：name → custom catalog(`src/isaac/sim/config/sensor/`) 優先 → 否則 NV Isaac 內建 profile。沒給 topic override 時自動以 entity name 當 topic namespace 前綴（v1 stub 可後補）。
- **錯誤契約**：link 不存在 → raise `LinkNotFoundError`；catalog 兩邊都 miss → `SensorNotFoundError`；deep-merge list 欄位 = replace（非 append）。未實作路徑 raise `NotImplementedError`。

### A5. 資料夾架構
**base repo**（root = 消費端 `src/docker`）：`Dockerfile/compose/.base/apps/web_viewer` + `config/`(env 級 instances+ros2 fastdds) + `script/`(wrapper+hooks+`new-workspace.sh`) + `framework/`(pyproject+`isaac_devkit/{__init__,driver,model_import,materials,sensors,ros_io,scene}.py`) + `example/`(README i18n + `sim/`{model,config/sensor,scene,example_driver.py} + `ros2/src/`{ament_python,ament_cmake 各一}) + `doc/`(adr+changelog+test+readme) + `test/`(smoke/bats, unit/pytest+import-safety, integration/pytest example 端到端) + README。現有 root `src/` 整個移除。

**消費端**：`my-robot-ws/`（WS_PATH，掛 `~/work`）→ `.env` + `src/{docker(submodule pin tag), isaac/{README+i18n, sim/{model,config/sensor,scene,<driver>.py}, ros2/src/<pkg>}}`。

**isaac-forklift**：同消費端 shape，`src/isaac` 放 forklift 內容 + ADR 重編。

### A6. Versioning / pin / stage / test 執行（pending base double-check）
- **Versioning**：base 打 semver tag；消費端 submodule pin tag，bump = `git submodule update --remote`（mount 框架免 rebuild）。`isaac_devkit.__version__` 對齊 tag。
- **Stage**：mount 下框架不進 image stage，devel/headless/stream 都從 mount 拿；ROS2 bridge extension function-local enable，與 ADR-0014 stage taxonomy 正交。
- **Test 執行**：integration/GPU pytest 走 **isaac#74 / base#493 機制**（`run.sh -t test -- /isaac-sim/python.sh -m pytest`，devel-test stage + 掛載 workspace + GPU）。base#493 CLOSED（機制應已 ship >v0.40.0），動作 = bump `.base` 解 isaac#74。消費端 test 騎同一條路。**不開新 issue**（已 cover）。

### A7. API 契約（committed interface 形狀）
- `class IsaacDriver`: `SCENE: str`（class attr）；hooks `setup(stage)->None` / `main()->None` / `shutdown()->None`；helper `init_rclpy()->None`；entry `run()->None`。
- `load_scene(scene_path: str, repo_root: str) -> Stage`
- `setup_sensors(stage, scene) -> None`（建 OmniGraph + ROS2 publish）
- `setup_ros2_io(stage, scene) -> RosIo`；`RosIo.latest(topic: str) -> Msg | None`（非阻塞、無訊息 None、同 msg 不重複新鮮標記、讀 OmniGraph attr 非 rclpy）
- `import_urdf(urdf_path: str, out_usd_path: str) -> PrimSummary`
- variant single owner = `materials`（scene loader 只傳 variant 名，不直接 `SetVariantSelection`）。
- 例外階層：`IsaacDevkitError` ← `SceneError` / `SensorConfigError`(`SensorNotFoundError`/`LinkNotFoundError`) / …；stub 路徑 `NotImplementedError`。

## Testing & Acceptance Criteria

**4 軸**：Lint（ShellCheck/Hadolint/ruff/mypy/ament_lint，零容忍，hosted）/ Smoke（env+wrapper+hooks，bats，hosted）/ Unit（framework pure 表面 + import-safety，hosted 無 Isaac）/ Integration（**只 example 端到端**，GPU）。

**per-layer 可執行驗收（強斷言）**：
- **L1**：`stage.GetPrimAtPath("/World/<robot>/base_link").IsValid()` + 預期 link/joint 數 + base_link 有 RigidBodyAPI；URDF→USD prim/joint 數 diff = 0。
- **L2**：`prim.GetVariantSet("<name>").GetVariantSelection() == "<expected>"` 且綁定 MDL path 命中。
- **L3（camera，已實作路徑）**：topic 存在 + 型別 + **frame_id == 預期** + **N 秒內 ≥1 則 message**。lidar/imu v1 stub → unit 斷言 raise `NotImplementedError`，integration 隨實作再補。
- **ros_io**：發一則 `/cmd_vel` → `io.latest()` ≤K tick 回非 None 且內容相符；無訊息回 None 不阻塞。
- **L4**：marker line `[BOOT OK]` + `[EXIT CLEAN]` 皆現（不靠 returncode，Kit `_exit(0)` 吞之）；注入 SIGINT 後 `shutdown()` 確被呼叫；lifecycle 呼叫序 pure-side spy 驗。
- **scaffold**：`new-workspace.sh <tmp>` → build → run → 斷言 camera topic 出現（M1 可執行化）。

**GPU CI 政策**：integration 跑 **headless（不開 livestream）繞 #228**；timeout = 啟動預算 × 1.5；retry 最多 1 次且記錄；GPU runner 不可用 → job `skipped` 但**不算綠**（PR 不可只靠 hosted merge）；marker-line 當 pass 判準。

**Coverage 政策**：framework pure 表面計入並 ratchet（80% gate，每 PR 不低於 baseline，100% aspirational）；**Isaac-side function-local 用 pyproject `[tool.coverage]` config 排除（source-scope / `exclude_also` regex，非 inline 註解 → 不違反禁-coverage-ignore）**；example/ros2 ament pkg 不計入 framework 分母（另有 ament_lint + smoke）。

**遷移 parity**：抽 `framework/` 後舊測試 **1:1 搬到 `isaac_devkit.*` 且全綠**，TEST.md 總數不得下降（除非 CHANGELOG 記明刪除理由，`check_test_md_drift.sh` 強制）；isaac-forklift 搬完跑一次 smoke 當交付 gate（M7）。

**好測試定義**：只測外部行為（YAML→驗證/merge 結果、env→config、URDF→prim summary、setup→ROS2 topic+message），不測實作細節（不斷言內部哪個 OmniGraph node 名）。**Prior art**：現有 `test/unit/pytest/*` pure/Isaac 分離範式 + `test/integration/pytest/_*_runner.py` 的 marker-line / Kit `_exit(0)` workaround（提升為所有 integration 強制驗收手段）。

## Compatibility Matrix（supported 軸，CI 實跑 vs 宣稱）
| 軸 | v1 supported | CI |
|---|---|---|
| Isaac Sim | 5.x（Asset Structure 3.0） | integration 實跑 |
| ROS 2 distro | Humble（主驗證軸） | integration 實跑；Jazzy 僅 smoke 驗 lib 存在 + 標 best-effort（未在 integration 實跑） |
| GPU / VRAM | NVIDIA，VRAM ≥ 8GB | self-hosted GPU runner |
| sensor type | camera（實作）；lidar/imu（schema 鎖、實作漸進） | camera integration 實跑；lidar/imu unit 驗 stub |
| ament | ament_python + ament_cmake（範本） | ament_lint 走 hosted `ros:humble`（`docker run --rm`） |
| 啟動預算 | boot→first camera frame ≤（warm）GPU runner 上限（calibrate） | 當 timeout 基準 + 退化偵測 |

## MVP / Phasing & Definition of Done
| Slice | 內容 | DoD |
|---|---|---|
| 0（prereq）| camera→ROS2 topic headless smoke（`custom.yaml`，繞 #228）= demo 基礎 | smoke 綠（變 base 第一條 integration）|
| 1 | successor ADR（base 化/mount/三檔 scene/sensor catalog/test 契約，作廢 0013/修訂 0012）| ADR merge，cross-ref 對齊 |
| 2 | 抽 `framework/isaac_devkit` + mount wiring + 遷 unit test(1:1) + import-safety | base CI 綠（M4），TEST.md 不降 |
| 3 | example：`sim/`(camera 實作 + 三檔 scene + ExampleDriver + cmd_vel round-trip) + `ros2/`(py+cmake 範本) + i18n README；example 端到端 integration（強斷言）| M1/M2 達標 |
| 4 | `new-workspace.sh` + smoke | scaffold→build→run→topic 驗收綠 |
| 5 | 開 `-research/isaac-forklift` + 搬內容/ADR + submodule base | M7（forklift boot smoke 綠）|
| 6 | 清 base repo（刪 `src/`、root README 改 base 定位 4-lang、CHANGELOG、修 `src/README.md`）| M3 grep 0 命中 + M9 文件對齊 |

每階段兩 repo 各自獨立綠燈、不留跨 repo 半截狀態（tracer-bullet：同 PR 內新增 base 端 + 調整來源端 skip-check）。

## Risks / Assumptions / Rollback
- **R1 example pipeline 未驗**：camera→ROS2 在 Isaac 內從沒跑通（memory `project_isaac_rgbd_ros2_blockers`：#228 segfault、setup_camera 未驗）。**Mitigation**：Slice 0 prereq gate 先打通才執行後續。
- **R2 框架抽出破壞 forklift**：**Mitigation**：base 化在 worktree/branch 進行，main monorepo 維持可用直到 isaac-forklift boot 驗證；rollback trigger = 「框架抽出後 forklift driver 無法 import」；新舊並存上限 1 個 milestone。
- **R3 base double-check 推翻消費模型**（A6 pending）：**Mitigation**：消費機制/versioning 等 base 定案才 publish；submodule vs subtree 若翻盤，`new-workspace.sh` 與 A5 需改。
- **Assumption**：base#493 機制 ship 於 base > v0.40.0（CLOSED 待確認版本）；Isaac 5.x + Humble 為主軸。

## Out of Scope
forklift 應用邏輯開發 / ros1_bridge 反向搬遷 / per-layer 獨立 GPU integration / `make new-robot` codegen / workspace-template 一鍵 repo / controller abstraction（defer 第三 robot）/ 框架 baked 或 live-toggle（已定 mount）/ Gazebo `<gazebo>` tag→Isaac translator（無人維護）/ SDF→USD(gz-usd) model 轉換 / lidar・imu・zed 的 Isaac-side 實作（v1 stub，schema 已鎖）。

## Pre-Publish Checklist（三角色 review 第二輪驗收殘留）
三輪 grill + 兩輪 agent review 後，critical gaps（RD C1-C6 / PM C1-C7 / QA C1-C6）大致全關。publish 前補完以下殘留：

1. **A7 sibling ROS2 CI 路由**：ament pkg（py+cmake）走 hosted `ros:humble`（`docker run --rm`）做 **ament_lint + colcon build**；Isaac↔ament 的 cross-container round-trip（node 真的收到 sim topic）併進 example GPU integration 的 cmd_vel round-trip + camera_echo 斷言，不另起 sibling 容器 CI job。
2. **C6 ratchet enforcement vector**：committed `coverage-baseline`（數值檔）→ `pytest --cov-fail-under=<baseline>`；每 PR 不得低於 baseline，調升 baseline 才算 ratchet，CI step 強制。非口頭。
3. **C1 lidar/imu pure-schema 測試**：除 stub-raises 外，補一條 pure-side 測試斷言 lidar/imu catalog YAML **驗證通過 + 解析出預期 prim-path 字串**（證明「形狀鎖死」的 locked shape 真的 parse）。
4. **MVP cut-line（locked）**：MVP = Issue 1-6（smoke + ADR + 框架 + example + scaffold = 可消費 base repo）；P1 = Issue 7a/7b/8（forklift 搬遷 + 清 base；M3 純淨度為 P1 metric，因 depends on forklift 抽離）。
5. **工作量估計（locked，T-shirt 占位待 GPU runner pin 後 calibrate）**：見下方 Finalized Issue Breakdown 的 size 欄；critical path = 3→4。

## Finalized Issue Breakdown（locked — gate 一過依此建，blocker 先）
9 個 tracer-bullet issue（example 拆 sim/ros2 兩刀、forklift 拆 repo-setup/migration 兩刀分離 HITL/AFK）。建時：先建 `ready-for-agent` label、依 Blocked-by 序、body 雙語（zh-TW draft→英文 `--body-file`）。

| # | Issue | Type | Blocked by | MVP/P1 | Size | Stories |
|---|---|---|---|---|---|---|
| 1 | camera→ROS2 topic headless smoke（`custom.yaml` 繞 #228）= demo 基礎 + 首條 integration | HITL | — | MVP | S* | 2,14 |
| 2 | successor ADR（base 化/mount/三檔 scene/sensor catalog/test 契約；作廢0013/修訂0012）| HITL | — | MVP | S | 12,18,24,30 |
| 3 | 抽 isaac_devkit 框架（mount）+ 遷 unit test 1:1 + import-safety + coverage baseline | AFK | 2 | MVP | L | 4,5,13,19,20,23 |
| 4 | example `sim/`（camera+三檔 scene+ExampleDriver+cmd_vel round-trip）+ GPU integration 強斷言（headless/timeout/retry policy）| AFK | 1,3 | MVP | L | 6,7,8,10,21,22 |
| 5 | example `ros2/`（ament_python + ament_cmake 範本）+ ament_lint/colcon build（hosted ros:humble）| AFK | 4 | MVP | M | 14,15 |
| 6 | `new-workspace.sh` scaffold + smoke（scaffold→build→run→topic）| AFK | 4,5 | MVP | M | 1,3 |
| 7a | 開 `-research/isaac-forklift`：repo + base 對齊（license/flags/branch protection）| HITL | — | P1 | S | 26 |
| 7b | 搬 forklift 內容/ADR + submodule base + boot smoke | AFK | 3,7a | P1 | M | 20,27,28 |
| 8 | 清 base repo（刪 `src/`、root README→base 4-lang、CHANGELOG、修 `src/README.md`、純淨度 grep lint）| AFK | 7b | P1 | M | 3,16,25,31 |

\* #1 size=S 指 smoke 本身；HITL 取得 Isaac pipeline 跑通的前置努力 variable（pipeline 從沒在 Isaac 內跑通，見 R1）。critical path = 3→4（框架→example，皆 L）。CI/政策（GPU runner pin、coverage ratchet vector、headless+timeout+retry）折進 #3/#4，不另開 infra issue。
6. **M1 + timeout calibrate**：pin 指定 GPU runner spec 後，量 warm time-to-first-topic 與 boot budget，把 M1「<30s」與 integration timeout 落成具體數字（promote 為 hard pre-publish blocker）。
7. **A2 兩層 versioning**（gated base double-check）：消費端 submodule pin tag ↔ base repo 內 `.base` subtree 版的連動規則。
8. **base#493 ship 版本確認**（gated）：落成具體 base tag；查不到則退回開 issue（目前「不開新 issue」基於未證實假設）。

## Open Dependencies / Further Notes
- **base double-check**：`-docker/base` 定案後核對消費機制（subtree vs submodule）、目錄慣例、versioning、test 執行（base#493/isaac#74 bump `.base`），補進 PRD 再 publish。
- **demo gate**：Slice 0 通過 + demo 拍完才執行 Slice 1+。
- 所有 PR 走 worktree（`coreSAM_ws/worktree/isaac-<N>/`，submodule 內），不動主 checkout。
- 框架核心（IsaacDriver lifecycle / sensor dispatch / scene loader）穩可先抽；controller 留 example 跟 forklift 演化，第三 robot 再上收。
