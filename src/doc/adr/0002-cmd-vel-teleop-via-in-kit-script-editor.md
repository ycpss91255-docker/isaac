# cmd_vel Teleop via in-kit Script Editor + rclpy + dc Velocity Write

在 Isaac Sim 5.1 內把外部 `/cmd_vel` 接到 OpenBase。我們選 **in-kit Script Editor 跑 `cmd_vel_planar_move.py`** —— `rclpy.create_subscription` 訂閱 `/cmd_vel`，每 frame 透過 `omni.isaac.dynamic_control` 的 `set_rigid_body_linear_velocity` 直接寫進 base_link rigid body 速度；base_link `disableGravity=True` + 輪子 drive 全關 → Gazebo `planar_move` plugin 等效行為（**Chassis SE(2) Slide**，見 ADR-0001）。5.1 限制下這是唯一已實機驗證穩定的路徑；6.0 GA 後可遷移到 OnImpulseEvent OmniGraph 純腳本。

## Considered Options

- **(a-blackbox) NVIDIA Tools menu → Holonomic Controller + ArticulationController**: 輪子物理介入，PhysX friction 模型造成 trajectory drift 不等於 cmd_vel
- **(a-fake-α) Action Graph baked into USD + ROS2SubscribeTwist + WritePrimAttribute(`physics:velocity`)**: NVIDIA 零範例；`physics:velocity` 連續寫可能只在 reset 時讀，未驗證
- **(β) OmniGraph Script Node baked into USD + 自寫 Python 積分**: 5.1 USD-embedded Python 安全 gating，每次 kit launch 跳 trust dialog → 違背「zero daily GUI」承諾
- **(γ) in-kit Script Editor + rclpy + `dc.set_rigid_body_linear_velocity`**: daily 點 Script Editor 載 + Run ~1-2 分鐘 GUI；**選此**

## Why (γ)

- 邏輯改動只動 Python，**不烤進 USD**，git diff 完全可讀，code review 直觀
- M1 已驗 rclpy 在 `runheadless.sh -v` Script Editor 內穩定運行
- Chassis SE(2) Slide + dc velocity write 實機驗證 `pos.x` 完美線性跟隨 cmd_vel，**zero wheel-induced drift**
- 對應 `omni.isaac.dynamic_control` 是 NVIDIA 文件支援路徑（雖標 deprecated favor of `isaacsim.*`，但 API 仍可用）
- (a-blackbox) 牴觸 ADR-0001 把 motion control 排在範圍外的決策；(a-fake-α) / (β) 都有 5.1 內未解的 NVIDIA gating / 未驗證問題

## Consequences

- Daily 流程綁定 Script Editor 步驟，**無法 fully autonomous startup**
- USD 內保持乾淨：URDF 重 import 不會 wipe 業務邏輯（all setup 重 Run 自動 re-create）
- 任何 cmd_vel 邏輯改動只需編輯 Python + 重 Ctrl+Enter，**不需重 build USD**
- 6.0 GA 後可平滑遷移到 OmniGraph OnImpulseEvent 純腳本路徑，本 ADR 由未來 ADR superseded
- daily GUI 操作流程記在 `cmd_vel_inkit_teleop.md`

## Update (2026-05-20) — Entrypoint Pattern Superseded by ADR-0005

本 ADR 的 `(γ) in-kit Script Editor` 路徑解了 5.1 的 NVIDIA gating 問題,但建立了一個新問題:LLM agent 無法驅動 sim — 每次 re-run 都需要人在瀏覽器點 Ctrl+Enter,也擋住 `docker exec` 風格的自動化測試。

PoC #15 / Issue ycpss91255-docker/isaac#19 驗證 `SimulationApp({"headless": True, "livestream": 2})` 在現有 `headless` Docker stage 上就跑得起來,不需要新 Dockerfile stage。這條 **standalone-with-livestream** 路徑同時保留瀏覽器 view-on-demand 跟 CLI-driven scripts(`./exec.sh -t headless /isaac-sim/python.sh <script>`),把人 / LLM 的 driver 取消綁定瀏覽器 Ctrl+Enter。

**結果**:`(γ)` 不再是 daily driver 預設;改走 standalone-with-livestream,細節 / trade-off 寫在 `adr/0005-standalone-with-livestream-as-default-dev-entrypoint.md`。本 ADR 的決策依然是「5.1 + bridge ext 條件下 (a-blackbox) / (a-fake-α) / (β) 都不可行」這個歷史結論,只是 entrypoint pattern 從 `(γ)` 換成 standalone-with-livestream(對應 SOP 從 `cmd_vel_inkit_teleop.md` 換成 `standalone_livestream_workflow.md`)。

舊 in-kit Script Editor 流程不刪除,留給:
- 5.1 上偶爾要做 interactive REPL 偵錯(載 stage、手動戳 prim、看 state)
- 將來 6.0 GA 後遷移到 OnImpulseEvent OmniGraph 純腳本路徑前的過渡期 fallback
