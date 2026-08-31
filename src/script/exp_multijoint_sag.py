#!/usr/bin/env python3
"""Multi-joint coupling on Isaac Sim 6.0.1 -- sag accumulation + cross-joint
disturbance in a serial position-drive chain (re-validate isaac#226).

The single-DOF experiments (EXP-184 sag, #180 tracking, #193 hold, and their
6.0.1 re-vals ``exp_l25_sag_sweep.py`` / ``exp_drive_precision_load.py`` /
``exp_traj_tracking.py``) each drive ONE joint / one body. Two properties of
the PhysX reduced-coordinate articulation solver only show up with N>=2 joints
in series, and this driver measures both on Isaac Sim 6.0.1:

1. **Sag accumulation down the chain.** In a serial chain of N position-driven
   joints, the base joint carries the weight of EVERY link above it, so it sags
   most; each child link inherits its parents' sag on top of its own. Question:
   does the tip's total steady-state error equal the SUM of per-joint sags
   (errors compound linearly), or does the implicit solver couple them
   differently? We compare the measured cumulative tip error against the
   single-joint ``mg/k`` prediction summed over the chain, where joint j's
   supported mass is the sum of masses of links j..N-1.

2. **Cross-joint dynamic disturbance.** After the chain settles, we STEP the
   base joint's target (joint 0) while the child joints (1, 2) are commanded to
   HOLD. Question: do the held joints deviate during joint 0's transient
   (inertial / reaction coupling through the shared multibody), and do they
   settle back? We record each held joint's peak transient deviation and its
   residual steady-state error relative to its pre-step resting position.

Physical setup -- a VERTICAL PRISMATIC serial stack
---------------------------------------------------
Same rationale as ``exp_l25_sag_sweep.py``: ADR-0021 D1b frames L2/L2.5/L3 as a
JOINT POSITION-control vocabulary whose canonical case is a forklift mast/fork
told "go to this height" -- a vertical prismatic lift -- and states the
prediction as the LINEAR relation ``droop = load / stiffness`` (N/m, meters),
only dimensionally consistent for a prismatic drive. A revolute chain with axes
along +Z would feel ZERO gravity torque (gravity is -Z) and produce no sag; a
horizontal-axis revolute chain would make each joint's supported torque depend
on the (changing) lever arm as parents sag, muddying the clean sum-of-mg/k
comparison. A vertical prismatic stack keeps each joint's supported load a pure
weight (sum of masses above), so the accumulation hypothesis is a clean linear
sum. A linear drive takes NO ``pi/180`` conversion (that scaling is
angular-only, #168), so stiffness is plain N/m and the ``mg/k`` prediction is
exact.

The chain is ``base_link`` (fixed to world) -> joint_0 -> link_0 -> joint_1 ->
link_1 -> joint_2 -> link_2, every joint prismatic along +Z with an independent
position drive. joint_0 supports (m0+m1+m2)*g, joint_1 supports (m1+m2)*g,
joint_2 supports m2*g. The URDF is authored INLINE (written to /tmp at runtime)
so this one committed file is self-contained, and imported through the migrated
framework pipeline (``isaac_devkit.model_import._convert_urdf`` -- the same
URDF->USD converter the #168 joint-drive integration test exercises on 6.0.1).
The per-joint linear drive is set directly on each prismatic joint's
``UsdPhysics.DriveAPI("linear")`` (a USD physics schema, settable in pure
Python per ADR-0021 D4).

Results are written as JSON to ``--out`` (a MOUNTED path, so the host reads it
back) -- stdout through the docker run wrapper is not reliably captured, so the
file is the source of truth. Teardown is an explicit ``os._exit(0)``
(isaac#248 round 9): under 6.0.1 a cold headless container's Omniverse Hub
connector cannot launch and carb's reconnect task aborts SimulationApp.close()
with a busy-TaskGroup SIGABRT; os._exit reaches the same clean exit while
skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_multijoint_sag.py \\
        --out /home/<user>/work/worktree/<wt>/test/.multijoint-sag.json \\
        [--masses 1.0 1.0 1.0] [--stiffness 5000] [--target 0.1] \\
        [--step-delta 0.1] [--settle-steps 800] [--coupling-steps 800]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

# Serial vertical prismatic stack. base_link is fixed to the world
# (fix_base=True at conversion). Each link_i is a moving mass free to slide
# along +Z relative to its parent under an independent prismatic drive. High
# effort limit so no drive saturates at its target (ADR-0021 A3: an effort
# clamp would masquerade as extra droop). Masses are templated in per run.
_LINK_TEMPLATE = """  <link name="link_{i}">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="{mass}"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
"""

_JOINT_TEMPLATE = """  <joint name="joint_{i}" type="prismatic">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="{parent}"/>
    <child link="link_{i}"/>
    <axis xyz="0 0 1"/>
    <limit lower="-1.0" upper="2.0" effort="100000.0" velocity="10.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
"""

GRAVITY = 9.81


def _build_urdf(masses):
    """Author a serial vertical prismatic chain URDF for the given masses."""
    parts = [
        '<?xml version="1.0"?>',
        '<robot name="multi_joint_chain">',
        '  <link name="base_link">',
        '    <inertial>',
        '      <origin xyz="0 0 0" rpy="0 0 0"/>',
        '      <mass value="1.0"/>',
        '      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0"'
        ' izz="0.01"/>',
        '    </inertial>',
        '    <visual>',
        '      <geometry><box size="0.1 0.1 0.1"/></geometry>',
        '    </visual>',
        '  </link>',
    ]
    for i, mass in enumerate(masses):
        parts.append(_LINK_TEMPLATE.format(i=i, mass=mass))
        parent = "base_link" if i == 0 else f"link_{i - 1}"
        parts.append(_JOINT_TEMPLATE.format(i=i, parent=parent))
    parts.append("</robot>")
    return "\n".join(parts)


def _find_prismatic_joints(stage):
    """Ordered list of prismatic joint prim paths on the stage."""
    from pxr import UsdPhysics

    paths = []
    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.PrismaticJoint):
            paths.append(str(prim.GetPath()))
    if not paths:
        for prim in stage.Traverse():
            if "Prismatic" in str(prim.GetTypeName()):
                paths.append(str(prim.GetPath()))
    return paths


def _find_articulation_root(stage):
    """Path of the prim carrying ArticulationRootAPI (or None)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            return str(prim.GetPath())
    return None


def _joint_name(joint_path):
    """Trailing prim name (== URDF joint name) from a joint prim path."""
    return joint_path.rsplit("/", 1)[-1]


def _set_linear_drive(stage, joint_path, stiffness, damping, target):
    """Author a linear (prismatic) DriveAPI with the given gains + target.

    Prismatic drive: stiffness is plain N/m and target is meters -- NO pi/180
    (that conversion is angular-only). Returns the read-back (stiffness,
    damping, target) so the caller can confirm what PhysX will parse.
    """
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "linear")
    if not drive:
        drive = UsdPhysics.DriveAPI.Apply(prim, "linear")
    drive.CreateTypeAttr().Set("force")
    drive.CreateStiffnessAttr().Set(float(stiffness))
    drive.CreateDampingAttr().Set(float(damping))
    drive.CreateTargetPositionAttr().Set(float(target))
    # Do not clamp the drive force -- keep the effort headroom the URDF gave.
    drive.CreateMaxForceAttr().Set(float("inf"))
    return (
        drive.GetStiffnessAttr().Get(),
        drive.GetDampingAttr().Get(),
        drive.GetTargetPositionAttr().Get(),
    )


def _set_drive_target(stage, joint_path, target):
    """Update only the DriveAPI target of an already-authored linear drive."""
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "linear")
    drive.CreateTargetPositionAttr().Set(float(target))
    return drive.GetTargetPositionAttr().Get()


def _make_articulation(root_path):
    """Best-effort articulation view over root_path across 6.0.x API names."""
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


def _joint_positions(art):
    """Full joint-position vector as a flat python list."""
    import numpy as np

    pos = art.get_joint_positions()
    return [float(x) for x in np.asarray(pos).reshape(-1)]


def run_experiment(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    masses = list(args.masses)
    n = len(masses)
    # Per-joint supported mass = sum of masses of this link and every link
    # above it in the chain (joint j carries links j..n-1).
    supported = [sum(masses[j:]) for j in range(n)]

    result = {
        "isaac_variant": "6.0.1",
        "experiment": "multi_joint_coupling",
        "masses_kg": masses,
        "num_joints": n,
        "gravity": GRAVITY,
        "supported_mass_kg": supported,
        "stiffness": args.stiffness,
        "target_m": args.target,
        "step_delta_m": args.step_delta,
        "settle_steps": args.settle_steps,
        "coupling_steps": args.coupling_steps,
        "physics_dt": args.dt,
        "api": {},
        "chain": None,
        "coupling": None,
        "error": None,
    }
    try:
        from isaacsim.core.api import SimulationContext
        from pxr import Usd, UsdPhysics  # noqa: F401

        from isaac_devkit import model_import

        # 1. Author the serial-chain URDF and convert to USD (migrated
        #    pipeline). No import-time joint_drive -- each linear drive is set
        #    explicitly below directly on its joint's DriveAPI.
        urdf_path = Path("/tmp/multi_joint_chain.urdf")
        urdf_path.write_text(_build_urdf(masses))
        out_usd = Path("/tmp/multi_joint_chain.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
        )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        import omni.usd

        omni.usd.get_context().open_stage(str(produced))
        stage = omni.usd.get_context().get_stage()

        joint_paths = _find_prismatic_joints(stage)
        if len(joint_paths) != n:
            raise RuntimeError(
                f"expected {n} prismatic joints, found {len(joint_paths)}: "
                f"{joint_paths}"
            )
        # Map URDF joint name -> stage prim path.
        path_by_name = {_joint_name(p): p for p in joint_paths}
        ordered_paths = [path_by_name[f"joint_{i}"] for i in range(n)]
        root_path = _find_articulation_root(stage) or ordered_paths[0]
        result["api"]["joint_paths"] = ordered_paths
        result["api"]["root_path"] = root_path

        # 2. Physics context (default gravity -Z at 1.0 m/unit).
        sim = SimulationContext(
            stage_units_in_meters=1.0,
            physics_dt=args.dt,
            rendering_dt=args.dt,
        )

        # Author all per-joint linear drives at critical damping, all pointing
        # at the same target extension. Critical damping per joint uses that
        # joint's OWN supported mass so each converges cleanly.
        k = float(args.stiffness)
        for j, jp in enumerate(ordered_paths):
            damping = 2.0 * math.sqrt(k * supported[j])
            _set_linear_drive(stage, jp, k, damping, args.target)

        art, art_cls = _make_articulation(root_path)
        result["api"]["articulation_cls"] = art_cls

        sim.reset()
        try:
            art.initialize()
        except Exception:  # noqa: BLE001
            pass  # some API versions bind lazily / in reset()

        # DOF-name -> index map (get_joint_positions follows dof order).
        dof_names = None
        try:
            dof_names = list(art.dof_names)
        except Exception:  # noqa: BLE001
            dof_names = None
        result["api"]["dof_names"] = dof_names
        if dof_names and all(f"joint_{i}" in dof_names for i in range(n)):
            dof_index = [dof_names.index(f"joint_{i}") for i in range(n)]
        else:
            dof_index = list(range(n))  # fall back to authoring order
        result["api"]["dof_index"] = dof_index

        # -- Phase (a): sag accumulation --------------------------------------
        tail = []
        for step_i in range(args.settle_steps):
            sim.step(render=False)
            if step_i >= args.settle_steps - 60:
                tail.append(_joint_positions(art))

        settled_vec = tail[-1] if tail else _joint_positions(art)
        per_joint = []
        cumulative_sag_mm = 0.0
        cumulative_pred_mm = 0.0
        for i in range(n):
            idx = dof_index[i]
            settled = settled_vec[idx]
            sag_mm = (args.target - settled) * 1000.0
            pred_mm = (supported[i] * GRAVITY / k) * 1000.0
            drift_mm = (
                (max(t[idx] for t in tail) - min(t[idx] for t in tail))
                * 1000.0
                if tail
                else float("nan")
            )
            cumulative_sag_mm += sag_mm
            cumulative_pred_mm += pred_mm
            per_joint.append(
                {
                    "joint": f"joint_{i}",
                    "supported_mass_kg": supported[i],
                    "settled_position_m": settled,
                    "sag_mm": sag_mm,
                    "predicted_mm": pred_mm,
                    "drift_mm": drift_mm,
                }
            )
        result["chain"] = {
            "per_joint": per_joint,
            "cumulative_tip_error_mm": cumulative_sag_mm,
            "sum_of_predicted_mm": cumulative_pred_mm,
            "accumulation_ratio": (
                cumulative_sag_mm / cumulative_pred_mm
                if cumulative_pred_mm
                else float("nan")
            ),
        }
        Path(args.out).write_text(json.dumps(result, indent=2))

        # -- Phase (b): cross-joint disturbance -------------------------------
        # Record the pre-step resting positions (held reference) for the child
        # joints, then STEP joint_0's target by +step_delta while joints 1..n-1
        # keep their targets. Track each held joint's peak deviation from its
        # resting position and its residual after re-settling.
        held_ref = {i: settled_vec[dof_index[i]] for i in range(1, n)}
        moved_ref = settled_vec[dof_index[0]]
        new_target0 = args.target + args.step_delta
        _set_drive_target(stage, ordered_paths[0], new_target0)

        peak_dev = {i: 0.0 for i in range(1, n)}
        peak_step = {i: -1 for i in range(1, n)}
        coup_tail = []
        for step_i in range(args.coupling_steps):
            sim.step(render=False)
            vec = _joint_positions(art)
            for i in range(1, n):
                dev = abs(vec[dof_index[i]] - held_ref[i])
                if dev > peak_dev[i]:
                    peak_dev[i] = dev
                    peak_step[i] = step_i
            if step_i >= args.coupling_steps - 60:
                coup_tail.append(vec)

        final_vec = coup_tail[-1] if coup_tail else _joint_positions(art)
        held = []
        for i in range(1, n):
            residual_mm = abs(final_vec[dof_index[i]] - held_ref[i]) * 1000.0
            held.append(
                {
                    "joint": f"joint_{i}",
                    "held_target_m": args.target,
                    "resting_position_m": held_ref[i],
                    "peak_transient_deviation_mm": peak_dev[i] * 1000.0,
                    "peak_at_step": peak_step[i],
                    "residual_deviation_mm": residual_mm,
                }
            )
        moved_final = final_vec[dof_index[0]]
        result["coupling"] = {
            "moved_joint": "joint_0",
            "moved_from_m": moved_ref,
            "moved_target_m": new_target0,
            "moved_settled_m": moved_final,
            "moved_reached_mm_short": (new_target0 - moved_final) * 1000.0,
            "held_joints": held,
            "max_peak_transient_deviation_mm": (
                max(h["peak_transient_deviation_mm"] for h in held)
                if held
                else float("nan")
            ),
            "max_residual_deviation_mm": (
                max(h["residual_deviation_mm"] for h in held)
                if held
                else float("nan")
            ),
        }
        Path(args.out).write_text(json.dumps(result, indent=2))
        sim.stop()

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
        os._exit(0 if result["error"] is None else 1)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument(
        "--masses",
        type=float,
        nargs="+",
        default=[1.0, 1.0, 1.0],
        help="Per-link masses (kg), base->tip. Length = chain length.",
    )
    p.add_argument(
        "--stiffness",
        type=float,
        default=5000.0,
        help="Per-joint drive stiffness (N/m), shared across the chain.",
    )
    p.add_argument(
        "--target", type=float, default=0.1, help="Per-joint target extension m."
    )
    p.add_argument(
        "--step-delta",
        type=float,
        default=0.1,
        help="Step added to joint_0 target in the coupling phase (m).",
    )
    p.add_argument(
        "--settle-steps", type=int, default=800, help="Steps for phase (a)."
    )
    p.add_argument(
        "--coupling-steps", type=int, default=800, help="Steps for phase (b)."
    )
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run_experiment(_parse_args())
