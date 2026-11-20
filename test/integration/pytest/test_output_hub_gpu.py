"""OutputHub GPU delivery test (isaac#365).

Boots a headless Isaac scene inside the devel-test GPU container with the
official Jetbot USD (``test/test_assets.py``), builds the python-mode
output (RGB + depth camera, joint state, IMU) through ``setup_output``,
steps the app and asserts every registered callback fired with the
documented dtypes. Pass criterion is marker lines from
``_output_hub_runner.py`` (Kit's ``app.close`` swallows the exit code).

Run inside the GPU test container::

    ./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
        <repo>/test/integration/pytest/test_output_hub_gpu.py -s
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

_TEST_DIR = Path(__file__).resolve().parents[2]
if str(_TEST_DIR) not in sys.path:
    sys.path.insert(0, str(_TEST_DIR))

from test_assets import fetch_test_asset  # noqa: E402

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).parent / "_output_hub_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 900

requires_isaac = pytest.mark.skipif(
    not Path(PYTHON_SH).exists(), reason="needs the Isaac container"
)


@pytest.fixture(scope="module")
def runner_output():
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER), "--repo-root", str(REPO_ROOT),
         "--robot-usd", str(fetch_test_asset("jetbot"))],
        capture_output=True, text=True, timeout=SUBPROC_TIMEOUT_SEC,
    )
    out = result.stdout
    assert "[HUB RAISED]" not in out, out[-2000:]
    assert "[HUB EXIT CLEAN]" in out, out[-2000:]
    return out


@requires_isaac
def test_rgb_callback_delivers_uint8_hw3(runner_output):
    m = re.search(r"\[HUB RGB\] count=(\d+) dtype=(\S+) shape=(\S+)",
                  runner_output)
    assert m and int(m.group(1)) >= 1, runner_output[-1500:]
    assert m.group(2) == "uint8" and m.group(3) == "480x640x3"


@requires_isaac
def test_depth_callback_delivers_float32_hw(runner_output):
    m = re.search(r"\[HUB DEPTH\] count=(\d+) dtype=(\S+) shape=(\S+)",
                  runner_output)
    assert m and int(m.group(1)) >= 1, runner_output[-1500:]
    assert m.group(2) == "float32" and m.group(3) == "480x640"


@requires_isaac
def test_joint_state_callback_delivers_names(runner_output):
    m = re.search(r"\[HUB JOINT\] count=(\d+) names=(\d+)", runner_output)
    assert m and int(m.group(1)) >= 1 and int(m.group(2)) >= 1


@requires_isaac
def test_imu_callback_delivers_wxyz_orientation(runner_output):
    m = re.search(r"\[HUB IMU\] count=(\d+) orientation_len=(\d+)",
                  runner_output)
    assert m and int(m.group(1)) >= 1 and int(m.group(2)) == 4
