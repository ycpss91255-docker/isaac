"""Unit tests for ``isaac_devkit.driver`` -- pure-Python helpers.

These cover the host-runnable surface (``parse_livestream_env`` and
``resolve_repo_relative_usd``). The Kit-side lifecycle (``IsaacDriver.run``
walking through SimulationApp / open_stage / play_timeline / ...) is
covered by the integration test under ``test/integration/pytest/``; the
pure side of the lifecycle ORDER is covered hosted by the spy test at
the bottom of this file (ADR-0017 section 7 greenfield addition).
"""

import sys
import types
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))

from isaac_devkit import driver as id_mod  # noqa: E402  (path injection before import)


# ---------- parse_livestream_env ----------


class TestParseLivestreamEnv:
    def test_unset_returns_headless(self):
        assert id_mod.parse_livestream_env(None) == {"headless": True}

    def test_empty_string_returns_headless(self):
        assert id_mod.parse_livestream_env("") == {"headless": True}

    def test_zero_returns_headless(self):
        assert id_mod.parse_livestream_env("0") == {"headless": True}

    def test_one_returns_native_livestream(self):
        cfg = id_mod.parse_livestream_env("1")
        assert cfg == {"headless": False, "livestream": 1}

    def test_two_returns_webrtc_with_raytracing(self):
        cfg = id_mod.parse_livestream_env("2")
        assert cfg == {
            "headless": False,
            "livestream": 2,
            "renderer": "RaytracedLighting",
        }

    def test_unknown_value_raises(self):
        with pytest.raises(ValueError) as ei:
            id_mod.parse_livestream_env("3")
        assert "'3'" in str(ei.value)
        # Lists the accepted values so a misconfigured compose file is
        # obvious at boot time.
        assert "'0'" in str(ei.value) or "'1'" in str(ei.value)

    def test_garbage_value_raises(self):
        with pytest.raises(ValueError):
            id_mod.parse_livestream_env("yes")


# ---------- parse_livestream_applauncher (ADR-0018) ----------


class TestParseLivestreamApplauncher:
    """The ADR-0018 AppLauncher-args variant. Mirrors the ISAAC_LIVESTREAM
    0/1/2 mapping but emits Isaac Lab AppLauncher kwargs (headless /
    livestream / enable_cameras), with enable_cameras always on so cameras
    render headless for the ROS 2 publish chain.
    """

    def test_unset_returns_headless_cameras(self):
        assert id_mod.parse_livestream_applauncher(None) == {
            "headless": True,
            "enable_cameras": True,
        }

    def test_empty_string_returns_headless_cameras(self):
        assert id_mod.parse_livestream_applauncher("") == {
            "headless": True,
            "enable_cameras": True,
        }

    def test_zero_returns_headless_cameras(self):
        assert id_mod.parse_livestream_applauncher("0") == {
            "headless": True,
            "enable_cameras": True,
        }

    def test_one_returns_native_livestream(self):
        assert id_mod.parse_livestream_applauncher("1") == {
            "headless": True,
            "livestream": 1,
            "enable_cameras": True,
        }

    def test_two_returns_webrtc_livestream(self):
        assert id_mod.parse_livestream_applauncher("2") == {
            "headless": True,
            "livestream": 2,
            "enable_cameras": True,
        }

    def test_enable_cameras_always_on(self):
        for value in (None, "", "0", "1", "2"):
            assert id_mod.parse_livestream_applauncher(value)["enable_cameras"] is True

    def test_unknown_value_raises(self):
        with pytest.raises(ValueError) as ei:
            id_mod.parse_livestream_applauncher("3")
        assert "'3'" in str(ei.value)

    def test_garbage_value_raises(self):
        with pytest.raises(ValueError):
            id_mod.parse_livestream_applauncher("yes")


# ---------- resolve_repo_relative_usd ----------


class TestResolveRepoRelativeUsd:
    def test_relative_path_resolves_under_repo_root(self, tmp_path):
        # Fake a framework layout: repo_root/framework/isaac_devkit/driver.py.
        # Models live under <repo_root>/src, so resolution anchors there
        # (same directory the pre-extraction script/ layout resolved to).
        repo_root = tmp_path / "myrepo"
        module_dir = repo_root / "framework" / "isaac_devkit"
        module_dir.mkdir(parents=True)
        fake_module = module_dir / "driver.py"
        fake_module.write_text("# stub")

        resolved = id_mod.resolve_repo_relative_usd(
            "model/usd/robot/foo/foo.usd",
            module_file=str(fake_module),
        )

        assert resolved == repo_root / "src" / "model/usd/robot/foo/foo.usd"

    def test_absolute_path_returned_unchanged(self, tmp_path):
        abs_usd = tmp_path / "anywhere" / "fixture.usda"
        resolved = id_mod.resolve_repo_relative_usd(
            str(abs_usd),
            module_file=__file__,  # value irrelevant for absolute path
        )
        assert resolved == abs_usd

    def test_empty_string_raises(self):
        with pytest.raises(ValueError) as ei:
            id_mod.resolve_repo_relative_usd("", module_file=__file__)
        assert "USD" in str(ei.value)

    def test_subclass_forgot_to_set_usd_raises(self):
        # Mirrors the "subclass forgot to set USD" failure mode -- the
        # class attribute defaults to "" so resolve sees an empty path.
        default_usd_value = id_mod.IsaacDriver.USD
        with pytest.raises(ValueError):
            id_mod.resolve_repo_relative_usd(
                default_usd_value, module_file=__file__,
            )


# ---------- Construction without Kit ----------


class TestConstructionWithoutKit:
    """The class must be import-safe and constructible on the host so
    unit tests can poke at attribute defaults without booting Isaac Sim.
    Kit-touching code is deferred into ``run`` and friends.
    """

    def test_default_attrs(self):
        driver = id_mod.IsaacDriver()
        assert driver._should_quit is False
        assert driver._app is None
        assert driver._rclpy_inited is False

    def test_default_usd_is_empty(self):
        assert id_mod.IsaacDriver.USD == ""

    def test_signal_handler_flips_quit_flag(self):
        # Exercises the pure side of the SIGINT path without installing
        # the handler globally.
        driver = id_mod.IsaacDriver()
        assert driver._should_quit is False
        driver._on_signal(2, None)  # SIGINT
        assert driver._should_quit is True


# ---------- A7 contract shape + lifecycle-order spy (ADR-0017 additions) ----


class TestSceneAttrShape:
    """``SCENE`` class attr (ADR-0017 section 9 A7 shape). Greenfield
    addition -- ``run()`` still consumes ``USD``; the SCENE-driven
    lifecycle rewire lands with the example (#131).
    """

    def test_default_scene_is_empty(self):
        assert id_mod.IsaacDriver.SCENE == ""


class TestLifecycleOrderSpy:
    """Hosted pure-side spy on ``IsaacDriver.run()`` call order
    (ADR-0017 section 7: lifecycle call order is verified hosted via a
    pure-side spy). Greenfield addition on top of the ported baseline.

    Fake ``isaaclab`` / ``isaaclab.app`` modules are injected so ``run()``'s
    function-local ``from isaaclab.app import AppLauncher`` resolves on the
    host (ADR-0018); the Kit-touching internals are overridden with
    recorders. ``monkeypatch`` restores ``sys.modules`` and
    ``signal.signal`` afterwards, keeping the import-safety invariant
    intact for siblings.
    """

    @staticmethod
    def _fake_isaaclab_app(calls):
        # Parent package stub so ``from isaaclab.app import AppLauncher``
        # resolves the parent before the submodule.
        pkg = types.ModuleType("isaaclab")
        pkg.__path__ = []  # mark as a package
        app_mod = types.ModuleType("isaaclab.app")

        class _FakeApp:
            def is_running(self):
                return False

            def update(self):
                pass

            def close(self):
                calls.append("close")

        class _FakeLauncher:
            def __init__(self, _args):
                calls.append("app_launcher")
                self.app = _FakeApp()

        app_mod.AppLauncher = _FakeLauncher
        return pkg, app_mod

    def test_run_walks_lifecycle_in_order(self, monkeypatch):
        calls = []
        pkg, app_mod = self._fake_isaaclab_app(calls)
        monkeypatch.setitem(sys.modules, "isaaclab", pkg)
        monkeypatch.setitem(sys.modules, "isaaclab.app", app_mod)
        monkeypatch.delenv("ISAAC_LIVESTREAM", raising=False)
        # Do not install real process-wide handlers from inside a test.
        monkeypatch.setattr(id_mod.signal, "signal", lambda *_args: None)

        class _SpyDriver(id_mod.IsaacDriver):
            USD = "model/usd/robot/foo/foo.usd"

            def _open_stage(self):
                calls.append("open_stage")
                return object()

            def _ensure_scene_defaults(self, stage):
                calls.append("ensure_scene_defaults")

            def _play_timeline(self):
                calls.append("play_timeline")

            def setup(self, stage):
                calls.append("setup")

            def main(self):
                calls.append("main")

            def shutdown(self):
                calls.append("shutdown")

        _SpyDriver().run()

        assert calls == [
            "app_launcher",
            "open_stage",
            "ensure_scene_defaults",
            "play_timeline",
            "setup",
            "main",
            "shutdown",
            "close",
        ]
