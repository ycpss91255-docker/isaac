"""Kit-side runner: kinematic carry speed-limit experiment (#201 sub-issue).

Milestone "Physics: L2 true-kinematic + hybrid". Boots ONE headless
``SimulationApp``, opens the carry-speed fixture
(``test/fixtures/usd/l2_carry_speed.usda``: a KINEMATIC mover starting at
z=0.5 + a DYNAMIC 10 kg payload resting on it at z=0.70 + a gravity
``PhysicsScene`` + a ground collider), plays ``omni.timeline`` and steps with
``app.update()`` (NEVER a ``SimulationContext`` -- deferred, #151 shutdown
hang), then RAMPS the kinematic mover up to a target height in fixed per-tick
steps (``--ramp-step`` metres) via ``dc.set_rigid_body_pose`` (the proven
openbase L2 pattern, ``test_openbase_l2_stability.py``).

The point: ``dc.set_rigid_body_pose`` is a teleport (``setGlobalPose``) that
BYPASSES the contact integrator (ADR-0008: "must use setKinematicTarget not
setGlobalPose"). Move the kinematic mover too far in one tick and the resting
dynamic payload cannot follow -- it is left behind / tunnels and falls to the
ground. So there is an effective per-timestep carry speed limit. This runner
ramps at one ``--ramp-step`` and reports whether the payload was carried; the
test sweeps several steps to bracket the threshold.

Every ``isaacsim`` / ``omni`` / ``pxr`` import is FUNCTION-LOCAL so the file
stays host-importable (``python3 -m py_compile`` passes without Isaac).

Marker line::

    [CARRY SUMMARY] ramp_step=<f> target=<f> mover_z=<f> payload_z=<f> \
        payload_carried=<bool>
    [EXIT CLEAN]

On exception::

    [RAISED] <type>: <msg>
    [TRACEBACK]
    <traceback>
"""

import argparse
import sys
from pathlib import Path


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


def _seat(app, iface, handle, x, y, z, ticks):
    """Hold the mover at its start height so the payload seats firmly on it."""
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    target.p = (x, y, z)
    for _ in range(ticks):
        iface.set_rigid_body_pose(handle, target)
        app.update()


def _ramp(app, iface, handle, x, y, start_z, target_z, ramp_step):
    """Ramp the kinematic mover from ``start_z`` to ``target_z`` in fixed
    per-tick steps of ``ramp_step`` metres; return the final mover pose.

    Each tick teleports (``set_rigid_body_pose``) the mover up by one step.
    A small step keeps the payload in contact every tick (it rides up); a
    large step jumps past the payload (it is left behind / tunnels).
    """
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    cz = start_z
    while cz < target_z - 1e-9:
        cz = min(cz + ramp_step, target_z)
        target.p = (x, y, cz)
        iface.set_rigid_body_pose(handle, target)
        app.update()
    return iface.get_rigid_body_pose(handle)


def _settle(app, iface, handle, x, y, target_z, ticks):
    """Hold at the target so the payload settles (carried) or falls (dropped)."""
    from omni.isaac.dynamic_control import _dynamic_control as dc

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)
    target.p = (x, y, target_z)
    for _ in range(ticks):
        iface.set_rigid_body_pose(handle, target)
        app.update()


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--ramp-step", type=float, required=True)
    parser.add_argument("--start-z", type=float, default=0.5)
    parser.add_argument("--target-z", type=float, default=1.0)
    parser.add_argument("--seat-ticks", type=int, default=60)
    parser.add_argument("--settle-ticks", type=int, default=120)
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
        payload = _get_body(iface, "/World/Payload")

        ramp_step = float(args.ramp_step)
        start_z = float(args.start_z)
        target_z = float(args.target_z)

        # Seat the payload, ramp the mover up at ramp_step, let it settle.
        _seat(app, iface, mover, 0.0, 0.0, start_z, args.seat_ticks)
        mover_pose = _ramp(
            app, iface, mover, 0.0, 0.0, start_z, target_z, ramp_step
        )
        _settle(app, iface, mover, 0.0, 0.0, target_z, args.settle_ticks)

        mover_pose = iface.get_rigid_body_pose(mover)
        payload_pose = iface.get_rigid_body_pose(payload)
        mover_z = float(mover_pose.p[2])
        payload_z = float(payload_pose.p[2])

        # The payload was carried iff it rode up with the mover and is resting
        # on its top (mover half-height 0.05 + payload half-height 0.15 = 0.20
        # above the mover centre). If it was left behind it sits near its
        # start (~0.70) or on the ground, well below target_z + 0.05.
        payload_carried = payload_z > (target_z + 0.05)

        print(
            f"[CARRY SUMMARY] ramp_step={ramp_step:.6f} target={target_z:.6f} "
            f"mover_z={mover_z:.6f} payload_z={payload_z:.6f} "
            f"payload_carried={payload_carried}",
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
