"""Hosted contract tests for the gpu-integration caller in main.yaml.

isaac#344: the gpu-integration job must call the org reusable workflow at
a ref that supports `reap-container-filter` (v0.4.0) so containers of a
cancelled run are reaped. The real cancel-reap behaviour needs the GPU
runner and is not checkable here; these tests pin the caller contract.
"""

from pathlib import Path

import yaml

_REPO_ROOT = Path(__file__).resolve().parents[3]
_MAIN_WF = _REPO_ROOT / ".github" / "workflows" / "main.yaml"

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
