"""Hosted guards for the README-listed standalone driver scripts.

The README's "Standalone Python workflow" table points a new user at four
scripts under ``src/script/``. A README-only onboarding run on Isaac Sim
6.2.0 found that:

  - ``move_openbase_planar_standalone.py`` died on
    ``ModuleNotFoundError: omni.isaac.dynamic_control`` (removed in the 6.x
    line) and still exited 0, because ``SimulationApp`` shuts Kit down with
    ``_exit(0)`` and a module-top failure never reaches any handler;
  - ``cmd_vel_planar_standalone.py`` let the base fall through the floor
    (``lin.z = -0.16`` every report): the per-tick velocity write clears
    ``v.z`` only after PhysX has integrated gravity, the same effect the
    ``move_openbase`` script already cancels by disabling gravity on
    ``base_link``;
  - ``ros2_test_pub_standalone.py`` claimed ~1 Hz but published every 60
    Kit updates, i.e. 3.5-7.5 Hz depending on load;
  - all four hard-coded ``/home/yunchien/work/...``.

The runtime behaviour needs the GPU and is verified in the container (see
the PR); these hosted tests pin the shape that makes it hold: a pure helper
(``standalone_common``) for the exit code, the Kit config, the repo paths
and a wall-clock publish timer, and each script routing through it with no
module-top Isaac import. Pure -- file reads, AST parses and a fake clock.
"""

import ast
import importlib.util
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT_DIR = _REPO_ROOT / "src" / "script"
_HELPER = _SCRIPT_DIR / "standalone_common.py"

# The four standalone scripts the README tells a new user to run.
_README_SCRIPTS = (
    "ros2_test_pub_standalone.py",
    "ros2_test_sub_standalone.py",
    "move_openbase_planar_standalone.py",
    "cmd_vel_planar_standalone.py",
)
_ISAAC_TOP_LEVEL = ("omni", "pxr", "isaacsim", "isaaclab", "carb", "rclpy")


def _load_helper():
    spec = importlib.util.spec_from_file_location("standalone_common", _HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _tree(name):
    return ast.parse((_SCRIPT_DIR / name).read_text(encoding="utf-8"))


def _imported_modules(tree):
    names = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.append(node.module)
    return names


# -- the pure helper -----------------------------------------------------


def test_helper_exists_and_imports_without_isaac():
    assert _HELPER.is_file()
    before = set(sys.modules)
    _load_helper()
    leaked = sorted(
        name
        for name in set(sys.modules) - before
        if name.partition(".")[0] in _ISAAC_TOP_LEVEL
    )
    assert leaked == []


def test_kit_config_follows_isaac_livestream():
    helper = _load_helper()
    assert helper.kit_config(None) == {"headless": True}
    assert helper.kit_config("0") == {"headless": True}
    streaming = helper.kit_config("2")
    assert streaming["livestream"] == 2
    assert streaming["headless"] is False
    with pytest.raises(ValueError):
        helper.kit_config("9")


def test_openbase_usd_path_is_repo_relative_and_exists():
    helper = _load_helper()
    usd = helper.openbase_usd_path()
    assert usd == (
        _REPO_ROOT / "src" / "model" / "usd" / "robot" / "openbase"
        / "openbase.usda"
    )
    assert usd.is_file()


def test_periodic_timer_fires_once_per_period_regardless_of_tick_rate():
    helper = _load_helper()
    now = [100.0]
    timer = helper.PeriodicTimer(1.0, clock=lambda: now[0])
    fired = 0
    # 600 updates/s for 3 s: a tick-count gate (every 60) would fire 30x.
    for _ in range(1800):
        now[0] += 1.0 / 600.0
        if timer.due():
            fired += 1
    assert fired == 3


def test_periodic_timer_does_not_burst_after_a_stall():
    helper = _load_helper()
    now = [0.0]
    timer = helper.PeriodicTimer(1.0, clock=lambda: now[0])
    now[0] = 10.0  # a 10 s hitch (shader compile, first frame)
    assert timer.due() is True
    assert timer.due() is False


def test_run_and_exit_turns_an_exception_into_exit_code_1(capsys):
    helper = _load_helper()
    codes = []

    def _boom():
        raise ModuleNotFoundError("No module named 'omni.isaac.dynamic_control'")

    helper.run_and_exit(_boom, exit_fn=codes.append)
    assert codes == [1]
    assert "omni.isaac.dynamic_control" in capsys.readouterr().err


@pytest.mark.parametrize("returned, expected", [(None, 0), (0, 0), (3, 3)])
def test_run_and_exit_passes_main_return_code_through(returned, expected):
    helper = _load_helper()
    codes = []
    helper.run_and_exit(lambda: returned, exit_fn=codes.append)
    assert codes == [expected]


# -- every README-listed script --------------------------------------------


@pytest.mark.parametrize("name", _README_SCRIPTS)
def test_script_does_not_use_removed_dynamic_control(name):
    modules = _imported_modules(_tree(name))
    assert not [m for m in modules if "dynamic_control" in m]


@pytest.mark.parametrize("name", _README_SCRIPTS)
def test_script_has_no_hard_coded_home(name):
    assert "/home/yunchien" not in (_SCRIPT_DIR / name).read_text(
        encoding="utf-8"
    )


@pytest.mark.parametrize("name", _README_SCRIPTS)
def test_script_has_no_module_top_isaac_import_or_app(name):
    """A module-top failure would bypass run_and_exit and exit 0."""
    offenders = []
    for node in _tree(name).body:
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)):
            continue  # function bodies run inside run_and_exit
        if isinstance(node, ast.Import):
            mods = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom):
            mods = [node.module or ""]
        else:
            mods = []
        offenders += [m for m in mods if m.partition(".")[0] in _ISAAC_TOP_LEVEL]
        offenders += [
            "SimulationApp(...)"
            for call in ast.walk(node)
            if isinstance(call, ast.Call)
            and getattr(call.func, "id", "") == "SimulationApp"
        ]
    assert offenders == []


@pytest.mark.parametrize("name", _README_SCRIPTS)
def test_script_main_block_routes_through_run_and_exit(name):
    tree = _tree(name)
    main_blocks = [
        node
        for node in tree.body
        if isinstance(node, ast.If) and "__main__" in ast.unparse(node.test)
    ]
    assert len(main_blocks) == 1
    assert "run_and_exit(" in ast.unparse(main_blocks[0])


def test_ros2_test_pub_publishes_on_a_wall_clock_period():
    source = (_SCRIPT_DIR / "ros2_test_pub_standalone.py").read_text(
        encoding="utf-8"
    )
    assert "PeriodicTimer(" in source
    assert "_PUBLISH_EVERY" not in source


@pytest.mark.parametrize(
    "name", ("cmd_vel_planar_standalone.py", "move_openbase_planar_standalone.py")
)
def test_planar_scripts_disable_gravity_on_base_link(name):
    source = (_SCRIPT_DIR / name).read_text(encoding="utf-8")
    assert "GetDisableGravityAttr().Set(True)" in source
