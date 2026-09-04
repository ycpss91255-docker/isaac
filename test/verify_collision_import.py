#!/usr/bin/env python3
"""Empirical A1/A2 check: does the 6.0.1 URDF importer keep N box <collision>
elements per link, as ANALYTIC boxes, and how are they structured in USD?

Authors a 1-link URDF with THREE non-overlapping <collision><box> at distinct
origins (+ one visual box) and imports it through the SAME migrated pipeline the
experiments use (isaac_devkit.model_import._convert_urdf -> the real
isaacsim.asset.importer.urdf backend). Then opens the produced USD and, for every
prim carrying UsdPhysics.CollisionAPI, records: prim type (UsdGeom.Cube = analytic
box), whether MeshCollisionAPI / a physics:approximation is present (should NOT be
for a box), the local translate, and the parent prim (to see whether colliders sit
directly under the link or under a 'colliders' Scope).

Settles empirically, not from docs:
  A1  all 3 collisions kept (not just the first / not merged into 1)
  A2  each is UsdGeom.Cube + CollisionAPI, NO MeshCollisionAPI, NO convexHull
  +   the actual USD prim structure (Scope grouping? ghost/duplicate colliders?)

CLI:
  just exec -t devel env PYTHONPATH=$W/framework /isaac-sim/python.sh \\
    $W/test/verify_collision_import.py --out $W/test/.verify-collision-import.json
"""

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

# 3 boxes at distinct origins, distinct sizes -> easy to tell apart in USD.
_BOXES = [
    {"name": "cb_a", "size": (0.20, 0.20, 0.20), "xyz": (0.30, 0.0, 0.0)},
    {"name": "cb_b", "size": (0.10, 0.40, 0.10), "xyz": (-0.30, 0.0, 0.0)},
    {"name": "cb_c", "size": (0.15, 0.15, 0.30), "xyz": (0.0, 0.0, 0.30)},
]

_URDF = """<?xml version="1.0"?>
<robot name="multibox">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <geometry><box size="0.05 0.05 0.05"/></geometry>
    </visual>
{collisions}
  </link>
</robot>
"""

_COLLISION = """    <collision>
      <origin xyz="{x} {y} {z}" rpy="0 0 0"/>
      <geometry><box size="{sx} {sy} {sz}"/></geometry>
    </collision>"""


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "check": "A1/A2 multi-box <collision> import fidelity",
        "isaac_variant": "6.0.1",
        "authored_boxes": _BOXES,
        "error": None,
    }
    try:
        from pxr import Usd, UsdGeom, UsdPhysics
        from isaac_devkit import model_import

        cols = "\n".join(
            _COLLISION.format(x=b["xyz"][0], y=b["xyz"][1], z=b["xyz"][2],
                              sx=b["size"][0], sy=b["size"][1], sz=b["size"][2])
            for b in _BOXES
        )
        urdf_path = Path("/tmp/multibox.urdf")
        urdf_path.write_text(_URDF.format(collisions=cols))
        out_usd = Path("/tmp/multibox.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
        )
        result["produced_usd"] = str(produced)
        if not Path(produced).exists():
            raise RuntimeError(f"no USD produced at {produced}")

        stage = Usd.Stage.Open(str(produced))
        colliders = []
        for prim in stage.Traverse():
            if not prim.HasAPI(UsdPhysics.CollisionAPI):
                continue
            type_name = str(prim.GetTypeName())
            has_mesh_api = prim.HasAPI(UsdPhysics.MeshCollisionAPI)
            approx = None
            if has_mesh_api:
                mc = UsdPhysics.MeshCollisionAPI(prim)
                a = mc.GetApproximationAttr()
                approx = str(a.Get()) if a and a.HasAuthoredValue() else None
            # local-to-world translation
            try:
                xf = UsdGeom.Xformable(prim)
                m = xf.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
                t = m.ExtractTranslation()
                trans = [round(float(t[0]), 4), round(float(t[1]), 4),
                         round(float(t[2]), 4)]
            except Exception:  # noqa: BLE001
                trans = None
            parent = prim.GetParent()
            colliders.append({
                "path": str(prim.GetPath()),
                "type": type_name,
                "is_analytic_cube": type_name == "Cube",
                "has_mesh_collision_api": bool(has_mesh_api),
                "approximation": approx,
                "world_translate": trans,
                "parent_path": str(parent.GetPath()) if parent else None,
                "parent_type": str(parent.GetTypeName()) if parent else None,
            })
        result["n_colliders"] = len(colliders)
        result["colliders"] = colliders
        result["A1_all_three_kept"] = len(colliders) == 3
        result["A2_all_analytic_boxes_no_hull"] = bool(colliders) and all(
            c["is_analytic_cube"] and not c["has_mesh_collision_api"]
            and c["approximation"] is None for c in colliders
        )
        parents = {c["parent_path"] for c in colliders}
        ptypes = {c["parent_type"] for c in colliders}
        result["colliders_parent_paths"] = sorted(p for p in parents if p)
        result["colliders_grouped_under_scope"] = any(
            pt == "Scope" for pt in ptypes
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
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
