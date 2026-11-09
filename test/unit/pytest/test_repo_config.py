"""Hosted guards for repo-level build/run config found by onboarding.

- ``.dockerignore`` must keep the host-side Isaac Sim cache tree
  (``isaac-sim/``, the bind-mount sources under ``${WS_PATH}`` = the repo
  root) out of the build context. It is hundreds of MB to GBs, and Kit
  creates ``isaac-sim/documents/Kit/shared/screenshots`` with mode 000, which
  made ``just docker build`` fail with ``open .../screenshots: permission
  denied`` after the first Isaac launch.
- ``.setup.conf`` ``[deploy]`` must use ``gpu_runtime``: base v0.42.0 renamed
  ``runtime`` and warns ``runtime is renamed to gpu_runtime`` on every setup.

Pure file reads.
"""

import re
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]


def _section(text, name):
    match = re.search(
        rf"^\[{re.escape(name)}\]\s*$(.*?)(?=^\[|\Z)", text, re.M | re.S
    )
    assert match, f"[{name}] section missing"
    return match.group(1)


def test_dockerignore_excludes_isaac_sim_cache_tree():
    lines = {
        line.strip()
        for line in (_REPO_ROOT / ".dockerignore").read_text().splitlines()
    }
    assert {"isaac-sim/", "isaac-sim", "/isaac-sim/"} & lines


def test_setup_conf_deploy_uses_gpu_runtime_key():
    deploy = _section((_REPO_ROOT / ".setup.conf").read_text(), "deploy")
    keys = [
        line.split("=", 1)[0].strip()
        for line in deploy.splitlines()
        if "=" in line and not line.lstrip().startswith("#")
    ]
    assert "runtime" not in keys
    assert "gpu_runtime" in keys


def test_dockerfile_precreates_kit_extension_folders():
    # The experience file lists ${app}/../extsUser as an extension folder.
    # It is missing from the NGC image, and the non-root container user
    # cannot create it under /isaac-sim (mode 0750), so Kit drops it to ''
    # and scans the working directory (the repo root, ~/work) instead:
    # one "Extensions config 'extension.toml' doesn't exist" warning per
    # top-level directory on every launch.
    dockerfile = (_REPO_ROOT / "Dockerfile").read_text()
    mkdirs = re.findall(r"^RUN\s+mkdir\s+-p\s+([^\n&]+)", dockerfile, re.M)
    created = {path for line in mkdirs for path in line.split()}
    assert "/isaac-sim/extsUser" in created
