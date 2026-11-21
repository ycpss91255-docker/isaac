"""Shape of `.github/workflows/main.yaml` after the scope split (isaac#434).

Structural guards for the things a path-filtered CI can silently get wrong:

* no workflow-level `paths:` filter: GitHub leaves a required check pending
  forever when the whole workflow is skipped by a trigger filter, so the
  filtering happens in the `changes` job instead;
* `gate` needs every other job and runs `always()`, so a skipped job cannot
  hold the required check and a failed one cannot slip through;
* every scoped job is gated on its own group flag from `changes`, the GPU
  jobs included, so a docs-only PR never reaches the GPU runner;
* release waits for `gate`, and a tag runs every group.
"""

from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.core

_MAIN = Path(__file__).resolve().parents[3] / ".github" / "workflows" / "main.yaml"

SCOPED = {
    "docs-unit": None,
    "core-unit": "core",
    "stream-unit": "stream",
    "core-gpu": "core",
    "core-build": "build",
}


@pytest.fixture(scope="module")
def doc():
    return yaml.safe_load(_MAIN.read_text())


@pytest.fixture(scope="module")
def jobs(doc):
    return doc["jobs"]


def _triggers(doc):
    # PyYAML (YAML 1.1) parses the bare key `on` as boolean True.
    return doc.get("on", doc.get(True))


def test_job_set_is_exactly_the_scoped_jobs_plus_changes_gate_release(jobs):
    assert set(jobs) == {"changes", "gate", "release", *SCOPED}


def test_no_trigger_level_path_filter(doc):
    triggers = _triggers(doc)
    for name, cfg in triggers.items():
        if isinstance(cfg, dict):
            assert "paths" not in cfg, name
            assert "paths-ignore" not in cfg, name


def test_triggers_cover_pr_main_tags_and_manual_dispatch(doc):
    triggers = _triggers(doc)
    assert "pull_request" in triggers
    assert "main" in triggers["push"]["branches"]
    assert "v*" in triggers["push"]["tags"]
    assert "groups" in triggers["workflow_dispatch"]["inputs"]


def test_there_is_no_schedule_trigger(doc):
    assert "schedule" not in _triggers(doc)


def test_gate_needs_every_other_job_and_runs_always(jobs):
    gate = jobs["gate"]
    assert set(gate["needs"]) == set(jobs) - {"gate", "release"}
    assert "always()" in str(gate["if"])


def test_gate_runs_the_gate_script_with_needs_json(jobs):
    steps = jobs["gate"]["steps"]
    text = yaml.safe_dump(steps)
    assert "script/ci/gate_result.py" in text
    assert "toJSON(needs)" in text


@pytest.mark.parametrize("job", sorted(set(SCOPED) - {"docs-unit"}))
def test_scoped_jobs_wait_for_changes_and_check_their_flag(jobs, job):
    cfg = jobs[job]
    needs = cfg["needs"] if isinstance(cfg["needs"], list) else [cfg["needs"]]
    assert "changes" in needs
    assert f"needs.changes.outputs.{SCOPED[job]} == 'true'" in str(cfg["if"])


def test_docs_unit_always_runs_after_changes(jobs):
    cfg = jobs["docs-unit"]
    assert "if" not in cfg
    assert "changes" in (cfg["needs"] if isinstance(cfg["needs"], list) else [cfg["needs"]])


def test_gpu_job_waits_for_core_unit_and_keeps_the_fork_guard(jobs):
    cfg = jobs["core-gpu"]
    assert "core-unit" in cfg["needs"]
    assert "github.event.pull_request.head.repo.full_name == github.repository" in str(
        cfg["if"]
    )


def test_build_receives_the_selected_stages_and_bats_skip(jobs):
    cfg = jobs["core-build"]
    assert cfg["with"]["extra_stages"] == "${{ needs.changes.outputs.stages }}"
    assert "BATS_SKIP_GROUPS=${{ needs.changes.outputs.bats_skip }}" in cfg["with"][
        "build_args"
    ]


def test_release_waits_for_gate_and_only_runs_on_tags(jobs):
    cfg = jobs["release"]
    needs = cfg["needs"] if isinstance(cfg["needs"], list) else [cfg["needs"]]
    assert "gate" in needs
    assert "refs/tags/" in str(cfg["if"])


def test_changes_job_exposes_every_flag_the_jobs_read(jobs):
    outputs = jobs["changes"]["outputs"]
    for key in ("groups", "core", "gui", "stream", "headless", "docs", "build",
                "stages", "bats_skip"):
        assert key in outputs, key
