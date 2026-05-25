# Isaac SIM Validation Context

CoreSAM 在 Isaac SIM 內驗證上層演算法時用的詞彙。**範疇限定於 isaac_ws/** — CoreSAM 本體與 ROS 2 服務的詞彙不在此。

## Language

**Upper-Layer Algorithm**（上層演算法）:
CoreSAM 感知（mask）+ 應用層幾何（mask → 3D → 對齊指令）的整條鏈。
_Avoid_: 演算法 (太籠統)、controller (在 robotics 語境會跟運動控制混)

**Motion-Control Simulation**（運動控制模擬）:
完整模擬 mecanum 輪子轉動、joint dynamics、輪胎滑動等低層物理。
_Avoid_: 物理模擬 (太籠統 — gravity / collision 還是要)、kinematics simulation

**Chassis SE(2) Slide**:
把 OpenBase 當完美 SE(2) actuator — base_link 直接按 cmd_vel 平移，不轉輪子、`/joint_states` 全 0。
_Avoid_: fake movement、cheat mode (帶貶意)

**Model A**（**Chassis SE(2) Slide Model** 的正式命名）:
A/B-Phase 用於 Upper-Layer Algorithm 驗證的 SIM 模型實作 — 單一 base_link rigid body USD + 直寫 velocity script。**Chassis SE(2) Slide** 的具體 deliverable。
_Avoid_: simple model、fake model、Model 1

**Model B**（**Motion-Control Simulation** 的正式命名）:
C-Phase 用於 Sim2Real gap 量化的 SIM 模型實作 — 完整 mecanum URDF + Holonomic/Articulation Controller + PhysX 完整動力學。
_Avoid_: real model、full model、Model 2

**L2 (Kinematic)**:
USD prim 走 kinematic rigid body。命令即位置（無 force lag）,但**會產生 collision contact**——會推開 dynamic body、會被 contact query 偵測到。「ideal actuator + 真實接觸」的 canonical 組合,PhysX 官方列為 moving platforms / character controllers 的標準工具。Forklift_blocky 預設 5 cube 都在此階（ADR-0004）。
_Avoid_: ideal physics（太籠統）、scripted body（隱沒 collision 屬性）

**L3 (Dynamic + Joint)**:
USD prim 走 dynamic rigid body + joint + drive。受重力 / 外力 / 摩擦影響,joint drive 透過力學試圖追命令,追隨品質受 stiffness/damping tuning 影響。屬 **Motion-Control Simulation** 範疇。
_Avoid_: 真物理（太籠統）、articulation（articulation 是 L3 的特殊 solver,L3 不一定走 articulation）

**Action Graph**:
USD-embedded OmniGraph，跑在 kit C++ pipeline。
_Avoid_: visual scripting (Isaac UI 用詞但對外溝通不清)、graph

**cmd_vel sink**:
Action Graph 內接 `ROS2SubscribeTwist` → `WritePrimAttribute(/open_base/base_link, physics:velocity)` 的節點鏈。

## Relationships

- **Upper-Layer Algorithm** 與 **Motion-Control Simulation** 是兩個獨立 scope；當前 isaac_ws 只做前者
- **Chassis SE(2) Slide** 是 **Upper-Layer Algorithm** 開發時用的代理模式
- **cmd_vel sink** 是 **Chassis SE(2) Slide** 的具體實現位置
- **Model A** 是 **Chassis SE(2) Slide** 的 SIM 模型實作，**Model B** 是 **Motion-Control Simulation** 的 SIM 模型實作；兩軌並行不取代（C-Phase 為切換點，A/B-Phase 用 Model A，C-Phase 切 Model B 量化 sim-real gap）— 詳見 ADR-0003
- **L2 / L3** 是 per-body 物理階段。Model A 家族的 USD 預設 chassis 與 mast 系統都 L2；升任何 body 到 L3 即跨入 **Motion-Control Simulation** 範疇,屬 Model B 軌

## Example dialogue

> **Dev:** "B-Phase 對齊驗證跑 SIM 時，要看 `/joint_states` 嗎?"
> **Domain expert:** "不用。我們是 **Upper-Layer Algorithm** 開發，跑 **Chassis SE(2) Slide**，輪子根本不轉。`/joint_states` 是 **Motion-Control Simulation** 才看的事，那是另一個專案。"

## Flagged ambiguities

- 「joint 控制」一詞在這個 context 下不存在 — **Model A** 做的是 **Chassis SE(2) Slide**，**沒有 joint**；只有 **Model B** 才有 joint 控制概念。若有人說 "Isaac 是否支援 joint 控制"，先釐清是 Upper-Layer 還是 Motion-Control 範疇。
- 「車子在 SIM 內怎麼動」要先確認當前在 **Model A** 還是 **Model B**：Model A 是直寫 base velocity（不轉輪），Model B 是 cmd_vel → controller → joint drive → wheel friction → base 移動（會打滑、會偏）。
