"""Test-group contract (isaac#434): every test belongs to exactly one scope.

CI runs per scope (core / gui / stream / headless / docs), so a test with no
group would never be selected by any scoped job and a test with two groups
would run twice. This file pins the guards that make an ungrouped test a red
build instead of a silently skipped one:

* pytest: a module-level ``pytestmark = pytest.mark.<group>`` per test module
  (checked statically by ``script/ci/scope_groups.py`` and at collection time
  by ``test/group_markers.py``);
* bats: ``# bats file_tags=<group>`` per spec;
* ``test/pytest-baseline.txt`` carries one floor per group, and
  ``doc/test/TEST.md`` lists the counts per group.
"""

import importlib.util
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT = _REPO_ROOT / "script" / "ci" / "scope_groups.py"
_PLUGIN = _REPO_ROOT / "test" / "group_markers.py"
_BATS_DIR = _REPO_ROOT / "test" / "bats" / "smoke"
_PYTEST_DIRS = (
    _REPO_ROOT / "test" / "unit" / "pytest",
    _REPO_ROOT / "test" / "integration" / "pytest",
)
_BASELINE = _REPO_ROOT / "test" / "pytest-baseline.txt"
_TEST_MD = _REPO_ROOT / "doc" / "test" / "TEST.md"


def _load_script():
    spec = importlib.util.spec_from_file_location("scope_groups", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["scope_groups"] = module
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def tg():
    return _load_script()


def test_group_names_are_the_five_scopes(tg):
    assert tg.GROUPS == ("core", "gui", "stream", "headless", "docs")


def test_plugin_and_script_agree_on_the_groups(tg):
    spec = importlib.util.spec_from_file_location("group_markers", _PLUGIN)
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    assert plugin.GROUPS == tg.GROUPS


# -- pytest static guard ------------------------------------------------------


def test_every_real_pytest_module_has_exactly_one_group(tg):
    assert tg.check_pytest_modules(_PYTEST_DIRS) == []


def test_real_pytest_dirs_are_not_empty(tg):
    # A guard over an empty glob would pass vacuously.
    assert len(tg.pytest_modules(_PYTEST_DIRS)) >= 30


def test_unmarked_module_is_reported(tg, tmp_path):
    (tmp_path / "test_a.py").write_text("def test_x():\n    pass\n")
    errors = tg.check_pytest_modules([tmp_path])
    assert len(errors) == 1
    assert "test_a.py" in errors[0]
    assert "no group" in errors[0]


def test_two_groups_on_one_module_is_reported(tg, tmp_path):
    (tmp_path / "test_a.py").write_text(
        "import pytest\n"
        "pytestmark = [pytest.mark.core, pytest.mark.stream]\n"
        "def test_x():\n    pass\n"
    )
    errors = tg.check_pytest_modules([tmp_path])
    assert len(errors) == 1
    assert "exactly one" in errors[0]


def test_unknown_group_is_reported(tg, tmp_path):
    (tmp_path / "test_a.py").write_text(
        "import pytest\n"
        "pytestmark = pytest.mark.nightly\n"
        "def test_x():\n    pass\n"
    )
    errors = tg.check_pytest_modules([tmp_path])
    assert len(errors) == 1
    assert "no group" in errors[0]


def test_group_marker_on_a_function_is_reported(tg, tmp_path):
    # A test may not be re-grouped away from its module.
    (tmp_path / "test_a.py").write_text(
        "import pytest\n"
        "pytestmark = pytest.mark.core\n"
        "@pytest.mark.stream\n"
        "def test_x():\n    pass\n"
    )
    errors = tg.check_pytest_modules([tmp_path])
    assert len(errors) == 1
    assert "module level" in errors[0]


def test_marked_module_passes(tg, tmp_path):
    (tmp_path / "test_a.py").write_text(
        "import pytest\n"
        "pytestmark = pytest.mark.gui\n"
        "def test_x():\n    pass\n"
    )
    assert tg.check_pytest_modules([tmp_path]) == []


# -- bats static guard --------------------------------------------------------


def test_every_real_bats_spec_has_exactly_one_group(tg):
    assert tg.check_bats(_BATS_DIR) == []


def test_real_bats_dir_is_not_empty(tg):
    assert len(tg.bats_specs(_BATS_DIR)) >= 15


def test_untagged_bats_spec_is_reported(tg, tmp_path):
    (tmp_path / "a.bats").write_text('@test "x" {\n  true\n}\n')
    errors = tg.check_bats(tmp_path)
    assert len(errors) == 1
    assert "a.bats" in errors[0]
    assert "file_tags" in errors[0]


def test_bats_spec_with_two_groups_is_reported(tg, tmp_path):
    (tmp_path / "a.bats").write_text(
        "# bats file_tags=core,stream\n" '@test "x" {\n  true\n}\n'
    )
    errors = tg.check_bats(tmp_path)
    assert len(errors) == 1
    assert "exactly one" in errors[0]


def test_bats_test_tags_with_a_group_are_reported(tg, tmp_path):
    (tmp_path / "a.bats").write_text(
        "# bats file_tags=core\n"
        "# bats test_tags=stream\n"
        '@test "x" {\n  true\n}\n'
    )
    errors = tg.check_bats(tmp_path)
    assert len(errors) == 1
    assert "test_tags" in errors[0]


def test_bats_non_group_tags_are_allowed(tg, tmp_path):
    (tmp_path / "a.bats").write_text(
        "# bats file_tags=core,slow\n" '@test "x" {\n  true\n}\n'
    )
    assert tg.check_bats(tmp_path) == []


def test_bats_counts_per_group(tg, tmp_path):
    (tmp_path / "a.bats").write_text(
        '# bats file_tags=core\n@test "1" {\n  true\n}\n@test "2" {\n  true\n}\n'
    )
    (tmp_path / "b.bats").write_text(
        '# bats file_tags=stream\n@test "3" {\n  true\n}\n'
    )
    assert tg.count_bats(tmp_path) == {
        "core": 2,
        "gui": 0,
        "stream": 1,
        "headless": 0,
        "docs": 0,
    }


# -- collection-time guard (test/group_markers.py) ----------------------------


def _run_pytest(tmp_path, body, *args):
    """Run a throwaway test tree wired to the real plugin, in a subprocess."""
    (tmp_path / "test_sample.py").write_text(textwrap.dedent(body))
    (tmp_path / "conftest.py").write_text(
        "import importlib.util\n"
        f"_s = importlib.util.spec_from_file_location('group_markers', r'{_PLUGIN}')\n"
        "_m = importlib.util.module_from_spec(_s)\n"
        "_s.loader.exec_module(_m)\n"
        "pytest_configure = _m.pytest_configure\n"
        "pytest_collection_modifyitems = _m.pytest_collection_modifyitems\n"
    )
    return subprocess.run(
        [sys.executable, "-m", "pytest", "-p", "no:cacheprovider", "-q",
         "--rootdir", str(tmp_path), *args, str(tmp_path)],
        capture_output=True,
        text=True,
        cwd=tmp_path,
        check=False,
    )


def test_collection_fails_for_an_ungrouped_test(tmp_path):
    result = _run_pytest(tmp_path, "def test_x():\n    pass\n")
    assert result.returncode != 0
    assert "test_sample.py::test_x" in result.stdout + result.stderr
    assert "exactly one group" in result.stdout + result.stderr


def test_collection_fails_for_two_groups(tmp_path):
    result = _run_pytest(
        tmp_path,
        """
        import pytest
        pytestmark = [pytest.mark.core, pytest.mark.docs]
        def test_x():
            pass
        """,
    )
    assert result.returncode != 0
    assert "exactly one group" in result.stdout + result.stderr


def test_collection_accepts_a_grouped_test(tmp_path):
    result = _run_pytest(
        tmp_path,
        """
        import pytest
        pytestmark = pytest.mark.stream
        def test_x():
            pass
        """,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_marker_expression_selects_only_that_group(tmp_path):
    result = _run_pytest(
        tmp_path,
        """
        import pytest
        pytestmark = pytest.mark.stream
        def test_x():
            pass
        """,
        "--collect-only",
        "-m",
        "gui",
    )
    # Nothing is collected for another group (rc 5), and no unknown-marker
    # warning: all five groups are registered.
    assert result.returncode == 5
    assert "PytestUnknownMarkWarning" not in result.stdout + result.stderr


# -- baseline + TEST.md -------------------------------------------------------


def test_baseline_has_a_floor_for_every_group(tg):
    baseline = tg.read_baseline(_BASELINE)
    for group in tg.GROUPS:
        assert f"HOSTED_UNIT_BASELINE_{group.upper()}" in baseline, group
        assert f"BATS_BASELINE_{group.upper()}" in baseline, group


def test_group_floors_sum_to_the_total_floor(tg):
    baseline = tg.read_baseline(_BASELINE)
    total = sum(baseline[f"HOSTED_UNIT_BASELINE_{g.upper()}"] for g in tg.GROUPS)
    assert total == baseline["HOSTED_UNIT_BASELINE"]


def test_bats_counts_meet_the_group_floors(tg):
    baseline = tg.read_baseline(_BASELINE)
    counts = tg.count_bats(_BATS_DIR)
    for group in tg.GROUPS:
        assert counts[group] >= baseline[f"BATS_BASELINE_{group.upper()}"], group


def test_test_md_lists_the_bats_counts_per_group(tg):
    table = tg.parse_test_md_groups(_TEST_MD)
    counts = tg.count_bats(_BATS_DIR)
    for group in tg.GROUPS:
        assert table[group]["bats"] == counts[group], group


def test_test_md_pytest_counts_match_the_baseline(tg):
    table = tg.parse_test_md_groups(_TEST_MD)
    baseline = tg.read_baseline(_BASELINE)
    for group in tg.GROUPS:
        assert table[group]["hosted"] == baseline[
            f"HOSTED_UNIT_BASELINE_{group.upper()}"
        ], group
    # Every GPU integration test is core: it boots Isaac on the shared layer.
    assert table["core"]["gpu"] == baseline["GPU_INTEGRATION_BASELINE"]
    assert all(table[g]["gpu"] == 0 for g in tg.GROUPS if g != "core")
