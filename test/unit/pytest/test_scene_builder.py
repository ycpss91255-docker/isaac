"""Unit tests for scene_builder.py — host-runnable, no Isaac Sim required.

Tests cover: YAML loading, validation, model path resolution,
multi-instance generation, and sensor config reference resolution.
"""

import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "script"))
import scene_builder


@pytest.fixture
def repo_root(tmp_path):
    """Create a minimal model directory structure for path resolution."""
    usd_dir = tmp_path / "model" / "usd" / "robot" / "openbase"
    usd_dir.mkdir(parents=True)
    (usd_dir / "openbase.usd").write_text("#usda 1.0")

    obj_dir = tmp_path / "model" / "usd" / "object" / "pallet"
    obj_dir.mkdir(parents=True)
    (obj_dir / "pallet.usd").write_text("#usda 1.0")

    sensor_dir = tmp_path / "config" / "camera"
    sensor_dir.mkdir(parents=True)
    sensor_cfg = {
        "mount": {"parent_prim": "/World/Robot/base_link", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
        "sensor": {"category": "camera", "type": "realsense", "asset_suffix": "x"},
        "ros": {"topic_prefix": "/cam", "frame_id_prefix": "cam"},
        "streams": {"color": True, "depth": True},
    }
    (sensor_dir / "realsense.yaml").write_text(yaml.dump(sensor_cfg))

    imu_dir = tmp_path / "config" / "imu"
    imu_dir.mkdir(parents=True)
    imu_cfg = {
        "mount": {"parent_prim": "/World/Robot/base_link", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
        "sensor": {"category": "imu", "type": "imu"},
        "ros": {"topic_prefix": "/imu", "frame_id_prefix": "imu"},
    }
    (imu_dir / "default.yaml").write_text(yaml.dump(imu_cfg))

    return tmp_path


@pytest.fixture
def minimal_scene(repo_root):
    cfg = {
        "robot": {
            "model": "robot/openbase/openbase.usd",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
        },
    }
    path = repo_root / "scene" / "minimal.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.dump(cfg))
    return path


@pytest.fixture
def full_scene(repo_root):
    cfg = {
        "robot": {
            "model": "robot/openbase/openbase.usd",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
        },
        "objects": [
            {
                "model": "object/pallet/pallet.usd",
                "pose": {"xyz": [3.0, 0.5, 0.8], "rpy": [0, 0, 0]},
                "variant": {"color": "blue"},
            },
            {
                "model": "object/pallet/pallet.usd",
                "pose": {"xyz": [3.0, 1.0, 0.8], "rpy": [0, 0, 0]},
                "count": 3,
                "spacing": [0, 0.2, 0],
            },
        ],
        "sensors": [
            "config/camera/realsense.yaml",
            "config/imu/default.yaml",
        ],
    }
    path = repo_root / "scene" / "full.yaml"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.dump(cfg))
    return path


class TestLoadScene:
    def test_loads_minimal_scene(self, minimal_scene, repo_root):
        scene = scene_builder.load_scene(minimal_scene, repo_root=repo_root)
        assert "robot" in scene
        assert scene["robot"]["model"] == "robot/openbase/openbase.usd"

    def test_loads_full_scene(self, full_scene, repo_root):
        scene = scene_builder.load_scene(full_scene, repo_root=repo_root)
        assert "robot" in scene
        assert len(scene["objects"]) == 2
        assert len(scene["sensors"]) == 2

    def test_rejects_missing_file(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            scene_builder.load_scene(tmp_path / "nope.yaml", repo_root=tmp_path)

    def test_rejects_missing_robot(self, repo_root):
        cfg = {"objects": []}
        path = repo_root / "scene" / "bad.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="robot"):
            scene_builder.load_scene(path, repo_root=repo_root)


class TestValidateScene:
    def test_rejects_robot_without_model(self, repo_root):
        cfg = {"robot": {"pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}}}
        path = repo_root / "scene" / "bad.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="model"):
            scene_builder.load_scene(path, repo_root=repo_root)

    def test_rejects_robot_without_pose(self, repo_root):
        cfg = {"robot": {"model": "robot/openbase/openbase.usd"}}
        path = repo_root / "scene" / "bad.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="pose"):
            scene_builder.load_scene(path, repo_root=repo_root)

    def test_rejects_object_without_model(self, repo_root):
        cfg = {
            "robot": {"model": "robot/openbase/openbase.usd", "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}},
            "objects": [{"pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]}}],
        }
        path = repo_root / "scene" / "bad.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.dump(cfg))
        with pytest.raises(ValueError, match="model"):
            scene_builder.load_scene(path, repo_root=repo_root)


class TestResolveModelPath:
    def test_resolves_robot_model(self, repo_root):
        resolved = scene_builder.resolve_model_path("robot/openbase/openbase.usd", repo_root)
        assert resolved.exists()
        assert resolved.name == "openbase.usd"

    def test_resolves_object_model(self, repo_root):
        resolved = scene_builder.resolve_model_path("object/pallet/pallet.usd", repo_root)
        assert resolved.exists()

    def test_rejects_missing_model(self, repo_root):
        with pytest.raises(FileNotFoundError, match="not found"):
            scene_builder.resolve_model_path("robot/nope/nope.usd", repo_root)


class TestGenerateInstances:
    def test_single_instance(self):
        entry = {
            "model": "object/pallet/pallet.usd",
            "pose": {"xyz": [1.0, 2.0, 3.0], "rpy": [0, 0, 0]},
        }
        instances = scene_builder.generate_instances(entry)
        assert len(instances) == 1
        assert instances[0]["pose"]["xyz"] == [1.0, 2.0, 3.0]

    def test_multi_instance_with_spacing(self):
        entry = {
            "model": "object/pallet/pallet.usd",
            "pose": {"xyz": [1.0, 0.0, 0.0], "rpy": [0, 0, 0]},
            "count": 3,
            "spacing": [0, 0.5, 0],
        }
        instances = scene_builder.generate_instances(entry)
        assert len(instances) == 3
        assert instances[0]["pose"]["xyz"] == [1.0, 0.0, 0.0]
        assert instances[1]["pose"]["xyz"] == pytest.approx([1.0, 0.5, 0.0])
        assert instances[2]["pose"]["xyz"] == pytest.approx([1.0, 1.0, 0.0])

    def test_multi_instance_preserves_variant(self):
        entry = {
            "model": "object/pallet/pallet.usd",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
            "variant": {"color": "blue"},
            "count": 2,
            "spacing": [1, 0, 0],
        }
        instances = scene_builder.generate_instances(entry)
        assert all(i.get("variant") == {"color": "blue"} for i in instances)

    def test_count_defaults_to_one(self):
        entry = {
            "model": "x",
            "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
        }
        instances = scene_builder.generate_instances(entry)
        assert len(instances) == 1


class TestResolveSensorConfigs:
    def test_resolves_sensor_paths(self, full_scene, repo_root):
        scene = scene_builder.load_scene(full_scene, repo_root=repo_root)
        resolved = scene_builder.resolve_sensor_configs(scene, repo_root)
        assert len(resolved) == 2
        assert all(Path(p).exists() for p in resolved)

    def test_rejects_missing_sensor_config(self, repo_root):
        scene = {"sensors": ["config/lidar/nonexistent.yaml"]}
        with pytest.raises(FileNotFoundError):
            scene_builder.resolve_sensor_configs(scene, repo_root)

    def test_empty_sensors_ok(self, repo_root):
        scene = {}
        resolved = scene_builder.resolve_sensor_configs(scene, repo_root)
        assert resolved == []
