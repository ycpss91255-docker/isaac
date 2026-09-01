#!/usr/bin/env python3
"""L2.5 dynamic-object interaction (finite-spring actuator) on Isaac Sim 6.0.1.

Re-validates the dynamic-object interaction experiments -- #201 (a mover pushing
an independent dynamic object) and #217/#218 (a mover carrying a resting dynamic
payload) -- but with an L2.5 actuator instead of the TRUE L2 KINEMATIC mover the
originals used.

Why this experiment exists
--------------------------
#201/#217/#218 were validated with a TRUE L2 KINEMATIC mover. PhysX guarantees a
kinematic actor is INFINITE MASS: "A kinematic actor can push away dynamic
objects, but nothing pushes it back" (ADR-0008 coexistence rule 1). Measured on
6.0.1 the kinematic mover's tracking error was 6e-8 m (0.00006 mm) even during
contact -- effectively 0.000; the cube was pushed ~1.19 m; the payload rode.

But the REAL deployed actuator is L2.5: a DYNAMIC rigid body held by a
very-high-stiffness JOINT DRIVE -- a finite spring, not an infinite mass. A
finite spring CAN be shoved back by contact reaction (back-off) and CAN sag / lag
under load and acceleration. So the L2 numbers do NOT automatically transfer. This
driver measures whether L2.5 still behaves acceptably (approximates L2) and, if
so, at what stiffness k.

The L2.5 actuator, built directly in USD (no UrdfConverter)
-----------------------------------------------------------
Per swept stiffness k, a lane contains:

  * a base ANCHOR body: a plain rigid body with physics:kinematicEnabled=True,
    used ONLY as the fixed end of the joint. It is NOT an ArticulationRootAPI and
    we NEVER call a tensor get_transforms on it -- so this is emphatically NOT the
    #803 maximal-loop-fixed-joint + get_transforms SIGSEGV case. It is a plain
    maximal prismatic joint between two rigid bodies.
  * a DYNAMIC slider/platform rigid body (the mover itself), free to translate
    along +X only.
  * a UsdPhysics.PrismaticJoint (axis X) between anchor (body0) and slider
    (body1), carrying a UsdPhysics.DriveAPI("linear"): stiffness = k (plain N/m,
    NO pi/180 -- that scaling is angular only), damping = 2*sqrt(k*m) (critical),
    maxForce = inf (the drive never saturates), and a per-tick target position.

The joint local frames are authored so joint-position 0 == the slider's initial
world X, hence commanded world X = slider_x0 + drive_target, and the slider is
read back with isaacsim.core.prims.SingleRigidPrim.get_world_pose ONLY.

MODE = push  (L2.5 analog of #201)
----------------------------------
The L2 kinematic pusher plate is replaced by the L2.5 slider plate; a free
dynamic cube sits in front on the ground, exactly like exp_l2_push_dynamic.py.
The plate floats a hair above the ground (bottom z=0.02) so the ONLY horizontal
force on it is the drive and the cube-contact reaction -- ground friction on the
plate would otherwise contaminate the back-off measurement. The SAME command as
the L2 driver is issued as the drive target: warm-up hold at x0, then a linear
sweep to x0+2.0 m straight into the cube, then a hold/settle. Per k:
  (a) cube +X displacement + max speed (did the L2.5 mover still push it?),
  (b) PUSHER BACK-OFF = max |slider_x - commanded_x|, overall and restricted to
      contact frames (the finite-spring reaction the mover feels; L2 was 0.000),
      reported in mm,
  (c) steady lag after contact settles (settle-window mean |slider_x - cmd_x|).

MODE = carry  (L2.5 analog of #217/#218)
----------------------------------------
An L2.5 carrier: a dynamic platform on the same high-stiffness prismatic X drive,
with a free dynamic payload cube resting on its top under gravity + friction
(mu=0.5 physics material on both, so the payload can slip). The commanded move is
a constant-accel / constant-decel profile (triangular velocity, zero at both
ends; A=0.75 m/s^2, so peak per-tick displacement ~0.031 m/tick, inside the L2
"clean carry" band of <=0.05 m/tick). Per k:
  (a) does the payload ride: payload +X travel vs carrier +X travel, and
      retention (stayed on the platform top, did not slip/launch to the ground),
  (b) carrier SAG/LAG under the payload weight + acceleration: carrier tracking
      error |slider_x - commanded_x| in mm (max over the move, steady value on the
      accel plateau, and residual in the settle window), vs the L2 clean-carry
      baseline (#217/#218: clean <=0.05 m/tick carried, launches at 0.2 m/tick).

Results are written as JSON to ``--out`` (a MOUNTED path) so the host reads them
back; stdout through the docker run wrapper is not reliably captured. Teardown is
an explicit ``os._exit`` (isaac#248 round 9): a cold headless 6.0.1 container's
Omniverse Hub connector aborts SimulationApp.close() with a busy-TaskGroup
SIGABRT; os._exit reaches the same clean exit while skipping that teardown.

CLI::

    /isaac-sim/python.sh exp_l25_dynamic_interaction.py --mode push \\
        --out /home/<user>/work/worktree/<wt>/test/.l25-dynamic-push.json
    /isaac-sim/python.sh exp_l25_dynamic_interaction.py --mode carry \\
        --out /home/<user>/work/worktree/<wt>/test/.l25-dynamic-carry.json
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# Stiffness sweep (N/m). k=1e4 is the soft end, k=1e7 the stiff end; the knee at
# which L2.5 back-off / lag falls below the acceptance bar is the finding.
_STIFFNESS = [1e4, 1e5, 1e6, 1e7]

_LANE_SPACING_Y = 4.0        # y gap between independent lanes (no interaction)
_ANCHOR_BEHIND_X = 0.5       # anchor placed this far behind the slider start
_SLIDER_MASS = 1.0           # mover mass (kg); damping = 2*sqrt(k*mass)

# ----- MODE=push geometry (mirrors exp_l2_push_dynamic.py) -------------------
_PUSH_PLATE_DIMS = (0.10, 1.00, 0.60)   # sx, sy, sz (thin in X, wide/tall face)
_PUSH_PLATE_X0 = 0.0                     # slider centre start x
_PUSH_SWEEP_M = 2.0                      # linear sweep distance into the cube
# Float the plate a hair off the ground so the ONLY horizontal load is the drive
# + the cube contact reaction (ground friction would pollute back-off).
_PUSH_PLATE_Z = 0.32                     # centre z -> bottom at 0.02 (floats)
_PUSH_CUBE_SIZE = 0.30
_PUSH_CUBE_DX = 1.00                     # cube centre x = slider_x0 + this
_PUSH_CUBE_Z = 0.15                      # centre z so bottom rests on ground

# ----- MODE=carry geometry (mirrors exp_l2_carry_speed_limit.py) ------------
_CARRY_PLATE_DIMS = (2.0, 0.6, 0.2)      # sx, sy, sz -> half-length in X = 1.0
_CARRY_PLATE_TOP_Z = 0.7                 # platform top surface height
_CARRY_PAYLOAD_SIZE = 0.2
_CARRY_MU = 0.5                          # friction (static=dynamic) on both
_CARRY_ACCEL = 0.75                      # m/s^2 constant accel then decel
_CARRY_CARRIED_Z = 0.45                  # payload z above this => still on top


def _author_l25_actuator(stage, tag, x0, y0, z0, dims, mass, k):
    """Author anchor + dynamic slider + prismatic X drive at stiffness k.

    Returns (anchor_path, slider_path, joint_path). Joint-position 0 == the
    slider's initial world X, so commanded world X = x0 + drive_target.
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    # --- base anchor: plain kinematic rigid body, NO collider, joint end only.
    anchor_x = x0 - _ANCHOR_BEHIND_X
    anchor_path = f"/World/anchor_{tag}"
    anchor = UsdGeom.Cube.Define(stage, anchor_path)
    anchor.GetSizeAttr().Set(0.1)  # tiny, unscaled -> local frame == world offset
    anchor.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(anchor_x, y0, z0)
    )
    aprim = anchor.GetPrim()
    arb = UsdPhysics.RigidBodyAPI.Apply(aprim)
    arb.CreateKinematicEnabledAttr(True)  # anchor: fixed end (NOT articulation)
    UsdPhysics.MassAPI.Apply(aprim).CreateMassAttr(1.0)

    # --- dynamic slider/platform: the L2.5 mover, free along +X only.
    slider_path = f"/World/slider_{tag}"
    slider = UsdGeom.Cube.Define(stage, slider_path)
    slider.GetSizeAttr().Set(1.0)
    slider.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(x0, y0, z0))
    slider.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(*dims))
    sprim = slider.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(sprim)  # dynamic (kinematic default off)
    UsdPhysics.CollisionAPI.Apply(sprim)
    UsdPhysics.MassAPI.Apply(sprim).CreateMassAttr(float(mass))
    PhysxSchema.PhysxRigidBodyAPI.Apply(sprim)

    # --- prismatic joint (axis X) anchor(body0) -> slider(body1).
    joint_path = f"/World/joint_{tag}"
    joint = UsdPhysics.PrismaticJoint.Define(stage, joint_path)
    joint.CreateAxisAttr("X")
    joint.CreateBody0Rel().SetTargets([anchor_path])
    joint.CreateBody1Rel().SetTargets([slider_path])
    # Joint frames: coincide at the slider origin initially -> q0 = 0. localPos0
    # is in the (unscaled) anchor frame; localPos1 = origin (scale-invariant).
    joint.CreateLocalPos0Attr(Gf.Vec3f(_ANCHOR_BEHIND_X, 0.0, 0.0))
    joint.CreateLocalPos1Attr(Gf.Vec3f(0.0, 0.0, 0.0))
    joint.CreateLocalRot0Attr(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    joint.CreateLocalRot1Attr(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    # No translation limits authored -> free along X; the drive positions it.

    damping = 2.0 * math.sqrt(k * mass)  # critical (linear)
    drive = UsdPhysics.DriveAPI.Apply(joint.GetPrim(), "linear")
    drive.CreateTypeAttr().Set("force")
    drive.CreateStiffnessAttr().Set(float(k))
    drive.CreateDampingAttr().Set(float(damping))
    drive.CreateTargetPositionAttr().Set(0.0)
    drive.CreateMaxForceAttr().Set(float("inf"))  # never saturates

    return anchor_path, slider_path, joint_path, damping


def _set_drive_target(stage, joint_path, target_q):
    """Update the linear drive target position on the prismatic joint."""
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "linear")
    drive.GetTargetPositionAttr().Set(float(target_q))


# ===========================================================================
# MODE = push
# ===========================================================================
def _run_push(args, app):
    import numpy as np
    import omni.usd
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    result = {
        "mode": "push",
        "issue": "isaac#201 (L2.5 re-validation)",
        "actuator": "L2.5 = dynamic slider on high-stiffness prismatic X drive",
        "isaac_variant": "6.0.1",
        "warmup_steps": args.warmup,
        "sweep_steps": args.steps,
        "settle_steps": args.settle,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "slider_mass_kg": _SLIDER_MASS,
        "plate_dims_m": list(_PUSH_PLATE_DIMS),
        "plate_sweep_m": _PUSH_SWEEP_M,
        "stiffness_sweep": list(_STIFFNESS),
        "l2_baseline_6_0_1": (
            "kinematic pusher (exp_l2_push_dynamic): back-off 6.0e-8 m "
            "(6.0e-5 mm) overall AND under contact; cube pushed 1.193 m; "
            "peak speed 0.400 m/s; cube stayed on ground"
        ),
        "metric": (
            "per k: (a) cube +X displacement (m) + max speed (m/s); "
            "(b) pusher back-off = max |slider_x - commanded_x| overall and on "
            "contact frames (mm); (c) steady lag = settle-window mean "
            "|slider_x - commanded_x| (mm)"
        ),
        "drive_api": (
            "UsdPhysics.PrismaticJoint (axis X, maximal joint between kinematic "
            "anchor + dynamic slider) with UsdPhysics.DriveAPI('linear') "
            "stiffness=k, damping=2*sqrt(k*m), maxForce=inf; target set per tick; "
            "slider read via SingleRigidPrim.get_world_pose"
        ),
        "points": [],
        "error": None,
    }

    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    UsdGeom.Xform.Define(stage, "/World")
    UsdLux.DistantLight.Define(stage, "/World/SunLight").CreateIntensityAttr(3000.0)

    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(400.0, 400.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    plate_half_x = _PUSH_PLATE_DIMS[0] * 0.5
    cube_half = _PUSH_CUBE_SIZE * 0.5
    contact_margin = 0.02

    lanes = []
    for i, k in enumerate(_STIFFNESS):
        y0 = i * _LANE_SPACING_Y
        tag = f"k{int(k):d}"
        _a, slider_path, joint_path, damping = _author_l25_actuator(
            stage, tag, _PUSH_PLATE_X0, y0, _PUSH_PLATE_Z,
            _PUSH_PLATE_DIMS, _SLIDER_MASS, k,
        )
        cube_path = f"/World/cube_{tag}"
        cube = UsdGeom.Cube.Define(stage, cube_path)
        cube.GetSizeAttr().Set(1.0)
        cube.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
            Gf.Vec3d(_PUSH_PLATE_X0 + _PUSH_CUBE_DX, y0, _PUSH_CUBE_Z)
        )
        cube.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
            Gf.Vec3f(_PUSH_CUBE_SIZE, _PUSH_CUBE_SIZE, _PUSH_CUBE_SIZE)
        )
        cprim = cube.GetPrim()
        UsdPhysics.RigidBodyAPI.Apply(cprim)
        UsdPhysics.CollisionAPI.Apply(cprim)
        UsdPhysics.MassAPI.Apply(cprim).CreateMassAttr(1.0)
        PhysxSchema.PhysxRigidBodyAPI.Apply(cprim).CreateLinearDampingAttr(0.2)
        lanes.append({
            "k": k, "tag": tag, "y0": y0, "x0": _PUSH_PLATE_X0,
            "slider_path": slider_path, "joint_path": joint_path,
            "cube_path": cube_path, "damping": damping,
        })

    world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                  rendering_dt=args.dt)
    world.reset()

    slider = {ln["tag"]: SingleRigidPrim(ln["slider_path"]) for ln in lanes}
    cube = {ln["tag"]: SingleRigidPrim(ln["cube_path"]) for ln in lanes}

    total = args.warmup + args.steps + args.settle
    acc = {ln["tag"]: {
        "max_backoff": 0.0, "max_backoff_contact": 0.0, "contact_frames": 0,
        "cube_baseline": None, "cube_prev": None, "cube_max_speed": 0.0,
        "cube_min_z": float("inf"), "cube_max_z": float("-inf"),
        "settle_err_sum": 0.0, "settle_n": 0,
    } for ln in lanes}

    for step_i in range(total):
        if step_i < args.warmup:
            target_q = 0.0
        elif step_i < args.warmup + args.steps:
            phase = (step_i - args.warmup) / float(args.steps)
            target_q = _PUSH_SWEEP_M * phase
        else:
            target_q = _PUSH_SWEEP_M
        for ln in lanes:
            _set_drive_target(stage, ln["joint_path"], target_q)
        world.step(render=False)

        for ln in lanes:
            tag = ln["tag"]
            a = acc[tag]
            spos, _ = slider[tag].get_world_pose()
            spos = np.asarray(spos, dtype=float).reshape(-1)
            slider_x = float(spos[0])
            commanded_x = ln["x0"] + target_q
            backoff = abs(slider_x - commanded_x)
            a["max_backoff"] = max(a["max_backoff"], backoff)

            cpos, _ = cube[tag].get_world_pose()
            cpos = np.asarray(cpos, dtype=float).reshape(-1)
            a["cube_min_z"] = min(a["cube_min_z"], float(cpos[2]))
            a["cube_max_z"] = max(a["cube_max_z"], float(cpos[2]))

            if step_i == args.warmup - 1:
                a["cube_baseline"] = cpos.copy()
                a["cube_prev"] = cpos.copy()

            if step_i >= args.warmup:
                if a["cube_prev"] is not None:
                    speed = float(np.linalg.norm(cpos - a["cube_prev"]) / args.dt)
                    a["cube_max_speed"] = max(a["cube_max_speed"], speed)
                a["cube_prev"] = cpos.copy()

                plate_front = slider_x + plate_half_x
                cube_back = float(cpos[0]) - cube_half
                if plate_front >= cube_back - contact_margin:
                    a["contact_frames"] += 1
                    a["max_backoff_contact"] = max(
                        a["max_backoff_contact"], backoff
                    )

            if step_i >= args.warmup + args.steps:
                a["settle_err_sum"] += backoff
                a["settle_n"] += 1

    for ln in lanes:
        tag = ln["tag"]
        a = acc[tag]
        cpos_final, _ = cube[tag].get_world_pose()
        cpos_final = np.asarray(cpos_final, dtype=float).reshape(-1)
        if a["cube_baseline"] is None:
            a["cube_baseline"] = cpos_final
        disp = cpos_final - a["cube_baseline"]
        disp_x = float(disp[0])
        steady_lag = (
            a["settle_err_sum"] / a["settle_n"] if a["settle_n"] else float("nan")
        )
        result["points"].append({
            "stiffness": ln["k"],
            "damping_critical": ln["damping"],
            "cube_displacement_x_m": disp_x,
            "cube_max_speed_mps": a["cube_max_speed"],
            "cube_final_z_m": float(cpos_final[2]),
            "cube_min_z_m": a["cube_min_z"],
            "contact_frames": a["contact_frames"],
            "backoff_overall_mm": a["max_backoff"] * 1000.0,
            "backoff_contact_mm": a["max_backoff_contact"] * 1000.0,
            "steady_lag_mm": steady_lag * 1000.0,
            "cube_pushed": bool(disp_x > 0.3 and a["cube_max_speed"] > 1e-3),
            "cube_on_ground": bool(
                abs(float(cpos_final[2]) - _PUSH_CUBE_Z) < 0.05
                and a["cube_min_z"] > 0.0
            ),
        })
    return result


# ===========================================================================
# MODE = carry
# ===========================================================================
def _carry_target(t, T, accel):
    """Constant-accel then constant-decel position at time t in [0, T]."""
    half = T * 0.5
    if t <= half:
        return 0.5 * accel * t * t
    v_peak = accel * half
    x_half = 0.5 * accel * half * half
    td = t - half
    return x_half + v_peak * td - 0.5 * accel * td * td


def _run_carry(args, app):
    import numpy as np
    import omni.usd
    from isaacsim.core.api import World
    from isaacsim.core.api.materials import PhysicsMaterial
    from isaacsim.core.prims import SingleGeometryPrim, SingleRigidPrim
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    plate_cz = _CARRY_PLATE_TOP_Z - _CARRY_PLATE_DIMS[2] * 0.5   # centre z
    payload_cz0 = _CARRY_PLATE_TOP_Z + _CARRY_PAYLOAD_SIZE * 0.5 + 0.005
    T_move = args.steps * args.dt
    total_travel = _carry_target(T_move, T_move, _CARRY_ACCEL)
    peak_vel = _CARRY_ACCEL * (T_move * 0.5)

    result = {
        "mode": "carry",
        "issue": "isaac#217/#218 (L2.5 re-validation)",
        "actuator": "L2.5 = dynamic platform on high-stiffness prismatic X drive",
        "isaac_variant": "6.0.1",
        "warmup_steps": args.warmup,
        "move_steps": args.steps,
        "settle_steps": args.settle,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "carrier_mass_kg": _SLIDER_MASS,
        "payload_mass_kg": 1.0,
        "friction_mu": _CARRY_MU,
        "plate_dims_m": list(_CARRY_PLATE_DIMS),
        "payload_size_m": _CARRY_PAYLOAD_SIZE,
        "accel_mps2": _CARRY_ACCEL,
        "total_travel_m": total_travel,
        "peak_velocity_mps": peak_vel,
        "peak_per_tick_m": peak_vel * args.dt,
        "stiffness_sweep": list(_STIFFNESS),
        "l2_baseline_ref": (
            "#217/#218 kinematic carry: clean carry <=0.05 m/tick, launches at "
            "0.2 m/tick; kinematic tracking error ~0"
        ),
        "metric": (
            "per k: (a) payload rides: payload +X travel vs carrier +X travel + "
            "retention (payload z stayed on platform top); (b) carrier tracking "
            "error |slider_x - commanded_x| in mm: max over move, steady on accel "
            "plateau, residual in settle"
        ),
        "drive_api": (
            "UsdPhysics.PrismaticJoint (axis X, maximal joint between kinematic "
            "anchor + dynamic platform) with UsdPhysics.DriveAPI('linear') "
            "stiffness=k, damping=2*sqrt(k*m), maxForce=inf; constant accel/decel "
            "target per tick; carrier + payload read via SingleRigidPrim"
        ),
        "friction_api": (
            "isaacsim.core.api.materials.PhysicsMaterial + "
            "SingleGeometryPrim.apply_physics_material on platform AND payload"
        ),
        "points": [],
        "error": None,
    }

    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    UsdGeom.Xform.Define(stage, "/World")
    UsdLux.DistantLight.Define(stage, "/World/SunLight").CreateIntensityAttr(3000.0)

    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(800.0, 800.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    lanes = []
    for i, k in enumerate(_STIFFNESS):
        y0 = i * _LANE_SPACING_Y
        tag = f"k{int(k):d}"
        _a, slider_path, joint_path, damping = _author_l25_actuator(
            stage, tag, 0.0, y0, plate_cz,
            _CARRY_PLATE_DIMS, _SLIDER_MASS, k,
        )
        payload_path = f"/World/payload_{tag}"
        payload = UsdGeom.Cube.Define(stage, payload_path)
        payload.GetSizeAttr().Set(1.0)
        payload.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
            Gf.Vec3d(0.0, y0, payload_cz0)
        )
        payload.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
            Gf.Vec3f(_CARRY_PAYLOAD_SIZE, _CARRY_PAYLOAD_SIZE, _CARRY_PAYLOAD_SIZE)
        )
        pprim = payload.GetPrim()
        UsdPhysics.RigidBodyAPI.Apply(pprim)
        UsdPhysics.CollisionAPI.Apply(pprim)
        UsdPhysics.MassAPI.Apply(pprim).CreateMassAttr(1.0)
        PhysxSchema.PhysxRigidBodyAPI.Apply(pprim).CreateLinearDampingAttr(0.05)
        lanes.append({
            "k": k, "tag": tag, "y0": y0, "slider_path": slider_path,
            "joint_path": joint_path, "payload_path": payload_path,
            "plate_cz": plate_cz, "damping": damping,
        })

    # Friction material on platform AND payload (Isaac core path writes the
    # physics-purpose binding PhysX actually reads).
    mat = PhysicsMaterial(
        prim_path="/World/PhysMat_carry",
        name="physmat_carry",
        static_friction=_CARRY_MU,
        dynamic_friction=_CARRY_MU,
        restitution=0.0,
    )
    for ln in lanes:
        SingleGeometryPrim(ln["slider_path"]).apply_physics_material(mat)
        SingleGeometryPrim(ln["payload_path"]).apply_physics_material(mat)

    world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                  rendering_dt=args.dt)
    world.reset()

    slider = {ln["tag"]: SingleRigidPrim(ln["slider_path"]) for ln in lanes}
    payload = {ln["tag"]: SingleRigidPrim(ln["payload_path"]) for ln in lanes}

    total = args.warmup + args.steps + args.settle
    # Steady-accel plateau window: middle of the first accel half.
    plateau_lo = args.warmup + int(args.steps * 0.15)
    plateau_hi = args.warmup + int(args.steps * 0.40)

    acc = {ln["tag"]: {
        "max_err": 0.0, "plateau_sum": 0.0, "plateau_n": 0,
        "settle_sum": 0.0, "settle_n": 0,
        "payload_x_base": None, "slider_x_base": None,
    } for ln in lanes}

    for step_i in range(total):
        if step_i < args.warmup:
            target_q = 0.0
        elif step_i < args.warmup + args.steps:
            t = (step_i - args.warmup) * args.dt
            target_q = _carry_target(t, T_move, _CARRY_ACCEL)
        else:
            target_q = total_travel
        for ln in lanes:
            _set_drive_target(stage, ln["joint_path"], target_q)
        world.step(render=False)

        for ln in lanes:
            tag = ln["tag"]
            a = acc[tag]
            spos, _ = slider[tag].get_world_pose()
            spos = np.asarray(spos, dtype=float).reshape(-1)
            slider_x = float(spos[0])
            err = abs(slider_x - target_q)

            if step_i == args.warmup - 1:
                ppos, _ = payload[tag].get_world_pose()
                ppos = np.asarray(ppos, dtype=float).reshape(-1)
                a["payload_x_base"] = float(ppos[0])
                a["slider_x_base"] = slider_x

            if step_i >= args.warmup:
                a["max_err"] = max(a["max_err"], err)
            if plateau_lo <= step_i < plateau_hi:
                a["plateau_sum"] += err
                a["plateau_n"] += 1
            if step_i >= args.warmup + args.steps:
                a["settle_sum"] += err
                a["settle_n"] += 1

    for ln in lanes:
        tag = ln["tag"]
        a = acc[tag]
        spos, _ = slider[tag].get_world_pose()
        spos = np.asarray(spos, dtype=float).reshape(-1)
        ppos, _ = payload[tag].get_world_pose()
        ppos = np.asarray(ppos, dtype=float).reshape(-1)
        base_p = a["payload_x_base"] if a["payload_x_base"] is not None else 0.0
        base_s = a["slider_x_base"] if a["slider_x_base"] is not None else 0.0
        carrier_travel = float(spos[0]) - base_s
        payload_travel = float(ppos[0]) - base_p
        payload_z = float(ppos[2])
        rel_x = float(ppos[0] - spos[0])
        plateau_err = (
            a["plateau_sum"] / a["plateau_n"] if a["plateau_n"] else float("nan")
        )
        settle_err = (
            a["settle_sum"] / a["settle_n"] if a["settle_n"] else float("nan")
        )
        result["points"].append({
            "stiffness": ln["k"],
            "damping_critical": ln["damping"],
            "carrier_travel_x_m": carrier_travel,
            "payload_travel_x_m": payload_travel,
            "payload_lag_m": carrier_travel - payload_travel,
            "payload_z_final_m": payload_z,
            "payload_rel_x_m": rel_x,
            "payload_rode": bool(payload_z > _CARRY_CARRIED_Z),
            "carrier_track_err_max_mm": a["max_err"] * 1000.0,
            "carrier_track_err_plateau_mm": plateau_err * 1000.0,
            "carrier_track_err_settle_mm": settle_err * 1000.0,
        })
    return result


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {"mode": args.mode, "error": None}
    try:
        if args.mode == "push":
            result = _run_push(args, app)
        elif args.mode == "carry":
            result = _run_carry(args, app)
        else:
            raise ValueError(f"unknown mode: {args.mode}")
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
        os._exit(1 if result.get("error") else 0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--mode", required=True, choices=["push", "carry"],
                   help="push (analog of #201) or carry (analog of #217/#218).")
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument("--warmup", type=int, default=60,
                   help="Warm-up steps (drive holds at start; scene settles).")
    p.add_argument("--steps", type=int, default=300,
                   help="Active-phase steps (push sweep / carry move).")
    p.add_argument("--settle", type=int, default=120,
                   help="Settle steps (drive holds at end target).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
