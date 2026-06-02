# Isaac Dev Kit: 4-Layer Standardized Development Environment

4 individual driver scripts, multiple robot/object USD models, and a single-sensor-type camera setup (ADR-0006) have grown organically without a unifying framework. Adding new robots (MR12, MR1533), environment objects (push-back with sliding joint, pallet with color variants), and additional sensor types (3D/2D LiDAR, IMU) under the current ad-hoc approach would multiply copy-paste boilerplate and create inconsistent conventions across the workspace.

**Decision**: Build a **robot-agnostic 4-layer development framework** ("Isaac Dev Kit") with a declarative Scene YAML composition layer on top. Each layer has a single responsibility and a clear config-driven interface. First validation target: OpenBase + push-back + pallet scene.

## Considered Options

- **(a) Ad-hoc scripts (status quo)** -- each driver handles model loading, sensor setup, scene composition, and control independently. Works for 1-2 robots but doesn't scale; every new robot duplicates ~100 lines of boilerplate across model load + sensor + scene defaults + shutdown
- **(b) 4-Layer Dev Kit + Scene YAML** (**chosen**) -- standardized pipeline per layer, declarative scene config, robot-agnostic framework

## Why (b)

- ADR-0009 already identified 60 lines of shared boilerplate across 4 drivers -- that's just the control layer. Model loading, sensor setup, and scene composition add another ~100 lines of per-driver duplication
- Upcoming work (MR12 robot, push-back sliding fixture, pallet color variants, LiDAR + IMU sensors) would each require touching all existing drivers under (a)
- NVIDIA's own Asset Structure 3.0 (Isaac Sim 6.0) and Nova Carter multi-sensor example validate this layered separation as the ecosystem direction

## Architecture

```
Scene YAML                    (declarative scene composition)
    |
    +-- L1 Model Pipeline     (SW -> URDF -> USD)
    +-- L2 Asset Structure    (geometry/material separation, variant sets)
    +-- L3 Sensor             (YAML-driven camera/lidar/imu setup)
    +-- L4 Control            (IsaacDriver base class, ADR-0009)
```

### L1 Model Pipeline

All models -- both robots and environment objects -- follow the same 3-stage pipeline:

```
SolidWorks (.SLDASM/.SLDPRT)
    -> sw2urdf plugin
URDF (.urdf + .stl meshes)
    -> Isaac Sim URDF Importer
USD (Asset Structure 3.0)
```

No exceptions. Environment objects (pallet, push-back) also go through URDF because they are drawn in SolidWorks with real-world dimensions, mass properties, and (for push-back) joints.

**Directory structure**:

```
model/
├── sw/
│   ├── robot/<name>/        # SolidWorks source files
│   └── object/<name>/
├── urdf/
│   ├── robot/<name>/        # URDF + STL meshes
│   └── object/<name>/
└── usd/
    ├── robot/<name>/        # USD assets (Asset Structure 3.0)
    └── object/<name>/
```

**Classification**: "Can it move on its own?" -- yes = robot, no = environment object.

- **Robot**: OpenBase, MR12, MR1533, MF1680, forklift_blocky (active movers)
- **Environment Object**: push-back, pallet, shelf, corner_position (passive, moved by external force)

### L2 Asset Structure (NVIDIA Asset Structure 3.0, simplified)

Each model directory under `model/usd/{robot,object}/<name>/` follows:

```
<name>/
├── <name>.usd               # root composition (Scene YAML points here)
├── <name>_geometry.usda      # URDF import output (geometry source of truth)
├── <name>_material.usda      # materials + USD Variant Sets (appearance source of truth)
└── textures/                 # texture files (if any)
    ├── wood.png
    └── blue.png
```

Key decisions:

- **Geometry and material are separate files**. URDF re-import overwrites only `_geometry.usda`; `_material.usda` is unaffected (sublayer override pattern, same as `openbase_l2.usda` overriding `openbase.usda`)
- **Textures are applied at the USD layer**, not from SolidWorks. The sw2urdf pipeline exports STL (geometry only, no material). Material application uses `CreateAndBindMdlMaterialFromLibrary` (OmniPBR) -- the most community-validated API
- **Color variants use USD Variant Sets** via `GetVariantEditContext()` to bind different OmniPBR materials per variant. Scene YAML selects variant at load time
- Robot assets may additionally have `_physics.usda` and `_robot.usda` (joint/drive metadata) as complexity warrants

### L3 Sensor

Extends the ADR-0006 per-sensor-type YAML framework to cover all 5 sensor types:

```
config/
├── camera/
│   ├── realsense.yaml
│   └── custom.yaml
├── lidar/
│   ├── ouster_os1.yaml      # 3D
│   └── rplidar_s2e.yaml     # 2D (RTX LiDAR with 2D profile)
└── imu/
    └── default.yaml
```

All sensor YAMLs share `mount:` + `ros:` sections. `sensor:` section is type-specific.

**LiDAR**: References NVIDIA pre-built profiles by name (e.g., `profile: "Ouster/OS1_Rev7_128ch_10Hz"`). Custom escape hatch: `profile: "custom"` + `config_path: "path/to/config.json"`. Uses `ROS2RtxLidarHelper` with `type: "point_cloud"` (3D) or `type: "laser_scan"` (2D).

**2D LiDAR is not a separate sensor type** -- it's an RTX LiDAR with a 2D scan profile (e.g., `SLAMTEC/RPLIDAR_S2E`). Same OmniGraph pipeline, different profile.

**IMU**: Uses `IsaacSensorCreateImuSensor` + `Isaac Read IMU Node` + `ROS2 Publish Imu`. **Must mount on a rigid body** (prim with `RigidBodyAPI`); setup script validates this at creation time and raises an error if the constraint is violated.

**Mount rules**:

| Sensor | Xform mount | Rigid body mount |
|--------|-------------|-----------------|
| Camera | allowed     | allowed         |
| LiDAR  | allowed     | allowed         |
| IMU    | **denied**  | allowed         |

Camera and LiDAR allow Xform mounts for fixed observation points (e.g., overhead camera mounted on a static `/World/Cameras/` Xform). IMU on a static Xform is physically meaningless (reads only gravity, no acceleration/angular velocity changes).

### L4 Control

**IsaacDriver base class** (ADR-0009) is the framework entry point. Controller logic (cmd_vel integration, joint commands, etc.) stays in driver subclasses. Reusable controller components (e.g., `CmdVelController`, `JointController`) are deferred until the third robot arrives (Rule of Three).

### Scene YAML

Declarative config that defines what to load and where:

```yaml
# scene/warehouse_pushback.yaml
robot:
  model: "robot/openbase/openbase_l2.usda"
  pose:
    xyz: [0, 0, 0]
    rpy: [0, 0, 0]

objects:
  - model: "object/push_back/push_back.usda"
    pose:
      xyz: [3.0, 0, 0]
      rpy: [0, 0, 0]
  - model: "object/pallet/pallet.usda"
    pose:
      xyz: [3.0, 0.5, 0.8]
      rpy: [0, 0, 0]
    variant:
      color: "blue"
    count: 3
    spacing: [0, 0.2, 0]

sensors:
  - "config/camera/realsense.yaml"
  - "config/lidar/ouster_os1.yaml"
  - "config/imu/default.yaml"
```

Key decisions:

- **Scenes are ephemeral** -- assembled at runtime by script, not saved as persistent USD files. If adjustments are needed, they go back to the source model's `.usda`
- **GUI is observation-only** -- all scene composition and control is script-driven. GUI (Streaming Client) is for visual inspection, never for editing
- **Integrated into IsaacDriver lifecycle** (ADR-0009 extension):

```
create_sim_app()
  -> _setup_signal()
  -> _load_scene(scene_yaml)       # NEW: read YAML, add_reference per model, apply pose
  -> _setup_sensors(scene_yaml)    # NEW: read sensors list, dispatch per-type setup
  -> _play_timeline()
  -> setup(stage)                  # subclass hook
  -> main()                        # subclass hook
  -> shutdown()                    # subclass hook
  -> app.close()
```

## Testing Strategy

Two dimensions:

**Per-layer integration tests** (each layer independently):
- L1: URDF import produces valid USD with expected prim hierarchy
- L2: Material binding + variant switching works; re-import preserves materials
- L3: Each sensor type publishes correct ROS 2 topic type
- L4: IsaacDriver subclass boots and exits cleanly (covered by ADR-0009 test plan)

**Per-model end-to-end test** (L1 through L4 golden path):
- Single model goes through full pipeline: SW source exists -> URDF valid -> USD loads -> sensors publish -> control responds
- Validates the integration between all 4 layers for a specific model

## Consequences

- `usd_model/` (legacy flat directory) will be retired; existing models migrate to `model/usd/{robot,object}/<name>/` with Asset Structure 3.0 layout
- Adding a new robot or object is a checklist: SW files in `model/sw/`, run import pipeline, add material config, write Scene YAML entry, write IsaacDriver subclass (robot only)
- Sensor addition is decoupled from model addition -- new sensor type = new `_setup_<type>()` function + YAML schema, no churn on existing models or drivers
- Scene YAML decouples "what's in the scene" from "how to control the robot" -- same driver can run different scenes by swapping YAML
- Material system adds a one-time setup cost per model (write `_material.usda` + `material.yaml` after first URDF import) but pays back on every re-import

## Cross-references

- **ADR-0003**: Two-track simulation strategy (Model A / Model B) -- this Dev Kit serves both tracks; Model A and Model B are different Scene YAML configs pointing to different robot USD variants
- **ADR-0006**: Per-sensor-type YAML camera config -- L3 extends this framework to LiDAR + IMU
- **ADR-0008**: L2/L3 physics level vocabulary -- sensor mount rules reference these physics levels
- **ADR-0009**: IsaacDriver base class lifecycle-only pattern -- L4 foundation; Scene YAML integration extends the `run()` lifecycle
- **ycpss91255/isaac#23**: IsaacDriver implementation (L4, in progress)
- **ycpss91255-docker/isaac#28**: Docker stage consolidation (closed, provides `ISAAC_LIVESTREAM` env var that `IsaacDriver.create_sim_app()` reads)

## Future considerations (not decided, deferred)

- **Controller abstraction** (L4): When the third robot arrives, evaluate extracting `CmdVelController` / `JointController` as reusable components. Must consider different robot types (differential drive, mecanum, articulated arm) -- not just the current SE(2) slide pattern
- **Domain randomization integration**: Omniverse Replicator (`rep.create.material_omnipbr`) for perception training material randomization. Relevant at C-Phase synthetic data generation, not now
- **Omniverse SolidWorks Connector**: Direct SW -> USD path (bypasses URDF, preserves materials) as alternative for environment objects that don't need joints. Currently excluded to keep a single unified pipeline; revisit if URDF re-import cycle becomes a bottleneck
