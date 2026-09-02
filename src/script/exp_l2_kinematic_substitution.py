#!/usr/bin/env python3
"""L2 per-link true-kinematic substitution generality on Isaac Sim 6.0.1 (isaac#193).

Re-validates the ADR-0008 L2 contract on Isaac Sim 6.0.1 / Isaac Lab 3.0:
a STANDALONE rigid body with ``physics:kinematicEnabled=True``, driven per-tick
to a commanded pose, follows the command EXACTLY -- "Each simulation step PhysX
moves the actor to its target position, regardless of external forces, gravity,
collision" (PhysX 5.4 RigidBodyDynamics, quoted in ADR-0008 L2 contract clause 2).

Issue #193 asks the GENERALITY question: can EACH link class of a model be pulled
out of the articulation and driven as a standalone kinematic body (leaf / internal
/ base-root, sub-issues #194/#195/#196), independent of its shape? Since PhysX
forbids kinematic links INSIDE an articulation (ADR-0008 coexistence rule 4), the
substitution target is always a standalone rigid body. This driver builds several
standalone bodies of DIFFERENT shapes -- each a stand-in for one link class -- and
drives every one along the same commanded SE(3) trajectory:

  leaf     -> small cube            (0.1 m)          -- no children, easiest
  internal -> elongated beam box    (0.4 x 0.1 x 0.1) -- the link that would split
                                                          the articulation tree
  base     -> large flat box        (0.6 x 0.6 x 0.2) -- whole-robot kinematic base
  odd      -> cylinder              (r0.15 h0.3)      -- shape-generality control

The commanded trajectory (per body, x-offset so they never overlap):
  x = x0 + 0.5*sin(2*pi*phase)   y = 0.3*sin(4*pi*phase)
  z = 1.0 + 0.2*sin(2*pi*phase)  yaw = 2*pi*phase        (phase = step/steps)

Two external influences are ACTIVE the whole run, so a faithful L2 body proves it
ignores both:
  (a) GRAVITY (-Z 9.81): a dynamic body would free-fall; the z-track must stay exact.
  (b) COLLISION / external push: a dynamic "pusher" sphere rests ON each kinematic
      body and is pressed down by gravity, so there is continuous contact as the
      body sweeps. Per ADR-0008 coexistence rule 1 the kinematic body pushes the
      sphere (one-way, infinite mass) but "nothing pushes it back" -- tracking error
      must stay 0 through every contact frame. The sphere staying up (final z well
      above ground) also CONFIRMS we drove through the contact integrator
      (set_world_pose on a kinematic body -> kinematic target, NOT a setGlobalPose
      teleport that the sphere could not feel; ADR-0008 L2 contract clause 3).

Metric per body: max over all steps of position error ||actual - commanded|| (m)
and orientation geodesic error (deg), where actual is read straight back from the
sim after each ``world.step``. Commanded and actual use the same Isaac scalar-first
(w,x,y,z) convention, so the error is convention-independent. Expectation (5.1
baseline, ADR-0008 openbase L2 migration result): 0.0000 m / 0.0 deg for every
shape -- exact, deterministic, shape-independent.

Results are written as JSON to ``--out`` (a MOUNTED path) so the host reads them
back; stdout through the docker run wrapper is not reliably captured. Teardown is
an explicit ``os._exit`` (isaac#248 round 9): a cold headless 6.0.1 container's
Omniverse Hub connector aborts SimulationApp.close() with a busy-TaskGroup SIGABRT;
os._exit reaches the same clean exit while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_l2_kinematic_substitution.py \\
        --out /home/<user>/work/worktree/<wt>/test/.l2-kinematic.json \\
        [--steps 360] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# (name, link_class, kind, dims). dims: box -> (sx,sy,sz); cylinder -> (radius,height).
_SHAPES = [
    ("leaf", "leaf-link (no children)", "box", (0.1, 0.1, 0.1)),
    ("internal", "internal-link (splits tree)", "box", (0.4, 0.1, 0.1)),
    ("base", "base/root-link (whole-robot base)", "box", (0.6, 0.6, 0.2)),
    ("odd", "shape-generality control", "cylinder", (0.15, 0.3)),
]


def _quat_mul(a, b):
    """Hamilton product of scalar-first quats a,b -> scalar-first (w,x,y,z)."""
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def _quat_angle_deg(q_cmd, q_act):
    """Geodesic angle (deg) between two scalar-first unit quaternions."""
    import numpy as np

    a = np.asarray(q_cmd, dtype=float)
    b = np.asarray(q_act, dtype=float)
    na = np.linalg.norm(a)
    nb = np.linalg.norm(b)
    if na == 0 or nb == 0:
        return float("nan")
    a = a / na
    b = b / nb
    dot = abs(float(np.dot(a, b)))
    dot = max(-1.0, min(1.0, dot))
    return math.degrees(2.0 * math.acos(dot))


def _yaw_quat_wxyz(yaw):
    """Yaw (rad) about +Z as scalar-first (w,x,y,z)."""
    half = yaw * 0.5
    return (math.cos(half), 0.0, 0.0, math.sin(half))


def _commanded_pose(x0, phase):
    """Commanded (position xyz, orientation wxyz) at trajectory phase in [0,1)."""
    two_pi = 2.0 * math.pi
    x = x0 + 0.5 * math.sin(two_pi * phase)
    y = 0.3 * math.sin(2.0 * two_pi * phase)
    z = 1.0 + 0.2 * math.sin(two_pi * phase)
    yaw = two_pi * phase
    return (x, y, z), _yaw_quat_wxyz(yaw)


def _build_scene(stage, x_spacing):
    """Author ground + light + kinematic bodies + dynamic pushers.

    Returns list of dicts with the kinematic body prim paths and their x0.
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    world = UsdGeom.Xform.Define(stage, "/World")

    light = UsdLux.DistantLight.Define(stage, "/World/SunLight")
    light.CreateIntensityAttr(3000.0)

    # Ground plane (static collider) at z=0.
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    gx = ground.AddXformOp(UsdGeom.XformOp.TypeTranslate)
    gx.Set(Gf.Vec3d(0.0, 0.0, -0.5))
    gs = ground.AddXformOp(UsdGeom.XformOp.TypeScale)
    gs.Set(Gf.Vec3f(200.0, 200.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    bodies = []
    for i, (name, _cls, kind, dims) in enumerate(_SHAPES):
        x0 = i * x_spacing
        (px, py, pz), _q = _commanded_pose(x0, 0.0)
        body_path = f"/World/kin_{name}"

        if kind == "box":
            geom = UsdGeom.Cube.Define(stage, body_path)
            geom.GetSizeAttr().Set(1.0)
            geom.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(px, py, pz)
            )
            geom.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
                Gf.Vec3f(dims[0], dims[1], dims[2])
            )
            top = pz + dims[2] * 0.5
        else:  # cylinder
            geom = UsdGeom.Cylinder.Define(stage, body_path)
            geom.GetRadiusAttr().Set(dims[0])
            geom.GetHeightAttr().Set(dims[1])
            geom.GetAxisAttr().Set(UsdGeom.Tokens.z)
            geom.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(px, py, pz)
            )
            top = pz + dims[1] * 0.5

        prim = geom.GetPrim()
        rb = UsdPhysics.RigidBodyAPI.Apply(prim)
        rb.CreateKinematicEnabledAttr(True)  # <-- L2: standalone kinematic body
        UsdPhysics.CollisionAPI.Apply(prim)
        mass = UsdPhysics.MassAPI.Apply(prim)
        mass.CreateMassAttr(1.0)

        # Dynamic pusher BOX resting on top -> continuous contact under gravity.
        # A box (not a sphere) will not roll off; friction drags it along as the
        # kinematic body sweeps, so contact is maintained through the whole run
        # -- and the box staying UP (never reaching the ground) confirms the
        # kinematic body pushed it (one-way, ADR-0008 rule 1) via the contact
        # integrator rather than teleporting through it.
        pusher_path = f"/World/push_{name}"
        pe = 0.12
        push = UsdGeom.Cube.Define(stage, pusher_path)
        push.GetSizeAttr().Set(1.0)
        push.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
            Gf.Vec3d(px, py, top + pe * 0.5 + 0.02)
        )
        push.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(pe, pe, pe))
        pprim = push.GetPrim()
        prb = UsdPhysics.RigidBodyAPI.Apply(pprim)  # dynamic (kinematic default off)
        UsdPhysics.CollisionAPI.Apply(pprim)
        pmass = UsdPhysics.MassAPI.Apply(pprim)
        pmass.CreateMassAttr(0.5)
        # Damp the pusher so it settles into steady contact instead of bouncing off.
        PhysxSchema.PhysxRigidBodyAPI.Apply(pprim).CreateLinearDampingAttr(0.5)

        bodies.append({
            "name": name,
            "link_class": _cls,
            "kind": kind,
            "dims": list(dims),
            "x0": x0,
            "body_path": body_path,
            "pusher_path": pusher_path,
        })
    return bodies


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "issue": "isaac#193",
        "adr": "ADR-0008 L2 kinematic contract",
        "isaac_variant": "6.0.1",
        "steps": args.steps,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "metric": (
            "max over trajectory of position error ||actual-commanded|| (m) "
            "and orientation geodesic error (deg), under active gravity + a "
            "resting dynamic pusher (continuous contact)"
        ),
        "expectation_5_1_baseline": (
            "0.0000 m / 0.0 deg per shape -- exact, deterministic, shape-"
            "independent (ADR-0008 openbase L2 migration: pose tracking 0.0000 err)"
        ),
        "drive_api": None,
        "bodies": [],
        "all_zero_error": None,
        "error": None,
    }

    try:
        import numpy as np
        import omni.usd
        from isaacsim.core.api import World
        from isaacsim.core.prims import SingleRigidPrim

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()

        specs = _build_scene(stage, x_spacing=3.0)

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        kin = {s["name"]: SingleRigidPrim(s["body_path"]) for s in specs}
        push = {s["name"]: SingleRigidPrim(s["pusher_path"]) for s in specs}
        result["drive_api"] = (
            "isaacsim.core.prims.SingleRigidPrim.set_world_pose per tick on a "
            "physics:kinematicEnabled body (routes to kinematic target, not "
            "setGlobalPose) + World.step"
        )

        # Per-body running max errors + contact tracking. The pusher provides a
        # real external-contact WINDOW: it rests on / impacts the moving body for
        # the opening frames, then (being dynamic) is left behind and free-falls
        # to the ground under gravity. Two things are recorded: the tracking error
        # across ALL frames, and -- separately -- the tracking error only during
        # the contact frames, to show the push changes nothing.
        acc = {s["name"]: {
            "max_pos_err_m": 0.0,
            "max_ang_err_deg": 0.0,
            "sum_pos_err_m": 0.0,
            "max_pos_err_contact_m": 0.0,
            "contact_frames": 0,
        } for s in specs}

        for step_i in range(args.steps):
            phase = step_i / float(args.steps)
            # Command every kinematic body BEFORE stepping.
            cmd = {}
            for s in specs:
                pos, quat = _commanded_pose(s["x0"], phase)
                cmd[s["name"]] = (pos, quat)
                kin[s["name"]].set_world_pose(
                    np.asarray(pos, dtype=float),
                    np.asarray(quat, dtype=float),
                )
            world.step(render=False)
            # Read back actuals and accumulate error.
            for s in specs:
                nm = s["name"]
                pos_c, quat_c = cmd[nm]
                pos_a, quat_a = kin[nm].get_world_pose()
                pos_a = np.asarray(pos_a, dtype=float).reshape(-1)
                quat_a = np.asarray(quat_a, dtype=float).reshape(-1)
                pos_err = float(np.linalg.norm(pos_a - np.asarray(pos_c)))
                ang_err = _quat_angle_deg(quat_c, tuple(quat_a.tolist()))
                a = acc[nm]
                a["max_pos_err_m"] = max(a["max_pos_err_m"], pos_err)
                if not math.isnan(ang_err):
                    a["max_ang_err_deg"] = max(a["max_ang_err_deg"], ang_err)
                a["sum_pos_err_m"] += pos_err
                # In-contact proxy: pusher still riding above the body centre and
                # well clear of the ground (not yet fallen off).
                push_pos, _ = push[nm].get_world_pose()
                push_z = float(np.asarray(push_pos).reshape(-1)[2])
                if push_z > pos_a[2] and push_z > 0.3:
                    a["contact_frames"] += 1
                    a["max_pos_err_contact_m"] = max(
                        a["max_pos_err_contact_m"], pos_err
                    )

        all_flags = []
        for s in specs:
            nm = s["name"]
            a = acc[nm]
            push_pos, _ = push[nm].get_world_pose()
            push_z_final = float(np.asarray(push_pos).reshape(-1)[2])
            mean_pos = a["sum_pos_err_m"] / float(args.steps)
            body = {
                "name": nm,
                "link_class": s["link_class"],
                "kind": s["kind"],
                "dims": s["dims"],
                "max_pos_err_m": a["max_pos_err_m"],
                "mean_pos_err_m": mean_pos,
                "max_ang_err_deg": a["max_ang_err_deg"],
                "pusher_final_z_m": push_z_final,
                "pusher_carried_frames": a["contact_frames"],
                "pusher_carried": bool(push_z_final > 0.3),
                "zero_error": bool(
                    a["max_pos_err_m"] < 1e-4 and a["max_ang_err_deg"] < 1e-2
                ),
            }
            result["bodies"].append(body)
            all_flags.append(body["zero_error"])

        result["all_zero_error"] = bool(all_flags) and all(all_flags)

    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
    finally:
        try:
            Path(args.out).write_text(json.dumps(result, indent=2))
        except Exception:  # noqa: BLE001
            pass
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1 if result["error"] else 0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument("--steps", type=int, default=360, help="Trajectory steps.")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
