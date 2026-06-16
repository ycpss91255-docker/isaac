"""IsaacDriver base class -- lifecycle-only pattern (ADR-0009).

Subclass contract:

    from isaac_devkit.driver import IsaacDriver

    class MyDriver(IsaacDriver):
        USD = "model/usd/robot/openbase/openbase.usd"  # repo-relative

        def setup(self, stage):
            self.init_rclpy()                          # optional
            # create publishers, attach OmniGraph, etc.

        def main(self):
            while not self._should_quit and self._app.is_running():
                # per-tick work
                self._sim.step()

        def shutdown(self):
            # release rclpy node, close files, etc.
            pass

    if __name__ == "__main__":
        MyDriver().run()

The base class owns the Kit init (Isaac Lab ``AppLauncher``) / signal
handling / stage open / scene defaults / ``SimulationContext`` start /
shutdown lifecycle. The subclass owns the main loop -- this matches the
IsaacLab / Isaac Sim standalone / Gymnasium / PyBullet pattern (ADR-0009),
now realized on Isaac Lab's own primitives (ADR-0018).

This module is import-safe without Isaac Sim available: the pure-Python
helpers (``parse_livestream_env``, ``parse_livestream_applauncher``,
``resolve_repo_relative_usd``) can be unit-tested on the host. The
Kit-side imports (``isaaclab``, ``isaacsim``, ``omni.*``, ``pxr``) are
deferred into the ``IsaacDriver.run`` body and friends so that
constructing the class outside Kit does not raise.
"""

from __future__ import annotations

import os
import signal
import sys
from pathlib import Path
from typing import Any, Dict, Optional


# ---------------------------------------------------------------------------
# Pure-Python helpers (host-runnable, no Isaac Sim dependency).
# ---------------------------------------------------------------------------


def parse_livestream_env(env_value: Optional[str]) -> Dict[str, Any]:
    """Translate the ``ISAAC_LIVESTREAM`` env value into SimulationApp kwargs.

    Values follow the docker stage convention introduced in
    `ycpss91255-docker/isaac#28`:

    - unset / empty / ``"0"`` -> headless, no streaming. Used by the
      ``headless`` Docker stage where Kit boots without a window or
      WebRTC publisher.
    - ``"1"`` -> native streaming. Kit's legacy streaming protocol.
    - ``"2"`` -> WebRTC streaming, raytraced lighting. Pairs with the
      ``headless-stream`` Docker stage and ADR-0007's custom Kit
      experience (`isaacsim.exp.base.python.streaming.kit`).

    Raising on unknown values rather than silently defaulting catches
    typos in compose / .env files at boot time instead of producing a
    confused-looking idle container.
    """
    if env_value is None or env_value == "" or env_value == "0":
        return {"headless": True}
    if env_value == "1":
        return {"headless": False, "livestream": 1}
    if env_value == "2":
        return {
            "headless": False,
            "livestream": 2,
            "renderer": "RaytracedLighting",
        }
    raise ValueError(
        f"unsupported ISAAC_LIVESTREAM value {env_value!r}; "
        "expected one of '', '0', '1', '2'"
    )


def parse_livestream_applauncher(env_value: Optional[str]) -> Dict[str, Any]:
    """Translate ``ISAAC_LIVESTREAM`` into Isaac Lab ``AppLauncher`` args.

    ADR-0018: the driver launches via Isaac Lab ``AppLauncher`` instead of
    a raw ``SimulationApp``. ``AppLauncher`` takes ``headless`` /
    ``livestream`` / ``enable_cameras`` (its ``HEADLESS`` / ``LIVESTREAM``
    env-var convention), so the existing ``ISAAC_LIVESTREAM`` (0/1/2)
    mapping is preserved through this helper:

    - unset / empty / ``"0"`` -> headless, no streaming.
    - ``"1"`` -> native streaming (livestream supersedes + forces headless).
    - ``"2"`` -> WebRTC streaming.

    ``enable_cameras=True`` is set in every mode so cameras render even
    headless -- the ROS 2 camera publish chain needs rendered frames (the
    headless+enable_cameras path the GPU integration relies on; cf. Isaac
    Lab issue #3250). Unknown values raise, same as ``parse_livestream_env``.
    """
    if env_value is None or env_value == "" or env_value == "0":
        return {"headless": True, "enable_cameras": True}
    if env_value == "1":
        return {"headless": True, "livestream": 1, "enable_cameras": True}
    if env_value == "2":
        return {"headless": True, "livestream": 2, "enable_cameras": True}
    raise ValueError(
        f"unsupported ISAAC_LIVESTREAM value {env_value!r}; "
        "expected one of '', '0', '1', '2'"
    )


def resolve_repo_relative_usd(usd_path: str, *, module_file: str) -> Path:
    """Resolve a repo-relative USD path to an absolute ``Path``.

    Subclasses declare ``USD = "model/usd/robot/openbase/openbase.usd"``
    so that the path travels with the repo and does not bake in a
    container mount point. The resolution uses the module's filesystem
    location: ``framework/isaac_devkit/driver.py`` lives two levels under
    the repo root, so ``parents[2]`` of that module's file is the repo
    root. Models live under ``<repo_root>/src`` (e.g. ``src/model/usd/``),
    so resolution anchors at ``<repo_root>/src`` -- the same directory the
    pre-extraction ``src/script/isaac_driver.py`` resolved against via its
    ``parents[1]``, keeping the repo-relative ``USD`` convention intact
    across the move.

    Absolute paths are returned unchanged so that ad-hoc tests can point
    at a fixture USD outside the repo without subclassing the resolver.
    """
    if not usd_path:
        raise ValueError(
            "USD class attribute is required; subclass must set it to a "
            "repo-relative path (e.g. 'model/usd/robot/openbase/openbase.usd')"
        )
    p = Path(usd_path)
    if p.is_absolute():
        return p
    # framework/isaac_devkit/driver.py -> parents[2] = repo root; models
    # live under <repo_root>/src (the old anchor directory).
    repo_root = Path(module_file).resolve().parents[2]
    return repo_root / "src" / usd_path


# ---------------------------------------------------------------------------
# Lifecycle base class.
# ---------------------------------------------------------------------------


class IsaacDriver:
    """Lifecycle-only base class for Isaac Sim standalone drivers (ADR-0009).

    Class attributes:
        ``USD`` -- repo-relative path to the USD that ``run()`` opens
        after Kit boots. Deprecated in favor of ``SCENE`` (ADR-0017
        section 9); kept functional for the existing drivers until the
        forklift migration (#136). Subclass must set this for now.
        ``SCENE`` -- repo-relative path to a scene YAML (ADR-0017 A7
        contract surface). Declared for the new contract shape; ``run()``
        is rewired to the ``load_scene -> build_scene -> setup_sensors ->
        setup_ros2_io`` lifecycle with the example (#131).

    Override surface:
        ``setup(stage)`` -- post-stage-open init (rclpy, publishers, OG).
        ``main()``        -- the loop. Default: ``app.update()`` until
                             ``_should_quit`` flips or Kit reports
                             ``is_running()`` is False.
        ``shutdown()``    -- pre-close cleanup (destroy rclpy node, etc.).

    Helpers:
        ``init_rclpy()``  -- safe rclpy init that suppresses rclpy's own
                             signal handler so it does not race Kit's +
                             ours into a 3-way SIGINT segfault.

    Internals (subclass should not override):
        ``_on_signal``, ``_open_stage``, ``_ensure_scene_defaults``,
        ``_start_sim`` -- pieces of the ``run()`` recipe.
    """

    USD: str = ""
    SCENE: str = ""

    def __init__(self) -> None:
        self._should_quit: bool = False
        self._app: Any = None
        self._app_launcher: Any = None
        self._sim: Any = None
        self._rclpy_inited: bool = False

    # -- Entry point ---------------------------------------------------------

    def run(self) -> None:
        """Walk the lifecycle: init Kit, open stage, set up, loop, shut down.

        Order matters (ADR-0018): Isaac Lab ``AppLauncher`` must be the
        *first* Isaac Sim construction, before any ``omni.*`` / ``pxr`` /
        ``isaaclab.sim`` import resolves; the signal handler override must
        come *after* it because Kit installs its own SIGINT trap during
        construction. ``AppLauncher.app`` is the ``SimulationApp`` instance,
        so ``is_running`` / ``update`` / ``close`` keep working.
        """
        from isaaclab.app import AppLauncher

        launcher_args = parse_livestream_applauncher(
            os.environ.get("ISAAC_LIVESTREAM")
        )
        self._app_launcher = AppLauncher(launcher_args)
        self._app = self._app_launcher.app

        # Override Kit's SIGINT (which swallows Ctrl+C) so the loop can
        # observe ``_should_quit`` and break out cleanly.
        signal.signal(signal.SIGINT, self._on_signal)
        signal.signal(signal.SIGTERM, self._on_signal)

        try:
            stage = self._open_stage()
            self._ensure_scene_defaults(stage)
            self._start_sim()
            self.setup(stage)
            self.main()
            self.shutdown()
        finally:
            # SimulationApp.close() (via AppLauncher.app) forces process
            # _exit(0) on its way out and overrides any sys.exit(N)
            # downstream. Subclasses that want to signal failure must do so
            # before calling super().run() or via stdout markers.
            sys.stdout.flush()
            sys.stderr.flush()
            self._app.close()

    # -- Subclass hooks ------------------------------------------------------

    def setup(self, stage: Any) -> None:
        """Post-stage-open hook. Default is a no-op."""

    def main(self) -> None:
        """Main loop. Default steps the SimulationContext until quit/stop."""
        while not self._should_quit and self._app.is_running():
            self._sim.step()

    def shutdown(self) -> None:
        """Pre-close cleanup hook. Default is a no-op."""

    # -- ROS 2 helper --------------------------------------------------------

    def init_rclpy(self) -> None:
        """Initialise rclpy without registering its signal handlers.

        Isaac Sim's Kit installs SIGINT/SIGTERM during SimulationApp
        construction; we then install our own. rclpy.init() also wants
        to install handlers by default, and the 3-way race triggers
        segfaults during driver shutdown. ``SignalHandlerOptions.NO``
        keeps rclpy clean and lets Kit + our handler co-exist.
        """
        if self._rclpy_inited:
            return
        import rclpy
        from rclpy.signals import SignalHandlerOptions

        rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
        self._rclpy_inited = True

    # -- Internals -----------------------------------------------------------

    def _on_signal(self, signum: int, _frame: Any) -> None:
        print(
            f"[isaac_driver] signal {signum} received; requesting shutdown",
            flush=True,
        )
        self._should_quit = True

    def _open_stage(self) -> Any:
        import omni.usd

        abs_path = resolve_repo_relative_usd(self.USD, module_file=__file__)
        ctx = omni.usd.get_context()
        if not ctx.open_stage(str(abs_path)):
            raise RuntimeError(
                f"open_stage returned False for {abs_path}; check the path "
                "is reachable from inside the container"
            )
        # Wait for the open to settle. 600 ticks ~= 10 s at 60 Hz which
        # covers Asset Structure 3.0 imports with sublayer chains.
        for _ in range(600):
            if ctx.get_stage_state() == omni.usd.StageState.OPENED:
                break
            self._app.update()
        else:
            raise RuntimeError(f"stage at {abs_path} never reached OPENED")
        return ctx.get_stage()

    def _ensure_scene_defaults(self, stage: Any) -> None:
        """Add a SunLight if the USD does not bring its own (opt-out).

        ADR-0009 calls for a SunLight + GroundPlane default. GroundPlane
        creation through ``omni.kit.commands.CreateGroundPlane`` is
        Kit-version-sensitive and deferred to a follow-up; SunLight via
        ``UsdLux.DistantLight`` is stable across 5.x and is enough to
        keep viewport-less debug renders readable.
        """
        from pxr import UsdLux

        if not stage.GetPrimAtPath("/World/SunLight").IsValid():
            UsdLux.DistantLight.Define(stage, "/World/SunLight")

    def _start_sim(self) -> None:
        """Create the Isaac Lab SimulationContext over the open stage, reset.

        ADR-0018: replaces the raw ``omni.timeline`` play with Isaac Lab's
        ``SimulationContext`` -- the loop manager an ``InteractiveScene``
        ("C") pairs with -- so the default ``main()`` steps via
        ``sim.step()`` and a later move to ``InteractiveScene`` is small.
        ``reset()`` plays the timeline and initialises the physics handles.
        A handful of warmup ticks then lets physx settle so ``setup()``
        sees a stable stage.
        """
        from isaaclab.sim import SimulationCfg, SimulationContext

        self._sim = SimulationContext(SimulationCfg())
        self._sim.reset()
        for _ in range(10):
            self._app.update()
