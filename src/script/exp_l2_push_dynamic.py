#!/usr/bin/env python3
"""L2 kinematic body pushing an INDEPENDENT dynamic object on Isaac Sim 6.0.1 (isaac#201).

Re-validates the ADR-0008 L2/L3 one-way-force-transfer contract on Isaac Sim
6.0.1 / Isaac Lab 3.0. ADR-0008 coexistence rule 1 (quoting PhysX 5.4.1 Rigid
Body Dynamics): "A kinematic actor can push away dynamic objects, but nothing
pushes it back." This experiment builds the minimal scene that exercises BOTH
halves of that clause at once:

  * a KINEMATIC pusher plate (standalone rigid body, physics:kinematicEnabled=
    True), driven per tick to a commanded pose via SingleRigidPrim.set_world_pose
    (routes to the PhysX kinematic target, NOT a setGlobalPose teleport -- so the
    dynamic cube actually feels the contact; ADR-0008 L2 contract clause 3), and
  * a SEPARATE free DYNAMIC cube resting on the static ground in front of it.

The plate starts behind the cube, is held still for a warm-up window while the
cube settles on the ground (so the measured push displacement is not polluted by
settling), then sweeps forward in +X at constant speed straight into the cube.

Two independent claims are measured:

  (a) PLATE TRACKING (kinematic follows command EXACTLY, unaffected by the cube).
      Metric: max over the whole run of position error ||actual-commanded|| (m)
      and orientation geodesic error (deg), read straight back from the sim after
      each world.step. Separately recorded is the max tracking error restricted
      to CONTACT frames (while the plate is actually pressing the cube) -- this is
      the "nothing pushes it back" half: pushing a real dynamic mass must not
      perturb the kinematic target by even a contact reaction. Expectation
      (5.1 baseline, ADR-0008 openbase L2 migration: pose tracking 0.0000 err):
      ~0 m / ~0 deg, and the contact-frame error identical to the overall error.

  (b) CUBE PUSH (the dynamic object IS displaced / gains velocity from contact).
      Metric: cube +X displacement from its settled baseline to final, and its
      max speed (finite-difference ||dpos||/dt) during the run. A cube that felt
      the push has displacement_x > 0 and a non-zero peak speed; a cube the plate
      teleported through (contact bypass) or never reached would stay put. Also
      recorded: final z stays at the resting height (cube slides along the ground,
      it is neither launched nor squished through the floor). Expectation
      (5.1 baseline / PhysX contract): cube pushed forward the geometric overlap
      of the sweep (order ~0.9 m here), peak speed > 0, z steady on the ground.

PASS = plate tracking exact (< 1e-4 m, < 1e-2 deg) INCLUDING during contact, AND
cube displaced forward (> 0.3 m) with non-zero peak speed while its ground height
holds. That is exactly ADR-0008 rule 1: one-way transfer, kinematic unmoved.

Results are written as JSON to ``--out`` (a MOUNTED path) so the host reads them
back; stdout through the docker run wrapper is not reliably captured. Teardown is
an explicit ``os._exit`` (isaac#248 round 9): a cold headless 6.0.1 container's
Omniverse Hub connector aborts SimulationApp.close() with a busy-TaskGroup
SIGABRT; os._exit reaches the same clean exit while skipping that teardown.

CLI::

    /isaac-sim/python.sh exp_l2_push_dynamic.py \\
        --out /home/<user>/work/worktree/<wt>/test/.l2-push.json \\
        [--warmup 60] [--push-steps 300] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# Scene geometry (metres). Plate is a thin tall wall; cube is a free rigid box.
_PLATE_DIMS = (0.10, 1.00, 0.60)   # sx, sy, sz  (thin in X, wide/tall face)
_PLATE_X0 = 0.0                    # plate centre start x
_PLATE_X1 = 2.0                    # plate centre end   x (after push phase)
_PLATE_Z = 0.30                    # centre z so bottom rests on ground (sz/2)
_CUBE_SIZE = 0.30                  # dynamic cube edge
_CUBE_X0 = 1.00                    # cube centre start x
_CUBE_Z = 0.15                     # centre z so bottom rests on ground


def _quat_angle_deg(q_cmd, q_act):
    """Geodesic angle (deg) between two scalar-first (w,x,y,z) unit quaternions."""
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


def _plate_cmd(phase):
    """Commanded plate pose (position xyz, orientation wxyz identity) at phase.

    phase in [0,1): 0 -> held at start (warm-up), then linear sweep to _PLATE_X1.
    """
    x = _PLATE_X0 + (_PLATE_X1 - _PLATE_X0) * phase
    return (x, 0.0, _PLATE_Z), (1.0, 0.0, 0.0, 0.0)


def _build_scene(stage):
    """Author ground + light + kinematic plate + dynamic cube. Returns paths."""
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    UsdGeom.Xform.Define(stage, "/World")
    light = UsdLux.DistantLight.Define(stage, "/World/SunLight")
    light.CreateIntensityAttr(3000.0)

    # Static ground collider at z=0.
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(200.0, 200.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    # Kinematic pusher plate.
    plate_path = "/World/kin_plate"
    plate = UsdGeom.Cube.Define(stage, plate_path)
    plate.GetSizeAttr().Set(1.0)
    plate.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(_PLATE_X0, 0.0, _PLATE_Z)
    )
    plate.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(*_PLATE_DIMS))
    pprim = plate.GetPrim()
    prb = UsdPhysics.RigidBodyAPI.Apply(pprim)
    prb.CreateKinematicEnabledAttr(True)  # <-- L2: standalone kinematic body
    UsdPhysics.CollisionAPI.Apply(pprim)
    UsdPhysics.MassAPI.Apply(pprim).CreateMassAttr(1.0)

    # Independent free DYNAMIC cube resting on the ground in front of the plate.
    cube_path = "/World/dyn_cube"
    cube = UsdGeom.Cube.Define(stage, cube_path)
    cube.GetSizeAttr().Set(1.0)
    cube.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(_CUBE_X0, 0.0, _CUBE_Z)
    )
    cube.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
        Gf.Vec3f(_CUBE_SIZE, _CUBE_SIZE, _CUBE_SIZE)
    )
    cprim = cube.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(cprim)  # dynamic (kinematic default off)
    UsdPhysics.CollisionAPI.Apply(cprim)
    UsdPhysics.MassAPI.Apply(cprim).CreateMassAttr(1.0)
    # A little linear damping so the pushed cube settles when the plate stops,
    # rather than skating indefinitely on a frictionless-looking surface.
    PhysxSchema.PhysxRigidBodyAPI.Apply(cprim).CreateLinearDampingAttr(0.2)

    return plate_path, cube_path


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    total_steps = args.warmup + args.push_steps
    result = {
        "issue": "isaac#201",
        "adr": "ADR-0008 L2/L3 one-way force transfer (coexistence rule 1)",
        "isaac_variant": "6.0.1",
        "warmup_steps": args.warmup,
        "push_steps": args.push_steps,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "plate_sweep_m": _PLATE_X1 - _PLATE_X0,
        "metric": (
            "(a) plate: max ||actual-commanded|| position err (m) + geodesic "
            "orientation err (deg), overall and restricted to contact frames; "
            "(b) cube: +X displacement (m) from settled baseline + max speed "
            "(finite-diff ||dpos||/dt, m/s) + ground-height hold"
        ),
        "expectation_5_1_baseline": (
            "plate ~0 m / ~0 deg overall AND during contact (ADR-0008 openbase "
            "L2 migration: pose tracking 0.0000 err; PhysX 'nothing pushes it "
            "back'); cube pushed forward ~0.9 m with non-zero peak speed, z "
            "steady on ground (PhysX 'kinematic pushes away dynamic objects')"
        ),
        "drive_api": None,
        "plate": None,
        "cube": None,
        "one_way_transfer_ok": None,
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

        plate_path, cube_path = _build_scene(stage)

        render = bool(args.mp4)
        cap = None
        if render:
            import viz_render as vr
            vr.apply_clean_render_settings()
            vr.add_fill_lights(stage)
            vr.bind(stage, "/World/Ground",
                    vr.material(stage, "/World/Looks/Gray", (0.55, 0.55, 0.58)))
            vr.bind(stage, plate_path,
                    vr.material(stage, "/World/Looks/Blue", (0.15, 0.4, 0.85)))
            vr.bind(stage, cube_path,
                    vr.material(stage, "/World/Looks/Orange", (0.95, 0.5, 0.1)))
            vr.make_camera(stage, "/World/VizCam", (1.0, -6.5, 3.2), (1.2, 0.0, 0.3))

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        plate = SingleRigidPrim(plate_path)
        cube = SingleRigidPrim(cube_path)
        if render:
            import viz_render as vr
            cap = vr.Capturer(world, "/World/VizCam", args.width, args.height)
        cap_steps = set(int(round(v)) for v in np.linspace(
            args.warmup, total_steps - 1, 48)) if render else set()
        frames, nonblack = [], 0
        result["drive_api"] = (
            "isaacsim.core.prims.SingleRigidPrim.set_world_pose per tick on a "
            "physics:kinematicEnabled plate (routes to kinematic target, not "
            "setGlobalPose) + World.step; cube is a free dynamic rigid body"
        )

        # Geometry helpers: plate front face x and cube back face x. Contact
        # window = plate front has reached (within a small margin of) the cube's
        # current back face -- i.e. the plate is actually pressing the cube.
        plate_half_x = _PLATE_DIMS[0] * 0.5
        cube_half = _CUBE_SIZE * 0.5
        contact_margin = 0.02

        # Plate tracking accumulators.
        max_pos_err = 0.0
        max_ang_err = 0.0
        max_pos_err_contact = 0.0
        contact_frames = 0

        # Cube tracking.
        cube_baseline = None       # settled position at end of warm-up
        cube_prev = None
        cube_max_speed = 0.0
        cube_min_z = float("inf")
        cube_max_z = float("-inf")

        for step_i in range(total_steps):
            if step_i < args.warmup:
                phase = 0.0
            else:
                phase = (step_i - args.warmup) / float(args.push_steps)

            pos_c, quat_c = _plate_cmd(phase)
            plate.set_world_pose(
                np.asarray(pos_c, dtype=float),
                np.asarray(quat_c, dtype=float),
            )
            world.step(render=render)

            # Plate read-back + tracking error.
            pos_a, quat_a = plate.get_world_pose()
            pos_a = np.asarray(pos_a, dtype=float).reshape(-1)
            quat_a = np.asarray(quat_a, dtype=float).reshape(-1)
            pos_err = float(np.linalg.norm(pos_a - np.asarray(pos_c)))
            ang_err = _quat_angle_deg(quat_c, tuple(quat_a.tolist()))
            max_pos_err = max(max_pos_err, pos_err)
            if not math.isnan(ang_err):
                max_ang_err = max(max_ang_err, ang_err)

            # Cube read-back.
            cpos, _ = cube.get_world_pose()
            cpos = np.asarray(cpos, dtype=float).reshape(-1)
            cube_min_z = min(cube_min_z, float(cpos[2]))
            cube_max_z = max(cube_max_z, float(cpos[2]))

            # Settle baseline captured on the last warm-up frame.
            if step_i == args.warmup - 1:
                cube_baseline = cpos.copy()
                cube_prev = cpos.copy()

            # During push phase: speed + contact-frame tracking error.
            if step_i >= args.warmup:
                if cube_prev is not None:
                    speed = float(np.linalg.norm(cpos - cube_prev) / args.dt)
                    cube_max_speed = max(cube_max_speed, speed)
                cube_prev = cpos.copy()

                plate_front = pos_a[0] + plate_half_x
                cube_back = float(cpos[0]) - cube_half
                if plate_front >= cube_back - contact_margin:
                    contact_frames += 1
                    max_pos_err_contact = max(max_pos_err_contact, pos_err)

            if render and step_i in cap_steps:
                import viz_render as vr
                base_x = cube_baseline[0] if cube_baseline is not None else cpos[0]
                lines = [
                    "L2 kinematic pushes dynamic cube (one-way transfer)",
                    "plate_x    = %7.3f m" % float(pos_a[0]),
                    "cube_x     = %7.3f m" % float(cpos[0]),
                    "cube disp  = %7.3f m" % float(cpos[0] - base_x),
                    "plate err  = %.1e m  (kinematic, exact)" % max_pos_err,
                ]
                rgb = cap.grab()
                if rgb is not None and float(rgb.mean()) > 1.0:
                    nonblack += 1
                if rgb is None:
                    rgb = np.zeros((args.height, args.width, 3), dtype=np.uint8)
                frames.append(vr.overlay(rgb, lines))

        cpos_final, _ = cube.get_world_pose()
        cpos_final = np.asarray(cpos_final, dtype=float).reshape(-1)
        if cube_baseline is None:  # warmup was 0
            cube_baseline = cpos_final
        disp = cpos_final - cube_baseline
        disp_x = float(disp[0])

        plate_ok = bool(max_pos_err < 1e-4 and max_ang_err < 1e-2)
        contact_ok = bool(max_pos_err_contact < 1e-4)
        cube_pushed = bool(disp_x > 0.3 and cube_max_speed > 1e-3)
        cube_on_ground = bool(
            abs(float(cpos_final[2]) - _CUBE_Z) < 0.05 and cube_min_z > 0.0
        )

        result["plate"] = {
            "path": plate_path,
            "kind": "kinematic box plate",
            "dims": list(_PLATE_DIMS),
            "max_pos_err_m": max_pos_err,
            "max_ang_err_deg": max_ang_err,
            "max_pos_err_contact_m": max_pos_err_contact,
            "contact_frames": contact_frames,
            "tracking_exact": plate_ok,
            "tracking_exact_under_contact": contact_ok,
        }
        result["cube"] = {
            "path": cube_path,
            "kind": "free dynamic rigid cube",
            "size_m": _CUBE_SIZE,
            "baseline_pos_m": [float(v) for v in cube_baseline],
            "final_pos_m": [float(v) for v in cpos_final],
            "displacement_m": [float(v) for v in disp],
            "displacement_x_m": disp_x,
            "max_speed_mps": cube_max_speed,
            "final_z_m": float(cpos_final[2]),
            "min_z_m": cube_min_z,
            "max_z_m": cube_max_z,
            "pushed": cube_pushed,
            "stayed_on_ground": cube_on_ground,
        }
        # One-way transfer confirmed: plate exact (incl. contact) AND cube moved.
        result["one_way_transfer_ok"] = bool(
            plate_ok and contact_ok and cube_pushed and cube_on_ground
        )

        if render and frames:
            import viz_render as vr
            vr.encode_mp4(args.mp4, frames, fps=15)
            cap.detach()
            result["mp4"] = args.mp4
            result["mp4_frames"] = len(frames)
            result["mp4_nonblack"] = nonblack

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
    p.add_argument("--warmup", type=int, default=60,
                   help="Warm-up steps (plate held; cube settles).")
    p.add_argument("--push-steps", type=int, default=300,
                   help="Push-phase steps (plate sweeps into cube).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument("--mp4", default=None,
                   help="If set, RTX-render the push with a per-frame data HUD "
                        "and encode an MP4 to this path (mounted).")
    p.add_argument("--width", type=int, default=960, help="mp4 render width.")
    p.add_argument("--height", type=int, default=540, help="mp4 render height.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
