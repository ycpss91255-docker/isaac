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
_PUBLISH_SCRIPT = _REPO_ROOT / "script" / "ci" / "publish_stream_source.sh"
# Every self-hosted job in the org goes through this one reusable workflow
# (the runner group is locked to it); it targets the self-hosted GPU pool.
_GPU_REUSABLE = (
    "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml@main"
)


def _publish_workflow():
    import yaml
    return yaml.safe_load(_PUBLISH_WF.read_text(encoding="utf-8"))


def _publish_job():
    return _publish_workflow()["jobs"]["publish"]


def _publish_commands():
    """The publish script's command lines: no comments, no blank lines."""
    lines = _PUBLISH_SCRIPT.read_text(encoding="utf-8").splitlines()
    return [ln.strip() for ln in lines if ln.strip() and not ln.lstrip().startswith("#")]


def test_publish_runs_where_kit_can_boot():
    job = _publish_job()
    assert job.get("uses") == _GPU_REUSABLE, (
        "the publish job must run where Kit can actually boot -- the org GPU "
        "reusable workflow; on a hosted runner nothing can prove the image "
        "streams (isaac#252)"
    )
    assert "runs-on" not in job, "no direct self-hosted target; go through the reusable workflow"
    labels = (job.get("with") or {}).get("runner-labels")
    assert labels is None or "gpu" in labels, "an override must keep the gpu label"
    assert job["with"]["run-script"].endswith("script/ci/publish_stream_source.sh")
    assert job["permissions"] == {"contents": "read", "packages": "write"}
    assert job["with"]["registry"] == "ghcr.io"
    assert job["with"]["setup-buildx"] is True


def test_the_build_step_does_not_push():
    builds = [c for c in _publish_commands() if c.startswith("docker buildx build")]
    assert len(builds) == 1, f"expected one buildx build, got {builds}"
    text = _PUBLISH_SCRIPT.read_text(encoding="utf-8")
    build_block = text[text.index("docker buildx build"):]
    build_block = build_block[: build_block.index("endgroup")]
    assert "--push" not in build_block, (
        "the build step must not push -- nothing may leave the runner "
        "before it has been proven to stream"
    )
    assert "--load" in build_block, "the smoke must run the image that would be pushed"


def test_the_push_stands_behind_the_streaming_proof():
    cmds = _publish_commands()
    assert "set -euo pipefail" in cmds, "a failed proof must stop the script"

    smoke = next((i for i, c in enumerate(cmds) if "producer_smoke.sh" in c), None)
    assert smoke is not None, "the publish path must run script/ci/producer_smoke.sh"
    push = next((i for i, c in enumerate(cmds) if c.startswith("docker push")), None)
    assert push is not None, f"no push found among {cmds}"
    assert smoke < push, "the streaming proof must come BEFORE the push"

    # A gate with a way out gets used on the day it matters most.
    line = cmds[smoke]
    assert line.startswith('timeout "${SMOKE_TIMEOUT}" '), (
        "the smoke keeps its 30-minute bound (the old step timeout)"
    )
    assert "||" not in line and not line.startswith("if"), (
        "the proof must be unconditional -- an ignored failure still lets "
        "the push run"
    )
    assert 'SMOKE_TIMEOUT="${PUBLISH_SMOKE_TIMEOUT:-30m}"' in _PUBLISH_SCRIPT.read_text(
        encoding="utf-8"
    )


def test_the_dispatch_tag_is_validated_before_the_gpu_host():
    wf = _publish_workflow()
    assert "tag" in wf[True]["workflow_dispatch"]["inputs"]  # `on:` parses as True
    job = _publish_job()
    assert job["needs"] == ["validate"]
    # script-env makes each line of an interpolated value its own variable, so
    # the raw input must never reach it -- only the validated output.
    import yaml
    assert "inputs.tag" not in yaml.safe_dump(job), (
        "the publish job must read needs.validate.outputs.tag, not inputs.tag"
    )
    assert job["with"]["script-env"].strip() == "IMAGE_TAG=${{ needs.validate.outputs.tag }}"
    validate = wf["jobs"]["validate"]
    assert validate["runs-on"] == "ubuntu-latest"
    run = validate["steps"][0]["run"]
    assert "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$" in run and "exit 1" in run


def test_the_publish_script_refuses_a_bad_tag_before_docker(tmp_path):
    # A stub docker that records any call: a refused tag must reach none.
    calls = tmp_path / "docker-calls"
    stub = tmp_path / "docker"
    stub.write_text(f'#!/bin/sh\necho "$@" >> "{calls}"\n')
    stub.chmod(0o755)
    import os
    for bad in ("", "-x", "0.0.3\nPATH=/tmp", "a" * 129, "0.0.3 extra", "x:y"):
        env = dict(os.environ, PATH=f"{tmp_path}:{os.environ['PATH']}",
                   IMAGE_TAG=bad, GITHUB_SHA="0" * 40)
        result = subprocess.run(
            ["bash", str(_PUBLISH_SCRIPT)], env=env, capture_output=True, text=True
        )
        assert result.returncode == 2, (bad, result.stderr)
        assert "IMAGE_TAG must be a docker tag" in result.stderr
    assert not calls.exists(), calls.read_text()
