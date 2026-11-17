"""Unit tests for isaac_devkit.sensor_prim -- host-runnable, no Isaac Sim.

Tests cover the sensor_prim module after the sensors.py three-layer split:
config loading, shared validation, per-category validation, and host-pure
helpers (_fov_to_aperture, _role_to_helper_type).

The key new behaviour: ``ros:`` config section is **optional**. A config
without ``ros:`` loads successfully and sets ``cfg["ros"] = None``.
"""

import math
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import sensor_prim


# -- Fixtures (identical shape to test_sensor_setup.py originals) --


@pytest.fixture
def lidar_3d_cfg(tmp_path):
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0, 0, 0.5], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "lidar",
            "type": "lidar_3d",
            "profile": "Ouster/OS1_Rev7_128ch_10Hz",
        },
        "ros": {
            "topic_prefix": "/lidar_3d",
            "frame_id_prefix": "lidar_3d",
            "publish_type": "point_cloud",
        },
    }
    path = tmp_path / "ouster_os1.yaml"
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def imu_cfg(tmp_path):
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0, 0, 0.1], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "imu",
            "type": "imu",
            "frequency_hz": 400,
            "filter": {
                "linear_acceleration": 10,
                "angular_velocity": 10,
                "orientation": 10,
            },
        },
        "ros": {
            "topic_prefix": "/imu",
            "frame_id_prefix": "imu",
        },
    }
    path = tmp_path / "default_imu.yaml"
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def camera_cfg(tmp_path):
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/camera_link",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "camera",
            "type": "realsense",
            "asset_suffix": "Isaac/Sensors/Intel/RealSense/rsd455.usd",
        },
        "ros": {
            "topic_prefix": "/camera",
            "frame_id_prefix": "camera",
        },
        "streams": {"color": True, "depth": True, "ir_left": False, "ir_right": False},
    }
    path = tmp_path / "realsense.yaml"
    path.write_text(yaml.dump(cfg))
    return path


# -- New: configs WITHOUT ros: section --


@pytest.fixture
def lidar_no_ros_cfg(tmp_path):
    """LiDAR config with no ``ros:`` section -- prim-only mode."""
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0, 0, 0.5], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "lidar",
            "type": "lidar_3d",
            "profile": "Ouster/OS1_Rev7_128ch_10Hz",
        },
    }
    path = tmp_path / "lidar_no_ros.yaml"
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def imu_no_ros_cfg(tmp_path):
    """IMU config with no ``ros:`` section -- prim-only mode."""
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0, 0, 0.1], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "imu",
            "type": "imu",
            "frequency_hz": 400,
        },
    }
    path = tmp_path / "imu_no_ros.yaml"
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def camera_no_ros_cfg(tmp_path):
    """Camera config with no ``ros:`` section -- prim-only mode."""
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/camera_link",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "camera",
            "type": "realsense",
            "asset_suffix": "Isaac/Sensors/Intel/RealSense/rsd455.usd",
        },
        "streams": {"color": True, "depth": True, "ir_left": False, "ir_right": False},
    }
    path = tmp_path / "camera_no_ros.yaml"
    path.write_text(yaml.dump(cfg))
    return path


# ============================================================
# Tests: load_config (existing behaviour preserved)
# ============================================================


class TestLoadConfig:
    def test_loads_valid_lidar(self, lidar_3d_cfg):
        cfg = sensor_prim.load_config(lidar_3d_cfg)
        assert cfg["sensor"]["category"] == "lidar"
        assert cfg["sensor"]["profile"] == "Ouster/OS1_Rev7_128ch_10Hz"

    def test_loads_valid_imu(self, imu_cfg):
        cfg = sensor_prim.load_config(imu_cfg)
        assert cfg["sensor"]["category"] == "imu"
        assert cfg["sensor"]["frequency_hz"] == 400

    def test_loads_valid_camera(self, camera_cfg):
        cfg = sensor_prim.load_config(camera_cfg)
        assert cfg["sensor"]["category"] == "camera"

    def test_stores_source_path(self, lidar_3d_cfg):
        cfg = sensor_prim.load_config(lidar_3d_cfg)
        assert cfg["_source"] == str(lidar_3d_cfg.resolve())

    def test_rejects_missing_file(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            sensor_prim.load_config(tmp_path / "nope.yaml")


# ============================================================
# Tests: ros: section is optional (NEW behaviour)
# ============================================================


class TestRosOptional:
    """When the ``ros:`` section is absent, load_config succeeds and
    ``cfg["ros"]`` is ``None``. This enables prim-only sensor placement
    without wiring ROS 2 OmniGraph publish chains."""

    def test_lidar_loads_without_ros(self, lidar_no_ros_cfg):
        cfg = sensor_prim.load_config(lidar_no_ros_cfg)
        assert cfg["sensor"]["category"] == "lidar"
        assert cfg["ros"] is None

    def test_imu_loads_without_ros(self, imu_no_ros_cfg):
        cfg = sensor_prim.load_config(imu_no_ros_cfg)
        assert cfg["sensor"]["category"] == "imu"
        assert cfg["ros"] is None

    def test_camera_loads_without_ros(self, camera_no_ros_cfg):
        cfg = sensor_prim.load_config(camera_no_ros_cfg)
        assert cfg["sensor"]["category"] == "camera"
        assert cfg["ros"] is None

    def test_lidar_no_ros_skips_publish_type_check(self, lidar_no_ros_cfg):
        """LiDAR publish_type validation lives in ros: -- should not
        fire when ros: is absent."""
        cfg = sensor_prim.load_config(lidar_no_ros_cfg)
        assert cfg["ros"] is None


# ============================================================
# Tests: shared validation (mount/sensor -- ros now optional)
# ============================================================


class TestValidateShared:
    def test_rejects_missing_mount(self, tmp_path):
        cfg = {
            "sensor": {"category": "imu", "type": "imu"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="mount"):
            sensor_prim.load_config(path)

    def test_rejects_missing_sensor(self, tmp_path):
        cfg = {
            "mount": {
                "parent_prim": "/x",
                "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
            },
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="sensor"):
            sensor_prim.load_config(path)

    def test_accepts_missing_ros(self, tmp_path):
        """ros: is optional -- missing ros: should NOT raise."""
        cfg = {
            "mount": {
                "parent_prim": "/x",
                "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
            },
            "sensor": {"category": "imu", "type": "imu"},
        }
        path = tmp_path / "ok_no_ros.yaml"
        path.write_text(yaml.dump(cfg))
        loaded = sensor_prim.load_config(path)
        assert loaded["ros"] is None

    def test_validates_ros_when_present(self, tmp_path):
        """When ros: is present but malformed, still reject."""
        cfg = {
            "mount": {
                "parent_prim": "/x",
                "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
            },
            "sensor": {"category": "imu", "type": "imu"},
            "ros": {"topic_prefix": "/x"},  # missing frame_id_prefix
        }
        path = tmp_path / "bad_ros.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="frame_id_prefix"):
            sensor_prim.load_config(path)


# ============================================================
# Tests: host-pure helpers
# ============================================================


class TestFovToAperture:
    def test_known_value(self):
        # 18mm focal, 90 deg FOV -> aperture = 2 * 18 * tan(45) = 36 mm
        result = sensor_prim.fov_to_aperture(18.0, 90.0)
        assert abs(result - 36.0) < 1e-6

    def test_zero_fov(self):
        result = sensor_prim.fov_to_aperture(18.0, 0.0)
        assert abs(result) < 1e-6


class TestRoleToHelperType:
    def test_rgb(self):
        assert sensor_prim.role_to_helper_type("rgb") == "rgb"

    def test_color(self):
        assert sensor_prim.role_to_helper_type("color") == "rgb"

    def test_ir(self):
        assert sensor_prim.role_to_helper_type("ir") == "rgb"

    def test_depth(self):
        assert sensor_prim.role_to_helper_type("depth") == "depth"

    def test_unsupported(self):
        with pytest.raises(ValueError, match="unsupported"):
            sensor_prim.role_to_helper_type("lidar")


class TestGetCategory:
    def test_lidar(self, lidar_3d_cfg):
        cfg = sensor_prim.load_config(lidar_3d_cfg)
        assert sensor_prim.get_category(cfg) == "lidar"

    def test_imu(self, imu_cfg):
        cfg = sensor_prim.load_config(imu_cfg)
        assert sensor_prim.get_category(cfg) == "imu"

    def test_camera(self, camera_cfg):
        cfg = sensor_prim.load_config(camera_cfg)
        assert sensor_prim.get_category(cfg) == "camera"
