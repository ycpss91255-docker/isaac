#!/usr/bin/env python3
"""L3 / L2.5 drive precision under EXTERNAL CONTACT load on Isaac Sim 6.0.1.

Re-validates isaac#184 -- the *parent* of the pure-sag issue #185. Where #185
(``exp_l25_sag_sweep.py``) baked the payload into the moving link's own
inertial mass (droop from the link's own weight), #184 is broader: an
L3-driven joint holding position against an **external load / contact** -- a
SEPARATE dynamic rigid body resting on the lift platform, whose weight reaches
the joint only through a **contact force** between two colliding models. This
is the "interactive" (with-another-model) case ADR-0021's Verification section
splits out from the isolated single-control sag.

What this measures
------------------
A minimal single-DOF PRISMATIC lift (fixed base + one light platform link,
joint axis +Z) holds a commanded target height. A free dynamic **payload
cuboid** is authored on the same stage, resting on the platform's collider, so
its weight is transmitted to the drive by CONTACT, not by inertial mass. For
each drive stiffness the driver commands the target, lets the coupled system
settle, and records the steady-state position error

    error = target - settled_joint_position

under that contact load, for a high-stiffness (**L2.5**) and a low-stiffness
(**L3**) config. ADR-0021 D1a predicts a linear steady-state droop
``error ~= supported_load / stiffness`` where the supported load is the TOTAL
weight the joint carries = (platform_link + payload) * g. The contact case must
reproduce the same linear law as #185's baked-in case -- confirming the drive's
precision under an external contact load equals its precision under an
equivalent inertial load. It also quantifies the L2.5-vs-L3 error ratio (the
key requirements question: is the high-stiffness droop within tolerance, or is
true-L2 needed?).

The error MAGNITUDE is itself the contact witness: if the payload were not in
contact (fell through / off the platform), the joint would carry only the tiny
0.1 kg platform link and the error would collapse to ~sub-mm even at low k;
seeing the ~(link+payload) droop confirms the contact force is being carried.
``drift_mm`` (tail peak-to-peak) confirms the contact is a STEADY rest, not a
bounce. A best-effort payload world-Z read is also recorded when the rigid-prim
view is available.

Why a PRISMATIC lift (same rationale as #185 / exp_l25_sag_sweep.py)
-------------------------------------------------------------------
ADR-0021 D1b frames L2/L2.5/L3 as a JOINT POSITION-control vocabulary whose
canonical case is a forklift mast/fork told "go to this height" -- a vertical
prismatic lift -- and states the prediction as the LINEAR relation
``droop = load / stiffness`` (N/m, meters), only dimensionally consistent for a
prismatic drive. A linear drive takes NO ``pi/180`` conversion (angular-only,
#168), so stiffness is plain N/m and the prediction is exact.

The URDF is authored INLINE (written to /tmp at runtime) so this one committed
file is self-contained, and imported through the migrated framework pipeline
(``isaac_devkit.model_import._convert_urdf`` -- the same URDF->USD converter the
#168 joint-drive integration test exercises on 6.0.1). Both links carry
``<collision>`` boxes so the platform can carry the payload; the converter
authors convexHull colliders (a box hull is the box). The linear drive is set
directly on the prismatic joint's ``UsdPhysics.DriveAPI("linear")`` (a USD
physics schema, settable in pure Python per ADR-0021 D4).

Results are written as JSON to ``--out`` (a MOUNTED path, so the host reads it
back) -- stdout through the docker wrapper is not reliably captured, so the
file is the source of truth. Teardown is an explicit ``os._exit(0)`` (isaac#248
round 9): under 6.0.1 a cold headless container's Omniverse Hub connector
cannot launch and carb's reconnect task aborts SimulationApp.close() with a
busy-TaskGroup SIGABRT; os._exit reaches the same clean exit while skipping
that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_drive_precision_load.py \\
        --out /home/<user>/work/worktree/<wt>/test/.drive-precision-load.json \\
        [--payload-mass 10.0] [--link-mass 0.1] [--target 0.3] \\
        [--settle-steps 1000] [--stiffness 1e5 5e3]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

# Minimal single-DOF prismatic lift. base_link is fixed to the world
# (fix_base=True at conversion); lift_link is a LIGHT platform (default 0.1 kg)
# free to slide along +Z under a prismatic drive. Both links carry <collision>
# so the platform can physically support the external payload cuboid dropped on
# top. High effort limit so the drive never saturates at the target (ADR-0021
# A3: an effort clamp would masquerade as extra droop). Link mass is templated.
_URDF_TEMPLATE = """<?xml version="1.0"?>
<robot name="prismatic_lift_contact">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
    <collision>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </collision>
  </link>
  <link name="lift_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="{link_mass}"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <geometry><box size="0.4 0.4 0.04"/></geometry>
    </visual>
    <collision>
      <geometry><box size="0.4 0.4 0.04"/></geometry>
    </collision>
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

# Geometry constants (meters) matching the URDF above, used to place the
# payload resting on the platform top when the joint is at the target height.
_JOINT_ORIGIN_Z = 0.2      # <joint><origin xyz="0 0 0.2">
_PLATFORM_HALF_THICK = 0.02  # half of the 0.04 platform box
_PAYLOAD_SIZE = 0.2        # payload cube edge length
_PAYLOAD_REST_GAP = 0.002  # tiny gap so it settles into contact, not interpenetrating


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


def _add_dynamic_payload(stage, path, size, mass, center_z):
    """Author a free DYNAMIC cube (payload) resting above the platform.

    A UsdGeom.Cube with a RigidBodyAPI + CollisionAPI + MassAPI, translated to
    ``center_z`` on the +Z axis. It is NOT part of the articulation -- a
    separate model that loads the lift joint purely through contact. Returns the
    prim path.
    """
    from pxr import Gf, UsdGeom, UsdPhysics

    cube = UsdGeom.Cube.Define(stage, path)
    cube.CreateSizeAttr(float(size))
    UsdGeom.Xformable(cube).AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, center_z))
    prim = cube.GetPrim()
    UsdPhysics.CollisionAPI.Apply(prim)
    UsdPhysics.RigidBodyAPI.Apply(prim)
    mass_api = UsdPhysics.MassAPI.Apply(prim)
    mass_api.CreateMassAttr(float(mass))
    return path


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


def _make_rigid_view(path):
    """Best-effort single-rigid-body view over path (for payload pose), or None."""
    import isaacsim.core.prims as prims

    for cls_name in ("SingleRigidPrim", "RigidPrim"):
        cls = getattr(prims, cls_name, None)
        if cls is None:
            continue
        try:
            return cls(path)
        except Exception:  # noqa: BLE001
            continue
    return None


def _joint_position(art, dof_idx):
    """Scalar joint position for dof_idx from a get_joint_positions() call."""
    import numpy as np

    pos = art.get_joint_positions()
    arr = np.asarray(pos).reshape(-1)
    return float(arr[dof_idx])


def _payload_z(view):
    """Best-effort world Z of the payload rigid body, or NaN."""
    import numpy as np

    if view is None:
        return float("nan")
    try:
        pos, _ = view.get_world_poses()
        return float(np.asarray(pos).reshape(-1)[2])
    except Exception:  # noqa: BLE001
        try:
            pos, _ = view.get_world_pose()
            return float(np.asarray(pos).reshape(-1)[2])
        except Exception:  # noqa: BLE001
            return float("nan")


def _try_set_target_position(art, dof_idx, target):
    """Best-effort: place the joint AT the target before settling.

    Starting the platform already at the commanded height keeps the payload
    (authored resting on the platform-at-target) in immediate light contact,
    instead of the drive slamming the platform up into it from z=0. Silently
    ignored if the API is unavailable.
    """
    import numpy as np

    try:
        n = len(list(art.dof_names))
    except Exception:  # noqa: BLE001
        n = dof_idx + 1
    q = np.zeros(n, dtype=float)
    q[dof_idx] = target
    for meth in ("set_joint_positions", "set_joint_position_targets"):
        fn = getattr(art, meth, None)
        if fn is None:
            continue
        try:
            fn(q)
            return meth
        except Exception:  # noqa: BLE001
            continue
    return None


def run_experiment(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    # Payload rests on the platform top when the joint is at the target height:
    #   platform_top = joint_origin_z + target + platform_half_thick
    #   payload_center = platform_top + payload_half + gap
    payload_center_z = (
        _JOINT_ORIGIN_Z
        + args.target
        + _PLATFORM_HALF_THICK
        + 0.5 * _PAYLOAD_SIZE
        + _PAYLOAD_REST_GAP
    )
    supported_mass = args.link_mass + args.payload_mass

    result = {
        "isaac_variant": "6.0.1",
        "experiment": "drive_precision_under_external_contact_load",
        "issue": 184,
        "link_mass_kg": args.link_mass,
        "payload_mass_kg": args.payload_mass,
        "supported_mass_kg": supported_mass,
        "gravity": GRAVITY,
        "contact_load_force_N": args.payload_mass * GRAVITY,
        "supported_load_force_N": supported_mass * GRAVITY,
        "target_m": args.target,
        "payload_center_z_authored_m": payload_center_z,
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

        # 1. Author the prismatic-lift URDF (with colliders) and convert to USD.
        urdf_path = Path("/tmp/prismatic_lift_contact.urdf")
        urdf_path.write_text(_URDF_TEMPLATE.format(link_mass=args.link_mass))
        out_usd = Path("/tmp/prismatic_lift_contact.usd")
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

        # 2. Author the external payload cuboid resting on the platform. This is
        #    the #184 distinction from #185: the load reaches the joint through
        #    a contact between two separate models, not baked inertial mass.
        payload_path = _add_dynamic_payload(
            stage, "/payload", _PAYLOAD_SIZE, args.payload_mass, payload_center_z
        )
        result["api"]["payload_path"] = payload_path

        # 3. Physics context (default gravity -Z at 1.0 m/unit).
        sim = SimulationContext(
            stage_units_in_meters=1.0,
            physics_dt=args.dt,
            rendering_dt=args.dt,
        )
        art, art_cls = _make_articulation(root_path)
        result["api"]["articulation_cls"] = art_cls
        payload_view = _make_rigid_view(payload_path)

        for k in args.stiffness:
            damping = 2.0 * math.sqrt(k * supported_mass)  # critical (linear)
            stored = _set_linear_drive(
                stage, joint_path, k, damping, args.target
            )
            # Re-parse the USD (new gains) into a fresh PhysX view.
            sim.reset()
            try:
                art.initialize()
            except Exception:  # noqa: BLE001
                pass  # some API versions bind lazily / in reset()
            if payload_view is not None:
                try:
                    payload_view.initialize()
                except Exception:  # noqa: BLE001
                    pass

            # find the lift DOF index once we have dof names
            dof_idx = 0
            try:
                names = list(art.dof_names)
                if "lift_joint" in names:
                    dof_idx = names.index("lift_joint")
            except Exception:  # noqa: BLE001
                names = None

            set_meth = _try_set_target_position(art, dof_idx, args.target)

            tail = []
            for step_i in range(args.settle_steps):
                sim.step(render=False)
                if step_i >= args.settle_steps - 60:
                    tail.append(_joint_position(art, dof_idx))

            settled = tail[-1] if tail else _joint_position(art, dof_idx)
            drift_mm = (max(tail) - min(tail)) * 1000.0 if tail else float("nan")
            error_mm = (args.target - settled) * 1000.0
            pred_mm = (supported_mass * GRAVITY / k) * 1000.0
            payload_z = _payload_z(payload_view)
            # Expected payload rest Z once the platform has settled to the
            # (drooped) height: platform_top(settled) + payload_half.
            platform_top_settled = _JOINT_ORIGIN_Z + settled + _PLATFORM_HALF_THICK
            payload_rest_expected = platform_top_settled + 0.5 * _PAYLOAD_SIZE
            payload_gap_mm = (
                (payload_z - payload_rest_expected) * 1000.0
                if payload_z == payload_z  # not NaN
                else float("nan")
            )
            label = "L2.5" if k >= 5e4 else "L3"
            point = {
                "label": label,
                "stiffness": k,
                "damping_critical": damping,
                "stored_stiffness": stored[0],
                "stored_target": stored[2],
                "dof_names": names,
                "dof_index": dof_idx,
                "set_target_method": set_meth,
                "settled_position_m": settled,
                "error_mm": error_mm,
                "predicted_mm": pred_mm,
                "drift_mm": drift_mm,
                "payload_z_m": payload_z,
                "payload_rest_expected_m": payload_rest_expected,
                "payload_gap_mm": payload_gap_mm,
            }
            result["points"].append(point)
            # Incremental write so a later crash still leaves earlier points.
            Path(args.out).write_text(json.dumps(result, indent=2))
            sim.stop()

        # Derived L2.5-vs-L3 comparison (contact-load droop ratio).
        by_label = {p["label"]: p for p in result["points"]}
        if "L2.5" in by_label and "L3" in by_label:
            e_l25 = by_label["L2.5"]["error_mm"]
            e_l3 = by_label["L3"]["error_mm"]
            result["comparison"] = {
                "l25_error_mm": e_l25,
                "l3_error_mm": e_l3,
                "l3_over_l25_ratio": (e_l3 / e_l25) if e_l25 else float("inf"),
                "stiffness_ratio": (
                    by_label["L2.5"]["stiffness"] / by_label["L3"]["stiffness"]
                ),
            }

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
    p.add_argument(
        "--payload-mass",
        type=float,
        default=10.0,
        help="External contact payload kg (rests on the platform).",
    )
    p.add_argument(
        "--link-mass",
        type=float,
        default=0.1,
        help="Moving platform link kg (light, so load is dominated by contact).",
    )
    p.add_argument("--target", type=float, default=0.3, help="Target lift m.")
    p.add_argument(
        "--settle-steps", type=int, default=1000, help="Sim steps per config."
    )
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument(
        "--stiffness",
        type=float,
        nargs="+",
        default=[1e5, 5e3],
        help="Stiffness values (N/m): >=5e4 labelled L2.5, else L3.",
    )
    return p.parse_args()


if __name__ == "__main__":
    run_experiment(_parse_args())
