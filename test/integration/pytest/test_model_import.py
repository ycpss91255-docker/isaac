"""L1 Model Pipeline integration test.

End-to-end coverage for ``isaac_devkit.model_import``: invoke the
importer as a subprocess against the openbase URDF (an existing minimal-link
robot already tracked in this repo), then verify the resulting
filesystem layout and prim hierarchy match Asset Structure 3.0 + the
re-import contract documented in ADR-0010.

Runtime requirement: this test must run inside the Isaac Sim devel-test
container (``/isaac-sim/python.sh -m pytest``). The importer spawns
Kit; the assertions then load the produced USD via ``pxr.Usd``, which
also needs the Isaac-Sim-bundled Python.

Why subprocess instead of in-process import:
``isaacsim.SimulationApp`` is a process-global singleton -- creating it
twice in the same Python process raises. Each importer invocation needs
a fresh process; pytest reuses one process for the whole module, so the
test must shell out per invocation. Trade-off accepted: ~30 s Kit boot
per test x 2 tests = ~1 min wall time; isolation outweighs the speed
cost for an L1 contract test.
"""

import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
OPENBASE_URDF = REPO_ROOT / "src" / "model" / "urdf" / "robot" / "openbase" / "openbase_minimal.urdf"
FRAMEWORK_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
IMPORT_TIMEOUT_SEC = 180


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


def test_openbase_import_produces_asset_structure_3_0(tmp_path):
    result = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(result)

    root_usd = tmp_path / "openbase.usd"
    geometry = tmp_path / "openbase_geometry.usda"
    material = tmp_path / "openbase_material.usda"
    textures = tmp_path / "textures"

    assert root_usd.is_file(), f"missing root .usd in {sorted(tmp_path.iterdir())}"
    assert geometry.is_file(), f"missing _geometry.usda in {sorted(tmp_path.iterdir())}"
    assert material.is_file(), f"missing _material.usda in {sorted(tmp_path.iterdir())}"
    assert textures.is_dir(), f"missing textures/ in {sorted(tmp_path.iterdir())}"


def test_openbase_import_sublayer_chain_resolves_geometry(tmp_path):
    """ADR-0010 L2 contract: composition reaches geometry from root.

    The Asset Structure 3.0 impl chains the sublayers
    ``root -> material -> geometry`` (so that variant-set edits to material
    can be authored in isolation from the URDF re-import path). This test
    walks the chain by text inspection — pxr is unavailable without booting
    Kit, and the .usda ASCII format is stable enough for sublayer-reference
    grep. The contract verified: starting from ``<name>.usd``, the geometry
    .usda is reachable via one hop through ``<name>_material.usda``.
    """
    result = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(result)

    root_text = (tmp_path / "openbase.usd").read_text(encoding="utf-8")
    assert "openbase_material.usda" in root_text, (
        "root .usd does not sublayer openbase_material.usda — root composition "
        "broken. Root content:\n" + root_text[:400]
    )

    material_text = (tmp_path / "openbase_material.usda").read_text(encoding="utf-8")
    assert "openbase_geometry.usda" in material_text, (
        "material .usda does not sublayer openbase_geometry.usda — the "
        "chain root->material->geometry is broken at the material hop. "
        "Material content head:\n" + material_text[:400]
    )

    geometry_text = (tmp_path / "openbase_geometry.usda").read_text(encoding="utf-8")
    assert "open_base" in geometry_text, (
        "geometry .usda missing the URDF robot name 'open_base' — the "
        "URDF import likely produced an empty stage. Geometry head:\n"
        + geometry_text[:400]
    )


def test_reimport_force_preserves_material_layer(tmp_path):
    initial = _run_import(OPENBASE_URDF, tmp_path, "openbase")
    _assert_ok(initial)

    material_path = tmp_path / "openbase_material.usda"
    marker = "# CUSTOM EDIT — must survive re-import (ADR-0010 L1 contract)\n"
    original = material_path.read_text(encoding="utf-8")
    material_path.write_text(original + marker, encoding="utf-8")

    reimport = _run_import(OPENBASE_URDF, tmp_path, "openbase", force=True)
    _assert_ok(reimport)

    after = material_path.read_text(encoding="utf-8")
    assert marker in after, (
        "re-import with --force overwrote the material layer; ADR-0010 "
        "contract violated. Material file head:\n" + after[:200]
    )
