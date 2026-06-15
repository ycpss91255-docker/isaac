# Adopt Isaac Lab `sim_utils` as the Scene-Spawn Backend

The M2 MVP (#146) shipped the `isaac_devkit` scene layer built on **raw `pxr.Usd`**:
`scene.build_scene` spawns ground / lights / robot / object prims with `stage.DefinePrim` +
`GetReferences().AddReference` + variant selection, and `model_import.import_urdf` wraps the
Isaac Sim URDF importer via `omni.kit.commands`. That layer re-implements, by hand, what NVIDIA
Isaac Lab's `sim_utils` spawners already provide as a maintained, config-driven interface.

This ADR adopts Isaac Lab as a **base tool** (alongside Isaac Sim itself) and re-bases the
"put things into the scene" half of the framework onto Isaac Lab's spawners, while explicitly
**preserving** the ROS-2-by-default bridge (`sensors` / `ros_io`) that is this base repo's
differentiator. It supersedes the raw-`pxr` spawning decisions implied by ADR-0017 sections 3
and 9, amends ADR-0009 (driver) and ADR-0008 (materials/variants), and reshapes the milestone
plan (the re-base lands **before** the `v1.0.0` tag). The grill record that produced it is in
the convergence PRD (`doc/PRD-template-convergence.draft.md`).

Running example unchanged: **camera-bot** (one chassis body, one camera on `base_link`,
publishes a ROS 2 camera topic, consumes `/cmd_vel`).

## Context

- Isaac Lab is RL-/tensor-first; it is **not** ROS-2-first. Its sensors expose data as PyTorch
  tensors (`scene["camera"].data.output`), not ROS 2 topics.
- The decisive finding (Isaac Lab maintainer, discussion #187): the recommended way to get ROS
  2 out of Isaac Lab is the **OmniGraph ROS 2 bridge** (`ROS2CameraHelper` etc., built with
  `og.Controller.edit()`, reading the render product / USD stage), the same mechanism
  `isaac_devkit` already uses. Publishing tensors from Python via rclpy is "incredibly slow and
  a bottleneck" and is explicitly not the path. The OmniGraph bridge runs inside the standalone
  `SimulationApp` that Isaac Lab's `AppLauncher` launches.
- Therefore the ROS 2 outlet is **orthogonal to how the scene is spawned**: it attaches to USD
  prims / render products regardless of whether they were spawned by raw `pxr`, by `sim_utils`,
  or by an `InteractiveScene`. Adopting Isaac Lab spawning does not touch the ROS 2 layer.

## Decision

### 1. Spawn backend = Isaac Lab `sim_utils`, at the spawner level ("A"), C-upgradeable

`scene.build_scene` is rewritten to spawn via Isaac Lab `isaaclab.sim` (`sim_utils`)
config-dataclass spawners — `GroundPlaneCfg` / `DistantLightCfg` / `UsdFileCfg` /
`UrdfFileCfg` + the physics-property cfgs — calling `cfg.func(prim_path, cfg, translation=...)`
instead of hand-rolled `DefinePrim` / `AddReference`. The raw-`pxr` spawning path is removed.

We adopt the **spawner level** (the `spawn_prims` tutorial surface), **not** the higher
`InteractiveScene` level, now. But the adapter (decision 3) emits Isaac Lab cfg **objects**, so
the same cfg objects can later be collected into an `InteractiveSceneCfg` (decision: "C") when
— and only when — a future need for parallel environments / RL-style domain randomization
arrives. The cfg objects are the stable seam between "A now" and "C later"; the YAML schema and
the adapter do not change across that upgrade.

`InteractiveScene`'s extras (`num_envs` cloning, tensor data buffers, gym-style `reset`) are
RL-training machinery that this ROS-2-service base repo does not use today, which is why C is
deferred, not adopted.

### 2. ROS 2 outlet stays OmniGraph (`sensors` / `ros_io` unchanged)

`sensors.py` (OmniGraph `ROS2CameraHelper` publish chain) and `ros_io.py` (OmniGraph Subscribe
node, no rclpy executor) are **kept as-is**. This is NVIDIA's recommended ROS 2 path for Isaac
Lab, it is M2-proven (the #146 GPU integration published real frames), and it is decoupled from
the spawn backend. The tensor -> rclpy publish path is **rejected** (slow per the maintainer;
it would also re-introduce the rclpy/Kit signal-init conflict `ros_io` was designed to avoid).

### 3. YAML stays the curated user contract; an adapter maps YAML -> Isaac Lab cfg

Isaac Lab's native config language is Python `@configclass` dataclasses (overridable from
YAML/CLI via Hydra / `update_class_from_dict`), shaped like its RL env. We do **not** expose
that surface to users. The `isaac_devkit` three-file YAML (scene / robot / object, ADR-0017
section 4) remains the user-facing contract; a new adapter in the framework translates the
validated YAML dict into Isaac Lab cfg objects.

Control model — **curated fields + raw passthrough**, generalizing the catalog/`overrides:`
pattern ADR-0017 section 5 already uses for sensors:

- **Curated fields** (`pose.xyz`, sensor catalog name, `mobility`, SDF-like names) — the
  framework owns these: validation, naming, `NotImplementedError` boundaries, docs. The common
  ~90% path. Curated names stay framework-stable (not coupled to Isaac Lab field renames).
- **`spawn_overrides:` raw passthrough** — a dict spread directly onto the Isaac Lab cfg
  constructor kwargs (its keys are Isaac Lab cfg parameter names). Any Isaac Lab parameter
  (physics props, scale, material) is reachable without the framework wrapping each one, and no
  Isaac Lab capability is lost.

Sketch:

```python
def to_isaaclab_cfg(robot_yaml: dict) -> "sim_utils.UsdFileCfg":
    return sim_utils.UsdFileCfg(
        usd_path=resolve_model_path(robot_yaml["model"]),
        **robot_yaml.get("spawn_overrides", {}),   # raw passthrough
    )
```

### 4. Isaac Lab is a baked base tool; `isaac_devkit` stays mounted

Isaac Lab is installed **into the image**, exactly like Isaac Sim — it is a base tool, not the
dev-iterated framework. This does **not** contradict ADR-0017 section 2: that "mount, not
baked" rule governs `isaac_devkit` (the framework the consumer iterates and bumps via
submodule), whereas base tools (Isaac Sim, now Isaac Lab) have always been baked (the base
image is `nvcr.io/nvidia/isaac-sim:5.1.0`). ADR-0017 section 2 is amended to state the
distinction explicitly: **base tools = baked + pinned; framework = mounted + git-commit
versioned.**

Install: a Dockerfile layer installs Isaac Lab **pinned to 2.3** against the existing
`/isaac-sim` Python (3.11), using Isaac Lab's documented install-against-existing-Isaac-Sim
flow. Pinned like every other dependency in the repo.

### 5. Version / compatibility

Isaac Lab **2.3 GA is built on Isaac Sim 5.1** (NVIDIA's recommended pairing); Isaac Sim 5.x
requires Python 3.11, which the container already runs. The supported stack is therefore
**Isaac Lab 2.3 + Isaac Sim 5.1 + Python 3.11** — no version blocker. The Compatibility Matrix
(PRD) gains an "Isaac Lab" axis = 2.3, exercised by the example GPU integration.

### 6. `model_import` delegates URDF -> USD to Isaac Lab `UrdfConverterCfg`

The hand-rolled `omni.kit.commands` importer is replaced by `isaaclab.sim.converters`
`UrdfConverterCfg` (which wraps the same `isaacsim.asset.importer.urdf` engine). Its **lazy
cached conversion** (regenerate only when the URDF changes, given a `usd_dir`) preserves the
existing offline-convert-and-commit workflow. Kept: the offline committed USD (reviewable,
deterministic) spawned at runtime via `UsdFileCfg`, and the **L1 `PrimSummary` diff=0
contract** — the contract is about the output USD structure, independent of who imported, so it
survives as a test on the Isaac-Lab-produced USD. Cost: `parse_urdf_expected` is **recalibrated
once** to the Isaac Lab importer's output conventions (prim naming, the instanceable wrapper).
Bonus: Isaac Lab outputs **instanceable** USD (the format C's cloning needs — C-ready for free)
and exposes joint-drive gains cfg the old path did not.

### 7. `materials`: color is a material parameter, not a variant set

The iron / green / blue 擋板 (and analogous) variants differ by **color**, which is a material
**parameter** on the same mesh/texture — not different assets. Color is set (and randomized for
domain-randomization image generation) via an Isaac Lab material cfg
(`sim_utils.PreviewSurfaceCfg(diffuse_color=...)` or an MDL cfg with a color param), carried
through the `spawn_overrides` passthrough. The USD **variant-set** machinery in `materials.py`
is therefore **dropped for color-only variants**. ADR-0008's `<model>_<suffix>` variant naming
is retained **only** for variants that are structurally distinct (different mesh / topology /
texture file), which is verified against the actual assets at the forklift migration (#136); on
current evidence (one texture, color-driven) the forklift variants are color-only. This amends
ADR-0008 (the variant-set emphasis) and supersedes the "variant single owner" / "3b" thread in
ADR-0017 section 9 for the color case.

### 8. `driver`: adopt `AppLauncher` + `SimulationContext` now

To keep the eventual A -> C transition cheap, the driver aligns with Isaac Lab **now**, not
later:

- Launch via Isaac Lab `AppLauncher` instead of a raw `SimulationApp`. The existing
  `ISAAC_LIVESTREAM` (0/1/2) maps directly onto `AppLauncher`'s `HEADLESS` / `LIVESTREAM={1,2}`
  env vars (CLI args override), so `parse_livestream_env` becomes "set these env/args".
  `enable_cameras` must be set so cameras render under headless (watch the known
  headless+enable_cameras issue #3250 at migration; the M2 GPU integration already renders
  cameras headless, so this path is validated there).
- Run the sim loop via `SimulationContext` (`sim.step()`), the loop manager `InteractiveScene`
  (C) pairs with — switching now makes the C step small.
- The `IsaacDriver` lifecycle hooks (`setup` / `main` / `shutdown`, ADR-0009) are retained as a
  thin wrapper over `AppLauncher` + `SimulationContext`. This amends ADR-0009: the lifecycle
  pattern it described "as aligned with Isaac Lab" is now actually realized on Isaac Lab's
  primitives, and the driver lifecycle in ADR-0017 section 9 changes its first line from
  `SimulationApp(parse_livestream_env(...))` to `AppLauncher(...).app` + `SimulationContext`.

## Consequences

- `scene.build_scene` is rewritten as the YAML -> Isaac Lab cfg adapter; the raw-`pxr` spawn
  path is removed. `model_import` delegates to `UrdfConverterCfg`. `materials.py` slims to (at
  most) the structurally-distinct-variant case. `driver.py` moves onto `AppLauncher` +
  `SimulationContext`. `sensors.py` / `ros_io.py` are untouched.
- Timing: the re-base lands **before** `v1.0.0` (the tag is born as the Isaac Lab version).
  The M2 example + GPU integration are reworked once onto the new spawn backend; a new
  "Isaac Lab re-base" milestone is inserted ahead of the forklift migration.
- ADR-0017 sections 2 (base-tool-baked vs framework-mounted), 3 (module set responsibilities),
  and 9 (driver lifecycle first line + variant-owner note) are amended; ADR-0009 (AppLauncher +
  SimulationContext) and ADR-0008 (variant-set scope) are amended. The PRD A2 / A6 / A7 /
  Compatibility Matrix / Implementation Decisions / Milestone plan / Risks are updated.
- New, bounded cost: a one-time `parse_urdf_expected` recalibration (decision 6) and the
  `enable_cameras`+headless watch (decision 8). The L1 / L2 / L3 / L4 strong-assertion test
  contract (ADR-0017 section 7) is unchanged in intent; only L1's expected-prim baseline is
  recalibrated.
- The base image grows by the Isaac Lab install layers (modest relative to the ~15 GB Isaac Sim
  base). Isaac Lab 2.3 / Isaac Sim 5.1 / Python 3.11 pins are added to the dependency set.

## Cross-references

- PRD: `doc/PRD-template-convergence.draft.md` — Implementation Decisions, A2 (lifecycle),
  A3 (scene), A6 (versioning / pin), A7 (API contract), Compatibility Matrix, Milestone plan.
- ADRs: 0017 (sections 2/3/9 amended), 0009 (driver — AppLauncher + SimulationContext),
  0008 (materials/variant scope), 0006 (sensor schema — unaffected, ROS 2 outlet unchanged).
- Isaac Lab references: spawn_prims tutorial (`sim_utils` spawners); InteractiveScene tutorial
  (the deferred "C"); discussion #187 (OmniGraph ROS 2 bridge is the recommended outlet, in
  Isaac Lab too); `isaaclab.sim.converters` (`UrdfConverterCfg`); AppLauncher deep-dive
  (`HEADLESS` / `LIVESTREAM` env); issue #3250 (headless + enable_cameras watch).
- Decisions superseded/amended here originate in the M2 MVP (#146) raw-`pxr` scene layer.
