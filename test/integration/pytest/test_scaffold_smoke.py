"""Scaffold GPU smoke: new-workspace.sh -> boot -> camera topic (isaac#134).

The PRD A5 / DoD smoke: ``new-workspace.sh <name>`` -> build -> run ->
assert the camera topic appears. This test runs inside the devel-test GPU
container (via ``./script/run.sh -t test -- /isaac-sim/python.sh -m
pytest ...``), so the "build" leg is the already-built test image; the
"run" leg boots the SCAFFOLDED ``example_driver.py`` headless (no
livestream -- bypasses IsaacSim#228).

What it proves end-to-end:

1. ``script/new-workspace.sh <name> --local-docker <repo>`` emits the A5
   consumer workspace, pre-fills the example, and wires ``src/docker`` to
   the live repo so the scaffolded driver resolves the framework at
   ``<ws>/src/docker/framework`` with no network.
2. Booting the SCAFFOLDED driver (path prologue rewritten for the
   consumer layout) on a live Kit stage emits ``[BOOT OK]`` /
   ``[CAMERA GRAPH OK]`` / ``[EXIT CLEAN]`` and publishes the camera
   topic, which a sibling rclpy probe receives (``[SCAFFOLD CAMERA OK]``).

Marker-line acceptance (Kit ``_exit(0)`` swallows the return code).
GPU-only: skipped on a host without ``/isaac-sim``.
"""

import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
SCAFFOLD = REPO_ROOT / "script" / "new-workspace.sh"
SMOKE_RUNNER = Path(__file__).parent / "_scaffold_smoke_runner.py"

PYTHON_SH = "/isaac-sim/python.sh"

# Boot budget = warm Kit boot + camera graph + first frame, same envelope
# as the example GPU integration (#132). Boot budget 400 s; GPU CI policy
# timeout = boot budget x 1.5 = 600 s.
BOOT_BUDGET_SEC = 400
SUBPROC_TIMEOUT_SEC = int(BOOT_BUDGET_SEC * 1.5)
MAX_RETRIES = 1

# custom.yaml ros: section -> expected camera topic + frame id (the
# scaffolded example is a verbatim copy, so the values are unchanged).
EXPECTED_CAMERA_TOPIC = "/camera_bot/camera/color/image_raw"
EXPECTED_CAMERA_FRAME_ID = "camera_bot_camera_color_optical_frame"

# Where the scaffold writes the throwaway workspace. Under the mounted
# repo's test tree so the container can both write it and read example/.
SCAFFOLD_WS_PARENT = REPO_ROOT / "test" / ".scaffold-smoke"
SCAFFOLD_WS_NAME = "my-robot-ws"


requires_isaac = pytest.mark.skipif(
    not Path("/isaac-sim").is_dir(),
    reason="GPU integration: requires Isaac Sim (/isaac-sim) -- skipped on host",
)


@pytest.fixture(scope="module")
def scaffolded_ws():
    """Scaffold a throwaway consumer workspace wired to the live repo."""
    if SCAFFOLD_WS_PARENT.exists():
        shutil.rmtree(SCAFFOLD_WS_PARENT)
    SCAFFOLD_WS_PARENT.mkdir(parents=True)
    result = subprocess.run(
        [
            str(SCAFFOLD),
            SCAFFOLD_WS_NAME,
            "--local-docker",
            str(REPO_ROOT),
        ],
        cwd=str(SCAFFOLD_WS_PARENT),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, (
        f"new-workspace.sh failed (rc={result.returncode})\n"
        f"{result.stdout}\n{result.stderr}"
    )
    ws = SCAFFOLD_WS_PARENT / SCAFFOLD_WS_NAME
    yield ws
    # Best-effort cleanup (symlinked src/docker -> repo: rmtree must not
    # follow it; shutil.rmtree unlinks symlinks, does not recurse them).
    if SCAFFOLD_WS_PARENT.exists():
        shutil.rmtree(SCAFFOLD_WS_PARENT, ignore_errors=True)


def _boot_scaffolded(driver_path: Path):
    """Boot the scaffolded driver via the smoke runner; capture markers."""
    return subprocess.run(
        [PYTHON_SH, str(SMOKE_RUNNER), "--driver", str(driver_path)],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )


def _boot_succeeded(result) -> bool:
    return (
        result is not None
        and "[BOOT OK]" in result.stdout
        and "[EXIT CLEAN]" in result.stdout
        and "[RAISED]" not in result.stdout
    )


def _boot_with_retry(driver_path: Path):
    """Boot headless with retry <= 1, logging each attempt (GPU CI policy)."""
    result = None
    for attempt in range(MAX_RETRIES + 1):
        sys.stderr.write(
            f"\n[scaffold-smoke] attempt {attempt + 1}/{MAX_RETRIES + 1} "
            f"(timeout={SUBPROC_TIMEOUT_SEC}s)\n"
        )
        try:
            result = _boot_scaffolded(driver_path)
        except subprocess.TimeoutExpired:
            sys.stderr.write(
                f"[scaffold-smoke] attempt {attempt + 1} timed out\n"
            )
            result = None
            continue
        if _boot_succeeded(result):
            return result
    return result


@pytest.fixture(scope="module")
def smoke_result(scaffolded_ws):
    """Scaffold once, boot the scaffolded driver once, share the result."""
    driver = scaffolded_ws / "src" / "isaac" / "sim" / "example_driver.py"
    assert driver.is_file(), f"scaffolded driver missing: {driver}"
    result = _boot_with_retry(driver)
    if result is not None:
        sys.stderr.write(
            "\n--- scaffold-smoke stdout ---\n" + result.stdout
            + "\n--- scaffold-smoke stderr ---\n" + result.stderr + "\n"
        )
    return result


@requires_isaac
def test_scaffolded_driver_boots_clean(smoke_result):
    """The scaffolded driver boots and exits clean (L4 markers)."""
    assert smoke_result is not None, "scaffold smoke produced no result"
    assert "[BOOT OK]" in smoke_result.stdout
    assert "[EXIT CLEAN]" in smoke_result.stdout
    assert "[RAISED]" not in smoke_result.stdout


@requires_isaac
def test_scaffolded_camera_graph_built(smoke_result):
    """The scaffolded driver wires the camera OmniGraph publish chain."""
    assert smoke_result is not None
    assert "[CAMERA GRAPH OK]" in smoke_result.stdout


@requires_isaac
def test_scaffolded_camera_topic_appears(smoke_result):
    """The scaffolded example publishes the camera topic (the DoD smoke).

    A sibling rclpy probe in the runner receives >= 1 frame on the topic
    the scaffolded custom.yaml declares, with the expected frame id.
    """
    assert smoke_result is not None
    assert "[SCAFFOLD CAMERA OK]" in smoke_result.stdout, (
        "camera topic did not appear after scaffold -> boot"
    )
    assert EXPECTED_CAMERA_TOPIC in smoke_result.stdout
    assert EXPECTED_CAMERA_FRAME_ID in smoke_result.stdout
