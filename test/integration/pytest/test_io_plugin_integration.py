"""ISAAC_IO_PLUGIN reaches the stage through IsaacDriver.run (isaac#423).

With the variable set, a fake plugin defines a marker prim on the official
Jetbot stage and the prim exists once the timeline is playing. Without it,
no ``rclpy`` / ``isaacsim.ros2*`` module is imported. Asserted via stdout
markers (Kit's ``app.close`` calls ``_exit(0)``).
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT))

from test.test_assets import fetch_test_asset  # noqa: E402

import pytest

pytestmark = pytest.mark.core

HERE = Path(__file__).parent
RUNNER_SCRIPT = HERE / "_io_plugin_runner.py"
SCRIPT_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 240


def _run(plugin):
    env = {k: v for k, v in os.environ.items() if k != "ISAAC_IO_PLUGIN"}
    env["PYTHONPATH"] = os.pathsep.join(
        [str(HERE)] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else [])
    )
    if plugin is not None:
        env["ISAAC_IO_PLUGIN"] = plugin
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER_SCRIPT), "--script-dir", str(SCRIPT_DIR),
         "--usd-path", str(fetch_test_asset("jetbot"))],
        capture_output=True, text=True, timeout=SUBPROC_TIMEOUT_SEC, env=env,
    )
    return result.stdout


def test_plugin_marker_prim_exists_after_play():
    out = _run("_io_plugin_marker:make_marker")
    assert "[MARKER_PRIM] True" in out, out[-1000:]


def test_no_plugin_imports_no_ros_modules():
    out = _run(None)
    assert "[MARKER_PRIM] False" in out, out[-1000:]
    assert "[ROS_MODULES] []" in out, out[-1000:]
