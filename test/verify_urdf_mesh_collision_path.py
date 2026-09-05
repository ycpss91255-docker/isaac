#!/usr/bin/env python3
"""Does OUR URDF->USD importer destroy a real concave collider? (ADR-0020 core claim)

The Isaac-asset experiments (verify_real_pallet_insertion.py) act on PRE-AUTHORED
USD, so they never exercise our import path. This closes that gap using the SAME
real geometry: the official pallet mesh is exported to OBJ, wrapped in a URDF as a
``<collision><mesh>``, and pushed through isaac_devkit.model_import._convert_urdf.

We then read back what approximation the importer actually authored, and raycast
the produced USD's entry face to see whether the fork tunnels survived:

  claim  : the importer hard-codes convexHull for a <collision> mesh, so ANY
           third-party URDF shipping concave collision meshes silently loses its
           pockets -- regardless of what the author intended.
  control: the same pallet authored as a URDF box-union (explicit <collision><box>
           per part) keeps the tunnels, because boxes are imported as real
           UsdGeom.Cube colliders (see verify_collision_import.py A1/A2).

CLI:
  just docker exec -t devel env PYTHONPATH=$W/framework /isaac-sim/python.sh \\
    $W/test/verify_urdf_mesh_collision_path.py \\
      --out $W/test/.verify-urdf-mesh-collision.json
"""

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

_PALLET_URL = (
    "https://omniverse-content-production.s3-us-west-2.amazonaws.com"
    "/Assets/Isaac/6.0/Isaac/Props/Pallet/pallet.usd"
)
_RAY_ORIGIN_X = -1.5
_RAY_MAX = 3.5
_FRONT_FACE_X = -0.605
_OPEN_DIST = (_FRONT_FACE_X - _RAY_ORIGIN_X) + 0.20

_URDF_MESH = """<?xml version="1.0"?>
<robot name="pallet_mesh">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="25.0"/>
      <inertia ixx="1.0" ixy="0" ixz="0" iyy="1.0" iyz="0" izz="1.0"/>
    </inertial>
    <visual><geometry><mesh filename="{obj}"/></geometry></visual>
    <collision><geometry><mesh filename="{obj}"/></geometry></collision>
  </link>
</robot>
"""


def _export_pallet_obj(obj_path):
    """Pull the real pallet mesh over HTTPS and write it out as a world-space OBJ."""
    from pxr import Gf, Usd, UsdGeom

    stage = Usd.Stage.Open(_PALLET_URL)
    if stage is None:
        raise RuntimeError("could not open pallet.usd over HTTPS")
    mesh_prim = None
    for prim in stage.Traverse():
        if str(prim.GetTypeName()) == "Mesh":
            mesh_prim = prim
            break
    if mesh_prim is None:
        raise RuntimeError("no Mesh in pallet.usd")

    m = UsdGeom.Mesh(mesh_prim)
    pts = m.GetPointsAttr().Get()
    counts = m.GetFaceVertexCountsAttr().Get()
    idx = m.GetFaceVertexIndicesAttr().Get()
    xf = UsdGeom.Xformable(mesh_prim).ComputeLocalToWorldTransform(
        Usd.TimeCode.Default())

    lines = ["# pallet.usd mesh exported to world space for URDF import test"]
    for p in pts:
        w = xf.Transform(Gf.Vec3d(p[0], p[1], p[2]))
        lines.append(f"v {w[0]:.6f} {w[1]:.6f} {w[2]:.6f}")
    o = 0
    nfaces = 0
    for c in counts:
        c = int(c)
        face = [idx[o + k] + 1 for k in range(c)]   # OBJ is 1-indexed
        lines.append("f " + " ".join(str(v) for v in face))
        o += c
        nfaces += 1
    Path(obj_path).write_text("\n".join(lines) + "\n")
    return len(pts), nfaces


def _entry_map(sq, tag):
    """Raycast the (y,z) entry grid; return ascii rows + open-cell count."""
    import numpy as np

    ys = [round(v, 3) for v in np.linspace(-0.4, 0.4, 17)]
    zs = [round(v, 3) for v in np.linspace(0.13, 0.01, 13)]
    rows, n_open = [], 0
    for z in zs:
        txt = ""
        for y in ys:
            hit = sq.raycast_closest([_RAY_ORIGIN_X, y, z], [1.0, 0.0, 0.0],
                                     _RAY_MAX)
            dist = float(hit["distance"]) if (hit and hit.get("hit")) else _RAY_MAX
            openc = dist >= _OPEN_DIST
            n_open += 1 if openc else 0
            txt += "." if openc else "#"
        rows.append(txt)
    print(f"--- entry map [{tag}] ('.'=open, '#'=solid) ---")
    for z, r in zip(zs, rows):
        print(f"z={z:.3f} {r}")
    return rows, n_open


def run(args):
    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    result = {
        "check": "URDF <collision><mesh> import path vs real concave pallet",
        "isaac_variant": "6.0.1",
        "source_mesh": _PALLET_URL,
        "error": None,
    }
    try:
        import omni.usd
        from isaacsim.core.api import World
        from omni.physx import get_physx_scene_query_interface
        from pxr import Usd, UsdGeom, UsdLux, UsdPhysics
        from isaac_devkit import model_import

        obj_path = "/tmp/pallet_export.obj"
        nv, nf = _export_pallet_obj(obj_path)
        result["exported_obj"] = {"path": obj_path, "verts": nv, "faces": nf}

        urdf_path = Path("/tmp/pallet_mesh.urdf")
        urdf_path.write_text(_URDF_MESH.format(obj=obj_path))
        out_usd = Path("/tmp/pallet_mesh.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=False)
        if not Path(produced).exists():
            raise RuntimeError(f"no USD produced at {produced}")
        result["produced_usd"] = str(produced)

        # what approximation did the IMPORTER choose for our <collision><mesh>?
        pstage = Usd.Stage.Open(str(produced))
        authored = []
        for prim in pstage.Traverse():
            if prim.HasAPI(UsdPhysics.CollisionAPI):
                a = None
                if prim.HasAPI(UsdPhysics.MeshCollisionAPI):
                    a = UsdPhysics.MeshCollisionAPI(prim).GetApproximationAttr().Get()
                authored.append({"path": str(prim.GetPath()),
                                 "type": str(prim.GetTypeName()),
                                 "approximation": None if a is None else str(a)})
        result["importer_authored_colliders"] = authored
        schemes = sorted({c["approximation"] for c in authored
                          if c["approximation"]})
        result["importer_approximations"] = schemes
        result["importer_forced_convex_hull"] = bool(
            schemes and all(s == "convexHull" for s in schemes))

        # load it into a physics scene and raycast the entry face.
        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        UsdGeom.Xform.Define(stage, "/World")
        UsdLux.DistantLight.Define(stage, "/World/Sun").CreateIntensityAttr(3000.0)
        ref = stage.DefinePrim("/World/imported", "Xform")
        ref.GetReferences().AddReference(str(produced))

        world = World(stage_units_in_meters=1.0, physics_dt=1.0 / 60.0)
        world.reset()
        for _ in range(3):
            world.step(render=False)
        sq = get_physx_scene_query_interface()
        rows, n_open = _entry_map(sq, "URDF <collision><mesh> import")
        result["entry_map_ascii"] = rows
        result["entry_open_cells"] = n_open
        result["tunnels_survived_import"] = bool(n_open > 8)
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
