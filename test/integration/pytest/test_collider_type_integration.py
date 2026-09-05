"""GPU integration: collider_type contrast on a concave fixture (#167).

ADR-0020 decision 2. The concave U-shape fixture
(test/fixtures/urdf/concave_ushape.urdf, a single-link single-mesh robot
whose collision references mesh/ushape.stl) is imported BOTH ways via
``isaac_devkit.model_import.import_urdf(collider_type=...)`` and the produced
USDs are contrasted on the collision approximation the importer records:

  convex_hull           -> the collision mesh's UsdPhysics.MeshCollisionAPI
                           approximation is "convexHull" (the open-top notch
                           is filled into a single hull).
  convex_decomposition  -> the approximation is "convexDecomposition" (the
                           concavity is preserved; the multiple convex pieces
                           are cooked at sim time by PhysX, not authored as
                           separate USD prims, so the deterministic
                           stage-level contrast is the approximation token,
                           NOT a prim count).

Each import owns its own ``SimulationApp`` (a process-global singleton), so
the contrast is gathered by spawning the Kit-side ``_collider_import_runner``
once per collider_type and parsing its ``[COLLIDER SUMMARY]`` marker -- the
same subprocess-per-import / marker-line pattern as ``test_model_import.py``
(``pxr`` is not importable in the bare pytest process). The runner traverses
the produced (instanceable) USD WITH instance proxies so the collision mesh
prims inside the prototype are visited (a plain traversal sees none).

Runtime requirement: the Isaac Sim / Isaac Lab devel-test GPU container
(``/isaac-sim/python.sh -m pytest``).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_collider_import_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
IMPORT_TIMEOUT_SEC = 240

_SUMMARY_RE = re.compile(
    r"\[COLLIDER SUMMARY\] type=(\S+) collision_prims=(\d+) "
    r"approximation=(\S+) root=(\S+)"
)


def _run_collider(collider_type: str, out_usd: Path) -> dict:
    """Import the concave fixture with collider_type; parse the marker."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--collider-type", collider_type,
            "--out", str(out_usd),
        ],
        capture_output=True,
        text=True,
        timeout=IMPORT_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[COLLIDER SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- collider runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [COLLIDER SUMMARY] marker for {collider_type!r}"
    return {
        "type": m.group(1),
        "collision_prims": int(m.group(2)),
        "approximation": m.group(3),
        "root": m.group(4),
    }


def test_convex_hull_records_convex_hull_approximation(tmp_path):
    """convex_hull records the "convexHull" collision approximation.

    The concave U's collision mesh is imported and PhysX collapses it to a
    single filled hull -- recorded as the MeshCollisionAPI approximation
    token "convexHull". At least one collision prim must exist (the first
    GPU run reported zero because a plain traversal skipped the instanceable
    prototype the collision mesh lives in).
    """
    summary = _run_collider("convex_hull", tmp_path / "ushape_hull.usd")
    assert summary["type"] == "convex_hull"
    assert summary["collision_prims"] >= 1, (
        "convex_hull must import at least one collision prim (the resolved "
        f"collision mesh); got {summary}"
    )
    assert summary["approximation"] == "convexHull", (
        "convex_hull must record the 'convexHull' MeshCollisionAPI "
        f"approximation; got {summary}"
    )


def test_convex_decomposition_records_decomposition_approximation(tmp_path):
    """convex_decomposition records the "convexDecomposition" approximation.

    The decomposition preserves the concavity. PhysX cooks the multiple
    convex pieces at sim time rather than authoring them as separate USD
    prims, so the deterministic stage-level contrast against the hull import
    is the MeshCollisionAPI approximation token: "convexDecomposition" here
    vs "convexHull" for the hull import.
    """
    hull = _run_collider("convex_hull", tmp_path / "ushape_hull.usd")
    decomp = _run_collider(
        "convex_decomposition", tmp_path / "ushape_decomp.usd"
    )
    assert decomp["type"] == "convex_decomposition"
    assert decomp["collision_prims"] >= 1, (
        "convex_decomposition must import at least one collision prim; "
        f"got {decomp}"
    )
    assert decomp["approximation"] == "convexDecomposition", (
        "convex_decomposition must record the 'convexDecomposition' "
        f"MeshCollisionAPI approximation; got {decomp}"
    )
    assert decomp["approximation"] != hull["approximation"], (
        "convex_decomposition must record a DIFFERENT approximation than "
        f"convex_hull (hull={hull['approximation']}, "
        f"decomp={decomp['approximation']})"
    )
