"""ISAAC_KIT_EXTRA_ARGS reaches Kit through IsaacDriver.run (isaac#422).

A ``--/app/isaac_test/marker=1`` Kit setting passed through the variable
is read back via carb settings inside Isaac; without the variable the
setting is absent. Asserted via stdout markers (Kit's ``app.close`` calls
``_exit(0)``).
"""

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_kit_extra_args_runner.py"
SCRIPT_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 180


def _run(tmp_path, extra_args):
    usd = tmp_path / "stub.usda"
    usd.write_text(
        '#usda 1.0\n(\n    upAxis = "Z"\n    metersPerUnit = 1.0\n)\n\n'
        'def Xform "World"\n{\n}\n',
        encoding="utf-8",
    )
    env = {k: v for k, v in os.environ.items() if k != "ISAAC_KIT_EXTRA_ARGS"}
    if extra_args is not None:
        env["ISAAC_KIT_EXTRA_ARGS"] = extra_args
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER_SCRIPT),
         "--script-dir", str(SCRIPT_DIR), "--usd-path", str(usd)],
        capture_output=True, text=True, timeout=SUBPROC_TIMEOUT_SEC, env=env,
    )
    return result.stdout


def test_extra_arg_is_visible_in_carb_settings(tmp_path):
    out = _run(tmp_path, "--/app/isaac_test/marker=1")
    assert "[MARKER] 1" in out, out[-1000:]


def test_marker_absent_without_variable(tmp_path):
    out = _run(tmp_path, None)
    assert "[MARKER] None" in out, out[-1000:]
