#!/usr/bin/env python3
"""L2.5 / L3 sag-vs-stiffness sweep on Isaac Sim 6.0.1 (re-validate isaac#185).

Re-runs the ADR-0021 "L2.5 steady-state droop tracks load / stiffness"
experiment on Isaac Sim 6.0.1 / Isaac Lab 3.0, to check whether the numbers
recorded on Isaac Sim 5.1 / Isaac Lab 2.3 (EXP-184) still hold. The ADR-0021
baseline (10 kg payload): droop = 19.4 mm @ k=5000, 0.79 mm @ k=1e5,
18 um @ k=1e6, with the linear prediction droop ~= m*g / stiffness.

Physical setup -- WHY a PRISMATIC lift, not the revolute test fixture
--------------------------------------------------------------------
ADR-0021 D1b frames L2/L2.5/L3 as a JOINT POSITION-control vocabulary whose
canonical case is "a forklift mast / fork told go to this height" -- i.e. a
VERTICAL PRISMATIC lift. And the ADR's own prediction is stated as a LINEAR
relation, droop = m*g / stiffness in meters:  98.1 N / 5000 (N/m) = 19.6 mm,
matching the recorded 19.4 mm. That relation is only dimensionally consistent
for a prismatic (linear, N/m) drive holding a mass against gravity. The repo's
two_link_revolute.urdf fixture has its revolute axis along +Z (vertical), so
gravity (also -Z) produces ZERO torque about that axis -> no sag at all; it
cannot reproduce the baseline. So this driver builds a minimal single-DOF
PRISMATIC lift (fixed base + one 10 kg moving link, joint axis +Z) -- the
faithful reproduction of the ADR's forklift-mast case and its m*g/k prediction.

The URDF is authored INLINE (written to /tmp at runtime) so this one committed
file is self-contained, and imported through the migrated framework pipeline
(``isaac_devkit.model_import._convert_urdf`` -- the same URDF->USD converter the
#168 joint-drive integration test exercises on 6.0.1). The joint drive is then
set DIRECTLY on the prismatic joint's ``UsdPhysics.DriveAPI("linear")`` (a USD
physics schema, settable in pure Python per ADR-0021 D4). A LINEAR drive takes
NO pi/180 conversion (that scaling is angular-only, #168), so stiffness is
plain N/m and the m*g/k prediction is exact.

Per stiffness k the driver: writes k + critical damping (2*sqrt(k*m)) + a fixed
target height onto the DriveAPI, ``SimulationContext.reset()`` (re-parses the
USD so PhysX picks up the new gains), steps until the DOF settles, and measures
the steady-state droop = target - settled_joint_position. Sweep default
{5000, 1e4, 1e5, 5e5, 1e6} covers the three ADR points plus two easy extras.

Results are written as JSON to ``--out`` (a MOUNTED path, so the host reads it
back) -- stdout through the docker run.sh wrapper is not reliably captured, so
the file is the source of truth. Runs headless in the 6.0.1 devel-test
container via ``/isaac-sim/python.sh``. Teardown is an explicit ``os._exit(0)``
(isaac#248 round 9): under 6.0.1 a cold headless container's Omniverse Hub
connector cannot launch and carb's reconnect task aborts SimulationApp.close()
with a busy-TaskGroup SIGABRT; os._exit reaches the same clean exit while
skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_l25_sag_sweep.py \\
        --out /home/<user>/work/worktree/<wt>/test/.sag-sweep.json \\
        [--mass 10.0] [--target 0.3] [--settle-steps 600] \\
        [--stiffness 5000 1e4 1e5 5e5 1e6]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

# Minimal single-DOF prismatic lift. base_link is fixed to the world
# (fix_base=True at conversion); lift_link is the loaded mass, free to slide
# along +Z under a prismatic drive. High effort limit so the drive never
# saturates at the target (ADR-0021 A3: an effort clamp would masquerade as
# extra droop). MASS is templated in per run.
_URDF_TEMPLATE = """<?xml version="1.0"?>
<robot name="prismatic_lift">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
  <link name="lift_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="{mass}"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
  <joint name="lift_joint" type="prismatic">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="base_link"/>
    <child link="lift_link"/>
    <axis xyz="0 0 1"/>
    <limit lower="-1.0" upper="1.0" effort="100000.0" velocity="10.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
</robot>
"""

GRAVITY = 9.81


def _find_prismatic_joint(stage):
    """Path of the first prismatic joint prim (or a Prismatic-typed prim)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.PrismaticJoint):
            return str(prim.GetPath())
    for prim in stage.Traverse():
        if "Prismatic" in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _find_articulation_root(stage):
    """Path of the prim carrying ArticulationRootAPI (or None)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            return str(prim.GetPath())
    return None


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


def _joint_position(art, dof_idx):
    """Scalar joint position for dof_idx from a get_joint_positions() call."""
    import numpy as np

    pos = art.get_joint_positions()
    arr = np.asarray(pos).reshape(-1)
    return float(arr[dof_idx])


def run_sweep(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "isaac_variant": "6.0.1",
        "mass_kg": args.mass,
        "gravity": GRAVITY,
        "load_force_N": args.mass * GRAVITY,
        "target_m": args.target,
        "settle_steps": args.settle_steps,
        "physics_dt": args.dt,
        "points": [],
        "api": {},
        "error": None,
    }
    try:
        from isaacsim.core.api import SimulationContext
        from pxr import Usd, UsdPhysics  # noqa: F401

        from isaac_devkit import model_import

        # 1. Author the prismatic-lift URDF and convert to USD (migrated
        #    pipeline). No import-time joint_drive -- the linear drive is set
        #    per-k below directly on the joint's DriveAPI.
        urdf_path = Path("/tmp/prismatic_lift.urdf")
        urdf_path.write_text(_URDF_TEMPLATE.format(mass=args.mass))
        out_usd = Path("/tmp/prismatic_lift.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
        )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        import omni.usd

        omni.usd.get_context().open_stage(str(produced))
        stage = omni.usd.get_context().get_stage()

        joint_path = _find_prismatic_joint(stage)
        if joint_path is None:
            raise RuntimeError("no prismatic joint in produced USD")
        root_path = _find_articulation_root(stage) or joint_path
        result["api"]["joint_path"] = joint_path
        result["api"]["root_path"] = root_path

        # 2. Physics context (default gravity -Z at 1.0 m/unit). Build the
        #    articulation view once; re-initialize it after every reset().
        sim = SimulationContext(
            stage_units_in_meters=1.0,
            physics_dt=args.dt,
            rendering_dt=args.dt,
        )
        art, art_cls = _make_articulation(root_path)
        result["api"]["articulation_cls"] = art_cls

        for k in args.stiffness:
            damping = 2.0 * math.sqrt(k * args.mass)  # critical (linear)
            stored = _set_linear_drive(
                stage, joint_path, k, damping, args.target
            )
            # Re-parse the USD (new gains) into a fresh PhysX view.
            sim.reset()
            try:
                art.initialize()
            except Exception:  # noqa: BLE001
                pass  # some API versions bind lazily / in reset()

            # find the lift DOF index once we have dof names
            dof_idx = 0
            try:
                names = list(art.dof_names)
                if "lift_joint" in names:
                    dof_idx = names.index("lift_joint")
            except Exception:  # noqa: BLE001
                names = None

            tail = []
            for step_i in range(args.settle_steps):
                sim.step(render=False)
                if step_i >= args.settle_steps - 60:
                    tail.append(_joint_position(art, dof_idx))

            settled = tail[-1] if tail else _joint_position(art, dof_idx)
            drift_mm = (max(tail) - min(tail)) * 1000.0 if tail else float("nan")
            droop_mm = (args.target - settled) * 1000.0
            pred_mm = (args.mass * GRAVITY / k) * 1000.0
            point = {
                "stiffness": k,
                "damping_critical": damping,
                "stored_stiffness": stored[0],
                "stored_target": stored[2],
                "dof_names": names,
                "dof_index": dof_idx,
                "settled_position_m": settled,
                "droop_mm": droop_mm,
                "predicted_mm": pred_mm,
                "drift_mm": drift_mm,
            }
            result["points"].append(point)
            # Incremental write so a later crash still leaves earlier points.
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
        os._exit(0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument("--mass", type=float, default=10.0, help="Payload kg.")
    p.add_argument("--target", type=float, default=0.3, help="Target lift m.")
    p.add_argument(
        "--settle-steps", type=int, default=600, help="Sim steps per k."
    )
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument(
        "--stiffness",
        type=float,
        nargs="+",
        default=[5000.0, 1e4, 1e5, 5e5, 1e6],
        help="Stiffness values to sweep (N/m).",
    )
    return p.parse_args()


if __name__ == "__main__":
    run_sweep(_parse_args())
