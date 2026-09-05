#!/usr/bin/env python3
"""Empirical A3/A4 check: does the 6.0.1 URDF->USD pipeline preserve link ORIGIN
and CAD INERTIA (mass + inertia tensor), or silently mangle them?

Authors a synthetic URDF (no CAD needed) with a link carrying:
  * a known <inertial>: mass + a DIAGONAL inertia tensor with three distinct
    values (so a reorder / recompute is detectable), and
  * a <collision><box> at a known non-zero origin,
imports it through the migrated pipeline (isaac_devkit.model_import._convert_urdf)
and reads the produced USD back:

  A3 (origin):  the collider prim's world translate == the authored <origin>.
  A4 (inertia): USD physics:mass == URDF mass, and physics:diagonalInertia matches
                the URDF ixx/iyy/izz (as a set; USD may reorder to principal axes).
                A box-fitting / recompute would change these -> caught here.

Settles empirically (not from docs) whether the CAD-derived mass/inertia -- the
highest-value output of the sw2urdf path -- survives conversion unchanged.

CLI:
  just docker exec -t devel env PYTHONPATH=$W/framework /isaac-sim/python.sh \\
    $W/test/verify_import_fidelity.py --out $W/test/.verify-import-fidelity.json
"""

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

# Known authored values (distinct so any reorder/recompute is visible).
_MASS = 7.5
_IXX, _IYY, _IZZ = 0.021, 0.034, 0.047
_ORIGIN = (0.30, -0.20, 0.15)
_BOX = (0.20, 0.30, 0.40)

_URDF = """<?xml version="1.0"?>
<robot name="fidelity">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual><geometry><box size="0.05 0.05 0.05"/></geometry></visual>
  </link>
  <link name="probe_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="{mass}"/>
      <inertia ixx="{ixx}" ixy="0" ixz="0" iyy="{iyy}" iyz="0" izz="{izz}"/>
    </inertial>
    <collision>
      <origin xyz="{ox} {oy} {oz}" rpy="0 0 0"/>
      <geometry><box size="{bx} {by} {bz}"/></geometry>
    </collision>
    <visual>
      <origin xyz="{ox} {oy} {oz}" rpy="0 0 0"/>
      <geometry><box size="{bx} {by} {bz}"/></geometry>
    </visual>
  </link>
  <joint name="j" type="fixed">
    <origin xyz="0 0 0.5" rpy="0 0 0"/>
    <parent link="base_link"/>
    <child link="probe_link"/>
  </joint>
</robot>
"""


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "check": "A3 origin + A4 inertia import fidelity",
        "isaac_variant": "6.0.1",
        "authored": {
            "mass": _MASS, "ixx": _IXX, "iyy": _IYY, "izz": _IZZ,
            "collision_origin": list(_ORIGIN), "box": list(_BOX),
            "joint_z": 0.5,
        },
        "error": None,
    }
    try:
        from pxr import Usd, UsdGeom, UsdPhysics
        from isaac_devkit import model_import

        urdf_path = Path("/tmp/fidelity.urdf")
        urdf_path.write_text(_URDF.format(
            mass=_MASS, ixx=_IXX, iyy=_IYY, izz=_IZZ,
            ox=_ORIGIN[0], oy=_ORIGIN[1], oz=_ORIGIN[2],
            bx=_BOX[0], by=_BOX[1], bz=_BOX[2]))
        out_usd = Path("/tmp/fidelity.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=False)
        if not Path(produced).exists():
            raise RuntimeError(f"no USD at {produced}")
        stage = Usd.Stage.Open(str(produced))

        # A4: find the prim carrying MassAPI with our mass; read mass + inertia.
        mass_read = None
        diag_read = None
        for prim in stage.Traverse():
            if prim.HasAPI(UsdPhysics.MassAPI):
                mapi = UsdPhysics.MassAPI(prim)
                m = mapi.GetMassAttr().Get()
                if m is not None and abs(float(m) - _MASS) < 0.5:
                    mass_read = float(m)
                    di = mapi.GetDiagonalInertiaAttr().Get()
                    if di is not None:
                        diag_read = [float(v) for v in di]
                    break
        # A3: collider prim world translate. probe box collider is a Cube with
        # CollisionAPI; its world x should match joint_z-composed origin.
        origin_read = None
        for prim in stage.Traverse():
            if (prim.HasAPI(UsdPhysics.CollisionAPI)
                    and str(prim.GetTypeName()) == "Cube"
                    and "probe" in str(prim.GetPath()).lower()):
                m = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(
                    Usd.TimeCode.Default())
                t = m.ExtractTranslation()
                origin_read = [round(float(t[0]), 4), round(float(t[1]), 4),
                               round(float(t[2]), 4)]
                break

        result["mass_read"] = mass_read
        result["diagonal_inertia_read"] = diag_read
        result["collider_world_translate_read"] = origin_read
        # A4 verdicts.
        result["A4_mass_exact"] = bool(
            mass_read is not None and abs(mass_read - _MASS) < 1e-4)
        authored_set = sorted([_IXX, _IYY, _IZZ])
        result["A4_inertia_preserved"] = bool(
            diag_read is not None
            and all(abs(a - b) < 1e-5
                    for a, b in zip(sorted(diag_read), authored_set)))
        # A3 verdict: world x/y == origin x/y; world z == origin z + joint 0.5.
        exp = [_ORIGIN[0], _ORIGIN[1], _ORIGIN[2] + 0.5]
        result["A3_origin_preserved"] = bool(
            origin_read is not None
            and all(abs(origin_read[i] - exp[i]) < 1e-3 for i in range(3)))
        result["A3_expected_world_translate"] = [round(v, 4) for v in exp]
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
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
