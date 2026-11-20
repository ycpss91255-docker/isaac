"""pytest plugin: every collected test belongs to exactly one scope group.

CI runs per scope (isaac#434): ``pytest -m stream`` must collect the stream
tests and nothing else. A test with no group would be selected by no scoped
job; a test with two would run twice. Both abort collection here, so an
ungrouped test is a red build, not a silently skipped one.

Loaded by the ``conftest.py`` next to each test directory (the two are tiny
shims, because pytest only finds a conftest at or below the rootdir it picks
from the command-line paths). The group is declared per module::

    pytestmark = pytest.mark.core

Keep ``GROUPS`` equal to ``script/ci/scope_groups.py``; a hosted test pins it.
"""

import pytest

GROUPS = ("core", "gui", "stream", "headless", "docs")

_DESCRIPTIONS = {
    "core": "framework, shared Docker layers, shared scripts and CI tooling",
    "gui": "the gui stage",
    "stream": "the stream stage and the WebRTC livestream",
    "headless": "the headless stage",
    "docs": "documentation and commit lint checks",
}


def pytest_configure(config):
    for group in GROUPS:
        config.addinivalue_line("markers", f"{group}: {_DESCRIPTIONS[group]}")


def pytest_collection_modifyitems(config, items):
    bad = []
    for item in items:
        groups = {m.name for m in item.iter_markers() if m.name in GROUPS}
        if len(groups) != 1:
            bad.append(f"  {item.nodeid}: {sorted(groups) or 'no group'}")
    if bad:
        raise pytest.UsageError(
            "every test must belong to exactly one group "
            f"({', '.join(GROUPS)}); set `pytestmark = pytest.mark.<group>` "
            "at module level:\n" + "\n".join(bad)
        )
