"""IsaacDriver integration smoke test.

Verifies a minimal subclass walks the full lifecycle (Kit boot, stage
open, scene defaults, timeline play, setup hook, main loop, shutdown
hook, app.close) without raising. Asserted via stdout markers because
Kit's ``app.close`` calls ``_exit(0)`` on the way out and swallows
``sys.exit`` (see ``_minimal_driver_runner.py``).
"""

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest  # noqa: F401  (kept for fixture style consistency)

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_minimal_driver_runner.py"
SCRIPT_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 180


def _write_stub_usd(tmp_path: Path) -> Path:
    """Write the smallest USD Kit will open without complaining."""
    p = tmp_path / "stub.usda"
    p.write_text(
        textwrap.dedent("""\
            #usda 1.0
            (
                upAxis = "Z"
                metersPerUnit = 1.0
            )

            def Xform "World"
            {
            }
            """),
        encoding="utf-8",
    )
    return p


def test_minimal_driver_runs_and_exits(tmp_path):
    stub_usd = _write_stub_usd(tmp_path)

    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER_SCRIPT),
            "--script-dir", str(SCRIPT_DIR),
            "--usd-path", str(stub_usd),
        ],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )

    if "[OK] minimal driver main reached" not in result.stdout:
        sys.stderr.write(
            "\n--- minimal_driver stdout ---\n" + result.stdout
            + "\n--- minimal_driver stderr ---\n" + result.stderr
        )
    assert "[OK] minimal driver main reached" in result.stdout, (
        "IsaacDriver.run() did not reach the subclass main() hook."
    )
    # And no exception was reported.
    assert "[RAISED]" not in result.stdout, (
        "IsaacDriver.run() raised inside the lifecycle. "
        + result.stdout[-1000:]
    )
