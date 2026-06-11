"""Backward-compatible shim for the extracted sensors module (isaac#130).

The unified sensor-setup code (former ``sensor_setup.py`` +
``camera_setup.py``) merged into ``isaac_devkit.sensors`` when the
framework was extracted into ``framework/isaac_devkit/`` (ADR-0017's
"one file per layer" rule). This module re-exports the former
``sensor_setup`` public surface so the existing ``src/script`` entry
points keep importing ``sensor_setup`` unchanged until they migrate with
the forklift application content (#136).

New code should import ``isaac_devkit.sensors`` directly.
"""

from isaac_devkit.sensors import (
    get_category,
    load_config,
    setup_sensor,
)

__all__ = [
    "get_category",
    "load_config",
    "setup_sensor",
]
