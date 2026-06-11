"""Hosted structure-check for ``script/new-workspace.sh`` (isaac#134).

The scaffold emits a consumer workspace and pre-fills the base ``example/``
into ``src/isaac/`` so that right after ``new-workspace.sh <name>`` a
newcomer has a runnable working reference (PRD A5, M1/M5 literal). These
tests run the scaffold for real into a tmp dir (no Isaac, no GPU, no
network -- ``--no-submodule`` skips the ``git submodule add``) and assert:

* every file the A5 layout promises exists at the emitted path;
* the two-file env model (``.env`` overlay emitted; ``.env.generated`` NOT
  emitted -- it is produced by the consumer's first ``just setup``);
* the emitted driver imports cleanly on the host (import-safety preserved
  through the copy + path rewrite, PRD A1) and its pure helpers work;
* the emitted driver's path prologue points at the consumer submodule
  framework path (``src/docker/framework``) and resolves its sim assets
  relative to its own location, not the base repo's ``example/sim``.

The boot-the-sim half (scaffold -> build -> run -> camera topic) is the
GPU smoke (``test/integration/...``); this file is the hosted half.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[3]
SCAFFOLD = REPO_ROOT / "script" / "new-workspace.sh"

WS_NAME = "my-robot-ws"


@pytest.fixture(scope="module")
def scaffolded(tmp_path_factory):
    """Run new-workspace.sh once into a tmp dir; return the ws root."""
    parent = tmp_path_factory.mktemp("scaffold")
    result = subprocess.run(
        [str(SCAFFOLD), WS_NAME, "--no-submodule"],
        cwd=str(parent),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"new-workspace.sh failed (rc={result.returncode})\n"
        f"--- stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}"
    )
    ws = parent / WS_NAME
    assert ws.is_dir(), "scaffold did not create the workspace dir"
    return ws


# ---------------------------------------------------------------------------
# A5 file-tree existence.
# ---------------------------------------------------------------------------

# Every path the A5 consumer layout promises, relative to the ws root.
EXPECTED_FILES = [
    ".env",
    "src/isaac/README.md",
    "src/isaac/README.zh-TW.md",
    "src/isaac/README.zh-CN.md",
    "src/isaac/README.ja.md",
    "src/isaac/sim/example_driver.py",
    "src/isaac/sim/config/sensor/custom.yaml",
    "src/isaac/sim/scene/scene.yaml",
    "src/isaac/sim/scene/robot.yaml",
    "src/isaac/sim/scene/object.yaml",
    "src/isaac/sim/model/camera_bot.urdf",
    "src/isaac/sim/model/usd/robot/camera_bot/camera_bot.usd",
    "src/isaac/ros2/src/example_app_py/package.xml",
    "src/isaac/ros2/src/example_app_py/setup.py",
    "src/isaac/ros2/src/example_app_py/example_app_py/camera_subscriber.py",
    "src/isaac/ros2/src/example_app_py/example_app_py/cmd_vel_publisher.py",
]


@pytest.mark.parametrize("rel", EXPECTED_FILES)
def test_emitted_file_exists(scaffolded, rel):
    """Every A5-promised file exists at the emitted path."""
    assert (scaffolded / rel).is_file(), f"missing emitted file: {rel}"


def test_src_docker_submodule_placeholder(scaffolded):
    """With --no-submodule the src/docker mount point is present.

    The real run does ``git submodule add`` pinned to a base tag; with
    ``--no-submodule`` (offline/test) the scaffold still creates the
    ``src/docker`` directory as the framework mount point so the layout
    is complete.
    """
    assert (scaffolded / "src" / "docker").is_dir()


# ---------------------------------------------------------------------------
# Two-file env model (PRD A5).
# ---------------------------------------------------------------------------


def test_env_overlay_emitted_generated_is_not(scaffolded):
    """The scaffold emits the hand-written .env overlay, not .env.generated.

    ``.env.generated`` is the consumer's first ``just setup`` /
    ``just build`` output, never the scaffold's.
    """
    assert (scaffolded / ".env").is_file()
    assert not (scaffolded / ".env.generated").exists()


def test_env_overlay_holds_workload_vars(scaffolded):
    """The overlay carries per-task workload vars (e.g. ROS_DOMAIN_ID)."""
    body = (scaffolded / ".env").read_text()
    assert "ROS_DOMAIN_ID" in body


# ---------------------------------------------------------------------------
# Driver import-safety + path rewrite for the consumer layout.
# ---------------------------------------------------------------------------


def _load_emitted_driver(ws):
    """Import the emitted driver module from its scaffolded location."""
    driver_path = ws / "src" / "isaac" / "sim" / "example_driver.py"
    # The emitted driver inserts the consumer framework path itself; mirror
    # the runtime sys.path so the import resolves isaac_devkit.
    fw = ws / "src" / "docker" / "framework"
    fw.mkdir(parents=True, exist_ok=True)
    # Point the consumer framework at the base repo's framework so the
    # import resolves on the host (the real submodule IS this repo).
    base_fw = REPO_ROOT / "framework"
    for child in base_fw.iterdir():
        link = fw / child.name
        if not link.exists():
            link.symlink_to(child)
    sys.path.insert(0, str(fw))
    spec = importlib.util.spec_from_file_location(
        "emitted_example_driver", str(driver_path)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_emitted_driver_imports_cleanly(scaffolded):
    """The emitted driver imports on the host with no Isaac modules pulled."""
    module = _load_emitted_driver(scaffolded)
    for banned in ("omni", "pxr", "isaacsim"):
        assert banned not in sys.modules, (
            f"{banned} leaked into sys.modules on emitted-driver import"
        )
    # Pure helpers survive the copy.
    assert module.cmd_vel_to_planar_velocity([1.0, 2.0, 0.0], [0.0, 0.0, 3.0]) == (
        1.0,
        2.0,
        3.0,
    )


def test_emitted_driver_scene_path_is_consumer_relative(scaffolded):
    """SCENE points at the consumer sim scene, not example/sim."""
    module = _load_emitted_driver(scaffolded)
    assert "example/sim" not in module.ExampleDriver.SCENE
    assert module.ExampleDriver.SCENE.endswith("scene.yaml")


def test_emitted_driver_resolves_its_own_three_file_scene(scaffolded):
    """The emitted driver loads + merges its own three-file scene."""
    module = _load_emitted_driver(scaffolded)
    scene_yaml = scaffolded / "src" / "isaac" / "sim" / "scene" / "scene.yaml"
    scene = module.load_three_file_scene(scene_yaml)
    assert scene["robot"]["name"] == "camera_bot"
    assert scene["objects"][0]["mobility"] in ("dynamic", "static")
    assert scene["ros2_io"]["subscriptions"][0]["topic"] == "/cmd_vel"


def test_emitted_driver_framework_path_is_submodule(scaffolded):
    """The driver's framework path is the consumer submodule path.

    In the consumer layout the framework rides at
    ``<ws>/src/docker/framework`` (the src/docker submodule), not the base
    repo's ``<repo>/framework``.
    """
    driver_src = (
        scaffolded / "src" / "isaac" / "sim" / "example_driver.py"
    ).read_text()
    assert "src" in driver_src and "docker" in driver_src and "framework" in driver_src
    # The base-repo "example/sim" asset prefix must be gone.
    assert '"example" / "sim"' not in driver_src
