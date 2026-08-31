#!/usr/bin/env python3
"""L3 drive-limit / constraint verification on Isaac Sim 6.0.1 (isaac#188).

Empirically exercises the four known limitations that constrain L3 articulation
drive behavior (ADR-0021 "needs experiment" list), one section per sub-issue,
and records the observed 6.0.1 behavior + the numeric limits into one MOUNTED
JSON so the host reads them back (stdout through the docker wrapper is not
reliably captured -- the file is the source of truth).

Sub-issues (parent #188)
------------------------
  #189  *pi/180 revolute gain scaling. STAGE-ONLY: apply a known drive stiffness
        (800) through the migrated ``apply_joint_drive`` (Isaac Lab
        ``modify_joint_drive_properties``) and read the as-applied USD DriveAPI
        stiffness back. USD stores ANGULAR gains per-DEGREE while the config Kp
        is per-RADIAN, so a revolute joint's stored value is 800*pi/180 = 13.96;
        a PRISMATIC (linear) drive takes NO conversion -> stored 800. Confirms
        the scaling factor + that it is angular-only (#168).

  #190  effort / velocity clamp. STEPPED on a vertical PRISMATIC lift holding a
        10 kg payload against gravity (load = m*g = 98.1 N):
          effort:   sweep the drive maxForce. A vertical gravity hold needs
                    F_drive = m*g at ANY position, so the clamp is binary --
                    maxForce >= m*g holds (droop = m*g/k), maxForce < m*g cannot
                    support the weight and the joint STALLS at the lower joint
                    limit. That "can't lift it / stalls" IS the effort-limit
                    clamp (ADR-0021 D1a). Measured joint effort is read back and
                    confirmed to saturate at maxForce.
          velocity: command a large step with LOW damping and measure the peak
                    joint velocity under a HIGH vs a LOW physxJoint:
                    maxJointVelocity. The low limit clamps the peak -> velocity
                    is clamped.

  #191  joint position limit. Command a target FAR beyond the joint upper limit
        and confirm the joint stops AT the limit (clamp), measuring the settled
        position vs the limit and any transient overshoot past the bound.

  #192  solver position-iteration count vs precision. Vary the articulation
        physxArticulation:solverPositionIterationCount and measure the
        steady-state droop of a loaded moderate-stiffness drive; report whether
        (and how much) iteration count moves the achievable precision.

Physical setup -- WHY a VERTICAL PRISMATIC lift for #190-#192
-------------------------------------------------------------
ADR-0021 D1b frames L2/L2.5/L3 as a JOINT POSITION-control vocabulary whose
canonical case is a forklift mast/fork told "go to this height" -- a vertical
prismatic lift -- and states its prediction as the LINEAR relation
``droop = m*g / stiffness`` (N/m, meters), only dimensionally consistent for a
prismatic drive. A linear drive takes NO ``pi/180`` conversion (angular-only,
#168), so the effort/limit numbers stay in plain SI. The URDFs are authored
INLINE (written to /tmp at runtime) so this one committed file is self-contained,
and imported through the migrated framework pipeline
(``isaac_devkit.model_import._convert_urdf``) -- the same URDF->USD converter the
#168 joint-drive integration test exercises on 6.0.1.

Teardown is an explicit ``os._exit`` (isaac#248 round 9): under 6.0.1 a cold
headless container's Omniverse Hub connector cannot launch and carb's reconnect
task aborts SimulationApp.close() with a busy-TaskGroup SIGABRT; os._exit reaches
the same clean exit while skipping that asserting teardown.

CLI::

    PYTHONPATH=/home/<user>/work/worktree/<wt>/framework \\
    /isaac-sim/python.sh exp_drive_limits.py \\
        --out /home/<user>/work/worktree/<wt>/test/.drive-limits.json \\
        [--mass 10.0] [--stiffness 1e5] [--settle-steps 600]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# ---- Fixtures ---------------------------------------------------------------

# Minimal single-DOF revolute joint (for the #189 angular readback). The
# geometry is irrelevant -- only the joint type (revolute -> angular DriveAPI)
# matters for the per-degree conversion.
_REVOLUTE_URDF = """<?xml version="1.0"?>
<robot name="revolute_scale">
  <link name="base_link">
    <inertial><origin xyz="0 0 0"/><mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual><geometry><box size="0.1 0.1 0.1"/></geometry></visual>
  </link>
  <link name="arm_link">
    <inertial><origin xyz="0 0 0"/><mass value="1.0"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual><geometry><box size="0.4 0.1 0.1"/></geometry></visual>
  </link>
  <joint name="arm_joint" type="revolute">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="base_link"/><child link="arm_link"/>
    <axis xyz="0 0 1"/>
    <limit lower="-3.14159" upper="3.14159" effort="100000.0" velocity="100.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
</robot>
"""

# Minimal single-DOF prismatic vertical lift (for #189 linear readback and the
# #190-#192 stepped tests). lift_link is the payload mass, free to slide along
# +Z; gravity loads the drive with m*g. Joint limits are set generously here and
# TIGHTENED at runtime for the #191 position-limit test.
_PRISMATIC_URDF = """<?xml version="1.0"?>
<robot name="prismatic_limits">
  <link name="base_link">
    <inertial><origin xyz="0 0 0"/><mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual><geometry><box size="0.1 0.1 0.1"/></geometry></visual>
  </link>
  <link name="lift_link">
    <inertial><origin xyz="0 0 0"/><mass value="{mass}"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual><geometry><box size="0.2 0.2 0.1"/></geometry></visual>
  </link>
  <joint name="lift_joint" type="prismatic">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="base_link"/><child link="lift_link"/>
    <axis xyz="0 0 1"/>
    <limit lower="-2.0" upper="2.0" effort="100000.0" velocity="1000.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
</robot>
"""


# ---- Stage / prim helpers ---------------------------------------------------


def _convert(urdf_text, stem):
    """Author urdf_text to /tmp and convert to USD via the migrated pipeline."""
    from isaac_devkit import model_import

    urdf_path = Path(f"/tmp/{stem}.urdf")
    urdf_path.write_text(urdf_text)
    out_usd = Path(f"/tmp/{stem}.usd")
    produced = model_import._convert_urdf(
        urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
    )
    if not produced.exists():
        raise RuntimeError(f"converter produced no USD at {produced}")
    return produced


def _open_stage(usd_path):
    import omni.usd

    omni.usd.get_context().open_stage(str(usd_path))
    return omni.usd.get_context().get_stage()


def _find_joint(stage, kind):
    """Path of the first joint prim of ``kind`` ('Revolute'|'Prismatic')."""
    from pxr import UsdPhysics

    typed = getattr(UsdPhysics, f"{kind}Joint")
    for prim in stage.Traverse():
        if prim.IsA(typed):
            return str(prim.GetPath())
    for prim in stage.Traverse():
        if kind in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _find_articulation_root(stage):
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            return str(prim.GetPath())
    return None


def _read_drive_stiffness(stage, joint_path, axis):
    """As-applied USD DriveAPI stiffness on ``axis`` ('angular'|'linear')."""
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, axis)
    if not drive:
        return None
    attr = drive.GetStiffnessAttr()
    return float(attr.Get()) if attr and attr.Get() is not None else None


def _set_linear_drive(stage, joint_path, stiffness, damping, target, max_force):
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "linear")
    if not drive:
        drive = UsdPhysics.DriveAPI.Apply(prim, "linear")
    drive.CreateTypeAttr().Set("force")
    drive.CreateStiffnessAttr().Set(float(stiffness))
    drive.CreateDampingAttr().Set(float(damping))
    drive.CreateTargetPositionAttr().Set(float(target))
    drive.CreateMaxForceAttr().Set(float(max_force))
    return {
        "stored_stiffness": drive.GetStiffnessAttr().Get(),
        "stored_damping": drive.GetDampingAttr().Get(),
        "stored_target": drive.GetTargetPositionAttr().Get(),
        "stored_max_force": drive.GetMaxForceAttr().Get(),
    }


def _set_joint_limits(stage, joint_path, lower, upper):
    """Tighten the prismatic joint's lower/upper position limits."""
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    joint = UsdPhysics.PrismaticJoint(prim)
    joint.CreateLowerLimitAttr().Set(float(lower))
    joint.CreateUpperLimitAttr().Set(float(upper))
    return (
        joint.GetLowerLimitAttr().Get(),
        joint.GetUpperLimitAttr().Get(),
    )


def _set_max_joint_velocity(stage, joint_path, max_vel):
    """Set physxJoint:maxJointVelocity on the joint prim (best-effort)."""
    from pxr import Sdf

    prim = stage.GetPrimAtPath(joint_path)
    attr = prim.GetAttribute("physxJoint:maxJointVelocity")
    if not attr or not attr.IsValid():
        attr = prim.CreateAttribute(
            "physxJoint:maxJointVelocity", Sdf.ValueTypeNames.Float
        )
    attr.Set(float(max_vel))
    got = attr.Get()
    return float(got) if got is not None else None


def _set_solver_position_iterations(stage, root_path, count):
    """Set physxArticulation:solverPositionIterationCount (best-effort)."""
    from pxr import Sdf

    prim = stage.GetPrimAtPath(root_path)
    attr = prim.GetAttribute("physxArticulation:solverPositionIterationCount")
    if not attr or not attr.IsValid():
        attr = prim.CreateAttribute(
            "physxArticulation:solverPositionIterationCount",
            Sdf.ValueTypeNames.Int,
        )
    attr.Set(int(count))
    got = attr.Get()
    return int(got) if got is not None else None


def _make_articulation(root_path):
    import isaacsim.core.prims as prims

    errors = []
    for cls_name in ("SingleArticulation", "Articulation"):
        cls = getattr(prims, cls_name, None)
        if cls is None:
            errors.append(f"{cls_name}: absent")
            continue
        try:
            return cls(root_path), cls_name
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{cls_name}: {type(exc).__name__}: {exc}")
    raise RuntimeError("no usable Articulation class: " + " | ".join(errors))


def _dof_index(art, joint_name):
    try:
        names = list(art.dof_names)
        if joint_name in names:
            return names.index(joint_name), names
        return 0, names
    except Exception:  # noqa: BLE001
        return 0, None


def _joint_position(art, dof_idx):
    import numpy as np

    return float(np.asarray(art.get_joint_positions()).reshape(-1)[dof_idx])


def _joint_velocity(art, dof_idx):
    import numpy as np

    try:
        return float(
            np.asarray(art.get_joint_velocities()).reshape(-1)[dof_idx]
        )
    except Exception:  # noqa: BLE001
        return float("nan")


def _measured_effort(art, dof_idx):
    """Best-effort measured joint effort (drive force) for dof_idx, or NaN."""
    import numpy as np

    for meth in (
        "get_measured_joint_efforts",
        "get_applied_joint_efforts",
        "get_measured_joint_forces",
    ):
        fn = getattr(art, meth, None)
        if fn is None:
            continue
        try:
            val = np.asarray(fn()).reshape(-1)
            if val.size:
                return float(val[dof_idx]) if dof_idx < val.size else float(val[0])
        except Exception:  # noqa: BLE001
            continue
    return float("nan")


def _set_target(art, dof_idx, value):
    """Best-effort live position-target write through the articulation view."""
    import numpy as np

    base = np.asarray(art.get_joint_positions()).reshape(-1).astype(float)
    vec = base.copy()
    vec[dof_idx] = float(value)
    setter = getattr(art, "set_joint_position_targets", None)
    if setter is not None:
        for shaped in (vec.reshape(1, -1), vec):
            try:
                setter(shaped)
                return True
            except Exception:  # noqa: BLE001
                continue
    try:
        from isaacsim.core.utils.types import ArticulationAction

        art.apply_action(ArticulationAction(joint_positions=vec))
        return True
    except Exception:  # noqa: BLE001
        return False


# ---- Test sections ----------------------------------------------------------


def _test_gain_scaling(result):
    """#189: read back as-applied DriveAPI stiffness for a known Kp=800."""
    from isaac_devkit import model_import

    kp = 800.0
    kd = 50.0
    out = {"applied_stiffness_config_Kp": kp, "cases": []}

    for kind, urdf, axis, expect in (
        ("revolute", _REVOLUTE_URDF, "angular", kp * math.pi / 180.0),
        ("prismatic", _PRISMATIC_URDF.format(mass=1.0), "linear", kp),
    ):
        produced = _convert(urdf, f"scale_{kind}")
        stage = _open_stage(produced)
        joint_path = _find_joint(stage, kind.capitalize())
        applied = model_import.apply_joint_drive(
            joint_path, kp, kd, stage=stage
        )
        stored = _read_drive_stiffness(stage, joint_path, axis)
        factor = (stored / kp) if stored not in (None, 0) else None
        out["cases"].append({
            "joint_kind": kind,
            "drive_axis": axis,
            "apply_returned": bool(applied),
            "stored_stiffness_usd": stored,
            "expected_stored": expect,
            "ratio_stored_over_Kp": factor,
            "matches_expected": (
                stored is not None and abs(stored - expect) < 0.05
            ),
            "note": (
                "USD angular DriveAPI stores per-DEGREE; Kp per-RADIAN -> *pi/180"
                if axis == "angular"
                else "linear drive: no angular conversion (per-meter == per-meter)"
            ),
        })
    result["gain_scaling_pi_over_180"] = out


def _build_lift(args):
    """Convert the prismatic lift, open it, build a persistent articulation."""
    from isaacsim.core.api import SimulationContext

    produced = _convert(_PRISMATIC_URDF.format(mass=args.mass), "lift_limits")
    stage = _open_stage(produced)
    joint_path = _find_joint(stage, "Prismatic")
    root_path = _find_articulation_root(stage) or joint_path
    sim = SimulationContext(
        stage_units_in_meters=1.0, physics_dt=args.dt, rendering_dt=args.dt
    )
    art, art_cls = _make_articulation(root_path)
    return stage, joint_path, root_path, sim, art, art_cls


def _reset_and_init(sim, art):
    sim.reset()
    try:
        art.initialize()
    except Exception:  # noqa: BLE001
        pass


def _test_effort_clamp(result, ctx, args):
    """#190a: sweep drive maxForce on a gravity hold -> stall when < m*g."""
    stage, joint_path, _root, sim, art, _cls = ctx
    load = args.mass * GRAVITY
    k = args.stiffness
    damping = 2.0 * math.sqrt(k * args.mass)
    target = 0.5
    # maxForce: comfortably above the load, just above, and below (< m*g).
    max_forces = [1.0e6, load * 1.2, load * 0.5]
    points = []
    for mf in max_forces:
        stored = _set_linear_drive(stage, joint_path, k, damping, target, mf)
        # generous limits so a stall shows the effort clamp, not a wall
        _set_joint_limits(stage, joint_path, -2.0, 2.0)
        _reset_and_init(sim, art)
        dof_idx, names = _dof_index(art, "lift_joint")
        _set_target(art, dof_idx, target)
        tail_pos, tail_eff = [], []
        for step_i in range(args.settle_steps):
            sim.step(render=False)
            if step_i >= args.settle_steps - 60:
                tail_pos.append(_joint_position(art, dof_idx))
                tail_eff.append(abs(_measured_effort(art, dof_idx)))
        settled = tail_pos[-1] if tail_pos else _joint_position(art, dof_idx)
        eff = [e for e in tail_eff if e == e]  # drop NaN
        mean_eff = sum(eff) / len(eff) if eff else float("nan")
        held = abs(target - settled) < 0.05
        points.append({
            "max_force_N": mf,
            "max_force_vs_load": mf / load,
            "stored_max_force": stored["stored_max_force"],
            "load_force_N": load,
            "target_m": target,
            "settled_position_m": settled,
            "droop_mm": (target - settled) * 1000.0,
            "measured_effort_N": mean_eff,
            "held_target": held,
            "stalled_at_lower_limit": settled < -1.5,
            "dof_names": names,
        })
        sim.stop()
    result["effort_clamp"] = {
        "issue": 190,
        "predicted_droop_when_held_mm": (load / k) * 1000.0,
        "expectation": (
            "maxForce >= m*g holds (droop=m*g/k); maxForce < m*g cannot support "
            "the weight -> stalls at the lower joint limit; measured effort "
            "saturates at maxForce"
        ),
        "points": points,
    }


def _test_velocity_clamp(result, ctx, args):
    """#190b: peak joint velocity under a HIGH vs LOW maxJointVelocity."""
    stage, joint_path, _root, sim, art, _cls = ctx
    k = args.stiffness
    # sub-critical damping so the drive WOULD move fast -> the clamp binds
    damping = 0.2 * 2.0 * math.sqrt(k * args.mass)
    step_target = 1.0  # large travel from 0
    points = []
    for label, max_vel in (("high_limit", 1000.0), ("low_limit", 0.3)):
        _set_linear_drive(stage, joint_path, k, damping, step_target, 1.0e7)
        _set_joint_limits(stage, joint_path, -2.0, 2.0)
        stored_vlim = _set_max_joint_velocity(stage, joint_path, max_vel)
        _reset_and_init(sim, art)
        dof_idx, _names = _dof_index(art, "lift_joint")
        # start at 0, command the step, capture the transient velocity profile
        _set_target(art, dof_idx, 0.0)
        for _ in range(30):
            sim.step(render=False)
        _set_target(art, dof_idx, step_target)
        peak_vel = 0.0
        vels = []
        for _ in range(args.settle_steps):
            sim.step(render=False)
            v = abs(_joint_velocity(art, dof_idx))
            if v == v:
                peak_vel = max(peak_vel, v)
                vels.append(v)
        points.append({
            "label": label,
            "max_joint_velocity_limit": max_vel,
            "stored_max_joint_velocity": stored_vlim,
            "peak_measured_velocity": peak_vel,
            "clamped_near_limit": (
                label == "low_limit" and peak_vel <= max_vel * 1.5
            ),
        })
        sim.stop()
    hi = next(p for p in points if p["label"] == "high_limit")
    lo = next(p for p in points if p["label"] == "low_limit")
    result["velocity_clamp"] = {
        "issue": 190,
        "expectation": (
            "the low maxJointVelocity clamps the transient peak velocity well "
            "below the unclamped (high-limit) peak"
        ),
        "high_limit_peak_velocity": hi["peak_measured_velocity"],
        "low_limit_peak_velocity": lo["peak_measured_velocity"],
        "low_limit_setting": lo["max_joint_velocity_limit"],
        "clamp_confirmed": (
            lo["peak_measured_velocity"] < hi["peak_measured_velocity"]
            and lo["peak_measured_velocity"] <= lo["max_joint_velocity_limit"] * 1.5
        ),
        "points": points,
    }


def _test_position_limit(result, ctx, args):
    """#191: command past the upper joint limit -> stops at the limit."""
    stage, joint_path, _root, sim, art, _cls = ctx
    k = args.stiffness
    damping = 2.0 * math.sqrt(k * args.mass)
    upper = 0.5
    commanded = 2.0  # far beyond the upper limit
    _set_linear_drive(stage, joint_path, k, damping, commanded, 1.0e7)
    _set_max_joint_velocity(stage, joint_path, 1000.0)
    stored_lim = _set_joint_limits(stage, joint_path, -2.0, upper)
    _reset_and_init(sim, art)
    dof_idx, names = _dof_index(art, "lift_joint")
    _set_target(art, dof_idx, commanded)
    traj = []
    for _ in range(args.settle_steps):
        sim.step(render=False)
        traj.append(_joint_position(art, dof_idx))
    settled = traj[-1] if traj else _joint_position(art, dof_idx)
    peak = max(traj) if traj else settled
    result["position_limit"] = {
        "issue": 191,
        "upper_limit_m": upper,
        "stored_limits": {"lower": stored_lim[0], "upper": stored_lim[1]},
        "commanded_target_m": commanded,
        "settled_position_m": settled,
        "peak_position_m": peak,
        "overshoot_past_limit_mm": (peak - upper) * 1000.0,
        "settled_error_from_limit_mm": (settled - upper) * 1000.0,
        "clamped_at_limit": abs(settled - upper) < 0.05,
        "dof_names": names,
        "expectation": (
            "the joint stops AT the upper limit despite a target well beyond it; "
            "settled ~= upper_limit, bounded transient overshoot"
        ),
    }


def _test_solver_iterations(result, ctx, args):
    """#192: droop under load vs solverPositionIterationCount."""
    stage, joint_path, root_path, sim, art, _cls = ctx
    load = args.mass * GRAVITY
    # moderate stiffness so there is a measurable droop to resolve
    k = 5000.0
    damping = 2.0 * math.sqrt(k * args.mass)
    target = 0.5
    points = []
    for iters in (1, 4, 32):
        _set_linear_drive(stage, joint_path, k, damping, target, 1.0e7)
        _set_joint_limits(stage, joint_path, -2.0, 2.0)
        stored_iters = _set_solver_position_iterations(stage, root_path, iters)
        _reset_and_init(sim, art)
        dof_idx, _names = _dof_index(art, "lift_joint")
        _set_target(art, dof_idx, target)
        tail = []
        for step_i in range(args.settle_steps):
            sim.step(render=False)
            if step_i >= args.settle_steps - 60:
                tail.append(_joint_position(art, dof_idx))
        settled = tail[-1] if tail else _joint_position(art, dof_idx)
        drift_mm = (max(tail) - min(tail)) * 1000.0 if tail else float("nan")
        points.append({
            "solver_position_iterations": iters,
            "stored_iterations": stored_iters,
            "settled_position_m": settled,
            "droop_mm": (target - settled) * 1000.0,
            "drift_mm": drift_mm,
        })
        sim.stop()
    droops = [p["droop_mm"] for p in points]
    result["solver_iterations"] = {
        "issue": 192,
        "stiffness": k,
        "load_force_N": load,
        "predicted_droop_mm": (load / k) * 1000.0,
        "droop_spread_mm": max(droops) - min(droops),
        "sensitive_to_iterations": (max(droops) - min(droops)) > 0.5,
        "expectation": (
            "the implicit articulation drive is a PD position controller; its "
            "steady-state droop is m*g/k, largely independent of position-solver "
            "iterations (those resolve contacts/constraints, not the drive PD). "
            "Expect near-flat droop across iteration counts"
        ),
        "points": points,
    }


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})  # noqa: F841

    result = {
        "issue": "isaac#188",
        "isaac_variant": "6.0.1",
        "mass_kg": args.mass,
        "gravity": GRAVITY,
        "load_force_N": args.mass * GRAVITY,
        "stiffness_ref": args.stiffness,
        "physics_dt": args.dt,
        "settle_steps": args.settle_steps,
        "note_5_1_baseline": (
            "no numeric 5.1 baseline for #188 in the repo; the constraints are "
            "doc-confirmed (PhysX 5.4 Articulations + Isaac Sim joint-tuning) and "
            "the *pi/180 scaling is the #168 finding first hit on 5.1 / Isaac Lab "
            "2.3. This run re-confirms them empirically on 6.0.1 / Isaac Lab 3.0"
        ),
        "error": None,
    }
    try:
        # #190-#192 -- stepped tests on one persistent lift articulation FIRST,
        # while the sim state is clean. (The #189 readback below calls Isaac
        # Lab's modify_joint_drive_properties, which perturbs the sim/stage
        # singleton enough that a later SingleArticulation(root) construction
        # falls back to the unbound batched Articulation view -> its physics
        # view stays None. So do all stepped physics before touching isaaclab.)
        ctx = _build_lift(args)
        result["api"] = {
            "joint_path": ctx[1],
            "root_path": ctx[2],
            "articulation_cls": ctx[5],
        }
        _test_effort_clamp(result, ctx, args)
        Path(args.out).write_text(json.dumps(result, indent=2))
        _test_velocity_clamp(result, ctx, args)
        Path(args.out).write_text(json.dumps(result, indent=2))
        _test_position_limit(result, ctx, args)
        Path(args.out).write_text(json.dumps(result, indent=2))
        _test_solver_iterations(result, ctx, args)
        Path(args.out).write_text(json.dumps(result, indent=2))

        # #189 -- stage-only DriveAPI readback LAST (isaaclab modify path).
        _test_gain_scaling(result)
        Path(args.out).write_text(json.dumps(result, indent=2))

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
    p.add_argument("--mass", type=float, default=10.0, help="Payload kg.")
    p.add_argument(
        "--stiffness",
        type=float,
        default=1.0e5,
        help="Reference drive stiffness (N/m) for the stepped tests.",
    )
    p.add_argument(
        "--settle-steps", type=int, default=600, help="Sim steps per config."
    )
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
