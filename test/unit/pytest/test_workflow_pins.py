"""Hosted guard: every caller of the org GPU reusable workflow is pinned.

isaac#402.  The callers of `gpu-self-hosted.yml` (main.yaml,
ci-stream-smoke.yaml, publish-stream-source.yaml) must all pin the same
release tag.  Callers are discovered by parsing every workflow file, so a
new caller is covered without editing this list; a second test pins the
discovered set so a rename or an empty discovery cannot pass vacuously.
isaac#344 adds two tests for the run-scoped reap filter of core-gpu.
"""

import pathlib
import shutil
import subprocess

import yaml

import pytest

pytestmark = pytest.mark.core

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_WORKFLOWS = _REPO_ROOT / ".github" / "workflows"
_REUSABLE = "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml"
_PINNED_TAG = "v0.4.0"
_EXPECTED_CALLERS = {
    "main.yaml",
    "ci-stream-smoke.yaml",
    "publish-stream-source.yaml",
}


def _callers():
    """Map workflow file name -> list of `uses` refs to the GPU reusable."""
    found = {}
    for path in sorted(_WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for job in (doc.get("jobs") or {}).values():
            uses = (job or {}).get("uses") or ""
            if uses.startswith(_REUSABLE + "@"):
                found.setdefault(path.name, []).append(uses)
    return found


def _gpu_integration_job():
    """Parsed `core-gpu` job of main.yaml."""
    doc = yaml.safe_load(
        (_WORKFLOWS / "main.yaml").read_text(encoding="utf-8")
    )
    return doc["jobs"]["core-gpu"]


def test_every_gpu_reusable_caller_is_pinned_to_v040():
    bad = {
        name: refs
        for name, refs in _callers().items()
        if any(ref != f"{_REUSABLE}@{_PINNED_TAG}" for ref in refs)
    }
    assert not bad, f"callers not pinned to @{_PINNED_TAG}: {bad}"


def test_gpu_reusable_callers_are_the_known_three():
    assert set(_callers()) == _EXPECTED_CALLERS


def test_gpu_integration_passes_run_scoped_reap_filter():
    """isaac#344: the cancel-safe reap step only runs when the input is set."""
    job = _gpu_integration_job()
    assert job["uses"] == f"{_REUSABLE}@{_PINNED_TAG}"
    assert job["with"]["reap-container-filter"] == (
        "label=com.docker.compose.project="
        "isaac-baseline-${{ github.run_id }}-${{ github.run_attempt }}"
    )


_STUB_SETUP = "#!/usr/bin/env bash\nprintf 'WS_PATH=/x\\n' > .env.generated\n"
_STUB_BUILD = "#!/usr/bin/env bash\nexit 0\n"
_STUB_BASELINE = (
    "#!/usr/bin/env bash\n"
    'echo "BASELINE_PROJECT=${BASELINE_PROJECT}" > "${OBSERVED}"\n'
)


def test_reap_filter_matches_script_baseline_project(tmp_path):
    """isaac#344: the reap filter must name the project the script runs.

    The script is run for real (stubbed setup/build/baseline) with a known
    run id and attempt; the project it exports is the expected value.
    """
    (tmp_path / "script" / "ci").mkdir(parents=True)
    (tmp_path / "test").mkdir()
    for name in ("gpu_job_lib.sh", "gpu_integration_job.sh"):
        shutil.copy(_REPO_ROOT / "script" / "ci" / name,
                    tmp_path / "script" / "ci" / name)
    for rel, body in (
        ("script/setup.sh", _STUB_SETUP),
        ("script/build.sh", _STUB_BUILD),
        ("test/assert_pytest_baseline.sh", _STUB_BASELINE),
    ):
        (tmp_path / rel).write_text(body, encoding="utf-8")
    for path in tmp_path.rglob("*.sh"):
        path.chmod(0o755)
    observed = tmp_path / "observed.txt"
    env = {
        "PATH": "/usr/bin:/bin",
        "GITHUB_WORKSPACE": str(tmp_path),
        "GITHUB_RUN_ID": "111",
        "GITHUB_RUN_ATTEMPT": "2",
        "OBSERVED": str(observed),
    }
    subprocess.run(
        ["bash", str(tmp_path / "script" / "ci" / "gpu_integration_job.sh")],
        check=True, env=env, cwd=tmp_path, capture_output=True,
    )
    project = observed.read_text(encoding="utf-8").strip().split("=", 1)[1]

    template = _gpu_integration_job()["with"]["reap-container-filter"]
    rendered = template.replace("${{ github.run_id }}", "111").replace(
        "${{ github.run_attempt }}", "2"
    )
    assert rendered == f"label=com.docker.compose.project={project}"
