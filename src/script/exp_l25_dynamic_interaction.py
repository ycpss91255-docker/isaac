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

MODE = viz  (RENDER the push so a human WATCHES the back-off)
------------------------------------------------------------
The push modes above run headless (render=False) and only emit numbers. ``viz``
re-runs the SAME push scene with render=True on the GPU and captures an ANNOTATED
RTX frame sequence at TWO stiffnesses -- k=1e4 (soft: the ~6.8 mm back-off is
visible to the eye) and k=1e6 (stiff: back-off ~0.035 mm, visually vanishes) --
so a viewer literally SEES the back-off shrink as k rises. The RTX-headless
frame-capture recipe (histogram/auto-exposure off, own acceptance camera, rgb
annotator on a replicator render product, converge-then-read-back-as-numpy,
non-black verification) is mirrored from ``exp_visual_metric_acceptance.py``
(isaac#209). Additions for visual clarity, per k:

  * a side/isometric CAMERA where the +X push motion is horizontal in the frame
    (pusher + cube + ground all in view);
  * a bright-green emissive COMMAND-REFERENCE MARKER (a thin tall bar) placed each
    frame at the COMMANDED plate front face (cmd_x + plate_half_x). The blue
    pusher plate's actual front face trails this marker by EXACTLY the back-off,
    so the visible horizontal gap IS the finite-spring back-off;
  * a per-frame text HUD (PIL) printing k, t, cmd_x, actual_x, back_off (mm),
    cube_x, cube_speed for THAT exact frame (read from the sim at capture time,
    never interpolated).

Outputs (all MOUNTED): per-k annotated PNG sequence ``push_k1e4_NNN.png`` /
``push_k1e6_NNN.png`` and an assembled GIF ``push_k1e4.gif`` / ``push_k1e6.gif``
under ``--viz-dir`` (default ``<out-parent>/viz``), plus a per-frame JSON trace at
``--out`` so the host can verify each overlay matches the numbers.

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
    /isaac-sim/python.sh exp_l25_dynamic_interaction.py --mode viz \\
        --out /home/<user>/work/worktree/<wt>/test/.l25-viz-trace.json
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

# ----- MODE=viz (render the push at two stiffnesses to SEE back-off) --------
_VIZ_STIFFNESS = [1e4, 1e6]              # soft (~6.8mm, visible) vs stiff (~0.035mm)
_VIZ_N_FRAMES = 32                       # captured frames per k (smooth GIF)
_VIZ_CAM_EYE = (-0.8, -7.0, 2.6)         # side/iso view; +X is horizontal in frame
_VIZ_CAM_TARGET = (1.1, 0.0, 0.30)
_VIZ_MARKER_DIMS = (0.02, 0.06, 1.00)    # thin in X/Y, tall in Z (a vertical bar)
_VIZ_GIF_MS = 150                        # per-frame GIF duration (ms)
_VIZ_WIDTH = 960
_VIZ_HEIGHT = 540


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


# ===========================================================================
# MODE = viz  (render the push at two stiffnesses so a human SEES back-off)
# ===========================================================================
def _viz_klabel(k):
    """Compact stiffness label for file names / HUD: 1e4 -> '1e4'."""
    return "1e%d" % int(round(math.log10(k)))


def _viz_look_at(eye, target, up=(0.0, 0.0, 1.0)):
    """Row-major 4x4 (flat list of 16) camera-to-world (mirror #209 look-at).

    USD cameras look down local -Z with +Y up, so camera +Z = normalize(eye-target);
    basis vectors go in the ROWS, translation in the last row (Gf.Matrix4d row-major).
    """
    def sub(a, b):
        return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1],
                a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0])

    def norm(a):
        n = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
        return (a[0] / n, a[1] / n, a[2] / n) if n else a

    z = norm(sub(eye, target))
    x = norm(cross(up, z))
    y = cross(z, x)
    return [
        x[0], x[1], x[2], 0.0,
        y[0], y[1], y[2], 0.0,
        z[0], z[1], z[2], 0.0,
        eye[0], eye[1], eye[2], 1.0,
    ]


def _viz_material(stage, path, rgb, emissive=None, rough=0.6):
    """UsdPreviewSurface material; optional emissiveColor for the marker glow."""
    from pxr import Gf, Sdf, UsdShade

    m = UsdShade.Material.Define(stage, path)
    s = UsdShade.Shader.Define(stage, path + "/Shader")
    s.CreateIdAttr("UsdPreviewSurface")
    s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
    s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(rough)
    s.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    if emissive is not None:
        s.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).Set(
            Gf.Vec3f(*emissive)
        )
    m.CreateSurfaceOutput().ConnectToSource(s.ConnectableAPI(), "surface")
    return m


def _viz_bind(stage, prim_path, material):
    from pxr import UsdShade

    UsdShade.MaterialBindingAPI.Apply(stage.GetPrimAtPath(prim_path)).Bind(material)


def _viz_font(size):
    """A readable font for the HUD; fall back to PIL's default if none on disk."""
    from PIL import ImageFont

    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except Exception:  # noqa: BLE001
            continue
    try:
        return ImageFont.load_default(size)
    except Exception:  # noqa: BLE001
        return ImageFont.load_default()


def _viz_text_w(font, draw, s):
    try:
        return draw.textlength(s, font=font)
    except Exception:  # noqa: BLE001
        b = font.getbbox(s)
        return b[2] - b[0]


def _viz_overlay(rgb, lines):
    """Draw the per-frame HUD lines onto an HxWx3 uint8 frame; return a PIL Image."""
    from PIL import Image, ImageDraw

    img = Image.fromarray(rgb, mode="RGB").convert("RGB")
    draw = ImageDraw.Draw(img)
    font = _viz_font(20)
    pad, lh = 8, 26
    wmax = max(_viz_text_w(font, draw, ln) for ln in lines)
    draw.rectangle(
        [8, 8, 8 + int(wmax) + pad * 2, 8 + pad * 2 + lh * len(lines)],
        fill=(0, 0, 0),
    )
    y = 8 + pad
    for ln in lines:
        draw.text((8 + pad, y), ln, fill=(240, 240, 60), font=font)
        y += lh
    return img


def _run_viz(args, app):
    import numpy as np
    import carb
    import omni.replicator.core as rep
    import omni.usd
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    viz_dir = args.viz_dir or str(Path(args.out).parent / "viz")
    Path(viz_dir).mkdir(parents=True, exist_ok=True)

    stiffnesses = [args.stiffness] if args.stiffness else list(_VIZ_STIFFNESS)
    plate_half_x = _PUSH_PLATE_DIMS[0] * 0.5
    total = args.warmup + args.steps + args.settle
    cap_steps = sorted(set(
        int(round(v)) for v in np.linspace(args.warmup, total - 1, _VIZ_N_FRAMES)
    ))

    result = {
        "mode": "viz",
        "issue": "isaac#201 (L2.5 push, rendered for human visual confirmation)",
        "actuator": "L2.5 = dynamic slider on high-stiffness prismatic X drive",
        "isaac_variant": "6.0.1",
        "render": True,
        "capture_recipe": (
            "mirror exp_visual_metric_acceptance.py (#209): histogram/auto-exposure "
            "off, own camera prim, omni.replicator.core rgb annotator on a render "
            "product, converge via world.render() then read back as numpy, verify "
            "non-black"
        ),
        "warmup_steps": args.warmup,
        "sweep_steps": args.steps,
        "settle_steps": args.settle,
        "physics_dt": args.dt,
        "width": args.width,
        "height": args.height,
        "stiffnesses": stiffnesses,
        "n_frames_target": _VIZ_N_FRAMES,
        "cam_eye": list(_VIZ_CAM_EYE),
        "cam_target": list(_VIZ_CAM_TARGET),
        "viz_dir": viz_dir,
        "marker": (
            "bright-green emissive vertical bar placed each frame at the COMMANDED "
            "plate front face (cmd_x + plate_half_x); the blue plate front face "
            "trails it by exactly the back-off, so the visible gap IS the back-off"
        ),
        "hud_fields": [
            "k", "t_s", "cmd_x_m", "actual_x_m", "back_off_mm",
            "cube_x_m", "cube_speed_mps",
        ],
        "per_k": {},
        "error": None,
    }

    # RTX auto-exposure off (histogram) -- mirror #209 so brightness is stable.
    carb.settings.get_settings().set("/rtx/post/histogram/enabled", False)

    for k in stiffnesses:
        tag = f"k{_viz_klabel(k)}"
        World.clear_instance()

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        UsdGeom.Xform.Define(stage, "/World")

        # Non-black lit stage (dome + distant key), mirror #209's discipline.
        UsdLux.DomeLight.Define(stage, "/World/DomeLight").CreateIntensityAttr(250.0)
        key = UsdLux.DistantLight.Define(stage, "/World/KeyLight")
        key.CreateIntensityAttr(1200.0)
        key.CreateAngleAttr(0.53)
        UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(
            Gf.Vec3f(-40.0, 20.0, 0.0)
        )

        gray = _viz_material(stage, "/World/Looks/Gray", (0.50, 0.50, 0.52))
        blue = _viz_material(stage, "/World/Looks/Blue", (0.10, 0.35, 0.85))
        orange = _viz_material(stage, "/World/Looks/Orange", (0.95, 0.45, 0.10))
        green = _viz_material(
            stage, "/World/Looks/MarkerGreen", (0.10, 1.0, 0.10),
            emissive=(0.10, 1.0, 0.10),
        )

        ground = UsdGeom.Cube.Define(stage, "/World/Ground")
        ground.GetSizeAttr().Set(1.0)
        ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
            Gf.Vec3d(0.0, 0.0, -0.5)
        )
        ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
            Gf.Vec3f(400.0, 400.0, 1.0)
        )
        UsdPhysics.CollisionAPI.Apply(ground.GetPrim())
        _viz_bind(stage, "/World/Ground", gray)

        _a, slider_path, joint_path, _damp = _author_l25_actuator(
            stage, tag, _PUSH_PLATE_X0, 0.0, _PUSH_PLATE_Z,
            _PUSH_PLATE_DIMS, _SLIDER_MASS, k,
        )
        _viz_bind(stage, slider_path, blue)

        cube_path = f"/World/cube_{tag}"
        cube = UsdGeom.Cube.Define(stage, cube_path)
        cube.GetSizeAttr().Set(1.0)
        cube.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
            Gf.Vec3d(_PUSH_PLATE_X0 + _PUSH_CUBE_DX, 0.0, _PUSH_CUBE_Z)
        )
        cube.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
            Gf.Vec3f(_PUSH_CUBE_SIZE, _PUSH_CUBE_SIZE, _PUSH_CUBE_SIZE)
        )
        cprim = cube.GetPrim()
        UsdPhysics.RigidBodyAPI.Apply(cprim)
        UsdPhysics.CollisionAPI.Apply(cprim)
        UsdPhysics.MassAPI.Apply(cprim).CreateMassAttr(1.0)
        PhysxSchema.PhysxRigidBodyAPI.Apply(cprim).CreateLinearDampingAttr(0.2)
        _viz_bind(stage, cube_path, orange)

        # Visual-only command marker: NO RigidBodyAPI / NO CollisionAPI, so it
        # never perturbs the physics -- we just re-place it each frame.
        marker_path = "/World/cmd_marker"
        marker = UsdGeom.Cube.Define(stage, marker_path)
        marker.GetSizeAttr().Set(1.0)
        marker_t = marker.AddXformOp(UsdGeom.XformOp.TypeTranslate)
        marker_t.Set(Gf.Vec3d(_PUSH_PLATE_X0 + plate_half_x, 0.0, _PUSH_PLATE_Z))
        marker.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
            Gf.Vec3f(*_VIZ_MARKER_DIMS)
        )
        _viz_bind(stage, marker_path, green)

        # Own acceptance camera (deterministic framing; +X horizontal in frame).
        cam = UsdGeom.Camera.Define(stage, "/World/VizCam")
        cam.CreateFocalLengthAttr(24.0)
        cam.CreateHorizontalApertureAttr(36.0)
        cam.CreateVerticalApertureAttr(20.25)
        cam.CreateClippingRangeAttr(Gf.Vec2f(0.1, 100000.0))
        UsdGeom.Xformable(cam.GetPrim()).AddTransformOp().Set(
            Gf.Matrix4d(*_viz_look_at(_VIZ_CAM_EYE, _VIZ_CAM_TARGET))
        )

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        slider = SingleRigidPrim(slider_path)
        cube_prim = SingleRigidPrim(cube_path)

        rp = rep.create.render_product("/World/VizCam", (args.width, args.height))
        annot = rep.AnnotatorRegistry.get_annotator("rgb")
        annot.attach(rp)

        # Let RTX load materials + converge before the first capture (render only,
        # no physics -- world.render() does not advance the sim).
        for _ in range(args.warmup):
            world.render()

        def _grab():
            for _ in range(3):
                world.render()
            raw = np.asarray(annot.get_data())
            if raw.size and raw.ndim >= 2 and raw.shape[0] == args.height:
                px = raw[:, :, :3] if (raw.ndim == 3 and raw.shape[2] == 4) else raw
                return np.ascontiguousarray(px.astype(np.uint8))
            return None

        frames_meta = []
        pil_frames = []
        cube_prev = None
        for step_i in range(total):
            if step_i < args.warmup:
                target_q = 0.0
            elif step_i < args.warmup + args.steps:
                target_q = _PUSH_SWEEP_M * (
                    (step_i - args.warmup) / float(args.steps)
                )
            else:
                target_q = _PUSH_SWEEP_M

            _set_drive_target(stage, joint_path, target_q)
            cmd_x = _PUSH_PLATE_X0 + target_q
            # Marker at the COMMANDED plate front face (set before the render).
            marker_t.Set(Gf.Vec3d(cmd_x + plate_half_x, 0.0, _PUSH_PLATE_Z))
            world.step(render=True)

            spos, _ = slider.get_world_pose()
            slider_x = float(np.asarray(spos, dtype=float).reshape(-1)[0])
            cpos, _ = cube_prim.get_world_pose()
            cpos = np.asarray(cpos, dtype=float).reshape(-1)
            cube_x = float(cpos[0])
            cube_speed = (
                float(np.linalg.norm(cpos - cube_prev) / args.dt)
                if cube_prev is not None else 0.0
            )
            cube_prev = cpos.copy()

            if step_i in cap_steps:
                rgb = None
                for _try in range(4):
                    rgb = _grab()
                    if rgb is not None and float(rgb.mean()) > 1.0:
                        break
                idx = len(pil_frames)
                t_s = step_i * args.dt
                back_off_mm = abs(slider_x - cmd_x) * 1000.0
                lines = [
                    f"k = {_viz_klabel(k)} N/m",
                    f"t = {t_s:6.3f} s",
                    f"cmd_x    = {cmd_x:7.4f} m",
                    f"actual_x = {slider_x:7.4f} m",
                    f"back_off = {back_off_mm:7.3f} mm",
                    f"cube_x   = {cube_x:7.4f} m",
                    f"cube_v   = {cube_speed:6.3f} m/s",
                ]
                mean_px = float(rgb.mean()) if rgb is not None else 0.0
                if rgb is None:
                    rgb = np.zeros((args.height, args.width, 3), dtype=np.uint8)
                r = rgb[:, :, 0].astype(float)
                g = rgb[:, :, 1].astype(float)
                b = rgb[:, :, 2].astype(float)
                lum = float((0.2126 * r + 0.7152 * g + 0.0722 * b).mean())
                png_name = f"push_{tag}_{idx:03d}.png"
                img = _viz_overlay(rgb, lines)
                img.save(str(Path(viz_dir) / png_name))
                pil_frames.append(img)
                frames_meta.append({
                    "i": idx, "step": step_i, "t_s": t_s,
                    "cmd_x_m": cmd_x, "actual_x_m": slider_x,
                    "back_off_mm": back_off_mm, "cube_x_m": cube_x,
                    "cube_speed_mps": cube_speed, "png": png_name,
                    "frame_mean_pixel": mean_px, "frame_mean_luminance": lum,
                    "nonblack": bool(mean_px > 1.0),
                })

        gif_name = f"push_{tag}.gif"
        gif_path = str(Path(viz_dir) / gif_name)
        if pil_frames:
            pil_frames[0].save(
                gif_path, save_all=True, append_images=pil_frames[1:],
                duration=_VIZ_GIF_MS, loop=0, optimize=False,
            )
        nonblack_n = sum(1 for f in frames_meta if f["nonblack"])
        result["per_k"][tag] = {
            "stiffness": k,
            "gif": gif_path,
            "png_dir": viz_dir,
            "png_pattern": f"push_{tag}_NNN.png",
            "n_frames": len(frames_meta),
            "n_nonblack": nonblack_n,
            "max_back_off_mm": max(
                (f["back_off_mm"] for f in frames_meta), default=0.0
            ),
            "frames": frames_meta,
        }

        try:
            annot.detach()
        except Exception:  # noqa: BLE001
            pass
        world.stop()

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
        elif args.mode == "viz":
            result = _run_viz(args, app)
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
    p.add_argument("--mode", required=True, choices=["push", "carry", "viz"],
                   help="push (analog of #201), carry (analog of #217/#218), or "
                        "viz (render the push at two k so a human SEES back-off).")
    p.add_argument("--out", required=True, help="JSON results path (mounted). For "
                        "--mode viz this is the per-frame trace JSON.")
    p.add_argument("--viz-dir", default=None,
                   help="viz mode: dir for PNG sequence + GIF (mounted); default "
                        "<out-parent>/viz.")
    p.add_argument("--stiffness", type=float, default=None,
                   help="viz mode: render only this single k (N/m); default renders "
                        "both 1e4 and 1e6.")
    p.add_argument("--width", type=int, default=_VIZ_WIDTH,
                   help="viz mode: render width.")
    p.add_argument("--height", type=int, default=_VIZ_HEIGHT,
                   help="viz mode: render height.")
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
