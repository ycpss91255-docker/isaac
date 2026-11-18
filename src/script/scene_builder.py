"""Backward-compatible shim for the extracted scene module (isaac#130).

The scene-composition code moved to ``isaac_devkit.scene`` when the
framework was extracted into ``framework/isaac_devkit/`` (ADR-0017).
This module re-exports the public surface so that the existing
``src/script`` entry points (e.g. the #127 integration runners that add ``src/script``
to ``sys.path``) keep importing ``scene_builder`` unchanged. The forklift
driver that also used this shim moved to isaac_physics_test (#309, #320).

New code should import ``isaac_devkit.scene`` directly.
"""

from isaac_devkit.scene import (
    build_scene,
    generate_instances,
    load_scene,
    resolve_model_path,
    resolve_sensor_configs,
    to_isaaclab_cfg,
)

__all__ = [
    "build_scene",
    "generate_instances",
    "load_scene",
    "resolve_model_path",
    "resolve_sensor_configs",
    "to_isaaclab_cfg",
]
