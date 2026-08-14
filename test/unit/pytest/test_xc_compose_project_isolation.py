"""Hosted guard: the cross-container round-trip owns a DEDICATED compose project.

Regression guard for ycpss91255-docker/omniverse_web_viewer#55 (isaac-side
root cause). ``test_cross_container_roundtrip`` runs the Isaac runner via
``docker compose -p <COMPOSE_PROJECT> run --rm ...``; its teardown tears down
that whole compose project (``docker compose -p <project> down`` /
``run.sh`` EXIT ``_app_cleanup`` / ``stop.sh`` ``_compose_project down
--remove-orphans``). If ``COMPOSE_PROJECT`` coincides with the DEFAULT manual
stream stack's compose project -- ``${DOCKER_HUB_USER}-${IMAGE_NAME}`` (e.g.
``yunchien-isaac``, from ``compose.yaml`` ``name:``) -- then a CI cross-container
run (or its cleanup) removes EVERY container in that project, killing a
long-lived, manually-run ``stream`` container it never intended to touch.

The fix is a DEDICATED default project name distinct from any real stream
stack. Note that *deriving* the default from ``.env.generated``
(``${DOCKER_HUB_USER}-${IMAGE_NAME}``) -- as floated in the owv#55 thread --
would STILL resolve to ``yunchien-isaac`` and therefore still coincide with the
default stream stack, giving no isolation. Only a distinct name restores the
invariant. ``XC_COMPOSE_PROJECT`` remains an override seam for CI to inject a
per-run-unique project when it wants concurrency isolation.

Hosted tier: no docker, no GPU. The integration module imports cleanly on a
non-docker host (its ``requires_xc`` skip marker resolves ``docker`` absent via
``shutil.which`` without spawning anything), so this reads the REAL module-level
``COMPOSE_PROJECT`` default rather than a copy.
"""

import importlib.util
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
XC_MODULE_PATH = (
    REPO_ROOT
    / "test"
    / "integration"
    / "pytest"
    / "test_cross_container_roundtrip.py"
)

DEDICATED_PROJECT = "xc-isaac-roundtrip"
# The default manual stream stack's compose project (compose.yaml `name:` ->
# ${DOCKER_HUB_USER}-${IMAGE_NAME}). The cross-container test must NOT default
# to this, nor to anything a `${user}-${image}` derivation would produce.
STREAM_STACK_PROJECT = "yunchien-isaac"


def _load_xc_default(monkeypatch) -> str:
    """Import the integration module with XC_COMPOSE_PROJECT unset and return
    its module-level ``COMPOSE_PROJECT`` default (the real code, freshly
    executed so the env override cannot leak in)."""
    monkeypatch.delenv("XC_COMPOSE_PROJECT", raising=False)
    spec = importlib.util.spec_from_file_location(
        "xc_roundtrip_under_test", XC_MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.COMPOSE_PROJECT


def test_default_compose_project_is_the_dedicated_one(monkeypatch):
    """With no override, the default is the dedicated ``xc-isaac-roundtrip``."""
    assert _load_xc_default(monkeypatch) == DEDICATED_PROJECT


def test_default_compose_project_is_isolated_from_the_stream_stack(monkeypatch):
    """The default is distinct from any real stream-stack compose project.

    Asserts the ISOLATION INTENT, not just the literal: it must not equal the
    default stream stack (``yunchien-isaac``) and must not equal a
    ``${DOCKER_HUB_USER}-${IMAGE_NAME}``-style derivation (which would still
    coincide with the stream stack and defeat the fix).
    """
    default = _load_xc_default(monkeypatch)
    assert default != STREAM_STACK_PROJECT
    # A `${user}-${image}` derivation for this repo would resolve to
    # `yunchien-isaac`; guard against any such coinciding default.
    for user in ("yunchien", "alice"):
        assert default != f"{user}-isaac"


def test_xc_compose_project_env_override_still_wins(monkeypatch):
    """The override seam is intact: XC_COMPOSE_PROJECT sets the project."""
    monkeypatch.setenv("XC_COMPOSE_PROJECT", "xc-ci-run-1234")
    spec = importlib.util.spec_from_file_location(
        "xc_roundtrip_under_test_override", XC_MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.COMPOSE_PROJECT == "xc-ci-run-1234"
