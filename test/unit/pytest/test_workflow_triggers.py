"""Workflow triggers (isaac#434): no nightly test run, stream smoke on demand.

The stream smoke used to run from a `schedule` trigger every night. Over its
last 100 runs it failed 86 times and nobody acted on it, so a scheduled run
bought nothing. It is now a job of the stream group (runs when stream files
change, and on push to main / a release tag), and stays runnable by hand.
"""

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.core

_WORKFLOWS = Path(__file__).resolve().parents[3] / ".github" / "workflows"

# A schedule is allowed only for a bot that tracks an upstream release; it
# runs no tests. Anything else on a timer is the nightly run this removed.
_SCHEDULE_ALLOWED = {"base-version-monitor.yaml"}


def _load(name):
    return yaml.safe_load((_WORKFLOWS / name).read_text())


def _triggers(doc):
    return doc.get("on", doc.get(True))


def _all():
    files = sorted(_WORKFLOWS.glob("*.y*ml"))
    assert files, "no workflow files found: the guard would pass vacuously"
    return files


def test_only_the_upstream_tracking_bot_has_a_schedule():
    scheduled = {f.name for f in _all() if "schedule" in _triggers(yaml.safe_load(f.read_text()))}
    assert scheduled <= _SCHEDULE_ALLOWED, scheduled


def test_stream_smoke_has_no_schedule_but_keeps_manual_dispatch():
    triggers = _triggers(_load("ci-stream-smoke.yaml"))
    assert "schedule" not in triggers
    assert "workflow_dispatch" in triggers


def test_stream_smoke_is_callable_from_main():
    assert "workflow_call" in _triggers(_load("ci-stream-smoke.yaml"))


def test_stream_smoke_still_runs_the_stream_smoke_script_on_the_gpu_runner():
    doc = _load("ci-stream-smoke.yaml")
    job = doc["jobs"]["stream-smoke"]
    assert job["uses"].startswith(
        "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml@"
    )
    assert job["with"]["run-script"] == "./script/ci/stream_smoke_job.sh"
    assert job["with"]["timeout-minutes"] == 30
