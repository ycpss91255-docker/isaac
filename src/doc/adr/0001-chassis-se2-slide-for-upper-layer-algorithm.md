# Chassis SE(2) Slide for Upper-Layer Algorithm Development

當前在 isaac_ws 內驗證 CoreSAM **Upper-Layer Algorithm**（感知 + 對齊幾何）。我們刻意把 OpenBase 模擬成完美 SE(2) actuator —— Action Graph 內 `ROS2SubscribeTwist → WritePrimAttribute(/open_base/base_link, physics:velocity)`，整台車身平移、輪子不轉、`/joint_states` 全 0。**Motion-Control Simulation**（mecanum kinematics、輪胎打滑等）排除在範圍外，假設運動控制完美無誤。

## Considered Options

- **(a) Chassis SE(2) Slide** — `openbase_minimal.urdf` 單一 `base_link`，graph 寫 RigidBody 的 `physics:velocity`。**選此**
- **(b) Full Articulation** — 完整 32-link `openbase.urdf`，graph 接 HolonomicController + ArticulationController，模擬 3 輪 mecanum 真實運動

## Why (a)

上層演算法開發階段不想處理運動控制狀況，假定它完美無誤就好。CoreSAM 對齊驗證需要的是 base_link 處在正確 SE(2) pose 讓 camera mount 跟著移到能驗 mask alignment 的位置 —— 輪子轉不轉、有沒有打滑都跟 mask 投影到 base_link 的幾何鏈無關。(b) 複雜度高 1-2 個量級且當前用不到。

## Consequences

- `/joint_states` 在 isaac_ws 內無意義，下游應用層不該依賴
- camera mount TF 鏈仍正確（跟著 base_link 移動），mask → 3D 投影鏈完整可驗
- 若未來要在 SIM 內驗 VSLAM / wheel odometry / 輪胎打滑情境，需切換至 (b)，會涉及 URDF 重 import + graph 重建
- 後續 ADR-0003 將 (a)/(b) 切換正式化為 **Model A / Model B 兩軌策略**：A/B-Phase 用 Model A (本 ADR 範圍)，C-Phase 切 Model B 量化 sim-real gap。兩軌並行不取代

## Update (2026-05-19) — PoC #59 結果：Model A 不可在 full articulation USD 上偷渡

PoC #59 在 `openbase_free.usda`（完整 32-link articulation USD，本 ADR 中的選項 (b)) 上實驗 4 種 Model A bypass 路徑：

| MODE | 機制 | 結果 |
|---|---|---|
| A | wheel drive=0 + base_link disableGravity + `dc.set_rigid_body_linear_velocity` | FAIL — articulation kinematics solver 從 joint state 倒算 base velocity，蓋掉 rigid body velocity write，`lin` readback = 0 |
| B | A + `PhysxArticulationAPI.articulationEnabled=False` | velocity 寫得進 (`lin` readback = 0.5)，但 disable articulation 也 disable PhysX integration → `pos` 完全不動 |
| C | `isaacsim.core.api.World + SingleRigidPrim.set_linear_velocity` | FAIL — 新 API 對 articulation link silently no-op，`lin` readback = 0 |
| **D** | **B 的 articulation disable + `dc.set_rigid_body_pose` 每 tick teleport** | **數值 PASS** — `pos.x` 完美 tracking `expect_x`（t=17s → +8.50m），證明 pose teleport 路徑技術可行 |

**但 MODE D 的副作用**：disable articulation root 同時解開 wheel ↔ base 的 joint constraint，wheels (back/left/right_rim) 變 free rigid body 從 base 上散落，視覺破碎。

**Implication**：
- **Model A 路徑（無論 velocity 或 pose）只能在 (a) 簡化 USD（單一 base_link，無 articulation）上乾淨運作**，不能套在 (b) full articulation USD 上
- 任何嘗試在 full articulation USD 上跑 Model A 都需要某種 USD 手術（remove ArticulationRootAPI / reparent wheels / 拔 root_joint），代價超出 Model A 的「乾淨無 motion control noise」初衷
- 此 finding 直接餵給 ADR-0003：兩軌不只 USD 維護考量，**dc.velocity / pose-write 路徑與 articulation USD 物理上不相容**，是技術硬性 ground truth，而非可選 trade-off

## Update (2026-05-20) — Model A 細分為 A-pure / A-hybrid

實作後 Model A 自然分裂為兩個子型,擇用視應用需求:

| 子型 | Forklift cube | 環境 | 用途 |
|---|---|---|---|
| **A-pure** | Xform-only(無 collision / 物理) | Xform-only | 純動畫,fork 穿過物件。範圍狹隘,實務不採用 |
| **A-hybrid**(標準採用) | kinematic RigidBody + Collision | dynamic RigidBody(pallet / 障礙物) | 演算法驗證 + 環境互動。詳見 ADR-0004 |

「Model A」在後續 ADR / PR / 文件預設指 **A-hybrid**。A-pure 純粹概念存底,可作為 fallback 或極簡 demo。

Forklift_blocky 是 A-hybrid 首個具體實作 — 5 cube kinematic + scripted pickup state machine + dynamic pallet 環境物理。完整設計決策見 ADR-0004。
