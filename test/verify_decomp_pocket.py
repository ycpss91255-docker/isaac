#!/usr/bin/env python3
"""Empirical Claim-2 check: can convex_decomposition preserve a FUNCTIONAL pocket
(a slot a probe must ENTER), and is the failure fundamental or a hull-count knob?

A U-channel obstacle (base + two walls, leaving a central slot) is authored as a
UsdGeom.Mesh STATIC collider. Its convex HULL fills the slot (the hull of a U is a
solid block); a convex DECOMPOSITION with enough hulls keeps base+walls separate,
so the slot stays open. We drop a dynamic probe box (narrower than the slot)
straight down over the slot and read its resting height:

  probe rests HIGH (on top, ~z of wall top)  -> slot filled  -> did NOT enter
  probe rests LOW  (inside slot, on base)     -> slot open    -> ENTERED

Three lanes on the SAME geometry:
  A  approximation = convexHull                    (expected: blocked)
  B  approximation = convexDecomposition, maxHulls=8
  C  approximation = convexDecomposition, maxHulls=64

Reads (empirical, not doc):
  - if C enters and A does not  -> decomposition CAN represent the pocket
                                   => "fundamentally disqualified" is REFUTED
  - if B blocked but C enters    -> it is a hull-count TUNING issue (as the audit
                                   of the doc argued)
  - if neither B nor C enters    -> supports the doc's stronger claim

CLI:
  just exec -t devel /isaac-sim/python.sh \\
    $W/test/verify_decomp_pocket.py --out $W/test/.verify-decomp-pocket.json
"""

import argparse
import json
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81
# U-channel = 3 boxes: base + left wall + right wall. Slot is the gap between
# walls above the base: X in [-0.2, 0.2] (width 0.40), Z in [0.30, 0.60].
_UBOXES = [
    ((0.0, 0.0, 0.15), (0.5, 0.25, 0.15)),    # base   X[-.5,.5] Z[0,.3]
    ((-0.35, 0.0, 0.45), (0.15, 0.25, 0.15)),  # left   X[-.5,-.2] Z[.3,.6]
    ((0.35, 0.0, 0.45), (0.15, 0.25, 0.15)),   # right  X[.2,.5]  Z[.3,.6]
]
_SLOT_WIDTH = 0.40
_WALL_TOP_Z = 0.60
_BASE_TOP_Z = 0.30
_PROBE_HALF = (0.15, 0.20, 0.15)  # width 0.30 < slot 0.40 -> fits if slot open
_PROBE_DROP_Z = 1.10              # start above; falls under gravity
# entered if the probe centre settles below the wall top minus its half-height.
_ENTER_Z_THRESH = _WALL_TOP_Z - 0.02


def _u_mesh_points_faces():
    """Points + triangle faceVertexCounts/Indices for the 3-box U-channel."""
    pts, idx = [], []
    for (cx, cy, cz), (hx, hy, hz) in _UBOXES:
        base = len(pts)
        for sx in (-1, 1):
            for sy in (-1, 1):
                for sz in (-1, 1):
                    pts.append((cx + sx * hx, cy + sy * hy, cz + sz * hz))
        # 12 triangles for this box (corner order: bit0=x,bit1=y,bit2=z)
        # vertices: 0=(-,-,-)1=(-,-,+)2=(-,+,-)3=(-,+,+)4=(+,-,-)5=(+,-,+)
        #           6=(+,+,-)7=(+,+,+)
        quads = [
            (0, 1, 3, 2), (4, 6, 7, 5),   # -X, +X
            (0, 4, 5, 1), (2, 3, 7, 6),   # -Y, +Y
            (0, 2, 6, 4), (1, 5, 7, 3),   # -Z, +Z
        ]
        for a, b, c, d in quads:
            idx += [base + a, base + b, base + c]
            idx += [base + a, base + c, base + d]
    counts = [3] * (len(idx) // 3)
    return pts, counts, idx


def _author_pocket(stage, path, y0, approximation, max_hulls):
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    pts, counts, idx = _u_mesh_points_faces()
    mesh = UsdGeom.Mesh.Define(stage, path)
    mesh.CreatePointsAttr([Gf.Vec3f(*p) for p in pts])
    mesh.CreateFaceVertexCountsAttr(counts)
    mesh.CreateFaceVertexIndicesAttr(idx)
    mesh.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, y0, 0.0))
    prim = mesh.GetPrim()
    UsdPhysics.CollisionAPI.Apply(prim)  # static collider (no RigidBodyAPI)
    mc = UsdPhysics.MeshCollisionAPI.Apply(prim)
    mc.CreateApproximationAttr().Set(approximation)
    if max_hulls is not None:
        dec = PhysxSchema.PhysxConvexDecompositionCollisionAPI.Apply(prim)
        dec.CreateMaxConvexHullsAttr().Set(int(max_hulls))
        dec.CreateHullVertexLimitAttr().Set(64)
        dec.CreateVoxelResolutionAttr().Set(500000)
        dec.CreateErrorPercentageAttr().Set(0.0)
        dec.CreateShrinkWrapAttr().Set(True)
    return path


def _author_probe(stage, path, y0):
    from pxr import Gf, UsdGeom, UsdPhysics
    cube = UsdGeom.Cube.Define(stage, path)
    cube.GetSizeAttr().Set(1.0)
    cube.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(0.0, y0, _PROBE_DROP_Z)
    )
    cube.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
        Gf.Vec3f(_PROBE_HALF[0] * 2, _PROBE_HALF[1] * 2, _PROBE_HALF[2] * 2)
    )
    prim = cube.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(prim)
    UsdPhysics.CollisionAPI.Apply(prim)
    UsdPhysics.MassAPI.Apply(prim).CreateMassAttr(1.0)
    return path


_CAM_EYE = (-4.6, -2.2, 3.1)
_CAM_TARGET = (0.0, 3.0, 0.35)


def _look_at(eye, target, up=(0.0, 0.0, 1.0)):
    import math

    def sub(a, b):
        return (a[0] - b[0], a[1] - b[1], a[2] - b[2])

    def cross(a, b):
        return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2],
                a[0] * b[1] - a[1] * b[0])

    def norm(a):
        n = math.sqrt(sum(c * c for c in a))
        return tuple(c / n for c in a) if n else a

    z = norm(sub(eye, target))
    x = norm(cross(up, z))
    y = cross(z, x)
    return [x[0], x[1], x[2], 0.0, y[0], y[1], y[2], 0.0,
            z[0], z[1], z[2], 0.0, eye[0], eye[1], eye[2], 1.0]


def _mat(stage, path, rgb):
    # Emissive/unlit: the surface emits its own colour, bypassing the (per-pixel,
    # denoiser-less -> grainy) lighting integral -> deterministic clean flat colour.
    from pxr import Gf, Sdf, UsdShade
    m = UsdShade.Material.Define(stage, path)
    s = UsdShade.Shader.Define(stage, path + "/S")
    s.CreateIdAttr("UsdPreviewSurface")
    s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(0, 0, 0))
    s.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
    s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
    s.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    m.CreateSurfaceOutput().ConnectToSource(s.ConnectableAPI(), "surface")
    return m


def _bind(stage, path, mat):
    from pxr import UsdShade
    UsdShade.MaterialBindingAPI.Apply(stage.GetPrimAtPath(path)).Bind(mat)


def _font(size):
    from PIL import ImageFont
    for p in ("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",):
        try:
            return ImageFont.truetype(p, size)
        except Exception:  # noqa: BLE001
            pass
    return ImageFont.load_default()


def _overlay(rgb, lines):
    from PIL import Image, ImageDraw
    img = Image.fromarray(rgb, mode="RGB").convert("RGB")
    d = ImageDraw.Draw(img)
    f = _font(20)
    d.rectangle([6, 6, 560, 6 + 26 * len(lines) + 10], fill=(0, 0, 0))
    y = 12
    for ln in lines:
        d.text((14, y), ln, fill=(240, 240, 60), font=f)
        y += 26
    return img


def run(args):
    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    result = {
        "check": "Claim 2 -- convex_decomposition functional pocket (probe drop)",
        "isaac_variant": "6.0.1",
        "slot_width_m": _SLOT_WIDTH,
        "probe_width_m": _PROBE_HALF[0] * 2,
        "enter_z_threshold_m": _ENTER_Z_THRESH,
        "wall_top_z_m": _WALL_TOP_Z,
        "base_top_z_m": _BASE_TOP_Z,
        "lanes": [],
        "error": None,
    }
    try:
        import numpy as np
        import omni.usd
        from isaacsim.core.api import World
        from isaacsim.core.prims import SingleRigidPrim
        from pxr import Gf, UsdGeom, UsdLux, UsdPhysics

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
        UsdGeom.SetStageMetersPerUnit(stage, 1.0)
        UsdGeom.Xform.Define(stage, "/World")
        UsdLux.DistantLight.Define(stage, "/World/Sun").CreateIntensityAttr(3000.0)
        ground = UsdGeom.Cube.Define(stage, "/World/Ground")
        ground.GetSizeAttr().Set(1.0)
        ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0, 0, -0.5))
        ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(200, 200, 1.0))
        UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

        lanes_cfg = [
            ("A_convexHull", UsdPhysics.Tokens.convexHull, None),
            ("B_decomp_h8", UsdPhysics.Tokens.convexDecomposition, 8),
            ("C_decomp_h64", UsdPhysics.Tokens.convexDecomposition, 64),
        ]
        probe_rgb = {"A_convexHull": (0.9, 0.3, 0.2),
                     "B_decomp_h8": (0.2, 0.8, 0.3),
                     "C_decomp_h64": (0.2, 0.5, 0.9)}
        probes = {}
        for i, (tag, approx, mh) in enumerate(lanes_cfg):
            y0 = i * 3.0
            _author_pocket(stage, f"/World/pocket_{tag}", y0, approx, mh)
            p = _author_probe(stage, f"/World/probe_{tag}", y0)
            probes[tag] = (p, y0)

        render = bool(args.mp4)
        annot = None
        if render:
            import carb
            import omni.replicator.core as rep
            from pxr import Gf, UsdGeom, UsdLux
            _s = carb.settings.get_settings()
            _s.set("/rtx/post/histogram/enabled", False)
            _s.set("/rtx/rendermode", "RaytracedLighting")
            for _k in ("/rtx/indirectDiffuse/enabled",
                       "/rtx/ambientOcclusion/enabled", "/rtx/reflections/enabled",
                       "/rtx/directLighting/sampledLighting/enabled",
                       "/rtx/shadows/enabled"):
                _s.set(_k, False)
            _key = UsdLux.DistantLight.Define(stage, "/World/VizKey")
            _key.CreateIntensityAttr(3000.0)
            UsdGeom.Xformable(_key.GetPrim()).AddRotateXYZOp().Set(
                Gf.Vec3f(-45.0, 15.0, 0.0))
            _fill = UsdLux.DistantLight.Define(stage, "/World/VizFill")
            _fill.CreateIntensityAttr(1500.0)
            UsdGeom.Xformable(_fill.GetPrim()).AddRotateXYZOp().Set(
                Gf.Vec3f(-30.0, 40.0, 0.0))
            gray = _mat(stage, "/World/Looks/Gray", (0.55, 0.55, 0.58))
            _bind(stage, "/World/Ground", gray)
            for tag, (approx, mh) in ((c[0], (c[1], c[2])) for c in lanes_cfg):
                _bind(stage, f"/World/pocket_{tag}", gray)
                pm = _mat(stage, f"/World/Looks/{tag}", probe_rgb[tag])
                _bind(stage, f"/World/probe_{tag}", pm)
            cam = UsdGeom.Camera.Define(stage, "/World/Cam")
            cam.CreateFocalLengthAttr(20.0)
            cam.CreateClippingRangeAttr((0.1, 100000.0))
            UsdGeom.Xformable(cam.GetPrim()).AddTransformOp().Set(
                __import__("pxr").Gf.Matrix4d(*_look_at(_CAM_EYE, _CAM_TARGET))
            )

        world = World(stage_units_in_meters=1.0, physics_dt=1.0 / 60.0,
                      rendering_dt=1.0 / 60.0)
        world.reset()
        views = {tag: SingleRigidPrim(p) for tag, (p, _y) in probes.items()}

        if render:
            rp = rep.create.render_product("/World/Cam", (960, 540))
            annot = rep.AnnotatorRegistry.get_annotator("rgb")
            annot.attach(rp)

        def _grab():
            for _ in range(3):
                world.render()
            raw = np.asarray(annot.get_data())
            if raw.size and raw.ndim == 3:
                px = raw[:, :, :3] if raw.shape[2] == 4 else raw
                return np.ascontiguousarray(px.astype(np.uint8))
            return None

        total = 210
        cap_steps = set(int(round(v)) for v in np.linspace(20, total - 1, 45)) \
            if render else set()
        frames, nonblack = [], 0
        for step_i in range(total):
            world.step(render=render)
            if render and step_i in cap_steps:
                lines = ["convex_decomposition preserves a functional pocket?"]
                for tag in probe_rgb:
                    pz = float(np.asarray(
                        views[tag].get_world_pose()[0]).reshape(-1)[2])
                    ent = pz < _ENTER_Z_THRESH
                    lines.append(f"{tag:13s} z={pz:5.3f} "
                                 f"{'ENTERED' if ent else 'blocked'}")
                rgb = _grab()
                if rgb is not None and float(rgb.mean()) > 1.0:
                    nonblack += 1
                if rgb is None:
                    rgb = np.zeros((540, 960, 3), dtype=np.uint8)
                frames.append(np.asarray(_overlay(rgb, lines)))

        for tag, (approx, mh) in ((c[0], (c[1], c[2])) for c in lanes_cfg):
            pos, _ = views[tag].get_world_pose()
            z = float(np.asarray(pos).reshape(-1)[2])
            result["lanes"].append({
                "lane": tag,
                "approximation": str(approx),
                "max_convex_hulls": mh,
                "probe_final_z_m": round(z, 4),
                "entered_pocket": bool(z < _ENTER_Z_THRESH),
            })

        if render and frames:
            import imageio.v2 as imageio
            Path(args.mp4).parent.mkdir(parents=True, exist_ok=True)
            imageio.mimwrite(args.mp4, frames, fps=15, codec="libx264",
                             quality=8)
            result["mp4"] = args.mp4
            result["mp4_frames"] = len(frames)
            result["mp4_nonblack"] = nonblack
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
    p.add_argument("--mp4", default=None,
                   help="If set, RTX-render the 3-lane probe drop with a per-frame "
                        "data HUD and encode an MP4 to this path (mounted).")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
