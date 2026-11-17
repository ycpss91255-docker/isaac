#!/usr/bin/env python3
"""Kit-side runner for test_capture_noise.py (isaac#266). Not collected.

Boots one headless ``SimulationApp``, builds a small lit room (a large lit
surface is what makes the speckle visible -- a nearly empty scene hides it),
and captures the SAME static scene twice through the SAME render product:

  1. as replicator creates it -- the Isaac Sim 6.0 default RealTimePathTracing,
     one path-traced sample per pixel denoised by NGX (available since
     isaac#285);
  2. after ``apply_converged_render_settings`` (inlined from the former
     ``viz_render`` module) authors the converged-still recipe on the
     RenderProduct prim.

Prints one ``[CAPTURE NOISE]`` marker line per capture. The noise metric is the
mean absolute difference between horizontally neighbouring pixels: sampling
noise dominates it, smooth shading barely registers, and unlike ``std`` it does
not move when the mode change legitimately changes the exposure of the image.
"""

import os
import sys
import traceback
from pathlib import Path

# ---------------------------------------------------------------------------
# Converged-still render recipe (inlined from the former viz_render.py,
# which moved to ycpss91255-docker/isaac_physics_test with the experiment
# drivers).  Only the subset _capture_noise_runner actually calls is kept.
# ---------------------------------------------------------------------------
_CONVERGED_RENDER_MODE = "PathTracing"
_DEFAULT_SAMPLES_PER_PIXEL = 512
CONVERGE_RENDER_TICKS = 16

_RENDER_VAR_SDF_TYPE_NAMES = {
    "omni:rtx:rendermode": "String",
    "omni:rtx:pt:samplesPerPixel": "Int",
    "omni:rtx:pt:clampSpp": "Int",
}


def _converged_still_render_vars(samples_per_pixel=_DEFAULT_SAMPLES_PER_PIXEL):
    """RenderProduct-prim attributes that make a still converge (isaac#266)."""
    budget = int(samples_per_pixel)
    if budget < 1:
        raise ValueError(
            f"samples_per_pixel must be >= 1, got {samples_per_pixel!r}"
        )
    return {
        "omni:rtx:rendermode": _CONVERGED_RENDER_MODE,
        "omni:rtx:pt:samplesPerPixel": budget,
        "omni:rtx:pt:clampSpp": budget,
    }


def apply_converged_render_settings(render_product_path, stage=None,
                                    samples_per_pixel=_DEFAULT_SAMPLES_PER_PIXEL):
    """Author the converged-still recipe on one render product's prim."""
    if stage is None:
        import omni.usd
        stage = omni.usd.get_context().get_stage()

    path = str(render_product_path)
    prim = stage.GetPrimAtPath(path)
    if not prim or not prim.IsValid():
        raise ValueError(f"no RenderProduct prim at {path!r}")

    applied = _converged_still_render_vars(samples_per_pixel)
    for name, value in applied.items():
        attr = prim.GetAttribute(name)
        if not attr:
            from pxr import Sdf
            attr = prim.CreateAttribute(
                name,
                getattr(Sdf.ValueTypeNames, _RENDER_VAR_SDF_TYPE_NAMES[name]),
            )
        attr.Set(value)
    return applied


def _look_at(eye, target, up=(0.0, 0.0, 1.0)):
    """Row-major 4x4 (flat 16) camera-to-world for a USD camera."""
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


def _room(stage):
    """Floor + three walls + one box, grey diffuse, lit by a dome and a key."""
    from pxr import Gf, Sdf, UsdGeom, UsdLux, UsdShade

    UsdGeom.Xform.Define(stage, "/World")
    stage.SetDefaultPrim(stage.GetPrimAtPath("/World"))

    def box(name, center, half):
        cube = UsdGeom.Cube.Define(stage, f"/World/{name}")
        cube.CreateSizeAttr(2.0)
        xform = UsdGeom.Xformable(cube.GetPrim())
        xform.AddTranslateOp().Set(Gf.Vec3d(*center))
        xform.AddScaleOp().Set(Gf.Vec3f(*half))
        return name

    names = [
        box("Floor", (0.0, 0.0, -0.05), (4.0, 3.0, 0.05)),
        box("WallXp", (4.05, 0.0, 1.5), (0.05, 3.0, 1.5)),
        box("WallYp", (0.0, 3.05, 1.5), (4.0, 0.05, 1.5)),
        box("BoxA", (1.4, 0.9, 0.4), (0.4, 0.4, 0.4)),
    ]

    material = UsdShade.Material.Define(stage, "/World/Looks/Grey")
    shader = UsdShade.Shader.Define(stage, "/World/Looks/Grey/S")
    shader.CreateIdAttr("UsdPreviewSurface")
    shader.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(
        Gf.Vec3f(0.6, 0.6, 0.62))
    shader.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.8)
    material.CreateSurfaceOutput().ConnectToSource(
        shader.ConnectableAPI(), "surface")
    for name in names:
        UsdShade.MaterialBindingAPI.Apply(
            stage.GetPrimAtPath(f"/World/{name}")).Bind(material)

    UsdLux.DomeLight.Define(stage, "/World/Dome").CreateIntensityAttr(400.0)
    key = UsdLux.DistantLight.Define(stage, "/World/Key")
    key.CreateIntensityAttr(1500.0)
    UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(
        Gf.Vec3f(-45.0, 15.0, 0.0))


def _camera(stage, path, eye, target):
    from pxr import Gf, UsdGeom

    cam = UsdGeom.Camera.Define(stage, path)
    cam.CreateFocalLengthAttr(18.0)
    cam.CreateClippingRangeAttr(Gf.Vec2f(0.05, 1000.0))
    xform = UsdGeom.Xformable(cam.GetPrim())
    xform.ClearXformOpOrder()
    xform.AddTransformOp().Set(Gf.Matrix4d(*_look_at(eye, target)))
    return path


def _metrics(raw):
    import numpy as np

    arr = np.asarray(raw)
    if not arr.size or arr.ndim != 3:
        return None
    px = arr[:, :, :3] if arr.shape[2] == 4 else arr
    rgb = np.ascontiguousarray(px.astype(np.uint8))
    grey = rgb.astype(np.float64).mean(axis=2)
    return {
        "noise": float(np.abs(np.diff(grey, axis=1)).mean()),
        "std": float(rgb.std()),
        "black": float((rgb.max(axis=2) < 8).mean()),
    }


def main():
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})
    failed = False

    try:
        import omni.replicator.core as rep
        import omni.timeline
        import omni.usd

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()
        _room(stage)
        cam = _camera(stage, "/World/NoiseCam", (-2.8, -2.3, 1.9),
                      (1.4, 0.9, 0.7))

        omni.timeline.get_timeline_interface().play()
        for _ in range(60):
            app.update()

        width, height = 640, 360
        # Deliberately the RAW replicator call, not the repo's
        # create_converged_render_product: this leg IS the defect.
        render_product = rep.create.render_product(cam, (width, height))
        rp_path = str(render_product.path)
        annot = rep.AnnotatorRegistry.get_annotator("rgb")
        annot.attach(render_product)
        prim = stage.GetPrimAtPath(rp_path)

        def report(label):
            for _ in range(CONVERGE_RENDER_TICKS * 2):
                app.update()
            metrics = _metrics(annot.get_data())
            assert metrics is not None, f"empty annotator data for {label}"
            mode = prim.GetAttribute("omni:rtx:rendermode").Get()
            print(
                f"[CAPTURE NOISE] leg={label} mode={mode} "
                f"noise={metrics['noise']:.4f} std={metrics['std']:.4f} "
                f"black={metrics['black']:.6f}",
                flush=True,
            )

        report("default")
        apply_converged_render_settings(rp_path, stage=stage)
        report("converged")

    except Exception:  # noqa: BLE001
        traceback.print_exc()
        failed = True
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        try:
            app.close()
        except Exception:  # noqa: BLE001
            pass
        # 6.0.1 cold shutdown can abort a TaskGroup on the way out and mask
        # the real exit status (isaac#248).
        os._exit(1 if failed else 0)


if __name__ == "__main__":
    main()
