"""Kit-side runner: true-L2 zero-error kinematic hold under load (#193/#194).

ADR-0021 D1/D2, milestone "Physics: L2 true-kinematic + hybrid". Boots ONE
headless ``SimulationApp``, opens the standalone-kinematic fixture
(``test/fixtures/usd/l2_kinematic_hold.usda``: a KINEMATIC platform + a
DYNAMIC 10 kg payload + a gravity ``PhysicsScene`` + a ground collider),
plays ``omni.timeline`` and steps with ``app.update()`` (NEVER a
``SimulationContext`` -- deferred, #151 shutdown hang), commands the
kinematic platform to a target height each tick via
``dc.set_rigid_body_pose`` (the proven openbase L2 pattern,
``test_openbase_l2_stability.py``), lets the dynamic payload settle onto it
under gravity, then reads the platform pose with ``dc.get_rigid_body_pose``
and reports the steady-state position error.

The point: PhysX moves a kinematic actor to its target "regardless of
external forces, gravity, collision", so the platform's error is essentially
ZERO even while it carries the payload -- the true-L2 endpoint, in direct
contrast to EXP-184's L2.5 articulation-drive sag (``m*g/stiffness``: 19.4 mm
at k=5000 for the same 10 kg load).

Every ``isaacsim`` / ``omni`` / ``pxr`` import is FUNCTION-LOCAL so the file
stays host-importable (``python3 -m py_compile`` passes without Isaac).

Marker line::

    [L2HOLD SUMMARY] target=<f> resting=<f> error=<f> payload_mass=<f> \
        payload_z=<f> payload_on_platform=<bool> l25_sag_mm_k5000=<f>
    [EXIT CLEAN]

On exception::

    [RAISED] <type>: <msg>
    [TRACEBACK]
    <traceback>
"""

import argparse
import sys
from pathlib import Path

# EXP-184 reference: the L2.5 articulation high-stiffness position drive sags
# by m*g/stiffness under continuous load (ADR-0021 D1a). For a 10 kg payload
# at the lowest swept stiffness k=5000 N/m the measured steady-state error was
# 19.4 mm. We recompute the mg/k model here for the contrast assertion.
_EXP184_PAYLOAD_KG = 10.0
_EXP184_K5000 = 5000.0
_G = 9.81


def _l25_sag_m(mass_kg: float, stiffness: float) -> float:
    """L2.5 steady-state sag (m) = m*g / stiffness (ADR-0021 D1a / EXP-184)."""
    return (mass_kg * _G) / stiffness


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


def _command_and_settle(
    app, iface, handle, target_xyz, ticks, ramp_step=0.003, seat_ticks=30
):
    """Lift the kinematic body to ``target_xyz`` so it CARRIES the resting
    payload, then hold; return the final pose.

    A kinematic body teleported straight to the target jumps out from under a
    dynamic payload (the payload cannot follow a one-tick jump and is left
    behind / falls). Instead: (1) command the body at its START height for a
    few ticks so the payload seats firmly on it, (2) RAMP the commanded height
    toward the target in small steps (``ramp_step`` per tick, quasi-static) so
    the kinematic body pushes the payload up via contact every step, then
    (3) HOLD at the target for ``ticks`` updates so the payload settles. The
    held position is still EXACT (kinematic ignores the load) -- the ramp only
    keeps the payload in contact during the lift.
    """
    from omni.isaac.dynamic_control import _dynamic_control as dc

    start = iface.get_rigid_body_pose(handle)
    cz = float(start.p[2])
    tx, ty, tz = float(target_xyz[0]), float(target_xyz[1]), float(target_xyz[2])
    up = tz > cz

    target = dc.Transform()
    target.r = (0.0, 0.0, 0.0, 1.0)

    # (1) Seat the payload on the platform at its start height.
    target.p = (tx, ty, cz)
    for _ in range(seat_ticks):
        iface.set_rigid_body_pose(handle, target)
        app.update()

    # (2) Ramp slowly so the platform carries the payload via contact.
    while abs(cz - tz) > 1e-9:
        cz += ramp_step if up else -ramp_step
        if (up and cz > tz) or (not up and cz < tz):
            cz = tz
        target.p = (tx, ty, cz)
        iface.set_rigid_body_pose(handle, target)
        app.update()

    # (3) Hold at the target so the payload settles firmly on top.
    target.p = (tx, ty, tz)
    for _ in range(ticks):
        iface.set_rigid_body_pose(handle, target)
        app.update()
    return iface.get_rigid_body_pose(handle)


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--target-z", type=float, default=1.0)
    parser.add_argument("--settle-ticks", type=int, default=240)
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
        platform = _get_body(iface, "/World/Platform")
        payload = _get_body(iface, "/World/Payload")

        target_z = float(args.target_z)
        target_xyz = (0.0, 0.0, target_z)

        # Command the kinematic platform to the target height each tick and
        # let the dynamic payload settle onto it under gravity.
        platform_pose = _command_and_settle(
            app, iface, platform, target_xyz, args.settle_ticks
        )
        resting_z = float(platform_pose.p[2])
        error = abs(resting_z - target_z)

        payload_pose = iface.get_rigid_body_pose(payload)
        payload_z = float(payload_pose.p[2])
        # The payload sits on the platform top (platform half-height 0.05 +
        # payload half-height 0.15 = 0.20 above the platform centre). If the
        # payload is near the ground the platform failed to hold the load.
        payload_on_platform = payload_z > (target_z + 0.05)

        l25_sag_mm_k5000 = _l25_sag_m(_EXP184_PAYLOAD_KG, _EXP184_K5000) * 1000.0

        print(
            f"[L2HOLD SUMMARY] target={target_z:.6f} resting={resting_z:.6f} "
            f"error={error:.6e} payload_mass={_EXP184_PAYLOAD_KG:.3f} "
            f"payload_z={payload_z:.6f} "
            f"payload_on_platform={payload_on_platform} "
            f"l25_sag_mm_k5000={l25_sag_mm_k5000:.4f}",
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
