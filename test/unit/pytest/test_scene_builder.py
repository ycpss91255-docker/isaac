"""Unit tests for isaac_devkit.scene — host-runnable, no Isaac Sim required.

Tests cover: YAML loading, validation, model path resolution,
multi-instance generation, and sensor config reference resolution.
"""

import math
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import scene as scene_builder


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


class TestRpyToQuat:
    """Pure rpy(deg) -> (w,x,y,z) quaternion, XYZ intrinsic order."""

    def test_identity(self):
        w, x, y, z = scene_builder.rpy_to_quat([0, 0, 0])
        assert (w, x, y, z) == pytest.approx((1.0, 0.0, 0.0, 0.0))

    def test_yaw_90(self):
        # 90 deg about Z -> (cos45, 0, 0, sin45).
        w, x, y, z = scene_builder.rpy_to_quat([0, 0, 90])
        s = math.sqrt(2) / 2
        assert (w, x, y, z) == pytest.approx((s, 0.0, 0.0, s))

    def test_roll_90(self):
        # 90 deg about X -> (cos45, sin45, 0, 0).
        w, x, y, z = scene_builder.rpy_to_quat([90, 0, 0])
        s = math.sqrt(2) / 2
        assert (w, x, y, z) == pytest.approx((s, s, 0.0, 0.0))

    def test_pitch_90(self):
        # 90 deg about Y -> (cos45, 0, sin45, 0).
        w, x, y, z = scene_builder.rpy_to_quat([0, 90, 0])
        s = math.sqrt(2) / 2
        assert (w, x, y, z) == pytest.approx((s, 0.0, s, 0.0))

    def test_unit_norm(self):
        w, x, y, z = scene_builder.rpy_to_quat([30, 45, 60])
        norm = math.sqrt(w * w + x * x + y * y + z * z)
        assert norm == pytest.approx(1.0)


def _scene_dict(robot=None, objects=None, environment=None):
    base_robot = {
        "model": "robot/openbase/openbase.usd",
        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
    }
    if robot:
        base_robot.update(robot)
    scene = {"robot": base_robot}
    if objects is not None:
        scene["objects"] = objects
    if environment is not None:
        scene["environment"] = environment
    return scene


class TestToIsaaclabCfg:
    """Pure YAML -> SpawnSpec mapping; asserted without a live stage."""

    def test_default_environment_emits_light_only(self, repo_root):
        # No environment block -> no ground, but a default light is emitted.
        specs = scene_builder.to_isaaclab_cfg(_scene_dict(), repo_root)
        kinds = [s.kind for s in specs]
        assert "ground_plane" not in kinds
        assert kinds[0] == "distant_light"

    def test_ground_plane_spec(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(environment={"ground_plane": True}), repo_root
        )
        ground = next(s for s in specs if s.kind == "ground_plane")
        assert ground.prim_path == "/World/ground"
        assert ground.mobility is None

    def test_default_light_when_absent(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(environment={"ground_plane": True}), repo_root
        )
        light = next(s for s in specs if s.kind == "distant_light")
        assert light.prim_path == "/World/light"
        assert light.kwargs.get("intensity") == 3000.0

    def test_curated_light_fields(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                environment={
                    "light": {
                        "intensity": 1500.0,
                        "color": [0.5, 0.5, 0.5],
                        "angle": 0.3,
                    }
                }
            ),
            repo_root,
        )
        light = next(s for s in specs if s.kind == "distant_light")
        assert light.kwargs["intensity"] == 1500.0
        assert light.kwargs["color"] == [0.5, 0.5, 0.5]
        assert light.kwargs["angle"] == 0.3

    def test_emits_specs_in_order(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                environment={"ground_plane": True},
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [1, 0, 0], "rpy": [0, 0, 0]},
                    }
                ],
            ),
            repo_root,
        )
        kinds = [s.kind for s in specs]
        # ground, light, robot usd, object usd -- in that order.
        assert kinds == ["ground_plane", "distant_light", "usd", "usd"]

    def test_robot_usd_spec(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(robot={"pose": {"xyz": [1.0, 2.0, 3.0], "rpy": [0, 0, 0]}}),
            repo_root,
        )
        robot = next(s for s in specs if s.prim_path == "/World/Robot")
        assert robot.kind == "usd"
        assert robot.kwargs["usd_path"].endswith("openbase.usd")
        assert robot.translation == pytest.approx((1.0, 2.0, 3.0))
        assert robot.orientation == pytest.approx((1.0, 0.0, 0.0, 0.0))
        assert robot.mobility is None

    def test_object_usd_spec_translation_and_path(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [3.0, 0.5, 0.8], "rpy": [0, 0, 0]},
                        "mobility": "dynamic",
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        assert obj.prim_path == "/World/Objects/pallet_0_0"
        assert obj.kwargs["usd_path"].endswith("pallet.usd")
        assert obj.translation == pytest.approx((3.0, 0.5, 0.8))
        assert obj.mobility == "dynamic"

    def test_object_static_mobility(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                        "mobility": "static",
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        assert obj.mobility == "static"

    def test_object_rpy_to_orientation(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 90]},
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        s = math.sqrt(2) / 2
        assert obj.orientation == pytest.approx((s, 0.0, 0.0, s))

    def test_instance_expansion_flows_through(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [3.0, 1.0, 0.8], "rpy": [0, 0, 0]},
                        "count": 3,
                        "spacing": [0, 0.2, 0],
                        "mobility": "dynamic",
                    }
                ]
            ),
            repo_root,
        )
        objs = [
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        ]
        assert len(objs) == 3
        assert objs[0].prim_path == "/World/Objects/pallet_0_0"
        assert objs[2].prim_path == "/World/Objects/pallet_0_2"
        assert objs[1].translation == pytest.approx((3.0, 1.2, 0.8))
        assert objs[2].translation == pytest.approx((3.0, 1.4, 0.8))
        assert all(o.mobility == "dynamic" for o in objs)

    def test_spawn_overrides_spread_onto_kwargs(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                robot={
                    "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                    "spawn_overrides": {"scale": (2.0, 2.0, 2.0)},
                }
            ),
            repo_root,
        )
        robot = next(s for s in specs if s.prim_path == "/World/Robot")
        assert robot.kwargs["scale"] == (2.0, 2.0, 2.0)

    def test_spawn_overrides_win_over_curated(self, repo_root):
        # An override on usd_path beats the curated resolved path.
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                robot={
                    "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                    "spawn_overrides": {"usd_path": "/override/path.usd"},
                }
            ),
            repo_root,
        )
        robot = next(s for s in specs if s.prim_path == "/World/Robot")
        assert robot.kwargs["usd_path"] == "/override/path.usd"

    def test_variant_carried_as_variants_kwarg(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                        "variant": {"shape": "tall"},
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        assert obj.kwargs["variants"] == {"shape": "tall"}

    def test_specs_are_json_serializable(self, repo_root):
        import json

        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(environment={"ground_plane": True}), repo_root
        )
        # NamedTuple -> list of fields; every field is plain data.
        json.dumps([list(s) for s in specs])

    def test_material_diffuse_recorded(self, repo_root, tmp_path):
        # A material YAML referenced by an object records a diffuse color
        # under visual_material_diffuse so build_scene can attach it.
        material = {
            "materials": {
                "/Looks/Body": {
                    "shader": "OmniPBR",
                    "diffuse_color": [0.1, 0.2, 0.3],
                }
            }
        }
        mat_path = repo_root / "model" / "usd" / "object" / "pallet" / "mat.yaml"
        mat_path.write_text(yaml.dump(material))
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                        "material": "model/usd/object/pallet/mat.yaml",
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        assert obj.kwargs["visual_material_diffuse"] == pytest.approx(
            (0.1, 0.2, 0.3)
        )

    def test_no_material_no_diffuse_key(self, repo_root):
        specs = scene_builder.to_isaaclab_cfg(
            _scene_dict(
                objects=[
                    {
                        "model": "object/pallet/pallet.usd",
                        "pose": {"xyz": [0, 0, 0], "rpy": [0, 0, 0]},
                    }
                ]
            ),
            repo_root,
        )
        obj = next(
            s for s in specs if s.prim_path.startswith("/World/Objects/")
        )
        assert "visual_material_diffuse" not in obj.kwargs
