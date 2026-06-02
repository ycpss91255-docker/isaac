# Per-Sensor-Type YAML Config for Sim Cameras

`isaac_ws` needs to drop a virtual camera onto `forklift_blocky` and publish color + depth + camera_info + TF as ROS 2 topics. Three target hardware variants are on the table:

- **Intel RealSense D455** — NVIDIA Isaac Sim ships `Isaac/Sensors/Intel/RealSense/rsd455.usd` with intrinsics, IMU, and stereo baseline baked in. Publish path uses Isaac Sim's native `ROS2CameraHelper` / `ROS2CameraInfoHelper` Action Graph nodes.
- **ZED-M (Mini)** — the physical hardware user has on hand. **No** official Stereolabs Isaac Sim USD asset exists for ZED-M; we have to synthesize the camera with generic `UsdGeom.Camera` prims and hand-set the intrinsics from the datasheet. Publish path reuses the same `ROS2CameraHelper` chain.
- **Stereolabs ZED X** — third-party Stereolabs extension provides a USD asset and a dedicated `ZED Camera Helper` Omnigraph node (not the standard `ROS2CameraHelper`). Different publish chain, different topic conventions.

A single unified YAML schema covering all three would be a wall of `if sensor.type == realsense / custom / zed` conditionals — dirty and fragile. **Decision**: one YAML file per sensor type, driver dispatch on `sensor.type`.

## Considered Options

- **(a) Single unified YAML with conditional fields** — every camera sensor crammed into one schema (`hfov_deg`, `vfov_deg`, `baseline_m`, `asset_url`, `streams: {color, depth, ir_left, ir_right, imu}`, ...). Validation would have to special-case "if realsense, ignore manual intrinsics; if custom, require them; if zed, ignore both and read from Stereolabs preset". Becomes unmaintainable as a 4th sensor lands.
- **(b) Per-sensor-type YAML files + driver dispatch on `sensor.type`** (**chosen**) — `config/camera/realsense.yaml`, `config/camera/custom.yaml`, `config/camera/zed.yaml`. Each schema is tuned to its own sensor's natural shape. Common section (`mount` + `ros`) is small and identical, intentional duplication.
- **(c) Plugin registry pattern** — each sensor type is a Python class registered in a dict; the driver looks up by `sensor.type`. Rule of Three not yet hit (only one sensor type implemented at the point this ADR lands — realsense), and the YAML structure already gives us most of the decoupling.

## Why (b)

The three sensor variants are not isomorphic — they have genuinely different shapes:

| Aspect | realsense | custom | zed |
|---|---|---|---|
| Source of intrinsics | rsd455.usd asset | user-supplied (datasheet) | Stereolabs preset |
| Number of camera prims | 4 (Color, Pseudo_Depth, IR_L, IR_R) | configurable list (1 or more) | hidden inside Stereolabs asset |
| Publish nodes | `ROS2CameraHelper` × N | `ROS2CameraHelper` × N | Stereolabs `ZED Camera Helper` |
| Mount asset reference | `omni:`-style asset reference | none (Camera prims authored in place) | Stereolabs asset reference |
| Resolution override | per-stream resolution dict | per-sensor entry's `resolution` | Stereolabs preset name |
| Extension dependency | `isaacsim.ros2.bridge` (bundled) | `isaacsim.ros2.bridge` (bundled) | third-party Stereolabs ext (install required) |

Cramming these into one schema means every read of the YAML has to mentally branch on `sensor.type`. Splitting per file lets each file be self-documenting for its sensor.

The cost — three almost-identical `mount:` and `ros:` blocks — is real but small, and edits to those blocks are rare. We accept the duplication.

## Schema (shared across all sensor types)

```yaml
# Where the camera body sits in the scene.
mount:
  parent_prim: "/World/.../<some-xform>"  # any USD prim path
  pose:
    xyz: [x, y, z]                        # meters, relative to parent_prim
    rpy: [r, p, y]                        # degrees, URDF convention

# Sensor type dispatch.
sensor:
  type: realsense | custom | zed
  # Plus per-type fields (asset_suffix for realsense, sensors[] list for custom, etc.)

# ROS 2 output naming.
ros:
  topic_prefix: "/<your-prefix>"
  frame_id_prefix: "<your-prefix>"
```

`parent_prim` does **not** need to be a physical body (rigid body / collision). Any USD prim with a Xform works:

- Kinematic body (e.g. `forklift_blocky`'s `carriage`) → camera follows the body's pose updates.
- Static Xform under `/World` → camera fixed at world pose.
- A dedicated `/World/Cameras/<name>` Xform that the driver moves each tick → scripted observer camera.

## Frame Hierarchy

```
parent_prim (e.g. /World/Forklift/carriage)
  └── mount (camera_link analog — device body center; pose relative to parent_prim)
        ├── color (color_optical_frame; offset within device body)
        └── depth (depth_optical_frame; offset within device body)
```

In ROS / URDF terms, `mount` is the `camera_link` frame and `color` / `depth` are the per-sensor optical frames. The naming uses the `frame_id_prefix` from `ros:` plus a fixed `_<role>_optical_frame` suffix.

## Per-Sensor-Type Bottom Section

**realsense**:

```yaml
sensor:
  type: realsense
  asset_suffix: "Isaac/Sensors/Intel/RealSense/rsd455.usd"

streams:
  color: true
  depth: true
  ir_left: false
  ir_right: false
  imu: false

overrides:
  color: {width: 1280, height: 800}
  depth: {width: 1280, height: 720}
```

The asset prim hierarchy comes from rsd455.usd itself (`Camera_OmniVision_OV9782_Color`, `Camera_Pseudo_Depth`, etc.). Color and depth come from different camera prims, so the stereo baseline offset is modeled by the asset.

**custom**:

```yaml
sensor:
  type: custom

sensors:                      # list of independent sensors
  - role: rgb
    name: color
    pose:
      xyz: [x, y, z]          # relative to mount
      rpy: [r, p, y]
    resolution: [w, h]
    fps: 30
    hfov: 90.0                # degrees
    vfov: 60.0                # degrees
  - role: depth
    name: depth
    pose: {...}
    resolution: [w, h]
    fps: 30
    hfov: 90.0
    vfov: 60.0
    range_m: [0.1, 15.0]
```

Each entry becomes one `UsdGeom.Camera` prim under `mount` with the listed intrinsics. Drop an entry for RGB-only / depth-only setups. Add entries for multi-camera rigs.

**zed**:

```yaml
sensor:
  type: zed
  asset_path: "<path-to-stereolabs-extension-usd>"

overrides:
  resolution: HD720           # ZED preset (HD2K / HD1080 / HD720 / VGA)
  depth_mode: NEURAL          # ZED SDK depth mode
  fps: 30
```

Stereolabs extension creates the USD prim hierarchy and the publish Omnigraph node — driver only sets reference + pose + presets.

## Driver Dispatch

```python
def setup_camera(config, stage):
    sensor_type = config["sensor"]["type"]
    if sensor_type == "realsense":
        return _setup_realsense(config, stage)
    if sensor_type == "custom":
        return _setup_custom(config, stage)
    if sensor_type == "zed":
        return _setup_zed(config, stage)
    raise ValueError(f"unsupported sensor.type: {sensor_type}")
```

Implementation lives in `script/camera_setup.py`. Each `_setup_*` function:

1. Resolves `mount.parent_prim` and applies `mount.pose` (creates a child Xform under parent if needed).
2. References / creates camera prims under the mount per sensor-specific logic.
3. Builds the Action Graph publish chain.
4. Returns the graph path for inspection / teardown.

## Multi-Camera Support

The driver accepts `--config <path>` multiple times. Each YAML = one independent camera entity. All cameras share the same `SimulationApp` instance; resource cost scales with the number of render products, not processes.

`ros.topic_prefix` and `ros.frame_id_prefix` must be unique across loaded configs. Driver validates uniqueness at startup and refuses to launch on conflict.

## File Layout

```
config/
  camera/
    realsense.yaml     # PR-1 (this ADR lands with it)
    custom.yaml        # PR-2 (ZED-M baseline initially)
    zed.yaml           # PR-3 (needs Stereolabs extension)
```

Short file names for single-camera scenes. For multi-camera scenes that reuse the same sensor type at multiple positions, future yaml files take a role / location suffix: `realsense_observer.yaml`, `custom_overhead.yaml`, etc.

## Consequences

- One ADR pin to land before PR-1 codes the dispatch (this file).
- Adding a fourth sensor type means new YAML + new `_setup_*` function. No churn on existing files.
- Multi-camera scenes ride on `--config` repetition; no scene-level YAML required (deferred until a real use case).
- The duplication of `mount:` / `ros:` blocks across files is documented as intentional. Linters / pre-commit checks that want to enforce "common section identical" can read it.
- `parent_prim` flexibility (kinematic body / static Xform / dynamic observer) is intentional and tested across PR-1 / PR-2 / PR-3 acceptance criteria. ADR-0004's `forklift_blocky` kinematic carriage stays the canonical anchor for the forklift demo.

## References

- [Camera and Depth Sensors — Isaac Sim 5.1 docs](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/assets/usd_assets_camera_depth_sensors.html)
- [ROS 2 Cameras tutorial — Isaac Sim 5.1](https://docs.isaacsim.omniverse.nvidia.com/5.1.0/ros2_tutorials/tutorial_ros2_camera.html)
- [Stereolabs ZED Isaac Sim Extension](https://www.stereolabs.com/docs/isaac-sim)
- ADR-0004 — Model A-hybrid forklift block model (kinematic carriage that the realsense.yaml mounts to by default)
- ADR-0005 — Standalone-with-livestream as default dev entrypoint (driver runtime that loads these configs)
- Umbrella issue `ycpss91255/isaac#6` — Add RGB-D camera + ROS 2 publishing to forklift_blocky
