#!/usr/bin/env python3
"""Real-asset collision probe (Isaac 6.0 official pallet), via direct-HTTPS.

Two things settled empirically here:

  1. HUB BYPASS: earlier `omni.client.list()` failed because the local Omniverse
     Hub connector daemon cannot launch in this container (cannot write
     /tmp/hub-*.config.json). This opens the SAME NVIDIA asset over a direct
     HTTPS S3 URL -- the USD resolver walks references over the same root, no
     Hub involved -- proving source "A" (Isaac official assets) is usable.

  2. REAL CONCAVE GEOMETRY: the wooden pallet is an art-asset mesh with deep
     fork pockets -- the canonical convex-hull-fills-the-cavity case. We dump
     its mesh/collider inventory (triangle counts, existing collision APIs,
     approximation scheme, world bbox) as the baseline the hull/decomp/SDF
     comparison runs against. Contrast object to the synthetic clean box-union.

Opens the stage read-only over HTTPS and inventories geometry; does NOT step
physics here (that is the separate fork-insertion comparison).

CLI:
  just exec -t devel env PYTHONPATH=$W/framework /isaac-sim/python.sh \\
    $W/test/verify_real_asset_collision.py \\
      --url https://omniverse-content-production.s3-us-west-2.amazonaws.com/Assets/Isaac/6.0/Isaac/Props/Pallet/pallet.usd \\
      --out $W/test/.verify-real-asset-collision.json
"""

import argparse
import json
import os
import sys
import traceback

_DEFAULT_URL = (
    "https://omniverse-content-production.s3-us-west-2.amazonaws.com"
    "/Assets/Isaac/6.0/Isaac/Props/Pallet/pallet.usd"
)


def _inventory_one(url):
    """Open one asset over HTTPS and inventory its geometry/colliders."""
    from pxr import Usd, UsdGeom, UsdPhysics, Gf

    rec = {"url": url, "opened_over_https": False, "error": None}
    try:
        stage = Usd.Stage.Open(url)
        if stage is None:
            raise RuntimeError("Usd.Stage.Open returned None (asset not resolved)")
        rec["opened_over_https"] = True
        rec["root_layer_identifier"] = str(stage.GetRootLayer().identifier)

        bbcache = UsdGeom.BBoxCache(
            Usd.TimeCode.Default(),
            [UsdGeom.Tokens.default_, UsdGeom.Tokens.render])

        def _world_bbox(prim):
            try:
                b = bbcache.ComputeWorldBound(prim).ComputeAlignedRange()
                if b.IsEmpty():
                    return None
                mn, mx = b.GetMin(), b.GetMax()
                return {
                    "min": [round(float(mn[i]), 4) for i in range(3)],
                    "max": [round(float(mx[i]), 4) for i in range(3)],
                    "size": [round(float(mx[i] - mn[i]), 4) for i in range(3)],
                }
            except Exception:  # noqa: BLE001
                return None

        meshes = []
        colliders = []
        total_tris = 0
        world_min = [float("inf")] * 3
        world_max = [float("-inf")] * 3
        for prim in stage.Traverse():
            tn = str(prim.GetTypeName())
            if tn == "Mesh":
                m = UsdGeom.Mesh(prim)
                fvc = m.GetFaceVertexCountsAttr().Get()
                ntri = 0
                if fvc:
                    # a face with n verts -> (n-2) tris (fan)
                    ntri = sum(max(int(c) - 2, 0) for c in fvc)
                total_tris += ntri
                meshes.append({
                    "path": str(prim.GetPath()),
                    "tris": ntri,
                    "has_collision_api": bool(
                        prim.HasAPI(UsdPhysics.CollisionAPI)),
                })
                # accumulate world bbox from extent if present
                ext = m.GetExtentAttr().Get()
                xf = UsdGeom.Xformable(prim).ComputeLocalToWorldTransform(
                    Usd.TimeCode.Default())
                if ext:
                    for corner in ext:
                        p = xf.Transform(Gf.Vec3d(corner[0], corner[1], corner[2]))
                        for i in range(3):
                            world_min[i] = min(world_min[i], float(p[i]))
                            world_max[i] = max(world_max[i], float(p[i]))
            if prim.HasAPI(UsdPhysics.CollisionAPI):
                scheme = None
                if prim.HasAPI(UsdPhysics.MeshCollisionAPI):
                    mc = UsdPhysics.MeshCollisionAPI(prim)
                    a = mc.GetApproximationAttr().Get()
                    scheme = str(a) if a is not None else None
                colliders.append({
                    "path": str(prim.GetPath()),
                    "type": tn,
                    "approximation": scheme,
                    "world_bbox": _world_bbox(prim),
                })

        rec["mesh_count"] = len(meshes)
        rec["total_triangles"] = total_tris
        rec["collider_count"] = len(colliders)
        rec["colliders"] = colliders[:50]
        rec["meshes"] = sorted(
            meshes, key=lambda d: d["tris"], reverse=True)[:20]
        if world_min[0] != float("inf"):
            rec["world_bbox_min"] = [round(v, 4) for v in world_min]
            rec["world_bbox_max"] = [round(v, 4) for v in world_max]
            rec["world_size"] = [
                round(world_max[i] - world_min[i], 4) for i in range(3)]
    except Exception as exc:  # noqa: BLE001
        rec["error"] = f"{type(exc).__name__}: {exc}"
        rec["traceback"] = traceback.format_exc()
    return rec


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    urls = [u.strip() for u in args.url.split(",") if u.strip()]
    result = {
        "check": "real-asset collision probe (Hub-bypass via direct HTTPS)",
        "isaac_variant": "6.0.1",
        "asset_count": len(urls),
        "assets": [],
        "error": None,
    }
    try:
        for u in urls:
            result["assets"].append(_inventory_one(u))
        # top-level error only if EVERY asset failed to open
        if urls and all(a.get("error") for a in result["assets"]):
            result["error"] = "all assets failed to open"
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
    finally:
        try:
            with open(args.out, "w") as f:
                json.dump(result, f, indent=2)
        except Exception:  # noqa: BLE001
            pass
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1 if result["error"] else 0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--url", default=_DEFAULT_URL,
                   help="Direct HTTPS asset URL(s), comma-separated for batch.")
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
