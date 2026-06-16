"""Isaac Lab availability integration smoke (issue #149, ADR-0018).

Proves the baked Isaac Lab base tool is importable inside the built GPU
container: launches `AppLauncher` headless, imports `isaaclab.sim`, and
confirms the spawner + URDF-converter surfaces and the pinned 2.3 version
the re-base (MR-2..MR-6) builds on. Pass criterion is the runner's stdout
marker line, not the return code (Kit `_exit(0)` swallows it, same
convention as the other integration runners).

Run inside the GPU-enabled test container:

    ./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
        <repo>/test/integration/pytest/test_isaaclab_available.py -s
"""

import re
import subprocess
import sys
from pathlib import Path

import pytest  # noqa: F401  (kept for fixture style consistency)

RUNNER_SCRIPT = Path(__file__).parent / "_isaaclab_available_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"

# AppLauncher boot is light here (headless, no cameras), but a cold Kit /
# shader cache on the runner can still take minutes; keep a generous ceiling.
SUBPROC_TIMEOUT_SEC = 900

# Pinned base-tool major.minor (ADR-0018; Dockerfile ISAACLAB_VERSION).
EXPECTED_VERSION_PREFIX = "2.3"


def _dump_output(result):
    sys.stderr.write(
        "\n--- isaaclab_available stdout ---\n" + result.stdout
        + "\n--- isaaclab_available stderr ---\n" + result.stderr
    )


def test_isaaclab_importable_in_container():
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER_SCRIPT)],
        capture_output=True,
        text=True,
        timeout=SUBPROC_TIMEOUT_SEC,
    )
    _dump_output(result)
    out = result.stdout

    assert "[EXIT CLEAN]" in out, "runner did not reach a clean Kit shutdown."
    m = re.search(
        r"\[ISAACLAB OK\] version=(\S+) spawn=(\S+) urdf_converter=(\S+)", out
    )
    assert m, "Isaac Lab availability marker missing -- import failed inside the container."
    version, spawn, urdf_converter = m.group(1), m.group(2), m.group(3)
    assert version.startswith(EXPECTED_VERSION_PREFIX), (
        f"Isaac Lab version {version} does not match the pinned "
        f"{EXPECTED_VERSION_PREFIX}.x (Dockerfile ISAACLAB_VERSION)."
    )
    assert spawn == "True", (
        "isaaclab.sim spawner surface (UsdFileCfg / GroundPlaneCfg) missing."
    )
    assert urdf_converter == "True", (
        "isaaclab.sim.converters.UrdfConverterCfg surface missing."
    )
