"""Material setup — YAML-config-driven material cfg parameters.

Reads a material YAML per model and maps it to the cfg-param structure
the Isaac Lab spawn adapter consumes (ADR-0018 decision 7): visual
material (including color) is applied at SPAWN time as an Isaac Lab
``sim_utils`` material cfg parameter, NOT as a USD variant set.

Color-only "variants" (e.g. the iron / green / blue boards) are no
longer USD variant sets -- color is a material parameter on the same
mesh/texture, varied at spawn (and randomized there for
domain-randomization image generation). The variant *naming* in the YAML
schema is retained only for structurally-distinct variants (different
mesh / topology / texture file); ``material_cfg_from_yaml`` collapses a
chosen variant down to a flat per-prim cfg-param mapping the spawn
adapter (#152) attaches to ``sim_utils.PreviewSurfaceCfg`` /
``visual_material``.

This module is entirely pure / host-runnable: it reads and validates the
YAML and produces a plain, JSON-serializable, GPU-free mapping. The
actual spawn-time material binding (the Isaac Sim / GPU side) lives in
the spawn adapter (#152) and gets its GPU coverage there (#154).

Usage:

    from isaac_devkit.materials import (
        load_material_config, material_cfg_from_yaml,
    )
    cfg = load_material_config("model/usd/object/pallet/material.yaml")
    spawn_material = material_cfg_from_yaml(cfg, variant="blue")
"""

from pathlib import Path

import yaml


def load_material_config(path):
    """Load and validate a material YAML config."""
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"material config not found: {p}")
    with p.open() as f:
        cfg = yaml.safe_load(f)
    _validate(cfg, source=str(p))
    cfg["_source"] = str(p)
    return cfg


def get_variant_names(cfg):
    """Return list of variant names, or [] if single material mode."""
    if "variants" not in cfg:
        return []
    return list(cfg["variants"].keys())


def get_prim_material_map(cfg, variant=None):
    """Return {prim_path: material_props} for the given variant.

    In single material mode, variant is ignored.
    In variant mode, if variant is None, uses default_variant.
    """
    if "materials" in cfg:
        return dict(cfg["materials"])

    if variant is None:
        variant = cfg.get("default_variant")
    variants = cfg["variants"]
    if variant not in variants:
        raise ValueError(
            f"variant '{variant}' not found in {sorted(variants.keys())}"
        )
    return dict(variants[variant])


def resolve_texture_path(texture_rel, model_dir):
    """Resolve a texture path relative to the model directory."""
    resolved = Path(model_dir) / texture_rel
    if not resolved.exists():
        raise FileNotFoundError(
            f"texture not found: {resolved} "
            f"(from texture_rel='{texture_rel}', model_dir='{model_dir}')"
        )
    return resolved


def material_cfg_from_yaml(cfg, variant=None):
    """Map a material YAML spec to spawn-time cfg parameters (ADR-0018 dec 7).

    Produces the cfg-param structure the Isaac Lab spawn adapter (#152)
    attaches to a ``sim_utils`` visual material (e.g.
    ``PreviewSurfaceCfg(diffuse_color=...)`` or an MDL/OmniPBR cfg with a
    color param), instead of authoring a USD variant set. The result is a
    plain, JSON-serializable, GPU-free mapping; no Isaac / pxr import.

    Per prim, the returned dict carries:

    * ``shader`` -- the shader name from the YAML (e.g. ``"OmniPBR"``),
      so the adapter can pick the matching ``sim_utils`` cfg class;
    * ``diffuse_color`` -- an ``(r, g, b)`` tuple of floats, when the
      YAML declares one (this is the color-only randomization target);
    * ``albedo_texture`` / ``roughness`` / ``metallic`` -- passed through
      verbatim when present (textures stay relative paths; the adapter
      resolves them against the model dir at spawn).

    Args:
        cfg: A loaded material config (from ``load_material_config``).
        variant: Variant name to resolve in variant mode; ``None`` uses
            ``default_variant``. Ignored in single-material mode.

    Returns:
        ``{prim_path: {"shader": str, "diffuse_color": (r,g,b)?, ...}}``.

    Raises:
        ValueError: If ``variant`` is unknown (via
            ``get_prim_material_map``).
    """
    prim_map = get_prim_material_map(cfg, variant=variant)

    spawn_cfg = {}
    for prim_path, props in prim_map.items():
        entry = {"shader": props["shader"]}
        if "diffuse_color" in props:
            entry["diffuse_color"] = tuple(
                float(c) for c in props["diffuse_color"]
            )
        for key in ("albedo_texture", "roughness", "metallic"):
            if key in props:
                value = props[key]
                if key in ("roughness", "metallic"):
                    value = float(value)
                entry[key] = value
        spawn_cfg[prim_path] = entry
    return spawn_cfg


def _validate(cfg, source):
    """Validate material config structure."""
    has_variants = "variants" in cfg
    has_materials = "materials" in cfg

    if not has_variants and not has_materials:
        raise ValueError(
            f"{source}: needs either 'variants' or 'materials' top-level key"
        )

    if has_variants:
        _validate_variants(cfg, source)
    if has_materials:
        _validate_materials(cfg, source)


def _validate_variants(cfg, source):
    variants = cfg["variants"]
    if not variants:
        raise ValueError(f"{source}: variants is empty")

    if "default_variant" not in cfg:
        raise ValueError(f"{source}: variant mode requires 'default_variant'")

    default = cfg["default_variant"]
    if default not in variants:
        raise ValueError(
            f"{source}: default_variant '{default}' not in "
            f"{sorted(variants.keys())}"
        )

    for vname, prim_map in variants.items():
        for prim_path, mat_props in prim_map.items():
            if "shader" not in mat_props:
                raise ValueError(
                    f"{source}: variants.{vname}.{prim_path} needs 'shader'"
                )


def _validate_materials(cfg, source):
    for prim_path, mat_props in cfg["materials"].items():
        if "shader" not in mat_props:
            raise ValueError(
                f"{source}: materials.{prim_path} needs 'shader'"
            )
