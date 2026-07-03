"""Kit-side runner: kinematic base CARRIES an articulation (#228; ADR-0021).

Milestone "Physics: L2 true-kinematic + hybrid". Boots ONE headless
``SimulationApp``, opens the base-carry fixture
(``test/fixtures/usd/l2_base_carry.usda``: a KINEMATIC chassis on the ground
under a plain ``/World/Base`` group Xform + a 1-DOF prismatic "arm"
articulation (``/World/Base/Arm``) parented under that same group, resting on
the chassis top + a gravity ``PhysicsScene`` + a ground collider), plays
``omni.timeline`` and steps with ``app.update()`` (NEVER a
``SimulationContext`` -- deferred, #151 shutdown hang).

Topology (A) -- USD-hierarchy parent, NOT a FixedJoint: the arm articulation
is a CHILD of the base group prim, meant to ride along by the transform
hierarchy. A PhysX articulation LINK cannot be kinematic (ADR-0021 D2), so the
base cannot be a link of the arm; and a rigid body cannot nest inside another
rigid body, so the arm cannot be a child of the chassis rigid body itself --
hence the shared plain-Xform base group parents the kinematic chassis and the
arm articulation as siblings. The base is MOVED by writing ``/World/Base``'s
``xformOp:translate`` each tick while physics plays (the #201/#218
kinematic-carry mechanism, here applied to the group transform).

The runner takes two measurements against the same live scene and prints two
markers:

  1. RIDE-ALONG (``[CARRY SUMMARY]``) -- drive the base along an
     accel -> cruise -> decel -> stop translate profile and read how far the
     ARM's world pose (its Anchor link) tracked the CHASSIS's actual world
     displacement. ``ride_along_err`` is the final |arm_disp - base_disp|;
     ``ride_along_peak_err`` is its worst value across the profile. A rigid
     hierarchy carry gives ~0; a stationary (left-behind) arm gives
     ~base_disp.

  2. BASE-MOTION DISTURBANCE (``[BASE COUPLING SUMMARY]``) -- the arm slide is
     commanded to HOLD at 0; its settled equilibrium is recorded, then during
     the base accel/decel the held slide's PEAK deviation is tracked, and
     after the base stops the RESIDUAL deviation is read. A rigid hierarchy
     carry transmits no acceleration to the slide (peak ~ 0); a contact-drag
     carry does (peak > 0, settling to a small residual).

Whether topology (A) actually carries the articulation is the OPEN QUESTION
this experiment answers on the GPU box (see the module doc / the recorded
results doc ``doc/experiments/exp-228-base-carry.md``). The runner exits
cleanly and prints the measured numbers in EVERY regime -- including the null
case where the base does not move the arm at all -- so the GPU run can be read
and the approach revised (a FixedJoint, topology B, if (A) does not carry).

Every ``isaacsim`` / ``omni`` / ``pxr`` import is FUNCTION-LOCAL so the file
stays host-importable (``python3 -m py_compile`` passes without Isaac).

Marker lines::

    [CARRY SUMMARY] base_disp=<f> arm_disp=<f> ride_along_err=<f> \
        ride_along_peak_err=<f> tracked=<bool>
    [BASE COUPLING SUMMARY] hold_target=<f> equilibrium=<f> peak_dev=<f> \
        residual=<f> base_disp=<f> base_accel=<f> cruise_speed=<f>
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

# USD prim paths in the fixture.
BASE_GROUP_PATH = "/World/Base"
CHASSIS_PATH = "/World/Base/Chassis"
ARM_ROOT_PATH = "/World/Base/Arm"
ARM_ANCHOR_PATH = "/World/Base/Arm/Anchor"
ARM_ANCHOR_NAME = "Anchor"
SLIDE_JOINT_NAME = "arm_slide"
# Ticks to let PhysX init after play and to seat / settle the arm hold before
# the base starts moving, and to settle after the base stops.
INIT_TICKS = 10
SEAT_TICKS = 120
SETTLE_TICKS = 150
# The held slide target (m) -- hold the arm at its home slide position.
HOLD_TARGET = 0.0


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


def _set_group_translate(stage, prim_path, x, y, z):
    """Set the base group prim's ``xformOp:translate`` to (x, y, z).

    While physics plays, writing the base group's transform is the topology-A
    kinematic-carry command: the kinematic chassis is a child, so its composed
    world target moves; the arm articulation is the sibling child whose
    ride-along is being measured.
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


def _get_rigid_body(iface, dc, prim_path):
    """Acquire a standalone dc rigid-body handle, raising on INVALID_HANDLE."""
    handle = iface.get_rigid_body(prim_path)
    if handle == dc.INVALID_HANDLE:
        raise RuntimeError(f"dc.get_rigid_body({prim_path}) INVALID_HANDLE")
    return handle


def _candidate_articulation_paths(stage):
    """Ordered, de-duped candidate prim paths for dc.get_articulation.

    Try the authored arm root first, then any ArticulationRootAPI prim, then
    the rigid-body links -- the first that yields a valid handle wins (mirrors
    the multijoint runner's resolution).
    """
    from pxr import UsdPhysics

    paths = [ARM_ROOT_PATH]
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            paths.append(str(prim.GetPath()))
    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.RigidBodyAPI):
            paths.append(str(prim.GetPath()))
    return list(dict.fromkeys(paths))


def _resolve_articulation(iface, dc, stage):
    """Return a valid articulation handle for the arm, or raise."""
    for cand in _candidate_articulation_paths(stage):
        handle = iface.get_articulation(cand)
        if handle != dc.INVALID_HANDLE:
            return handle, cand
    raise RuntimeError("dc.get_articulation failed for all candidate paths")


def _resolve_anchor_body(iface, dc, art):
    """Return a body handle for the arm Anchor link (world-pose readback).

    Prefer the named articulation body; fall back to the standalone rigid-body
    lookup on the Anchor prim path if the named lookup is unavailable.
    """
    if hasattr(iface, "find_articulation_body"):
        handle = iface.find_articulation_body(art, ARM_ANCHOR_NAME)
        if handle and handle != dc.INVALID_HANDLE:
            return handle
    handle = iface.get_rigid_body(ARM_ANCHOR_PATH)
    if handle == dc.INVALID_HANDLE:
        raise RuntimeError("could not resolve the arm Anchor body handle")
    return handle


def _resolve_slide_dof(iface, dc, art):
    """Return the prismatic slide DOF handle, or raise."""
    invalid = getattr(dc, "INVALID_DOF_HANDLE", dc.INVALID_HANDLE)
    handle = iface.find_articulation_dof(art, SLIDE_JOINT_NAME)
    if handle and handle != invalid:
        return handle
    ndof = iface.get_articulation_dof_count(art)
    if ndof >= 1:
        return iface.get_articulation_dof(art, 0)
    raise RuntimeError("articulation exposes no DOF for the arm slide")


def _base_x_profile(accel, cruise_speed, dt, cruise_ticks):
    """Base X position samples for accel -> cruise -> decel -> stop.

    Returns a list of (x, phase) with one entry per tick, phase in
    {"accel", "cruise", "decel"}. Constant +accel to cruise_speed, then
    constant cruise, then a symmetric -accel back to rest.
    """
    accel_ticks = max(1, int(math.ceil(cruise_speed / (accel * dt))))
    samples = []
    x = 0.0
    v = 0.0
    for _ in range(accel_ticks):
        v = min(v + accel * dt, cruise_speed)
        x += v * dt
        samples.append((x, "accel"))
    for _ in range(cruise_ticks):
        x += cruise_speed * dt
        samples.append((x, "cruise"))
    for _ in range(accel_ticks):
        v = max(v - accel * dt, 0.0)
        x += v * dt
        samples.append((x, "decel"))
    return samples


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--accel", type=float, default=2.0)
    parser.add_argument("--cruise-speed", type=float, default=1.0)
    parser.add_argument("--cruise-ticks", type=int, default=60)
    parser.add_argument("--dt", type=float, default=1.0 / 60.0)
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
        for _ in range(INIT_TICKS):
            app.update()

        iface = dc.acquire_dynamic_control_interface()
        chassis = _get_rigid_body(iface, dc, CHASSIS_PATH)
        art, art_root = _resolve_articulation(iface, dc, stage)
        iface.wake_up_articulation(art)
        anchor = _resolve_anchor_body(iface, dc, art)
        slide = _resolve_slide_dof(iface, dc, art)
        print(f"[ARTICULATION] root={art_root}", flush=True)

        # Command the slide to HOLD and let the arm seat on the chassis.
        iface.set_dof_position_target(slide, float(HOLD_TARGET))
        for _ in range(SEAT_TICKS):
            iface.set_dof_position_target(slide, float(HOLD_TARGET))
            app.update()

        # Reference start poses (the ACTUAL world X of the chassis and the arm
        # anchor) and the settled slide equilibrium.
        base_x0 = float(iface.get_rigid_body_pose(chassis).p[0])
        arm_x0 = float(iface.get_rigid_body_pose(anchor).p[0])
        equilibrium = float(iface.get_dof_position(slide))

        # Drive the base group along the accel -> cruise -> decel -> stop
        # profile, tracking the ride-along error and the held-slide peak
        # deviation during the accel/decel (base-acceleration) phases.
        profile = _base_x_profile(
            float(args.accel), float(args.cruise_speed), float(args.dt),
            int(args.cruise_ticks),
        )
        ride_along_peak_err = 0.0
        peak_dev = 0.0
        for x, phase in profile:
            _set_group_translate(stage, BASE_GROUP_PATH, x, 0.0, 0.0)
            iface.set_dof_position_target(slide, float(HOLD_TARGET))
            app.update()

            base_disp = float(iface.get_rigid_body_pose(chassis).p[0]) - base_x0
            arm_disp = float(iface.get_rigid_body_pose(anchor).p[0]) - arm_x0
            err = abs(arm_disp - base_disp)
            if err > ride_along_peak_err:
                ride_along_peak_err = err
            # The base acceleration is non-zero only during accel / decel.
            if phase in ("accel", "decel"):
                dev = abs(float(iface.get_dof_position(slide)) - equilibrium)
                if dev > peak_dev:
                    peak_dev = dev

        # Hold the base at its final position and let everything settle.
        final_x = profile[-1][0] if profile else 0.0
        for _ in range(SETTLE_TICKS):
            _set_group_translate(stage, BASE_GROUP_PATH, final_x, 0.0, 0.0)
            iface.set_dof_position_target(slide, float(HOLD_TARGET))
            app.update()

        base_disp = float(iface.get_rigid_body_pose(chassis).p[0]) - base_x0
        arm_disp = float(iface.get_rigid_body_pose(anchor).p[0]) - arm_x0
        ride_along_err = abs(arm_disp - base_disp)
        residual = abs(float(iface.get_dof_position(slide)) - equilibrium)
        # The arm "tracked" the base iff the base actually moved and the arm
        # followed it to within half the base displacement (a recorded regime
        # flag, not a gate).
        tracked = abs(base_disp) > 0.05 and ride_along_err < 0.5 * abs(base_disp)

        print(
            f"[CARRY SUMMARY] base_disp={base_disp:.6f} arm_disp={arm_disp:.6f} "
            f"ride_along_err={ride_along_err:.6e} "
            f"ride_along_peak_err={ride_along_peak_err:.6e} tracked={tracked}",
            flush=True,
        )
        print(
            f"[BASE COUPLING SUMMARY] hold_target={float(HOLD_TARGET):.6f} "
            f"equilibrium={equilibrium:.6e} peak_dev={peak_dev:.6e} "
            f"residual={residual:.6e} base_disp={base_disp:.6f} "
            f"base_accel={float(args.accel):.6f} "
            f"cruise_speed={float(args.cruise_speed):.6f}",
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
