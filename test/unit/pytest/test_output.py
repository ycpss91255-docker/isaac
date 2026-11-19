"""setup_output single entry, python mode (isaac#365 / #366)."""

import sys
from pathlib import Path

import pytest

_FRAMEWORK_DIR = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK_DIR))

from isaac_devkit import output  # noqa: E402
from isaac_devkit.exceptions import IsaacDevkitError, OutputModeError  # noqa: E402
from isaac_devkit.output import (  # noqa: E402
    CameraOutput,
    ImuOutput,
    JointOutput,
    setup_output,
)


def test_output_mode_error_is_a_devkit_error():
    assert issubclass(OutputModeError, IsaacDevkitError)


def test_spec_defaults():
    cam = CameraOutput("cam", "/World/Cam", 640, 480)
    assert cam.depth is False
    assert JointOutput("/World/Robot").prim == "/World/Robot"
    assert ImuOutput("imu", "/World/Robot/imu").name == "imu"


def test_python_mode_builds_python_sources(monkeypatch):
    seen = {}

    def fake_sources(cameras, joint, imu):
        seen.update(cameras=cameras, joint=joint, imu=imu)
        return []

    monkeypatch.setattr(output, "make_python_sources", fake_sources)
    cam = CameraOutput("cam", "/World/Cam", 640, 480)
    out = setup_output({"ISAAC_OUTPUT_MODE": "python"}, cameras=[cam])
    assert out.mode == "python"
    assert seen == {"cameras": (cam,), "joint": None, "imu": None}


def test_unset_defaults_to_python(monkeypatch):
    monkeypatch.setattr(output, "make_python_sources", lambda *a: [])
    assert setup_output({}).mode == "python"


def test_invalid_mode_raises_value_error():
    with pytest.raises(ValueError, match="both"):
        setup_output({"ISAAC_OUTPUT_MODE": "both"})


def test_step_emits_to_registered_consumers(monkeypatch):
    monkeypatch.setattr(
        output, "make_python_sources",
        lambda *a: [("js", "joint_state", lambda: {
            "names": ["a"], "positions": [0.0],
            "velocities": [0.0], "efforts": [0.0]})],
    )
    out = setup_output({})
    got = []
    out.register(got.append, kinds=["joint_state"])
    out.step(3.0)
    assert [(f.kind, f.stamp) for f in got] == [("joint_state", 3.0)]


def test_unregister_stops_delivery(monkeypatch):
    calls = []
    monkeypatch.setattr(
        output, "make_python_sources",
        lambda *a: [("js", "joint_state",
                     lambda: calls.append(1) or {
                         "names": [], "positions": [],
                         "velocities": [], "efforts": []})],
    )
    out = setup_output({})
    cb = lambda frame: None  # noqa: E731
    out.register(cb)
    out.step(0.0)
    out.unregister(cb)
    out.step(1.0)
    assert calls == [1]


def test_ros_mode_is_not_available_yet():
    with pytest.raises(NotImplementedError, match="ros"):
        setup_output({"ISAAC_OUTPUT_MODE": "ros"})
