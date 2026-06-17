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
    """environment ground + light + robot USD spawn via the cfg adapter.

    Strengthened in #154: also asserts /World/Robot/base_link RESOLVES
    through the adapter reference. The committed camera_bot.usd now carries
    a defaultPrim (/camera_bot, fb6f580), so the adapter's UsdFileCfg
    reference pulls in the referenced robot content and base_link lands at
    /World/Robot/base_link. (Reported-not-asserted before the defaultPrim
    fix -- the legacy-importer asset had no referenceable root prim.)
    """
    m = re.search(
        r"\[ADAPTER OK\] ground=(\w+) light=(\w+) robot=(\w+) objects=(\d+)",
        adapter_run.stdout,
    )
    assert m, f"no [ADAPTER OK] marker:\n{adapter_run.stdout}"
    assert m.group(1) == "True", "ground plane not spawned at /World/ground"
    assert m.group(2) == "True", "distant light not spawned at /World/light"
    assert m.group(3) == "True", "robot USD not spawned at /World/Robot"
    assert int(m.group(4)) >= 1, "no object instance spawned under /World/Objects"

    base_link = re.search(r"\[ADAPTER BASE_LINK\] valid=(\w+)", adapter_run.stdout)
    assert base_link, f"no [ADAPTER BASE_LINK] marker:\n{adapter_run.stdout}"
    assert base_link.group(1) == "True", (
        "/World/Robot/base_link did not resolve through the adapter "
        "reference (defaultPrim regression?)"
    )


def test_adapter_spawns_mobility_dynamic_object(adapter_run):
    """A mobility: dynamic object spawns AND carries RigidBodyAPI.

    object.yaml declares the prop_cube as ``mobility: dynamic``; the
    adapter builds a ``UsdFileCfg`` with ``rigid_props`` + ``mass_props`` +
    ``collision_props`` and ``cfg.func`` spawns it.

    Strengthened in #154: the resulting ``UsdPhysics.RigidBodyAPI`` IS now
    asserted. The committed ``prop_cube.usda`` carries a defaultPrim
    (/prop_cube, fb6f580), so the ``UsdFileCfg`` reference resolves to the
    referenced content and the dynamic-mobility props land on a real prim
    (``rigidbody=True``). Before the defaultPrim fix the reference resolved
    empty and the API landed on absent content (reported-not-asserted).
    """
    m = re.search(
        r"\[ADAPTER OBJECT\] path=(\S+) valid=True rigidbody=(\w+)",
        adapter_run.stdout,
    )
    assert m, f"no dynamic object spawned via the adapter:\n{adapter_run.stdout}"
    assert m.group(2) == "True", (
        f"dynamic object {m.group(1)} spawned without RigidBodyAPI; the "
        "defaultPrim reference did not resolve the rigid-body content"
    )
