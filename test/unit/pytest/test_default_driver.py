"""Unit tests for ``isaac_devkit.default_driver`` (isaac#336 part 3).

``DefaultSceneDriver`` is what a scene launch uses when the config names
no user driver: open the stage from the scene, play the timeline, tick
``app.update()``. These tests cover the host-pure surface and the
lifecycle order with fake Kit modules; the live-Kit path is GPU-covered.
"""

import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))

from isaac_devkit import default_driver as dd  # noqa: E402
from isaac_devkit import driver as id_mod  # noqa: E402


class TestConstruction:
    def test_is_an_isaac_driver(self):
        assert issubclass(dd.DefaultSceneDriver, id_mod.IsaacDriver)

    def test_requires_a_scene_path(self):
        with pytest.raises(ValueError):
            dd.DefaultSceneDriver("")

    def test_keeps_scene_path(self, tmp_path):
        d = dd.DefaultSceneDriver(tmp_path / "scene.yaml")
        assert d.scene_path == tmp_path / "scene.yaml"

    def test_repo_root_override(self, tmp_path):
        d = dd.DefaultSceneDriver("s.yaml", repo_root=tmp_path)
        assert d.repo_root == tmp_path

    def test_adds_no_custom_logic(self):
        # Default driver = base lifecycle only: no setup/main/shutdown
        # override, so the loop is the base "tick app.update()" loop.
        for name in ("setup", "main", "shutdown"):
            assert getattr(dd.DefaultSceneDriver, name) is getattr(
                id_mod.IsaacDriver, name
            )


class TestOpenStage:
    def test_loads_scene_then_builds_on_new_stage(self, monkeypatch):
        calls = []
        scene = {"robot": {}}
        stage = object()

        monkeypatch.setattr(
            dd, "load_scene",
            lambda path, root: calls.append(("load", path, root)) or scene,
        )
        monkeypatch.setattr(
            dd, "build_scene",
            lambda s, st, root: calls.append(("build", s, st, root)),
        )

        class _D(dd.DefaultSceneDriver):
            def _new_stage(self):
                calls.append(("new_stage",))
                return stage

        d = _D("scene.yaml", repo_root=Path("/r"))
        assert d._open_stage() is stage
        assert calls == [
            ("load", Path("scene.yaml"), Path("/r")),
            ("new_stage",),
            ("build", scene, stage, Path("/r")),
        ]


class TestRunLifecycle:
    def test_run_opens_plays_ticks_closes(self, monkeypatch):
        calls = []
        pkg = types.ModuleType("isaaclab")
        pkg.__path__ = []
        app_mod = types.ModuleType("isaaclab.app")

        class _App:
            ticks = 0

            def is_running(self):
                return _App.ticks < 3

            def update(self):
                _App.ticks += 1
                calls.append("update")

            def close(self):
                calls.append("close")

        class _Launcher:
            def __init__(self, _args):
                self.app = _App()

        app_mod.AppLauncher = _Launcher
        monkeypatch.setitem(sys.modules, "isaaclab", pkg)
        monkeypatch.setitem(sys.modules, "isaaclab.app", app_mod)
        monkeypatch.delenv("ISAAC_LIVESTREAM", raising=False)
        monkeypatch.setattr(id_mod.signal, "signal", lambda *_a: None)

        class _D(dd.DefaultSceneDriver):
            def _open_stage(self):
                calls.append("open_stage")
                return object()

            def _ensure_scene_defaults(self, stage):
                calls.append("defaults")

            def _play_timeline(self):
                calls.append("play")

        _D("scene.yaml").run()
        assert calls == [
            "open_stage", "defaults", "play",
            "update", "update", "update", "close",
        ]


def test_import_is_kit_free():
    for mod in ("omni", "pxr", "isaacsim"):
        assert mod not in sys.modules
