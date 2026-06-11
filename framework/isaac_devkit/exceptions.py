"""Exception hierarchy for isaac_devkit (ADR-0017 section 9).

Shared by every module in the package; extracted first so the six
parallel module extractions can all raise from one hierarchy::

    IsaacDevkitError
    |-- SceneError
    `-- SensorConfigError
        |-- SensorNotFoundError
        `-- LinkNotFoundError

Error contract anchors (ADR-0017 section 5):

* placement ``link`` not found on the robot -> ``LinkNotFoundError``
* catalog miss across all three resolution tiers -> ``SensorNotFoundError``
* not-yet-implemented contract paths raise the builtin
  ``NotImplementedError``, deliberately NOT a subclass of
  ``IsaacDevkitError`` -- "unimplemented" is a development state, not a
  runtime input error a caller should catch alongside scene/sensor
  failures.

This module is pure (no Isaac imports) and is part of the import-safety
surface (ADR-0017 section 8 / PRD A1).
"""


class IsaacDevkitError(Exception):
    """Base class for all isaac_devkit errors."""


class SceneError(IsaacDevkitError):
    """Scene YAML load / validation / stage-build failure."""


class SensorConfigError(IsaacDevkitError):
    """Sensor catalog / placement resolution or validation failure."""


class SensorNotFoundError(SensorConfigError):
    """Catalog entry not found across all three resolution tiers.

    Tiers (ADR-0017 section 5): user catalog -> base default catalog
    (ships inside ``framework/isaac_devkit/``) -> NVIDIA Isaac builtin
    profiles.
    """


class LinkNotFoundError(SensorConfigError):
    """Placement ``link`` does not exist on the target robot prim."""
