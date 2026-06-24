"""GPU integration: collider_type contrast on a concave fixture (#167).

ADR-0020 decision 2. The concave U-shape fixture
(test/fixtures/urdf/concave_ushape.urdf, a single-link single-mesh robot
whose collision references mesh/ushape.stl) is imported BOTH ways via
``isaac_devkit.model_import.import_urdf(collider_type=...)`` and the produced
USDs are contrasted:

  convex_hull           -> ONE convex collider piece (the open-top notch is
                           filled into a single hull).
  convex_decomposition  -> MULTIPLE convex collider pieces (the concavity is
                           preserved as several convex hulls).

Each import owns its own ``SimulationApp`` (a process-global singleton), so
the contrast is gathered by spawning the Kit-side ``_collider_import_runner``
once per collider_type and parsing its ``[COLLIDER SUMMARY]`` marker -- the
same subprocess-per-import / marker-line pattern as ``test_model_import.py``
(``pxr`` is not importable in the bare pytest process).

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
    r"convex_pieces=(\d+) root=(\S+)"
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
        "convex_pieces": int(m.group(3)),
        "root": m.group(4),
    }


def test_convex_hull_yields_single_collider(tmp_path):
    """convex_hull collapses the concave U into ONE convex collider piece."""
    summary = _run_collider("convex_hull", tmp_path / "ushape_hull.usd")
    assert summary["type"] == "convex_hull"
    assert summary["convex_pieces"] == 1, (
        "convex_hull must produce exactly one convex collider piece (the "
        f"concavity filled into a single hull); got {summary}"
    )


def test_convex_decomposition_yields_multiple_colliders(tmp_path):
    """convex_decomposition preserves the concavity as MULTIPLE pieces.

    The decomposition of the U-shape must produce more than one convex
    collider piece -- the open-top notch is preserved by the multiple
    convex hulls, where convex_hull would have filled it solid. Asserted
    as the direct contrast against the hull import.
    """
    hull = _run_collider("convex_hull", tmp_path / "ushape_hull.usd")
    decomp = _run_collider(
        "convex_decomposition", tmp_path / "ushape_decomp.usd"
    )
    assert decomp["type"] == "convex_decomposition"
    assert decomp["convex_pieces"] > 1, (
        "convex_decomposition must produce multiple convex collider pieces "
        f"(the concavity preserved); got {decomp}"
    )
    assert decomp["convex_pieces"] > hull["convex_pieces"], (
        "convex_decomposition must yield MORE convex pieces than convex_hull "
        f"(hull={hull['convex_pieces']}, decomp={decomp['convex_pieces']})"
    )
