"""Hosted guard: every caller of the org GPU reusable workflow is pinned.

isaac#402.  The callers of `gpu-self-hosted.yml` (main.yaml,
stream-smoke.yaml, publish-stream-source.yaml) must all pin the same
release tag.  Callers are discovered by parsing every workflow file, so a
new caller is covered without editing this list; a second test pins the
discovered set so a rename or an empty discovery cannot pass vacuously.
"""

import pathlib

import yaml

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_WORKFLOWS = _REPO_ROOT / ".github" / "workflows"
_REUSABLE = "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml"
_PINNED_TAG = "v0.4.0"
_EXPECTED_CALLERS = {
    "main.yaml",
    "stream-smoke.yaml",
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


def test_every_gpu_reusable_caller_is_pinned_to_v040():
    bad = {
        name: refs
        for name, refs in _callers().items()
        if any(ref != f"{_REUSABLE}@{_PINNED_TAG}" for ref in refs)
    }
    assert not bad, f"callers not pinned to @{_PINNED_TAG}: {bad}"


def test_gpu_reusable_callers_are_the_known_three():
    assert set(_callers()) == _EXPECTED_CALLERS
