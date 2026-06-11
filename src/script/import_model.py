#!/usr/bin/env python3
"""Backward-compatible shim for the extracted model_import module (isaac#130).

The URDF -> Asset Structure 3.0 importer moved to
``isaac_devkit.model_import`` when the framework was extracted into
``framework/isaac_devkit/`` (ADR-0017). This module re-exports ``main``
and forwards CLI execution so callers invoking
``/isaac-sim/python.sh import_model.py ...`` keep working until they
migrate with the forklift application content (#136).

New code should run ``python.sh -m isaac_devkit.model_import`` or import
``isaac_devkit.model_import`` directly.
"""

import sys

from isaac_devkit.model_import import main

__all__ = ["main"]


if __name__ == "__main__":
    sys.exit(main())
