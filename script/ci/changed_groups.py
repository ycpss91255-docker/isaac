#!/usr/bin/env python3
"""Pick the scope groups a CI run covers (isaac#434).

Reads the event from the environment and prints ``key=value`` lines for
``$GITHUB_OUTPUT``:

  EVENT_NAME        github.event_name
  BASE_SHA/HEAD_SHA the PR's base and head (pull_request only)
  DISPATCH_GROUPS   workflow_dispatch input: ``all`` / empty, or a comma list

Rules:

* push (main), a release tag, a manual dispatch and anything that is not a
  pull request run every group;
* a pull request runs the groups its changed paths belong to, plus ``docs``
  (cheap lint, always on);
* a shared layer (Dockerfile, compose, setup conf, config, the base subtree,
  the CI wiring) runs every group;
* a test file belongs to the group it declares (pytestmark / file_tags), so
  moving a test between groups needs no edit here;
* a path matching no rule is ``core`` -- never "nothing".

Outputs: ``groups`` (csv), one ``true``/``false`` flag per group, ``build``
(any non-docs group: the image build job runs), ``stages`` (csv of the
gui/stream/headless stages to build as extra stages) and ``bats_skip`` (csv of
groups NOT selected, fed to run_bats.sh so those specs do not run).
"""

import fnmatch
import importlib.util
import os
import subprocess
import sys
from pathlib import Path

GROUPS = ("core", "gui", "stream", "headless", "docs")
STAGE_GROUPS = ("gui", "stream", "headless")

_REPO_ROOT = Path(__file__).resolve().parents[2]

# Paths whose change can affect every stage: the image, how it is composed
# and configured, the base subtree, and the CI wiring and guards themselves.
_SHARED = (
    "Dockerfile",
    "compose.yaml",
    ".setup.conf",
    ".dockerignore",
    "config/*",
    ".base/*",
    ".github/workflows/main.yaml",
    "script/ci/changed_groups.py",
    "script/ci/gate_result.py",
    "script/ci/run_bats.sh",
    "script/ci/scope_groups.py",
    "test/assert_pytest_baseline.sh",
    "test/pytest-baseline.txt",
    "test/group_markers.py",
    "test/*/pytest/conftest.py",
)

# Documentation: only the docs group (lint + doc checks) is needed.
_DOCS = (
    "*.md",
    "*.rst",
    "doc/*",
    "*/doc/*",
    "LICENSE",
    ".github/CODEOWNERS",
    ".github/dependabot.yml",
)

# Stage- and stream-specific files that are not tests (tests carry their own
# group declaration).
_PATH_RULES = (
    ("stream", (
        "script/ci/stream_smoke*",
        "script/ci/producer_smoke.sh",
        "script/ci/publish_stream_source.sh",
        "script/ci/sync_producer_versions.py",
        "script/runheadless-host-config.sh",
        "script/host_yaml.sh",
        "script/hooks/post/*",
        "src/script/stream_source_producer.py",
        ".github/workflows/ci-stream-*",
        ".github/workflows/publish-stream-source.yaml",
    )),
    ("gui", ("script/ci/gui_*", ".github/workflows/ci-gui-*")),
    ("headless", ("script/ci/headless_*", ".github/workflows/ci-headless-*")),
)


def _matches(path, patterns):
    return any(fnmatch.fnmatchcase(path, p) for p in patterns)


def _load_scope_groups():
    spec = importlib.util.spec_from_file_location(
        "scope_groups", Path(__file__).resolve().parent / "scope_groups.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("scope_groups", module)
    spec.loader.exec_module(module)
    return module


def _declared_group(path, repo_root):
    """The group a test file declares for itself, or None."""
    full = Path(repo_root) / path
    if not full.is_file():
        return None
    sg = _load_scope_groups()
    if path.startswith("test/bats/smoke/") and path.endswith(".bats"):
        groups = sg.bats_file_groups(full)
        return groups[0] if len(groups) == 1 else None
    if (
        path.startswith(("test/unit/pytest/", "test/integration/pytest/"))
        and Path(path).name.startswith("test_")
        and path.endswith(".py")
    ):
        import ast

        groups = sg._module_groups(ast.parse(full.read_text()))
        return groups[0] if len(groups) == 1 else None
    return None


def classify(path, repo_root=_REPO_ROOT):
    """Groups one changed path belongs to (all five for a shared layer)."""
    if _matches(path, _SHARED):
        return set(GROUPS)
    declared = _declared_group(path, repo_root)
    if declared:
        return {declared}
    if _matches(path, _DOCS):
        return {"docs"}
    for group, patterns in _PATH_RULES:
        if _matches(path, patterns):
            return {group}
    return {"core"}


def _ordered(groups):
    return [g for g in GROUPS if g in groups]


def select(event, paths, dispatch_groups="", repo_root=_REPO_ROOT):
    """Ordered list of groups to run for this event and changed paths."""
    if event == "workflow_dispatch" and dispatch_groups.strip() not in ("", "all"):
        wanted = {g.strip() for g in dispatch_groups.split(",") if g.strip()}
        unknown = sorted(wanted - set(GROUPS))
        if unknown:
            raise ValueError(
                f"unknown group(s) {unknown}; choose from {', '.join(GROUPS)} or 'all'"
            )
        return _ordered(wanted | {"docs"})
    if event != "pull_request":
        return list(GROUPS)
    selected = {"docs"}
    for path in paths:
        if path.strip():
            selected |= classify(path.strip(), repo_root)
    return _ordered(selected)


def outputs(groups):
    """The ``$GITHUB_OUTPUT`` key/values for a selected group list."""
    chosen = set(groups)
    out = {"groups": ",".join(_ordered(chosen))}
    for g in GROUPS:
        out[g] = "true" if g in chosen else "false"
    out["build"] = "true" if chosen & {"core", *STAGE_GROUPS} else "false"
    out["stages"] = ",".join(g for g in STAGE_GROUPS if g in chosen)
    out["bats_skip"] = ",".join(g for g in GROUPS if g not in chosen)
    return out


def _git_paths(base, head):
    proc = subprocess.run(
        ["git", "diff", "--name-only", f"{base}...{head}"],
        capture_output=True,
        text=True,
        check=True,
    )
    return proc.stdout.splitlines()


def main():
    event = os.environ.get("EVENT_NAME", "")
    paths = []
    if event == "pull_request":
        paths = _git_paths(os.environ["BASE_SHA"], os.environ["HEAD_SHA"])
    try:
        groups = select(event, paths, os.environ.get("DISPATCH_GROUPS", ""))
    except ValueError as err:
        print(f"error: {err}", file=sys.stderr)
        return 2
    for key, value in outputs(groups).items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
