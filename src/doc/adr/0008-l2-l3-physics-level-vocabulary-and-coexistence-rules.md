# L2 / L3 Physics Level Vocabulary and Coexistence Rules

ADR-0004 picked "kinematic forklift 5 cube + dynamic environment" but never named the pattern formally. Future Model A variants (升 mast 到 joint-drive、加 wheel 視覺旋轉、openbase 改寫 etc.) 都需要一個 per-body physics level vocabulary 來描述要動哪格、不動哪格,以及描述 PhysX 對 mixed scene 的官方保證。

**Decision**: 採 **L2 (Kinematic) + L3 (Dynamic + Joint) 兩階詞彙**,不引入 L0 (Xform-only)。USD variant 用 `<model>_<suffix>` 命名(`forklift_blocky_kin` / `forklift_blocky_kin_fork_dyn` 等),不再延用 Model A/B/C/D 字母序。任何 body 升 L3 即跨入 ADR-0003 的 **Motion-Control Simulation** 軌(Model B),不再屬 Model A 範疇。

## Considered Options

- **(a) L0 / L2 / L3 三階詞彙** — 把 ADR-0004 拒絕的「Pure Xform Model A」(無物理) 也納入詞彙表當第 0 階。理由:語言完整、Bisection 思路(從 xform 起一步步加物理) 直觀
- **(b) L2 / L3 兩階詞彙**(**選此**) — L0 從詞彙表移除。理由:L0 對 interactive forklift sim **沒實際用途**(無 collision 就無法跟 dynamic pallet 互動),保留在 vocabulary 只會讓人誤以為它是合法的設計起點。Bisection 概念仍在,但起點是 L2(現況) 而非 L0
- **(c) 沿用 Model A/B/C/D 字母序** — 加 Model C、Model D 表示中間階。**拒絕**:ADR-0003 已把 Model A/B 定義為「驗證目的」(Upper-Layer Algorithm vs Motion-Control Simulation),不是「物理理想化程度」;用同字母 overload 兩個獨立 axis 會讓「Model B」既指驗證軌道又指物理階,長期解讀混亂

## Why (b)

研究 NVIDIA Isaac Sim 5.1 / PhysX 5.4.1 官方文件後,L2 是 forklift 這類「ideal actuator + 真實接觸」場景的 textbook 答案,不是 L0 與 L3 之間的折衷:

| 能力 | L0 Xform-only | L2 Kinematic | L3 Dynamic+Joint |
|---|---|---|---|
| 視覺渲染 | yes | yes | yes |
| Collision shape 存在 | **no** | yes | yes |
| 可推開 dynamic body | **no** | yes | yes(透過力) |
| 被 contact query 偵測到 | **no** | yes | yes |
| 受力學影響 | no | no | yes |
| 命令即位置 | yes | yes | no |

forklift_blocky 場景 fork 要插 pallet、chassis 要 collide 障礙物 — 三個 collision 相關的能力 L0 全 no,所以 L0 對應用範圍**根本進不去**;L2 / L3 之外的「第四種 pattern」(現有 openbase 走的 dynamic + 每 tick 強制覆寫 velocity + gravity disabled) 是 workaround,非 PhysX 官方推薦,新詞彙不收。

PhysX 5.4.1 RigidBodyDynamics 原文把 L2 列為 canonical use cases 的核心:moving platforms、character controllers、scripted motion with collision response — 都不含 joint。Isaac Lab make_fixed_prim doc 確認「kinematic approach requires no joint setup」。

## L2 契約(來自 PhysX 5.4.1 官方)

1. **不需要 joint**。USD `physics:kinematicEnabled = true` + driver 每 tick `set_kinematic_target(pose)`,搞定。多 body 系統(如 forklift 5 cube) 在 driver 端做 forward-kinematics 自行計算 child pose,joint 是 optional 選項而非必須
2. **命令即位置**:「Each simulation step PhysX moves the actor to its target position, **regardless of external forces, gravity, collision, etc.**」— 無 lag、無 approximation。pallet 多重、被外物撞、重力作用,kinematic body 都不受影響
3. **必須用 `setKinematicTarget()`,不能 `setGlobalPose()`**:後者繞過 contact integrator,L2 ↔ L3 互動失效(pallet 感知不到 fork 移動)。USD `xformOp:translate.Set()` 屬於 setGlobalPose 等價物,只能當作 USD render layer 的補寫,**不能** 取代 set_kinematic_target

## L2 + L3 共存規則(來自 PhysX 5.4.1 官方)

1. **單向力傳遞**:L2 推 L3 視同 infinite mass(L3 被推開);L3 不能反推 L2。「A kinematic actor can push away dynamic objects, **but nothing pushes it back**」
2. **L2 ↔ L3 contact 預設 report**,但 **L2 ↔ L2 跟 L2 ↔ static 預設不 report**。要 enable 後兩者需設 `PxSceneDesc::kineKineFilteringMode` / `staticKineFilteringMode`。對 forklift_blocky 影響:fork↔carriage(L2↔L2) 互撞 PhysX 不報事件 — 不重要,因為 driver 自己算 pose 已避免互撞
3. **L2 會 squish 夾在 L2/static 中間的 L3**:「a kinematic can easily squish a dynamic actor against a static actor」,squished L3 會深入穿透。設計責任在應用層(driver 端避免、或接受 limitation)
4. **Articulation tree 內 link 不能 kinematic**:「links cannot be kinematic」。但 standalone L2 body + standalone L3 articulation 在同 scene 可共存,L2/L3 之間可透過 standalone rigid-body joint 連接(loops 機制)。對 forklift_blocky **無影響**因為 5 個 cube 都是裸 kinematic body 沒有 articulation tree

## Naming Scheme

- USD 變體檔名:`<model_name>_<suffix>.usda`
- Suffix 文法:列出**有物理的部位** + 其 level
  - `_xform` 不採用(L0 已被排除)
  - `_kin` = 該 model 既有部位全 L2(forklift_blocky 預設)
  - `_<part>_dyn` = 列出來的部位升 L3,其餘維持 baseline
- 命名範例:
  - `forklift_blocky_kin` = ADR-0004 現況(5 cube 全 L2 + pallet L3 + scripted attach)
  - `forklift_blocky_kin_fork_dyn` = fork L3、其餘 L2(若未來想驗夾取力學)
  - `openbase_kin` = openbase 改成正規 L2(取代現有 dynamic + velocity override pattern)

> **跨軌警示**:任何 `_<part>_dyn` 變體屬 ADR-0003 **Motion-Control Simulation** 軌(Model B),不再屬 Model A。命名上可加 `_b_` 前綴(如 `forklift_blocky_b_fork_dyn`)強調歸屬,或用獨立 Model B 命名空間,留待真要做 L3 variant 時的後續 ADR 決定

## Consequences

- **CONTEXT.md 新增 L2 / L3 兩詞條**(已更新):未來討論 forklift / openbase / 其他 sim asset 時統一用此詞彙,避免「kinematic vs scripted vs ideal」等模糊用語
- **openbase L2 migration 完成**(ycpss91255-docker/isaac#23):新增 `openbase_l2.usda` sublayer override(`kinematicEnabled=True` + `disableGravity=True`),`cmd_vel_planar_standalone_l2.py` L2 driver(Euler 積分 + `set_rigid_body_pose`),smoke + 4 項 stability test 全 PASS(pose tracking 0.0000 err, z-drift 0.0000, no NaN, multi-waypoint clean)。原 `move_openbase_planar*.py` 保留作歷史參考(dynamic+velocity-override pattern)
- **isaac#16 解除 block**:stability test 已在正規 L2 上跑過 sustained motion;#16 可直接引用此結果或擴展更豐富場景測試
- **forklift_blocky 不需立刻動**:現況本就是 L2,符合新詞彙、符合 PhysX 官方契約。是否升 L3 是另一個獨立決策,屬未來 ADR(若做)
- **未來 USD 變體有清晰命名規則**:加新檔不再要新發明字母,直接 `forklift_blocky_<新 suffix>.usda`
- **明確排除「在 articulation tree 內混 L2」這條路**:任何想把 forklift 整體包成 articulation 的提案,必須先處理 chassis 無法 kinematic 的限制(走 separate kinematic anchor + standalone joint to dynamic articulation 的 hybrid 模式)

## References

- PhysX 5.4.1 Rigid Body Dynamics(Kinematic Actors): https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/RigidBodyDynamics.html
- PhysX 5.4.1 Rigid Body Collision(filtering modes): https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/RigidBodyCollision.html
- PhysX 5.4.1 Articulations(links cannot be kinematic): https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/Articulations.html
- PhysX 5.4.1 Advanced Collision Detection(squish / CCD): https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/AdvancedCollisionDetection.html
- Isaac Lab — Making a physics prim fixed: https://isaac-sim.github.io/IsaacLab/main/source/how-to/make_fixed_prim.html
- Isaac Sim 5.1 Physics Simulation Fundamentals: https://docs.isaacsim.omniverse.nvidia.com/5.1.0/physics/simulation_fundamentals.html

## Cross-references

- **ADR-0001**:Chassis SE(2) Slide / Model A 起源 — 本 ADR 把它的「ideal actuator」隱含選擇形式化為 L2
- **ADR-0003**:兩軌策略(Model A / Model B) — 本 ADR 增補「物理階」這條 orthogonal axis,並 lock 「升 L3 即跨軌」邊界
- **ADR-0004**:Model A-hybrid forklift_blocky — 本 ADR 把它的 5 cube 配置形式化為 `forklift_blocky_kin` 命名
- **CONTEXT.md**:本 session 已新增 L2 / L3 詞條
- **isaac#16**:reframed planning #57 — 本 ADR 縮小其範圍至「sustained motion stability」,前置 openbase L2 migration
