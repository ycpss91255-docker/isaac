"""Backward-compatible shim for the extracted materials module (isaac#130).

The material-setup code moved to ``isaac_devkit.materials`` when the
framework was extracted into ``framework/isaac_devkit/`` (ADR-0017).
This module re-exports the public surface so the existing ``src/script``
entry points keep importing ``material_setup`` unchanged until they
migrate with the forklift application content (#136).

New code should import ``isaac_devkit.materials`` directly.
"""

from isaac_devkit.materials import (
    apply_materials,
    get_prim_material_map,
    get_variant_names,
    load_material_config,
    resolve_texture_path,
)

__all__ = [
    "apply_materials",
    "get_prim_material_map",
    "get_variant_names",
    "load_material_config",
    "resolve_texture_path",
]
