"""Scope selection for CI (isaac#434): which groups does a change touch?

`script/ci/changed_groups.py` turns a PR's changed paths into the set of
scope groups to run. The rules the workflow relies on:

* push to main, a release tag, and a manual dispatch run every group;
* a PR runs only the groups its paths belong to, plus `docs` (cheap lint);
* a change to a shared layer (Dockerfile, compose, setup conf, base subtree,
  the CI wiring itself) runs every group;
* a path that matches no rule is `core`, never "nothing".
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT = _REPO_ROOT / "script" / "ci" / "changed_groups.py"
ALL = ["core", "gui", "stream", "headless", "docs"]


@pytest.fixture(scope="module")
def cg():
    spec = importlib.util.spec_from_file_location("changed_groups", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["changed_groups"] = module
    spec.loader.exec_module(module)
    return module


def _pr(cg, *paths):
    return cg.select("pull_request", list(paths), repo_root=_REPO_ROOT)


# -- events -------------------------------------------------------------------


@pytest.mark.parametrize("event", ["push", "workflow_dispatch", "schedule", ""])
def test_non_pr_events_run_every_group(cg, event):
    assert cg.select(event, [], repo_root=_REPO_ROOT) == ALL


def test_a_pr_with_no_changed_path_runs_only_docs(cg):
    assert _pr(cg) == ["docs"]


def test_dispatch_with_an_explicit_group_list(cg):
    got = cg.select(
        "workflow_dispatch", [], dispatch_groups="stream", repo_root=_REPO_ROOT
    )
    assert got == ["stream", "docs"]


def test_dispatch_with_all_runs_everything(cg):
    got = cg.select(
        "workflow_dispatch", [], dispatch_groups="all", repo_root=_REPO_ROOT
    )
    assert got == ALL


def test_dispatch_rejects_an_unknown_group(cg):
    with pytest.raises(ValueError, match="nightly"):
        cg.select(
            "workflow_dispatch", [], dispatch_groups="nightly", repo_root=_REPO_ROOT
        )


# -- paths --------------------------------------------------------------------


def test_docs_only_pr_touches_only_docs(cg):
    got = _pr(
        cg,
        "README.md",
        "doc/test/TEST.md",
        "doc/changelog/CHANGELOG.md",
        "doc/README.ja.md",
        "src/doc/adr/0011-ci-architecture-with-self-hosted-gpu-runner.md",
    )
    assert got == ["docs"]


def test_framework_change_is_core_only(cg):
    assert _pr(cg, "framework/isaac_devkit/driver.py") == ["core", "docs"]


def test_stream_script_change_is_stream(cg):
    assert _pr(cg, "script/ci/stream_smoke.sh") == ["stream", "docs"]
    assert _pr(cg, "script/runheadless-host-config.sh") == ["stream", "docs"]
    assert _pr(cg, "script/hooks/post/run.sh") == ["stream", "docs"]
    assert _pr(cg, "src/script/stream_source_producer.py") == ["stream", "docs"]


def test_a_stream_spec_follows_its_declared_group(cg):
    # Not a path pattern: the spec's own `# bats file_tags=stream` decides.
    assert _pr(cg, "test/bats/smoke/post_run_hook_spec.bats") == ["stream", "docs"]
    assert _pr(cg, "test/unit/pytest/test_stream_source_producer.py") == [
        "stream",
        "docs",
    ]


def test_a_core_spec_follows_its_declared_group(cg):
    assert _pr(cg, "test/bats/smoke/docker_env.bats") == ["core", "docs"]
    assert _pr(cg, "test/unit/pytest/test_scene_builder.py") == ["core", "docs"]


def test_a_docs_group_test_runs_docs_not_core(cg):
    assert _pr(cg, "test/unit/pytest/test_producer_versions.py") == ["docs"]


def test_a_deleted_or_unknown_test_path_is_core(cg):
    assert _pr(cg, "test/unit/pytest/test_removed_long_ago.py") == ["core", "docs"]


def test_ci_workflow_files_follow_their_group_in_the_name(cg):
    # The naming rule (isaac#443) puts the group in the file name, so the
    # path rule needs no per-file list.
    assert _pr(cg, ".github/workflows/ci-stream-smoke.yaml") == ["stream", "docs"]
    assert _pr(cg, ".github/workflows/ci-gui-smoke.yaml") == ["gui", "docs"]
    assert _pr(cg, ".github/workflows/ci-headless-smoke.yaml") == ["headless", "docs"]


def test_gui_and_headless_scripts(cg):
    assert _pr(cg, "script/ci/gui_smoke.sh") == ["gui", "docs"]
    assert _pr(cg, "script/ci/headless_smoke.sh") == ["headless", "docs"]


def test_unknown_path_is_core_never_nothing(cg):
    assert _pr(cg, "some/new/dir/file.txt") == ["core", "docs"]


@pytest.mark.parametrize(
    "path",
    [
        "Dockerfile",
        "compose.yaml",
        ".setup.conf",
        ".dockerignore",
        "config/host.yaml.example",
        ".base/dist/dockerfile/Dockerfile",
        ".github/workflows/main.yaml",
        "script/ci/changed_groups.py",
        "script/ci/gate_result.py",
        "script/ci/run_bats.sh",
        "test/assert_pytest_baseline.sh",
        "test/pytest-baseline.txt",
        "test/group_markers.py",
    ],
)
def test_shared_layer_change_runs_every_group(cg, path):
    assert _pr(cg, path) == ALL


def test_union_of_several_paths_keeps_canonical_order(cg):
    got = _pr(cg, "script/ci/stream_smoke.sh", "framework/isaac_devkit/driver.py")
    assert got == ["core", "stream", "docs"]


# -- outputs ------------------------------------------------------------------


def test_outputs_for_a_docs_only_run_skip_every_heavy_job(cg):
    out = cg.outputs(["docs"])
    assert out["core"] == "false"
    assert out["stream"] == "false"
    assert out["docs"] == "true"
    assert out["build"] == "false"
    assert out["stages"] == ""


def test_outputs_for_a_stream_run(cg):
    out = cg.outputs(["stream", "docs"])
    assert out["stream"] == "true"
    assert out["core"] == "false"
    assert out["build"] == "true"
    assert out["stages"] == "stream"
    assert out["bats_skip"] == "core,gui,headless"


def test_outputs_for_a_core_run_build_no_extra_stage(cg):
    out = cg.outputs(["core", "docs"])
    assert out["build"] == "true"
    assert out["stages"] == ""
    assert out["bats_skip"] == "gui,stream,headless"


def test_outputs_for_every_group_build_every_stage(cg):
    out = cg.outputs(ALL)
    assert out["stages"] == "gui,stream,headless"
    assert out["bats_skip"] == ""
    assert out["groups"] == "core,gui,stream,headless,docs"


# -- CLI ----------------------------------------------------------------------


def _cli(env_extra, cwd=_REPO_ROOT):
    import os

    env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME")}
    env.update(env_extra)
    return subprocess.run(
        [sys.executable, str(_SCRIPT)],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        check=False,
    )


def test_cli_prints_github_output_lines_for_a_push():
    result = _cli({"EVENT_NAME": "push"})
    assert result.returncode == 0, result.stderr
    lines = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert lines["groups"] == "core,gui,stream,headless,docs"
    assert lines["core"] == "true"
    assert lines["stages"] == "gui,stream,headless"


def test_cli_exits_2_on_a_bad_dispatch_group():
    result = _cli({"EVENT_NAME": "workflow_dispatch", "DISPATCH_GROUPS": "nightly"})
    assert result.returncode == 2
    assert "nightly" in result.stderr


def test_cli_pr_diff_comes_from_git(tmp_path):
    # The hosted slim-python container has no git, so a stub `git` on PATH
    # stands in: it records its argv and prints the "changed" paths.
    bindir = tmp_path / "bin"
    bindir.mkdir()
    log = tmp_path / "git.log"
    stub = bindir / "git"
    stub.write_text(
        "#!/bin/sh\n"
        f'echo "$@" >> "{log}"\n'
        "printf 'doc/x.md\\nREADME.md\\n'\n"
    )
    stub.chmod(0o755)
    result = _cli(
        {
            "EVENT_NAME": "pull_request",
            "BASE_SHA": "aaa111",
            "HEAD_SHA": "bbb222",
            "PATH": f"{bindir}:/usr/bin:/bin",
        }
    )
    assert result.returncode == 0, result.stderr
    assert log.read_text().strip() == "diff --name-only aaa111...bbb222"
    lines = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert lines["groups"] == "docs"
    assert lines["build"] == "false"
