"""L1 Model Pipeline integration test (ADR-0018 decision 6).

End-to-end coverage for ``isaac_devkit.model_import``: invoke the CLI as
a subprocess against the openbase URDF (an existing minimal-link robot
already tracked in this repo), then verify the resulting USD is a SINGLE
Isaac Lab instanceable USD with the expected prim hierarchy. The old
multi-file "Asset Structure 3.0" layout (root + geometry + material +
textures + sublayer chain + material-layer-survives-reimport) is dropped
(ADR-0018: model_import emits one instanceable USD; material color is a
spawn-time cfg param, not a USD variant layer).

Runtime requirement: this test must run inside the Isaac Sim / Isaac Lab
devel-test container (``/isaac-sim/python.sh -m pytest``). The CLI spawns
Kit and delegates conversion to ``isaaclab.sim.converters.UrdfConverter``.

Prim-hierarchy inspection: ``pxr.Usd`` needs a live Kit (USD plugins),
which the bare pytest process does NOT have -- the same reason the legacy
test inspected ``.usda`` as text. We reuse the shared
``_prim_summary_runner.py`` (already used by the L1 diff test): it opens
the produced USD inside one headless ``SimulationApp`` and prints a
parseable ``[PRIM SUMMARY]`` marker line we assert on here -- no in-process
pxr import.

Why subprocess per import: ``isaacsim.SimulationApp`` is a process-global
singleton -- creating it twice in one Python process raises. Each CLI
invocation needs a fresh process; pytest reuses one process for the whole
module, so the test shells out per invocation.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
OPENBASE_URDF = REPO_ROOT / "src" / "model" / "urdf" / "robot" / "openbase" / "openbase_minimal.urdf"
FRAMEWORK_DIR = REPO_ROOT / "framework"
SUMMARY_RUNNER = Path(__file__).parent / "_prim_summary_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
IMPORT_TIMEOUT_SEC = 180

# The openbase URDF robot is named "open_base"; the Isaac Lab importer
# uses the robot name for the root prim. NOTE (ADR-0018 decision 6): the
# exact prim/joint counts and instanceable-wrapper scoping the Isaac Lab
# UrdfConverter produces may differ from the legacy omni.kit.commands
# path, so the hierarchy assertion below is deliberately loose (root prim
# carries the robot name, stage is non-empty) -- the recalibration target
# is the GPU run, which reports the true counts via the marker line.
EXPECTED_ROBOT_NAME = "open_base"


def _run_import(urdf_path: Path, output_dir: Path, name: str, *, force: bool = False) -> subprocess.CompletedProcess:
    cmd = [
        PYTHON_SH,
        "-m", "isaac_devkit.model_import",
        "--urdf", str(urdf_path),
        "--output", str(output_dir),
        "--name", name,
    ]
    if force:
        cmd.append("--force")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=IMPORT_TIMEOUT_SEC,
        env=env,
    )


def _assert_ok(result: subprocess.CompletedProcess) -> None:
    if result.returncode != 0:
        sys.stderr.write(f"\n--- import_model stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}\n")
    assert result.returncode == 0, f"import_model exit {result.returncode}"


def _summarize(usd_path: Path, tag: str = "openbase") -> dict:
    """Summarize a produced USD via the shared Kit-side runner.

    pxr / USD plugins need a live Kit, which the bare pytest process does
    not have; ``_prim_summary_runner.py`` opens the stage inside one
    headless SimulationApp and prints a ``[PRIM SUMMARY]`` marker we parse.
    """
    result = subprocess.run(
        [
            PYTHON_SH, str(SUMMARY_RUNNER),
            "--framework", str(FRAMEWORK_DIR),
            "--usd", f"{tag}={usd_path}",
        ],
        capture_output=True,
        text=True,
        timeout=IMPORT_TIMEOUT_SEC,
    )
    if result.returncode != 0:
        sys.stderr.write(f"\n--- summary stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}\n")
    m = re.search(
        rf"\[PRIM SUMMARY\] tag={re.escape(tag)} prim=(\d+) joint=(\d+) "
        rf"links=(\d+) root=(\S+)",
        result.stdout,
    )
    assert m, f"no [PRIM SUMMARY] marker for {tag!r} in runner stdout:\n{result.stdout}"
    return {
        "prim": int(m.group(1)),
        "joint": int(m.group(2)),
        "links": int(m.group(3)),
        "root": m.group(4),
    }


def test_openbase_import_produces_single_usd(tmp_path):
    """ADR-0018 decision 6: a single <name>.usd is the whole output."""
    result = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(result)

    usd = tmp_path / "openbase.usd"
    assert usd.is_file(), f"missing single openbase.usd in {sorted(tmp_path.iterdir())}"

    # The dropped Asset Structure 3.0 artifacts must NOT be produced.
    assert not (tmp_path / "openbase_geometry.usda").exists()
    assert not (tmp_path / "openbase_material.usda").exists()
    assert not (tmp_path / "textures").exists()


def test_openbase_usd_has_expected_prim_hierarchy(tmp_path):
    """The produced USD is a valid, non-empty stage rooted at the robot.

    Loosely asserted (ADR-0018 recalibration target): the stage has prims
    and the root prim path carries the URDF robot name. The GPU run's
    marker line reports the exact prim/joint counts the Isaac Lab importer
    produces for this single-rigid-body robot.
    """
    result = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(result)

    summary = _summarize(tmp_path / "openbase.usd")
    assert summary["prim"] >= 1, "produced USD stage has no prims"
    assert EXPECTED_ROBOT_NAME in summary["root"], (
        f"root prim {summary['root']!r} does not carry robot name "
        f"{EXPECTED_ROBOT_NAME!r}"
    )


def test_reimport_force_regenerates_single_usd(tmp_path):
    """--force regenerates the single USD cleanly (exit 0, file exists).

    Replaces the old material-layer-survives-reimport contract (there is
    no separate material layer any more): the offline commit step always
    wants a fresh deterministic artifact, so --force just re-runs the
    conversion and the single USD is regenerated.
    """
    initial = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(initial)
    usd = tmp_path / "openbase.usd"
    assert usd.is_file()

    reimport = _run_import(OPENBASE_URDF, tmp_path, "openbase", force=True)
    _assert_ok(reimport)
    assert usd.is_file(), "single USD missing after --force re-import"
    assert _summarize(usd)["prim"] >= 1, "regenerated USD stage has no prims"
