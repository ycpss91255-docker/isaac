"""L1 adapter GPU test (#152, ADR-0018 decisions 1 + 3).

Dedicated GPU coverage for the new ``isaac_devkit.scene.build_scene``
adapter: the example scene is spawned through ``to_isaaclab_cfg`` ->
``sim_utils`` cfg -> ``cfg.func()`` (NOT the example driver's own raw-pxr
``_build_scene``, which still runs until #154), and the spawned prims are
asserted on the live stage. This is the DoD "the example scene spawns via
the adapter; L1 prim assertions hold" check.

The Kit side runs in ``_build_scene_runner.py`` (one ``SimulationApp`` per
process -- the singleton constraint); this module owns the subprocess
invocation and marker assertions. ``pxr`` is not importable in the bare
pytest process, so the runner emits marker lines parsed here.

Runtime: inside the Isaac Sim / Isaac Lab devel-test container
(``/isaac-sim/python.sh -m pytest``).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER_SCRIPT = Path(__file__).parent / "_build_scene_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 600


@pytest.fixture(scope="module")
def adapter_run():
    """Spawn the example scene via the framework adapter once, share stdout."""
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER_SCRIPT), "--repo-root", str(REPO_ROOT)],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
    )
    if result.returncode != 0 or "[ADAPTER OK]" not in result.stdout:
        sys.stderr.write(
            f"\n--- build_scene_runner stdout ---\n{result.stdout}"
            f"\n--- stderr ---\n{result.stderr}\n"
        )
    return result


def test_adapter_runner_clean_exit(adapter_run):
    """The adapter spawn path runs end-to-end without raising."""
    assert adapter_run.returncode == 0, "build_scene_runner exited non-zero"
    assert "[EXIT CLEAN]" in adapter_run.stdout
    assert "[RAISED]" not in adapter_run.stdout


def test_adapter_spawns_ground_light_robot(adapter_run):
    """environment ground + light + robot USD spawn via the cfg adapter."""
    m = re.search(
        r"\[ADAPTER OK\] ground=(\w+) light=(\w+) robot=(\w+) objects=(\d+)",
        adapter_run.stdout,
    )
    assert m, f"no [ADAPTER OK] marker:\n{adapter_run.stdout}"
    assert m.group(1) == "True", "ground plane not spawned at /World/ground"
    assert m.group(2) == "True", "distant light not spawned at /World/light"
    assert m.group(3) == "True", "robot USD not spawned at /World/Robot"
    assert int(m.group(4)) >= 1, "no object instance spawned under /World/Objects"


def test_adapter_spawns_mobility_dynamic_object(adapter_run):
    """A mobility: dynamic object materializes + spawns via its rigid cfg.

    object.yaml declares the prop_cube as ``mobility: dynamic``; the
    adapter builds a ``UsdFileCfg`` with ``rigid_props`` + ``mass_props`` +
    ``collision_props`` and ``cfg.func`` spawns it -- this test proves that
    dynamic-mobility cfg path runs end-to-end (the prim is authored).

    The resulting ``UsdPhysics.RigidBodyAPI`` is NOT asserted here: the
    committed ``prop_cube.usda`` is a legacy-importer asset with no
    ``defaultPrim``, so the ``UsdFileCfg`` reference resolves empty and the
    physics API lands on absent referenced content. That assertion is #154's
    once the example assets are regenerated (with a ``defaultPrim``) by the
    Isaac Lab importer. ``rigidbody=`` is reported by the runner for that
    follow-up.
    """
    assert re.search(
        r"\[ADAPTER OBJECT\] path=\S+ valid=True rigidbody=\w+",
        adapter_run.stdout,
    ), f"no dynamic object spawned via the adapter:\n{adapter_run.stdout}"
