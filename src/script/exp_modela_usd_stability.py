#!/usr/bin/env python3
"""Model A simplified USD stays stable in a richer scene on Isaac Sim 6.0.1 (isaac#94).

Re-validates issue #94 / ADR-0004 on Isaac Sim 6.0.1 / Isaac Lab 3.0. Model A is
the kinematic forklift block model: the committed asset
``src/model/usd/robot/forklift_blocky/forklift_blocky.usda`` -- 6 standalone
``physics:kinematicEnabled=1`` cubes (body, mast_lower, mast_upper, carriage,
left_fork, right_fork), no articulation, plus a dynamic Pallet and a checkerboard
of collidable ground tiles (ADR-0004 "USD structure"). The issue asks whether this
simplified USD "stays STABLE over time" when dropped into a RICHER scene: extra
dynamic obstacles of varying mass on and around the driven path, plus free-falling
clutter that must settle.

This driver OPENS THE COMMITTED USD (genuine asset re-validation, not a
programmatic rebuild), AUGMENTS it with a richer dynamic scene, then drives the
forklift as a chassis SE(2) slide (x, y, yaw) over a sustained multi-phase path:

  approach  -- ramp forward so the forks/body sweep light clutter and bump the
               dynamic pallet into a heavy backstop box + a baffle wall;
  cruise    -- a slow ~20 s constant-curvature arc (sustained motion, the classic
               accumulated-drift test) with yaw following the heading;
  settle    -- hold the final pose ~12 s so the bumped dynamic neighbours settle.

CRITICAL drive rule (ADR-0008 L2 clause 3, isaac#217 finding)
-------------------------------------------------------------
Each kinematic cube is driven every tick by a TRUE PhysX kinematic target
(``RigidBodyView.set_kinematic_targets`` on the physics tensor view; pos xyz + quat
xyzw, warp float32), NOT ``set_world_pose`` -- a ``setGlobalPose`` teleport leaves
solver velocity 0 and would let the forklift pass through the obstacles without a
contact impulse. The kinematic target computes the solver velocity the dynamic
neighbours' contacts react to, so the bump is a real physics event.

The forklift is a RIGID composition: each cube's world pose = chassis pose composed
with the cube's authored rest offset (read back once after ``world.reset()``),
rotated by the chassis yaw. So the commanded pose per cube per tick is
``(cx,cy,0) + Rz(yaw) * rest_pos`` with orientation ``Rz(yaw)`` (all cubes author
identity orientation).

Metrics over the whole run
--------------------------
* max_pos_track_err_m / max_ang_track_err_deg per cube -- actual read-back vs
  commanded. L2 kinematic exactness => ~0 (the "kinematic bodies hold their
  commanded poses" check).
* z_lock_max_dev_m, rollpitch_lock_max_dev_deg on the chassis body cube -- the
  SE(2)-slide assumption (z / pitch / roll fixed) must survive every collision.
* nan_seen -- any non-finite pose on ANY body (forklift cubes + pallet + every
  clutter obstacle), any tick => fail.
* explosion_max_abs_coord_m -- max |coord| over ALL bodies; a blow-up sends this
  to huge/inf. Bounded => no explosion.
* per dynamic obstacle: max_speed_mps over the run and mean_speed_mps over the
  settle window (finite-difference of read-back positions / dt); settled =>
  settle-window speed below threshold. displacement_m from start (bumped but
  bounded).

Expectation (5.1 baseline, ADR-0004 A-hybrid + ADR-0008 openbase L2 migration:
pose tracking 0.0000 err): every cube tracks EXACT (~0 m / ~0 deg), z / roll /
pitch stay locked through the bumps, no NaN, coordinates bounded, and the dynamic
neighbours settle (near-zero speed) by the end. No committed 6.0.1 baseline for
the richer-scene stability run itself -- this is the first-run 6.0.1
characterization; the per-link L2 exactness half is what #193 already showed
0.0000 on 6.0.1.

Results are written as JSON to ``--out`` (a MOUNTED path); stdout through the
docker run wrapper is not reliably captured. Teardown is an explicit ``os._exit``
(isaac#248 round 9): a cold headless 6.0.1 container's Omniverse Hub connector
aborts SimulationApp.close() with a busy-TaskGroup SIGABRT; os._exit reaches the
same clean exit while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_modela_usd_stability.py \\
        --out /home/<user>/work/worktree/<wt>/test/.modela-stability.json \\
        [--steps 2400] [--warmup 120] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# Committed Model A simplified USD, resolved relative to this script so it works
# both on the host and inside the mounted container.
_USD_REL = "../model/usd/robot/forklift_blocky/forklift_blocky.usda"

# The 6 kinematic cubes that rigidly compose the forklift (ADR-0004 USD structure).
_FORKLIFT_CUBES = [
    "body",
    "mast_lower",
    "mast_upper",
    "carriage",
    "left_fork",
    "right_fork",
]
_CHASSIS_CUBE = "body"  # the cube whose z / roll / pitch lock we assert

# Richer-scene clutter added on top of the committed USD. Each entry:
#   (name, kind, x, y, z, sx, sy, sz, mass, role)
# role "path"  -> sits on / near the driven path, gets bumped;
# role "drop"  -> spawned above ground, free-falls and must settle;
# role "backstop"/"baffle" -> heavy environment the pallet is pushed into.
_CLUTTER = [
    ("light_a", "box", 2.4, 0.55, 0.12, 0.22, 0.22, 0.22, 0.5, "path"),
    ("light_b", "box", 2.7, -0.55, 0.12, 0.22, 0.22, 0.22, 0.5, "path"),
    ("medium_a", "box", 3.1, 0.95, 0.16, 0.32, 0.32, 0.32, 5.0, "path"),
    ("heavy_backstop", "box", 5.6, 0.0, 0.30, 0.5, 0.5, 0.6, 50.0, "backstop"),
    ("baffle_wall", "box", 6.6, 0.0, 0.35, 0.15, 2.0, 0.7, 30.0, "baffle"),
    ("drop_a", "box", -1.8, 3.2, 1.0, 0.3, 0.3, 0.3, 2.0, "drop"),
    ("drop_b", "box", 0.4, -3.4, 1.25, 0.3, 0.3, 0.3, 2.0, "drop"),
    ("drop_c", "box", 1.6, 4.1, 0.85, 0.25, 0.25, 0.25, 1.0, "drop"),
]
_PALLET_PATH = "/World/Pallet"

_SETTLE_SPEED_THRESH = 0.05  # m/s mean over settle window => "settled"
_EXPLOSION_LIMIT_M = 1.0e3   # any |coord| beyond this => runaway


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


def _roll_pitch_deg(q_wxyz):
    """Roll (about x) and pitch (about y) in degrees from a scalar-first quat."""
    w, x, y, z = q_wxyz
    roll = math.atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y))
    s = max(-1.0, min(1.0, 2.0 * (w * y - z * x)))
    pitch = math.asin(s)
    return math.degrees(roll), math.degrees(pitch)


def _yaw_quat_wxyz(yaw):
    """Yaw (rad) about +Z as scalar-first (w,x,y,z)."""
    half = yaw * 0.5
    return (math.cos(half), 0.0, 0.0, math.sin(half))


def _smoothstep(a, b, t):
    """C1 smoothstep of t in [a,b] -> [0,1] (clamped)."""
    if b <= a:
        return 1.0 if t >= b else 0.0
    u = (t - a) / (b - a)
    u = max(0.0, min(1.0, u))
    return u * u * (3.0 - 2.0 * u)


def _chassis_pose(t, total_t):
    """Chassis SE(2) pose (cx, cy, yaw) at sim time t.

    Phase timing (fractions of total_t):
      approach  0.00 -> 0.20 : ramp +X to X_APPROACH (bump pallet + clutter)
      cruise    0.20 -> 0.70 : slow constant-curvature arc, yaw follows heading
      settle    0.70 -> 1.00 : hold the final pose (dynamic neighbours settle)
    """
    x_approach = 2.5
    t_appr = 0.20 * total_t
    t_cruise_end = 0.70 * total_t

    if t <= t_appr:
        cx = x_approach * _smoothstep(0.0, t_appr, t)
        return cx, 0.0, 0.0

    # Cruise: a gentle arc starting from (x_approach, 0, yaw=0), curving in +Y.
    # Parametrised by arc angle theta swept smoothly to THETA_MAX over the window.
    theta_max = math.radians(60.0)
    radius = 4.0
    if t <= t_cruise_end:
        theta = theta_max * _smoothstep(t_appr, t_cruise_end, t)
    else:
        theta = theta_max  # held through settle

    # Arc centre placed so the path is tangent (+X heading) at the hand-off point.
    cx0, cy0 = x_approach, 0.0
    ccx, ccy = cx0, cy0 + radius
    cx = ccx + radius * math.sin(theta)
    cy = ccy - radius * math.cos(theta)
    yaw = theta
    return cx, cy, yaw


def _open_model_a_usd():
    """Open the committed Model A simplified USD as the working stage."""
    import omni.usd

    usd_path = (Path(__file__).resolve().parent / _USD_REL).resolve()
    if not usd_path.is_file():
        raise FileNotFoundError(f"Model A USD not found: {usd_path}")
    ctx = omni.usd.get_context()
    ok = ctx.open_stage(str(usd_path))
    if not ok:
        raise RuntimeError(f"open_stage failed for {usd_path}")
    return ctx.get_stage(), str(usd_path)


def _add_clutter(stage):
    """Author the richer dynamic scene on top of the opened USD."""
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    UsdGeom.Xform.Define(stage, "/World/Clutter")
    added = []
    for name, _kind, x, y, z, sx, sy, sz, mass, role in _CLUTTER:
        path = f"/World/Clutter/{name}"
        geom = UsdGeom.Cube.Define(stage, path)
        geom.GetSizeAttr().Set(1.0)
        geom.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(x, y, z))
        geom.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(sx, sy, sz))
        prim = geom.GetPrim()
        UsdPhysics.RigidBodyAPI.Apply(prim)  # dynamic (kinematic default off)
        UsdPhysics.CollisionAPI.Apply(prim)
        m = UsdPhysics.MassAPI.Apply(prim)
        m.CreateMassAttr(float(mass))
        # Light damping so bumped obstacles settle instead of ringing forever.
        PhysxSchema.PhysxRigidBodyAPI.Apply(prim).CreateLinearDampingAttr(0.2)
        added.append({"name": name, "path": path, "role": role,
                      "mass": mass, "spawn": (x, y, z)})
    return added


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})  # noqa: F841

    result = {
        "issue": "isaac#94",
        "adr": "ADR-0004 Model A-hybrid kinematic forklift block model",
        "isaac_variant": "6.0.1",
        "usd_asset": None,
        "steps": args.steps,
        "warmup_steps": args.warmup,
        "physics_dt": args.dt,
        "sim_seconds": round(args.steps * args.dt, 3),
        "gravity": GRAVITY,
        "forklift_cubes": _FORKLIFT_CUBES,
        "clutter": [
            {"name": c[0], "role": c[9], "mass": c[8]} for c in _CLUTTER
        ],
        "drive_api": None,
        "metric": (
            "per cube: max pos/ang tracking err (actual read-back vs commanded "
            "Rz(yaw)*rest_offset); chassis z/roll/pitch lock max deviation; "
            "nan on any body any tick; max |coord| over all bodies (explosion); "
            "per dynamic obstacle max speed + settle-window mean speed + "
            "displacement (finite-diff of read-back poses)"
        ),
        "expectation_5_1_baseline": (
            "cubes track ~0 m / ~0 deg (L2 kinematic exactness, ADR-0008 openbase "
            "migration 0.0000); z/roll/pitch locked through bumps; no NaN; "
            "coordinates bounded; dynamic neighbours settle (~0 m/s) by the end"
        ),
        "cubes": [],
        "chassis_lock": None,
        "obstacles": [],
        "nan_seen": None,
        "explosion_max_abs_coord_m": None,
        "no_explosion": None,
        "all_cubes_track_exact": None,
        "all_obstacles_settled": None,
        "stable": None,
        "error": None,
    }

    try:
        import numpy as np
        import warp as wp
        from isaacsim.core.api import World

        stage, usd_path = _open_model_a_usd()
        result["usd_asset"] = usd_path
        clutter = _add_clutter(stage)

        render = bool(args.mp4)
        cap = None
        if render:
            import viz_render as vr
            from pxr import UsdGeom as _UG
            vr.apply_clean_render_settings()
            vr.add_fill_lights(stage)
            for _gp in ("/World/Ground", "/World/GroundPlane",
                        "/World/defaultGroundPlane"):
                _p = stage.GetPrimAtPath(_gp)
                if _p and _p.IsValid():
                    _UG.Imageable(_p).MakeInvisible()
            blue = vr.material(stage, "/World/Looks/Fork", (0.15, 0.45, 0.9))
            for c in _FORKLIFT_CUBES:
                vr.bind(stage, f"/World/Forklift/{c}", blue)
            vr.bind(stage, _PALLET_PATH,
                    vr.material(stage, "/World/Looks/Pallet", (0.85, 0.55, 0.2)))
            for c in clutter:
                vr.bind(stage, c["path"], vr.material(
                    stage, f"/World/Looks/cl_{c['name']}", (0.5, 0.5, 0.55)))
            vr.make_camera(stage, "/World/VizCam", (-3.0, -10.0, 8.0),
                           (2.0, 2.0, 0.3))

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        sim_view = world.physics_sim_view
        wp_device = sim_view.device
        wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)

        # Read pose from a physics tensor rigid-body view. get_transforms returns
        # [px,py,pz, qx,qy,qz,qw] (position + xyzw quat); return position and a
        # scalar-first (w,x,y,z) quat for the metric helpers. Everything is read
        # through these views -- mixing in a SingleRigidPrim registers a SECOND
        # view on the same prim and invalidates the tensor view ("prim deleted
        # while being used by a shape in a tensor view class").
        def _read_pose(view):
            tf = np.asarray(view.get_transforms()).reshape(-1)
            pos = tf[:3].astype(float)
            quat_wxyz = np.array([tf[6], tf[3], tf[4], tf[5]], dtype=float)
            return pos, quat_wxyz

        # Forklift cubes: one driving+reading tensor view per kinematic cube.
        cube_paths = {c: f"/World/Forklift/{c}" for c in _FORKLIFT_CUBES}
        cube_view = {c: sim_view.create_rigid_body_view(cube_paths[c])
                     for c in _FORKLIFT_CUBES}

        # Dynamic readers: the committed pallet + every clutter obstacle.
        dyn_view = {"Pallet": sim_view.create_rigid_body_view(_PALLET_PATH)}
        for c in clutter:
            dyn_view[c["name"]] = sim_view.create_rigid_body_view(c["path"])

        result["drive_api"] = (
            "physics tensor RigidBodyView.set_kinematic_targets (pos xyz + quat "
            "xyzw) per tick on each physics:kinematicEnabled forklift cube -> real "
            "PhysX kinematic target with solver velocity + World.step; "
            "RigidBodyView.get_transforms for read-back (all bodies)"
        )

        # Rest offsets: authored world pose of each cube after reset (the rigid
        # composition; chassis origin is world origin at t=0).
        rest = {}
        for c in _FORKLIFT_CUBES:
            pos, _quat = _read_pose(cube_view[c])
            rest[c] = pos  # rest orientation is identity

        def _commanded(c, cx, cy, yaw):
            rx, ry, rz = rest[c]
            cyaw, syaw = math.cos(yaw), math.sin(yaw)
            wx = cx + (rx * cyaw - ry * syaw)
            wy = cy + (rx * syaw + ry * cyaw)
            return (wx, wy, rz), _yaw_quat_wxyz(yaw)

        # Per-cube tracking accumulators.
        cube_acc = {c: {"max_pos": 0.0, "max_ang": 0.0, "sum_pos": 0.0}
                    for c in _FORKLIFT_CUBES}
        # Chassis lock accumulators (body cube).
        rest_body_z = float(rest[_CHASSIS_CUBE][2])
        lock_acc = {"z_dev": 0.0, "roll_dev": 0.0, "pitch_dev": 0.0}
        # Obstacle accumulators (finite-diff speed).
        obst_prev = {}
        obst_acc = {k: {"max_speed": 0.0, "settle_speeds": []} for k in dyn_view}
        obst_start = {}

        nan_seen = False
        max_abs = 0.0
        total_steps = args.warmup + args.steps
        settle_start = args.warmup + int(0.70 * args.steps)
        total_t = args.steps * args.dt

        if render:
            import viz_render as vr
            cap = vr.Capturer(world, "/World/VizCam", args.width, args.height)
        cap_steps = set(int(round(v)) for v in np.linspace(
            args.warmup, total_steps - 1, 60)) if render else set()
        frames, nonblack = [], 0

        for step_i in range(total_steps):
            if step_i < args.warmup:
                cx, cy, yaw = 0.0, 0.0, 0.0
            else:
                t = (step_i - args.warmup) * args.dt
                cx, cy, yaw = _chassis_pose(t, total_t)

            # Command every forklift cube with a true kinematic target.
            cmd = {}
            for c in _FORKLIFT_CUBES:
                (wx, wy, wz), q_wxyz = _commanded(c, cx, cy, yaw)
                cmd[c] = ((wx, wy, wz), q_wxyz)
                qx, qy, qz, qw = q_wxyz[1], q_wxyz[2], q_wxyz[3], q_wxyz[0]
                target = wp.array([[wx, wy, wz, qx, qy, qz, qw]],
                                  dtype=wp.float32, device=wp_device)
                cube_view[c].set_kinematic_targets(target, wp_idx)

            world.step(render=render)

            # Read-back forklift cubes: tracking error + lock + NaN + explosion.
            for c in _FORKLIFT_CUBES:
                pos_a, quat_a = _read_pose(cube_view[c])
                if not (np.all(np.isfinite(pos_a)) and np.all(np.isfinite(quat_a))):
                    nan_seen = True
                    continue
                max_abs = max(max_abs, float(np.max(np.abs(pos_a))))
                (pc, qc) = cmd[c]
                pos_err = float(np.linalg.norm(pos_a - np.asarray(pc)))
                ang_err = _quat_angle_deg(qc, tuple(quat_a.tolist()))
                a = cube_acc[c]
                a["max_pos"] = max(a["max_pos"], pos_err)
                a["sum_pos"] += pos_err
                if not math.isnan(ang_err):
                    a["max_ang"] = max(a["max_ang"], ang_err)
                if c == _CHASSIS_CUBE:
                    lock_acc["z_dev"] = max(
                        lock_acc["z_dev"], abs(float(pos_a[2]) - rest_body_z))
                    roll, pitch = _roll_pitch_deg(tuple(quat_a.tolist()))
                    lock_acc["roll_dev"] = max(lock_acc["roll_dev"], abs(roll))
                    lock_acc["pitch_dev"] = max(lock_acc["pitch_dev"], abs(pitch))

            # Read-back dynamic obstacles: speed (finite-diff) + NaN + explosion.
            for k, view in dyn_view.items():
                pos_a, _ = _read_pose(view)
                if not np.all(np.isfinite(pos_a)):
                    nan_seen = True
                    continue
                max_abs = max(max_abs, float(np.max(np.abs(pos_a))))
                if k not in obst_start:
                    obst_start[k] = pos_a.copy()
                if k in obst_prev:
                    speed = float(np.linalg.norm(pos_a - obst_prev[k]) / args.dt)
                    obst_acc[k]["max_speed"] = max(obst_acc[k]["max_speed"], speed)
                    if step_i >= settle_start:
                        obst_acc[k]["settle_speeds"].append(speed)
                obst_prev[k] = pos_a.copy()

            if render and step_i in cap_steps:
                import viz_render as vr
                gmax = max(a["max_pos"] for a in cube_acc.values())
                lines = [
                    "Model A forklift (6 kinematic cubes) SE(2) slide over clutter",
                    "chassis  x=%6.3f  y=%6.3f  yaw=%6.1f deg"
                    % (cx, cy, math.degrees(yaw)),
                    "forklift track err = %.1e m  (kinematic, exact)" % gmax,
                    "t = %5.2f s" % (max(0.0, (step_i - args.warmup) * args.dt)),
                ]
                rgb = cap.grab()
                if rgb is not None and float(rgb.mean()) > 1.0:
                    nonblack += 1
                if rgb is None:
                    rgb = np.zeros((args.height, args.width, 3), dtype=np.uint8)
                frames.append(vr.overlay(rgb, lines))

        if render and frames:
            import viz_render as vr
            vr.encode_mp4(args.mp4, frames, fps=20)
            cap.detach()
            result["mp4"] = args.mp4
            result["mp4_frames"] = len(frames)
            result["mp4_nonblack"] = nonblack

        # Assemble per-cube results.
        cube_flags = []
        for c in _FORKLIFT_CUBES:
            a = cube_acc[c]
            exact = bool(a["max_pos"] < 1e-4 and a["max_ang"] < 1e-2)
            cube_flags.append(exact)
            result["cubes"].append({
                "cube": c,
                "max_pos_track_err_m": a["max_pos"],
                "mean_pos_track_err_m": a["sum_pos"] / float(total_steps),
                "max_ang_track_err_deg": a["max_ang"],
                "tracks_exact": exact,
            })

        result["chassis_lock"] = {
            "rest_body_z_m": rest_body_z,
            "z_lock_max_dev_m": lock_acc["z_dev"],
            "roll_lock_max_dev_deg": lock_acc["roll_dev"],
            "pitch_lock_max_dev_deg": lock_acc["pitch_dev"],
            "locked": bool(lock_acc["z_dev"] < 1e-4
                           and lock_acc["roll_dev"] < 1e-2
                           and lock_acc["pitch_dev"] < 1e-2),
        }

        # Assemble per-obstacle results.
        obst_flags = []
        role_by_name = {c["name"]: c["role"] for c in clutter}
        role_by_name["Pallet"] = "pallet"
        for k, view in dyn_view.items():
            settle = obst_acc[k]["settle_speeds"]
            settle_mean = (sum(settle) / len(settle)) if settle else float("nan")
            pos_a, _ = _read_pose(view)
            disp = (float(np.linalg.norm(pos_a - obst_start[k]))
                    if k in obst_start else float("nan"))
            settled = bool(not math.isnan(settle_mean)
                           and settle_mean < _SETTLE_SPEED_THRESH)
            obst_flags.append(settled)
            result["obstacles"].append({
                "name": k,
                "role": role_by_name.get(k, "?"),
                "max_speed_mps": obst_acc[k]["max_speed"],
                "settle_mean_speed_mps": settle_mean,
                "displacement_m": disp,
                "final_z_m": float(pos_a[2]),
                "settled": settled,
            })

        result["nan_seen"] = bool(nan_seen)
        result["explosion_max_abs_coord_m"] = max_abs
        result["no_explosion"] = bool(max_abs < _EXPLOSION_LIMIT_M and not nan_seen)
        result["all_cubes_track_exact"] = bool(cube_flags) and all(cube_flags)
        result["all_obstacles_settled"] = bool(obst_flags) and all(obst_flags)
        result["stable"] = bool(
            (not nan_seen)
            and result["no_explosion"]
            and result["all_cubes_track_exact"]
            and result["chassis_lock"]["locked"]
            and result["all_obstacles_settled"]
        )

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
    p.add_argument("--steps", type=int, default=2400,
                   help="Driven steps (2400 @ dt=1/60 = 40 s).")
    p.add_argument("--warmup", type=int, default=120,
                   help="Pre-drive settle steps (forklift held at rest).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument("--mp4", default=None,
                   help="If set, RTX-render the forklift SE(2) slide with a data "
                        "HUD and encode an MP4 to this path (mounted).")
    p.add_argument("--width", type=int, default=960, help="mp4 render width.")
    p.add_argument("--height", type=int, default=540, help="mp4 render height.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
