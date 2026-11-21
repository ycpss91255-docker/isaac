"""Workflow naming rule and its lint (isaac#443).

The rule lives in `doc/workflow-naming.md`; `script/ci/lint_workflow_names.py`
enforces it over `.github/workflows/*.yaml`:

* file:  `<category>-<feature>.yaml`, category one of ci / release / bot / tool;
* name:  `<Category>: <Feature Words>` matching the file name;
* jobs:  kebab-case ids; in CI workflows (`main.yaml`, `ci-*.yaml`) either one
  of changes / gate / release or prefixed by a scope group
  (core- / gui- / stream- / headless- / docs-); no job-level `name:` (the
  check name is the job id, which is what branch protection refers to);
* a short list of files is exempt by exact name, each with a reason, because
  base's `init.sh` owns them.

The lint also scans the documentation for workflow / job names the rule
retired, so a rename cannot leave a stale name behind.
"""

import importlib.util
import sys
import textwrap
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT = _REPO_ROOT / "script" / "ci" / "lint_workflow_names.py"
_DOC = _REPO_ROOT / "doc" / "workflow-naming.md"
_INIT_SH = _REPO_ROOT / ".base" / "dist" / "script" / "base" / "init.sh"


@pytest.fixture(scope="module")
def lint():
    spec = importlib.util.spec_from_file_location("lint_workflow_names", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["lint_workflow_names"] = module
    spec.loader.exec_module(module)
    return module


def _tree(tmp_path, files):
    wf = tmp_path / ".github" / "workflows"
    wf.mkdir(parents=True)
    for name, body in files.items():
        (wf / name).write_text(textwrap.dedent(body))
    return tmp_path


_GOOD_CI = """
    name: "CI: Stream Smoke"
    on: {workflow_dispatch: {}}
    jobs:
      stream-smoke:
        runs-on: ubuntu-latest
        steps: [{run: "true"}]
"""


# -- the real tree ------------------------------------------------------------


def test_the_real_workflows_follow_the_rule(lint):
    assert lint.lint(_REPO_ROOT) == []


def test_the_real_workflow_dir_is_not_empty(lint):
    names = {p.name for p in lint.workflow_files(_REPO_ROOT)}
    assert {"main.yaml", "ci-stream-smoke.yaml"} <= names


def test_the_retired_stream_smoke_name_is_gone(lint):
    assert not (_REPO_ROOT / ".github" / "workflows" / "stream-smoke.yaml").exists()


# -- file names ---------------------------------------------------------------


def test_a_good_ci_workflow_passes(lint, tmp_path):
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": _GOOD_CI})
    assert lint.lint(root) == []


@pytest.mark.parametrize(
    "filename",
    ["stream-smoke.yaml", "ci-stream-smoke.yml", "CI-Stream-Smoke.yaml",
     "ci_stream_smoke.yaml", "ci-.yaml", "deploy-stream.yaml"],
)
def test_a_bad_file_name_is_reported(lint, tmp_path, filename):
    root = _tree(tmp_path, {filename: _GOOD_CI})
    errors = lint.lint(root)
    assert any(filename in e and "file name" in e for e in errors), errors


# -- display names ------------------------------------------------------------


@pytest.mark.parametrize(
    "name",
    ["Stream Smoke (GPU)", "CI: Stream smoke", "Bot: Stream Smoke", "ci: Stream Smoke", ""],
)
def test_a_bad_display_name_is_reported(lint, tmp_path, name):
    body = _GOOD_CI.replace('"CI: Stream Smoke"', f'"{name}"')
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": body})
    errors = lint.lint(root)
    assert any("name" in e and "CI: Stream Smoke" in e for e in errors), errors


def test_the_display_name_category_follows_the_file_category(lint, tmp_path):
    body = _GOOD_CI.replace("CI: Stream Smoke", "Bot: Base Watch")
    root = _tree(tmp_path, {"bot-base-watch.yaml": body.replace("stream-smoke", "base-watch")})
    assert lint.lint(root) == []


# -- job ids ------------------------------------------------------------------


@pytest.mark.parametrize("job", ["Stream_Smoke", "streamSmoke", "stream--smoke", "-stream"])
def test_a_non_kebab_job_id_is_reported(lint, tmp_path, job):
    body = _GOOD_CI.replace("stream-smoke:", f"{job}:")
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": body})
    errors = lint.lint(root)
    assert any(job in e and "kebab" in e for e in errors), errors


def test_a_ci_job_without_a_group_prefix_is_reported(lint, tmp_path):
    body = _GOOD_CI.replace("stream-smoke:", "build:")
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": body})
    errors = lint.lint(root)
    assert any("build" in e and "group" in e for e in errors), errors


@pytest.mark.parametrize("job", ["changes", "gate", "release", "core-unit", "docs-unit"])
def test_ci_job_ids_that_are_allowed(lint, tmp_path, job):
    body = _GOOD_CI.replace("stream-smoke:", f"{job}:")
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": body})
    assert lint.lint(root) == []


def test_a_bot_job_only_has_to_be_kebab_case(lint, tmp_path):
    body = """
        name: "Bot: Sim Version"
        on: {workflow_dispatch: {}}
        jobs:
          check-latest:
            runs-on: ubuntu-latest
            steps: [{run: "true"}]
    """
    root = _tree(tmp_path, {"bot-sim-version.yaml": body})
    assert lint.lint(root) == []


def test_a_job_level_name_is_reported(lint, tmp_path):
    body = _GOOD_CI.replace(
        "stream-smoke:\n", "stream-smoke:\n        name: Stream smoke\n"
    )
    root = _tree(tmp_path, {"ci-stream-smoke.yaml": body})
    errors = lint.lint(root)
    assert any("stream-smoke" in e and "name:" in e for e in errors), errors


# -- exemptions ---------------------------------------------------------------


def test_every_exemption_has_a_reason(lint):
    assert lint.EXEMPT_FILES
    for filename, reason in lint.EXEMPT_FILES.items():
        assert len(reason) > 30, filename


def test_exemption_is_by_exact_file_name_only(lint, tmp_path):
    root = _tree(tmp_path, {"main2.yaml": _GOOD_CI})
    assert any("main2.yaml" in e for e in lint.lint(root))


def test_main_yaml_is_exempt_from_file_and_display_name(lint, tmp_path):
    body = """
        name: Main CI/CD
        on: {workflow_dispatch: {}}
        jobs:
          core-unit:
            runs-on: ubuntu-latest
            steps: [{run: "true"}]
    """
    assert lint.lint(_tree(tmp_path, {"main.yaml": body})) == []


def test_main_yaml_jobs_still_follow_the_job_rule(lint, tmp_path):
    body = """
        name: Main CI/CD
        on: {workflow_dispatch: {}}
        jobs:
          call-docker-build:
            runs-on: ubuntu-latest
            steps: [{run: "true"}]
    """
    errors = lint.lint(_tree(tmp_path, {"main.yaml": body}))
    assert any("call-docker-build" in e for e in errors), errors


def test_the_base_generated_monitor_keeps_its_name(lint):
    assert "base-version-monitor.yaml" in lint.EXEMPT_FILES
    assert "main.yaml" in lint.EXEMPT_FILES


def test_base_init_still_generates_the_monitor_under_its_original_name_and_never_overwrites():
    # Why the monitor keeps its file name: init.sh creates exactly this path
    # when it is absent, so a renamed file would be regenerated beside the
    # renamed one on the next base upgrade. It only creates, never overwrites,
    # so the content is ours -- but the name is not.
    text = _INIT_SH.read_text()
    assert ".github/workflows/base-version-monitor.yaml" in text
    assert '[[ -e "${_wf}" ]] && return 0' in text


# -- documentation ------------------------------------------------------------


def test_the_rule_is_documented_with_every_exemption_and_reason(lint):
    text = _DOC.read_text()
    for category in ("ci", "release", "bot", "tool"):
        assert f"`{category}-" in text, category
    for group in ("core", "gui", "stream", "headless", "docs"):
        assert f"`{group}-" in text, group
    for filename in lint.EXEMPT_FILES:
        assert filename in text, filename
    assert "init.sh" in text


def test_the_docs_hold_no_retired_name(lint):
    assert lint.stale_references(_REPO_ROOT) == []


@pytest.mark.parametrize(
    "stale",
    ["call-docker-build", "call-release", "stream-smoke.yaml", "Stream Smoke (GPU)"],
)
def test_a_retired_name_in_the_docs_is_reported(lint, tmp_path, stale):
    (tmp_path / "README.md").write_text(f"see {stale} for details\n")
    assert any(stale in e for e in lint.stale_references(tmp_path))


def test_the_new_file_name_is_not_mistaken_for_the_retired_one(lint, tmp_path):
    (tmp_path / "README.md").write_text("see ci-stream-smoke.yaml\n")
    assert lint.stale_references(tmp_path) == []


def test_history_documents_may_keep_old_names(lint, tmp_path):
    (tmp_path / "doc" / "changelog").mkdir(parents=True)
    (tmp_path / "doc" / "changelog" / "CHANGELOG.md").write_text("call-docker-build\n")
    (tmp_path / "src" / "doc" / "adr").mkdir(parents=True)
    (tmp_path / "src" / "doc" / "adr" / "0011.md").write_text("call-release\n")
    assert lint.stale_references(tmp_path) == []
