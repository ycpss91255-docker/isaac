"""Unit tests for isaac_devkit.materials — host-runnable, no Isaac Sim required.

Tests cover: material YAML loading, validation, variant enumeration,
prim-to-material mapping, and config file generation.
"""

import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import materials as material_setup


@pytest.fixture
def pallet_material_cfg(tmp_path):
    textures_dir = tmp_path / "textures"
    textures_dir.mkdir()
    (textures_dir / "wood.png").write_bytes(b"fake png")
    (textures_dir / "blue.png").write_bytes(b"fake png")
    (textures_dir / "white.png").write_bytes(b"fake png")

    cfg = {
        "variants": {
            "wood": {
                "/pallet/body": {
                    "shader": "OmniPBR",
                    "albedo_texture": "textures/wood.png",
                    "roughness": 0.8,
                },
            },
            "blue": {
                "/pallet/body": {
                    "shader": "OmniPBR",
                    "albedo_texture": "textures/blue.png",
                    "roughness": 0.4,
                },
            },
            "white": {
                "/pallet/body": {
                    "shader": "OmniPBR",
                    "albedo_texture": "textures/white.png",
                    "roughness": 0.5,
                },
            },
        },
        "default_variant": "wood",
    }
    path = tmp_path / "material.yaml"
    path.write_text(yaml.dump(cfg))
    return {"path": path, "model_dir": tmp_path}


@pytest.fixture
def single_material_cfg(tmp_path):
    cfg = {
        "materials": {
            "/robot/base_link/visual": {
                "shader": "OmniPBR",
                "diffuse_color": [0.3, 0.3, 0.3],
                "roughness": 0.6,
                "metallic": 0.2,
            },
        },
    }
    path = tmp_path / "material.yaml"
    path.write_text(yaml.dump(cfg))
    return {"path": path, "model_dir": tmp_path}


class TestLoadMaterialConfig:
    def test_loads_variant_config(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        assert "variants" in cfg
        assert len(cfg["variants"]) == 3

    def test_loads_single_material_config(self, single_material_cfg):
        cfg = material_setup.load_material_config(single_material_cfg["path"])
        assert "materials" in cfg

    def test_stores_source_path(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        assert "_source" in cfg

    def test_rejects_missing_file(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            material_setup.load_material_config(tmp_path / "nope.yaml")

    def test_rejects_empty_config(self, tmp_path):
        path = tmp_path / "empty.yaml"
        path.write_text("{}")
        with pytest.raises(ValueError, match="variants.*materials"):
            material_setup.load_material_config(path)


class TestValidateVariants:
    def test_valid_variant_config(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        assert cfg["default_variant"] == "wood"

    def test_rejects_missing_default_variant(self, tmp_path):
        cfg_data = {
            "variants": {
                "red": {"/x": {"shader": "OmniPBR"}},
            },
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg_data))
        with pytest.raises(ValueError, match="default_variant"):
            material_setup.load_material_config(path)

    def test_rejects_default_not_in_variants(self, tmp_path):
        cfg_data = {
            "variants": {
                "red": {"/x": {"shader": "OmniPBR"}},
            },
            "default_variant": "green",
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg_data))
        with pytest.raises(ValueError, match="default_variant.*not in"):
            material_setup.load_material_config(path)

    def test_rejects_empty_variants(self, tmp_path):
        cfg_data = {"variants": {}, "default_variant": "x"}
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg_data))
        with pytest.raises(ValueError, match="variants.*empty"):
            material_setup.load_material_config(path)


class TestValidateMaterials:
    def test_valid_single_material(self, single_material_cfg):
        cfg = material_setup.load_material_config(single_material_cfg["path"])
        mat = cfg["materials"]["/robot/base_link/visual"]
        assert mat["shader"] == "OmniPBR"

    def test_rejects_missing_shader(self, tmp_path):
        cfg_data = {
            "materials": {
                "/x": {"roughness": 0.5},
            },
        }
        path = tmp_path / "bad.yaml"
        path.write_text(yaml.dump(cfg_data))
        with pytest.raises(ValueError, match="shader"):
            material_setup.load_material_config(path)


class TestGetVariantNames:
    def test_returns_variant_names(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        names = material_setup.get_variant_names(cfg)
        assert set(names) == {"wood", "blue", "white"}

    def test_returns_empty_for_single_material(self, single_material_cfg):
        cfg = material_setup.load_material_config(single_material_cfg["path"])
        names = material_setup.get_variant_names(cfg)
        assert names == []


class TestGetPrimMaterialMap:
    def test_variant_prim_map(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        prim_map = material_setup.get_prim_material_map(cfg, variant="blue")
        assert "/pallet/body" in prim_map
        assert prim_map["/pallet/body"]["roughness"] == 0.4

    def test_single_material_prim_map(self, single_material_cfg):
        cfg = material_setup.load_material_config(single_material_cfg["path"])
        prim_map = material_setup.get_prim_material_map(cfg)
        assert "/robot/base_link/visual" in prim_map

    def test_rejects_unknown_variant(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        with pytest.raises(ValueError, match="variant.*not found"):
            material_setup.get_prim_material_map(cfg, variant="purple")

    def test_default_variant_used(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        prim_map = material_setup.get_prim_material_map(cfg)
        assert prim_map["/pallet/body"]["roughness"] == 0.8


class TestResolveTexturePath:
    def test_resolves_relative_to_model_dir(self, pallet_material_cfg):
        model_dir = pallet_material_cfg["model_dir"]
        resolved = material_setup.resolve_texture_path(
            "textures/wood.png", model_dir
        )
        assert resolved.exists()
        assert resolved.name == "wood.png"

    def test_rejects_missing_texture(self, tmp_path):
        with pytest.raises(FileNotFoundError, match="texture"):
            material_setup.resolve_texture_path("textures/gone.png", tmp_path)


@pytest.fixture
def color_material_cfg(tmp_path):
    """A color-only variant config (ADR-0018 decision 7: iron/green/blue)."""
    cfg = {
        "variants": {
            "iron": {
                "/board/panel": {
                    "shader": "OmniPBR",
                    "diffuse_color": [0.5, 0.5, 0.5],
                    "roughness": 0.3,
                    "metallic": 0.9,
                },
            },
            "green": {
                "/board/panel": {
                    "shader": "OmniPBR",
                    "diffuse_color": [0.1, 0.6, 0.1],
                    "roughness": 0.5,
                },
            },
            "blue": {
                "/board/panel": {
                    "shader": "OmniPBR",
                    "diffuse_color": [0.1, 0.1, 0.8],
                },
            },
        },
        "default_variant": "iron",
    }
    path = tmp_path / "material.yaml"
    path.write_text(yaml.dump(cfg))
    return {"path": path, "model_dir": tmp_path}


class TestMaterialCfgFromYaml:
    """ADR-0018 decision 7: color via spawn cfg param, no USD variant set."""

    def test_returns_per_prim_mapping(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="green")
        assert "/board/panel" in spawn_cfg
        entry = spawn_cfg["/board/panel"]
        assert entry["shader"] == "OmniPBR"

    def test_diffuse_color_is_float_tuple(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="green")
        color = spawn_cfg["/board/panel"]["diffuse_color"]
        assert color == (0.1, 0.6, 0.1)
        assert isinstance(color, tuple)
        assert all(isinstance(c, float) for c in color)

    def test_default_variant_used_when_none(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg)
        # default_variant: iron
        assert spawn_cfg["/board/panel"]["diffuse_color"] == (0.5, 0.5, 0.5)

    def test_color_varies_per_variant(self, color_material_cfg):
        """The randomization target: same prim, different color per variant."""
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        iron = material_setup.material_cfg_from_yaml(cfg, variant="iron")
        blue = material_setup.material_cfg_from_yaml(cfg, variant="blue")
        assert (
            iron["/board/panel"]["diffuse_color"]
            != blue["/board/panel"]["diffuse_color"]
        )

    def test_passthrough_roughness_metallic_as_floats(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="iron")
        entry = spawn_cfg["/board/panel"]
        assert entry["roughness"] == 0.3
        assert entry["metallic"] == 0.9
        assert isinstance(entry["roughness"], float)

    def test_omits_absent_optional_keys(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="blue")
        entry = spawn_cfg["/board/panel"]
        # blue declares no roughness/metallic/texture.
        assert "roughness" not in entry
        assert "metallic" not in entry
        assert "albedo_texture" not in entry

    def test_passthrough_texture_relative(self, pallet_material_cfg):
        cfg = material_setup.load_material_config(pallet_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="blue")
        entry = spawn_cfg["/pallet/body"]
        # Texture stays a relative path; the adapter resolves at spawn.
        assert entry["albedo_texture"] == "textures/blue.png"

    def test_single_material_mode(self, single_material_cfg):
        cfg = material_setup.load_material_config(single_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg)
        entry = spawn_cfg["/robot/base_link/visual"]
        assert entry["shader"] == "OmniPBR"
        assert entry["diffuse_color"] == (0.3, 0.3, 0.3)

    def test_result_is_json_serializable(self, color_material_cfg):
        import json
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        spawn_cfg = material_setup.material_cfg_from_yaml(cfg, variant="iron")
        # GPU-free, plain mapping: round-trips through JSON (tuples -> lists).
        round_tripped = json.loads(json.dumps(spawn_cfg))
        assert round_tripped["/board/panel"]["shader"] == "OmniPBR"

    def test_rejects_unknown_variant(self, color_material_cfg):
        cfg = material_setup.load_material_config(color_material_cfg["path"])
        with pytest.raises(ValueError, match="variant.*not found"):
            material_setup.material_cfg_from_yaml(cfg, variant="purple")
