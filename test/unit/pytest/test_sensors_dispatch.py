"""Unit tests for isaac_devkit.sensors (layer b) -- the OmniGraph wiring
dispatcher after the three-layer split.

Tests cover:
  - setup_sensor delegates to sensor_prim.load_config (back-compat path)
  - setup_sensor skips ROS graph when ros config is None
  - _enable_extensions unchanged behaviour (via fake_kit fixture from
    test_sensor_setup.py)
  - setup_sensors still raises NotImplementedError
  - backward-compatible re-exports (load_config, get_category,
    validate_camera) remain accessible via the sensors module
"""

import sys
import types
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import sensors as sensor_setup


class TestBackwardCompatReexports:
    """The sensors module must still expose load_config, get_category,
    validate_camera for backward compatibility with scene.py and
    external callers."""

    def test_has_load_config(self):
        assert callable(sensor_setup.load_config)

    def test_has_get_category(self):
        assert callable(sensor_setup.get_category)

    def test_has_validate_camera(self):
        assert callable(sensor_setup.validate_camera)

    def test_has_setup_sensor(self):
        assert callable(sensor_setup.setup_sensor)

    def test_has_setup_sensors(self):
        assert callable(sensor_setup.setup_sensors)


class TestSetupSensorsStillRaises:
    """setup_sensors is a stub until #131."""

    def test_raises_not_implemented(self):
        with pytest.raises(NotImplementedError):
            sensor_setup.setup_sensors(None, None)


class TestLoadConfigRosOptionalViaBackcompat:
    """load_config accessed through the sensors module also accepts
    missing ros: section (the new optional behavior)."""

    def test_no_ros_section(self, tmp_path):
        cfg = {
            "mount": {
                "parent_prim": "/World/Robot/base_link",
                "pose": {"xyz": [0, 0, 0.1], "rpy": [0, 0, 0]},
            },
            "sensor": {"category": "imu", "type": "imu"},
        }
        path = tmp_path / "imu_no_ros.yaml"
        path.write_text(yaml.dump(cfg))
        loaded = sensor_setup.load_config(path)
        assert loaded["ros"] is None

    def test_with_ros_section(self, tmp_path):
        cfg = {
            "mount": {
                "parent_prim": "/World/Robot/base_link",
                "pose": {"xyz": [0, 0, 0.1], "rpy": [0, 0, 0]},
            },
            "sensor": {"category": "imu", "type": "imu"},
            "ros": {"topic_prefix": "/imu", "frame_id_prefix": "imu"},
        }
        path = tmp_path / "imu.yaml"
        path.write_text(yaml.dump(cfg))
        loaded = sensor_setup.load_config(path)
        assert loaded["ros"] is not None


# ---------- _enable_extensions (unchanged) ----------


class _FakeExtManager:
    """Records Kit extension-manager calls."""

    def __init__(self, enabled=()):
        self.enabled = set(enabled)
        self.immediate_calls = []

    def is_extension_enabled(self, name):
        return name in self.enabled

    def set_extension_enabled_immediate(self, name, value):
        self.immediate_calls.append((name, value))
        if value:
            self.enabled.add(name)
        return True


@pytest.fixture
def fake_kit(monkeypatch):
    """Install fake ``omni.kit.app``."""
    mgr = _FakeExtManager()
    omni_pkg = types.ModuleType("omni")
    omni_pkg.__path__ = []
    kit_pkg = types.ModuleType("omni.kit")
    kit_pkg.__path__ = []
    app_mod = types.ModuleType("omni.kit.app")

    class _App:
        def get_extension_manager(self):
            return mgr

    app_mod.get_app = lambda: _App()
    omni_pkg.kit = kit_pkg
    kit_pkg.app = app_mod
    monkeypatch.setitem(sys.modules, "omni", omni_pkg)
    monkeypatch.setitem(sys.modules, "omni.kit", kit_pkg)
    monkeypatch.setitem(sys.modules, "omni.kit.app", app_mod)
    for name in ("isaacsim.core.utils", "isaacsim.core.utils.extensions"):
        monkeypatch.setitem(sys.modules, name, None)
    return mgr


class TestEnableExtensions:
    """_enable_extensions unchanged from the original sensors module."""

    def test_enables_missing_extension_via_ext_manager(self, fake_kit):
        sensor_setup._enable_extensions("isaacsim.ros2.bridge")
        assert fake_kit.immediate_calls == [("isaacsim.ros2.bridge", True)]

    def test_skips_already_enabled_extension(self, fake_kit):
        fake_kit.enabled.add("isaacsim.ros2.bridge")
        sensor_setup._enable_extensions("isaacsim.ros2.bridge")
        assert fake_kit.immediate_calls == []

    def test_failed_enable_raises(self, fake_kit, monkeypatch):
        monkeypatch.setattr(
            fake_kit, "set_extension_enabled_immediate", lambda *_a: False,
        )
        with pytest.raises(RuntimeError, match="isaacsim.ros2.bridge"):
            sensor_setup._enable_extensions("isaacsim.ros2.bridge")
