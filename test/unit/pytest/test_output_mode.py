"""Output-mode resolver (isaac#366).

``ISAAC_OUTPUT_MODE`` selects exactly one output path for the whole
container: ``python`` (default; Python callbacks, no ROS) or ``ros`` (the
native OmniGraph ROS 2 bridge; no Python data). The resolver is pure --
no Isaac or ROS import -- so it is hosted-testable (ADR-0025).
"""

import sys
from pathlib import Path

import pytest

_FRAMEWORK_DIR = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK_DIR))

from isaac_devkit.output_mode import (  # noqa: E402
    DEFAULT_MODE,
    ENV_VAR,
    MODES,
    resolve_output_mode,
)

pytestmark = pytest.mark.core


def test_unset_defaults_to_python():
    assert resolve_output_mode({}) == "python"


@pytest.mark.parametrize("value", ["ros", "python"])
def test_valid_values_pass_through(value):
    assert resolve_output_mode({"ISAAC_OUTPUT_MODE": value}) == value


@pytest.mark.parametrize("value", ["ROS", "Python", "", "both", " ros", "ros "])
def test_invalid_values_raise_naming_value_and_allowed_set(value):
    with pytest.raises(ValueError) as exc:
        resolve_output_mode({"ISAAC_OUTPUT_MODE": value})
    msg = str(exc.value)
    assert repr(value) in msg
    assert "ISAAC_OUTPUT_MODE" in msg
    assert "'ros'" in msg and "'python'" in msg


def test_other_variables_are_ignored():
    assert resolve_output_mode({"ISAAC_LIVESTREAM": "1"}) == "python"


def test_reads_os_environ_by_default(monkeypatch):
    monkeypatch.setenv("ISAAC_OUTPUT_MODE", "ros")
    assert resolve_output_mode() == "ros"
    monkeypatch.delenv("ISAAC_OUTPUT_MODE")
    assert resolve_output_mode() == "python"


def test_constants():
    assert ENV_VAR == "ISAAC_OUTPUT_MODE"
    assert set(MODES) == {"ros", "python"}
    assert DEFAULT_MODE == "python"
