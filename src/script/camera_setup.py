"""Sim camera setup — YAML-config-driven, dispatches by sensor.type.

Schema rules live in doc/adr/0006-per-sensor-yaml-camera-config.md.

Usage from a SimulationApp standalone driver:

    from camera_setup import load_config, setup_camera
    cfg = load_config(yaml_path)
    setup_camera(cfg, stage)

This module must be imported AFTER `SimulationApp(...)` since it pulls in
Kit-side modules (`omni.*`, `pxr`, `isaacsim.*`).
"""

import math
from pathlib import Path

import yaml

import omni.graph.core as og
import omni.usd
from pxr import Gf, Sdf, Usd, UsdGeom, UsdPhysics

from isaacsim.core.utils.extensions import enable_extension
from isaacsim.storage.native import get_assets_root_path

_SUPPORTED_TYPES = {"realsense", "custom", "zed"}


def load_config(path):
    """Load a single camera YAML config; raise on missing required keys."""
    p = Path(path).expanduser().resolve()
    with p.open() as f:
        cfg = yaml.safe_load(f)
    _validate(cfg, source=str(p))
    cfg["_source"] = str(p)
    return cfg


def _validate(cfg, source):
    for key in ("mount", "sensor", "ros"):
        if key not in cfg:
            raise ValueError(f"{source}: missing top-level key '{key}'")
    if "parent_prim" not in cfg["mount"] or "pose" not in cfg["mount"]:
        raise ValueError(f"{source}: mount needs 'parent_prim' and 'pose'")
    if "xyz" not in cfg["mount"]["pose"] or "rpy" not in cfg["mount"]["pose"]:
        raise ValueError(f"{source}: mount.pose needs 'xyz' and 'rpy'")
    sensor_type = cfg["sensor"].get("type")
    if sensor_type not in _SUPPORTED_TYPES:
        raise ValueError(
            f"{source}: sensor.type='{sensor_type}' not in {sorted(_SUPPORTED_TYPES)}"
        )
    for key in ("topic_prefix", "frame_id_prefix"):
        if key not in cfg["ros"]:
            raise ValueError(f"{source}: ros needs '{key}'")


def setup_camera(cfg, stage):
    """Dispatch to the per-sensor-type setup function.

    Returns the OmniGraph path created for the camera publish chain.
    """
    sensor_type = cfg["sensor"]["type"]
    enable_extension("isaacsim.ros2.bridge")

    if sensor_type == "realsense":
        return _setup_realsense(cfg, stage)
    if sensor_type == "custom":
        raise NotImplementedError(
            "custom sensor.type lands in PR-2 (umbrella issue #6)"
        )
    if sensor_type == "zed":
        raise NotImplementedError(
            "zed sensor.type lands in PR-3 (umbrella issue #6)"
        )
    raise ValueError(f"unsupported sensor.type: {sensor_type}")


def _setup_realsense(cfg, stage):
    """RealSense D455 via Isaac Sim's bundled rsd455.usd asset.

    Layout:
        <parent_prim>/RealSenseMount        Xform with mount.pose applied
                     └── RSD455 (from referenced rsd455.usd)
                         ├── Camera_OmniVision_OV9782_Color  → color stream
                         ├── Camera_Pseudo_Depth             → depth stream
                         ├── Camera_OmniVision_OV9782_Left   → ir_left (optional)
                         └── Camera_OmniVision_OV9782_Right  → ir_right (optional)
    """
    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    mount_name = "RealSenseMount"
    mount_path = f"{parent_path}/{mount_name}"
    mount_prim = stage.DefinePrim(mount_path, "Xform")

    # Apply mount pose (translate + rotate)
    _set_xform_pose(mount_prim, cfg["mount"]["pose"])

    # Reference the rsd455 asset under the mount prim
    asset_url = _resolve_asset_url(cfg["sensor"]["asset_suffix"])
    mount_prim.GetReferences().AddReference(asset_url)

    # Asset root after referencing — rsd455.usd defines /Root/RSD455 internally,
    # so once referenced under mount_prim, RSD455 lives at <mount>/RSD455.
    rsd455_root = f"{mount_path}/RSD455"

    # rsd455.usd carries its own RigidBodyAPI on the RSD455 subtree (for
    # standalone physical-prop usage). Nested under our kinematic carriage
    # this triggers a "nested rigid body" PhysX error and breaks the
    # forklift's own rigid body registration. Override RigidBodyAPI off
    # in our local layer so PhysX sees only carriage's body.
    rsd_prim = stage.GetPrimAtPath(rsd455_root)
    if rsd_prim.IsValid():
        for p in Usd.PrimRange(rsd_prim):
            if p.HasAPI(UsdPhysics.RigidBodyAPI):
                UsdPhysics.RigidBodyAPI(p).CreateRigidBodyEnabledAttr().Set(False)

    streams = cfg.get("streams", {})
    overrides = cfg.get("overrides", {})
    topic_prefix = cfg["ros"]["topic_prefix"].rstrip("/")
    frame_id_prefix = cfg["ros"]["frame_id_prefix"]

    # Stream → (camera prim suffix, helper type, optical_frame_suffix)
    stream_map = {
        "color":    (f"{rsd455_root}/Camera_OmniVision_OV9782_Color", "rgb",   "color_optical_frame"),
        "depth":    (f"{rsd455_root}/Camera_Pseudo_Depth",            "depth", "depth_optical_frame"),
        "ir_left":  (f"{rsd455_root}/Camera_OmniVision_OV9782_Left",  "rgb",   "ir_left_optical_frame"),
        "ir_right": (f"{rsd455_root}/Camera_OmniVision_OV9782_Right", "rgb",   "ir_right_optical_frame"),
    }

    enabled = [s for s, on in streams.items() if on and s in stream_map]
    if not enabled:
        raise ValueError("streams: at least one of color/depth/ir_left/ir_right must be true")

    graph_path = f"/World/CameraGraphs/{frame_id_prefix}_realsense"
    nodes, set_values, connects = _build_graph_topology(
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
    # Evaluate once to materialize the ROS publishers in the SDG pipeline.
    # Without this the graph nodes exist but no ROS topics actually appear.
    og.Controller.evaluate_sync(graph)
    return graph_path


def _build_graph_topology(stream_map, enabled, overrides, topic_prefix, frame_id_prefix):
    """Action Graph topology: 1 OnTick → N (RenderProduct → Helper + InfoHelper).

    One render product per enabled stream so different camera prims (and
    therefore different optical offsets in the rsd455 asset) drive their own
    publish chain.
    """
    nodes = [("OnTick", "omni.graph.action.OnPlaybackTick")]
    set_values = []
    connects = []

    for stream in enabled:
        camera_path, helper_type, optical_suffix = stream_map[stream]
        # node names: per-stream prefix
        rp_node = f"RP_{stream}"
        helper_node = f"Helper_{stream}"
        info_node = f"Info_{stream}"

        nodes.extend([
            (rp_node, "isaacsim.core.nodes.IsaacCreateRenderProduct"),
            (helper_node, "isaacsim.ros2.bridge.ROS2CameraHelper"),
            (info_node, "isaacsim.ros2.bridge.ROS2CameraInfoHelper"),
        ])

        # Render product points at the camera prim. Resolution override if any.
        rp_values = [(f"{rp_node}.inputs:cameraPrim", [Sdf.Path(camera_path)])]
        ov = overrides.get(stream, {})
        if "width" in ov:
            rp_values.append((f"{rp_node}.inputs:width", int(ov["width"])))
        if "height" in ov:
            rp_values.append((f"{rp_node}.inputs:height", int(ov["height"])))
        set_values.extend(rp_values)

        frame_id = f"{frame_id_prefix}_{optical_suffix}"
        topic_image = f"{topic_prefix}/{stream}/image_raw"
        topic_info  = f"{topic_prefix}/{stream}/camera_info"

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


def _resolve_asset_url(suffix):
    root = get_assets_root_path()
    if root is None:
        raise RuntimeError("get_assets_root_path() returned None — Isaac Sim assets not reachable")
    return f"{root}/{suffix.lstrip('/')}"


def _set_xform_pose(prim, pose):
    """Apply translate + rotateXYZ (degrees) to a USD prim."""
    xformable = UsdGeom.Xformable(prim)
    xformable.ClearXformOpOrder()

    translate_op = xformable.AddTranslateOp()
    x, y, z = pose["xyz"]
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))

    rotate_op = xformable.AddRotateXYZOp()
    r, p, yaw = pose["rpy"]
    rotate_op.Set(Gf.Vec3f(float(r), float(p), float(yaw)))
