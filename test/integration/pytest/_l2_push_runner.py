"""Kit-side runner: an L2 KINEMATIC mover pushes a SEPARATE dynamic box
(#201, milestone "Physics: L2 true-kinematic + hybrid").

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp``, opens the push fixture
(``test/fixtures/usd/l2_push.usda``: a KINEMATIC mover at x=-1.0 + a DYNAMIC
5 kg box in its path at x=0.0 + a static ground + a static wall at x=+1.2 +
a gravity ``PhysicsScene``), plays ``omni.timeline`` and steps with
``app.update()`` (NEVER a ``SimulationContext`` -- the #151 shutdown-hang
surface), then drives the kinematic mover HORIZONTALLY along +X into the box
in fixed per-tick steps (``--ramp-step`` metres).

The contact-respecting kinematic write path (ADR-0008):

  * ``dc.set_kinematic_target`` (``setKinematicTarget``) where this dc build
    exposes it, else a USD ``xformOp:translate`` write on the kinematicEnabled
    prim WHILE physics plays -- both feed the kinematic TARGET through the
    contact solver, so the mover PUSHES the box. (This Isaac Sim build's
    dynamic_control does NOT ship ``set_kinematic_target``, so the USD path is
    used -- the proven #201 carry-speed mechanism, green on the GPU runner in
    PR #218.) A plain ``dc.set_rigid_body_pose`` teleport (``setGlobalPose``)
    BYPASSES contact and does NOT push, so it is not used. The per-tick step
    must be SMALL so contact transfers each tick (a large step outruns the
    contact solver -- the same carry-speed caveat as the #201 carry
    experiment).

Horizontal push is deliberately chosen over a vertical carry: it does not
fight gravity through the contact, so it is far less sensitive to the per-tick
speed limit.

Two modes (``--mode``):

  * ``push`` -- drive the mover to ``--target-x`` (short of the wall). Assert
    the box was displaced (momentum transfer) and the mover landed on its
    COMMANDED path (a kinematic body ignores the reaction force).
  * ``squish`` -- drive the mover further so the box is pinned between the
    mover and the static wall. The box stops at the wall (cannot move past
    it) and stays finite/settled.

Every ``isaacsim`` / ``omni`` / ``pxr`` import is FUNCTION-LOCAL so the file
stays host-importable (``python3 -m py_compile`` passes without Isaac).

Marker line::

    [PUSH SUMMARY] mode=<s> drive=<s> ramp_step=<f> target_x=<f> \
        mover_x=<f> box_x0=<f> box_x=<f> box_disp=<f> mover_err=<f> \
        box_finite=<bool> wall_x=<f>
    [EXIT CLEAN]

On exception::

    [RAISED] <type>: <msg>
    [TRACEBACK]
    <traceback>
"""

import argparse
import math
import sys
from pathlib import Path

WALL_X = 1.2          # matches l2_push.usda /World/Wall translate x.
BOX_HALF = 0.15       # box scale 0.3 -> half-extent 0.15.
MOVER_HALF_X = 0.15   # mover scale x 0.3 -> half-extent 0.15.


def _open_stage(app, usd_path: str):
    """Open ``usd_path`` and update until the stage reaches OPENED."""
    import omni.usd

    ctx = omni.usd.get_context()
    if not ctx.open_stage(usd_path):
        raise RuntimeError(f"open_stage returned False for {usd_path}")
    for _ in range(600):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    else:
        raise RuntimeError("stage did not reach OPENED")
    return ctx.get_stage()


def _get_body(iface, prim_path: str):
    """Acquire a dc rigid-body handle, raising on INVALID_HANDLE."""
    from omni.isaac.dynamic_control import _dynamic_control as dc

    handle = iface.get_rigid_body(prim_path)
    if handle == dc.INVALID_HANDLE:
        raise RuntimeError(f"dc.get_rigid_body({prim_path}) INVALID_HANDLE")
    return handle


def _set_translate(stage, prim_path, x, y, z):
    """Set the prim's ``xformOp:translate`` to (x, y, z) on the USD stage.

    While physics plays, writing a kinematicEnabled body's transform through
    the USD stage is the contact-respecting kinematic TARGET write: PhysX reads
    the new target and interpolates the body to it across the substep,
    resolving contact (so a dynamic box in its path is PUSHED via contact).
    This is the ``setKinematicTarget`` equivalent when the dynamic_control
    build exposes no ``set_kinematic_target`` method -- the proven path from
    the #201 carry-speed experiment (PR #218, green on the GPU runner).
    """
    from pxr import Gf, UsdGeom

    prim = stage.GetPrimAtPath(prim_path)
    xform = UsdGeom.Xformable(prim)
    translate_op = None
    for op in xform.GetOrderedXformOps():
        if op.GetOpType() == UsdGeom.XformOp.TypeTranslate:
            translate_op = op
            break
    if translate_op is None:
        translate_op = xform.AddTranslateOp()
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))


def _drive_kinematic(iface, handle, stage, prim_path, x, y, z):
    """Advance the kinematic mover toward (x, y, z) via the contact-respecting
    kinematic TARGET write (ADR-0008).

    Use ``dc.set_kinematic_target`` if this dc build exposes it, else fall back
    to a USD ``xformOp:translate`` write on the stage (both feed the target
    through the contact solver so the mover pushes the box). A plain
    ``set_rigid_body_pose`` teleport would bypass contact and NOT push -- so it
    is not used.
    """
    if hasattr(iface, "set_kinematic_target"):
        from omni.isaac.dynamic_control import _dynamic_control as dc

        target = dc.Transform()
        target.r = (0.0, 0.0, 0.0, 1.0)
        target.p = (x, y, z)
        iface.set_kinematic_target(handle, target)
    else:
        _set_translate(stage, prim_path, x, y, z)


def _seat(app, iface, handle, stage, prim_path, x, y, z, ticks):
    """Hold the mover at its start so the box seats firmly on the ground."""
    for _ in range(ticks):
        _drive_kinematic(iface, handle, stage, prim_path, x, y, z)
        app.update()


def _ramp_x(app, iface, handle, stage, prim_path, start_x, target_x, y, z,
            ramp_step):
    """Drive the kinematic mover from ``start_x`` to ``target_x`` along +X in
    fixed per-tick steps of ``ramp_step`` metres; return the final mover pose.

    Small steps keep the box in contact every tick (it is pushed ahead);
    a large step outruns the contact solver (the mover passes past it).
    """
    cx = start_x
    while cx < target_x - 1e-9:
        cx = min(cx + float(ramp_step), target_x)
        _drive_kinematic(iface, handle, stage, prim_path, cx, y, z)
        app.update()
    return iface.get_rigid_body_pose(handle)


def _settle(app, iface, handle, stage, prim_path, x, y, z, ticks):
    """Hold at the target so the box settles (pushed) or is pinned (squish)."""
    for _ in range(ticks):
        _drive_kinematic(iface, handle, stage, prim_path, x, y, z)
        app.update()


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--mode", choices=("push", "squish"), required=True)
    parser.add_argument("--ramp-step", type=float, required=True)
    parser.add_argument("--start-x", type=float, default=-1.0)
    parser.add_argument("--target-x", type=float, required=True)
    parser.add_argument("--z", type=float, default=0.15)
    parser.add_argument("--seat-ticks", type=int, default=60)
    parser.add_argument("--settle-ticks", type=int, default=180)
    args = parser.parse_args()

    usd_path = str(Path(args.usd).resolve())

    from isaacsim import SimulationApp

    def _livestream_kwargs():
        """SimulationApp kwargs honoring ISAAC_LIVESTREAM so the scene is
        stream-viewable (mirrors framework parse_livestream_env): unset/"0"
        -> headless; "1"/"2" -> livestream. CI leaves it unset -> headless,
        so this is behavior-identical to the previous hardcoded boot."""
        import os

        value = os.environ.get("ISAAC_LIVESTREAM")
        if not value or value == "0":
            return {"headless": True}
        kwargs = {"headless": False, "livestream": int(value)}
        if value == "2":
            kwargs["renderer"] = "RaytracedLighting"
        return kwargs

    app = SimulationApp(_livestream_kwargs())
    try:
        import omni.timeline
        from omni.isaac.dynamic_control import _dynamic_control as dc

        stage = _open_stage(app, usd_path)
        if stage is None:
            raise RuntimeError("no stage")

        timeline = omni.timeline.get_timeline_interface()
        timeline.set_end_time(1.0e9)
        timeline.play()
        for _ in range(10):
            app.update()

        iface = dc.acquire_dynamic_control_interface()
        mover_path = "/World/Mover"
        mover = _get_body(iface, mover_path)
        box = _get_body(iface, "/World/Box")

        ramp_step = float(args.ramp_step)
        start_x = float(args.start_x)
        target_x = float(args.target_x)
        z = float(args.z)

        # The contact-respecting kinematic drive path: dc.set_kinematic_target
        # where the build exposes it, else a USD xformOp:translate write while
        # physics plays (the proven #201 carry-speed path). Report which.
        drive = (
            "set_kinematic_target"
            if hasattr(iface, "set_kinematic_target")
            else "usd_translate"
        )
        print(f"[PUSH DRIVE] drive={drive}", flush=True)

        box_x0 = float(iface.get_rigid_body_pose(box).p[0])

        _seat(app, iface, mover, stage, mover_path, start_x, 0.0, z,
              args.seat_ticks)
        _ramp_x(app, iface, mover, stage, mover_path, start_x, target_x, 0.0, z,
                ramp_step)
        _settle(app, iface, mover, stage, mover_path, target_x, 0.0, z,
                args.settle_ticks)

        mover_pose = iface.get_rigid_body_pose(mover)
        box_pose = iface.get_rigid_body_pose(box)
        mover_x = float(mover_pose.p[0])
        box_x = float(box_pose.p[0])
        box_disp = box_x - box_x0
        # The mover is kinematic: it must land on its COMMANDED path (target_x)
        # regardless of the reaction force from the box. mover_err is the
        # tracking error.
        mover_err = abs(mover_x - target_x)
        box_finite = all(
            math.isfinite(v) for v in (box_pose.p[0], box_pose.p[1],
                                       box_pose.p[2])
        )

        print(
            f"[PUSH SUMMARY] mode={args.mode} drive={drive} "
            f"ramp_step={ramp_step:.6f} target_x={target_x:.6f} "
            f"mover_x={mover_x:.6f} box_x0={box_x0:.6f} box_x={box_x:.6f} "
            f"box_disp={box_disp:.6f} mover_err={mover_err:.6f} "
            f"box_finite={box_finite} wall_x={WALL_X:.6f}",
            flush=True,
        )
        print("[EXIT CLEAN]", flush=True)
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        raise
    finally:
        app.close()


if __name__ == "__main__":
    _main()
