"""Example GPU automated integration test (isaac#132, M2 gate; #325).

Boots a headless Isaac scene inside the devel-test GPU container (no
livestream -- bypasses IsaacSim#228) and makes the strong L1-L4 +
``/cmd_vel`` round-trip assertions the PRD lists (Testing & Acceptance
Criteria) as committed test code.

Scene source (#325): the official NVIDIA Jetbot USD fetched through the
``test/test_assets.py`` helper (#341), NOT the bundled ``example/sim/``
camera_bot, which is being removed. The assertions keep their meaning;
only the scene (and so the expected prim paths / counts / topic) changed:

* L1 -- ``/World/Robot/chassis`` IsValid + RigidBodyAPI present +
  link/joint counts (3 links / 2 joints / root ``/jetbot``) on the live
  Jetbot robot subtree, spawned through the framework Isaac Lab adapter
  (#154). The former URDF->USD diff==0 leg is RETIRED
  (#154): the committed asset is a curated legacy-importer USD, so a fresh
  re-import diff is non-zero by construction; the "fresh import is
  structurally correct" contract lives in ``test_model_import.py`` (#150).
* L3 -- camera topic exists, type ``sensor_msgs/Image``, ``frame_id`` ==
  expected, and >= 1 message within budget.
* ros_io / cmd_vel round-trip -- ``io.latest()`` is None before any
  publish (non-blocking), then a published ``/cmd_vel`` Twist is echoed
  back through ``io.latest()`` within K ticks with matching content.
* L4 -- ``[BOOT OK]`` / ``[EXIT CLEAN]`` markers present; an injected
  SIGINT runs ``shutdown()`` (``[SIGINT SHUTDOWN OK]``). The pure-side
  lifecycle call ORDER spy lives in the hosted unit suite where Isaac
  is not needed; this asserts the live runner honors the same SIGINT
  path.

The in-process ``/cmd_vel`` round-trip here publishes the Twist from an
in-process rclpy node (no second container) to verify the OmniGraph
Subscribe attribute path. The genuine Isaac<->ament cross-container
round-trip (PRD Pre-Publish item 1 -- a real message crossing the
container boundary in both directions) lives in
``test_cross_container_roundtrip.py``, host-orchestrated against a
sibling ``ros:humble`` container running the ``example/ros2/`` ament
nodes.

Pass criterion is stdout marker lines, not the return code: Kit's
``app.close`` calls ``_exit(0)`` and swallows ``sys.exit`` (same
convention as ``test_camera_ros2_headless.py``).

GPU CI policy (PRD Testing & Acceptance): headless; timeout = boot budget
x 1.5; retry <= 1, logged. A skipped GPU job does NOT count as green.

Run inside the GPU-enabled test container (requires the
``[stage:devel-test] deploy.gpu_mode = force`` setup.conf override)::

    ./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
        <repo>/test/integration/pytest/test_example_gpu_integration.py -s
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest

# ``test/`` hosts the shared asset helper (#341); make it importable.
_TEST_DIR = Path(__file__).resolve().parents[2]
if str(_TEST_DIR) not in sys.path:
    sys.path.insert(0, str(_TEST_DIR))

from test_assets import fetch_test_asset  # noqa: E402

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_example_headless_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"

# Boot budget = warm Kit boot + camera graph + first frame + cmd_vel
# round-trip. On the reference GPU runner (RTX 5090) a warm shader cache
# boots the camera path in ~60-120 s; the example adds the robot
# reference + cmd_vel graph. Boot budget 400 s; GPU CI policy timeout =
# boot budget x 1.5 = 600 s. A cold cache can take longer, but retry
# (below) re-runs once with a warmed cache.
BOOT_BUDGET_SEC = 400
SUBPROC_TIMEOUT_SEC = int(BOOT_BUDGET_SEC * 1.5)

# GPU CI policy: retry at most once, logged.
MAX_RETRIES = 1

# Scene dict in the runner + camera ``ros:`` section -> expected L1 / L3
# values. The Jetbot chassis is its articulation body (no ``base_link``).
EXPECTED_BASE_LINK = "/World/Robot/chassis"
EXPECTED_CAMERA_TOPIC = "/jetbot/camera/color/image_raw"
EXPECTED_CAMERA_FRAME_ID = "jetbot_camera_color_optical_frame"

# Jetbot USD structure (pxr inspection of the pinned asset, defaultPrim
# /jetbot): three rigid-body Xform links directly under the root (chassis,
# left_wheel, right_wheel) and two PhysicsRevoluteJoints (the wheel
# joints). Counted by the same ``_summarize_prim_records`` rule the L1
# runner uses (Xform children of the root / types containing "Joint").
EXPECTED_LINK_COUNT = 3
EXPECTED_JOINT_COUNT = 2
EXPECTED_ROBOT_ROOT_PRIM_NAME = "/jetbot"

# Sent /cmd_vel content (must match _example_headless_runner.py).
EXPECTED_VX = 0.42
EXPECTED_WZ = 0.21


def _run_once(robot_usd):
    """Run the headless example runner once; return CompletedProcess."""
    return subprocess.run(
        [
            PYTHON_SH,
            str(RUNNER_SCRIPT),
            "--repo-root",
            str(REPO_ROOT),
            "--robot-usd",
            str(robot_usd),
        ],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )


def _boot_succeeded(result) -> bool:
    """Did the runner reach a clean lifecycle exit without raising?"""
    return (
        result is not None
        and "[BOOT OK]" in result.stdout
        and "[EXIT CLEAN]" in result.stdout
        and "[RAISED]" not in result.stdout
    )


def _run_with_retry(robot_usd):
    """Run headless with retry <= 1, logging each attempt (GPU CI policy)."""
    result = None
    for attempt in range(MAX_RETRIES + 1):
        sys.stderr.write(
            f"\n[example-gpu-integration] attempt "
            f"{attempt + 1}/{MAX_RETRIES + 1} "
            f"(timeout={SUBPROC_TIMEOUT_SEC}s)\n"
        )
        try:
            result = _run_once(robot_usd)
        except subprocess.TimeoutExpired:
            sys.stderr.write(
                f"[example-gpu-integration] attempt {attempt + 1} timed out "
                f"after {SUBPROC_TIMEOUT_SEC}s\n"
            )
            result = None
            continue
        if _boot_succeeded(result):
            sys.stderr.write(
                f"[example-gpu-integration] attempt {attempt + 1} booted "
                f"clean\n"
            )
            return result
        sys.stderr.write(
            f"[example-gpu-integration] attempt {attempt + 1} did not boot "
            f"clean; retrying if budget remains\n"
        )
    return result


def _dump(result) -> None:
    if result is None:
        sys.stderr.write(
            "\n--- example_gpu stdout --- (no result: timed out)\n"
        )
        return
    sys.stderr.write(
        "\n--- example_gpu stdout ---\n" + result.stdout
        + "\n--- example_gpu stderr ---\n" + result.stderr
    )


@pytest.fixture(scope="module")
def example_run():
    """Boot the Jetbot scene headless once (module-scoped, retry<=1)."""
    robot_usd = fetch_test_asset("jetbot")
    result = _run_with_retry(robot_usd)
    if not _boot_succeeded(result):
        _dump(result)
        pytest.fail(
            "example headless runner did not boot clean within the GPU CI "
            "budget (timeout / retry exhausted)."
        )
    return result


def test_l4_boot_and_clean_exit_markers(example_run):
    """L4: [BOOT OK] + [EXIT CLEAN] present, nothing raised."""
    out = example_run.stdout
    assert "[BOOT OK]" in out, "Kit never reached the boot marker."
    assert "[EXIT CLEAN]" in out, "Runner did not exit cleanly."
    assert "[RAISED]" not in out, (
        "Runner raised inside the lifecycle. " + out[-1000:]
    )


def test_cuda_and_vulkan_init(example_run):
    """GPU actually initialized: libcuda device count + Kit log markers."""
    out = example_run.stdout
    cuda = re.search(r"\[CUDA OK\] devices=(\d+)", out)
    assert cuda, "CUDA init marker missing."
    assert int(cuda.group(1)) >= 1, "CUDA reported zero devices."

    kit_log = re.search(r"\[KIT LOG\] path=(.+)", out)
    assert kit_log, "Runner did not announce the Kit log path."
    log_text = Path(kit_log.group(1).strip()).read_text(
        encoding="utf-8", errors="replace"
    )
    assert "vulkan" in log_text.lower(), "No Vulkan init marker in Kit log."
    assert "cuda" in log_text.lower(), "No CUDA init marker in Kit log."


def test_l1_base_link_valid_and_rigidbody(example_run):
    """L1: base_link IsValid + RigidBodyAPI present at the expected path."""
    out = example_run.stdout
    m = re.search(
        r"\[L1 BASE_LINK OK\] path=(\S+) valid=(\S+) rigidbody=(\S+)", out
    )
    assert m, "L1 base_link marker missing."
    assert m.group(1) == EXPECTED_BASE_LINK, (
        f"base_link path mismatch: got {m.group(1)!r}, "
        f"expected {EXPECTED_BASE_LINK!r}"
    )
    assert m.group(2) == "True", "base_link is not IsValid on the live stage."
    assert m.group(3) == "True", "base_link is missing RigidBodyAPI."


def test_l1_link_and_joint_counts(example_run):
    """L1: live Jetbot link/joint counts match the asset's structure."""
    out = example_run.stdout
    m = re.search(
        r"\[L1 COUNTS OK\] links=(\d+) joints=(\d+) root=(\S+)", out
    )
    assert m, "L1 counts marker missing."
    assert int(m.group(1)) == EXPECTED_LINK_COUNT, (
        f"link count mismatch: got {m.group(1)}, expected "
        f"{EXPECTED_LINK_COUNT}"
    )
    assert int(m.group(2)) == EXPECTED_JOINT_COUNT, (
        f"joint count mismatch: got {m.group(2)}, expected "
        f"{EXPECTED_JOINT_COUNT}"
    )
    assert m.group(3) == EXPECTED_ROBOT_ROOT_PRIM_NAME, (
        f"robot root mismatch: got {m.group(3)!r}, "
        f"expected {EXPECTED_ROBOT_ROOT_PRIM_NAME!r}"
    )


# test_l1_urdf_to_usd_diff_zero RETIRED (#154, ADR-0018 decision 6).
#
# It re-imported camera_bot.urdf and asserted a byte/structure diff == 0
# against the COMMITTED camera_bot.usd (since replaced by the official
# Jetbot asset, #325). The committed USD is a curated
# legacy-importer asset (a defaultPrim was added in fb6f580 so the
# UsdFileCfg reference resolves, but the asset was NOT regenerated by the
# new Isaac Lab instanceable importer), so a fresh-import vs committed
# diff is non-zero BY CONSTRUCTION and regenerating the committed asset is
# an out-of-band GPU step the example rework deliberately does not take.
#
# The "a fresh import is structurally correct" contract is already covered
# by test_model_import.py (the openbase single-USD import, #150). The L1
# structure of the live committed USD is still asserted here by
# test_l1_link_and_joint_counts (3 links / 2 joints / root /jetbot) and
# test_l1_base_link_valid_and_rigidbody. The collected GPU baseline drops
# by 1 (the retired test) -- a documented ratchet exception, recorded in
# test/pytest-baseline.txt and the PR body.


def test_l3_camera_topic_frame_and_message(example_run):
    """L3: camera topic + frame_id == expected + >= 1 sensor_msgs/Image."""
    out = example_run.stdout
    assert "[CAMERA GRAPH OK]" in out, (
        "setup_camera() did not build the OmniGraph publish chain."
    )
    m = re.search(
        r"\[L3 CAMERA OK\] topic=(\S+) frame_id=(\S+) "
        r"width=(\d+) height=(\d+) count=(\d+)",
        out,
    )
    assert m, "No camera frame observed on the ROS 2 topic within budget."
    assert m.group(1) == EXPECTED_CAMERA_TOPIC, (
        f"topic mismatch: got {m.group(1)!r}, "
        f"expected {EXPECTED_CAMERA_TOPIC!r}"
    )
    assert m.group(2) == EXPECTED_CAMERA_FRAME_ID, (
        f"frame_id mismatch: got {m.group(2)!r}, "
        f"expected {EXPECTED_CAMERA_FRAME_ID!r}"
    )
    assert int(m.group(5)) >= 1, "Zero camera frames received."


def test_ros_io_latest_none_before_publish(example_run):
    """ros_io: latest() returns None (non-blocking) before any publish."""
    out = example_run.stdout
    assert "[ROS_IO NONE FAIL]" not in out, (
        "io.latest() returned a message before any /cmd_vel was published."
    )
    assert "[ROS_IO NONE OK]" in out, (
        "ros_io non-blocking None marker missing."
    )


def test_cmd_vel_round_trip(example_run):
    """cmd_vel: published Twist echoes back through io.latest() in budget."""
    out = example_run.stdout
    assert "[CMD_VEL ROUNDTRIP MISSING]" not in out, (
        "Published /cmd_vel never echoed back through io.latest() within "
        "the tick budget."
    )
    m = re.search(
        r"\[CMD_VEL ROUNDTRIP OK\] seq=(\d+) vx=(\S+) vy=(\S+) wz=(\S+)",
        out,
    )
    assert m, "cmd_vel round-trip marker missing."
    assert int(m.group(1)) >= 1, (
        "round-trip freshness counter did not advance."
    )
    assert float(m.group(2)) == pytest.approx(EXPECTED_VX, abs=1e-3), (
        f"vx mismatch: got {m.group(2)}, expected {EXPECTED_VX}"
    )
    assert float(m.group(4)) == pytest.approx(EXPECTED_WZ, abs=1e-3), (
        f"wz mismatch: got {m.group(4)}, expected {EXPECTED_WZ}"
    )


def test_l4_injected_sigint_runs_shutdown(example_run):
    """L4: an injected SIGINT still runs shutdown() in the live driver."""
    out = example_run.stdout
    assert "[SIGINT SHUTDOWN OK]" in out, (
        "Injected SIGINT did not reach shutdown() (the live-driver leg of "
        "the lifecycle-order assertion; the pure-side ORDER spy is in "
        "hosted unit suite)."
    )


# The Isaac<->ament cross-container round-trip (PRD Pre-Publish item 1)
# is now IMPLEMENTED in test_cross_container_roundtrip.py: it
# host-orchestrates a sibling ros:humble container running the
# example/ros2/ ament nodes and asserts a real message crosses the
# container boundary in both directions (sim->ament camera receipt,
# ament->sim /cmd_vel receipt). The previously-skipped placeholder that
# deferred it to #133 has been removed now that example/ros2/ is on this
# branch.
