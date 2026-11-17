"""ROS 2 OmniGraph publish chain for sensors.

Layer (c) of the three-layer sensor split (ADR-0024):
  (a) sensor_prim  -- config I/O, validation, prim creation helpers
  (b) sensors      -- OmniGraph wiring dispatcher
  (c) sensor_ros   -- ROS 2 OmniGraph publish chain (this module)

This module builds the OmniGraph action graph that publishes sensor data
over ROS 2 topics.  It is the downstream consumer of layer (a) sensor
prims and is called by layer (b) when ``ros:`` config is present.

``setup_sensor_publish(stage, sensor_prim_path, ros_config, category,
sensor_config)`` is the public entry point: given a sensor prim that
already exists on stage, it wires the OmniGraph ROS 2 publish chain.

Future: this module will migrate to ``ycpss91255-docker/isaac_ros2``
once that repo can operate independently.  See ADR-0024 for the
migration plan.

Host-pure: ``build_graph_topology`` can run without Isaac Sim (needs
only ``pxr.Sdf`` for the Path type).  The ``setup_*_ros`` functions
require Isaac Sim.
"""


def build_graph_topology(stream_map, enabled, overrides, topic_prefix, frame_id_prefix):
    """Action Graph topology: 1 OnTick -> N (RenderProduct -> Helper + InfoHelper).

    One render product per enabled stream so different camera prims (and
    therefore different optical offsets in the rsd455 asset) drive their own
    publish chain.

    This is a host-pure graph-spec builder.  The caller passes the result
    to ``og.Controller.edit``.

    Args:
        stream_map: {stream_name: (camera_prim_path, helper_type, optical_suffix)}
        enabled: list of stream names to wire.
        overrides: {stream_name: {"width": int, "height": int}} resolution overrides.
        topic_prefix: ROS 2 topic prefix (e.g. "/camera").
        frame_id_prefix: ROS 2 frame_id prefix (e.g. "camera").

    Returns:
        (nodes, set_values, connects) tuple for og.Controller.edit.
    """
    from pxr import Sdf

    nodes = [("OnTick", "omni.graph.action.OnPlaybackTick")]
    set_values = []
    connects = []

    for stream in enabled:
        camera_path, helper_type, optical_suffix = stream_map[stream]
        rp_node = f"RP_{stream}"
        helper_node = f"Helper_{stream}"
        info_node = f"Info_{stream}"

        nodes.extend([
            (rp_node, "isaacsim.core.nodes.IsaacCreateRenderProduct"),
            (helper_node, "isaacsim.ros2.bridge.ROS2CameraHelper"),
            (info_node, "isaacsim.ros2.bridge.ROS2CameraInfoHelper"),
        ])

        rp_values = [(f"{rp_node}.inputs:cameraPrim", [Sdf.Path(camera_path)])]
        ov = overrides.get(stream, {})
        if "width" in ov:
            rp_values.append((f"{rp_node}.inputs:width", int(ov["width"])))
        if "height" in ov:
            rp_values.append((f"{rp_node}.inputs:height", int(ov["height"])))
        set_values.extend(rp_values)

        frame_id = f"{frame_id_prefix}_{optical_suffix}"
        topic_image = f"{topic_prefix}/{stream}/image_raw"
        topic_info = f"{topic_prefix}/{stream}/camera_info"

        set_values.extend([
            (f"{helper_node}.inputs:type", helper_type),
            (f"{helper_node}.inputs:topicName", topic_image),
            (f"{helper_node}.inputs:frameId", frame_id),
            (f"{info_node}.inputs:topicName", topic_info),
            (f"{info_node}.inputs:frameId", frame_id),
        ])

        connects.extend([
            ("OnTick.outputs:tick", f"{rp_node}.inputs:execIn"),
            (f"{rp_node}.outputs:execOut", f"{helper_node}.inputs:execIn"),
            (f"{rp_node}.outputs:execOut", f"{info_node}.inputs:execIn"),
            (f"{rp_node}.outputs:renderProductPath", f"{helper_node}.inputs:renderProductPath"),
            (f"{rp_node}.outputs:renderProductPath", f"{info_node}.inputs:renderProductPath"),
        ])

    return nodes, set_values, connects


def setup_sensor_publish(stage, sensor_prim_path, ros_config, category, sensor_config=None):
    """Wire the OmniGraph ROS 2 publish chain for an existing sensor prim.

    This is the public interface between layer (b) and layer (c).

    Args:
        stage: The USD stage containing the sensor prim.
        sensor_prim_path: Absolute USD prim path of the sensor.
        ros_config: The ``ros:`` section of the sensor config dict.
            Must contain ``topic_prefix`` and ``frame_id_prefix``.
        category: Sensor category ("camera", "lidar", "imu").
        sensor_config: The full sensor config dict (needed for
            category-specific ROS wiring, e.g. lidar publish_type).

    Returns:
        The OmniGraph path created for the publish chain, or None if
        ROS wiring is not applicable.

    Raises:
        ValueError: If ros_config is missing required fields.
    """
    if ros_config is None:
        return None

    if category == "lidar":
        return _setup_lidar_ros(stage, sensor_prim_path, ros_config, sensor_config)
    if category == "imu":
        return _setup_imu_ros(stage, sensor_prim_path, ros_config, sensor_config)
    if category == "camera":
        return _setup_camera_ros(stage, sensor_prim_path, ros_config, sensor_config)
    raise ValueError(f"unsupported category for ROS publish: {category}")


# ============================================================
# Per-category ROS 2 OmniGraph wiring (require Isaac Sim)
# ============================================================


def _setup_lidar_ros(stage, lidar_prim_path, ros_config, sensor_config):
    """Build the OmniGraph ROS 2 publish chain for an RTX LiDAR."""
    import omni.graph.core as og
    from pxr import Sdf

    frame_id_prefix = ros_config["frame_id_prefix"]
    topic_prefix = ros_config["topic_prefix"].rstrip("/")
    publish_type = ros_config["publish_type"]

    graph_path = f"/World/SensorGraphs/{frame_id_prefix}_lidar"
    nodes = [
        ("OnTick", "omni.graph.action.OnPlaybackTick"),
        ("SimFrame", "isaacsim.core.nodes.OgnIsaacRunOneSimulationFrame"),
        ("RenderProduct", "isaacsim.core.nodes.IsaacCreateRenderProduct"),
        ("LidarHelper", "isaacsim.ros2.bridge.ROS2RtxLidarHelper"),
    ]
    set_values = [
        ("RenderProduct.inputs:cameraPrim", [Sdf.Path(lidar_prim_path)]),
        ("LidarHelper.inputs:type", publish_type),
        ("LidarHelper.inputs:topicName",
         f"{topic_prefix}/{'scan' if publish_type == 'laser_scan' else 'points'}"),
        ("LidarHelper.inputs:frameId", f"{frame_id_prefix}_lidar_frame"),
    ]
    connects = [
        ("OnTick.outputs:tick", "SimFrame.inputs:execIn"),
        ("SimFrame.outputs:step", "RenderProduct.inputs:execIn"),
        ("RenderProduct.outputs:execOut", "LidarHelper.inputs:execIn"),
        ("RenderProduct.outputs:renderProductPath",
         "LidarHelper.inputs:renderProductPath"),
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


def _setup_imu_ros(stage, imu_prim_path, ros_config, sensor_config):
    """Build the OmniGraph ROS 2 publish chain for an IMU sensor."""
    import omni.graph.core as og

    frame_id_prefix = ros_config["frame_id_prefix"]
    topic_prefix = ros_config["topic_prefix"].rstrip("/")

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


def _setup_camera_ros(stage, camera_mount_path, ros_config, sensor_config):
    """Build the OmniGraph ROS 2 publish chain for a camera sensor.

    This handles both realsense and custom camera types.  The camera prim
    must already exist on stage.
    """
    import omni.graph.core as og

    sensor_type = sensor_config.get("sensor", {}).get("type", "realsense")

    if sensor_type == "realsense":
        return _setup_realsense_ros(stage, camera_mount_path, ros_config, sensor_config)
    if sensor_type == "custom":
        return _setup_custom_ros(stage, camera_mount_path, ros_config, sensor_config)
    # zed: NotImplementedError in the prim layer already catches this.
    return None


def _setup_realsense_ros(stage, mount_path, ros_config, sensor_config):
    """Build the OmniGraph publish chain for a RealSense camera."""
    import omni.graph.core as og

    rsd455_root = f"{mount_path}/RSD455"

    streams = sensor_config.get("streams", {})
    overrides = sensor_config.get("overrides", {})
    topic_prefix = ros_config["topic_prefix"].rstrip("/")
    frame_id_prefix = ros_config["frame_id_prefix"]

    stream_map = {
        "color": (
            f"{rsd455_root}/Camera_OmniVision_OV9782_Color",
            "rgb",
            "color_optical_frame",
        ),
        "depth": (
            f"{rsd455_root}/Camera_Pseudo_Depth",
            "depth",
            "depth_optical_frame",
        ),
        "ir_left": (
            f"{rsd455_root}/Camera_OmniVision_OV9782_Left",
            "rgb",
            "ir_left_optical_frame",
        ),
        "ir_right": (
            f"{rsd455_root}/Camera_OmniVision_OV9782_Right",
            "rgb",
            "ir_right_optical_frame",
        ),
    }

    enabled = [s for s, on in streams.items() if on and s in stream_map]

    graph_path = f"/World/CameraGraphs/{frame_id_prefix}_realsense"
    nodes, set_values, connects = build_graph_topology(
        stream_map, enabled, overrides, topic_prefix, frame_id_prefix,
    )

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


def _setup_custom_ros(stage, mount_path, ros_config, sensor_config):
    """Build the OmniGraph publish chain for custom cameras."""
    import omni.graph.core as og

    from isaac_devkit.sensor_prim import role_to_helper_type

    sensors = sensor_config["sensors"]
    frame_id_prefix = ros_config["frame_id_prefix"]
    topic_prefix = ros_config["topic_prefix"].rstrip("/")

    stream_map = {}
    overrides = {}
    for entry in sensors:
        name = entry["name"]
        helper_type = role_to_helper_type(entry["role"])
        camera_path = f"{mount_path}/{name}"
        stream_map[name] = (camera_path, helper_type, f"{name}_optical_frame")
        overrides[name] = {
            "width": int(entry["resolution"][0]),
            "height": int(entry["resolution"][1]),
        }

    enabled = list(stream_map.keys())
    graph_path = f"/World/CameraGraphs/{frame_id_prefix}_custom"
    nodes, set_values, connects = build_graph_topology(
        stream_map, enabled, overrides, topic_prefix, frame_id_prefix,
    )

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
