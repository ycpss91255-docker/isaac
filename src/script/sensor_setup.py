"""Unified sensor setup — YAML-config-driven, dispatches by sensor.category.

Extends the ADR-0006 per-sensor-type camera framework to LiDAR and IMU.
Camera dispatch delegates to the existing camera_setup module.

Schema rules:
  - ADR-0006 (camera): doc/adr/0006-per-sensor-yaml-camera-config.md
  - ADR-0010 L3 (lidar/imu): doc/adr/0010-isaac-dev-kit-*.md

Usage from a SimulationApp standalone driver:

    from sensor_setup import load_config, setup_sensor
    cfg = load_config(yaml_path)
    setup_sensor(cfg, stage)

Host-side functions (load_config, get_category, validation) work without
Isaac Sim. The setup_sensor() dispatcher requires Isaac Sim (Kit-side
modules).
"""

from pathlib import Path

import yaml

_SUPPORTED_CATEGORIES = {"camera", "lidar", "imu"}
_LIDAR_TYPES = {"lidar_3d", "lidar_2d"}
_LIDAR_PUBLISH_TYPES = {"point_cloud", "laser_scan"}


def load_config(path):
    """Load a sensor YAML config; validate shared + per-category rules."""
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"sensor config not found: {p}")
    with p.open() as f:
        cfg = yaml.safe_load(f)
    _validate_shared(cfg, source=str(p))
    category = cfg["sensor"]["category"]
    if category == "camera":
        from camera_setup import validate_camera
        validate_camera(cfg, source=str(p))
    elif category == "lidar":
        _validate_lidar(cfg, source=str(p))
    elif category == "imu":
        _validate_imu(cfg, source=str(p))
    cfg["_source"] = str(p)
    return cfg


def get_category(cfg):
    """Return the sensor category from a loaded config."""
    return cfg["sensor"]["category"]


def setup_sensor(cfg, stage):
    """Dispatch to the per-category setup function.

    Requires Isaac Sim (Kit-side modules). Returns an identifier for
    the created sensor (graph path, prim path, etc.).
    """
    category = get_category(cfg)
    if category == "camera":
        return _setup_camera_dispatch(cfg, stage)
    if category == "lidar":
        return _setup_lidar(cfg, stage)
    if category == "imu":
        return _setup_imu(cfg, stage)
    raise ValueError(f"unsupported sensor.category: {category}")


def _validate_shared(cfg, source):
    """Validate top-level keys and mount/ros sections (all categories)."""
    for key in ("mount", "sensor", "ros"):
        if key not in cfg:
            raise ValueError(f"{source}: missing top-level key '{key}'")

    mount = cfg["mount"]
    if "parent_prim" not in mount or "pose" not in mount:
        raise ValueError(f"{source}: mount needs 'parent_prim' and 'pose'")
    pose = mount.get("pose", {})
    if "xyz" not in pose or "rpy" not in pose:
        raise ValueError(f"{source}: mount.pose needs 'xyz' and 'rpy'")

    sensor = cfg["sensor"]
    category = sensor.get("category")
    if category not in _SUPPORTED_CATEGORIES:
        raise ValueError(
            f"{source}: sensor.category='{category}' not in "
            f"{sorted(_SUPPORTED_CATEGORIES)}"
        )

    ros = cfg["ros"]
    for key in ("topic_prefix", "frame_id_prefix"):
        if key not in ros:
            raise ValueError(f"{source}: ros needs '{key}'")


def _validate_lidar(cfg, source):
    """Validate LiDAR-specific fields."""
    sensor = cfg["sensor"]
    if "profile" not in sensor:
        raise ValueError(f"{source}: lidar sensor needs 'profile'")

    if sensor["profile"] == "custom" and "config_path" not in sensor:
        raise ValueError(
            f"{source}: lidar profile='custom' requires 'config_path'"
        )

    ros = cfg["ros"]
    publish_type = ros.get("publish_type")
    if publish_type not in _LIDAR_PUBLISH_TYPES:
        raise ValueError(
            f"{source}: ros.publish_type='{publish_type}' not in "
            f"{sorted(_LIDAR_PUBLISH_TYPES)}"
        )


def _validate_imu(cfg, source):
    """Validate IMU-specific fields (host-side checks only).

    The rigid body mount constraint is enforced at setup time (requires
    stage access to check RigidBodyAPI), not at config load time.
    """
    pass


# -- Isaac Sim dispatchers (require container) --


def _setup_camera_dispatch(cfg, stage):
    """Delegate to existing camera_setup module (ADR-0006)."""
    from camera_setup import setup_camera
    return setup_camera(cfg, stage)


def _setup_lidar(cfg, stage):
    """Create RTX LiDAR sensor + ROS 2 Action Graph publish chain.

    Uses NVIDIA pre-built profile by name, or custom JSON config.
    """
    from pxr import UsdGeom, UsdPhysics

    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    sensor = cfg["sensor"]
    ros = cfg["ros"]
    frame_id_prefix = ros["frame_id_prefix"]
    topic_prefix = ros["topic_prefix"].rstrip("/")
    publish_type = ros["publish_type"]

    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    _set_xform_pose(mount_prim, cfg["mount"]["pose"])

    from isaacsim.core.utils.extensions import enable_extension
    enable_extension("isaacsim.core.nodes")
    enable_extension("isaacsim.ros2.bridge")
    enable_extension("isaacsim.sensors.rtx")

    import omni.kit.commands
    lidar_name = "lidar"
    lidar_path = f"{mount_path}/{lidar_name}"

    # IsaacSensorCreateRtxLidar takes (path, parent, config) separately.
    # `path` is the new prim's local name; `parent` is the absolute
    # parent prim path. `config` is the NVIDIA profile name (no path,
    # no .json extension) -- it's looked up in
    # /isaac-sim/exts/isaacsim.sensors.rtx/data/lidar_configs/.
    if sensor["profile"] == "custom":
        # User-supplied JSON config (full path on disk).
        omni.kit.commands.execute(
            "IsaacSensorCreateRtxLidar",
            path=f"/{lidar_name}",
            parent=mount_path,
            config=sensor["config_path"],
        )
    else:
        omni.kit.commands.execute(
            "IsaacSensorCreateRtxLidar",
            path=f"/{lidar_name}",
            parent=mount_path,
            config=sensor["profile"],
        )

    import omni.graph.core as og
    from pxr import Sdf

    graph_path = f"/World/SensorGraphs/{frame_id_prefix}_lidar"
    nodes = [
        ("OnTick", "omni.graph.action.OnPlaybackTick"),
        ("SimFrame", "isaacsim.core.nodes.OgnIsaacRunOneSimulationFrame"),
        ("RenderProduct", "isaacsim.core.nodes.IsaacCreateRenderProduct"),
        ("LidarHelper", "isaacsim.ros2.bridge.ROS2RtxLidarHelper"),
    ]
    set_values = [
        ("RenderProduct.inputs:cameraPrim", [Sdf.Path(lidar_path)]),
        ("LidarHelper.inputs:type", publish_type),
        ("LidarHelper.inputs:topicName", f"{topic_prefix}/{'scan' if publish_type == 'laser_scan' else 'points'}"),
        ("LidarHelper.inputs:frameId", f"{frame_id_prefix}_lidar_frame"),
    ]
    connects = [
        ("OnTick.outputs:tick", "SimFrame.inputs:execIn"),
        ("SimFrame.outputs:step", "RenderProduct.inputs:execIn"),
        ("RenderProduct.outputs:execOut", "LidarHelper.inputs:execIn"),
        ("RenderProduct.outputs:renderProductPath", "LidarHelper.inputs:renderProductPath"),
    ]

    (graph, _, _, _) = og.Controller.edit(
        {"graph_path": graph_path, "evaluator_name": "execution"},
        {
            og.Controller.Keys.CREATE_NODES: nodes,
            og.Controller.Keys.SET_VALUES: set_values,
            og.Controller.Keys.CONNECT: connects,
        },
    )
    og.Controller.evaluate_sync(graph)
    return graph_path


def _setup_imu(cfg, stage):
    """Create IMU sensor + ROS 2 Action Graph publish chain.

    Validates that parent_prim has RigidBodyAPI (physical constraint).
    """
    from pxr import UsdPhysics

    parent_path = cfg["mount"]["parent_prim"]
    parent_prim = stage.GetPrimAtPath(parent_path)
    if not parent_prim.IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    if not parent_prim.HasAPI(UsdPhysics.RigidBodyAPI):
        raise ValueError(
            f"IMU requires parent_prim with RigidBodyAPI, but "
            f"'{parent_path}' does not have it. IMU must be mounted "
            f"on a rigid body (L2 kinematic or L3 dynamic)."
        )

    sensor = cfg["sensor"]
    ros = cfg["ros"]
    frame_id_prefix = ros["frame_id_prefix"]
    topic_prefix = ros["topic_prefix"].rstrip("/")

    from pxr import UsdGeom, Gf
    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    _set_xform_pose(mount_prim, cfg["mount"]["pose"])

    from isaacsim.core.utils.extensions import enable_extension
    enable_extension("isaacsim.ros2.bridge")

    import omni.kit.commands
    frequency_hz = sensor.get("frequency_hz", 200)
    sensor_period = 1.0 / frequency_hz if frequency_hz > 0 else 0.0
    filter_cfg = sensor.get("filter", {})

    omni.kit.commands.execute(
        "IsaacSensorCreateImuSensor",
        path="imu_sensor",
        parent=mount_path,
        sensor_period=sensor_period,
        linear_acceleration_filter_size=filter_cfg.get("linear_acceleration", 10),
        angular_velocity_filter_size=filter_cfg.get("angular_velocity", 10),
        orientation_filter_size=filter_cfg.get("orientation", 10),
    )

    imu_prim_path = f"{mount_path}/imu_sensor"

    import omni.graph.core as og
    graph_path = f"/World/SensorGraphs/{frame_id_prefix}_imu"
    nodes = [
        ("OnTick", "omni.graph.action.OnPlaybackTick"),
        ("ReadIMU", "isaacsim.sensors.physics.IsaacReadIMU"),
        ("ReadSimTime", "isaacsim.core.nodes.IsaacReadSimulationTime"),
        ("PublishIMU", "isaacsim.ros2.bridge.ROS2PublishImu"),
    ]
    set_values = [
        ("ReadIMU.inputs:imuPrim", imu_prim_path),
        ("ReadIMU.inputs:readGravity", True),
        ("PublishIMU.inputs:topicName", f"{topic_prefix}/data"),
        ("PublishIMU.inputs:frameId", f"{frame_id_prefix}_imu_frame"),
    ]
    connects = [
        ("OnTick.outputs:tick", "ReadIMU.inputs:execIn"),
        ("ReadIMU.outputs:execOut", "PublishIMU.inputs:execIn"),
        ("ReadIMU.outputs:angVel", "PublishIMU.inputs:angularVelocity"),
        ("ReadIMU.outputs:linAcc", "PublishIMU.inputs:linearAcceleration"),
        ("ReadIMU.outputs:orientation", "PublishIMU.inputs:orientation"),
        ("ReadSimTime.outputs:simulationTime", "PublishIMU.inputs:timeStamp"),
    ]

    (graph, _, _, _) = og.Controller.edit(
        {"graph_path": graph_path, "evaluator_name": "execution"},
        {
            og.Controller.Keys.CREATE_NODES: nodes,
            og.Controller.Keys.SET_VALUES: set_values,
            og.Controller.Keys.CONNECT: connects,
        },
    )
    og.Controller.evaluate_sync(graph)
    return graph_path


def _set_xform_pose(prim, pose):
    """Apply translate + rotateXYZ (degrees) to a USD prim."""
    from pxr import UsdGeom, Gf
    xformable = UsdGeom.Xformable(prim)
    xformable.ClearXformOpOrder()

    translate_op = xformable.AddTranslateOp()
    x, y, z = pose["xyz"]
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))

    rotate_op = xformable.AddRotateXYZOp()
    r, p, yaw = pose["rpy"]
    rotate_op.Set(Gf.Vec3f(float(r), float(p), float(yaw)))
