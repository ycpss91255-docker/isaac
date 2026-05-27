# Model A-Hybrid Forklift Block Model

isaac_ws 內為 CoreSAM 上層演算法驗證需要一個叉車模型。原 ADR-0001 / 0003 的 Model A 只是「chassis SE(2) slide」概念,實作上是 OpenBase 的單 base_link 簡化 USD。但驗證後推式貨架對齊邏輯時需要:

1. **可控的牙叉抬升 / 開合** — 模擬叉子伸進托盤、舉起、放下
2. **環境物件物理反應** — 托盤要會掉、被推、被叉起
3. **理想控制** — 命令多少達多少,不要 motion-control noise 污染演算法驗證

OpenBase 的單 base_link 簡化 USD **不足**:沒牙叉、沒抬升、沒環境互動。完整 articulation Model B 則**過度**:把要驗的演算法跟 mecanum 動力學 noise 混在一起。

**Decision**: 新增 Model A-hybrid — **kinematic forklift 5 cube + scripted pickup + dynamic environment**。

## Considered Options

- **(a) 純 Xform Model A**(原 A-pure) — 5 cube 純 visual,driver 每 tick 寫 `xformOp:translate`。沒 collision、沒物理。**演算法看得到 forklift 動,但碰不到任何東西**。範圍太狹隘
- **(b) Kinematic forklift + dynamic env**(A-hybrid,**選此**) — 5 cube `kinematicEnabled=True` + collision,driver 寫 `set_kinematic_target` 跟 USD attr。Pallet / 障礙物用完整 dynamic rigid body。**理想控制 + 真實環境物理**並存
- **(c) 完整 Model B** — 加 mecanum wheels + 完整 articulation + drive PID + IK。完整物理,但開發成本高 + drive lag / friction tuning 干擾演算法驗證。**留給 C-Phase**

## Why (b)

| 需求 | Pure Xform (a) | A-Hybrid (b) | Model B (c) |
|---|---|---|---|
| Chassis 命令 1.5m → 達 1.5m | yes | yes | no(drive lag) |
| 牙叉抬升精準 | yes | yes | no(物理 noise) |
| 牙叉撞托盤有反應 | no | yes | yes |
| 托盤可被舉起 | no(穿透) | yes(scripted pickup) | yes(摩擦力) |
| 開發複雜度 | 低 | 中 | 高 |

A-hybrid 在「理想控制」跟「環境互動」之間找到 sweet spot,正好符合 CoreSAM A/B Phase 的需求。

## Implementation Details

**USD 結構**(`isaac_ws/src/model/usd/robot/forklift_blocky/forklift_blocky.usda`):

```
World/
├── SunLight                              [DistantLight]
├── GroundTiles                           [6×6 checkerboard tiles, CollisionAPI]
├── Forklift/                             [5 kinematic cubes]
│   ├── body         (1.5 × 1.0 × 1.0 m)  [RigidBody, Collision, kinematic]
│   ├── mast_lower   (0.15 × 0.4 × 1.8)   [同上]
│   ├── mast_upper   (0.13 × 0.35 × 1.6)  [同上]
│   ├── carriage     (0.08 × 0.6 × 0.15)  [同上]
│   ├── left_fork    (1.0 × 0.08 × 0.05)  [同上]
│   └── right_fork   (1.0 × 0.08 × 0.05)  [同上]
└── Pallet/                               [dynamic rigid body with gap]
    ├── top_deck     (1.2 × 0.8 × 0.03)   [CollisionAPI, child shape]
    ├── bottom_slab  (1.2 × 0.8 × 0.03)   [同上]
    └── 4 legs       (0.1 × 0.1 × 0.1)    [same, 10cm gap for fork insertion]
```

**Driver**(`isaac_ws/src/script/forklift_blocky_driver_wip.py`):

5 個邏輯維度(`chassis_x, chassis_y, mast_lift, carriage_lift, fork_spread`)→ 6 cube 世界座標。每 tick:

```python
target = dc.Transform()
target.p = (x, y, z)
iface.set_kinematic_target(handle, target)   # PhysX kinematic update
attr.Set(Gf.Vec3d(x, y, z))                  # USD attr → Hydra render
```

雙寫(`set_kinematic_target` + USD attr)的原因:Isaac Sim 5.1 在某些 config 下 kinematic body 的 pose 沒自動 sync 到 USD render layer,顯式 USD attr 寫補上 viewport 同步。

**Pickup state machine**:

```
idle ────[fork_tip 進入 pallet & lift > threshold]────> carrying
                                                            │
carrying ────[lift < drop_threshold]────> idle
                                              │
                                              └─> pallet 回歸 physics(落地)
```

Carrying 狀態下,driver 每 tick `iface.set_rigid_body_pose(pallet, ...)` 把 pallet teleport 到 fork 上方 + `set_rigid_body_*_velocity(pallet, 0)` 抑制 gravity。Drop 後停止寫入,pallet 回歸 dynamic 行為。

**Timeline pause respect**: tick callback 檢查 `timeline.is_playing()`,paused 時凍住 demo 時間軸,resume 從原進度繼續。

## Consequences

- **演算法 demo 完整**:命令端可靠(瞬間追上 target),環境端真實(pallet 物理掉落 / 被推),scripted pickup 取代物理摩擦的不可預期行為
- **可往 Model B 延伸**:per-cube `kinematicEnabled=False` 即可釋放成 dynamic,並逐步加 joint 變成局部 articulation。不需要從零開始
- **可加 dynamic 障礙物**:複製 pallet 的 RigidBody / Collision / Mass pattern 即可,demo 自然包含碰撞效應
- **限制**:
  - 牙叉跟托盤之間沒「摩擦帶動」(scripted attach 取代),所以叉車後退時托盤跟著是腳本而非物理
  - 沒 wheel rotation 視覺(底盤滑行,輪子不轉) — 跟 ADR-0001 (a) Model A 同個 trade-off
  - 完整 articulation 動力學(液壓抬升 / steering Ackermann 等)需切 Model B

## Cross-references

- **ADR-0001**:Model A 範圍 / chassis SE(2) slide 起源
- **ADR-0003**:兩軌策略 — Model A-hybrid 屬 Model A 軌,Model B 軌獨立(C-Phase)
- **`isaac#15`(PoC #59)**:確認 dc.velocity 在 full articulation USD 上不可行,A-hybrid 走 kinematic + scripted 路徑是繞開這個問題的具體方案
- **`isaac#16`** (reframed planning #57):Model A 簡化 USD 在豐富場景下穩定性驗證 — 本 ADR 的 A-hybrid 是該驗證的具體形式
