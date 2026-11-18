"""Backward-compatible shim for the extracted driver module (isaac#130).

The ``IsaacDriver`` lifecycle base class moved to
``isaac_devkit.driver`` when the framework was extracted into
``framework/isaac_devkit/`` (ADR-0017). This module re-exports the
public surface so the existing ``src/script`` entry points (the #127
minimal-driver runner) keep importing ``isaac_driver`` unchanged. The
forklift driver that also used this shim moved to isaac_physics_test
(#309, #320).

New code should import ``isaac_devkit.driver`` directly.
"""

from isaac_devkit.driver import (
    IsaacDriver,
    parse_livestream_env,
    resolve_repo_relative_usd,
)

__all__ = [
    "IsaacDriver",
    "parse_livestream_env",
    "resolve_repo_relative_usd",
]
