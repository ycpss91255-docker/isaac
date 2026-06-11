"""Unit tests for isaac_devkit.sensors (former sensor_setup.py) —
host-runnable, no Isaac Sim required.

Tests cover: YAML loading, shared validation (mount/ros), category dispatch,
per-category validation (lidar profile, IMU rigid body requirement),
and config file examples.
"""

import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import sensors as sensor_setup


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
def lidar_2d_cfg(tmp_path):
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0.2, 0, 0.1], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "lidar",
            "type": "lidar_2d",
            "profile": "SLAMTEC/RPLIDAR_S2E",
        },
        "ros": {
            "topic_prefix": "/scan",
            "frame_id_prefix": "base_scan",
            "publish_type": "laser_scan",
        },
    }
    path = tmp_path / "rplidar_s2e.yaml"
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def lidar_custom_cfg(tmp_path):
    custom_json = tmp_path / "my_lidar.json"
    custom_json.write_text("{}")
    cfg = {
        "mount": {
            "parent_prim": "/World/Robot/base_link",
            "pose": {"xyz": [0, 0, 0.5], "rpy": [0, 0, 0]},
        },
        "sensor": {
            "category": "lidar",
            "type": "lidar_3d",
            "profile": "custom",
            "config_path": str(custom_json),
        },
        "ros": {
            "topic_prefix": "/lidar",
            "frame_id_prefix": "lidar",
            "publish_type": "point_cloud",
        },
    }
    path = tmp_path / "custom_lidar.yaml"
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


class TestLoadConfig:
    def test_loads_valid_lidar(self, lidar_3d_cfg):
        cfg = sensor_setup.load_config(lidar_3d_cfg)
        assert cfg["sensor"]["category"] == "lidar"
        assert cfg["sensor"]["profile"] == "Ouster/OS1_Rev7_128ch_10Hz"

    def test_loads_valid_imu(self, imu_cfg):
        cfg = sensor_setup.load_config(imu_cfg)
        assert cfg["sensor"]["category"] == "imu"
        assert cfg["sensor"]["frequency_hz"] == 400

    def test_loads_valid_camera(self, camera_cfg):
        cfg = sensor_setup.load_config(camera_cfg)
        assert cfg["sensor"]["category"] == "camera"

    def test_stores_source_path(self, lidar_3d_cfg):
        cfg = sensor_setup.load_config(lidar_3d_cfg)
        assert cfg["_source"] == str(lidar_3d_cfg.resolve())

    def test_rejects_missing_file(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            sensor_setup.load_config(tmp_path / "nope.yaml")


class TestValidateShared:
    def test_rejects_missing_mount(self, tmp_path):
        cfg = {"sensor": {"category": "imu", "type": "imu"}, "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"}}
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="mount"):
            sensor_setup.load_config(path)

    def test_rejects_missing_sensor(self, tmp_path):
        cfg = {"mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}}, "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"}}
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="sensor"):
            sensor_setup.load_config(path)

    def test_rejects_missing_ros(self, tmp_path):
        cfg = {"mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}}, "sensor": {"category": "imu", "type": "imu"}}
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="ros"):
            sensor_setup.load_config(path)

    def test_rejects_missing_pose_xyz(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"rpy": [0, 0, 0]}},
            "sensor": {"category": "imu", "type": "imu"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="xyz"):
            sensor_setup.load_config(path)

    def test_rejects_invalid_category(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "radar", "type": "radar"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="category"):
            sensor_setup.load_config(path)


class TestValidateLidar:
    def test_rejects_missing_profile(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "lidar", "type": "lidar_3d"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x", "publish_type": "point_cloud"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="profile"):
            sensor_setup.load_config(path)

    def test_rejects_missing_publish_type(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "lidar", "type": "lidar_3d", "profile": "X/Y"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="publish_type"):
            sensor_setup.load_config(path)

    def test_rejects_invalid_publish_type(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "lidar", "type": "lidar_3d", "profile": "X/Y"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x", "publish_type": "image"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="publish_type"):
            sensor_setup.load_config(path)

    def test_accepts_point_cloud(self, lidar_3d_cfg):
        cfg = sensor_setup.load_config(lidar_3d_cfg)
        assert cfg["ros"]["publish_type"] == "point_cloud"

    def test_accepts_laser_scan(self, lidar_2d_cfg):
        cfg = sensor_setup.load_config(lidar_2d_cfg)
        assert cfg["ros"]["publish_type"] == "laser_scan"

    def test_custom_profile_requires_config_path(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "lidar", "type": "lidar_3d", "profile": "custom"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x", "publish_type": "point_cloud"},
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="config_path"):
            sensor_setup.load_config(path)

    def test_custom_profile_with_config_path(self, lidar_custom_cfg):
        cfg = sensor_setup.load_config(lidar_custom_cfg)
        assert cfg["sensor"]["profile"] == "custom"
        assert "config_path" in cfg["sensor"]


class TestValidateImu:
    def test_valid_imu_loads(self, imu_cfg):
        cfg = sensor_setup.load_config(imu_cfg)
        assert cfg["sensor"]["type"] == "imu"

    def test_defaults_frequency(self, tmp_path):
        cfg = {
            "mount": {"parent_prim": "/x", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "sensor": {"category": "imu", "type": "imu"},
            "ros": {"topic_prefix": "/x", "frame_id_prefix": "x"},
        }
        path = tmp_path / "minimal_imu.yaml"
        path.write_text(yaml.dump(cfg))
        loaded = sensor_setup.load_config(path)
        assert loaded["sensor"].get("frequency_hz", 200) > 0


class TestGetCategory:
    def test_lidar(self, lidar_3d_cfg):
        cfg = sensor_setup.load_config(lidar_3d_cfg)
        assert sensor_setup.get_category(cfg) == "lidar"

    def test_imu(self, imu_cfg):
        cfg = sensor_setup.load_config(imu_cfg)
        assert sensor_setup.get_category(cfg) == "imu"

    def test_camera(self, camera_cfg):
        cfg = sensor_setup.load_config(camera_cfg)
        assert sensor_setup.get_category(cfg) == "camera"
