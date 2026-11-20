"""Hosted guard: the cross-container round-trip runs on the official Jetbot (#325).

``test_cross_container_roundtrip`` used to boot the bundled ``example/sim/``
camera_bot through ``example_driver``. #325 moves it onto the official Jetbot
USD fetched via ``test/test_assets.py`` (same approach as
``test_example_gpu_integration``). The GPU/docker legs cannot run on a hosted
runner, so this reads the real module + runner source and pins the migration:

* expected camera topic / frame_id follow the Jetbot camera prefix;
* the ament camera sibling is pointed at that topic (``camera_topic`` param,
  no ament package change);
* the Isaac runner takes ``--robot-usd`` and no longer imports
  ``example_driver`` / references camera_bot.

Hosted tier: no docker, no GPU, no network.
"""

import importlib.util
import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[3]
XC_DIR = REPO_ROOT / "test" / "integration" / "pytest"
XC_MODULE_PATH = XC_DIR / "test_cross_container_roundtrip.py"
XC_RUNNER_PATH = XC_DIR / "_cross_container_runner.py"


def _load_xc():
    spec = importlib.util.spec_from_file_location(
        "xc_roundtrip_migration_under_test", XC_MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_expected_camera_values_follow_the_jetbot():
    xc = _load_xc()
    assert xc.EXPECTED_CAMERA_TOPIC == "/jetbot/camera/color/image_raw"
    assert xc.EXPECTED_CAMERA_FRAME_ID == "jetbot_camera_color_optical_frame"


def test_camera_sibling_is_pointed_at_the_expected_topic():
    xc = _load_xc()
    script = xc._ament_node_script(
        custom_run=xc._camera_run_cmd()
    )
    assert f"camera_topic:={xc.EXPECTED_CAMERA_TOPIC}" in script
    assert "ros2 run example_app_py camera_subscriber" in script


def test_test_module_fetches_the_asset_via_the_helper():
    src = XC_MODULE_PATH.read_text()
    assert "fetch_test_asset" in src
    assert "--robot-usd" in src
    assert "camera_bot" not in src.replace("example_app_py", "")


def test_isaac_runner_uses_robot_usd_not_example_driver():
    src = XC_RUNNER_PATH.read_text()
    assert "--robot-usd" in src
    assert not re.search(r"^\s*from example_driver import", src, re.M)
    assert "camera_bot" not in src
    assert '"example" / "sim"' not in src
