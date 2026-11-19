# Three-layer sensor module split

## Status

Accepted (2026-11-17).

Implements ADR-0023 (Python as sole external interface) for the sensor
subsystem.  Does **not** supersede ADR-0006 (camera config) or ADR-0010
(sensor framework).

## Context

`framework/isaac_devkit/sensors.py` (756 lines) mixed three distinct
responsibilities:

1. **Config loading and validation** (host-pure, no Isaac Sim).
2. **USD prim creation** (Isaac Sim Kit commands, but no ROS 2).
3. **ROS 2 OmniGraph wiring** (depends on `isaacsim.ros2.bridge`).

ADR-0023 established that Python is the sole external interface and ROS 2
is a replaceable downstream consumer.  The sensor module's structure
contradicted that decision: `_setup_lidar`, `_setup_imu`, `_setup_realsense`,
and `_setup_custom` each interleaved prim creation with ROS 2 graph wiring,
making it impossible to place a sensor without also wiring ROS 2.

The repo split tracked by isaac#309 plans to move sensor prim creation to
`ycpss91255-docker/urdf2usd` and ROS 2 wiring to
`ycpss91255-docker/isaac_ros2`.  A clean in-repo split is a prerequisite
for that cross-repo move.

## Decision

Split `sensors.py` into three modules with a strict dependency direction:

```
sensor_prim.py  (a)  <---  sensors.py  (b)  --->  sensor_ros.py  (c)
     |                         |                        |
config loading          OmniGraph wiring        ROS 2 OmniGraph
validation              dispatcher              publish chain
prim helpers            (entry point)
```

### Layer (a): `sensor_prim.py`

Config I/O, shared and per-category validation, host-pure helpers
(`fov_to_aperture`, `role_to_helper_type`), and USD prim helpers
(`set_xform_pose`, `set_camera_intrinsics`, `resolve_asset_url`).

The `ros:` config section is **optional**.  When absent, `load_config`
sets `cfg["ros"] = None`.  Validation of `ros:` fields (topic_prefix,
frame_id_prefix, publish_type) runs only when `ros:` is present.

### Layer (b): `sensors.py` (dispatcher, stays in isaac)

The entry point for scene.py and standalone drivers.  `setup_sensor` builds
the sensor prim on the stage (delegating to layer a helpers) and, when
`cfg["ros"]` is not None, calls into layer (c) for ROS 2 wiring.

Backward-compatible re-exports: `load_config`, `get_category`,
`validate_camera` are re-exported from `sensor_prim` so existing callers
(`scene.py`, example drivers, shim scripts) continue to work without
changing their imports.

### Layer (c): `sensor_ros.py` (ROS 2 publish, future isaac_ros2)

Builds the OmniGraph action graph that publishes sensor data over ROS 2
topics.  Public interface:

```python
def setup_sensor_publish(
    stage,
    sensor_prim_path: str,
    ros_config: dict,
    category: str,
    sensor_config: dict | None = None,
) -> str | None:
    """Wire the OmniGraph ROS 2 publish chain for an existing sensor prim.

    Args:
        stage: The USD stage containing the sensor prim.
        sensor_prim_path: Absolute USD prim path of the sensor.
        ros_config: The ``ros:`` section dict (topic_prefix, frame_id_prefix, ...).
        category: Sensor category ("camera", "lidar", "imu").
        sensor_config: The full sensor config dict (needed for category-specific
            ROS wiring, e.g. lidar publish_type, camera streams).

    Returns:
        The OmniGraph path, or None if wiring is not applicable.
    """
```

`build_graph_topology` (the camera stream graph-spec builder) is also
public for direct use by callers that build their own OmniGraph topology.

**Future migration**: this module will move to `ycpss91255-docker/isaac_ros2`
once that repo can operate independently.  At that point, `sensors.py`
(layer b) in the isaac repo will import from `isaac_ros2` instead of from
the local `sensor_ros`.  The public interface (`setup_sensor_publish`)
remains the same.

## Consequences

- **`ros:` config is optional.** Sensor prim placement works without ROS 2
  dependencies.  Scene configs that omit `ros:` get prim creation only.
- **Existing public API unchanged.** `from isaac_devkit.sensors import
  load_config, setup_sensor` works exactly as before.  `scene.py` and
  the example driver do not need changes.
- **Integration tests unchanged.** The GPU integration tests
  (`test_sensor_setup_integration.py`, `test_camera_ros2_headless.py`)
  exercise the full prim+ROS path and continue to pass because the sensor
  configs in those tests include `ros:`.
- **New unit tests.** `test_sensor_prim.py` (host-runnable) covers config
  loading, the `ros:` optional path, and host-pure helpers.
  `test_sensor_ros.py` covers the graph topology builder.
  `test_sensors_dispatch.py` covers backward-compat re-exports and
  `_enable_extensions`.
- **Cross-repo migration path.** Layer (a) functions are the seed for
  `urdf2usd`'s sensor prim support.  Layer (c) is the seed for
  `isaac_ros2`'s OmniGraph publish chain.  Both can be moved with a
  one-line import change in layer (b).

## References

- isaac#309 -- repo split tracking.
- ADR-0023 -- Python as sole external interface.
- ADR-0006 (in isaac_physics_test) -- per-sensor YAML camera config.
- ADR-0010 (in isaac_physics_test) -- isaac_devkit standardized development environment.
- ADR-0017 section 8 -- import-safety invariant.
