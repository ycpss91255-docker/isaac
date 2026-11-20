"""Static AST guard: no module-top ROS import in isaac_devkit (ADR-0023).

Python is the sole external interface; ROS 2 wiring is a downstream
consumer. Companion of ``test_no_module_top_isaac_import.py`` for the ROS
names: ``rclpy``, ``rosidl_*``, ``builtin_interfaces`` and the
``isaacsim.ros2`` extension namespace must not be imported at module level
in any package source. Function-local imports are allowed.
"""

import ast
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

_PACKAGE_DIR = (
    Path(__file__).resolve().parents[3] / "framework" / "isaac_devkit"
)


def _is_banned(name):
    root = name.partition(".")[0]
    return (
        root in ("rclpy", "builtin_interfaces")
        or root.startswith("rosidl_")
        or name == "isaacsim.ros2"
        or name.startswith("isaacsim.ros2.")
    )


def _module_top_ros_imports(source):
    """Return ``(lineno, name)`` of banned imports at module level."""
    offenders = []
    for node in ast.parse(source).body:
        if isinstance(node, ast.Import):
            offenders += [
                (node.lineno, a.name) for a in node.names if _is_banned(a.name)
            ]
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if _is_banned(module):
                offenders.append((node.lineno, module))
    return offenders


@pytest.mark.parametrize(
    "module_file", sorted(_PACKAGE_DIR.glob("*.py")), ids=lambda p: p.name
)
def test_no_module_top_ros_import(module_file):
    offenders = _module_top_ros_imports(module_file.read_text())
    assert offenders == [], (
        f"{module_file.name} has module-top ROS import(s) {offenders}; "
        "ROS names must be function-local (ADR-0023)"
    )


@pytest.mark.parametrize(
    "line",
    [
        "import rclpy",
        "from rclpy.node import Node",
        "from rosidl_runtime_py import message_to_ordereddict",
        "from builtin_interfaces.msg import Time",
        "import isaacsim.ros2.bridge",
        "from isaacsim.ros2.bridge import ROS2Context",
    ],
)
def test_detector_flags_ros_imports(line):
    assert _module_top_ros_imports(line + "\n") != []


def test_detector_ignores_function_local_and_unrelated_imports():
    src = "import os\n\ndef f():\n    import rclpy\n    return rclpy\n"
    assert _module_top_ros_imports(src) == []
