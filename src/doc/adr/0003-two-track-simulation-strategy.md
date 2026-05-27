# Two-Track Simulation Strategy: Model A vs Model B

isaac_ws 同時維護兩條 SIM 模型軌道，**並行不取代**：

- **Model A — Chassis SE(2) Slide Model**：`openbase_minimal.urdf → openbase.usda` (單一 base_link rigid body) + `cmd_vel_planar_move.py` 直寫 base velocity + `disableGravity` + 輪子 drive 全關。Gazebo `planar_move` 等效。**A/B-Phase 用於 Upper-Layer Algorithm（CoreSAM perception + 應用層幾何 + 對齊指令生成）驗證**，假定運動控制完美無誤。
- **Model B — Motion-Control Simulation Model**：完整 `openbase.urdf`（32-link mecanum）+ Holonomic Controller + ArticulationController (Action Graph 或 NVIDIA Tools menu)，PhysX 完整模擬輪胎接觸 / 摩擦 / 打滑 / joint dynamics。**C-Phase 用於 Sim2Real gap 量化 / nav stack 驗證 / motion-control performance 對標**。

切換時機：**C-Phase 開始**（B-Phase 上層演算法閉環全部驗收完成後）。兩軌物件（URDF / USD / script）各自維護不互踩。

## Considered Options

- **(a) Single-track Model A only**：永遠不離開 SE(2) slide 假設。風險：C-Phase 沒有量化 sim-real motion gap 的工具，D-Phase 實車就硬撞到「演算法跟現實 motion 行為差異未驗證」的問題
- **(b) Single-track Model B only**：A/B-Phase 演算法驗證就要面對 mecanum 動力學 noise（輪胎打滑、friction drift），算對齊成功率時無法區分「演算法錯了」vs「motion control 偏了」，違反 ADR-0001 立場
- **(c) Two-track A + B parallel**: 演算法階段用 A (乾淨)，sim-real gap 量化用 B (現實感)；**選此**

## Why (c)

- ADR-0001 已決定 A/B-Phase 排除 motion-control simulation 範圍；但 D-Phase 實車驗證若沒先在 SIM 內收斂 motion gap，會把「演算法 bug」跟「motion 差異」混在實車除錯，成本爆炸
- Model A 跟 Model B 在 SIM 內各自獨立 — USD 檔不同、in-kit script 不同、跑的 launch 不同；不會 cross-contaminate
- 切換點明確（C-Phase 起），不會在 B-Phase 中段為了「要不要先驗 motion gap」反覆猶豫

## Consequences

- **兩個 USD 並存**：
  - `isaac_ws/src/model/usd/robot/openbase/openbase.usda` (Model A，當前使用)
  - 未來 `isaac_ws/src/model/usd/robot/openbase/openbase_full.usda`（Model B，C-Phase 1 產出）
- **兩支 in-kit script 並存**：
  - `cmd_vel_planar_move.py` (Model A，當前)
  - 未來 `cmd_vel_motion_control.py` 或 Action Graph in USD（Model B，C-Phase 設計）
- **C-Phase 1 預算需含 Model B setup 成本**：完整 URDF re-import、HolonomicController / ArticulationController 接線、wheel friction params 量測 + 校準、Action Graph 烤進 USD 一次性 GUI（重新撞 (β) 的 USD-embedded Python gating 議題）
- **CHANGELOG / TEST.md** 應在 C-Phase 1 starting 時加 Model B switchover 標記
- Sim2Real gap 量化是 C-Phase 主要交付物之一；Model A 跟 Model B 在相同任務（後推式貨架對齊）下的成功率差異 = motion gap 量化
- 6.0 GA 後兩軌實作細節都會 migrate（Model A: Script Editor → OmniGraph; Model B: 5.1 Action Graph → 6.0 純腳本 OmniGraph），但**分軌策略本身不變**

## Update (2026-05-19) — PoC #59 強化兩軌獨立性的技術 ground truth

PoC #59 在 `openbase_free.usda`（Model B 候選 USD）上嘗試套 Model A bypass 路徑（velocity write / pose teleport），實驗結果：

- **velocity write 路徑（MODE A/B/C）全 fail** — articulation kinematics solver 把 rigid body velocity write 吃掉或 silently no-op
- **pose teleport（MODE D）數值通過** — `dc.set_rigid_body_pose` 確實能 teleport base_link，數值對齊完美
- **但 MODE D 副作用**：disable articulation root 連帶解開 wheel ↔ base joint constraint，wheels 散落，視覺破碎

詳細實驗表格見 ADR-0001 「Update (2026-05-19) — PoC #59 結果」section。

**對本 ADR 兩軌策略的影響**：

1. 兩軌策略原本理由偏向「乾淨分工 / 避免 motion noise 污染演算法驗證」（軟性 trade-off）。PoC #59 把它升級為**硬性技術不相容**：dc.velocity 與 articulation USD 物理上不相容，dc.set_rigid_body_pose 與 articulation USD 視覺上不相容。試圖單一 USD 雙模式（runtime 切換 Model A/B）會撞這個底層硬牆
2. 兩個 USD 的設計差異不只是 link 數量差，而是**根本性架構選擇**：簡化 USD 把 chassis 當 free rigid body，PhysX 整 body integration；full USD 把 chassis 當 articulation root，PhysX 走 reduced-coordinate dynamics solver。兩種 solver path 寫入介面不同 (`dc.set_rigid_body_velocity` vs `dc.set_articulation_joint_velocities`)，不能在同一 USD 上 toggle
3. 未來若要做 single-USD 雙模式（例如為了減少 USD 維護成本），等同於要做 USD-runtime articulation surgery（add/remove ArticulationRootAPI dynamically），目前 Kit 5.1 沒乾淨 API，且必觸發 wheel detachment side-effect

**結論**：兩軌兩 USD 策略由「軟性偏好」升格為「實驗驗證的硬性需求」，後續 ADR / PR 引用此 finding 即可結束「能不能改成一個 USD」這類討論。

**Reconfirm (2026-05-19, user)**：在釐清「2D move + joint 雙介面是否可在同 USD 並存」議題後，user 明確選擇 **launch-time 二擇一 (option 2)** — Profile A 用簡化 USD 只 expose `2d_move/cmd_vel`，Profile B 用完整 USD expose `joint_<N>/cmd_vel`（未來可加 IK 包成 2D 上層介面）。兩 topic 直接並存在同 USD（option 3 同 scene 並存 / single-USD bypass + joint）皆排除。

## Update (2026-05-20) — Model A 軌實作分裂為 A-pure / A-hybrid

ADR-0001 Update (2026-05-20) 把 Model A 細分為兩個子型:

- **A-pure**: 純 Xform 動畫,無 collision,無環境物理。極簡 fallback
- **A-hybrid**(預設): kinematic forklift + dynamic 環境物件,完整 Model A-hybrid 設計見 ADR-0004。Forklift_blocky 是首個實作

本 ADR 兩軌策略不變 — Model A 軌涵蓋 A-pure 與 A-hybrid 兩個子型,獨立於 Model B 軌(C-Phase mecanum 完整物理)。「Model A」在本 ADR 後續預設指 A-hybrid。
