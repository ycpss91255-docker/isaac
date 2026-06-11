"""Hosted structure-check for the M5 onboarding agent-proxy gate (isaac#135).

The onboarding metric (M5, PRD Testing & Acceptance) is: a fresh agent or
newcomer given ONLY ``example/`` + its README can scaffold -> run -> swap a
URDF -> swap an in-scope sensor WITHOUT reading framework source. The
gate's mechanical, repeatable precondition is that ``example/`` + the
example README are self-sufficient for those three tasks. This file is the
hosted (no Isaac, no GPU, no network) pytest mirror of the structure half
of ``test/onboarding/agent_proxy_gate.sh``: it asserts the same
preconditions and that the harness's ``--audit`` mode actually fails when a
proxy tool-call log references framework source.

The proxy RUN itself (spawn a fresh sub-agent, audit its tool calls) is the
gate runbook (``doc/onboarding/agent-proxy-gate.md``); it is not a hosted
test because it needs an agent harness. The pre-1.0.0 human dry-run is the
final backstop and stays OPEN until a human runs it before v1.0.0.
"""

import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
EXAMPLE = REPO_ROOT / "example"
README_EN = EXAMPLE / "README.md"
GATE = REPO_ROOT / "test" / "onboarding" / "agent_proxy_gate.sh"


# ---------------------------------------------------------------------------
# (a) the onboarding README exists in all four languages, next to example/.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    "lang", ["md", "zh-TW.md", "zh-CN.md", "ja.md"]
)
def test_example_readme_four_lang_present(lang):
    """The example walkthrough README exists in every language."""
    assert (EXAMPLE / f"README.{lang}").is_file(), (
        f"missing onboarding README: example/README.{lang}"
    )


# ---------------------------------------------------------------------------
# (b) the README documents the three onboarding tasks.
# ---------------------------------------------------------------------------

def test_readme_documents_first_topic_path():
    """The README documents the scaffold -> run -> first camera topic path."""
    body = README_EN.read_text().lower()
    assert "new-workspace" in body or "just run" in body
    assert "camera topic" in body or "first topic" in body


def test_readme_documents_urdf_swap():
    """The README documents the URDF swap task."""
    assert "urdf" in README_EN.read_text().lower()


def test_readme_documents_in_scope_sensor_swap():
    """The README documents an in-scope sensor swap (res/fps/topic/2nd cam)."""
    body = README_EN.read_text().lower()
    assert any(
        token in body
        for token in ("resolution", "fps", "second camera", "topic override")
    )


# ---------------------------------------------------------------------------
# (c) the lidar/imu NotImplementedError out-of-scope callout is present.
# ---------------------------------------------------------------------------

def test_readme_calls_out_lidar_imu_not_implemented_boundary():
    """The lidar/imu NotImplementedError edge is an explicit callout."""
    body = README_EN.read_text()
    lowered = body.lower()
    assert "NotImplementedError" in body, "boundary must name NotImplementedError"
    assert "lidar" in lowered and "imu" in lowered
    assert any(
        marker in lowered
        for marker in (
            "out of scope",
            "out-of-scope",
            "not yet implemented",
            "not implemented",
        )
    )


# ---------------------------------------------------------------------------
# (d) the swap surfaces the proxy edits exist.
# ---------------------------------------------------------------------------

def test_urdf_swap_surface_present():
    """The camera_bot URDF (the URDF-swap surface) is in example/sim."""
    assert (EXAMPLE / "sim" / "model" / "camera_bot.urdf").is_file()


def test_sensor_swap_surface_present():
    """The per-sensor custom.yaml (the sensor-swap surface) is present."""
    assert (EXAMPLE / "sim" / "config" / "sensor" / "custom.yaml").is_file()


# ---------------------------------------------------------------------------
# The harness itself: structure precondition passes, audit catches a leak.
# ---------------------------------------------------------------------------

def test_harness_structure_precondition_passes():
    """agent_proxy_gate.sh (default mode) passes on the real example tree."""
    result = subprocess.run(
        [str(GATE)], capture_output=True, text=True, cwd=str(REPO_ROOT)
    )
    assert result.returncode == 0, (
        f"structure gate failed\n--- stdout ---\n{result.stdout}\n"
        f"--- stderr ---\n{result.stderr}"
    )
    assert "STRUCTURE PASS" in result.stdout


def test_harness_audit_fails_on_framework_read(tmp_path):
    """--audit FAILS when a proxy log references framework/isaac_devkit/*."""
    log = tmp_path / "proxy.log"
    log.write_text(
        "Read example/sim/example_driver.py\n"
        "Read framework/isaac_devkit/sensors.py\n"
    )
    result = subprocess.run(
        [str(GATE), "--audit", str(log)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode != 0
    assert "framework source referenced" in result.stderr


def test_harness_audit_passes_on_clean_log(tmp_path):
    """--audit PASSES when a proxy log never touches framework source."""
    log = tmp_path / "proxy.log"
    log.write_text(
        "Read example/README.md\n"
        "Read example/sim/model/camera_bot.urdf\n"
        "Edit example/sim/config/sensor/custom.yaml\n"
    )
    result = subprocess.run(
        [str(GATE), "--audit", str(log)],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    assert result.returncode == 0, result.stderr
    assert "AUDIT PASS" in result.stdout
