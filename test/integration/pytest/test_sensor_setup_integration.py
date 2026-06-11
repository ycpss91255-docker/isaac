"""L3 sensor setup integration test.

Verifies ``isaac_devkit.sensors`` dispatches correctly for all four
sensor types (camera realsense, lidar_3d Ouster, lidar_2d Example_Rotary,
imu) on a minimal in-memory stage, and that the IMU mount-validation
rule rejects a non-RigidBody parent (ADR-0010 L3 + ADR-0006 IMU mount
constraint).

Scope for this PR (per #35 first L3 cut): Kit-side ``setup_sensor`` runs
without raising on positive cases and raises on the IMU negative case.
A follow-up PR will add rclpy subscribers to verify the ROS 2 messages
actually publish (sensor_msgs/Image, CameraInfo, PointCloud2, LaserScan,
Imu); that needs the bridge ext loaded + rclpy spin + timing tolerance
and is non-trivial enough to land separately.

Each test shells out to ``_sensor_setup_runner.py`` because
``SimulationApp`` is a process singleton.
"""

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_sensor_setup_runner.py"
FRAMEWORK_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 180


def _run(yaml_path: Path, body_mode: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            PYTHON_SH, str(RUNNER_SCRIPT),
            "--yaml", str(yaml_path),
            "--script-dir", str(FRAMEWORK_DIR),
            "--body-mode", body_mode,
        ],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )


def _dump(result: subprocess.CompletedProcess, label: str) -> str:
    return (
        f"\n--- {label} stdout ---\n{result.stdout}"
        f"\n--- {label} stderr ---\n{result.stderr}"
    )


# NOTE on exit codes: Kit's app.close() calls _exit(0) on the way down
# and swallows any sys.exit(N) that would otherwise propagate after it.
# Tests therefore key off stdout marker lines emitted by the runner
# ([OK] / [RAISED]) instead of the subprocess returncode. If neither
# marker shows up, the runner crashed before reaching either branch and
# the assertion message surfaces both streams for diagnosis.


def _assert_setup_ok(result: subprocess.CompletedProcess, label: str) -> None:
    assert "[OK] setup_sensor returned" in result.stdout, (
        f"{label}: runner did not print the [OK] marker (no successful "
        f"setup_sensor return). " + _dump(result, label)
    )


def _assert_setup_raised(result: subprocess.CompletedProcess, label: str, expected_substr: str) -> None:
    assert "[RAISED]" in result.stdout, (
        f"{label}: runner did not print the [RAISED] marker (setup_sensor "
        f"did not raise). " + _dump(result, label)
    )
    assert expected_substr in result.stdout, (
        f"{label}: [RAISED] marker present but message missing "
        f"{expected_substr!r}." + _dump(result, label)
    )


@pytest.fixture
def write_yaml(tmp_path):
    def _write(category: str, body: str) -> Path:
        p = tmp_path / f"{category}.yaml"
        p.write_text(body, encoding="utf-8")
        return p
    return _write


def test_imu_rejects_non_rigid_body_parent(write_yaml):
    yaml = write_yaml("imu_negative", textwrap.dedent("""\
        mount:
          parent_prim: "/World/Robot/base_link"
          pose:
            xyz: [0, 0, 0.1]
            rpy: [0, 0, 0]
        sensor:
          category: imu
          type: imu
          frequency_hz: 400
        ros:
          topic_prefix: "/imu"
          frame_id_prefix: "imu"
        """))
    result = _run(yaml, body_mode="xform")
    _assert_setup_raised(result, "imu_negative", "RigidBodyAPI")


def test_imu_setup_succeeds_on_rigid_body(write_yaml):
    yaml = write_yaml("imu_positive", textwrap.dedent("""\
        mount:
          parent_prim: "/World/Robot/base_link"
          pose:
            xyz: [0, 0, 0.1]
            rpy: [0, 0, 0]
        sensor:
          category: imu
          type: imu
          frequency_hz: 400
        ros:
          topic_prefix: "/imu"
          frame_id_prefix: "imu"
        """))
    result = _run(yaml, body_mode="rigid")
    _assert_setup_ok(result, "imu_positive")


def test_camera_realsense_setup_succeeds(write_yaml):
    # realsense reuses the bundled rsd455.usd via the camera_setup module.
    # The first run may download the asset; subsequent runs hit the
    # Isaac Sim cache. Either way setup_sensor itself should return.
    yaml = write_yaml("camera_realsense", textwrap.dedent("""\
        mount:
          parent_prim: "/World/Robot/base_link"
          pose:
            xyz: [0.2, 0.0, 0.1]
            rpy: [0.0, 0.0, 0.0]
        sensor:
          category: camera
          type: realsense
          asset_suffix: "Isaac/Sensors/Intel/RealSense/rsd455.usd"
        streams:
          color: true
          depth: true
          ir_left: false
          ir_right: false
          imu: false
        overrides:
          color: {width: 640, height: 480}
          depth: {width: 640, height: 480}
        ros:
          topic_prefix: "/camera"
          frame_id_prefix: "camera"
        """))
    result = _run(yaml, body_mode="rigid")
    _assert_setup_ok(result, "camera_realsense")


def test_lidar_3d_setup_succeeds(write_yaml):
    yaml = write_yaml("lidar_3d", textwrap.dedent("""\
        mount:
          parent_prim: "/World/Robot/base_link"
          pose:
            xyz: [0, 0, 0.5]
            rpy: [0, 0, 0]
        sensor:
          category: lidar
          type: lidar_3d
          profile: "OS1_REV7_128ch10hz1024res"
        ros:
          topic_prefix: "/lidar_3d"
          frame_id_prefix: "lidar_3d"
          publish_type: "point_cloud"
        """))
    result = _run(yaml, body_mode="rigid")
    _assert_setup_ok(result, "lidar_3d")


def test_lidar_2d_setup_succeeds(write_yaml):
    yaml = write_yaml("lidar_2d", textwrap.dedent("""\
        mount:
          parent_prim: "/World/Robot/base_link"
          pose:
            xyz: [0.2, 0, 0.1]
            rpy: [0, 0, 0]
        sensor:
          category: lidar
          type: lidar_2d
          profile: "Example_Rotary_2D"
        ros:
          topic_prefix: "/scan"
          frame_id_prefix: "base_scan"
          publish_type: "laser_scan"
        """))
    result = _run(yaml, body_mode="rigid")
    _assert_setup_ok(result, "lidar_2d")
