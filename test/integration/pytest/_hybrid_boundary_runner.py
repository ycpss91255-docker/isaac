"""Kit-side runner: hybrid kinematic+dynamic loop-joint boundary compliance
(#197, milestone "Physics: L2 true-kinematic + hybrid").

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp``, opens the hybrid fixture
(``test/fixtures/usd/l2_hybrid_loop.usda``: a KINEMATIC anchor at z=2.0 + a
DYNAMIC 10 kg body hung 0.5 m below at z=1.5 + a maximal-coordinate
``UsdPhysics.FixedJoint`` joining them + a gravity ``PhysicsScene``), plays
``omni.timeline`` and steps with ``app.update()`` (NEVER a
``SimulationContext`` -- the #151 shutdown-hang surface).

The maximal-coordinate (rigid-body) FixedJoint is solved as a SOFT constraint
(it is "weak"; PhysX #308), so the hung body GIVES at the joint under load
rather than holding rigidly. The runner quantifies the boundary:

  1. settle under gravity, measure the COMPLIANCE -- the steady-state
     separation between the anchor and the hung body vs the joint's rest
     separation (0.5 m). The give = ``settled_sep - rest_sep`` (the joint
     stretches under the 10 kg load).
  2. move the anchor UP by ``--lift`` (writing its pose every tick in SMALL
     increments; see ``_write_anchor`` for the write-path detail), settle, and
     measure FORCE TRANSFER --
     the hung body's rise vs the anchor's rise (a following body rises by ~the
     same amount; the joint transmits the motion even if compliantly).

Every ``isaacsim`` / ``omni`` / ``pxr`` import is FUNCTION-LOCAL so the file
stays host-importable (``python3 -m py_compile`` passes without Isaac).

Marker line::

    [HYBRID SUMMARY] rest_sep=<f> anchor_z0=<f> hung_z0=<f> settled_sep=<f> \
        compliance=<f> lift=<f> anchor_z1=<f> hung_z1=<f> anchor_rise=<f> \
        hung_rise=<f> follow_ratio=<f> hung_finite=<bool>
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

# Joint rest separation (anchor centre to hung centre), from the fixture.
REST_SEP = 0.5


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
    the USD stage is the contact/constraint-respecting kinematic TARGET write:
    PhysX reads the new target and interpolates the body to it across the
    substep, resolving the joint constraint (so the anchor's motion transmits
    to the hung body). This is the ``setKinematicTarget`` equivalent when the
    dynamic_control build exposes no ``set_kinematic_target`` -- the proven
    #201 carry-speed mechanism (PR #218, green on the GPU runner).
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


def _write_anchor(iface, handle, stage, prim_path, x, y, z):
    """Drive the kinematic anchor via the contact/constraint-respecting
    kinematic TARGET write (ADR-0008).

    Prefer ``dc.set_kinematic_target`` (``setKinematicTarget``) IF this dc
    build exposes it; otherwise write ``xformOp:translate`` on the
    kinematicEnabled prim while physics plays (the proven #201 carry-speed
    path). Both feed the kinematic target through the solver so the joint
    transmits the anchor motion to the hung body. A plain
    ``set_rigid_body_pose`` teleport bypasses the solver, so it is not used.
    This Isaac Sim build's dynamic_control does NOT ship
    ``set_kinematic_target``, so the USD path is used.
    """
    if hasattr(iface, "set_kinematic_target"):
        from omni.isaac.dynamic_control import _dynamic_control as dc

        target = dc.Transform()
        target.r = (0.0, 0.0, 0.0, 1.0)
        target.p = (x, y, z)
        iface.set_kinematic_target(handle, target)
    else:
        _set_translate(stage, prim_path, x, y, z)


def _hold(app, iface, handle, stage, prim_path, x, y, z, ticks):
    """Hold the anchor at (x, y, z) for ``ticks`` so the system settles."""
    for _ in range(ticks):
        _write_anchor(iface, handle, stage, prim_path, x, y, z)
        app.update()


def _ramp_anchor(app, iface, handle, stage, prim_path, x, y, start_z,
                 target_z, step):
    """Raise the anchor from ``start_z`` to ``target_z`` in fixed per-tick
    steps of ``step`` metres (small so the compliant joint keeps up)."""
    cz = start_z
    while cz < target_z - 1e-9:
        cz = min(cz + step, target_z)
        _write_anchor(iface, handle, stage, prim_path, x, y, cz)
        app.update()


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd", required=True)
    parser.add_argument("--lift", type=float, default=0.5)
    parser.add_argument("--ramp-step", type=float, default=0.005)
    parser.add_argument("--settle-ticks", type=int, default=400)
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
        anchor_path = "/World/Anchor"
        anchor = _get_body(iface, anchor_path)
        hung = _get_body(iface, "/World/Hung")

        drive = (
            "set_kinematic_target"
            if hasattr(iface, "set_kinematic_target")
            else "usd_translate"
        )
        print(f"[HYBRID DRIVE] drive={drive}", flush=True)

        anchor_z0 = float(iface.get_rigid_body_pose(anchor).p[2])

        # Phase 1: settle under gravity, hold the anchor at its start. Measure
        # the compliance (how far the hung body gives at the joint).
        _hold(app, iface, anchor, stage, anchor_path, 0.0, 0.0, anchor_z0,
              args.settle_ticks)
        anchor_z0 = float(iface.get_rigid_body_pose(anchor).p[2])
        hung_z0 = float(iface.get_rigid_body_pose(hung).p[2])
        settled_sep = anchor_z0 - hung_z0
        # Compliance = how much the joint stretched past its rest separation
        # under the 10 kg load (positive = the hung body drooped further).
        compliance = settled_sep - REST_SEP

        # Phase 2: raise the anchor by --lift, settle, measure force transfer.
        target_z = anchor_z0 + float(args.lift)
        _ramp_anchor(
            app, iface, anchor, stage, anchor_path, 0.0, 0.0, anchor_z0,
            target_z, float(args.ramp_step)
        )
        _hold(app, iface, anchor, stage, anchor_path, 0.0, 0.0, target_z,
              args.settle_ticks)

        anchor_z1 = float(iface.get_rigid_body_pose(anchor).p[2])
        hung_pose1 = iface.get_rigid_body_pose(hung)
        hung_z1 = float(hung_pose1.p[2])
        anchor_rise = anchor_z1 - anchor_z0
        hung_rise = hung_z1 - hung_z0
        # follow_ratio ~ 1.0 means the hung body followed the anchor's rise
        # (force transfer); ~0 means it did not follow.
        follow_ratio = (
            hung_rise / anchor_rise if abs(anchor_rise) > 1e-6 else float("nan")
        )
        hung_finite = all(
            math.isfinite(v) for v in (hung_pose1.p[0], hung_pose1.p[1],
                                       hung_pose1.p[2])
        )

        print(
            f"[HYBRID SUMMARY] rest_sep={REST_SEP:.6f} "
            f"anchor_z0={anchor_z0:.6f} hung_z0={hung_z0:.6f} "
            f"settled_sep={settled_sep:.6f} compliance={compliance:.6f} "
            f"lift={args.lift:.6f} anchor_z1={anchor_z1:.6f} "
            f"hung_z1={hung_z1:.6f} anchor_rise={anchor_rise:.6f} "
            f"hung_rise={hung_rise:.6f} follow_ratio={follow_ratio:.6f} "
            f"hung_finite={hung_finite}",
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
