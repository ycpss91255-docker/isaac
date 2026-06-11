# Isaac Base Repo Convergence: `isaac_devkit` Contract, Scene/Sensor Schema, and Test Contract

This repo converges from a research+env monorepo into the Isaac robot-simulation **base repo**:
env (Dockerfile / `.base` / compose) + a mounted `isaac_devkit` Python framework + one
ROS2-by-default bidirectional example. Application content (the forklift scenario and its
models / drivers / scenes) migrates to `ycpss91255-research/isaac-forklift` (#136). The full
rationale lives in the convergence PRD (`doc/PRD-template-convergence.draft.md`); this ADR is
the **committed architecture contract** (PRD "Finalized Issue Breakdown" row 2, issue #128):
consumers code against the final shape from day one, while the implementation grows
incrementally behind it (schema locked, implementation incremental; unimplemented paths raise
`NotImplementedError`).

Running example throughout: **camera-bot** — a minimal robot (one chassis body, one camera on
`base_link`) that publishes a ROS 2 camera topic and consumes `/cmd_vel`. It replaces the
forklift as the generic example so that base-repo documents carry no application vocabulary.

## Decision

### 1. Base-repo positioning

The repo's role mirrors `ycpss91255-docker/base`: it contains a runnable example, but its
primary job is to be the foundation that downstream scenario repos consume. Consumption model
(PRD A6, decided): a parent workspace holds `src/docker` (a **git submodule** pinned to a
semver tag of this repo) next to `src/isaac` (the consumer's own robot content); the whole
workspace mounts into the container. `new-workspace.sh` scaffolds this in one step (#134).
Target state: zero application-specific content in base (purity grep, M3 metric, enforced in
#137 after the migration in #136).

### 2. Framework install = mount, not baked

`framework/isaac_devkit/` rides the workspace mount into the container
(`~/work/src/docker/framework`) and is added to `PYTHONPATH`. There is **no** Dockerfile
`pip install`, no baked copy, no version=image coupling. Framework version = the git commit
the consumer's submodule pins. Editing the framework takes effect immediately under the mount;
bumping the submodule propagates fixes with **no image rebuild**. All decisions derived from a
baked model (live-mode toggles, bump+rebuild flows) are void.

### 3. `isaac_devkit` module set

Deep modules, each split into a pure half (module level, Isaac-free) and an Isaac half
(function-local imports only — see invariant in section 8):

| Module | Layer | Responsibility |
|---|---|---|
| `model_import` | L1 | URDF -> USD import, returns a verifiable `PrimSummary` |
| `materials` | L2 | material binding + USD variant sets; **single owner of variant selection** |
| `sensors` | L3 | catalog/placement resolution + OmniGraph -> ROS 2 publish wiring |
| `ros_io` | input | ROS 2 inbound via OmniGraph Subscribe node (not an rclpy executor) |
| `scene` | — | three-file scene load (pure) + stage build (Isaac) |
| `driver` | L4 | `IsaacDriver` lifecycle (lifecycle-only pattern per ADR-0009) |

`__init__.py` is a curated re-export surface; packaging via `pyproject.toml`;
`isaac_devkit.__version__` tracks the repo tag.

### 4. Three-file scene

| File | Holds | Notes |
|---|---|---|
| `scene.yaml` | environment + imports of the other two files | |
| `robot.yaml` | entities that move on their own; nests `sensors:` placements | |
| `object.yaml` | passive entities | each entry declares `mobility: dynamic\|static` |

Every entry carries an `xyz` / `rpy` placement. The classification rule is "can it move on its
own?" (robot vs object). The schema (three files + catalog/placement + `link` + `overrides:` +
`mobility` + SDF-like naming) is locked by this ADR; v1 implements the subset the example uses
(camera + `base_link` mount + topic override + `/cmd_vel` input) and raises
`NotImplementedError` elsewhere (lidar/imu/zed Isaac-side, multi-instance auto-namespace).

### 5. Sensor catalog / placement (two-tier) + three-tier resolution

**Catalog (tier 1)** — the full sensor spec, no mount information. It exposes **all**
Isaac-adjustable parameters (camera: resolution / fps / fov / aperture / focal length /
clipping / projection; lidar: profile or custom config; imu: rate / filter). Where SDF has a
corresponding name the SDF name is used; Isaac-only parameters keep their Isaac names.
Per-stream overrides inside a catalog entry use the key `stream_overrides:` (renamed to avoid
colliding with the placement-level `overrides:`).

**Placement (tier 2)** — nested under a robot/object entry's `sensors:` list, two blocks:
(1) mount: `sensor` (catalog entry name) + `link` (URDF link name, optional, default
`base_link`) + `xyz` / `rpy`; (2) `overrides:` deep-merged over the catalog entry.

Camera-bot example (`robot.yaml` excerpt):

```yaml
robot:
  model: "robot/camera_bot/camera_bot.usda"
  pose: {xyz: [0, 0, 0], rpy: [0, 0, 0]}
  sensors:
    - sensor: front_camera        # catalog entry name
      link: base_link             # default; any URDF link of the robot
      xyz: [0.2, 0.0, 0.3]
      rpy: [0.0, 0.0, 0.0]
      overrides:
        fps: 15                   # deep-merge over the catalog entry
        ros: {topic: "/camera_bot/front"}
```

**Three-tier resolution** (highest priority first):

1. user catalog — `src/isaac/sim/config/sensor/` in the consumer workspace
2. base default catalog — ships **inside `framework/isaac_devkit/`** (arrives by mount;
   submodule bump updates it); consumers get sane defaults with zero catalog authoring
3. NVIDIA Isaac builtin profiles

Tiers deep-merge (base default over NV builtin, user over base default). Deep-merge semantics
for list-valued fields = **replace**, not append. When no topic override is given, the entity
name becomes the topic namespace prefix (v1 stub acceptable).

**Honest pure/Isaac split for resolution**: *pure* = read YAML, validate schema, deep-merge,
compute the expected prim-path string from naming rules (hosted-testable, no GPU); *Isaac* =
verify the `link` prim actually exists and attach (needs a live stage).

**Error contract**: `link` not found -> raise `LinkNotFoundError`; catalog miss across all
three tiers -> `SensorNotFoundError`; unimplemented sensor paths -> `NotImplementedError`.

### 6. ROS 2 bidirectional bridge by default

Two-sided topology, structurally embodied in the example (#131/#133):

- **Isaac side**: the driver runs via `/isaac-sim/python.sh` in the Isaac container (it cannot
  be an ament package — Isaac's bundled Python rules that out). Outbound: `sensors` builds the
  OmniGraph -> ROS 2 publish chain. Inbound: `ros_io` uses an **OmniGraph ROS 2 Subscribe node
  whose output is read from a graph attribute** — no rclpy executor is spun up, which sidesteps
  the rclpy/Kit signal-init ordering conflict.
- **App side**: an ament package (templates for both `ament_python` and `ament_cmake`) runs in
  a sibling ROS 2 Humble container; algorithms stay standard ROS 2.

The framework owns the bridge wiring in both directions; controller logic stays in driver
subclasses (controller abstraction deferred until a third robot — Rule of Three).

### 7. Test contract

**Four axes**:

| Axis | Scope | Runner |
|---|---|---|
| Lint | ShellCheck / Hadolint / ruff / mypy / ament_lint, zero tolerance | hosted |
| Smoke | env + wrapper + hooks (bats) | hosted |
| Unit | framework pure surface + import-safety, no Isaac | hosted |
| Integration | the example end-to-end **only** | self-hosted GPU |

**Pytest parity baseline = 126** (115 unit + 11 integration). The framework extraction (#130)
ports the existing pytest suites to `isaac_devkit.*` with external-behavior assertions
preserved, commits a pytest-count baseline file of 126, and CI asserts "collected pytest >=
baseline and all green", aggregated across the two runners. Staged acceptance: M1 gate =
hosted-unit >= 115 all green; the full 126 cross-runner aggregate is asserted at M2 (the 11
GPU-integration tests arrive with #132). A skipped GPU job is **not** green. New-contract
tests (PrimSummary diff=0, `RosIo.latest`, lifecycle spy — all greenfield) are additions on
top of the baseline, not substitutes for ported tests.

**Marker-line acceptance** (promoted from existing integration-runner prior art to the
mandatory mechanism for all GPU integration): a run passes when both marker lines `[BOOT OK]`
and `[EXIT CLEAN]` appear in output — **not** by process returncode, which Kit's `_exit(0)`
swallows. SIGINT injection must show `shutdown()` was called. Lifecycle call order
(`load_scene -> build_scene -> setup_sensors -> setup_ros2_io -> setup -> main`) is verified
hosted via a pure-side spy.

**Per-layer strong assertions**: L1 — `GetPrimAtPath(...).IsValid()` + URDF-parse-expected vs
`PrimSummary`-actual prim/joint diff = 0; L2 — `GetVariantSet(name).GetVariantSelection()`
matches + bound MDL path hits; L3 (camera, implemented path) — topic exists + message type +
`frame_id` matches + >= 1 message within N seconds (lidar/imu v1: unit asserts the stub raises
`NotImplementedError`, and a pure-side test asserts their locked catalog schema validates and
resolves to the expected prim-path string); ros_io — publish one `/cmd_vel`, `latest()`
returns a matching message within K ticks; no message returns `None` without blocking.

**GPU CI policy**: integration runs headless (no livestream — avoids the known
bridge+livestream crash, #228 lineage); timeout = boot budget x 1.5; at most 1 logged retry;
GPU runner unavailable -> job `skipped` but the PR is not mergeable on hosted-only green.

**Coverage**: framework pure surface line coverage >= 80% with a committed ratchet baseline
(`pytest --cov-fail-under=<baseline>`, no PR below baseline). Isaac-side function-local code
is excluded via `pyproject` `[tool.coverage]` configuration (source scope / `exclude_also`
regex), **never** via inline coverage-ignore comments.

### 8. Import-safety invariant (PRD A1)

Each module keeps pure functions at module level; every Isaac import (`omni`, `pxr`,
`isaacsim`) is **function-local**. Enforcement, hosted with no Isaac installed:

1. Loop `importlib.import_module("isaac_devkit.<each>")` over every module **including** the
   `__init__` re-export surface, then assert `sys.modules` contains none of `omni` / `pxr` /
   `isaacsim`. "Import succeeded" alone is not sufficient.
2. A ruff/AST rule forbids module-top `import omni|isaacsim|pxr` (catches try/except
   disguises).

Type annotations that need `pxr` types use `TYPE_CHECKING` string annotations only.

### 9. API contract (PRD A7, committed shapes)

```text
class IsaacDriver:
    SCENE: str                                  # class attr; replaces the former USD attr
    setup(stage) -> None                        # subclass hook
    main() -> None                              # subclass hook (owns the loop)
    shutdown() -> None                          # subclass hook
    init_rclpy() -> None                        # helper, explicit call from setup()
    run() -> None                               # entry

load_scene(path: str, repo_root: str) -> dict   # pure: read YAML + validate schema,
                                                # return the validated scene dict
build_scene(scene: dict, stage, repo_root: str) -> None
                                                # Isaac: add_reference + pose + variant,
                                                # mutates the passed stage
setup_sensors(stage, scene: dict) -> None       # OmniGraph -> ROS 2 publish
setup_ros2_io(stage, scene: dict) -> RosIo
RosIo.latest(topic: str) -> Msg | None          # non-blocking; None when no message;
                                                # a message is fresh once (no re-mark);
                                                # reads an OmniGraph attr, not rclpy

import_urdf(urdf_path: str, out_usd_path: str) -> PrimSummary
PrimSummary = NamedTuple(prim_count: int, joint_count: int,
                         link_paths: list[str], root_prim: str, usd_path: str)
```

Driver lifecycle (`run()`, PRD A2):

```text
SimulationApp(parse_livestream_env(ISAAC_LIVESTREAM))   # must be first
install signal handlers (override Kit SIGINT)
scene = load_scene(SCENE, ROOT)      # pure
stage = get_stage()                  # from SimulationApp/World, not from load_scene
build_scene(scene, stage, ROOT)      # Isaac
setup_sensors(stage, scene)          # L3 outbound
setup_ros2_io(stage, scene)          # inbound
ensure_scene_defaults(stage)         # SunLight
play_timeline()
setup(stage); main(); shutdown(); app.close()
```

Additional locked points:

- **Variant single owner = `materials`**: the scene loader only passes variant names; only
  `materials` calls `SetVariantSelection`. Current code has the call split across the scene
  builder and the material setup; the consolidation refactor ("3b") lands with the forklift
  migration (#136) — the interface contract is locked now, the mechanical extraction (#130)
  keeps the status quo.
- **`import_urdf` is greenfield**: the existing CLI returns only an exit int and the existing
  unit tests assert asset-structure layout, not prim/joint counts. The `PrimSummary` contract
  and the L1 "diff = 0" assertion are new code + new assertions, not ported external behavior.
- **Exception hierarchy**: `IsaacDevkitError` <- `SceneError` / `SensorConfigError`
  (<- `SensorNotFoundError` / `LinkNotFoundError`); stub paths raise `NotImplementedError`.
- `build_scene` touches `pxr` only via function-local imports / `TYPE_CHECKING` string
  annotations, so it does not break the section-8 invariant.

## Restated generic decisions from superseded ADRs

The three superseded ADRs carry generic decisions wrapped in application-specific examples.
The generic content is restated here (camera-bot as the running example); the original files
are stub-marked and migrate with the application content (#136).

### From ADR-0006 (per-sensor-type YAML config)

What survives, generically: sensors are **declared in YAML, not coded**; a sensor mounts onto
an existing scene entity; the publish chain is generated from the declaration; multi-camera =
multiple declarations sharing one `SimulationApp`; topic/frame prefixes must be unique and are
validated at startup. What is replaced: per-sensor-**type** YAML files at a config root (one
schema wall per type, driver dispatch on `sensor.type`) give way to the catalog/placement
two-tier model of section 5 — one catalog schema exposing all parameters, placements nested in
`robot.yaml`/`object.yaml`, and `link`-based mounting aligned to the kinematic tree instead of
free-form `parent_prim` paths. This supersession is simultaneously the PRD A4 schema
replacement and the de-application of the original file — one cut. Camera-bot example: the
`front_camera` catalog entry plus the placement block in section 5 fully replace what a
`config/camera/<type>.yaml` file used to say.

### From ADR-0008 (L2/L3 physics-level vocabulary and coexistence rules)

The vocabulary and the PhysX ground rules are generic Isaac/PhysX facts and remain in force
for any robot built on this base:

- Two physics levels only: **L2 kinematic** (`kinematicEnabled=true`, command-is-position,
  collides) and **L3 dynamic + joint**. No L0 (Xform-only) level — without collision it cannot
  interact, so it is not a legal design starting point.
- L2 contract: no joints required (driver-side forward kinematics is fine); PhysX moves the
  body to its kinematic target regardless of forces; you must drive it with
  `set_kinematic_target`, not global-pose writes (those bypass the contact integrator).
- L2/L3 coexistence: force transfer is one-way (kinematic pushes dynamic, never the reverse);
  L2<->L3 contacts report by default, L2<->L2 and L2<->static do not; a kinematic body can
  squish a dynamic body against a static one (application-side responsibility); articulation
  links cannot be kinematic.
- USD variant naming: `<model>_<suffix>` (`_kin` = all-L2 baseline; `_<part>_dyn` = the listed
  part promoted to L3). Promoting any part to L3 crosses from the ideal-actuator track into
  motion-control simulation territory — that boundary stays.

Camera-bot example: `camera_bot_kin` is an L2 chassis cube carrying the camera; a dynamic prop
cube in `object.yaml` (`mobility: dynamic`) gets pushed when the chassis drives into it, and
the contact is reported. A hypothetical `camera_bot_mast_dyn` variant would promote a mast to
L3 and leave the ideal-actuator track.

### From ADR-0010 (4-layer dev kit + scene YAML)

The 4-layer separation survives as the module set of section 3:

| ADR-0010 layer | Survives as |
|---|---|
| L1 model pipeline (SW -> URDF -> USD, one pipeline, no exceptions) | `model_import` + the `PrimSummary` contract |
| L2 asset structure (geometry/material file split, variant sets, re-import safety) | `materials` (variant single owner) |
| L3 sensor (YAML-driven setup) | `sensors` + section 5 schema |
| L4 control (`IsaacDriver`, lifecycle-only) | `driver` (ADR-0009 pattern, `SCENE` attr) |
| Scene YAML (declarative, ephemeral scenes, GUI observation-only) | three-file scene of section 4 |

What changes: the dev kit stops being conventions over a `script/` directory and becomes an
importable, mounted, versioned package; the single scene YAML splits into three files with
explicit per-object `mobility`; per-sensor-type YAML is replaced per section 5. What also
survives: "scenes are ephemeral, assembled at runtime, adjustments go back to the source
model"; "GUI is observation-only"; the robot-vs-object classification rule; the IMU
must-mount-on-rigid-body validation (now a catalog-validation rule). Camera-bot traverses all
four layers: URDF in `src/isaac/sim/model/` -> `import_urdf` -> placement in `robot.yaml` ->
`ExampleDriver(IsaacDriver)`.

## Per-ADR disposition table

Disposition of all 16 existing ADRs. "Migrate" rows move physically in #136 (nothing moves in
this change); their proposed numbers in `isaac-forklift` are reserved here in migration order
and finalized by #136.

| ADR | Title (short) | Disposition | Destination | New number |
|---|---|---|---|---|
| 0001 | Chassis SE(2) slide | migrate | `isaac-forklift` (#136) | forklift ADR-0001 |
| 0002 | cmd_vel teleop via in-kit Script Editor | kept | base (historical; entrypoint already superseded in place by ADR-0005) | — |
| 0003 | Two-track simulation strategy | migrate | `isaac-forklift` (#136) | forklift ADR-0002 |
| 0004 | Model A-hybrid block model | migrate | `isaac-forklift` (#136) | forklift ADR-0003 |
| 0005 | Standalone-with-livestream entrypoint | kept (light editorial de-application) | base | — |
| 0006 | Per-sensor-type YAML config | **supersede** (this ADR section 5 + restatement above; stub header added) | file migrates with #136 | forklift ADR-0004 |
| 0007 | Custom streaming Kit experience | kept (light editorial de-application) | base | — |
| 0008 | L2/L3 physics vocabulary | **supersede** (restated generically above; stub header added) | file migrates with #136 | forklift ADR-0005 |
| 0009 | IsaacDriver lifecycle-only pattern | kept (light editorial de-application; `USD` class attr replaced by `SCENE` per section 9) | base | — |
| 0010 | 4-layer Isaac Dev Kit | **supersede** (restated as the module set above; stub header added) | file migrates with #136 | forklift ADR-0006 |
| 0011 | CI hosted/self-hosted split | kept (already revised inline by ADR-0012 + its own 2026-06-02 update) | base | — |
| 0012 | Research org split, dual runners | **amend** (update appended: org-axis re-derivation, below) | base | — |
| 0013 | Test ownership + tool sublayer | **amend** (update appended: re-derivation, below) | base | — |
| 0014 | Sim-runtime stage taxonomy | kept | base | — |
| 0015 | Cross-subnet ROS 2 TCP DDS | kept (light editorial de-application) | base | — |
| 0016 | Base-native per-instance bring-up | kept | base | — |

Light editorial de-application (0005 / 0007 / 0009 / 0015) = incidental application example
words swapped to camera-bot wording in place, with an editorial note in each file; original
wording stays in git history. Decision content is untouched.

Residual note: ADR-0002 (kept) still carries application-era example vocabulary (the research
robot it was written against). The PRD's de-application list does not include it; whether it
gets a light editorial pass or migrates alongside 0001/0003/0004 is deferred to the migration
review (#136 / #137) rather than decided unilaterally here.

## Amendment: ADR-0013 (re-derivation, not voiding)

ADR-0013 rejected "the docker repo owns all test categories" on two grounds: (1) pure-Python
unit tests living in the docker repo would force every contributor into a container build to
iterate on a one-line change; (2) locality inversion — tests should sit next to the code they
exercise, and the code lived in the research workspace.

Both premises have since changed, and re-deriving from 0013's own principles now lands on the
opposite ownership:

- **The mount model voids (1).** The framework is mounted, not baked (section 2); unit and
  import-safety tests run hosted, pure, with zero Isaac and zero container build. The cost
  0013 was protecting contributors from no longer exists.
- **The monorepo merge flips (2).** The research -> docker merge (#78) moved the framework
  code into this repo, so "tests follow code" — 0013's own locality principle — now points at
  base, not away from it.

Framework tests living in this repo is therefore a **continuation** of ADR-0013's reasoning,
not a violation of it. The `test/<category>/<tool>/` sublayer decision is untouched and
remains the layout for the converged repo. Recorded as an Update section in ADR-0013.

## Amendment: ADR-0012

The research -> docker monorepo merge (#78) already undid the research/docker split for the
isaac pair (recorded in ADR-0011's 2026-06-02 update). With the base-repo convergence, the org
axis is re-derived rather than abandoned: **`-docker` holds reusable base repos** (environment
and framework bases, like `base` itself and this isaac base repo) **vs `-research` holds
application / scenario source** (`isaac-forklift`, `seggpt`, `sam_manager`). The dual
org-level runner topology and the security gates stand unchanged. Recorded as an Update
section in ADR-0012.

## Consequences

- Consumers (the example, #130-#135, and future scenario repos) code against the shapes in
  sections 4, 5, and 9 from day one; interface churn is traded for `NotImplementedError` on
  not-yet-implemented paths.
- Nothing moves physically in this change: superseded files keep their paths (with stub
  headers pointing here) until #136, so every existing cross-reference to ADR-0006 / 0008 /
  0010 still resolves; after migration the stubs preserve traceability.
- The purity grep (M3, #137) excludes stub pointer lines by design.
- ADR-0009's lifecycle-only pattern is reaffirmed; its `USD` class attr is replaced by `SCENE`
  (section 9) as part of the contract, recorded here rather than as a 0009 rewrite.
- The pytest parity baseline (126) becomes a committed CI artifact in #130; TEST.md +
  `check_test_md_drift.sh` continue to govern bats counts only (a sidecar harness issue tracks
  teaching the drift hook to count pytest).

## Cross-references

- PRD: `doc/PRD-template-convergence.draft.md` — Implementation Decisions, A1 (import
  safety), A2 (lifecycle), A4 (sensor schema), A5 (layout), A6 (versioning / consumption),
  A7 (API contract), Testing & Acceptance Criteria.
- Issues: #128 (this ADR), #127 (M0 camera smoke), #130 (framework extraction + parity
  baseline), #131 / #132 (example + GPU integration), #133 (ament templates), #134
  (scaffold), #135 (onboarding gate), #129 / #136 (isaac-forklift repo + migration), #137
  (base purity).
- ADRs: 0006 / 0008 / 0010 (superseded by this file), 0012 / 0013 (amended, update sections
  appended), 0009 (lifecycle pattern carried forward), 0011 (CI split — the 4-bucket
  allocation this test contract rides on), 0014 (stage taxonomy — `headless` for GPU CI,
  orthogonal), 0016 (per-instance bring-up, unaffected).
