"""Static AST guard: no module-top Isaac import in isaac_devkit (ADR-0017
section 8 / PRD A1).

The runtime companion ``test_import_safety.py`` imports each module on a
host with no Isaac Sim and asserts ``sys.modules`` stays free of
``omni`` / ``pxr`` / ``isaacsim``. That alone misses a module-top
``import omni`` wrapped in ``try/except ImportError`` -- on a host the
import fails silently, so nothing leaks, yet inside the container the
same line would execute at import time and break the invariant.

This guard parses every package source with ``ast`` and asserts that no
``import omni|pxr|isaacsim`` (or ``from omni|pxr|isaacsim import ...``)
appears at module level (depth 0) -- the same rule the ruff TID253
``banned-module-level-imports`` config in ``framework/pyproject.toml``
enforces, restated as a hosted pytest so it runs in the unit job even
where ruff is not invoked. Isaac imports nested inside function bodies
(any deeper statement) are allowed.
"""

import ast
from pathlib import Path

import pytest

_PACKAGE_DIR = (
    Path(__file__).resolve().parents[3] / "framework" / "isaac_devkit"
)
_BANNED_TOP_LEVEL = ("omni", "pxr", "isaacsim", "isaaclab")


def _module_files():
    return sorted(_PACKAGE_DIR.glob("*.py"))


def _top_root(name):
    """Return the top-level package of a dotted module name."""
    return name.partition(".")[0]


def _module_top_isaac_imports(source):
    """Return banned Isaac imports that sit at module level (depth 0).

    Walks only the module body's direct children, so imports nested in
    function or class bodies are not reported.
    """
    tree = ast.parse(source)
    offenders = []
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                if _top_root(alias.name) in _BANNED_TOP_LEVEL:
                    offenders.append((node.lineno, alias.name))
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if _top_root(module) in _BANNED_TOP_LEVEL:
                offenders.append((node.lineno, module))
    return offenders


@pytest.mark.parametrize(
    "module_file", _module_files(), ids=lambda p: p.name
)
def test_no_module_top_isaac_import(module_file):
    """Every package source must keep Isaac imports function-local."""
    offenders = _module_top_isaac_imports(module_file.read_text())
    assert offenders == [], (
        f"{module_file.name} has module-top Isaac import(s) "
        f"{offenders}; every omni/pxr/isaacsim import must be "
        "function-local (ADR-0017 section 8 / PRD A1)"
    )
