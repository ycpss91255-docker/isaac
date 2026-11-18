"""Hosted contract tests for the gpu-integration caller in main.yaml.

isaac#344: the gpu-integration job must call the org reusable workflow at
a ref that supports `reap-container-filter` (v0.4.0) so containers of a
cancelled run are reaped. The real cancel-reap behaviour needs the GPU
runner and is not checkable here; these tests pin the caller contract.
"""

import re
from pathlib import Path

import yaml

_REPO_ROOT = Path(__file__).resolve().parents[3]
_MAIN_WF = _REPO_ROOT / ".github" / "workflows" / "main.yaml"
_JOB_SCRIPT = _REPO_ROOT / "script" / "ci" / "gpu_integration_job.sh"

# Tag v0.4.0 of ycpss91255-docker/.github resolves to 81d21141 and is the
# first release that declares the reap-container-filter input.
_GPU_REUSABLE_V0_4_0 = (
    "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml@v0.4.0"
)


def _gpu_integration_job():
    wf = yaml.safe_load(_MAIN_WF.read_text(encoding="utf-8"))
    return wf["jobs"]["gpu-integration"]


def test_gpu_integration_pins_v0_4_0():
    assert _gpu_integration_job()["uses"] == _GPU_REUSABLE_V0_4_0


def _reap_filter():
    with_block = _gpu_integration_job().get("with", {})
    assert "reap-container-filter" in with_block, (
        "gpu-integration must pass reap-container-filter (isaac#344)"
    )
    return with_block["reap-container-filter"]


def test_gpu_integration_reap_filter_is_run_scoped():
    # Scoped by run_id AND run_attempt: an unscoped project label would
    # reap other jobs' containers on the shared GPU daemon.
    assert _reap_filter() == (
        "label=com.docker.compose.project="
        "isaac-baseline-${{ github.run_id }}-${{ github.run_attempt }}"
    )


def test_reap_filter_matches_job_script_baseline_project():
    # Derive the expected project from the job script so the filter and
    # the BASELINE_PROJECT given to run.sh cannot drift apart.
    text = _JOB_SCRIPT.read_text(encoding="utf-8")
    m = re.search(r'^BASELINE_PROJECT="([^"]+)"', text, re.MULTILINE)
    assert m, "BASELINE_PROJECT assignment not found in gpu_integration_job.sh"
    project = m.group(1)
    project = project.replace("${GITHUB_RUN_ID:?}", "${{ github.run_id }}")
    project = project.replace(
        "${GITHUB_RUN_ATTEMPT:?}", "${{ github.run_attempt }}"
    )
    assert "GITHUB_" not in project, f"unsubstituted variable in {project!r}"
    assert _reap_filter() == f"label=com.docker.compose.project={project}"
