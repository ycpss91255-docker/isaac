"""Output-mode resolver: ``ros`` or ``python`` (isaac#366, ADR-0025).

One global setting, the ``ISAAC_OUTPUT_MODE`` environment variable,
chooses how simulation data leaves Isaac for the whole container:

* ``python`` (default): Python callbacks receive the data; no ROS node
  is created.
* ``ros``: the native OmniGraph ROS 2 bridge publishes the topics;
  Python receives no data.

The two are exclusive. This module only resolves the value; it is pure
(no Isaac or ROS import, ADR-0017 section 8 / ADR-0023) so it is
hosted-testable.
"""

import os
from collections.abc import Mapping

ENV_VAR = "ISAAC_OUTPUT_MODE"
MODES = ("python", "ros")
DEFAULT_MODE = "python"


def resolve_output_mode(environ: Mapping[str, str] | None = None) -> str:
    """Return the active output mode.

    Args:
        environ: Mapping to read ``ISAAC_OUTPUT_MODE`` from. Defaults to
            ``os.environ``.

    Returns:
        ``"python"`` when the variable is unset, otherwise ``"ros"`` or
        ``"python"`` exactly as given.

    Raises:
        ValueError: The variable is set to anything other than exactly
            ``ros`` or ``python`` (wrong case, empty, ``both``, ...).
            The message names the offending value and the allowed set;
            there is no silent fallback.
    """
    env = os.environ if environ is None else environ
    if ENV_VAR not in env:
        return DEFAULT_MODE
    value = env[ENV_VAR]
    if value not in MODES:
        allowed = ", ".join(repr(m) for m in MODES)
        raise ValueError(f"invalid {ENV_VAR}={value!r}; allowed: {allowed}")
    return value
