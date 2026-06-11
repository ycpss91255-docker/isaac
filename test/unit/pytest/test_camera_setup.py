"""Unit tests for the camera surface of isaac_devkit.sensors (former
camera_setup.py) — host-runnable, no Isaac Sim required.

Covers the host-pure surface: camera-specific validation (validate_camera),
the unified load_config loader, role -> Camera Helper type mapping, and the
FOV -> aperture math. The Kit-side dispatch (setup_camera and the _setup_*
OmniGraph builders) require Isaac Sim and are exercised in integration
tests, not here.

Schema rules: doc/adr/0006-per-sensor-yaml-camera-config.md
"""

import math
import sys
from pathlib import Path

import pytest
import yaml

_FRAMEWORK = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK))
from isaac_devkit import sensors as camera_setup

_REPO_CAMERA_CONFIG = (
    Path(__file__).resolve().parents[3] / "src" / "config" / "camera"
)


def _realsense_cfg(**override):
    cfg = {
        "mount": {"parent_prim": "/World/cam", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
        "sensor": {
            "category": "camera",
            "type": "realsense",
            "asset_suffix": "Isaac/Sensors/Intel/RealSense/rsd455.usd",
        },
        "ros": {"topic_prefix": "/cam", "frame_id_prefix": "cam"},
        "streams": {"color": True, "depth": True, "ir_left": False, "ir_right": False},
    }
    cfg.update(override)
    return cfg


def _custom_cfg(**override):
    cfg = {
        "mount": {"parent_prim": "/World/cam", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
        "sensor": {"category": "camera", "type": "custom"},
        "ros": {"topic_prefix": "/cam", "frame_id_prefix": "cam"},
        "sensors": [
            {
                "role": "rgb",
                "name": "color",
                "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                "resolution": [1280, 720],
                "hfov": 90.0,
                "vfov": 60.0,
            },
        ],
    }
    cfg.update(override)
    return cfg


def _zed_cfg(**override):
    cfg = {
        "mount": {"parent_prim": "/World/cam", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
        "sensor": {"category": "camera", "type": "zed", "model": "zed_x"},
        "ros": {"topic_prefix": "/cam", "frame_id_prefix": "cam"},
        "overrides": {"resolution": "HD720", "depth_mode": "NEURAL", "fps": 30},
    }
    cfg.update(override)
    return cfg


def _write(tmp_path, cfg):
    path = tmp_path / "camera.yaml"
    path.write_text(yaml.dump(cfg))
    return path


class TestValidateCamera:
    def test_accepts_realsense(self):
        camera_setup.validate_camera(_realsense_cfg(), source="t")

    def test_accepts_custom(self):
        camera_setup.validate_camera(_custom_cfg(), source="t")

    def test_accepts_zed(self):
        camera_setup.validate_camera(_zed_cfg(), source="t")

    def test_rejects_unknown_type(self):
        cfg = _realsense_cfg()
        cfg["sensor"]["type"] = "thermal"
        with pytest.raises(ValueError, match="type"):
            camera_setup.validate_camera(cfg, source="t")

    def test_realsense_requires_a_stream_enabled(self):
        cfg = _realsense_cfg(streams={"color": False, "depth": False, "ir_left": False, "ir_right": False})
        with pytest.raises(ValueError, match="stream"):
            camera_setup.validate_camera(cfg, source="t")

    def test_realsense_missing_streams_key(self):
        cfg = _realsense_cfg()
        del cfg["streams"]
        with pytest.raises(ValueError, match="stream"):
            camera_setup.validate_camera(cfg, source="t")

    def test_custom_requires_sensors_list(self):
        cfg = _custom_cfg()
        del cfg["sensors"]
        with pytest.raises(ValueError, match="sensors"):
            camera_setup.validate_camera(cfg, source="t")

    def test_custom_rejects_empty_sensors(self):
        with pytest.raises(ValueError, match="sensors"):
            camera_setup.validate_camera(_custom_cfg(sensors=[]), source="t")

    def test_custom_rejects_non_list_sensors(self):
        with pytest.raises(ValueError, match="sensors"):
            camera_setup.validate_camera(_custom_cfg(sensors={"role": "rgb"}), source="t")

    def test_custom_entry_missing_required_key(self):
        cfg = _custom_cfg()
        del cfg["sensors"][0]["hfov"]
        with pytest.raises(ValueError, match="hfov"):
            camera_setup.validate_camera(cfg, source="t")

    def test_custom_rejects_duplicate_names(self):
        entry = _custom_cfg()["sensors"][0]
        with pytest.raises(ValueError, match="duplicate"):
            camera_setup.validate_camera(_custom_cfg(sensors=[entry, dict(entry)]), source="t")

    def test_custom_rejects_bad_role(self):
        cfg = _custom_cfg()
        cfg["sensors"][0]["role"] = "lidar"
        with pytest.raises(ValueError, match="role"):
            camera_setup.validate_camera(cfg, source="t")


class TestRoleToHelperType:
    @pytest.mark.parametrize("role", ["rgb", "color", "ir"])
    def test_rgb_family(self, role):
        assert camera_setup._role_to_helper_type(role) == "rgb"

    def test_depth(self):
        assert camera_setup._role_to_helper_type("depth") == "depth"

    def test_rejects_unknown_role(self):
        with pytest.raises(ValueError, match="role"):
            camera_setup._role_to_helper_type("thermal")


class TestFovToAperture:
    def test_90deg_at_18mm(self):
        # 2 * 18 * tan(45deg) = 36.0
        assert camera_setup._fov_to_aperture(18.0, 90.0) == pytest.approx(36.0)

    def test_60deg_at_18mm(self):
        # 2 * 18 * tan(30deg)
        expected = 2.0 * 18.0 * math.tan(math.radians(60.0) / 2.0)
        assert camera_setup._fov_to_aperture(18.0, 60.0) == pytest.approx(expected)

    def test_scales_with_focal_length(self):
        assert camera_setup._fov_to_aperture(36.0, 90.0) == pytest.approx(72.0)


class TestLoadConfig:
    def test_loads_realsense_repo_config(self):
        cfg = camera_setup.load_config(_REPO_CAMERA_CONFIG / "realsense.yaml")
        assert cfg["sensor"]["category"] == "camera"
        assert cfg["sensor"]["type"] == "realsense"

    def test_loads_custom_repo_config(self):
        cfg = camera_setup.load_config(_REPO_CAMERA_CONFIG / "custom.yaml")
        assert cfg["sensor"]["category"] == "camera"
        assert cfg["sensor"]["type"] == "custom"

    @pytest.mark.parametrize("name", ["realsense.yaml", "custom.yaml", "zed.yaml"])
    def test_shipped_configs_carry_category(self, name):
        # Regression for the schema drift that motivated this change: every
        # shipped camera config must load through the unified loader, which
        # means it must declare sensor.category = camera.
        cfg = camera_setup.load_config(_REPO_CAMERA_CONFIG / name)
        assert cfg["sensor"]["category"] == "camera"

    def test_load_config_runs_camera_validation(self, tmp_path):
        path = _write(tmp_path, _realsense_cfg(streams={"color": False, "depth": False, "ir_left": False, "ir_right": False}))
        with pytest.raises(ValueError, match="stream"):
            camera_setup.load_config(path)

    def test_load_config_runs_shared_validation(self, tmp_path):
        cfg = _realsense_cfg()
        del cfg["mount"]
        path = _write(tmp_path, cfg)
        with pytest.raises(ValueError, match="mount"):
            camera_setup.load_config(path)
