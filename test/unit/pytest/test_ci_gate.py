"""The required-check summary job (isaac#434).

Path-filtered jobs are skipped, and a skipped job must not hold a required
check pending. Branch protection therefore requires one summary job, `gate`,
which runs `always()` and passes when every upstream job succeeded OR was
skipped. The cases that matter:

* a skipped job is fine (that is the whole point);
* a failed or cancelled job fails the gate;
* `changes` not succeeding fails the gate -- otherwise every downstream job
  is skipped and the gate would pass having checked nothing.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

_SCRIPT = Path(__file__).resolve().parents[3] / "script" / "ci" / "gate_result.py"


@pytest.fixture(scope="module")
def gate():
    spec = importlib.util.spec_from_file_location("gate_result", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["gate_result"] = module
    spec.loader.exec_module(module)
    return module


def _needs(**results):
    return {name: {"result": result, "outputs": {}} for name, result in results.items()}


def test_all_success_passes(gate):
    ok, _ = gate.evaluate(_needs(changes="success", **{"core-unit": "success"}))
    assert ok


def test_skipped_jobs_pass(gate):
    ok, _ = gate.evaluate(
        _needs(changes="success", **{"core-gpu": "skipped", "stream-unit": "skipped"})
    )
    assert ok


@pytest.mark.parametrize("bad", ["failure", "cancelled"])
def test_a_failed_or_cancelled_job_fails(gate, bad):
    ok, lines = gate.evaluate(
        _needs(changes="success", **{"core-unit": "success", "core-gpu": bad})
    )
    assert not ok
    assert any("core-gpu" in line and bad in line for line in lines)


def test_changes_not_succeeding_fails_even_if_the_rest_is_skipped(gate):
    ok, lines = gate.evaluate(_needs(changes="failure", **{"core-gpu": "skipped"}))
    assert not ok
    assert any("changes" in line for line in lines)


def test_missing_changes_job_fails(gate):
    ok, _ = gate.evaluate(_needs(**{"core-unit": "success"}))
    assert not ok


def test_empty_needs_fails(gate):
    ok, _ = gate.evaluate({})
    assert not ok


def _cli(needs):
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME")}
    env["NEEDS_JSON"] = json.dumps(needs)
    return subprocess.run(
        [sys.executable, str(_SCRIPT)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


def test_cli_exit_codes():
    assert _cli(_needs(changes="success", **{"core-gpu": "skipped"})).returncode == 0
    assert _cli(_needs(changes="success", **{"core-gpu": "failure"})).returncode == 1


def test_cli_without_needs_json_exits_2():
    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME")}
    result = subprocess.run(
        [sys.executable, str(_SCRIPT)],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    assert result.returncode == 2
