"""Material setup — YAML-config-driven OmniPBR + USD Variant Set.

Reads a material YAML per model and applies OmniPBR materials to
specified prims. Supports two modes:

1. **Variant mode** (color switching): multiple named variants, each
   mapping prims to different materials. USD Variant Set created for
   runtime switching. Used for objects like pallets.

2. **Single material mode**: direct prim-to-material mapping without
   variants. Used for robots or objects with fixed appearance.

Host-side functions (load, validate, query) work without Isaac Sim.
apply_materials() requires Isaac Sim (Kit-side modules).

Usage:

    from material_setup import load_material_config, apply_materials
    cfg = load_material_config("model/usd/object/pallet/material.yaml")
    apply_materials(cfg, stage, model_dir)
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


def apply_materials(cfg, stage, model_dir):
    """Apply materials to a live USD stage. Requires Isaac Sim.

    In variant mode: creates a USD Variant Set with all variants,
    each binding different OmniPBR materials to the target prims.
    Selects default_variant after creation.

    In single material mode: creates and binds OmniPBR materials
    directly to the target prims.
    """
    if "variants" in cfg:
        _apply_variant_materials(cfg, stage, model_dir)
    else:
        _apply_single_materials(cfg, stage, model_dir)


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


def _apply_variant_materials(cfg, stage, model_dir):
    """Create USD Variant Set with OmniPBR materials per variant."""
    import omni.kit.commands
    from pxr import Sdf, UsdShade

    variants = cfg["variants"]
    default_variant = cfg["default_variant"]

    all_prims = set()
    for prim_map in variants.values():
        all_prims.update(prim_map.keys())

    for prim_path in all_prims:
        prim = stage.GetPrimAtPath(prim_path)
        if not prim.IsValid():
            continue

        variant_set = prim.GetVariantSets().AddVariantSet("color")
        for vname in variants:
            variant_set.AddVariant(vname)

        for vname, prim_map in variants.items():
            if prim_path not in prim_map:
                continue
            mat_props = prim_map[prim_path]

            variant_set.SetVariantSelection(vname)
            with variant_set.GetVariantEditContext():
                mtl_prim = _create_omnipbr(
                    stage, f"/World/Looks/{prim.GetName()}_{vname}",
                    mat_props, model_dir,
                )
                mtl = UsdShade.Material(mtl_prim)
                UsdShade.MaterialBindingAPI.Apply(prim)
                UsdShade.MaterialBindingAPI(prim).Bind(mtl)

        variant_set.SetVariantSelection(default_variant)


def _apply_single_materials(cfg, stage, model_dir):
    """Create and bind OmniPBR materials directly."""
    from pxr import UsdShade

    for prim_path, mat_props in cfg["materials"].items():
        prim = stage.GetPrimAtPath(prim_path)
        if not prim.IsValid():
            continue

        mtl_prim = _create_omnipbr(
            stage, f"/World/Looks/{prim.GetName()}_mat",
            mat_props, model_dir,
        )
        mtl = UsdShade.Material(mtl_prim)
        UsdShade.MaterialBindingAPI.Apply(prim)
        UsdShade.MaterialBindingAPI(prim).Bind(mtl)


def _create_omnipbr(stage, mtl_path, mat_props, model_dir):
    """Create an OmniPBR material prim with given properties."""
    import omni.kit.commands
    from pxr import Sdf

    mtl_created_list = []
    omni.kit.commands.execute(
        "CreateAndBindMdlMaterialFromLibrary",
        mdl_name="OmniPBR.mdl",
        mtl_name="OmniPBR",
        mtl_created_list=mtl_created_list,
        prim_name=mtl_path.split("/")[-1],
    )

    mtl_prim = stage.GetPrimAtPath(mtl_created_list[0])

    if "albedo_texture" in mat_props:
        tex_path = resolve_texture_path(mat_props["albedo_texture"], model_dir)
        import omni.usd
        omni.usd.create_material_input(
            mtl_prim, "diffuse_texture",
            str(tex_path), Sdf.ValueTypeNames.Asset,
        )

    if "diffuse_color" in mat_props:
        import omni.usd
        color = tuple(float(c) for c in mat_props["diffuse_color"])
        omni.usd.create_material_input(
            mtl_prim, "diffuse_color_constant",
            color, Sdf.ValueTypeNames.Color3f,
        )

    if "roughness" in mat_props:
        import omni.usd
        omni.usd.create_material_input(
            mtl_prim, "reflection_roughness_constant",
            float(mat_props["roughness"]), Sdf.ValueTypeNames.Float,
        )

    if "metallic" in mat_props:
        import omni.usd
        omni.usd.create_material_input(
            mtl_prim, "metallic_constant",
            float(mat_props["metallic"]), Sdf.ValueTypeNames.Float,
        )

    return mtl_prim
