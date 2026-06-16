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
Kit and delegates conversion to ``isaaclab.sim.converters.UrdfConverter``;
the assertions then load the produced USD via ``pxr.Usd``, which needs
the Isaac-Sim-bundled Python.

Why subprocess instead of in-process import:
``isaacsim.SimulationApp`` is a process-global singleton -- creating it
twice in the same Python process raises. Each CLI invocation needs a
fresh process; pytest reuses one process for the whole module, so the
test must shell out per invocation.
"""

import os
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
OPENBASE_URDF = REPO_ROOT / "src" / "model" / "urdf" / "robot" / "openbase" / "openbase_minimal.urdf"
FRAMEWORK_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
IMPORT_TIMEOUT_SEC = 180

# The openbase URDF is a single rigid body (base_link only, all rims /
# rollers stripped). After fix_base + merge_fixed_joints the importer
# produces the robot root /open_base with base_link under it. NOTE
# (ADR-0018 decision 6): the Isaac Lab importer may name the instanceable
# wrapper or count the synthetic fix_base root_joint differently from the
# legacy omni.kit.commands path; these constants are the first GPU-run
# recalibration target. The assertions below are deliberately loose
# (root prim present, base_link present, >= 1 prim) so the first GPU run
# reports the true counts without a pre-emptive guess.
EXPECTED_ROOT_PRIM = "/open_base"
EXPECTED_LINK = "base_link"


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


def _prim_records(usd_path: Path):
    """Open the produced USD and return [(path, type_name)] traversal records."""
    from pxr import Usd

    stage = Usd.Stage.Open(str(usd_path))
    assert stage is not None, f"pxr could not open {usd_path}"
    return [
        (str(prim.GetPath()), str(prim.GetTypeName()))
        for prim in stage.Traverse()
    ]


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
    """The produced USD is a valid stage with /open_base + base_link.

    Loosely asserted (ADR-0018 recalibration target): the root prim
    /open_base is present, base_link appears under it, and the stage is
    non-empty. First GPU run will report the exact prim/joint counts the
    Isaac Lab importer produces for this single-rigid-body robot.
    """
    result = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(result)

    records = _prim_records(tmp_path / "openbase.usd")
    assert records, "produced USD stage has no prims"

    paths = [p for p, _ in records]
    assert EXPECTED_ROOT_PRIM in paths, (
        f"root prim {EXPECTED_ROOT_PRIM} missing; got roots "
        f"{[p for p in paths if p.count('/') == 1]}"
    )
    assert any(
        p == f"{EXPECTED_ROOT_PRIM}/{EXPECTED_LINK}" or p.endswith(f"/{EXPECTED_LINK}")
        for p in paths
    ), f"link {EXPECTED_LINK} missing from {paths}"


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
    assert _prim_records(usd), "regenerated USD stage has no prims"
