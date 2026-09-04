#!/usr/bin/env python3
"""Shared RTX-render + MP4 helpers for the motion experiment drivers.

The headless 6.0.1 container has no NGX/DLSS denoiser, so path-traced frames come
out grainy. This module centralises the clean-frame recipe used by the L2.5 carry
viz and the collision decomp-pocket viz: real-time raster mode, stochastic effects
(GI / AO / reflections / sampled + dome IBL lighting) OFF, two deterministic
directional lights, and N accumulation renders per capture. Drivers add a thin
``--mp4`` path: author materials + a camera, then step with render=True and call
:func:`Capturer.grab` at the frames they want, overlay a per-frame data HUD, and
:func:`encode_mp4` the result.

Not a standalone script (no __main__); imported by the exp_* drivers.
"""

import math


def apply_clean_render_settings():
    """Real-time raster + stochastic effects off (no denoiser in headless)."""
    import carb

    s = carb.settings.get_settings()
    s.set("/rtx/post/histogram/enabled", False)
    s.set("/rtx/rendermode", "RaytracedLighting")
    s.set("/rtx/indirectDiffuse/enabled", False)
    s.set("/rtx/ambientOcclusion/enabled", False)
    s.set("/rtx/reflections/enabled", False)
    s.set("/rtx/directLighting/sampledLighting/enabled", False)


def add_fill_lights(stage, root="/World"):
    """Two directional lights (deterministic, clean) -- no dome IBL speckle."""
    from pxr import Gf, UsdGeom, UsdLux

    key = UsdLux.DistantLight.Define(stage, f"{root}/VizKey")
    key.CreateIntensityAttr(3000.0)
    UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(Gf.Vec3f(-45.0, 15.0, 0.0))
    fill = UsdLux.DistantLight.Define(stage, f"{root}/VizFill")
    fill.CreateIntensityAttr(1500.0)
    UsdGeom.Xformable(fill.GetPrim()).AddRotateXYZOp().Set(Gf.Vec3f(-30.0, 40.0, 0.0))


def look_at(eye, target, up=(0.0, 0.0, 1.0)):
    """Row-major 4x4 (flat 16) camera-to-world for a USD camera looking at target."""
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


def make_camera(stage, path, eye, target, focal=20.0):
    from pxr import Gf, UsdGeom

    cam = UsdGeom.Camera.Define(stage, path)
    cam.CreateFocalLengthAttr(focal)
    cam.CreateClippingRangeAttr(Gf.Vec2f(0.1, 100000.0))
    UsdGeom.Xformable(cam.GetPrim()).AddTransformOp().Set(
        Gf.Matrix4d(*look_at(eye, target))
    )
    return path


def material(stage, path, rgb):
    from pxr import Gf, Sdf, UsdShade

    m = UsdShade.Material.Define(stage, path)
    s = UsdShade.Shader.Define(stage, path + "/S")
    s.CreateIdAttr("UsdPreviewSurface")
    s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
    s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.5)
    m.CreateSurfaceOutput().ConnectToSource(s.ConnectableAPI(), "surface")
    return m


def bind(stage, prim_path, mat):
    from pxr import UsdShade

    UsdShade.MaterialBindingAPI.Apply(stage.GetPrimAtPath(prim_path)).Bind(mat)


def _font(size):
    from PIL import ImageFont

    try:
        return ImageFont.truetype(
            "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", size)
    except Exception:  # noqa: BLE001
        return ImageFont.load_default()


def overlay(rgb, lines):
    """Draw HUD lines onto an HxWx3 uint8 frame; return a numpy array."""
    import numpy as np
    from PIL import Image, ImageDraw

    img = Image.fromarray(rgb, mode="RGB").convert("RGB")
    d = ImageDraw.Draw(img)
    f = _font(20)
    d.rectangle([6, 6, 640, 6 + 26 * len(lines) + 10], fill=(0, 0, 0))
    y = 12
    for ln in lines:
        d.text((14, y), ln, fill=(240, 240, 60), font=f)
        y += 26
    return np.asarray(img)


class Capturer:
    """Attach an rgb annotator to a camera; grab converged frames on demand."""

    def __init__(self, world, cam_path, width, height, accumulate=16):
        import omni.replicator.core as rep

        self.world = world
        self.accumulate = accumulate
        self._rp = rep.create.render_product(cam_path, (width, height))
        self._annot = rep.AnnotatorRegistry.get_annotator("rgb")
        self._annot.attach(self._rp)
        self.width = width
        self.height = height

    def grab(self):
        import numpy as np

        for _ in range(self.accumulate):
            self.world.render()
        raw = np.asarray(self._annot.get_data())
        if raw.size and raw.ndim == 3:
            px = raw[:, :, :3] if raw.shape[2] == 4 else raw
            return np.ascontiguousarray(px.astype(np.uint8))
        return None

    def detach(self):
        try:
            self._annot.detach()
        except Exception:  # noqa: BLE001
            pass


def encode_mp4(path, frames, fps=15):
    """Encode a list of HxWx3 uint8 frames to an H.264 MP4 (imageio-ffmpeg)."""
    from pathlib import Path

    import imageio.v2 as imageio

    if not frames:
        return None
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    imageio.mimwrite(path, frames, fps=fps, codec="libx264", quality=8)
    return path
