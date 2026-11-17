"""Sensor OmniGraph wiring dispatcher (L3) -- category dispatch, prim + ROS.

Layer (b) of the three-layer sensor split (ADR-0024):
  (a) sensor_prim  -- config I/O, validation, prim creation helpers
  (b) sensors      -- OmniGraph wiring dispatcher (this module)
  (c) sensor_ros   -- ROS 2 OmniGraph publish chain

This module is the entry point for scene.py and standalone drivers.
It delegates config loading and validation to sensor_prim (layer a),
builds sensor prims on the USD stage, and -- when ``ros:`` config is
present -- delegates ROS 2 OmniGraph wiring to sensor_ros (layer c).

Backward compatibility: ``load_config``, ``get_category``,
``validate_camera`` are re-exported from ``sensor_prim`` so existing
callers (scene.py, example drivers, shim scripts) continue to work.

Schema rules:
  - ADR-0006 (camera): src/doc/adr/0006-per-sensor-yaml-camera-config.md
  - ADR-0010 L3 (lidar/imu): src/doc/adr/0010-isaac-dev-kit-*.md
  - ADR-0024 (three-layer split): src/doc/adr/0024-sensor-three-layer-split.md

Usage from a SimulationApp standalone driver:

    from isaac_devkit.sensors import load_config, setup_sensor
    cfg = load_config(yaml_path)
    setup_sensor(cfg, stage)

Host-side functions (load_config, get_category, validate_camera) work
without Isaac Sim.  setup_sensor() requires Isaac Sim -- every ``omni.*``
/ ``pxr`` / ``isaacsim.*`` import is function-local so the module stays
host-importable (ADR-0017 section 8 / PRD A1).
"""

from pathlib import Path

# -- Backward-compatible re-exports from sensor_prim (layer a) --
from isaac_devkit.sensor_prim import (  # noqa: F401
    fov_to_aperture as _fov_to_aperture,
    get_category,
    load_config,
    role_to_helper_type as _role_to_helper_type,
    validate_camera,
)

_STEREOLABS_EXTENSION_NAME = "sl.sensor.camera"
_STEREOLABS_EXTRA_PATH = "/isaac-sim/extra_exts/zed"


def setup_sensor(cfg, stage):
    """Dispatch to the per-category setup function.

    Builds the sensor prim on the stage.  When ``cfg["ros"]`` is not None,
    also wires the OmniGraph ROS 2 publish chain via sensor_ros (layer c).

    Requires Isaac Sim (Kit-side modules).  Returns an identifier for
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


def setup_sensors(stage, scene):
    """Build every sensor a scene declares (A7 contract entry, greenfield).

    ADR-0017 section 5: resolves each scene ``sensors[]`` entry through
    the three-tier catalog (user catalog -> base default catalog ->
    NVIDIA Isaac builtin profiles), places it on the named robot link,
    and wires the OmniGraph ROS 2 publish chain.  Contract error surface:
    a catalog miss raises ``isaac_devkit.exceptions.SensorNotFoundError``;
    a missing placement link raises
    ``isaac_devkit.exceptions.LinkNotFoundError``.

    v1 (isaac#130) lands the shape only; the camera resolution path
    arrives with isaac#131.

    Args:
        stage: The USD stage to build sensors into.
        scene: A loaded scene dict (``isaac_devkit.scene.load_scene``).

    Raises:
        NotImplementedError: Always, until isaac#131 wires the camera
            path.
    """
    raise NotImplementedError(
        "setup_sensors: catalog/placement resolution is not implemented "
        "yet (lands with isaac#131); use load_config + setup_sensor for "
        "the per-sensor YAML path in the meantime."
    )


# -- Isaac Sim dispatchers (require container) --


def _enable_extensions(*names):
    """Enable Kit extensions through the ``omni.kit.app`` extension manager.

    Deliberately NOT ``isaacsim.core.utils.extensions.enable_extension``:
    that module is deprecated since Isaac Sim 6.0 (it lives in
    ``extsDeprecated/``) and the Isaac Lab ``AppLauncher`` experience never
    loads it, so importing it raises ``ModuleNotFoundError`` there
    (isaac#248).  Enabling at runtime through the extension manager works
    under both the Isaac Lab experience and a bare ``SimulationApp``.

    Already-enabled extensions are skipped.  Raises ``RuntimeError`` when
    Kit reports that an extension could not be enabled, so a missing
    extension fails here rather than later as unknown OmniGraph node types.
    """
    import omni.kit.app

    mgr = omni.kit.app.get_app().get_extension_manager()
    for name in names:
        if mgr.is_extension_enabled(name):
            continue
        if not mgr.set_extension_enabled_immediate(name, True):
            raise RuntimeError(f"failed to enable Kit extension {name!r}")


def _setup_camera_dispatch(cfg, stage):
    """Delegate to the camera framework below (ADR-0006)."""
    return setup_camera(cfg, stage)


def _setup_lidar(cfg, stage):
    """Create RTX LiDAR sensor prim + optional ROS 2 publish chain.

    Prim creation (layer a) always runs.  ROS 2 wiring (layer c) runs
    only when ``cfg["ros"]`` is not None.
    """
    from isaac_devkit.sensor_prim import set_xform_pose

    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    sensor = cfg["sensor"]
    ros = cfg["ros"]

    # Determine mount name: use frame_id_prefix from ros if available,
    # fall back to a default for prim-only mode.
    frame_id_prefix = ros["frame_id_prefix"] if ros else "lidar"
    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    set_xform_pose(mount_prim, cfg["mount"]["pose"])

    # Enable extensions needed for prim creation.
    ext_names = ["isaacsim.sensors.rtx"]
    if ros:
        ext_names = ["isaacsim.core.nodes", "isaacsim.ros2.bridge"] + ext_names
    _enable_extensions(*ext_names)

    import omni.kit.commands
    lidar_name = "lidar"
    lidar_path = f"{mount_path}/{lidar_name}"

    if sensor["profile"] == "custom":
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

    # Layer (c): ROS 2 OmniGraph wiring -- skip when ros is None.
    if ros is None:
        return lidar_path

    from isaac_devkit.sensor_ros import setup_sensor_publish
    return setup_sensor_publish(stage, lidar_path, ros, "lidar", cfg)


def _setup_imu(cfg, stage):
    """Create IMU sensor prim + optional ROS 2 publish chain.

    Validates that parent_prim has RigidBodyAPI (physical constraint).
    """
    from pxr import UsdPhysics

    from isaac_devkit.sensor_prim import set_xform_pose

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

    frame_id_prefix = ros["frame_id_prefix"] if ros else "imu"
    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    set_xform_pose(mount_prim, cfg["mount"]["pose"])

    if ros:
        _enable_extensions("isaacsim.ros2.bridge")

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

    # Layer (c): ROS 2 OmniGraph wiring -- skip when ros is None.
    if ros is None:
        return imu_prim_path

    from isaac_devkit.sensor_ros import setup_sensor_publish
    return setup_sensor_publish(stage, imu_prim_path, ros, "imu", cfg)


# -- Camera framework (former camera_setup.py, ADR-0006) --


def setup_camera(cfg, stage):
    """Dispatch to the per-sensor-type setup function.

    Returns the OmniGraph path created for the camera publish chain,
    or the mount prim path when ros is absent.
    """
    validate_camera(cfg, source=cfg.get("_source", "<cfg>"))

    sensor_type = cfg["sensor"]["type"]

    # Enable extensions needed for prim creation; ROS bridge only when ros present.
    ext_names = ["isaacsim.core.nodes"]
    if cfg["ros"]:
        ext_names.append("isaacsim.ros2.bridge")
    _enable_extensions(*ext_names)

    if sensor_type == "realsense":
        return _setup_realsense(cfg, stage)
    if sensor_type == "custom":
        return _setup_custom(cfg, stage)
    if sensor_type == "zed":
        return _setup_zed(cfg, stage)
    raise ValueError(f"unsupported sensor.type: {sensor_type}")


def _setup_realsense(cfg, stage):
    """RealSense D455: create prim + optional ROS 2 publish chain.

    Layout:
        <parent_prim>/RealSenseMount        Xform with mount.pose applied
                     +-- RSD455 (from referenced rsd455.usd)
                         +-- Camera_OmniVision_OV9782_Color
                         +-- Camera_Pseudo_Depth
                         +-- Camera_OmniVision_OV9782_Left   (optional)
                         +-- Camera_OmniVision_OV9782_Right  (optional)
    """
    from pxr import Gf, Usd, UsdGeom, UsdPhysics

    from isaac_devkit.sensor_prim import resolve_asset_url, set_xform_pose

    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    mount_name = "RealSenseMount"
    mount_path = f"{parent_path}/{mount_name}"
    mount_prim = stage.DefinePrim(mount_path, "Xform")

    set_xform_pose(mount_prim, cfg["mount"]["pose"])

    asset_url = resolve_asset_url(cfg["sensor"]["asset_suffix"])
    mount_prim.GetReferences().AddReference(asset_url)

    rsd455_root = f"{mount_path}/RSD455"

    rsd_prim = stage.GetPrimAtPath(rsd455_root)
    if rsd_prim.IsValid():
        UsdGeom.Xformable(rsd_prim).SetResetXformStack(True)
        for p in Usd.PrimRange(rsd_prim):
            if p.HasAPI(UsdPhysics.RigidBodyAPI):
                UsdPhysics.RigidBodyAPI(p).CreateRigidBodyEnabledAttr().Set(False)

    depth_range = cfg["sensor"].get("depth_range_m")
    if depth_range and len(depth_range) == 2:
        depth_cam = stage.GetPrimAtPath(f"{rsd455_root}/Camera_Pseudo_Depth")
        if depth_cam.IsValid():
            near, far = float(depth_range[0]), float(depth_range[1])
            UsdGeom.Camera(depth_cam).CreateClippingRangeAttr(Gf.Vec2f(near, far))

    # Layer (c): ROS 2 OmniGraph wiring -- skip when ros is None.
    if cfg["ros"] is None:
        return mount_path

    from isaac_devkit.sensor_ros import setup_sensor_publish
    return setup_sensor_publish(stage, mount_path, cfg["ros"], "camera", cfg)


def _setup_custom(cfg, stage):
    """Generic camera path: create prims + optional ROS 2 publish chain.

    Layout:
        <parent_prim>/<frame_id_prefix>_mount      Xform with mount.pose
                     +-- <sensors[0].name>          Camera with intrinsics
                     +-- <sensors[1].name>          Camera with intrinsics
                     +-- ...
    """
    from isaac_devkit.sensor_prim import (
        role_to_helper_type,
        set_camera_intrinsics,
        set_xform_pose,
    )

    parent_path = cfg["mount"]["parent_prim"]
    if not stage.GetPrimAtPath(parent_path).IsValid():
        raise ValueError(f"parent_prim does not exist: {parent_path}")

    sensors = cfg["sensors"]
    ros = cfg["ros"]

    frame_id_prefix = ros["frame_id_prefix"] if ros else "custom"

    mount_path = f"{parent_path}/{frame_id_prefix}_mount"
    mount_prim = stage.DefinePrim(mount_path, "Xform")
    set_xform_pose(mount_prim, cfg["mount"]["pose"])

    for entry in sensors:
        name = entry["name"]
        role_to_helper_type(entry["role"])  # validate (raises on bad role)
        camera_path = f"{mount_path}/{name}"
        cam_prim = stage.DefinePrim(camera_path, "Camera")
        set_xform_pose(cam_prim, entry["pose"])
        set_camera_intrinsics(
            cam_prim,
            hfov_deg=float(entry["hfov"]),
            vfov_deg=float(entry["vfov"]),
            range_m=entry.get("range_m"),
        )

    # Layer (c): ROS 2 OmniGraph wiring -- skip when ros is None.
    if ros is None:
        return mount_path

    from isaac_devkit.sensor_ros import setup_sensor_publish
    return setup_sensor_publish(stage, mount_path, ros, "camera", cfg)


def _setup_zed(cfg, stage):
    """Stereolabs ZED X via the official Isaac Sim extension.

    The extension is third-party and not bundled with the
    ycpss91255-docker/isaac container.  See src/doc/zed_install.md.

    Raises NotImplementedError -- the OmniGraph topology depends on the
    Stereolabs SDK API surface and is deferred until end-to-end verification.
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
            f"not be enabled.  Install per doc/zed_install.md and retry."
        )

    raise NotImplementedError(
        "zed dispatch: Stereolabs extension loaded successfully but the "
        "OmniGraph build step is deferred until end-to-end verification can "
        "happen against a real install.  In the meantime use realsense (D455) "
        "or custom (ZED-M baseline)."
    )
