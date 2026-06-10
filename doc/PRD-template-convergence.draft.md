# PRD (DRAFT — local only, not published): `ycpss91255-docker/isaac` 收斂為 Isaac 機器人模擬 base repo

> 狀態：local draft，三輪 grill-me + 三角色 review（資深 RD / PM / QA）+ 第四輪 grill（A–F 缺口 + 使用情景 + Milestone）+ **第五輪 grill（Q1–Q7）與兩輪多視角 workflow review** 已 fold 進。round-5 增量：A7 contract 訂正（load_scene→dict/build_scene、PrimSummary 欄位、3a/3b 拆）、pytest-baseline=126 parity gate、0013 amend-重推導（非作廢）、32-story 孤兒歸位 + 三套編號收斂、M5 onboarding agent-proxy gate、#4 拆 #4/#4-int。
> Publish 前 pending：(1) demo checkpoint（M0：camera→ROS2 topic headless smoke）通過後才執行 M1+。**(2) 原 #4-int 外部 gate 已解**：base v0.41.0 已 release（2026-06-10），isaac `.base` bump 在 PR #124（auto-merge）；#4-int 改 depend on #124 merge（即將），M2a/M2b 收斂為單一 M2。消費機制（submodule）、兩層 versioning、ADR/CONTEXT.md split、base#493 現況已查證收斂（見 A6 / Implementation Decisions / Pre-Publish 7-8）。
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
| M1 | Time-to-first-topic | cached image 下 `new-workspace.sh`→`just run`→`ros2 topic echo` 出第一筆 camera frame **< 30s（warm）**；cold `just build` 另計（分鐘級）。綁定指定 GPU runner spec。（wrapper 入口自 base v0.41.0 起為 `just`，非 `make`）|
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

32 條，依 persona 分組。編號對應「Finalized Issue Breakdown」的 Stories 欄（每條都掛在某 issue 上，無孤兒）。

### Persona: Robot Owner（用 base 建自己機器人模擬的人）
| # | Story |
|---|---|
| 1 | scaffold 一鍵：`new-workspace.sh <name>` 一行搭好 `.env` + `src/docker` submodule + `src/isaac` 骨架，不必手組結構 |
| 2 | warm image 下 `just run` **<30s** 出第一筆 camera ROS2 topic（M1）|
| 3 | 4 語言 step-by-step、可複製貼上的 README，新手照走不用問人 |
| 4 | driver 裡乾淨 `import isaac_devkit`（真 library，非散落 script）|
| 6 | `import_urdf()` 把 URDF 轉 USD 且回可驗的 prim/joint summary（L1 確定性）|
| 7 | SDF-like YAML 宣告 sensor，schema 熟悉可攜 |
| 8 | 三檔 scene（scene/robot/object）分離環境、可動機器人、被動物件 |
| 9 | 每個 object 標 `mobility: dynamic\|static`，被動物件物理行為顯式 |
| 10 | sensor 巢狀掛在 robot/object 的某 URDF `link`（預設 base_link），placement 對齊運動學樹 |
| 11 | catalog 暴露**所有** Isaac 可調參數，不限子集 |
| 12 | per-placement `overrides:` deep-merge 蓋 catalog，同一 catalog entry 可在地微調 |
| 13 | sensor config **三層**解析：NV builtin → base 預設 catalog → user catalog（合理預設但每層可覆蓋）|
| 14 | ROS2-by-default 雙邊（Isaac driver + sibling ament pkg），演算法跑標準 ROS2 |
| 15 | ament_python + ament_cmake 兩種範本任選 app 語言 |
| 24 | mount 下對 driver/scene/sensor 即時迭代，dev loop 緊 |

### Persona: Framework Maintainer（開發 isaac_devkit 的人）
| # | Story |
|---|---|
| 5 | mount 下改框架即時生效、免 rebuild |
| 19 | isaac_devkit 是正規 Python package（pyproject + curated `__init__`），可測可 import |
| 20 | 每模組 pure/Isaac 切分 + import-safety（hosted import 不漏 omni/pxr/isaacsim），框架邏輯免 GPU 可測 |
| 21 | example 當唯一 end-to-end integration 對象，integration 覆蓋具體 |
| 22 | 4 層強斷言（L1 prim/joint 數、L2 variant 綁定、L3 topic+frame_id+message、L4 boot/exit marker），測行為非實作 |
| 23 | committed coverage baseline 且 ratchet（≥80%，無 PR 低於 baseline），品質只升不降 |
| 25 | 零容忍 lint（ShellCheck/Hadolint/ruff/mypy/ament_lint）hosted 強制 |
| 30 | successor ADR 記錄收斂決策（base化/mount/三檔scene/catalog/test契約），新架構有文件 |
| 31 | 同一 change 對齊全部文件（4-lang README/CHANGELOG/TEST.md），文件不漂移 |
| 32 | CI 分流（hosted unit/lint + self-hosted GPU smoke/integration），每類測試都跑且免付費 GPU hosted runner |

### Persona: Scenario Owner（forklift 與未來情景，消費 base 的人）
| # | Story |
|---|---|
| 16 | base 零 app-specific 內容，可信為乾淨基底 |
| 17 | 框架修正經 submodule bump 傳播（mount 免 rebuild）|
| 18 | ADR 分類（generic 留 / app-specific 搬），決策史在 split 後仍連貫 |
| 26 | forklift 內容搬去 isaac-forklift，base 純化 |
| 27 | app-specific ADR 跟內容一起搬，各 repo 自有其決策 |
| 28 | 未來情景用跟 forklift 同樣方式消費 base，pattern 可重用 |
| 29 | 搬走的 ADR 留 stub 指向 successor / 新家，traceability 不斷 |

## Implementation Decisions

**身分**：Isaac 機器人模擬 **base repo**（對標 `-docker/base`）。

**框架安裝 = mount（非 baked，G1 修正）**：`framework/isaac_devkit/` 隨整包 `${WS_PATH}` mount 進容器 `~/work/src/docker/framework`，加進 `PYTHONPATH` 即可 `import isaac_devkit`。**無 Dockerfile pip install、無 baked、無 version=image**——框架版本 = submodule pin 的 git commit；改框架即時生效（mount），bump submodule 就更新、免 rebuild。「baked / 無 live 模式 / bump+rebuild」等衍生決策全作廢。

**模組（deep modules，每個拆 pure / Isaac 兩半）**：`model_import`(L1) / `materials`(L2，variant single owner) / `sensors`(L3) / `ros_io`(ROS2 輸入) / `scene`(三檔組裝) / `driver`(L4 lifecycle)。`__init__.py` curated surface。

**schema 形狀鎖死、實作漸進（決策 C）**：三檔 scene + catalog/placement + `link` + `overrides:` + `mobility` + SDF-like 命名的**全貌寫進 successor ADR 當 committed 契約**（consumer 一開始就 code against 最終形狀）；框架**先實作 example 用到的子集**（camera + base_link mount + topic override + cmd_vel 輸入），lidar/imu/zed/multi-instance auto-namespace/link 存在性驗證等 raise `NotImplementedError`，等真用到再補。介面不 churn、實作慢慢長滿。

**ROS2 by default 雙邊**：Isaac 端 driver（`python.sh`，受 Isaac python 限制不能是 ament）跑 Isaac 容器；app 端 ament package 跑 sibling ROS2 Humble 容器。框架做雙向 bridge wiring，controller logic 留子類。

**搬遷**：forklift 內容 + ADR 0001/0003/0004 → 新 `-research/isaac-forklift`（依 base 對齊 + submodule base）。successor ADR **amend 0013（重推導，非作廢）、修訂 0012、supersede 0006/0008/0010**，記錄 base 化 / mount / isaac_devkit / 三檔 scene / sensor catalog / ROS2 雙向 bridge / 新 test 契約。

**0013 為何是 amend-重推導而非作廢**：0013 當初否決「docker 擁有所有測試類別」，兩個理由 = (1) 純 Python unit test 搬進 docker 害 contributor 為改一行要 build container、(2) locality 倒置。**mount 模型抵銷 (1)**（框架 mount 非 baked、unit/import-safety hosted 純跑零 Isaac、免 container build），**research→docker monorepo merge 把框架 code 搬進 base 使 (2) 反向**（tests follow code，locality 現在指向 base）。故 framework test 跟著 framework 住 base 是 0013 原則的延續而非違反——successor ADR amend 0013 記錄這個重推導；0012 一併記 monorepo merge 已撤銷 research/docker 分割，新軸 = -docker 容納可重用 base repos（env + framework base，如 `base` 本身）vs -research 放 app/scenario。

**ADR 去 forklift 化（M3 純淨度 vs ADR append-only 的調和）**：保留 ADR 內仍含 forklift 詞彙（grep 實測：0008 L2/L3 vocab 26 處、0010 Dev Kit 12 處、0006 per-sensor yaml 6 處屬重度；0005/0007/0009/0015 各 2–4 處屬輕度），直接違反 M3。ADR 是 append-only 決策紀錄，不改寫歷史，分兩種處置：
- **重度（0006/0008/0010）= supersede + stub + 搬原檔**：generic 決策由 successor ADR 用 generic 詞彙（example camera-bot 當範例）重述；原檔（含 Forklift_blocky/Model A 範例）整檔搬去 isaac-forklift 當歷史紀錄；base 只留指向 successor 的 stub。successor ADR 的處置清單因此為「amend 0013（重推導）、修訂 0012、supersede 0006/0008/0010」。註：0006 supersede 同時是 A4 sensor schema 取代（per-sensor-type-yaml → catalog/placement two-tier），de-forklift 與 schema 取代是同一刀。
- **輕度（0005/0007/0009/0015）= 就地 editorial de-forklift**：把 incidental 範例詞 forklift→camera-bot，加 editorial footnote（原文留 git history），ADR 留 base。
- **M3 grep scope**：掃 base 全樹，排除 stub 的 pointer 行（`grep -iE 'forklift|coresam|pallet|pushback|openbase'`，stub 指向行不計）。

**CONTEXT.md split（同一把刀）**：現有 CONTEXT.md 混框架 generic（Isaac Dev Kit / L2 / L3 / Robot / Environment Object / Scene YAML / Action Graph）與 forklift 專屬（Model A/B / OpenBase / Chassis SE(2) Slide / push-back / cmd_vel sink deprecated）。切兩份：
- `base/doc/CONTEXT.md`：留 generic 詞彙，L2/L3 範例「Forklift_blocky 預設 5 cube」改 example camera-bot。
- `isaac-forklift/doc/CONTEXT.md`：Model A/B、OpenBase、Chassis SE(2) Slide、push-back、cmd_vel sink(deprecated) 全搬。

## Architecture

### A1. Package pure/Isaac 切分 + import-safety
每層單檔，pure 函式在 module 層（Isaac-free），Isaac import 一律 **function-local**。**import-safety enforcement**（hosted、無 Isaac）：迴圈 `importlib.import_module("isaac_devkit.<each>")`（含 `__init__` re-export surface），斷言 import 後 `sys.modules` **不含** `omni`/`pxr`/`isaacsim`（光「import 成功」不夠）；再加一條 ruff/AST 規則禁 module-top `import omni|isaacsim|pxr`（擋 try/except 偽裝）。invariant 寫進 successor ADR。

### A2. IsaacDriver lifecycle
driver 用 `SCENE`（三檔 scene 路徑）class attr 取代單 `USD`。
```
run():
  SimulationApp(parse_livestream_env(ISAAC_LIVESTREAM))   # 必須最先
  install signal handlers（蓋 Kit SIGINT）
  scene = load_scene(SCENE, ROOT)    # pure：讀 YAML + 驗 schema，回 validated dict
  stage = get_stage()                # 取 SimulationApp/World 的 stage（非 load_scene 產生）
  build_scene(scene, stage, ROOT)    # Isaac：add_reference + pose + variant，mutate stage
  setup_sensors(stage, scene)        # L3: OmniGraph → ROS2 publish
  setup_ros2_io(stage, scene)        # ROS2 輸入：OmniGraph Subscribe node（非 rclpy executor）
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
- **three-tier 解析（最高優先在上）**：user catalog(`src/isaac/sim/config/sensor/`) → **base repo 預設 catalog**（isaac_devkit 隨 mount 提供的 default catalog 層，這個 repo 自帶）→ NV Isaac 內建 profile。三層 deep-merge：base 預設覆蓋 NV，user 覆蓋 base 預設。沒給 topic override 時自動以 entity name 當 topic namespace 前綴（v1 stub 可後補）。
  - base 預設 catalog 的家：`framework/isaac_devkit/`（隨框架 mount，bump submodule 即更新），消費端可不寫任何 catalog 就拿到合理預設；要改才在 `src/isaac/sim/config/sensor/` 覆蓋。
- **錯誤契約**：link 不存在 → raise `LinkNotFoundError`；catalog 三層全 miss → `SensorNotFoundError`；deep-merge list 欄位 = replace（非 append）。未實作路徑 raise `NotImplementedError`。

### A5. 資料夾架構
**base repo**（root = 消費端 `src/docker`）：`Dockerfile/compose/.base/apps/web_viewer` + `config/`(env 級 instances+ros2 fastdds) + `script/`(wrapper+hooks+`new-workspace.sh`) + `framework/`(pyproject+`isaac_devkit/{__init__,driver,model_import,materials,sensors,ros_io,scene}.py` + `isaac_devkit/` 內附 **base 預設 sensor catalog** 資料，three-tier 的中間層、隨 mount 提供) + `example/`(README i18n + `sim/`{model,config/sensor,scene,example_driver.py} + `ros2/src/`{ament_python,ament_cmake 各一}) + `doc/`(adr+changelog+test+readme) + `test/`(smoke/bats, unit/pytest+import-safety, integration/pytest example 端到端) + README。現有 root `src/` 整個移除。

**消費端**：`my-robot-ws/`（WS_PATH，掛 `~/work`）→ `.env` + `src/{docker(submodule pin tag), isaac/{README+i18n, sim/{model,config/sensor,scene,<driver>.py}, ros2/src/<pkg>}}`。

**isaac-forklift**：同消費端 shape，`src/isaac` 放 forklift 內容 + ADR 重編。

**scaffold 預填（定案）**：`new-workspace.sh <name>` 把 base 的 `example/`（camera example 全套：model + 三檔 scene + ExampleDriver + ros2 pkg）**複製進 `src/isaac/`**，裝完直接 `just run` 即出 camera topic（M1/M5 字面成立，新手有可跑的 working reference，再在其上改/換 URDF）。`example/` 因此一物兩用 = integration 對象 + scaffold 模板（single source），故 Issue #6 blocked-by #4/#5。

### A6. Versioning / pin / stage / test 執行
- **消費機制（定案 = submodule）**：下游消費 isaac-base 走 **git submodule**（與本 repo 既有 `web_viewer` submodule 先例一致；mount + `git submodule update --remote` bump 比 subtree vendor 合身）。isaac-base 自己消費 `-docker/base` 仍走 `.base/` subtree（org template，現 v0.41.0，PR #124 bump 中）。**兩層版本**：下游 submodule pin isaac-base tag ↔ isaac-base 內 `.base` subtree 版。
- **Versioning**：base 打 semver tag；消費端 submodule pin tag，bump = `git submodule update --remote`（mount 框架免 rebuild）。`isaac_devkit.__version__` 對齊 tag。**MVP（Issue 1,2,3,4,4-int,5,6,6b）達標 = isaac-base 切 `v1.0.0` release**（消費者首個可用版本；base v0.41.0 已 release，#4-int 不再外部 gated、回歸 MVP）。
- **Stage**：mount 下框架不進 image stage，devel/headless/stream 都從 mount 拿；ROS2 bridge extension function-local enable，與 ADR-0014 stage taxonomy 正交。
- **Test 執行（gate 已解）**：integration/GPU pytest 走 **isaac#74 / base#493 機制**（`run.sh -t test -- /isaac-sim/python.sh -m pytest`，devel-test stage + 掛載 workspace + GPU）。**現況（2026-06-10 更新）**：**base 已 release v0.41.0（2026-06-10）含 base#493 機制**；isaac bump `.base` v0.40.0→v0.41.0 已在 **PR #124**（auto-merge，CI 跑中）。init-vs-upgrade parity 驗證相符（runtime.env 退役、Makefile→justfile、`.base` 樹 byte-identical）。**#124 merge 後 #4-int 的 GPU 自動 integration 即可跑、isaac#74 即可解**。原「外部 gated 等 base release」前提已消除——剩餘相依僅 #124 落地（即將）。**不另開新 issue**（isaac#74 已覆蓋此 bump）。

### A7. API 契約（committed interface 形狀）
- `class IsaacDriver`: `SCENE: str`（class attr）；hooks `setup(stage)->None` / `main()->None` / `shutdown()->None`；helper `init_rclpy()->None`；entry `run()->None`。
- `load_scene(path: str, repo_root: str) -> dict`（pure：讀 YAML + 驗 schema，回 validated scene dict；**採現有 `scene_builder.load_scene` 簽名**，非 PRD 前版誤寫的 `-> Stage`）
- `build_scene(scene: dict, stage, repo_root: str) -> None`（Isaac：add_reference + pose + variant，mutate 傳入 stage；採現有 `scene_builder.build_scene`。`pxr` 僅 function-local import / `TYPE_CHECKING` 字串 annotation，不破 A1 import-safety）
- `setup_sensors(stage, scene: dict) -> None`（建 OmniGraph + ROS2 publish）
- `setup_ros2_io(stage, scene: dict) -> RosIo`；`RosIo.latest(topic: str) -> Msg | None`（非阻塞、無訊息 None、同 msg 不重複新鮮標記、讀 OmniGraph attr 非 rclpy）
- `import_urdf(urdf_path: str, out_usd_path: str) -> PrimSummary`，`PrimSummary = NamedTuple{prim_count:int, joint_count:int, link_paths:list[str], root_prim:str, usd_path:str}`；L1「prim/joint diff=0」= pure URDF parse(expected) vs PrimSummary(actual) 比對。**註 greenfield**：現有 `import_urdf.py` 僅 `main()->int` CLI、真邏輯在 `import_model.py`，且既有 `test_model_import.py` 斷言 asset-structure-3.0 非 prim/joint 數——此契約落為**新 code + 新斷言**，不是被搬測試的 external-behavior 保留。
- variant single owner = `materials`（scene loader 只傳 variant 名，不直接 `SetVariantSelection`）。**v1 現況**：現 code 的 `SetVariantSelection` 散在 `scene_builder.py:142`（選）+ `material_setup.py`（建 variant set）；此單一-owner 重構 = 「3b」**折進 #7b**（forklift 才真用多變體），#3 機械抽取保留現狀散兩處；介面契約現在就鎖在此 ADR。
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
- **onboarding（M5 驗證，Q7a；owner = Issue #6b）**：主 gate = **agent-proxy** —— 一個只拿到 `example/` + README 的 fresh agent，須走到 M1 first-topic + 完成 URDF-swap + 一個 **in-scope** sensor-swap（改解析度/fps/topic override 或加第二顆 camera），**全程不讀 framework 原碼**（執行時 framework/ 設不可讀，或稽核 tool-call log；若無法機械強制則降為 advisory，真人 dry-run 當真 gate）；外加 **1.0.0 前一次真人 dry-run**。lidar/imu 的 `NotImplementedError` 邊界當**刻意 callout** 寫進 README，換 sensor 步驟釘在 in-scope op。

**GPU CI 政策**：integration 跑 **headless（不開 livestream）繞 #228**；timeout = 啟動預算 × 1.5；retry 最多 1 次且記錄；GPU runner 不可用 → job `skipped` 但**不算綠**（PR 不可只靠 hosted merge）；marker-line 當 pass 判準。

**Coverage 政策**：framework pure 表面計入並 ratchet（80% gate，每 PR 不低於 baseline，100% aspirational）；**Isaac-side function-local 用 pyproject `[tool.coverage]` config 排除（source-scope / `exclude_also` regex，非 inline 註解 → 不違反禁-coverage-ignore）**；example/ros2 ament pkg 不計入 framework 分母（另有 ament_lint + smoke）。

**遷移 parity**：抽 `framework/` 後既有測試 **PORT 到 `isaac_devkit.*` 且全綠**（外部行為斷言保留；**非純 1:1**，因 A7 variant single-owner 等內部歸屬在 3b/#7b 會變、PrimSummary/ros_io 等新契約是新增）。**pytest parity gate（訂正 TEST.md + `check_test_md_drift.sh` 只數 `^@test`/bats 的盲點——被抽框架其實由 126 個 pytest 測：115 unit + 11 integration，完全不在 TEST.md 視野）**：在 isaac repo commit 一個 pytest-count baseline = **126**，CI step assert「collected pytest ≥ baseline 且全綠」，跨兩 runner 聚合（115 hosted-unit + 11 GPU-integration）。**分段驗收**：M1（hosted-only，GPU 在 M2）門檻 = **hosted-unit ≥ 115 全綠**；**126 跨 runner 完整聚合於 M2 才 assert**（11 GPU-integration 隨 #4-int 上線），**GPU job skipped 視為未達 M2 baseline、不算綠**。新契約測試（PrimSummary diff=0 / RosIo.latest / lifecycle spy，皆 greenfield）為**新增**、不取代被搬測試。bats 仍由 TEST.md + `check_test_md_drift.sh` 管；另開 harness follow-up issue 讓 drift hook 也數 pytest（sidecar，不阻塞本 PRD）。isaac-forklift 搬完跑一次 smoke 當交付 gate（M7）。

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

## Phasing & Definition of Done

**單一編號制（收斂三套編號）**：交付控制以下方「Milestone 規劃」（M0 / M1 / M2 / M3）為準，工作單位以「Finalized Issue Breakdown」（#1–#8 + #4-int / #6b）為準，stories 以本檔 User Stories 1–32 為準。**作廢舊「Slice 0–6」獨立編號**（曾與 Issue 編號 off-by-one），不再使用。每階段兩 repo 各自獨立綠燈、不留跨 repo 半截狀態（tracer-bullet：同 PR 內新增 base 端 + 調整來源端 skip-check）。

**Release framing**：MVP（Issue **1,2,3,4,4-int,5,6,6b** = M2 完成點 = 可消費 base repo）達標 → isaac-base 切 **v1.0.0**。base v0.41.0 已 release（PR #124 bump 中），**#4-int 的 GPU 自動 integration 不再外部 gated**，回歸 MVP 一部分（剩餘相依僅 #124 merge）。P1（Issue 7a/7b/8，forklift 搬遷 + 清 base）為 v1.0.0 後的後續（base 純淨度 M3 屬 P1 metric，因 depends on forklift 抽離）。

## Milestone 規劃（GitHub Milestone + 階段性驗證 gate）

執行原則：除方向性 HITL 停點（#1 Isaac pipeline bring-up / #2 ADR 撰寫 / #7a 建 repo）外，milestone 內各 issue AFK 推進。**每個 milestone 收尾 = agent 敘述該 milestone 交付內容 + 驗證結果 → user review → user 確認後才推下一個 milestone**（user-review gate，每 milestone 都有，非僅 HITL 停點）。能平行就用 workflow 平行（如 #3 內 6 模組），不串列。

| Milestone | Issues | 模式 | 驗證 + user-review gate |
|---|---|---|---|
| **M0 — Pipeline prereq + ADR** | #1 camera→ROS2 headless smoke、#2 successor ADR | HITL | **R1 關鍵 gate（integration-tier 證據）**：camera topic 在 headless Isaac 真 echo 出（此 pipeline 從沒在 Isaac 內跑通）+ ADR merge。過不了則下游全部無意義。**user review**：確認 pipeline 證實可跑 + ADR 契約正確 |
| **M1 — 框架抽出** | #3 抽 isaac_devkit（機械「3a」）+ mount + PORT pytest + pytest-baseline + import-safety + coverage baseline | AFK | hosted CI 綠（M4 import-safety / M6 coverage），**hosted-unit pytest ≥ 115 全綠**（126 跨 runner 聚合含 11 GPU-integration 於 **M2** 才驗，非 M1）。免 GPU 輕 gate。**user review**：框架乾淨抽出、全綠、parity 證實 |
| **M2 — Example + scaffold + GPU integration** | #4(example camera+三檔scene+ExampleDriver+cmd_vel code)、#4-int(GPU 自動 integration 強斷言，`run.sh -t test`)、#5 ament 範本+4-lang README、#6 new-workspace scaffold、#6b onboarding agent-proxy | AFK（#4→#4-int；#4→#5→#6→#6b 序）| scaffold→build→run→topic 綠；ament_lint/colcon 綠；agent-proxy 過；**GPU 自動 integration 綠（126 跨 runner 完整聚合 + M1/M2 metric 於此驗收）**。#4-int 依 **PR #124（`.base` v0.40→v0.41 bump）** merge——v0.41.0 已 release（2026-06-10），非無限期外部 gate。**user review**：端到端範例跑通 + GPU integration 綠、新手/agent 能 scaffold→run→swap = **MVP 完成點** |
| **M3 — Forklift 搬遷 + 清 base** | #7a 開 isaac-forklift（base 對齊）、#7b 搬內容/ADR + submodule + 「3b」variant refactor、#8 清 base | #7a HITL / #7b#8 AFK | M3 純淨度 grep 0、M7 forklift boot smoke、M9 文件對齊。**user review**：forklift 搬完 boot 綠、base 純淨 → **tag v1.0.0** |

**#4 / #4-int 拆分**：兩者皆在 **M2**。**#4**（example camera 實作 code，#6 scaffold 驗收要用、手動 `just run` 可跑）；**#4-int**（GPU 自動 integration 斷言，`run.sh -t test`，用 base v0.41.0 的 test stage 機制）。拆分理由 = impl vs GPU-auto-test 可分（非外部 gate——v0.41.0 已 release）；#4-int blocked-by #4 + PR #124 merge。

## Risks / Assumptions / Rollback
- **R1 example pipeline 未驗**：camera→ROS2 在 Isaac 內從沒跑通（memory `project_isaac_rgbd_ros2_blockers`：#228 segfault、setup_camera 未驗）。**Mitigation**：M0（#1）prereq gate 先打通才執行後續。
- **R2 框架抽出破壞 forklift**：**Mitigation**：base 化在 worktree/branch 進行，main monorepo 維持可用直到 isaac-forklift boot 驗證；rollback trigger = 「框架抽出後 forklift driver 無法 import」；新舊並存上限 1 個 milestone。
- **R3 base double-check 推翻消費模型**（已大幅收斂）：消費機制定案 = **submodule**（A6，依本 repo `web_viewer` 先例），R3 殘留風險僅「`-docker/base` 自身慣例若大改」，低。`new-workspace.sh` 與 A5 以 submodule 為準。
- **R4 base v0.41.0 release 時程（外部）——已解（2026-06-10）**：base 已 release v0.41.0 含 base#493 機制；isaac `.base` bump 在 PR #124（auto-merge，CI 跑中，init-vs-upgrade parity 已驗）。殘留風險僅 #124 CI（Isaac image build）綠 + merge，屬內部即將事件，非無限期外部 gate。
- **Assumption**：base#493 已 CLOSED（2026-06-01）且**已進 release v0.41.0**（2026-06-10）；isaac bump `.base` 進行中（PR #124，覆蓋 isaac#74）。Isaac 5.x + Humble 為主軸。

## Out of Scope
forklift 應用邏輯開發 / ros1_bridge 反向搬遷 / per-layer 獨立 GPU integration / `make new-robot` codegen / workspace-template 一鍵 repo / controller abstraction（defer 第三 robot）/ 框架 baked 或 live-toggle（已定 mount）/ Gazebo `<gazebo>` tag→Isaac translator（無人維護）/ SDF→USD(gz-usd) model 轉換 / lidar・imu・zed 的 Isaac-side 實作（v1 stub，schema 已鎖）。

## Pre-Publish Checklist（三角色 review 第二輪驗收殘留）
三輪 grill + 兩輪 agent review 後，critical gaps（RD C1-C6 / PM C1-C7 / QA C1-C6）大致全關。publish 前補完以下殘留：

1. **A7 sibling ROS2 CI 路由**：ament pkg（py+cmake）走 hosted `ros:humble`（`docker run --rm`）做 **ament_lint + colcon build**；Isaac↔ament 的 cross-container round-trip（node 真的收到 sim topic）併進 example GPU integration 的 cmd_vel round-trip + camera_echo 斷言，不另起 sibling 容器 CI job。
2. **C6 ratchet enforcement vector**：committed `coverage-baseline`（數值檔）→ `pytest --cov-fail-under=<baseline>`；每 PR 不得低於 baseline，調升 baseline 才算 ratchet，CI step 強制。非口頭。
3. **C1 lidar/imu pure-schema 測試**：除 stub-raises 外，補一條 pure-side 測試斷言 lidar/imu catalog YAML **驗證通過 + 解析出預期 prim-path 字串**（證明「形狀鎖死」的 locked shape 真的 parse）。
4. **MVP cut-line（locked，已收斂編號）**：**MVP = Issue 1,2,3,4,4-int,5,6,6b**（smoke + ADR + 框架 + example + GPU integration + scaffold + onboarding = 可消費 base repo = M2 完成點 = 切 v1.0.0）。原「#4-int 外部 gated」前提已消除（base v0.41.0 已 release，PR #124 bump），#4-int 回歸 MVP，相依僅 #124 merge。P1 = Issue 7a/7b/8（forklift 搬遷 + 清 base；M3 純淨度為 P1 metric，因 depends on forklift 抽離）。
5. **工作量估計（locked，T-shirt 占位待 GPU runner pin 後 calibrate）**：見下方 Finalized Issue Breakdown 的 size 欄；critical path = 3→4。

## Finalized Issue Breakdown（locked — gate 一過依此建，blocker 先）
11 個 tracer-bullet issue（8 primary + #4-int / #6b 兩個 split：example 拆 sim/ros2 兩刀、#4 拆 impl/GPU-int、scaffold/onboarding 分 #6/#6b、forklift 拆 repo-setup/migration 兩刀分離 HITL/AFK）。建時：先建 `ready-for-agent` label、依 Blocked-by 序、body 雙語（zh-TW draft→英文 `--body-file`）。

| # | Issue | Type | Blocked by | Milestone | Size | Stories |
|---|---|---|---|---|---|---|
| 1 | camera→ROS2 topic headless smoke（`custom.yaml` 繞 #228）= demo 基礎 + 首條 integration | HITL | — | M0 | S* | 2,14 |
| 2 | successor ADR（base化/mount/三檔scene/sensor catalog/test契約；**amend 0013 重推導 / 修訂 0012 / supersede 0006/0008/0010** + de-forklift + CONTEXT.md split + ADR stub）| HITL | — | M0 | S | 12,18,24,29,30 |
| 3 | 抽 isaac_devkit 框架（mount，機械=「3a」）+ PORT pytest + **pytest-baseline=126 gate** + import-safety + coverage baseline（variant single-owner「3b」折進 #7b）| AFK | 2 | M1 | L | 4,5,11,13,19,20,23,32 |
| 4 | example `sim/`（camera impl + 三檔scene + ExampleDriver + cmd_vel round-trip code；#6 scaffold / 手動 `just run` 驗收要用）| AFK | 1,3 | M2 | L | 6,7,8,9,10,21 |
| 4-int | example GPU 自動 integration 強斷言（headless/timeout/retry，`run.sh -t test` path）| AFK | 4, PR #124 merge | M2 | M | 22 |
| 5 | example `ros2/`（ament_python + ament_cmake 範本）+ ament_lint/colcon build（hosted ros:humble）+ **4-lang README authored + sync-hook 綠** | AFK | 4 | M2 | M | 14,15 |
| 6 | `new-workspace.sh` scaffold（emit 檔案樹 + 預填 example）+ smoke（scaffold→build→run→topic）+ **M8 bump-傳播 demo** | AFK | 4,5 | M2 | M | 1,3,17 |
| 6b | onboarding 驗證：**agent-proxy gate**（example+README only、不讀 framework 原碼）+ 1.0.0 前真人 dry-run | AFK | 6 | M2 | S | 3 |
| 7a | 開 `-research/isaac-forklift`：repo + base 對齊（license/flags/branch protection）| HITL | — | M3 | S | 26 |
| 7b | 搬 forklift 內容/ADR + submodule base + boot smoke + **variant single-owner refactor（「3b」：SetVariantSelection 移出 scene_builder→materials）** | AFK | 3,7a | M3 | M | 20,27,28 |
| 8 | 清 base repo（刪 `src/`、root README→base 4-lang、CHANGELOG、修 `src/README.md`、純淨度 grep lint）| AFK | 7b | M3 | M | 3,16,25,31 |

**Stories 覆蓋稽核**：1–32 每條都出現在 ≥1 個 Stories 欄（5 個曾孤兒已歸位：9→#4、11→#3、17→#6、29→#2、32→#3）。1.0.0 = 所有 PRD 內容 = 全 issue 完成。

\* #1 size=S 指 smoke 本身；HITL 取得 Isaac pipeline 跑通的前置努力 variable（pipeline 從沒在 Isaac 內跑通，見 R1）。**M0 證據 gate = integration-tier**（headless Isaac 真 boot + camera topic echo，非 hosted unit；115 unit 全 host-pure 不證 GPU path）。critical path = 3→4（框架→example，皆 L）。**M2 內 #4→#5→#6 為序**（Blocked-by 為準，非平行；僅 #5 的 README 撰寫可早啟；#4-int 於 #4 後 + PR #124 merge 後跑）；**#3 內 6 模組可平行抽，但 `ros_io` 是 greenfield 新撰非抽取**。CI/政策（GPU runner pin、coverage ratchet vector、headless+timeout+retry）折進 #3/#4，不另開 infra issue。
6. **M1 + timeout calibrate**：pin 指定 GPU runner spec 後，量 warm time-to-first-topic 與 boot budget，把 M1「<30s」與 integration timeout 落成具體數字（promote 為 hard pre-publish blocker）。
7. **A2 兩層 versioning（已定案）**：消費端 submodule pin tag ↔ base repo 內 `.base` subtree 版，寫進 A6。
8. **base#493 ship 版本（已解，2026-06-10）**：#493 已進 base **v0.41.0**；isaac bump `.base` v0.40→v0.41 在 **PR #124**（auto-merge，覆蓋 isaac#74，不另開 issue）。#4-int 改 depend on #124 merge，原 M2b 外部 gate 消除、收斂進 M2。

## Open Dependencies / Further Notes
- **base double-check（已收斂）**：消費機制定案 = submodule、兩層 versioning 已寫進 A6；殘留僅 `-docker/base` 自身目錄慣例若大改需回核，風險低。
- **base v0.41.0（已 release 2026-06-10）**：含 #493 → isaac bump `.base` 在 PR #124（init-vs-upgrade parity 已驗）→ merge 後 isaac#74 解、#4-int 解鎖。
- **demo gate**：M0（#1）通過 + demo 拍完才執行 M1+。
- 所有 PR 走 worktree（`coreSAM_ws/worktree/isaac-<N>/`，submodule 內），不動主 checkout。
- 框架核心（IsaacDriver lifecycle / sensor dispatch / scene loader）穩可先抽；controller 留 example 跟 forklift 演化，第三 robot 再上收。
