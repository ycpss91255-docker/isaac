#!/usr/bin/env python3
"""Visual + metric acceptance re-validation on Isaac Sim 6.0.1 (isaac#209).

Issue #209 (sub-issue of the #205 end-to-end milestone) asks for two things on the
representative model, carried from the milestone A/B acceptance criteria:

  (a) VISUAL plausibility -- a real RTX-rendered frame that actually contains lit
      geometry, i.e. NOT a black frame and NOT a flat fill. This is the classic
      headless-rendering trap: a driver "runs" but the render product never
      converges and every downstream visual test silently passes on a black image.
  (b) METRIC acceptance -- the quantitative facts about the scene are what we
      authored: the prim hierarchy has the expected shape/counts, key prims sit at
      the expected world poses / dimensions, and the acceptance camera actually
      frames the model (the model projects INSIDE the camera frustum).

Because the #205 parent is BLOCKED on a real CAD model, this re-validation does NOT
ship a real-robot 5.1 baseline. Instead it builds a fully self-contained, byte-
deterministic representative scene (no external asset -- same discipline as
``stream_source_producer.py``, isaac#223): the producer's proven non-black stage
(dome + distant key light + a 12x12 checkerboard floor) with a recognizable
forklift-shaped robot assembly (base + mast + two forks, distinctly coloured) placed
on it. Every dimension and pose is authored here, so the METRIC expectations are
exact and the pass/fail is unambiguous. This is the visual+metric HARNESS; when the
real CAD lands under #205 the same two-part acceptance (non-black frame + authored-
fact check + camera framing) applies unchanged to the real USD.

What it proves on 6.0.1:
  - RTX renders real geometry headless: an ``omni.replicator.core`` rgb annotator on
    a render product from our own acceptance camera returns a frame whose mean
    luminance, non-black pixel fraction, and per-channel variance are all well above
    "black / flat fill" -- captured to a MOUNTED PNG so a human can eyeball it.
  - The stage matches the authored contract: counts of Cube gprims / lights /
    cameras / materials under /World are exactly what we built.
  - Key prims are where we put them: the robot base world pose and the whole-robot
    world-aligned bounding box extents match the authored values within eps.
  - Camera framing: the robot centroid and bbox project INSIDE the acceptance
    camera's frustum (Gf.Frustum built from the USD camera), and its image-plane NDC
    is reported so the framing is auditable.

5.1 baseline / expectation: none committed for a real robot (parent blocked on CAD).
For this deterministic harness the expectation is a NON-BLACK frame (mean luminance
well above 0, non-black fraction > 0.5, per-channel std well above a flat fill) and
authored-fact metrics matching within eps -- a first-run 6.0.1 characterization of
the visual+metric acceptance path itself.

Results are written as JSON to ``--out`` (a MOUNTED path) plus a PNG frame to
``--png`` (also MOUNTED) so the host reads both back; stdout through the docker run
wrapper is not reliably captured. Teardown is an explicit ``os._exit`` (isaac#248
round 9): a cold headless 6.0.1 container's Omniverse Hub connector aborts
``SimulationApp.close()`` with a busy-TaskGroup SIGABRT; ``os._exit`` reaches the
same clean exit while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_visual_metric_acceptance.py \\
        --out /home/<user>/work/worktree/<wt>/test/.visual-metric.json \\
        --png /home/<user>/work/worktree/<wt>/test/visual_metric_frame.png \\
        [--width 1280] [--height 720] [--warmup 90]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

# ── Authored scene contract (single source of truth for the metric checks) ──
N_TILES = 12
TILE_M = 1.0

# Robot parts: (name, dims (sx,sy,sz), center (x,y,z), colour rgb).
ROBOT_PARTS = [
    ("base", (0.80, 0.50, 0.30), (0.00, 0.00, 0.15), (0.80, 0.12, 0.10)),
    ("mast", (0.12, 0.40, 1.20), (0.34, 0.00, 0.75), (0.10, 0.25, 0.80)),
    ("fork_left", (0.60, 0.08, 0.05), (0.60, -0.12, 0.075), (0.90, 0.80, 0.10)),
    ("fork_right", (0.60, 0.08, 0.05), (0.60, 0.12, 0.075), (0.90, 0.80, 0.10)),
]

# Expected /World prim inventory (exact, from what _build_scene authors).
EXPECT_CUBES = N_TILES * N_TILES + len(ROBOT_PARTS)  # 144 tiles + 4 parts = 148
EXPECT_LIGHTS = 2   # dome + distant key
EXPECT_CAMERAS = 1  # the acceptance camera
EXPECT_MATERIALS = 2 + 3  # 2 tile materials + 3 robot colours (yellow shared)

# Acceptance camera framing (eye/target pulled to frame the whole robot + floor).
CAM_EYE = (5.5, -5.5, 3.6)
CAM_TARGET = (0.25, 0.0, 0.55)
ROBOT_CENTROID = (0.25, 0.0, 0.55)

# Visual (frame) acceptance thresholds -- a real lit render clears these by a wide
# margin; a black frame / flat fill fails at least one.
MIN_MEAN_LUM = 12.0        # 0..255; black frame ~0
MAX_MEAN_LUM = 245.0       # not a blown-out white fill
MIN_NONBLACK_FRAC = 0.50   # majority of pixels carry light
MIN_CHANNEL_STD = 10.0     # spatial/colour variance => geometry+shading, not flat
MIN_LUM_SPAN = 40.0        # max-min luminance => real dynamic range

EPS_POS = 2.0e-3           # 2 mm pose tolerance
EPS_DIM = 1.0e-2           # 1 cm extent tolerance


# ── Small vector helpers (host-safe, no Isaac import) ───────────────────────
def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )


def _norm(a):
    n = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
    return (a[0] / n, a[1] / n, a[2] / n) if n else a


def _look_at_transform(eye, target, up=(0.0, 0.0, 1.0)):
    """Row-major 4x4 (list of 16) camera-to-world for a USD camera.

    USD cameras look down local -Z with +Y up, so camera +Z = normalize(eye-target).
    Returns a flat row-major matrix suitable for Gf.Matrix4d(*rows).
    """
    z = _norm(_sub(eye, target))
    x = _norm(_cross(up, z))
    y = _cross(z, x)
    # Gf.Matrix4d is ROW-major and USD applies row-vector * matrix, so the basis
    # vectors go in the ROWS and the translation in the last row.
    return [
        x[0], x[1], x[2], 0.0,
        y[0], y[1], y[2], 0.0,
        z[0], z[1], z[2], 0.0,
        eye[0], eye[1], eye[2], 1.0,
    ]


def _build_scene(stage):
    """Author the deterministic representative scene; return handles/paths.

    Reuses the producer's non-black lit stage (dome + distant key + checkerboard)
    and adds the forklift-shaped robot assembly. Every count/pose/dim here is what
    the metric checks assert against.
    """
    from pxr import Gf, Sdf, UsdGeom, UsdLux, UsdPhysics, UsdShade

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    scene = UsdPhysics.Scene.Define(stage, "/physicsScene")
    scene.CreateGravityDirectionAttr().Set((0.0, 0.0, -1.0))
    scene.CreateGravityMagnitudeAttr().Set(9.81)

    UsdGeom.Xform.Define(stage, "/World")

    dome = UsdLux.DomeLight.Define(stage, "/World/DomeLight")
    dome.CreateIntensityAttr(250.0)
    key = UsdLux.DistantLight.Define(stage, "/World/KeyLight")
    key.CreateIntensityAttr(700.0)
    key.CreateAngleAttr(0.53)
    UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(
        Gf.Vec3f(-45.0, 30.0, 0.0)
    )

    def _mat(path, rgb, rough=0.7):
        m = UsdShade.Material.Define(stage, path)
        s = UsdShade.Shader.Define(stage, path + "/Shader")
        s.CreateIdAttr("UsdPreviewSurface")
        s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(
            Gf.Vec3f(*rgb)
        )
        s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(rough)
        s.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
        m.CreateSurfaceOutput().ConnectToSource(s.ConnectableAPI(), "surface")
        return m

    light_tile = _mat("/World/Looks/TileLight", (0.62, 0.62, 0.64))
    dark_tile = _mat("/World/Looks/TileDark", (0.15, 0.15, 0.17))

    UsdGeom.Xform.Define(stage, "/World/Ground")
    half = N_TILES * TILE_M / 2.0
    for i in range(N_TILES):
        for j in range(N_TILES):
            t = UsdGeom.Cube.Define(stage, f"/World/Ground/tile_{i}_{j}")
            t.CreateSizeAttr(1.0)
            tx = UsdGeom.Xformable(t.GetPrim())
            cx = -half + (i + 0.5) * TILE_M
            cy = -half + (j + 0.5) * TILE_M
            tx.AddTranslateOp().Set(Gf.Vec3d(cx, cy, -0.01))
            tx.AddScaleOp().Set(Gf.Vec3f(TILE_M, TILE_M, 0.02))
            UsdShade.MaterialBindingAPI.Apply(t.GetPrim()).Bind(
                light_tile if (i + j) % 2 == 0 else dark_tile
            )

    # Robot colours (yellow shared by both forks -> 3 distinct materials).
    red = _mat("/World/Looks/RobotRed", ROBOT_PARTS[0][3])
    blue = _mat("/World/Looks/RobotBlue", ROBOT_PARTS[1][3])
    yellow = _mat("/World/Looks/RobotYellow", ROBOT_PARTS[2][3])
    part_mat = {"base": red, "mast": blue, "fork_left": yellow,
                "fork_right": yellow}

    UsdGeom.Xform.Define(stage, "/World/Robot")
    for name, dims, ctr, _rgb in ROBOT_PARTS:
        c = UsdGeom.Cube.Define(stage, f"/World/Robot/{name}")
        c.CreateSizeAttr(1.0)
        cx = UsdGeom.Xformable(c.GetPrim())
        cx.AddTranslateOp().Set(Gf.Vec3d(*ctr))
        cx.AddScaleOp().Set(Gf.Vec3f(*dims))
        UsdShade.MaterialBindingAPI.Apply(c.GetPrim()).Bind(part_mat[name])

    # Acceptance camera (our own prim -> deterministic, no reliance on the
    # experience's default persp cam).
    cam = UsdGeom.Camera.Define(stage, "/World/AcceptanceCam")
    cam.CreateFocalLengthAttr(24.0)
    cam.CreateHorizontalApertureAttr(36.0)
    cam.CreateVerticalApertureAttr(20.25)
    cam.CreateClippingRangeAttr(Gf.Vec2f(0.1, 100000.0))
    xf = UsdGeom.Xformable(cam.GetPrim())
    m = Gf.Matrix4d(*_look_at_transform(CAM_EYE, CAM_TARGET))
    xf.AddTransformOp().Set(m)

    return "/World/AcceptanceCam"


def _count_inventory(stage):
    """Count typed prims under /World for the hierarchy metric."""
    from pxr import UsdGeom, UsdLux, UsdShade

    cubes = lights = cameras = materials = 0
    total = 0
    for prim in stage.Traverse():
        path = str(prim.GetPath())
        if not path.startswith("/World"):
            continue
        total += 1
        if prim.IsA(UsdGeom.Cube):
            cubes += 1
        if prim.IsA(UsdGeom.Camera):
            cameras += 1
        if prim.IsA(UsdShade.Material):
            materials += 1
        # Lights carry the LightAPI; count the two concrete light prims.
        if prim.IsA(UsdLux.DomeLight) or prim.IsA(UsdLux.DistantLight):
            lights += 1
    return {
        "total_world_prims": total,
        "cubes": cubes,
        "lights": lights,
        "cameras": cameras,
        "materials": materials,
    }


def _world_pose_and_bbox(stage, path):
    """World translation + world-aligned bbox (min, max, extent) for a prim."""
    from pxr import Gf, Usd, UsdGeom

    prim = stage.GetPrimAtPath(path)
    xf = UsdGeom.Xformable(prim)
    l2w = xf.ComputeLocalToWorldTransform(Usd.TimeCode.Default())
    trans = l2w.ExtractTranslation()
    cache = UsdGeom.BBoxCache(
        Usd.TimeCode.Default(), [UsdGeom.Tokens.default_, UsdGeom.Tokens.render]
    )
    rng = cache.ComputeWorldBound(prim).ComputeAlignedRange()
    mn, mx = rng.GetMin(), rng.GetMax()
    return {
        "world_pos": [trans[0], trans[1], trans[2]],
        "bbox_min": [mn[0], mn[1], mn[2]],
        "bbox_max": [mx[0], mx[1], mx[2]],
        "extent": [mx[0] - mn[0], mx[1] - mn[1], mx[2] - mn[2]],
    }


def _camera_framing(stage, cam_path, points):
    """Project world points through the USD camera frustum -> NDC + in-frame flag.

    Returns per-point NDC (x,y in [-1,1] when in frame) and a bbox-in-frustum flag.
    """
    from pxr import Gf, Usd, UsdGeom

    cam_prim = stage.GetPrimAtPath(cam_path)
    gf_cam = UsdGeom.Camera(cam_prim).GetCamera(Usd.TimeCode.Default())
    frustum = gf_cam.frustum
    view = frustum.ComputeViewMatrix()
    proj = frustum.ComputeProjectionMatrix()
    vp = view * proj

    out = []
    for name, p in points:
        h = vp.Transform(Gf.Vec3d(*p))  # perspective divide done by Transform
        ndc_x, ndc_y = h[0], h[1]
        in_frame = (-1.0 <= ndc_x <= 1.0) and (-1.0 <= ndc_y <= 1.0)
        out.append({
            "name": name,
            "ndc": [ndc_x, ndc_y],
            "in_frame": bool(in_frame),
        })
    return out


def _capture_rgb(app, cam_path, width, height, warmup):
    """Attach an rgb annotator to a render product on cam_path; return HxWx3 uint8.

    Canonical headless offline-render path: replicator drives its own RTX render
    product, so a bare ``SimulationApp({'headless': True})`` renders real frames.
    """
    import numpy as np
    import omni.replicator.core as rep

    rp = rep.create.render_product(cam_path, (width, height))
    annot = rep.AnnotatorRegistry.get_annotator("rgb")
    annot.attach(rp)

    data = None
    # Give RTX time to load materials + converge, then read; retry if empty.
    for attempt in range(3):
        for _ in range(warmup):
            app.update()
        raw = annot.get_data()
        arr = np.asarray(raw)
        if arr.size and arr.ndim >= 2 and arr.shape[0] == height:
            data = arr
            break
        warmup = 30  # shorter top-ups on retry

    if data is None:
        raise RuntimeError(
            f"rgb annotator returned empty data after retries "
            f"(shape={None if data is None else data.shape})"
        )

    if data.ndim == 3 and data.shape[2] == 4:
        data = data[:, :, :3]
    return np.ascontiguousarray(data.astype(np.uint8))


def _frame_stats(rgb):
    """Compute the visual-acceptance statistics on an HxWx3 uint8 frame."""
    import numpy as np

    r = rgb[:, :, 0].astype(np.float64)
    g = rgb[:, :, 1].astype(np.float64)
    b = rgb[:, :, 2].astype(np.float64)
    lum = 0.2126 * r + 0.7152 * g + 0.0722 * b

    nonblack = float((lum > 8.0).mean())
    per_ch_std = [float(r.std()), float(g.std()), float(b.std())]
    uniq = int(np.unique(rgb.reshape(-1, 3), axis=0).shape[0])

    return {
        "shape": list(rgb.shape),
        "mean_luminance": float(lum.mean()),
        "min_luminance": float(lum.min()),
        "max_luminance": float(lum.max()),
        "luminance_span": float(lum.max() - lum.min()),
        "nonblack_fraction": nonblack,
        "per_channel_std": per_ch_std,
        "min_channel_std": float(min(per_ch_std)),
        "mean_rgb": [float(r.mean()), float(g.mean()), float(b.mean())],
        "unique_colours": uniq,
    }


def _frame_verdict(stats):
    """Apply the non-black / non-flat thresholds; return (ok, reasons)."""
    checks = {
        "mean_luminance_in_range": (
            MIN_MEAN_LUM <= stats["mean_luminance"] <= MAX_MEAN_LUM
        ),
        "nonblack_fraction_ok": stats["nonblack_fraction"] >= MIN_NONBLACK_FRAC,
        "channel_variance_ok": stats["min_channel_std"] >= MIN_CHANNEL_STD,
        "luminance_span_ok": stats["luminance_span"] >= MIN_LUM_SPAN,
    }
    return all(checks.values()), checks


def _save_png(rgb, path):
    from PIL import Image

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(rgb, mode="RGB").save(path)


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "issue": "isaac#209",
        "parent": "isaac#205",
        "title": "visual + metric acceptance",
        "isaac_variant": "6.0.1",
        "scene": (
            "self-contained deterministic representative scene: producer non-black "
            "lit stage (dome + distant key + 12x12 checkerboard) + forklift-shaped "
            "robot (base + mast + 2 forks) -- no external asset (isaac#223 discipline)"
        ),
        "baseline_5_1": (
            "none committed -- parent #205 blocked on real CAD; this is a first-run "
            "6.0.1 characterization of the visual+metric acceptance harness itself"
        ),
        "png_path": args.png,
        "frame": None,
        "frame_checks": None,
        "frame_ok": None,
        "inventory": None,
        "inventory_expected": {
            "cubes": EXPECT_CUBES, "lights": EXPECT_LIGHTS,
            "cameras": EXPECT_CAMERAS, "materials": EXPECT_MATERIALS,
        },
        "inventory_ok": None,
        "key_prims": None,
        "key_prims_ok": None,
        "camera_framing": None,
        "camera_framing_ok": None,
        "accept": None,
        "error": None,
    }

    try:
        import carb
        import omni.timeline
        import omni.usd

        carb.settings.get_settings().set("/rtx/post/histogram/enabled", False)

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        cam_path = _build_scene(stage)

        timeline = omni.timeline.get_timeline_interface()
        timeline.play()
        for _ in range(30):
            app.update()

        # (a) VISUAL: capture a real RTX frame and score it.
        rgb = _capture_rgb(app, cam_path, args.width, args.height, args.warmup)
        _save_png(rgb, args.png)
        stats = _frame_stats(rgb)
        frame_ok, frame_checks = _frame_verdict(stats)
        result["frame"] = stats
        result["frame_checks"] = frame_checks
        result["frame_ok"] = bool(frame_ok)

        # (b) METRIC: prim inventory.
        inv = _count_inventory(stage)
        inv_ok = (
            inv["cubes"] == EXPECT_CUBES
            and inv["lights"] == EXPECT_LIGHTS
            and inv["cameras"] == EXPECT_CAMERAS
            and inv["materials"] == EXPECT_MATERIALS
        )
        result["inventory"] = inv
        result["inventory_ok"] = bool(inv_ok)

        # (b) METRIC: key prim poses/dimensions vs authored contract.
        base = _world_pose_and_bbox(stage, "/World/Robot/base")
        robot = _world_pose_and_bbox(stage, "/World/Robot")

        def _close(a, b, eps):
            return all(abs(x - y) <= eps for x, y in zip(a, b))

        base_pos_ok = _close(base["world_pos"], list(ROBOT_PARTS[0][2]), EPS_POS)
        base_dim_ok = _close(base["extent"], list(ROBOT_PARTS[0][1]), EPS_DIM)
        # Whole-robot extent: forks reach x=0.9, base back x=-0.4 -> ~1.3 in x;
        # y spans fork outer edges; z from floor tile top to mast top ~1.35.
        robot_extent_ok = (
            robot["extent"][0] > 1.2
            and robot["extent"][2] > 1.30
            and abs(robot["bbox_max"][2] - 1.35) <= 5.0e-2
        )
        key_prims = {
            "base": base,
            "base_pos_ok": bool(base_pos_ok),
            "base_dim_ok": bool(base_dim_ok),
            "robot_assembly": robot,
            "robot_extent_ok": bool(robot_extent_ok),
            "authored": {
                "base_pos": list(ROBOT_PARTS[0][2]),
                "base_dims": list(ROBOT_PARTS[0][1]),
                "mast_top_z": 0.75 + 0.60,
            },
        }
        key_ok = base_pos_ok and base_dim_ok and robot_extent_ok
        result["key_prims"] = key_prims
        result["key_prims_ok"] = bool(key_ok)

        # (b) METRIC: camera framing -- model projects inside the frustum.
        framing = _camera_framing(stage, cam_path, [
            ("robot_centroid", ROBOT_CENTROID),
            ("base_pos", ROBOT_PARTS[0][2]),
            ("mast_top", (0.34, 0.0, 1.35)),
            ("fork_tip", (0.90, 0.0, 0.075)),
        ])
        framing_ok = all(p["in_frame"] for p in framing)
        result["camera_framing"] = framing
        result["camera_framing_ok"] = bool(framing_ok)

        result["accept"] = bool(
            frame_ok and inv_ok and key_ok and framing_ok
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
    p.add_argument("--png", required=True, help="RGB frame PNG path (mounted).")
    p.add_argument("--width", type=int, default=1280, help="Render width.")
    p.add_argument("--height", type=int, default=720, help="Render height.")
    p.add_argument("--warmup", type=int, default=90,
                   help="app.update() ticks before reading the rgb annotator.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
