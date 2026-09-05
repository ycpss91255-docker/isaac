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

_REPO_ROOT = Path(__file__).resolve().parents[3]
_DRIVER = _REPO_ROOT / "src" / "script" / "stream_source_producer.py"

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


# ---------------------------------------------------------------------------
# Isaac Sim 6.0 livestream contract (isaac#252).
#
# On 5.1.0 the WebRTC server came up from `omni.kit.livestream.webrtc` alone,
# configured through `--/app/livestream/*`. On 6.0.1 neither half is true:
# the stream is created by `omni.kit.livestream.app` -- an extension this
# repo's experience did not depend on -- and only when its `streamType`
# setting is defined. The old settings are not rejected, they are ignored, so
# `:0.0.2` booted, printed its scene-ready marker, reported healthy for three
# minutes, and never bound a port. Nothing in the log said so.
#
# Measured on an RTX 5090 against the published `:0.0.2`:
#   5.x flags only ............................. no port bound
#   + 6.0 setting paths ........................ no port bound
#   + 6.0 paths and LIVESTREAM=2 ............... no port bound
#   + --enable omni.kit.livestream.app ......... bound in ~35 s, real picture
#
# So the argument list is pinned here: a settings-only regression would pass a
# test that only checked settings.

def test_kit_args_target_the_6_0_livestream_namespace():
    module = _load_module()
    args = module._kit_args(port=49399, public_ip="10.1.2.3", media_port=47998)

    joined = " ".join(args)
    assert "--/exts/omni.kit.livestream.app/primaryStream/signalPort=49399" in args
    assert "--/exts/omni.kit.livestream.app/primaryStream/streamPort=47998" in args
    assert "--/exts/omni.kit.livestream.app/primaryStream/publicIp=10.1.2.3" in args
    # The setting that makes the extension create a stream at all.
    assert "--/exts/omni.kit.livestream.app/primaryStream/streamType=webrtc" in args
    assert "/app/livestream/port" not in joined, "5.x path is ignored by 6.0"
    # NOT --enable. Settings alone do not start the stream, but the missing
    # piece is a DEPENDENCY and it belongs in the experience file -- declaring
    # it here as well would be the same fact in two places. The experience is
    # asserted separately, below.
    assert "--enable" not in args


def test_kit_args_omit_public_ip_when_unset():
    module = _load_module()
    args = module._kit_args(port=49100, public_ip="", media_port=47998)
    assert not any("publicIp" in a for a in args)


def test_media_port_defaults_from_env(monkeypatch):
    # 6.0 makes the media port explicit; two producers on one host collide on
    # it even with distinct signalling ports, so it joins the contract.
    monkeypatch.setenv("ISAAC_STREAM_PORT", "47777")
    module = _load_module()
    args = module._build_arg_parser().parse_args([])
    assert args.media_port == 47777


# ---------------------------------------------------------------------------
# The experience file is the fix, so the experience file is what this pins.
#
# The producer stage had NO test at all before isaac#252 -- `stream_smoke.sh`
# exercises `./script/run.sh -t stream`, a different bringup path that keeps
# working on 6.0.1, so the whole 5.1.0 -> 6.0.1 migration went green while the
# producer silently stopped streaming. A test that only checked the driver's
# argv would have stayed green too: the driver was not where the defect was.

_EXPERIENCE = _REPO_ROOT / "apps" / "isaacsim.exp.base.python.streaming.kit"


def test_streaming_experience_depends_on_the_extension_that_creates_the_stream():
    text = _EXPERIENCE.read_text(encoding="utf-8")
    deps = text.split("[dependencies]", 1)[1].split("[settings", 1)[0]
    # On 6.0 omni.kit.livestream.webrtc no longer brings the server up by
    # itself; omni.kit.livestream.app does, and only if it is loaded.
    assert '"omni.kit.livestream.app" = {}' in deps, (
        "the streaming experience must depend on omni.kit.livestream.app -- "
        "without it Isaac Sim 6.x boots, reports ready, and binds no port, "
        "with nothing in the log to say so (isaac#252)"
    )


def test_streaming_experience_defines_streamtype():
    text = _EXPERIENCE.read_text(encoding="utf-8")
    assert '[settings.exts."omni.kit.livestream.app"]' in text
    # "The extension automatically creates a primary stream at startup if the
    # streamType setting is defined." Undefined = no stream, silently.
    assert 'primaryStream.streamType = "webrtc"' in text


# ---------------------------------------------------------------------------
# The publish path itself (isaac#252).
#
# The code fix and the unit tests above would not have stopped `:0.0.2`: the
# workflow that published it built on a hosted runner and pushed, with the
# comment "No GPU needed -- Kit never boots at build time". A workflow that
# never boots Kit cannot discover that Kit will not stream, so the image was
# proven by nothing and consumed by owv's release gate.
#
# These pin the shape that fixes that, so removing the gate is a red test
# rather than a quiet edit.

_PUBLISH_WF = _REPO_ROOT / ".github" / "workflows" / "publish-stream-source.yaml"


def _publish_job():
    import yaml
    return yaml.safe_load(_PUBLISH_WF.read_text(encoding="utf-8"))["jobs"]["publish"]


def test_publish_runs_where_kit_can_boot():
    runs_on = _publish_job()["runs-on"]
    assert "self-hosted" in runs_on and "gpu" in runs_on, (
        "the publish job must run where Kit can actually boot; on a hosted "
        "runner nothing can prove the image streams (isaac#252)"
    )


def test_the_build_step_does_not_push():
    for step in _publish_job()["steps"]:
        with_ = step.get("with") or {}
        if "build-push-action" in str(step.get("uses", "")):
            assert with_.get("push") is not True, (
                "the build step must not push -- nothing may leave the runner "
                "before it has been proven to stream"
            )


def test_the_push_stands_behind_the_streaming_proof():
    steps = _publish_job()["steps"]
    names = [str(s.get("name", "")) for s in steps]
    runs = [str(s.get("run", "")) for s in steps]

    smoke = next(
        (i for i, r in enumerate(runs) if "producer_smoke.sh" in r), None
    )
    assert smoke is not None, "the publish path must run script/ci/producer_smoke.sh"

    push = next(
        (i for i, r in enumerate(runs) if "docker push" in r), None
    )
    assert push is not None, f"no push step found among {names}"
    assert smoke < push, "the streaming proof must come BEFORE the push"

    # A gate with a way out gets used on the day it matters most.
    assert steps[smoke].get("continue-on-error") is not True
    assert not steps[smoke].get("if"), (
        "the proof must be unconditional -- a skipped step still lets the "
        "push run"
    )
