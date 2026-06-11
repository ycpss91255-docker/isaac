"""Backward-compatible shim for the extracted scene module (isaac#130).

The scene-composition code moved to ``isaac_devkit.scene`` when the
framework was extracted into ``framework/isaac_devkit/`` (ADR-0017).
This module re-exports the public surface so that the existing
``src/script`` entry points (e.g. ``forklift_blocky_driver_wip.py`` and
the #127 integration runners that add ``src/script`` to ``sys.path``)
keep importing ``scene_builder`` unchanged until they migrate with the
forklift application content (#136).

New code should import ``isaac_devkit.scene`` directly.
"""

from isaac_devkit.scene import (
    build_scene,
    generate_instances,
    load_scene,
    resolve_model_path,
    resolve_sensor_configs,
)

__all__ = [
    "build_scene",
    "generate_instances",
    "load_scene",
    "resolve_model_path",
    "resolve_sensor_configs",
]
