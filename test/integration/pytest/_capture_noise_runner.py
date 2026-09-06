#!/usr/bin/env python3
"""Kit-side runner for test_capture_noise.py (isaac#266). Not collected.

Boots one headless ``SimulationApp``, builds a small lit room (a large lit
surface is what makes the speckle visible -- a nearly empty scene hides it),
and captures the SAME static scene twice through the SAME render product:

  1. as replicator creates it -- the Isaac Sim 6.0 default RealTimePathTracing,
     one path-traced sample per pixel with an NGX denoiser the headless
     container cannot create;
  2. after ``viz_render.apply_converged_render_settings`` authors the
     converged-still recipe on the RenderProduct prim.

Prints one ``[CAPTURE NOISE]`` marker line per capture. The noise metric is the
mean absolute difference between horizontally neighbouring pixels: sampling
noise dominates it, smooth shading barely registers, and unlike ``std`` it does
not move when the mode change legitimately changes the exposure of the image.
"""

import os
import sys
import traceback
from pathlib import Path

_SCRIPT_DIR = Path(__file__).resolve().parents[3] / "src" / "script"
if str(_SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIR))


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
    import viz_render as vr
    from pxr import Gf, UsdGeom

    cam = UsdGeom.Camera.Define(stage, path)
    cam.CreateFocalLengthAttr(18.0)
    cam.CreateClippingRangeAttr(Gf.Vec2f(0.05, 1000.0))
    xform = UsdGeom.Xformable(cam.GetPrim())
    xform.ClearXformOpOrder()
    xform.AddTransformOp().Set(Gf.Matrix4d(*vr.look_at(eye, target)))
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

        import viz_render as vr

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
            for _ in range(vr.CONVERGE_RENDER_TICKS * 2):
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
        vr.apply_converged_render_settings(rp_path, stage=stage)
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
