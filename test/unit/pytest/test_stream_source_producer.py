"""Hosted import / CLI-contract tests for the stream-source producer driver.

isaac#223 (publish a pullable, deterministic Kit stream-source producer
image to GHCR) / owv#48 (the omniverse_web_viewer visual e2e that consumes
it) / isaac#173 (the Tier B browser-frames smoke that builds on the Tier A
stream smoke).

The producer (`src/script/stream_source_producer.py`) is a mostly
declarative Kit driver: it boots `SimulationApp`, builds a deterministic
non-black checkerboard stage, frames a camera, and livestreams over WebRTC.
Its scene-build / camera-framing / stream-loop behaviour only runs on the
GPU inside the Isaac container, so it is out of scope for a hosted test.

What IS host-checkable -- and what the Dockerfile `producer` CMD and the
`docker run --network=host -e PUBLIC_IP=<ip> <image>` contract rely on --
is the import / CLI surface, which these tests pin:

  - the module imports on a non-Isaac host without pulling `omni` / `pxr` /
    `isaacsim` into `sys.modules` (every Isaac import must be
    function-local, mirroring `test_import_safety.py`);
  - the argparse surface exposes `--public-ip` / `--port` / `--run-seconds`;
  - `--public-ip` / `--port` default from the `PUBLIC_IP` /
    `ISAAC_SIGNAL_PORT` env vars (the env-driven container contract),
    falling back to `""` / `49100`; an explicit flag overrides the env;
  - `python stream_source_producer.py --help` exits 0 on a bare host
    (argparse prints usage and exits before any Isaac import), proving the
    entrypoint is import-safe end to end.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

_DRIVER = (
    Path(__file__).resolve().parents[3] / "src" / "script" /
    "stream_source_producer.py"
)

# Top-level Isaac namespaces that must never load on a hosted import.
_ISAAC_TOP_LEVEL = ("omni", "pxr", "isaacsim", "isaaclab", "carb")


def _load_module():
    """Import the driver by file path (it lives outside any package)."""
    spec = importlib.util.spec_from_file_location(
        "stream_source_producer", _DRIVER
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _leaked_isaac_modules():
    return sorted(
        name
        for name in sys.modules
        if name.partition(".")[0] in _ISAAC_TOP_LEVEL
    )


def test_driver_file_exists():
    assert _DRIVER.is_file(), f"missing producer driver at {_DRIVER}"


def test_hosted_import_leaves_sys_modules_isaac_free():
    _load_module()
    leaked = _leaked_isaac_modules()
    assert leaked == [], (
        f"hosted import of the producer leaked Isaac modules: {leaked}; "
        "every omni/pxr/isaacsim/carb import must be function-local"
    )


def test_arg_parser_exposes_expected_flags():
    module = _load_module()
    parser = module._build_arg_parser()
    dests = {action.dest for action in parser._actions}
    assert {"public_ip", "port", "run_seconds"} <= dests


def test_defaults_without_env(monkeypatch):
    monkeypatch.delenv("PUBLIC_IP", raising=False)
    monkeypatch.delenv("ISAAC_SIGNAL_PORT", raising=False)
    module = _load_module()
    args = module._build_arg_parser().parse_args([])
    assert args.public_ip == ""
    assert args.port == 49100
    assert args.run_seconds == 0.0


def test_public_ip_defaults_from_env(monkeypatch):
    monkeypatch.setenv("PUBLIC_IP", "10.1.2.3")
    module = _load_module()
    args = module._build_arg_parser().parse_args([])
    assert args.public_ip == "10.1.2.3"


def test_port_defaults_from_env(monkeypatch):
    monkeypatch.setenv("ISAAC_SIGNAL_PORT", "50555")
    module = _load_module()
    args = module._build_arg_parser().parse_args([])
    assert args.port == 50555


def test_cli_flags_override_env(monkeypatch):
    monkeypatch.setenv("PUBLIC_IP", "10.1.2.3")
    monkeypatch.setenv("ISAAC_SIGNAL_PORT", "50555")
    module = _load_module()
    args = module._build_arg_parser().parse_args(
        ["--public-ip", "9.9.9.9", "--port", "40000"]
    )
    assert args.public_ip == "9.9.9.9"
    assert args.port == 40000


def test_help_exits_zero_on_bare_host():
    result = subprocess.run(
        [sys.executable, str(_DRIVER), "--help"],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr
    for flag in ("--public-ip", "--port", "--run-seconds"):
        assert flag in result.stdout
