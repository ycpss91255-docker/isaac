#!/usr/bin/env python3
"""Raycast an entry-face occupancy map of pallet.usd under a chosen collision
approximation, to locate the fork tunnels (if any) empirically.

References the pallet at the origin, cooks the collider with the requested
approximation, then casts +x rays from x=-1.5 across a (y, z) grid over the -x
entry face. A ray that stops near the front face (x=-0.605) means SOLID there; a
ray that travels far means an OPEN tunnel. Prints an ASCII map ('#' solid at the
face, '.' open) and dumps the grid, so the insertion driver can aim the prongs at
real openings -- or show that this low-poly pallet has no through tunnel at all.

CLI:
  just docker exec -t devel /isaac-sim/python.sh \\
    $W/test/verify_pallet_entry_map.py \\
      --approx convexDecomposition \\
      --out $W/test/.pallet-entry-map.json
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
_FRONT_FACE_X = -0.605
_RAY_ORIGIN_X = -1.5
_RAY_MAX = 3.5
# "open" if the ray travels well past the front face before hitting anything.
_OPEN_DIST = (_FRONT_FACE_X - _RAY_ORIGIN_X) + 0.20   # 0.895 + 0.20


def run(args):
    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    result = {"check": "pallet entry-face occupancy (raycast)",
              "approx": args.approx, "front_face_x": _FRONT_FACE_X,
              "ys": [], "zs": [], "grid_hit_x": [], "error": None}
    try:
        import numpy as np
        import omni.usd
        from isaacsim.core.api import World
        from omni.physx import get_physx_scene_query_interface
        from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        UsdGeom.Xform.Define(stage, "/World")
        UsdLux.DistantLight.Define(stage, "/World/Sun").CreateIntensityAttr(3000.0)

        prim = stage.DefinePrim("/World/pallet", "Xform")
        prim.GetReferences().AddReference(_PALLET_URL)
        n = 0
        stack = [prim]
        while stack:
            p = stack.pop()
            stack.extend(p.GetChildren())
            if str(p.GetTypeName()) == "Mesh":
                UsdPhysics.CollisionAPI.Apply(p)
                mc = UsdPhysics.MeshCollisionAPI.Apply(p)
                mc.CreateApproximationAttr().Set(args.approx)
                if args.approx == "convexDecomposition":
                    dec = PhysxSchema.PhysxConvexDecompositionCollisionAPI.Apply(p)
                    dec.CreateMaxConvexHullsAttr().Set(128)
                    dec.CreateHullVertexLimitAttr().Set(64)
                    dec.CreateVoxelResolutionAttr().Set(500000)
                    dec.CreateErrorPercentageAttr().Set(0.0)
                    dec.CreateShrinkWrapAttr().Set(True)
                n += 1
        result["mesh_overrides"] = n

        world = World(stage_units_in_meters=1.0, physics_dt=1.0 / 60.0)
        world.reset()
        for _ in range(3):
            world.step(render=False)
        sq = get_physx_scene_query_interface()

        ys = [round(v, 3) for v in np.linspace(-0.4, 0.4, 17)]
        zs = [round(v, 3) for v in np.linspace(0.13, 0.01, 13)]  # top->bottom
        result["ys"], result["zs"] = ys, zs
        rows_ascii = []
        for z in zs:
            row_hit = []
            row_txt = ""
            for y in ys:
                hit = sq.raycast_closest([_RAY_ORIGIN_X, y, z], [1.0, 0.0, 0.0],
                                         _RAY_MAX)
                if hit and hit.get("hit"):
                    hx = _RAY_ORIGIN_X + float(hit["distance"])
                    dist = float(hit["distance"])
                else:
                    hx = None
                    dist = _RAY_MAX
                row_hit.append(None if hx is None else round(hx, 3))
                row_txt += "." if dist >= _OPEN_DIST else "#"
            result["grid_hit_x"].append(row_hit)
            rows_ascii.append(row_txt)
        result["ascii_map_top_to_bottom"] = rows_ascii
        # log the map to stdout for quick eyeballing
        print("APPROX", args.approx, "  ('.'=open tunnel, '#'=solid at face)")
        print("     y:", " ".join(f"{y:+.2f}" for y in ys))
        for z, r in zip(zs, rows_ascii):
            print(f"z={z:.3f} {r}")
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
    p.add_argument("--approx", default="convexDecomposition")
    p.add_argument("--out", required=True)
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
