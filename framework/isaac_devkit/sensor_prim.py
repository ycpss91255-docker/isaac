"""Sensor prim creation -- config loading, validation, USD prim helpers.

Layer (a) of the three-layer sensor split (ADR-0024):
  (a) sensor_prim  -- config I/O, validation, prim creation helpers
  (b) sensors      -- OmniGraph wiring dispatcher
  (c) sensor_ros   -- ROS 2 OmniGraph publish chain

Host-side functions (load_config, get_category, validate_camera,
validation helpers, fov_to_aperture, role_to_helper_type) work without
Isaac Sim.  The prim-creation helpers (_set_xform_pose,
_set_camera_intrinsics, _resolve_asset_url) require Isaac Sim and keep
all ``pxr`` / ``omni`` imports function-local (ADR-0017 section 8).

The ``ros:`` config section is **optional**.  When absent, load_config
sets ``cfg["ros"] = None`` and the caller (layer b) skips OmniGraph
wiring.  This enables sensor prim placement without ROS 2 dependencies.
"""

import math
from pathlib import Path

import yaml

_SUPPORTED_CATEGORIES = {"camera", "lidar", "imu"}
_LIDAR_TYPES = {"lidar_3d", "lidar_2d"}
_LIDAR_PUBLISH_TYPES = {"point_cloud", "laser_scan"}

_SUPPORTED_TYPES = {"realsense", "custom", "zed"}

# sensors[] entry keys the custom path requires (host-validated up front).
_CUSTOM_ENTRY_KEYS = ("role", "name", "pose", "resolution", "hfov", "vfov")

_STEREOLABS_EXTENSION_NAME = "sl.sensor.camera"
_STEREOLABS_EXTRA_PATH = "/isaac-sim/extra_exts/zed"


# ============================================================
# Config loading and validation
# ============================================================


def load_config(path):
    """Load a sensor YAML config; validate shared + per-category rules.

    The ``ros:`` section is optional.  When absent the returned dict has
    ``cfg["ros"] = None`` and the OmniGraph wiring layer (sensors.py)
    skips ROS 2 graph creation.
    """
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"sensor config not found: {p}")
    with p.open() as f:
        cfg = yaml.safe_load(f)
    _validate_shared(cfg, source=str(p))

    # ros: is optional -- normalize to None when absent.
    if "ros" not in cfg:
        cfg["ros"] = None
    else:
        _validate_ros(cfg, source=str(p))

    category = cfg["sensor"]["category"]
    if category == "camera":
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


# ============================================================
# Validation helpers
# ============================================================


def _validate_shared(cfg, source):
    """Validate top-level keys: mount and sensor are required; ros is optional."""
    for key in ("mount", "sensor"):
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


def _validate_ros(cfg, source):
    """Validate the ros: section when it is present."""
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

    # publish_type validation only when ros: is present.
    ros = cfg.get("ros")
    if ros is not None:
        publish_type = ros.get("publish_type")
        if publish_type not in _LIDAR_PUBLISH_TYPES:
            raise ValueError(
                f"{source}: ros.publish_type='{publish_type}' not in "
                f"{sorted(_LIDAR_PUBLISH_TYPES)}"
            )


def _validate_imu(cfg, source):
    """Validate IMU-specific fields (host-side checks only)."""
    pass


def validate_camera(cfg, source):
    """Validate camera-specific fields (host-pure; no Isaac Sim).

    Assumes shared mount/sensor checks already ran (_validate_shared).
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
        role_to_helper_type(entry["role"])  # raises on unsupported role


# ============================================================
# Host-pure helpers
# ============================================================


def role_to_helper_type(role):
    """Map a sensors[].role string to the Camera Helper 'type' input."""
    if role in ("rgb", "color", "ir"):
        return "rgb"
    if role == "depth":
        return "depth"
    raise ValueError(f"custom: unsupported sensors[].role '{role}'")


def fov_to_aperture(focal_mm, fov_deg):
    """Pinhole aperture (mm) for a given focal length and field of view."""
    return 2.0 * focal_mm * math.tan(math.radians(fov_deg) / 2.0)


# ============================================================
# Isaac Sim prim helpers (require container)
# ============================================================


def set_xform_pose(prim, pose):
    """Apply translate + rotateXYZ (degrees) to a USD prim.

    Single shared copy -- the two byte-identical copies the old
    sensor_setup.py / camera_setup.py files carried collapsed here.
    """
    from pxr import Gf, UsdGeom

    xformable = UsdGeom.Xformable(prim)
    xformable.ClearXformOpOrder()

    translate_op = xformable.AddTranslateOp()
    x, y, z = pose["xyz"]
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))

    rotate_op = xformable.AddRotateXYZOp()
    r, p, yaw = pose["rpy"]
    rotate_op.Set(Gf.Vec3f(float(r), float(p), float(yaw)))


def set_camera_intrinsics(prim, hfov_deg, vfov_deg, range_m=None, focal_mm=18.0):
    """Set focalLength + apertures from FOV; optional clipping range."""
    from pxr import Gf, UsdGeom

    cam = UsdGeom.Camera(prim)
    cam.CreateFocalLengthAttr(float(focal_mm))
    cam.CreateHorizontalApertureAttr(float(fov_to_aperture(focal_mm, hfov_deg)))
    cam.CreateVerticalApertureAttr(float(fov_to_aperture(focal_mm, vfov_deg)))
    if range_m and len(range_m) == 2:
        near, far = float(range_m[0]), float(range_m[1])
        cam.CreateClippingRangeAttr(Gf.Vec2f(near, far))


def resolve_asset_url(suffix):
    """Resolve an Isaac Sim asset path from a relative suffix."""
    from isaacsim.storage.native import get_assets_root_path

    root = get_assets_root_path()
    if root is None:
        raise RuntimeError(
            "get_assets_root_path() returned None -- Isaac Sim assets not reachable"
        )
    return f"{root}/{suffix.lstrip('/')}"
