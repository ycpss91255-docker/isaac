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

# Kit-side modules (omni.* / pxr / isaacsim.*) are imported lazily inside the
# functions that need them so the host-pure surface (load_config,
# validate_camera, _role_to_helper_type, _fov_to_aperture) stays importable
# without Isaac Sim — mirrors the deferred-import pattern in sensor_setup.py.

_SUPPORTED_TYPES = {"realsense", "custom", "zed"}

# sensors[] entry keys the custom path requires (host-validated up front).
_CUSTOM_ENTRY_KEYS = ("role", "name", "pose", "resolution", "hfov", "vfov")


def load_config(path):
    """Load a camera YAML config via the unified sensor_setup loader.

    Delegates to sensor_setup.load_config so cameras share one canonical
    validation path (shared mount/ros/category checks + the camera-specific
    validate_camera below). Kept as a convenience entry point for callers
    that only deal with cameras (e.g. forklift_blocky_driver_wip.py).
    """
    from sensor_setup import load_config as _load_config
    return _load_config(path)


def validate_camera(cfg, source):
    """Validate camera-specific fields (host-pure; no Isaac Sim).

    Assumes shared mount/ros/category checks already ran (sensor_setup.
    _validate_shared). Raises ValueError on any camera schema violation.
    """
    sensor_type = cfg["sensor"].get("type")
    if sensor_type not in _SUPPORTED_TYPES:
        raise ValueError(
            f"{source}: sensor.type='{sensor_type}' not in {sorted(_SUPPORTED_TYPES)}"
        )
    if sensor_type == "realsense":
        _validate_realsense(cfg, source)
    elif sensor_type == "custom":
        _validate_custom(cfg, source)
    # zed: the Stereolabs preset shape is validated by the extension at
    # setup time; no host-checkable required fields beyond sensor.type.


def _validate_realsense(cfg, source):
    streams = cfg.get("streams", {})
    if not any(streams.get(s) for s in ("color", "depth", "ir_left", "ir_right")):
        raise ValueError(
            f"{source}: realsense streams must enable at least one of "
            "color/depth/ir_left/ir_right"
        )


def _validate_custom(cfg, source):
    sensors = cfg.get("sensors")
    if not isinstance(sensors, list) or not sensors:
        raise ValueError(f"{source}: custom sensors must be a non-empty list")
    seen = set()
    for entry in sensors:
        for key in _CUSTOM_ENTRY_KEYS:
            if key not in entry:
                raise ValueError(f"{source}: custom sensors[] entry missing '{key}'")
        name = entry["name"]
        if name in seen:
            raise ValueError(f"{source}: duplicate custom sensors[] name '{name}'")
        seen.add(name)
        _role_to_helper_type(entry["role"])  # raises on unsupported role


def setup_camera(cfg, stage):
    """Dispatch to the per-sensor-type setup function.

    Returns the OmniGraph path created for the camera publish chain.
    """
    from isaacsim.core.utils.extensions import enable_extension

    # Single validation entry: guards direct callers that bypass load_config.
    validate_camera(cfg, source=cfg.get("_source", "<cfg>"))

    sensor_type = cfg["sensor"]["type"]
    enable_extension("isaacsim.ros2.bridge")

    if sensor_type == "realsense":
        return _setup_realsense(cfg, stage)
    if sensor_type == "custom":
        return _setup_custom(cfg, stage)
    if sensor_type == "zed":
        return _setup_zed(cfg, stage)
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
    import omni.graph.core as og
    from pxr import Gf, Usd, UsdGeom, UsdPhysics

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
    # in our local layer so PhysX sees only carriage's body, and reset the
    # xform stack at RSD455 so PhysX no longer flags it as a nested rigid
    # body missing an xform reset (the residual warning that survived the
    # RigidBodyAPI disable alone).
    rsd_prim = stage.GetPrimAtPath(rsd455_root)
    if rsd_prim.IsValid():
        UsdGeom.Xformable(rsd_prim).SetResetXformStack(True)
        for p in Usd.PrimRange(rsd_prim):
            if p.HasAPI(UsdPhysics.RigidBodyAPI):
                UsdPhysics.RigidBodyAPI(p).CreateRigidBodyEnabledAttr().Set(False)

    # D455 depth fidelity: clip the pseudo-depth camera to the sensor's valid
    # range (sensor.depth_range_m). Pixels closer than min or beyond max are
    # not reported as real depth. Out-of-range / no-surface pixels stay inf as
    # the no-data marker (real D455 reports invalid as 0); downstream
    # mask x depth -> 3D filters inf/0 alike. See ADR-0015 + ros2_cross_network.md.
    depth_range = cfg["sensor"].get("depth_range_m")
    if depth_range and len(depth_range) == 2:
        depth_cam = stage.GetPrimAtPath(f"{rsd455_root}/Camera_Pseudo_Depth")
        if depth_cam.IsValid():
            near, far = float(depth_range[0]), float(depth_range[1])
            UsdGeom.Camera(depth_cam).CreateClippingRangeAttr(Gf.Vec2f(near, far))

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

    # validate_camera (called from setup_camera) guarantees >= 1 enabled stream.
    enabled = [s for s, on in streams.items() if on and s in stream_map]

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


def _setup_custom(cfg, stage):
    """Generic camera path — one UsdGeom.Camera per sensors[] entry.

    Used for hardware with no Isaac Sim asset (e.g. ZED-M / Mini), and for
    RGB-only or depth-only setups by listing only the role you want.

    Layout:
        <parent_prim>/<frame_id_prefix>_mount      Xform with mount.pose
                     ├── <sensors[0].name>          Camera with intrinsics
                     ├── <sensors[1].name>          Camera with intrinsics
                     └── ...
    """
    import omni.graph.core as og

    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    # validate_camera (called from setup_camera) guarantees sensors is a
    # non-empty list with required keys, unique names, and valid roles.
    sensors = cfg["sensors"]

    frame_id_prefix = cfg["ros"]["frame_id_prefix"]
    topic_prefix = cfg["ros"]["topic_prefix"].rstrip("/")

    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    _set_xform_pose(mount_prim, cfg["mount"]["pose"])

    stream_map = {}
    overrides = {}
    for entry in sensors:
        name = entry["name"]
        helper_type = _role_to_helper_type(entry["role"])
        camera_path = f"{mount_path}/{name}"
        cam_prim = stage.DefinePrim(camera_path, "Camera")
        _set_xform_pose(cam_prim, entry["pose"])
        _set_camera_intrinsics(
            cam_prim,
            hfov_deg=float(entry["hfov"]),
            vfov_deg=float(entry["vfov"]),
            range_m=entry.get("range_m"),
        )
        stream_map[name] = (camera_path, helper_type, f"{name}_optical_frame")
        overrides[name] = {
            "width": int(entry["resolution"][0]),
            "height": int(entry["resolution"][1]),
        }

    enabled = list(stream_map.keys())
    graph_path = f"/World/CameraGraphs/{frame_id_prefix}_custom"
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
    og.Controller.evaluate_sync(graph)
    return graph_path


_STEREOLABS_EXTENSION_NAME = "sl.sensor.camera"
_STEREOLABS_EXTRA_PATH = "/isaac-sim/extra_exts/zed"


def _setup_zed(cfg, stage):
    """Stereolabs ZED X via the official Isaac Sim extension.

    The extension is third-party and not bundled with the
    ycpss91255-docker/isaac container, so it must be built + mounted
    in once before this dispatch can boot — see doc/zed_install.md.

    This dispatch validates that the Stereolabs extension is loadable
    and raises a tracked NotImplementedError for the OmniGraph build
    step. The graph topology depends on the Stereolabs SDK API surface,
    which is not stable across extension versions; baking it in here
    without an end-to-end test against a real install would just rot.
    The realsense (D455) and custom (ZED-M baseline) paths cover the
    practical needs of the project until ZED X is on the bench.
    """
    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    import omni.kit.app
    ext_mgr = omni.kit.app.get_app().get_extension_manager()
    if Path(_STEREOLABS_EXTRA_PATH).exists():
        ext_mgr.add_path(_STEREOLABS_EXTRA_PATH)

    if not ext_mgr.set_extension_enabled_immediate(_STEREOLABS_EXTENSION_NAME, True):
        raise RuntimeError(
            f"zed dispatch needs the Stereolabs ZED Isaac Sim extension "
            f"('{_STEREOLABS_EXTENSION_NAME}') but it was not found or could "
            f"not be enabled. Install per doc/zed_install.md and retry."
        )

    raise NotImplementedError(
        "zed dispatch: Stereolabs extension loaded successfully but the "
        "OmniGraph build step is deferred until end-to-end verification can "
        "happen against a real install. In the meantime use realsense (D455) "
        "or custom (ZED-M baseline)."
    )


def _role_to_helper_type(role):
    """Map a sensors[].role string to the Camera Helper 'type' input."""
    if role in ("rgb", "color", "ir"):
        return "rgb"
    if role == "depth":
        return "depth"
    raise ValueError(f"custom: unsupported sensors[].role '{role}'")


def _fov_to_aperture(focal_mm, fov_deg):
    """Pinhole aperture (mm) for a given focal length and field of view."""
    return 2.0 * focal_mm * math.tan(math.radians(fov_deg) / 2.0)


def _set_camera_intrinsics(prim, hfov_deg, vfov_deg, range_m=None, focal_mm=18.0):
    """Set focalLength + apertures from FOV; optional clipping range from range_m."""
    from pxr import Gf, UsdGeom

    cam = UsdGeom.Camera(prim)
    cam.CreateFocalLengthAttr(float(focal_mm))
    cam.CreateHorizontalApertureAttr(float(_fov_to_aperture(focal_mm, hfov_deg)))
    cam.CreateVerticalApertureAttr(float(_fov_to_aperture(focal_mm, vfov_deg)))
    if range_m and len(range_m) == 2:
        near, far = float(range_m[0]), float(range_m[1])
        cam.CreateClippingRangeAttr(Gf.Vec2f(near, far))


def _build_graph_topology(stream_map, enabled, overrides, topic_prefix, frame_id_prefix):
    """Action Graph topology: 1 OnTick → N (RenderProduct → Helper + InfoHelper).

    One render product per enabled stream so different camera prims (and
    therefore different optical offsets in the rsd455 asset) drive their own
    publish chain.
    """
    from pxr import Sdf

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
    from isaacsim.storage.native import get_assets_root_path

    root = get_assets_root_path()
    if root is None:
        raise RuntimeError("get_assets_root_path() returned None — Isaac Sim assets not reachable")
    return f"{root}/{suffix.lstrip('/')}"


def _set_xform_pose(prim, pose):
    """Apply translate + rotateXYZ (degrees) to a USD prim."""
    from pxr import Gf, UsdGeom

    xformable = UsdGeom.Xformable(prim)
    xformable.ClearXformOpOrder()

    translate_op = xformable.AddTranslateOp()
    x, y, z = pose["xyz"]
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))

    rotate_op = xformable.AddRotateXYZOp()
    r, p, yaw = pose["rpy"]
    rotate_op.Set(Gf.Vec3f(float(r), float(p), float(yaw)))
