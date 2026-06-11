"""Import-safety invariant for isaac_devkit (ADR-0017 section 8 / PRD A1).

Hosted (no Isaac Sim installed): import every ``isaac_devkit`` module --
including the package ``__init__`` re-export surface -- and assert that
after each import ``sys.modules`` contains none of ``omni`` / ``pxr`` /
``isaacsim``. "Import succeeded" alone is not sufficient: a module-top
``import omni`` inside a try/except would pass a plain import check on a
host where the import fails, yet still leak Isaac modules inside the
container. The companion static guard is the ruff TID253 rule in
``framework/pyproject.toml``.

Red state note (isaac#130 scaffold): the six module cases fail with
``ModuleNotFoundError`` until each module lands; the package and
``exceptions`` cases pass from the scaffold commit onward.
"""

import importlib
import sys
from pathlib import Path

import pytest

_FRAMEWORK_DIR = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK_DIR))

# Top-level Isaac namespaces that must never be imported at module top
# anywhere in the package (function-local imports only).
_ISAAC_TOP_LEVEL = ("omni", "pxr", "isaacsim")

# Every module of the package, plus the package itself (its curated
# __init__ re-export surface must also stay pure).
_DEVKIT_MODULES = (
    "isaac_devkit",
    "isaac_devkit.exceptions",
    "isaac_devkit.model_import",
    "isaac_devkit.materials",
    "isaac_devkit.sensors",
    "isaac_devkit.ros_io",
    "isaac_devkit.scene",
    "isaac_devkit.driver",
)


def _leaked_isaac_modules():
    """Return sorted Isaac module names currently present in sys.modules."""
    return sorted(
        name
        for name in sys.modules
        if name.partition(".")[0] in _ISAAC_TOP_LEVEL
    )


@pytest.mark.parametrize("module_name", _DEVKIT_MODULES)
def test_hosted_import_leaves_sys_modules_isaac_free(module_name):
    """Hosted import of each devkit module must not pull in Isaac modules."""
    module = importlib.import_module(module_name)
    assert module is not None

    leaked = _leaked_isaac_modules()
    assert leaked == [], (
        f"hosted import of {module_name!r} leaked Isaac modules into "
        f"sys.modules: {leaked}; every omni/pxr/isaacsim import must be "
        "function-local (ADR-0017 section 8)"
    )
