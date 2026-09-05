#!/usr/bin/env python3
"""Fork-insertion on a REAL Isaac pallet: boundingCube vs convexHull vs
convexDecomposition, measured empirically (penetration depth), not from docs.

Loads the official NVIDIA EUR pallet (Props/Pallet/pallet.usd, ~1.2x0.8x0.14 m)
over direct HTTPS (Hub-bypass), references it into three lanes, and OVERRIDES the
mesh collider approximation per lane. In each lane a fork prong -- a long thin box
constrained to a 1-DOF prismatic slide along +x and given an initial coast
velocity -- is driven into the pallet's fork tunnel at three lateral offsets
(local y = -0.26 / 0 / +0.26). PhysX contact stops the prong at a solid face; an
open tunnel lets it coast through. We read each prong's max +x reached and convert
to penetration past the pallet front face.

  boundingCube        -> pallet is one solid AABB  -> tunnels gone   -> blocked
  convexHull          -> hull of a pallet is solid -> tunnels gone   -> blocked
  convexDecomposition -> concavity kept (enough hulls) -> tunnel open -> ENTERS

This is the real-asset counterpart to test/verify_decomp_pocket.py (synthetic
U-channel) and directly tests the collision-authoring policy in ADR-0020: the
"fork cannot insert" failure is an approximation choice, not an import bug --
NVIDIA itself ships o3dyn_pallet.usd with convexDecomposition for exactly this.

CLI:
  just exec -t devel env PYTHONPATH=$W/framework /isaac-sim/python.sh \\
    $W/test/verify_real_pallet_insertion.py \\
      --out $W/test/.verify-real-pallet-insertion.json \\
      --mp4 $W/doc/viz/pallet_insertion.mp4
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

# pallet.usd measured world extent (from verify_real_asset_collision probe).
_FRONT_FACE_X = -0.605      # -x face the fork enters through
_PALLET_DEPTH_X = 1.21      # full length along x
_FORK_HALF_LEN = 0.70       # prong is 1.40 m long in x
_FORK_W = 0.08              # prong cross-section (y)
_FORK_H = 0.06             # prong cross-section (z)
_FORK_Z = 0.05             # prong centre height (tunnel spans z<=0.09; see map)
_START_GAP = 0.03          # prong tip starts this far outside the front face
_COAST_V = 0.5             # m/s, initial slide velocity
_LANE_DY = 2.2             # world-y spacing between approximation lanes
# tunnel centres located empirically by verify_pallet_entry_map.py: y=+/-0.15
# are open on the decomposed pallet; y=0 is the solid centre block (control).
_FORK_YS = (-0.15, 0.0, 0.15)   # lateral offsets probed within each pallet
_ENTER_THRESH = 0.30       # penetration past face (m) counted as "entered"
_TOTAL_STEPS = 320
_HULLS = 64                # decomposition hull budget (enough to keep tunnels)


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
    prim = stage.GetPrimAtPath(path)
    if prim and prim.IsValid():
        UsdShade.MaterialBindingAPI.Apply(prim).Bind(mat)


def _font(size):
    from PIL import ImageFont
    try:
        return ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", size)
    except Exception:  # noqa: BLE001
        return ImageFont.load_default()


def _overlay(rgb, lines):
    import numpy as np
    from PIL import Image, ImageDraw
    img = Image.fromarray(rgb, mode="RGB").convert("RGB")
    d = ImageDraw.Draw(img)
    f = _font(20)
    d.rectangle([6, 6, 620, 6 + 26 * len(lines) + 10], fill=(0, 0, 0))
    y = 12
    for ln in lines:
        d.text((14, y), ln, fill=(240, 240, 60), font=f)
        y += 26
    return np.asarray(img)


def _reference_pallet(stage, path, lane_y, approx, hulls):
    """Reference pallet.usd at (0, lane_y, 0); override its mesh approximation.

    Returns the front-face world x (== _FRONT_FACE_X, pallet placed at x=0)."""
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    prim = stage.DefinePrim(path, "Xform")
    prim.GetReferences().AddReference(_PALLET_URL)
    UsdGeom.Xformable(prim).AddTranslateOp().Set(Gf.Vec3d(0.0, lane_y, 0.0))

    # find the mesh collider(s) under the referenced pallet and override approx.
    n_over = 0
    for p in Usd_iter(stage, prim):
        if str(p.GetTypeName()) == "Mesh":
            UsdPhysics.CollisionAPI.Apply(p)
            mc = UsdPhysics.MeshCollisionAPI.Apply(p)
            mc.CreateApproximationAttr().Set(approx)
            if approx == UsdPhysics.Tokens.convexDecomposition:
                dec = PhysxSchema.PhysxConvexDecompositionCollisionAPI.Apply(p)
                dec.CreateMaxConvexHullsAttr().Set(int(hulls))
                dec.CreateHullVertexLimitAttr().Set(64)
                dec.CreateVoxelResolutionAttr().Set(500000)
                dec.CreateErrorPercentageAttr().Set(0.0)
                dec.CreateShrinkWrapAttr().Set(True)
            # keep it static: if it carries a rigid body, disable it.
            if p.HasAPI(UsdPhysics.RigidBodyAPI):
                UsdPhysics.RigidBodyAPI(p).CreateRigidBodyEnabledAttr(False)
            n_over += 1
    return n_over


def Usd_iter(stage, root_prim):
    """Depth-first iterate root_prim and all descendants."""
    stack = [root_prim]
    while stack:
        p = stack.pop()
        yield p
        stack.extend(p.GetChildren())


def _author_fork(stage, path, world_y):
    """A long thin box, 1-DOF prismatic slide along world +x, coasting into +x."""
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    start_x = _FRONT_FACE_X - _FORK_HALF_LEN - _START_GAP
    cube = UsdGeom.Cube.Define(stage, path)
    cube.GetSizeAttr().Set(1.0)
    cube.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
        Gf.Vec3d(start_x, world_y, _FORK_Z))
    cube.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
        Gf.Vec3f(_FORK_HALF_LEN * 2, _FORK_W, _FORK_H))
    prim = cube.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(prim)
    UsdPhysics.CollisionAPI.Apply(prim)
    UsdPhysics.MassAPI.Apply(prim).CreateMassAttr(1.0)
    rb = PhysxSchema.PhysxRigidBodyAPI.Apply(prim)
    rb.CreateEnableCCDAttr(True)               # thin boards -> avoid tunneling
    rb.CreateDisableGravityAttr(True)          # coast at tunnel height

    # prismatic joint: world (body0 empty) -> fork, axis X, free range.
    j = UsdPhysics.PrismaticJoint.Define(stage, path + "/xslide")
    j.CreateAxisAttr(UsdPhysics.Tokens.x)
    j.CreateBody1Rel().SetTargets([path])
    j.CreateLocalPos0Attr(Gf.Vec3f(start_x, world_y, _FORK_Z))
    j.CreateLocalPos1Attr(Gf.Vec3f(0.0, 0.0, 0.0))
    j.CreateLowerLimitAttr(-1.0)
    j.CreateUpperLimitAttr(1000.0)
    return path, start_x


def run(args):
    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    result = {
        "check": "real pallet fork-insertion: boundingCube vs convexHull vs "
                 "convexDecomposition",
        "isaac_variant": "6.0.1",
        "pallet_url": _PALLET_URL,
        "front_face_x": _FRONT_FACE_X,
        "pallet_depth_x": _PALLET_DEPTH_X,
        "fork_z": _FORK_Z,
        "fork_lateral_offsets": list(_FORK_YS),
        "coast_v": _COAST_V,
        "enter_threshold_m": _ENTER_THRESH,
        "decomposition_max_hulls": _HULLS,
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

        lanes_cfg = [
            ("free_control", None),
            ("boundingCube", UsdPhysics.Tokens.boundingCube),
            ("convexHull", UsdPhysics.Tokens.convexHull),
            ("convexDecomposition", UsdPhysics.Tokens.convexDecomposition),
        ]
        fork_index = {}   # (tag, y) -> (path, start_x)
        for li, (tag, approx) in enumerate(lanes_cfg):
            lane_y = li * _LANE_DY
            n = 0
            if approx is not None:
                n = _reference_pallet(
                    stage, f"/World/pallet_{tag}", lane_y, approx, _HULLS)
            result["lanes"].append({"lane": tag, "approximation": str(approx),
                                    "mesh_overrides": n, "forks": []})
            for yi, dy in enumerate(_FORK_YS):
                fp = f"/World/fork_{tag}_{yi}"
                path, sx = _author_fork(stage, fp, lane_y + dy)
                fork_index[(tag, yi)] = (path, sx)

        render = bool(args.mp4)
        annot = None
        if render:
            import carb
            import omni.replicator.core as rep
            _s = carb.settings.get_settings()
            _s.set("/rtx/post/histogram/enabled", False)
            _s.set("/rtx/rendermode", "RaytracedLighting")
            for _k in ("/rtx/indirectDiffuse/enabled",
                       "/rtx/ambientOcclusion/enabled", "/rtx/reflections/enabled",
                       "/rtx/directLighting/sampledLighting/enabled",
                       "/rtx/shadows/enabled"):
                _s.set(_k, False)
            _s.set("/rtx/post/aa/op", 2)
            key = UsdLux.DistantLight.Define(stage, "/World/VizKey")
            key.CreateIntensityAttr(3000.0)
            UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(
                Gf.Vec3f(-45.0, 15.0, 0.0))
            gray = _mat(stage, "/World/Looks/Gray", (0.55, 0.55, 0.58))
            fork_rgb = {"free_control": (0.6, 0.6, 0.6),
                        "boundingCube": (0.9, 0.3, 0.2),
                        "convexHull": (0.95, 0.7, 0.2),
                        "convexDecomposition": (0.2, 0.8, 0.35)}
            for tag, _a in lanes_cfg:
                pp = stage.GetPrimAtPath(f"/World/pallet_{tag}")
                if pp and pp.IsValid():
                    for p in Usd_iter(stage, pp):
                        if str(p.GetTypeName()) == "Mesh":
                            _bind(stage, str(p.GetPath()), gray)
                fm = _mat(stage, f"/World/Looks/{tag}", fork_rgb[tag])
                for yi in range(len(_FORK_YS)):
                    _bind(stage, f"/World/fork_{tag}_{yi}", fm)
            cam = UsdGeom.Camera.Define(stage, "/World/Cam")
            cam.CreateFocalLengthAttr(17.0)
            cam.CreateClippingRangeAttr(Gf.Vec2f(0.1, 100000.0))
            mid_y = (len(lanes_cfg) - 1) * _LANE_DY / 2.0
            UsdGeom.Xformable(cam.GetPrim()).AddTransformOp().Set(
                Gf.Matrix4d(*_look_at((-4.2, mid_y - 7.4, 4.0),
                                      (0.55, mid_y, 0.1))))

        world = World(stage_units_in_meters=1.0, physics_dt=1.0 / 120.0,
                      rendering_dt=1.0 / 60.0)
        world.reset()

        # readback: confirm the approximation override actually stuck on the mesh.
        for lane in result["lanes"]:
            tag = lane["lane"]
            pp = stage.GetPrimAtPath(f"/World/pallet_{tag}")
            approxes = []
            if pp and pp.IsValid():
                for p in Usd_iter(stage, pp):
                    if p.HasAPI(UsdPhysics.MeshCollisionAPI):
                        a = UsdPhysics.MeshCollisionAPI(p).GetApproximationAttr().Get()
                        approxes.append(str(a))
            lane["approximation_readback"] = approxes

        views = {k: SingleRigidPrim(v[0]) for k, v in fork_index.items()}
        for k, v in views.items():
            v.set_linear_velocity(np.array([_COAST_V, 0.0, 0.0]))
        max_x = {k: fork_index[k][1] for k in fork_index}

        if render:
            rp = rep.create.render_product("/World/Cam", (960, 540))
            annot = rep.AnnotatorRegistry.get_annotator("rgb")
            annot.attach(rp)

        def _grab():
            for _ in range(4):
                world.render()
            raw = np.asarray(annot.get_data())
            if raw.size and raw.ndim == 3:
                px = raw[:, :, :3] if raw.shape[2] == 4 else raw
                return np.ascontiguousarray(px.astype(np.uint8))
            return None

        cap_steps = set(int(round(v)) for v in
                        np.linspace(2, _TOTAL_STEPS - 1, 48)) if render else set()
        frames, nonblack = [], 0
        for step_i in range(_TOTAL_STEPS):
            # keep coasting forks at target speed until they hit something.
            for k, v in views.items():
                vx = float(np.asarray(v.get_linear_velocity()).reshape(-1)[0])
                if vx < _COAST_V * 0.9 and vx > 0.02:
                    pass  # decelerating against contact -> leave it
                cx = float(np.asarray(v.get_world_pose()[0]).reshape(-1)[0])
                if cx > max_x[k]:
                    max_x[k] = cx
            world.step(render=render)
            if render and step_i in cap_steps:
                lines = ["real pallet.usd fork insertion  (coast +x into tunnel)"]
                for tag, _a in lanes_cfg:
                    best = max(
                        max_x[(tag, yi)] + _FORK_HALF_LEN - _FRONT_FACE_X
                        for yi in range(len(_FORK_YS)))
                    ent = best > _ENTER_THRESH
                    lines.append(f"{tag:20s} depth={best:5.2f}m "
                                 f"{'ENTERED' if ent else 'blocked'}")
                rgb = _grab()
                if rgb is not None and float(rgb.mean()) > 1.0:
                    nonblack += 1
                if rgb is None:
                    rgb = np.zeros((540, 960, 3), dtype=np.uint8)
                frames.append(_overlay(rgb, lines))

        for lane in result["lanes"]:
            tag = lane["lane"]
            for yi, dy in enumerate(_FORK_YS):
                cx = max_x[(tag, yi)]
                depth = cx + _FORK_HALF_LEN - _FRONT_FACE_X
                lane["forks"].append({
                    "lateral_y": dy,
                    "max_center_x": round(cx, 4),
                    "penetration_depth_m": round(depth, 4),
                    "entered": bool(depth > _ENTER_THRESH),
                })
            lane["best_penetration_m"] = round(
                max(f["penetration_depth_m"] for f in lane["forks"]), 4)
            lane["any_entered"] = any(f["entered"] for f in lane["forks"])

        if render and frames:
            import imageio.v2 as imageio
            Path(args.mp4).parent.mkdir(parents=True, exist_ok=True)
            imageio.mimwrite(args.mp4, frames, fps=12, codec="libx264", quality=8)
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
                   help="If set, RTX-render the 3-lane insertion and encode MP4.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
