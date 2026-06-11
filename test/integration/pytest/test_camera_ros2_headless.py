"""Camera -> ROS 2 headless integration smoke test (issue #127, M0 gate).

First end-to-end proof that the `custom.yaml` camera path (local
UsdGeom.Camera prims, ZED-M baseline, no external assets) actually runs
inside Isaac: headless Kit boot, OmniGraph camera publish chain built by
``src/script/camera_setup.py``, and at least one ``sensor_msgs/Image``
frame observed on the ROS 2 topic with the expected ``frame_id``.

Headless only: running the ROS 2 bridge together with livestream in one
Kit process segfaults randomly (isaac-sim/IsaacSim#228); no-livestream
boot bypasses it.

Pass criterion is stdout marker lines, not the return code: Kit's
``app.close`` calls ``_exit(0)`` on the way out and swallows
``sys.exit`` (same convention as ``test_isaac_driver_integration.py``).
CUDA / Vulkan init evidence is asserted from the Kit log file announced
by the runner via ``[KIT LOG]`` (boot-time graphics/compute init lines
are logged at Info level, which does not reach stdout).

Run inside the GPU-enabled test container (requires the
``[stage:devel-test] deploy.gpu_mode = force`` setup.conf override):

    ./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
        <repo>/test/integration/pytest/test_camera_ros2_headless.py -s
"""

import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest  # noqa: F401  (kept for fixture style consistency)

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_camera_headless_runner.py"
SRC_DIR = REPO_ROOT / "src"
SCRIPT_DIR = SRC_DIR / "script"
CAMERA_YAML = SRC_DIR / "config" / "camera" / "custom.yaml"
PYTHON_SH = "/isaac-sim/python.sh"

# Kit boot + camera graph + first frame. Warm shader cache boots in
# ~60-120 s on the reference GPU runner (RTX 5090); a cold cache can
# take several minutes, hence the generous ceiling.
SUBPROC_TIMEOUT_SEC = 900

# custom.yaml ros: section -> expected topic + frame id (ADR-0006).
EXPECTED_TOPIC = "/forklift/camera/color/image_raw"
EXPECTED_FRAME_ID = "forklift_camera_color_optical_frame"


def _write_stub_usd(tmp_path: Path) -> Path:
    """Smallest stage carrying custom.yaml's mount parent prim.

    custom.yaml mounts the camera under ``/World/Forklift/carriage``;
    the smoke scope is the camera->ROS2 chain, not the forklift model,
    so a bare Xform chain stands in for the robot.
    """
    p = tmp_path / "camera_smoke_stub.usda"
    p.write_text(
        textwrap.dedent("""\
            #usda 1.0
            (
                upAxis = "Z"
                metersPerUnit = 1.0
            )

            def Xform "World"
            {
                def Xform "Forklift"
                {
                    def Xform "carriage"
                    {
                    }
                }
            }
            """),
        encoding="utf-8",
    )
    return p


def _dump_output(result):
    sys.stderr.write(
        "\n--- camera_headless stdout ---\n" + result.stdout
        + "\n--- camera_headless stderr ---\n" + result.stderr
    )


def test_camera_custom_yaml_publishes_frame_headless(tmp_path):
    stub_usd = _write_stub_usd(tmp_path)

    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER_SCRIPT),
            "--script-dir", str(SCRIPT_DIR),
            "--camera-yaml", str(CAMERA_YAML),
            "--usd-path", str(stub_usd),
        ],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )

    ok = all(
        marker in result.stdout
        for marker in ("[BOOT OK]", "[CAMERA FRAME OK]", "[EXIT CLEAN]")
    )
    if not ok or "[RAISED]" in result.stdout:
        _dump_output(result)

    # 1. Headless Isaac actually boots.
    assert "[BOOT OK]" in result.stdout, "Kit never reached the boot marker."

    # CUDA functional check (libcuda cuInit + device count, printed by
    # the runner from inside the booted Kit process).
    cuda = re.search(r"\[CUDA OK\] devices=(\d+)", result.stdout)
    assert cuda, "CUDA init marker missing."
    assert int(cuda.group(1)) >= 1, "CUDA reported zero devices."

    # CUDA/Vulkan init markers in the Kit log (Info-level boot lines).
    kit_log = re.search(r"\[KIT LOG\] path=(\S+)", result.stdout)
    assert kit_log, "Runner did not announce the Kit log path."
    log_text = Path(kit_log.group(1)).read_text(
        encoding="utf-8", errors="replace"
    )
    assert "vulkan" in log_text.lower(), "No Vulkan init marker in Kit log."
    assert "cuda" in log_text.lower(), "No CUDA init marker in Kit log."

    # 2. Camera graph built via the custom.yaml path.
    assert "[CAMERA GRAPH OK]" in result.stdout, (
        "setup_camera() did not build the OmniGraph publish chain."
    )

    # 3. >= 1 frame on the ROS 2 topic, frame_id as configured.
    frame = re.search(
        r"\[CAMERA FRAME OK\] topic=(\S+) frame_id=(\S+) "
        r"width=(\d+) height=(\d+) count=(\d+)",
        result.stdout,
    )
    assert frame, (
        "No camera frame observed on the ROS 2 topic within budget."
    )
    assert frame.group(1) == EXPECTED_TOPIC
    assert frame.group(2) == EXPECTED_FRAME_ID, (
        f"frame_id mismatch: got {frame.group(2)!r}, "
        f"expected {EXPECTED_FRAME_ID!r}"
    )
    assert int(frame.group(5)) >= 1

    # 4. Lifecycle completed without raising.
    assert "[EXIT CLEAN]" in result.stdout, "Runner did not exit cleanly."
    assert "[RAISED]" not in result.stdout, (
        "Runner raised inside the lifecycle. " + result.stdout[-1000:]
    )
