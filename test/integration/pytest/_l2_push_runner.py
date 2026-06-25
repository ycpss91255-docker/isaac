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

The kinematic write path matters (ADR-0008):

  * ``dc.set_kinematic_target`` (``setKinematicTarget``) feeds the target
    through the contact solver, so the mover PUSHES the box via contact each
    substep -- momentum transfer. SMALL per-tick steps keep contact every
    tick; a too-large step teleports the mover past the box (the same
    carry-speed caveat as the #201 carry experiment). This is the carry path.
  * ``dc.set_rigid_body_pose`` (``setGlobalPose``) is a teleport that BYPASSES
    contact -- it would pass straight through the box. Not used for the push
    (only relevant as the negative control documented in the carry-speed
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

    [PUSH SUMMARY] mode=<s> write_mode=<s> ramp_step=<f> target_x=<f> \
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


def _write_pose(iface, handle, target, write_mode):
    """Write a kinematic pose via the selected path (ADR-0008).

    ``kinematic_target`` -> ``dc.set_kinematic_target`` (``setKinematicTarget``,
    fed through the contact solver so the mover pushes via contact).
    ``global_pose`` -> ``dc.set_rigid_body_pose`` (``setGlobalPose``, a teleport
    bypassing contact). If ``set_kinematic_target`` is unavailable on this dc
    build the call raises so the experiment fails loudly rather than silently
    degrading to a teleport.
    """
    if write_mode == "kinematic_target":
        if not hasattr(iface, "set_kinematic_target"):
            raise RuntimeError(
                "dc has no set_kinematic_target (cannot run the contact-"
                "respecting push path; ADR-0008)"
            )
        iface.set_kinematic_target(handle, target)
    elif write_mode == "global_pose":
        iface.set_rigid_body_pose(handle, target)
    else:
        raise ValueError(f"unknown write_mode {write_mode!r}")


def _seat(app, iface, handle, x, y, z, ticks, write_mode):
    """Hold the mover at its start so the box seats firmly on the ground."""
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    target.p = (x, y, z)
    for _ in range(ticks):
        _write_pose(iface, handle, target, write_mode)
        app.update()


def _ramp_x(app, iface, handle, start_x, target_x, y, z, ramp_step, mode):
    """Drive the kinematic mover from ``start_x`` to ``target_x`` along +X in
    fixed per-tick steps of ``ramp_step`` metres; return the final mover pose.

    Small steps keep the box in contact every tick (it is pushed ahead);
    a large step outruns the contact solver (the mover teleports past it).
    """
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    cx = start_x
    while cx < target_x - 1e-9:
        cx = min(cx + ramp_step, target_x)
        target.p = (cx, y, z)
        _write_pose(iface, handle, target, mode)
        app.update()
    return iface.get_rigid_body_pose(handle)


def _settle(app, iface, handle, x, y, z, ticks, write_mode):
    """Hold at the target so the box settles (pushed) or is pinned (squish)."""
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    target.p = (x, y, z)
    for _ in range(ticks):
        _write_pose(iface, handle, target, write_mode)
        app.update()


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--mode", choices=("push", "squish"), required=True)
    parser.add_argument("--ramp-step", type=float, required=True)
    parser.add_argument(
        "--write-mode",
        choices=("kinematic_target", "global_pose"),
        default="kinematic_target",
    )
    parser.add_argument("--start-x", type=float, default=-1.0)
    parser.add_argument("--target-x", type=float, required=True)
    parser.add_argument("--z", type=float, default=0.15)
    parser.add_argument("--seat-ticks", type=int, default=60)
    parser.add_argument("--settle-ticks", type=int, default=180)
    args = parser.parse_args()

    usd_path = str(Path(args.usd).resolve())

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})
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
        mover = _get_body(iface, "/World/Mover")
        box = _get_body(iface, "/World/Box")

        ramp_step = float(args.ramp_step)
        start_x = float(args.start_x)
        target_x = float(args.target_x)
        z = float(args.z)
        write_mode = args.write_mode

        box_x0 = float(iface.get_rigid_body_pose(box).p[0])

        _seat(app, iface, mover, start_x, 0.0, z, args.seat_ticks, write_mode)
        _ramp_x(
            app, iface, mover, start_x, target_x, 0.0, z, ramp_step, write_mode
        )
        _settle(app, iface, mover, target_x, 0.0, z, args.settle_ticks,
                write_mode)

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
            f"[PUSH SUMMARY] mode={args.mode} write_mode={write_mode} "
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
