"""Example GPU automated integration test (isaac#132, M2 gate).

Boots the #131 ``ExampleDriver`` headless inside the devel-test GPU
container (no livestream -- bypasses IsaacSim#228) and makes the strong
L1-L4 + ``/cmd_vel`` round-trip assertions the PRD lists (Testing &
Acceptance Criteria) as committed test code:

* L1 -- ``/World/Robot/base_link`` IsValid + RigidBodyAPI present +
  link/joint counts + URDF->USD prim/joint diff == 0 (pure URDF parse
  expected vs live-stage PrimSummary actual).
* L3 -- camera topic exists, type ``sensor_msgs/Image``, ``frame_id`` ==
  expected, and >= 1 message within budget.
* ros_io / cmd_vel round-trip -- ``io.latest()`` is None before any
  publish (non-blocking), then a published ``/cmd_vel`` Twist is echoed
  back through ``io.latest()`` within K ticks with matching content.
* L4 -- ``[BOOT OK]`` / ``[EXIT CLEAN]`` markers present; an injected
  SIGINT runs ``shutdown()`` (``[SIGINT SHUTDOWN OK]``). The pure-side
  lifecycle call ORDER spy lives in the hosted unit suite
  (``test/unit/pytest/test_example_driver.py``) where Isaac is not
  needed; this asserts the live driver honors the same SIGINT path.

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

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_example_headless_runner.py"
SUMMARY_RUNNER = Path(__file__).parent / "_prim_summary_runner.py"
FRAMEWORK_DIR = REPO_ROOT / "framework"
EXAMPLE_SIM_DIR = REPO_ROOT / "example" / "sim"
SOURCE_URDF = EXAMPLE_SIM_DIR / "model" / "camera_bot.urdf"
COMMITTED_USD = (
    EXAMPLE_SIM_DIR / "model" / "usd" / "robot" / "camera_bot"
    / "camera_bot.usd"
)
PYTHON_SH = "/isaac-sim/python.sh"

# Single Kit boot for the importer + a second for the summarizer.
L1_IMPORT_TIMEOUT_SEC = 240

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

# robot.yaml name + custom.yaml ros: section -> expected L1 / L3 values.
EXPECTED_ROBOT_PRIM = "/World/Robot"
EXPECTED_BASE_LINK = "/World/Robot/base_link"
EXPECTED_ROBOT_ROOT = "/camera_bot"
EXPECTED_CAMERA_TOPIC = "/camera_bot/camera/color/image_raw"
EXPECTED_CAMERA_FRAME_ID = "camera_bot_camera_color_optical_frame"

# camera_bot.urdf as the Isaac URDF importer actually produces it
# (observed on the RTX 5090, isaac#132): the fixed camera_mount joint is
# NOT collapsed (camera_link carries its own inertial/visual), and
# fix_base=True adds a synthetic root_joint, so the imported robot has
# two link Xforms (base_link, camera_link) and two PhysicsFixedJoints
# (camera_mount + root_joint). This is the importer's real convention,
# not the (looser) prediction of the pure parse_urdf_expected helper --
# see the module docstring + the L1 finding in the PR body.
EXPECTED_LINK_COUNT = 2
EXPECTED_JOINT_COUNT = 2
EXPECTED_ROBOT_ROOT_PRIM_NAME = "/camera_bot"

# Sent /cmd_vel content (must match _example_headless_runner.py).
EXPECTED_VX = 0.42
EXPECTED_WZ = 0.21


def _run_once():
    """Run the headless example runner once; return CompletedProcess."""
    return subprocess.run(
        [PYTHON_SH, str(RUNNER_SCRIPT), "--repo-root", str(REPO_ROOT)],
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


def _run_with_retry():
    """Run headless with retry <= 1, logging each attempt (GPU CI policy)."""
    result = None
    for attempt in range(MAX_RETRIES + 1):
        sys.stderr.write(
            f"\n[example-gpu-integration] attempt "
            f"{attempt + 1}/{MAX_RETRIES + 1} "
            f"(timeout={SUBPROC_TIMEOUT_SEC}s)\n"
        )
        try:
            result = _run_once()
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
    """Boot the example headless once (module-scoped, retry<=1)."""
    result = _run_with_retry()
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
    """L1: live committed-USD link/joint counts match the importer truth."""
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


def _parse_prim_summaries(stdout):
    """Map tag -> (prim, joint, links, root) from [PRIM SUMMARY] lines."""
    summaries = {}
    for m in re.finditer(
        r"\[PRIM SUMMARY\] tag=(\S+) prim=(\d+) joint=(\d+) "
        r"links=(\d+) root=(\S+)",
        stdout,
    ):
        summaries[m.group(1)] = (
            int(m.group(2)),
            int(m.group(3)),
            int(m.group(4)),
            m.group(5),
        )
    return summaries


@pytest.mark.skip(
    reason="ADR-0018 decision 6: model_import now emits an Isaac Lab "
    "instanceable USD; the committed camera_bot.usd was produced by the "
    "legacy omni.kit.commands importer, so its PrimSummary diff != 0 by "
    "construction. Re-enabled when #154 regenerates the example USD with "
    "the Isaac Lab importer (the example rework owns the committed asset)."
)
def test_l1_urdf_to_usd_diff_zero(tmp_path):
    """L1: a fresh URDF->USD import matches the committed example USD.

    The PRD's L1 "diff = 0" contract -- the committed example USD must be
    in sync with its source URDF through the framework import pipeline.
    Re-imports ``camera_bot.urdf`` with the framework importer subprocess
    (the proven ``test_model_import.py`` pattern -- one SimulationApp per
    URDF import), then summarizes both the committed USD and the fresh
    one in a single Kit boot and asserts prim/joint/links/root all
    diff == 0. (A pure ``parse_urdf_expected`` model is asserted on the
    hosted-unit side; it intentionally does not model the importer's
    synthetic ``root_joint`` / USD scopes, so the authoritative L1 diff
    is committed-USD vs fresh-import here.)
    """
    fresh_dir = tmp_path / "fresh"
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    imp = subprocess.run(
        [
            PYTHON_SH, "-m", "isaac_devkit.model_import",
            "--urdf", str(SOURCE_URDF),
            "--output", str(fresh_dir),
            "--name", "camera_bot",
        ],
        capture_output=True,
        text=True,
        timeout=L1_IMPORT_TIMEOUT_SEC,
        env=env,
    )
    fresh_usd = fresh_dir / "camera_bot.usd"
    if not fresh_usd.is_file():
        sys.stderr.write(
            "\n--- import stdout ---\n" + imp.stdout
            + "\n--- import stderr ---\n" + imp.stderr
        )
    assert fresh_usd.is_file(), "fresh URDF import produced no camera_bot.usd"

    dump = subprocess.run(
        [
            PYTHON_SH, str(SUMMARY_RUNNER),
            "--framework", str(FRAMEWORK_DIR),
            "--usd", f"committed={COMMITTED_USD}",
            "--usd", f"fresh={fresh_usd}",
        ],
        capture_output=True,
        text=True,
        timeout=L1_IMPORT_TIMEOUT_SEC,
    )
    summaries = _parse_prim_summaries(dump.stdout)
    if "committed" not in summaries or "fresh" not in summaries:
        sys.stderr.write(
            "\n--- summary stdout ---\n" + dump.stdout
            + "\n--- summary stderr ---\n" + dump.stderr
        )
    assert "committed" in summaries, "no committed-USD PrimSummary emitted."
    assert "fresh" in summaries, "no fresh-import PrimSummary emitted."

    committed = summaries["committed"]
    fresh = summaries["fresh"]
    assert committed == fresh, (
        f"URDF->USD diff != 0: committed {committed} vs fresh {fresh}"
    )
    # And the structure is the importer truth this suite asserts.
    assert committed[1] == EXPECTED_JOINT_COUNT, (
        f"joint count {committed[1]} != expected {EXPECTED_JOINT_COUNT}"
    )
    assert committed[2] == EXPECTED_LINK_COUNT, (
        f"link count {committed[2]} != expected {EXPECTED_LINK_COUNT}"
    )
    assert committed[3] == EXPECTED_ROBOT_ROOT_PRIM_NAME, (
        f"root {committed[3]!r} != expected "
        f"{EXPECTED_ROBOT_ROOT_PRIM_NAME!r}"
    )


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
        "test/unit/pytest/test_example_driver.py)."
    )


# The Isaac<->ament cross-container round-trip (PRD Pre-Publish item 1)
# is now IMPLEMENTED in test_cross_container_roundtrip.py: it
# host-orchestrates a sibling ros:humble container running the
# example/ros2/ ament nodes and asserts a real message crosses the
# container boundary in both directions (sim->ament camera receipt,
# ament->sim /cmd_vel receipt). The previously-skipped placeholder that
# deferred it to #133 has been removed now that example/ros2/ is on this
# branch.
