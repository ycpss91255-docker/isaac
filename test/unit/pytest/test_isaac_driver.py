"""Unit tests for ``script/isaac_driver.py`` -- pure-Python helpers.

These cover the host-runnable surface (``parse_livestream_env`` and
``resolve_repo_relative_usd``). The Kit-side lifecycle (``IsaacDriver.run``
walking through SimulationApp / open_stage / play_timeline / ...) is
covered by the integration test under ``test/integration/pytest/``.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "script"))

import isaac_driver as id_mod  # noqa: E402  (path injection before import)


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


# ---------- resolve_repo_relative_usd ----------


class TestResolveRepoRelativeUsd:
    def test_relative_path_resolves_under_repo_root(self, tmp_path):
        # Fake a script layout: repo_root/script/isaac_driver.py
        repo_root = tmp_path / "myrepo"
        script_dir = repo_root / "script"
        script_dir.mkdir(parents=True)
        fake_module = script_dir / "isaac_driver.py"
        fake_module.write_text("# stub")

        resolved = id_mod.resolve_repo_relative_usd(
            "model/usd/robot/foo/foo.usd",
            module_file=str(fake_module),
        )

        assert resolved == repo_root / "model/usd/robot/foo/foo.usd"

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
