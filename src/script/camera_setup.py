"""Backward-compatible shim for the extracted camera surface (isaac#130).

The per-sensor-type camera framework (former ``camera_setup.py``) merged
into ``isaac_devkit.sensors`` when the framework was extracted into
``framework/isaac_devkit/`` (ADR-0017's "one file per layer" rule). This
module re-exports the former ``camera_setup`` public surface so the
existing ``src/script`` entry points (the #127 camera-headless runner,
``forklift_blocky_driver_wip.py``) keep importing ``camera_setup``
unchanged until they migrate with the forklift application content
(#136).

New code should import ``isaac_devkit.sensors`` directly.
"""

from isaac_devkit.sensors import (
    load_config,
    setup_camera,
    validate_camera,
)

__all__ = [
    "load_config",
    "setup_camera",
    "validate_camera",
]
