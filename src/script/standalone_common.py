"""Shared pure helpers for the standalone driver scripts in ``src/script/``.

Import-safe on a host without Isaac Sim (no ``omni`` / ``pxr`` /
``isaacsim`` / ``rclpy`` import here), so the hosted unit tests can pin it
(``test/unit/pytest/test_standalone_scripts.py``).

Why these exist:

- ``run_and_exit``: ``SimulationApp.close()`` ends the process with
  ``_exit(0)``, and an exception raised at module top (for example a
  removed extension module) never reaches any handler. Both made a failed
  script exit 0. Scripts now build their ``SimulationApp`` inside ``main()``
  and hand ``main`` to ``run_and_exit``, which prints the traceback and
  exits 1 on any exception, skipping Kit's own teardown.
- ``kit_config``: the ``headless`` / ``stream`` Docker stages set
  ``ISAAC_LIVESTREAM`` (0 / 2); scripts follow it instead of hard-coding
  ``livestream: 2``.
- ``PeriodicTimer``: Kit's update rate depends on the stage, the renderer
  and the host load (measured 200-450 updates/s headless), so "every 60
  updates" is not "every second".
- ``openbase_usd_path``: paths are relative to this file, not
  ``/home/<one user>/work``.
"""

from __future__ import annotations

import os
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Callable, Dict, Optional

_SCRIPT_DIR = Path(__file__).resolve().parent
SRC_DIR = _SCRIPT_DIR.parent


def openbase_usd_path() -> Path:
    """Return the committed OpenBase USD, resolved from this checkout."""
    return SRC_DIR / "model" / "usd" / "robot" / "openbase" / "openbase.usda"


def kit_config(livestream_env: Optional[str]) -> Dict[str, Any]:
    """Map an ``ISAAC_LIVESTREAM`` value to ``SimulationApp`` kwargs.

    Args:
        livestream_env: ``None`` / ``""`` / ``"0"`` for headless, ``"2"``
            for WebRTC streaming.

    Returns:
        The config dict for ``SimulationApp``.

    Raises:
        ValueError: for any other value, so a typo fails at boot.
    """
    if livestream_env in (None, "", "0"):
        return {"headless": True}
    if livestream_env == "2":
        return {
            "headless": False,
            "livestream": 2,
            "renderer": "RaytracedLighting",
        }
    raise ValueError(
        f"unsupported ISAAC_LIVESTREAM value {livestream_env!r}; "
        "expected '', '0' or '2'"
    )


class PeriodicTimer:
    """Wall-clock gate: ``due()`` is True at most once per ``period_s``.

    After a stall longer than one period it fires once and re-arms from
    the current time instead of firing a burst to catch up.
    """

    def __init__(
        self, period_s: float, clock: Callable[[], float] = time.monotonic
    ) -> None:
        if period_s <= 0:
            raise ValueError("period_s must be > 0")
        self._period = period_s
        self._clock = clock
        self._next = clock() + period_s

    def due(self) -> bool:
        """Return True when a period has elapsed since the last fire."""
        now = self._clock()
        if now < self._next:
            return False
        self._next += self._period
        if self._next <= now:
            self._next = now + self._period
        return True


def run_and_exit(
    main: Callable[[], Optional[int]],
    exit_fn: Callable[[int], Any] = os._exit,
) -> None:
    """Run ``main`` and end the process with its exit code.

    Args:
        main: returns ``None`` / ``0`` on success or a non-zero code.
        exit_fn: process exit; ``os._exit`` by default, because Kit's own
            ``SimulationApp.close()`` would turn every outcome into 0 and
            can hang or abort in a cold container (isaac#248).
    """
    try:
        rc = main()
        code = 0 if rc is None else int(rc)
    except SystemExit as exc:
        if isinstance(exc.code, int):
            code = exc.code
        else:
            code = 0 if exc.code is None else 1
    except BaseException:  # noqa: BLE001 - every failure must be non-zero
        traceback.print_exc()
        code = 1
    sys.stdout.flush()
    sys.stderr.flush()
    exit_fn(code)


# OpenBase wheel joints: their drives are zeroed so the wheels spin freely
# and the base moves only through the velocity the scripts write.
OPENBASE_WHEELS = ("left_rim_joint", "back_rim_joint", "right_rim_joint")
OPENBASE_BASE_LINK = "/open_base/base_link"


def setup_openbase_stage(app: Any, usd_path: Path) -> Any:
    """Open the OpenBase USD and prepare it for planar velocity control.

    Isaac-side (function-local imports; call after ``SimulationApp``).
    Adds a light and Isaac's GroundPlane when missing, frees the wheel
    drives, and disables gravity on ``base_link``. The scripts overwrite the
    base velocity every step (Gazebo planar_move semantics: SE(2) motion,
    constant height). PhysX integrates gravity inside the step after that
    write, so with gravity on the base gained ``v.z = -0.16`` m/s every
    step and fell through the floor.

    Args:
        app: the running ``SimulationApp``.
        usd_path: the OpenBase USD to open.

    Returns:
        The opened ``Usd.Stage``.

    Raises:
        FileNotFoundError: the USD does not exist.
        RuntimeError: the stage did not open.
    """
    import omni.usd
    from pxr import PhysxSchema, UsdLux, UsdPhysics

    if not usd_path.is_file():
        raise FileNotFoundError(
            f"USD not found: {usd_path}\n"
            "Generate it with src/script/import_urdf.py first."
        )
    ctx = omni.usd.get_context()
    if not ctx.open_stage(str(usd_path)):
        raise RuntimeError(f"open_stage() returned False for {usd_path}")
    # open_stage is asynchronous in standalone mode: pump updates until the
    # stage is OPENED instead of touching a None stage.
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    else:
        raise RuntimeError("stage did not reach OPENED within 600 updates")
    stage = ctx.get_stage()
    print(f"[setup] opened {usd_path}", flush=True)

    if not stage.GetPrimAtPath("/World/SunLight").IsValid():
        UsdLux.DistantLight.Define(
            stage, "/World/SunLight"
        ).GetIntensityAttr().Set(3000.0)
    if not stage.GetPrimAtPath("/World/GroundPlane").IsValid():
        from isaacsim.core.api.objects.ground_plane import GroundPlane

        GroundPlane(prim_path="/World/GroundPlane", z_position=0, size=100)

    for prim in stage.Traverse():
        if prim.GetName() in OPENBASE_WHEELS:
            drive = UsdPhysics.DriveAPI.Get(prim, "angular")
            drive.GetStiffnessAttr().Set(0.0)
            drive.GetDampingAttr().Set(0.0)
            drive.GetTargetVelocityAttr().Set(0.0)

    base_prim = stage.GetPrimAtPath(OPENBASE_BASE_LINK)
    if not base_prim.IsValid():
        raise RuntimeError(f"{OPENBASE_BASE_LINK} not found in {usd_path}")
    physx_body = PhysxSchema.PhysxRigidBodyAPI.Apply(base_prim)
    physx_body.GetDisableGravityAttr().Set(True)
    print("[setup] wheels freed, base_link gravity disabled", flush=True)
    return stage
