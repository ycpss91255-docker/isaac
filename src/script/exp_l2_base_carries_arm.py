#!/usr/bin/env python3
"""L2 kinematic base carries an articulation arm on Isaac Sim 6.0.1 (isaac#228).

The most common true-L2 topology: a KINEMATIC base that MOVES on the floor
(scripted position path, true L2 per ADR-0008 / ADR-0021 D2) while an ARM rides
ON it. Two questions the base-movement case raises, both measured here:

  (1) RIDE-ALONG -- when the kinematic base translates, does the arm follow
      rigidly (its world pose tracks the base), or lag / detach?
  (2) BASE-MOTION DISTURBANCE -- while the base accelerates and decelerates, does
      an arm joint commanded to HOLD deviate (inertial / reaction coupling from
      the base's acceleration), and does it settle back after the base stops?
      Peak transient deviation during accel/decel + residual once the base rests.

CRITICAL drive rule (isaac#217 / ADR-0008 L2 clause 3)
------------------------------------------------------
The base MUST impart real velocity to disturb the arm. ``set_world_pose`` /
``xformOp:translate.Set`` is a ``setGlobalPose`` TELEPORT: it moves the body but
leaves solver velocity 0, so it drives NO velocity-dependent effect -- the arm
would feel nothing (the #217 finding). The base is therefore driven every tick
by a TRUE PhysX kinematic target
(``RigidBodyView.set_kinematic_targets`` on the physics tensor view, pos xyz +
quat xyzw, warp float32), which computes the solver velocity/acceleration the
arm's constraint and inertia react to. The base follows an
accel -> cruise -> decel -> stop position profile so the accel/decel windows
carry a real, known acceleration.

The topology decision (ADR-0008 rule 4 + the isaac#197 6.0.1 finding)
---------------------------------------------------------------------
A PhysX articulation LINK cannot be kinematic (ADR-0008 rule 4), so the moving
base cannot be a link of the arm's articulation. Two ways to attach the arm:

  * (A) USD-hierarchy parent -- the arm prim is a CHILD of the kinematic base
    prim in the USD stage, riding along via the transform hierarchy (no joint).
    This is the "clean carry" the issue names as intended. Topology ``usd_child``
    builds it and MEASURES whether a floating articulation actually tracks a
    kinematic USD parent that moves while physics plays. Physics expectation: a
    floating multibody lives in the WORLD inertial frame, so a moving kinematic
    USD PARENT does NOT drag it -- the arm is left behind (ride-along fails). If
    so, a joint is forced (see below), which is itself the reportable finding.

  * (B) FixedJoint / maximal loop joint from base to a floating articulation root
    -- the isaac#221 soft-seam case. isaac#197 found on 6.0.1 that welding a
    standalone floating articulation to a kinematic anchor by a maximal loop
    joint CRASHES the PhysX tensor backend (native SIGSEGV, exit 139). So the
    full-articulation weld is not the realization to lean on here.

The realization that actually CARRIES the arm and DISTURBS a held joint without
tripping the #197 crash is a maximal-coordinate REVOLUTE joint straight from the
kinematic base to a single DYNAMIC arm link, with an angular drive holding the
joint (topology ``revolute_maximal``). There is no ArticulationRootAPI, so the
tensor backend never has to build the crashing kinematic+articulation weld; the
joint rigidly carries the arm (ride-along), and the base's linear accel torques
the pendulum arm about the joint axis -- the reaction/inertial coupling the issue
asks to measure. This is the working "1-joint arm carried by a moving kinematic
base" and the source of the disturbance numbers.

``revolute_maximal`` geometry
-----------------------------
Per lane (an independent y-lane, base moves +X only, lanes never interact): a
KINEMATIC base box, and a DYNAMIC arm cube hanging a pendulum length L below a
+Y-axis revolute joint anchored at the base centre. At rest the arm COM sits
directly below the axis: gravity torque about +Y is ZERO (stable equilibrium)
and the drive target 0 coincides with it, so the ONLY disturbance is the base's
+X acceleration -- a clean pendulum-on-an-accelerating-cart. A base +X accel a
applies an inertial torque ~ m*a*L about +Y; the held joint deviates, the drive
(swept stiffness) fights back, and the residual after the base stops reports
whether it settles. Sweep: drive stiffness x base peak-accel.

Joint angle without an articulation view: the base never rotates (pure +X
translate), so the joint angle equals the arm's world rotation about +Y. It is
read geometrically -- rotate the arm's local down-axis (0,0,-1) by the arm's
world quaternion and take atan2(v_x, -v_z). Ride-along is the world coincidence
of the two joint anchors: ``||arm_anchor - base_anchor||`` (0 => carried rigidly)
plus follow_ratio = arm +X travel / base +X travel.

Metrics
-------
revolute_maximal, per (stiffness, accel) lane:
  ride_along_anchor_err_max_m / follow_ratio (does the joint carry the arm),
  hold_peak_dev_accel_rad / hold_peak_dev_decel_rad (peak |joint deviation| in
  the accel and decel windows), hold_residual_rad (mean |deviation| in the final
  settle window, base at rest), stable (bounded, no NaN).
usd_child (topology A literal): ride_along_x_err_m (base +X travel minus arm-root
  +X travel) and follow_ratio -- ~0 err / ratio ~1 => USD hierarchy carries a
  floating articulation; err ~ base travel / ratio ~0 => it does NOT (joint
  forced).

No committed Isaac 5.1 baseline exists for base-carry ride-along or base-motion
joint disturbance; this is a first-run 6.0.1 characterization.

Results are JSON to ``--out`` (a MOUNTED path) for the host to read back; stdout
through the docker run wrapper is not reliably captured. Teardown is an explicit
``os._exit`` (isaac#248 round 9): a cold headless 6.0.1 container's Omniverse Hub
connector aborts SimulationApp.close() with a busy-TaskGroup SIGABRT; os._exit
reaches the same clean exit while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_l2_base_carries_arm.py \\
        --out /home/<user>/work/worktree/<wt>/test/.l2-basecarry.json \\
        [--topology revolute_maximal|usd_child] \\
        [--warmup 60] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# revolute_maximal sweep: angular drive stiffness (stored units) x base peak accel.
_STIFFNESSES = [1.0e3, 1.0e4]
_ACCELS = [2.0, 5.0]                # base peak acceleration (m/s^2)

# Geometry (metres) / masses (kg).
_BASE_DIMS = (0.6, 0.6, 0.4)        # kinematic base box (size attr, no scale on jointed prim)
_BASE_CZ = 0.5                      # base centre z
_ARM_SIZE = 0.2                     # dynamic arm cube edge
_ARM_L = 0.4                        # pendulum length: arm COM below the +Y joint axis
_ARM_MASS = 2.0                     # arm link mass
_LANE_SPACING_Y = 3.0              # y gap between independent lanes

# Base motion profile timing (seconds) -- accel -> cruise -> decel -> settle.
_T_ACCEL = 0.5
_T_CRUISE = 0.5
_T_DECEL = 0.5
_T_SETTLE = 1.0

_BLOWUP_RAD = 3.0                   # |joint dev| above this => unstable/flopped


def _base_profile(dt, accel):
    """Per-tick base +X target positions: accel, cruise, decel, then hold.

    Returns (positions, phase_of_tick) where phase in {"accel","cruise","decel",
    "settle"}. Constant accel a for T_ACCEL (v ramps 0->a*T_ACCEL), constant v
    cruise, constant -a decel (v ramps back to 0), then a static hold.
    """
    na = int(round(_T_ACCEL / dt))
    nc = int(round(_T_CRUISE / dt))
    nd = int(round(_T_DECEL / dt))
    ns = int(round(_T_SETTLE / dt))
    v_cruise = accel * (na * dt)

    positions = []
    phases = []
    x = 0.0
    v = 0.0
    for _ in range(na):
        v += accel * dt
        x += v * dt
        positions.append(x)
        phases.append("accel")
    for _ in range(nc):
        x += v_cruise * dt
        positions.append(x)
        phases.append("cruise")
    v = v_cruise
    for _ in range(nd):
        v -= accel * dt
        if v < 0.0:
            v = 0.0
        x += v * dt
        positions.append(x)
        phases.append("decel")
    x_final = x
    for _ in range(ns):
        positions.append(x_final)
        phases.append("settle")
    return positions, phases


def _qrot(quat_wxyz, vec):
    """Rotate vec by quaternion (w,x,y,z). Returns a length-3 numpy array."""
    import numpy as np

    w, x, y, z = [float(c) for c in quat_wxyz]
    vx, vy, vz = [float(c) for c in vec]
    # t = 2 * (q_vec x v)
    tx = 2.0 * (y * vz - z * vy)
    ty = 2.0 * (z * vx - x * vz)
    tz = 2.0 * (x * vy - y * vx)
    # v' = v + w*t + q_vec x t
    rx = vx + w * tx + (y * tz - z * ty)
    ry = vy + w * ty + (z * tx - x * tz)
    rz = vz + w * tz + (x * ty - y * tx)
    return np.asarray([rx, ry, rz], dtype=float)


def _joint_angle_about_y(arm_quat_wxyz):
    """Joint deflection (rad) about +Y from the arm's world quaternion.

    Base never rotates, so the joint angle == the arm's world rotation about +Y.
    Rotate the arm's rest down-axis (0,0,-1) into world and read its tilt in the
    X-Z plane: atan2(v_x, -v_z). Rest (down-axis -> world -Z) gives 0.
    """
    v = _qrot(arm_quat_wxyz, (0.0, 0.0, -1.0))
    return math.atan2(float(v[0]), -float(v[2]))


def _build_ground_and_light(stage):
    from pxr import Gf, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)
    UsdGeom.Xform.Define(stage, "/World")
    light = UsdLux.DistantLight.Define(stage, "/World/SunLight")
    light.CreateIntensityAttr(3000.0)

    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(400.0, 400.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())


def _build_revolute_maximal(stage):
    """One (kinematic base, dynamic pendulum arm, revolute+drive) per (k, accel) lane.

    NB: no XformOp scale on any jointed prim -- USD would scale the joint's
    LocalPos anchors and corrupt the weld; geometry size is set on the Cube size
    attr so LocalPos is true metres.
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    specs = []
    lane = 0
    for k in _STIFFNESSES:
        for accel in _ACCELS:
            y0 = lane * _LANE_SPACING_Y
            tag = f"k{int(round(k)):05d}_a{int(round(accel * 10)):03d}"

            base_path = f"/World/base_{tag}"
            base = UsdGeom.Cube.Define(stage, base_path)
            # Cubic base via the size attr (no XformOp scale): the joint's body0
            # is the base and a scaled base frame WOULD corrupt LocalPos0.
            base.GetSizeAttr().Set(_BASE_DIMS[0])
            base.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(0.0, y0, _BASE_CZ)
            )
            bprim = base.GetPrim()
            brb = UsdPhysics.RigidBodyAPI.Apply(bprim)
            brb.CreateKinematicEnabledAttr(True)   # <-- L2 standalone kinematic base
            UsdPhysics.CollisionAPI.Apply(bprim)
            UsdPhysics.MassAPI.Apply(bprim).CreateMassAttr(1.0)

            # Dynamic arm cube, COM _ARM_L below the base centre (pendulum).
            arm_path = f"/World/arm_{tag}"
            arm = UsdGeom.Cube.Define(stage, arm_path)
            arm.GetSizeAttr().Set(_ARM_SIZE)
            arm.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(0.0, y0, _BASE_CZ - _ARM_L)
            )
            aprim = arm.GetPrim()
            UsdPhysics.RigidBodyAPI.Apply(aprim)   # dynamic
            UsdPhysics.MassAPI.Apply(aprim).CreateMassAttr(_ARM_MASS)
            PhysxSchema.PhysxRigidBodyAPI.Apply(aprim).CreateLinearDampingAttr(0.0)

            # +Y revolute joint at the base centre; anchor on arm is _ARM_L above
            # the arm COM, so both anchors coincide at the base centre at rest.
            joint_path = f"/World/revjoint_{tag}"
            joint = UsdPhysics.RevoluteJoint.Define(stage, joint_path)
            joint.CreateBody0Rel().SetTargets([base_path])
            joint.CreateBody1Rel().SetTargets([arm_path])
            joint.CreateAxisAttr("Y")
            joint.CreateLocalPos0Attr().Set(Gf.Vec3f(0.0, 0.0, 0.0))
            joint.CreateLocalPos1Attr().Set(Gf.Vec3f(0.0, 0.0, _ARM_L))
            joint.CreateLocalRot0Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
            joint.CreateLocalRot1Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))

            drive = UsdPhysics.DriveAPI.Apply(joint.GetPrim(), "angular")
            # critical-ish damping for a pendulum of inertia ~ m*L^2 about the axis.
            axis_inertia = _ARM_MASS * _ARM_L * _ARM_L
            damping = 2.0 * math.sqrt(max(k, 1.0) * axis_inertia)
            drive.CreateStiffnessAttr(float(k))
            drive.CreateDampingAttr(float(damping))
            drive.CreateTargetPositionAttr(0.0)
            drive.CreateMaxForceAttr(float("inf"))

            specs.append({
                "tag": tag,
                "stiffness": k,
                "accel": accel,
                "y0": y0,
                "base_path": base_path,
                "arm_path": arm_path,
                "axis_inertia": axis_inertia,
                "damping": damping,
            })
            lane += 1
    return specs


def _build_usd_child(stage):
    """Topology A literal: a floating 1-revolute articulation parented UNDER the

    kinematic base prim in the USD hierarchy (no joint to the base). One lane.
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    y0 = 0.0
    base_path = "/World/base_child"
    base = UsdGeom.Cube.Define(stage, base_path)
    base.GetSizeAttr().Set(_BASE_DIMS[0])
    base.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, y0, _BASE_CZ))
    bprim = base.GetPrim()
    brb = UsdPhysics.RigidBodyAPI.Apply(bprim)
    brb.CreateKinematicEnabledAttr(True)
    UsdPhysics.CollisionAPI.Apply(bprim)
    UsdPhysics.MassAPI.Apply(bprim).CreateMassAttr(1.0)

    # Floating articulation root parented UNDER the base prim (USD child).
    root_path = f"{base_path}/arm_root"
    root = UsdGeom.Cube.Define(stage, root_path)
    root.GetSizeAttr().Set(_ARM_SIZE)
    root.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(0.0, 0.0, _BASE_DIMS[0] * 0.5 + _ARM_SIZE)
    )
    rprim = root.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(rprim)
    UsdPhysics.MassAPI.Apply(rprim).CreateMassAttr(_ARM_MASS)
    UsdPhysics.ArticulationRootAPI.Apply(rprim)
    PhysxSchema.PhysxArticulationAPI.Apply(rprim)

    child_path = f"{base_path}/arm_link"
    child = UsdGeom.Cube.Define(stage, child_path)
    child.GetSizeAttr().Set(_ARM_SIZE)
    child.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(0.3, 0.0, _BASE_DIMS[0] * 0.5 + _ARM_SIZE)
    )
    chprim = child.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(chprim)
    UsdPhysics.MassAPI.Apply(chprim).CreateMassAttr(_ARM_MASS * 0.5)

    rev = UsdPhysics.RevoluteJoint.Define(stage, f"{base_path}/arm_joint")
    rev.CreateBody0Rel().SetTargets([root_path])
    rev.CreateBody1Rel().SetTargets([child_path])
    rev.CreateAxisAttr("Y")
    rev.CreateLocalPos0Attr().Set(Gf.Vec3f(0.3, 0.0, 0.0))
    rev.CreateLocalPos1Attr().Set(Gf.Vec3f(0.0, 0.0, 0.0))

    return [{
        "tag": "usd_child",
        "y0": y0,
        "base_path": base_path,
        "root_path": root_path,
    }]


def _run_revolute_maximal(args, result):
    import numpy as np
    import omni.usd
    import warp as wp
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim

    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()
    _build_ground_and_light(stage)
    specs = _build_revolute_maximal(stage)

    world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                  rendering_dt=args.dt)
    world.reset()

    sim_view = world.physics_sim_view
    wp_device = sim_view.device
    wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)
    base_view = {s["tag"]: sim_view.create_rigid_body_view(s["base_path"]) for s in specs}
    arm = {s["tag"]: SingleRigidPrim(s["arm_path"]) for s in specs}
    result["drive_api"] = (
        "physics tensor RigidBodyView.set_kinematic_targets (pos xyz + quat xyzw) "
        "per tick on the physics:kinematicEnabled base -> real PhysX kinematic "
        "target with solver velocity; arm carried by a maximal UsdPhysics."
        "RevoluteJoint + angular DriveAPI (hold target 0); SingleRigidPrim reads "
        "the arm pose back. (set_world_pose would be a no-velocity teleport, #217.)"
    )

    # Warm-up: base held so the pendulum settles at the drive/gravity equilibrium.
    for _ in range(args.warmup):
        for s in specs:
            target = wp.array(
                [[0.0, s["y0"], _BASE_CZ, 0.0, 0.0, 0.0, 1.0]],
                dtype=wp.float32, device=wp_device,
            )
            base_view[s["tag"]].set_kinematic_targets(target, wp_idx)
        world.step(render=False)

    # Per-lane profiles + accumulators.
    profiles = {s["tag"]: _base_profile(args.dt, s["accel"]) for s in specs}
    n_ticks = len(next(iter(profiles.values()))[0])
    base_anchor0 = {}
    arm_x0 = {}
    for s in specs:
        bpos = np.asarray(base_view[s["tag"]].get_transforms()).reshape(-1)[:3].astype(float)
        apos, _ = arm[s["tag"]].get_world_pose()
        base_anchor0[s["tag"]] = bpos.copy()
        arm_x0[s["tag"]] = float(np.asarray(apos, dtype=float).reshape(-1)[0])

    peak_accel = {s["tag"]: 0.0 for s in specs}
    peak_decel = {s["tag"]: 0.0 for s in specs}
    ride_err_max = {s["tag"]: 0.0 for s in specs}
    nan_seen = {s["tag"]: False for s in specs}
    settle_dev = {s["tag"]: [] for s in specs}

    for t in range(n_ticks):
        for s in specs:
            xs, ph = profiles[s["tag"]]
            xt = xs[t]
            target = wp.array(
                [[xt, s["y0"], _BASE_CZ, 0.0, 0.0, 0.0, 1.0]],
                dtype=wp.float32, device=wp_device,
            )
            base_view[s["tag"]].set_kinematic_targets(target, wp_idx)
        world.step(render=False)

        for s in specs:
            tag = s["tag"]
            xs, ph = profiles[tag]
            phase = ph[t]
            btf = np.asarray(base_view[tag].get_transforms()).reshape(-1)
            bpos = btf[:3].astype(float)
            apos, aq = arm[tag].get_world_pose()
            apos = np.asarray(apos, dtype=float).reshape(-1)
            aq = np.asarray(aq, dtype=float).reshape(-1)   # (w,x,y,z)
            if not (np.all(np.isfinite(bpos)) and np.all(np.isfinite(apos))
                    and np.all(np.isfinite(aq))):
                nan_seen[tag] = True
                continue

            dev = _joint_angle_about_y(aq)

            # Ride-along: world coincidence of the two joint anchors. Base anchor
            # is the base centre (LocalPos0 = 0); arm anchor is arm COM + R*(0,0,L).
            arm_anchor = apos + _qrot(aq, (0.0, 0.0, _ARM_L))
            ride_err = float(np.linalg.norm(arm_anchor - bpos))
            ride_err_max[tag] = max(ride_err_max[tag], ride_err)

            if phase == "accel":
                peak_accel[tag] = max(peak_accel[tag], abs(dev))
            elif phase == "decel":
                peak_decel[tag] = max(peak_decel[tag], abs(dev))
            elif phase == "settle":
                settle_dev[tag].append(abs(dev))

    lanes = []
    stable_all = True
    ride_ok = True
    for s in specs:
        tag = s["tag"]
        btf = np.asarray(base_view[tag].get_transforms()).reshape(-1)
        bpos = btf[:3].astype(float)
        apos, _ = arm[tag].get_world_pose()
        apos = np.asarray(apos, dtype=float).reshape(-1)
        base_travel = float(bpos[0] - base_anchor0[tag][0])
        arm_travel = float(apos[0] - arm_x0[tag])
        follow_ratio = (arm_travel / base_travel) if abs(base_travel) > 1e-9 else float("nan")
        tail = settle_dev[tag][-30:] if len(settle_dev[tag]) >= 30 else settle_dev[tag]
        residual = float(np.mean(tail)) if tail else float("nan")
        peak = max(peak_accel[tag], peak_decel[tag])
        stable = bool((not nan_seen[tag]) and peak < _BLOWUP_RAD)
        lane = {
            "tag": tag,
            "stiffness_stored": s["stiffness"],
            "base_peak_accel_mps2": s["accel"],
            "axis_inertia_izz": s["axis_inertia"],
            "damping_stored": s["damping"],
            "base_travel_x_m": base_travel,
            "arm_travel_x_m": arm_travel,
            "follow_ratio": follow_ratio,
            "ride_along_anchor_err_max_m": ride_err_max[tag],
            "hold_peak_dev_accel_rad": peak_accel[tag],
            "hold_peak_dev_accel_deg": math.degrees(peak_accel[tag]),
            "hold_peak_dev_decel_rad": peak_decel[tag],
            "hold_peak_dev_decel_deg": math.degrees(peak_decel[tag]),
            "hold_residual_rad": residual,
            "hold_residual_mrad": residual * 1000.0 if not math.isnan(residual) else float("nan"),
            "nan_seen": bool(nan_seen[tag]),
            "stable": stable,
        }
        lanes.append(lane)
        if not stable:
            stable_all = False
        if not (not math.isnan(follow_ratio) and abs(follow_ratio - 1.0) < 0.05
                and ride_err_max[tag] < 1e-3):
            ride_ok = False
    result["lanes"] = lanes
    result["ride_along_ok"] = bool(ride_ok)
    result["stable_all"] = bool(stable_all)
    result["disturbance_scales_with_accel"] = _accel_monotonic(lanes)


def _accel_monotonic(lanes):
    """Within each stiffness, does peak deviation rise with base accel?"""
    by_k = {}
    for ln in lanes:
        by_k.setdefault(ln["stiffness_stored"], []).append(ln)
    out = {}
    for k, rows in by_k.items():
        rows = sorted(rows, key=lambda r: r["base_peak_accel_mps2"])
        peaks = [max(r["hold_peak_dev_accel_rad"], r["hold_peak_dev_decel_rad"]) for r in rows]
        accels = [r["base_peak_accel_mps2"] for r in rows]
        mono = all(peaks[i] <= peaks[i + 1] + 1e-9 for i in range(len(peaks) - 1))
        out[f"k_{int(round(k))}"] = {
            "accels_mps2": accels,
            "peak_dev_rad": peaks,
            "monotonic_nondecreasing": bool(mono) if len(peaks) > 1 else None,
        }
    return out


def _run_usd_child(args, result):
    import numpy as np
    import omni.usd
    import warp as wp
    from isaacsim.core.api import World
    from isaacsim.core.prims import SingleRigidPrim

    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()
    _build_ground_and_light(stage)
    specs = _build_usd_child(stage)

    # NOTE: --mp4 here is MISLEADING and kept only for completeness. The arm_root
    # is a USD child of the base, so the render composes its pose as base x local
    # -> the arm VISUALLY drags along with the base even though the PHYSICS (the
    # data: follow_ratio ~ 0) shows it does not follow. The negative result is a
    # data finding (the table), not a watchable one -- do not ship this video.
    render = bool(getattr(args, "mp4", None))
    cap = None
    if render:
        import viz_render as vr
        from pxr import UsdGeom as _UG
        s0 = specs[0]
        vr.apply_clean_render_settings()
        vr.add_fill_lights(stage)
        _UG.Imageable(stage.GetPrimAtPath("/World/Ground")).MakeInvisible()
        vr.bind(stage, s0["base_path"],
                vr.material(stage, "/World/Looks/Base", (0.2, 0.5, 0.9)))
        vr.bind(stage, s0["root_path"],
                vr.material(stage, "/World/Looks/Root", (0.95, 0.5, 0.1)))
        vr.bind(stage, s0["base_path"] + "/arm_link",
                vr.material(stage, "/World/Looks/Arm", (0.2, 0.8, 0.3)))
        vr.make_camera(stage, "/World/VizCam", (1.2, -7.0, 4.0), (1.2, 0.0, 0.6))

    world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                  rendering_dt=args.dt)
    world.reset()

    sim_view = world.physics_sim_view
    wp_device = sim_view.device
    wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)
    s = specs[0]
    base_view = sim_view.create_rigid_body_view(s["base_path"])
    root = SingleRigidPrim(s["root_path"])
    if render:
        import viz_render as vr
        cap = vr.Capturer(world, "/World/VizCam", args.width, args.height)
    frames, nonblack = [], 0
    result["drive_api"] = (
        "kinematic base driven by RigidBodyView.set_kinematic_targets (+X profile); "
        "arm is a FLOATING articulation parented UNDER the base prim in USD (no "
        "joint to base). SingleRigidPrim reads the arm-root world pose."
    )

    for _ in range(args.warmup):
        target = wp.array([[0.0, s["y0"], _BASE_CZ, 0.0, 0.0, 0.0, 1.0]],
                          dtype=wp.float32, device=wp_device)
        base_view.set_kinematic_targets(target, wp_idx)
        world.step(render=False)

    rpos0, _ = root.get_world_pose()
    root_x0 = float(np.asarray(rpos0, dtype=float).reshape(-1)[0])
    base_x0 = float(np.asarray(base_view.get_transforms()).reshape(-1)[0])

    positions, phases = _base_profile(args.dt, _ACCELS[-1])
    cap_steps = set(int(round(v)) for v in np.linspace(
        0, len(positions) - 1, 48)) if render else set()
    nan_seen = False
    for t in range(len(positions)):
        target = wp.array([[positions[t], s["y0"], _BASE_CZ, 0.0, 0.0, 0.0, 1.0]],
                          dtype=wp.float32, device=wp_device)
        base_view.set_kinematic_targets(target, wp_idx)
        world.step(render=render)
        if render and t in cap_steps:
            import viz_render as vr
            bx = float(np.asarray(base_view.get_transforms()).reshape(-1)[0])
            rx = float(np.asarray(root.get_world_pose()[0]).reshape(-1)[0])
            bt, rt = bx - base_x0, rx - root_x0
            fr = (rt / bt) if abs(bt) > 1e-9 else 0.0
            lines = [
                "L2 kinematic base carries a floating articulation? (negative)",
                "blue base slides +X; orange/green arm is parented under it in USD",
                "base travel  = %6.3f m" % bt,
                "arm  travel  = %6.3f m" % rt,
                "follow ratio = %6.3f   (0 = arm left behind -> joint needed)" % fr,
            ]
            rgb = cap.grab()
            if rgb is not None and float(rgb.mean()) > 1.0:
                nonblack += 1
            if rgb is None:
                rgb = np.zeros((args.height, args.width, 3), dtype=np.uint8)
            frames.append(vr.overlay(rgb, lines))

    if render and frames:
        import viz_render as vr
        vr.encode_mp4(args.mp4, frames, fps=15)
        cap.detach()
        result["mp4"] = args.mp4
        result["mp4_frames"] = len(frames)
        result["mp4_nonblack"] = nonblack

    bpos = np.asarray(base_view.get_transforms()).reshape(-1)[:3].astype(float)
    rpos, _ = root.get_world_pose()
    rpos = np.asarray(rpos, dtype=float).reshape(-1)
    if not (np.all(np.isfinite(bpos)) and np.all(np.isfinite(rpos))):
        nan_seen = True
    base_travel = float(bpos[0] - base_x0)
    root_travel = float(rpos[0] - root_x0)
    follow_ratio = (root_travel / base_travel) if abs(base_travel) > 1e-9 else float("nan")
    ride_err = float(base_travel - root_travel)
    carried = bool(not math.isnan(follow_ratio) and abs(follow_ratio - 1.0) < 0.05)
    result["lanes"] = [{
        "tag": "usd_child",
        "base_travel_x_m": base_travel,
        "arm_root_travel_x_m": root_travel,
        "ride_along_x_err_m": ride_err,
        "follow_ratio": follow_ratio,
        "nan_seen": bool(nan_seen),
        "topology_A_carries": carried,
    }]
    result["topology_A_usd_hierarchy_carries_arm"] = carried
    result["finding"] = (
        "topology A (USD-hierarchy parent) CARRIES the floating articulation"
        if carried else
        "topology A (USD-hierarchy parent) does NOT carry the floating "
        "articulation -- a joint is forced for base carry (see revolute_maximal)"
    )


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})   # noqa: F841

    result = {
        "issue": "isaac#228",
        "adr": "ADR-0008 L2 kinematic base carries an arm (rule 4: no kinematic articulation link)",
        "isaac_variant": "6.0.1",
        "topology": args.topology,
        "warmup_steps": args.warmup,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "base_profile_s": {
            "accel": _T_ACCEL, "cruise": _T_CRUISE, "decel": _T_DECEL, "settle": _T_SETTLE,
        },
        "arm_pendulum_length_m": _ARM_L,
        "arm_mass_kg": _ARM_MASS,
        "stiffnesses_stored": _STIFFNESSES if args.topology == "revolute_maximal" else None,
        "accels_mps2": _ACCELS,
        "metric": (
            "revolute_maximal: per (stiffness, accel) ride_along_anchor_err_max_m + "
            "follow_ratio (joint carries arm), hold_peak_dev_accel/decel_rad (held-"
            "joint peak deviation in accel/decel windows), hold_residual_rad (mean "
            "|dev| after base stops). usd_child: ride_along_x_err_m + follow_ratio "
            "(does a moving kinematic USD parent carry a floating articulation)."
        ),
        "baseline_5_1": (
            "none committed -- first-run 6.0.1 characterization of base-carry "
            "ride-along and base-motion joint disturbance"
        ),
        "drive_api": None,
        "lanes": [],
        "error": None,
    }

    try:
        if args.topology == "revolute_maximal":
            _run_revolute_maximal(args, result)
        elif args.topology == "usd_child":
            _run_usd_child(args, result)
        else:
            raise ValueError(f"unknown topology {args.topology!r}")
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
    p.add_argument("--topology", default="revolute_maximal",
                   choices=["revolute_maximal", "usd_child"],
                   help="revolute_maximal: kinematic base + maximal revolute joint "
                        "arm (carry + disturbance). usd_child: floating articulation "
                        "parented under the base in USD (topology A ride-along test).")
    p.add_argument("--warmup", type=int, default=60,
                   help="Warm-up steps (base held; arm settles at equilibrium).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument("--mp4", default=None,
                   help="usd_child topology: RTX-render the base-carry with a data "
                        "HUD and encode an MP4 to this path (mounted).")
    p.add_argument("--width", type=int, default=960, help="mp4 render width.")
    p.add_argument("--height", type=int, default=540, help="mp4 render height.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
