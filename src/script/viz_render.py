#!/usr/bin/env python3
"""Shared RTX-render + MP4 helpers for the motion experiment drivers.

The headless 6.0.1 container cannot create an NGX context, so nothing denoises
the renderer's default one-sample-per-pixel output. This module centralises the
clean-frame recipe: the converged-still render settings authored on each render
product (:func:`apply_converged_render_settings`, isaac#266), two deterministic
directional lights, and N accumulation renders per capture. Drivers add a thin
``--mp4`` path: author materials + a camera, then step with render=True and call
:func:`Capturer.grab` at the frames they want, overlay a per-frame data HUD, and
:func:`encode_mp4` the result.

Not a standalone script (no __main__); imported by the exp_* drivers. Every
Isaac import is function-local, so the recipe below is readable on a bare host.
"""

import math

# --------------------------------------------------------------------------
# Converged-still render settings (isaac#266)
# --------------------------------------------------------------------------
# Isaac Sim 6.0.1 boots the RealTimePathTracing render mode -- which is what
# "RTX Real-Time" now means. It path-traces ONE sample per pixel per frame and
# leans on NGX / DLSS ray reconstruction to clean the result. The headless
# container logs "Failed to create NGX context" on every boot, so nothing
# denoises that single sample and the rgb annotator hands back raw noise.
#
# The lever is NOT a carb setting. A render product's RTX settings are authored
# on its RenderProduct PRIM as ``omni:rtx:*`` USD attributes; the global
# ``/rtx/*`` carb keys only seed a product when it is created. Writing them
# afterwards changes nothing -- which is why every render knob tried in
# isaac#266 left the frame statistically, and twice byte-, identical.
# ``/rtx/rendermode`` also REJECTS "RaytracedLighting" on 6.0.1: the write is
# silently dropped and the mode stays RealTimePathTracing.
#
# PathTracing is the mode that ACCUMULATES: each render adds
# ``omni:rtx:pt:samplesPerIteration`` (64) samples until
# ``omni:rtx:pt:samplesPerPixel`` is reached, restarting whenever the scene or
# the camera moves. ``omni:rtx:pt:clampSpp`` is the ceiling and defaults to 64,
# so it has to be raised alongside the budget or the budget is ignored.
#
# Measured on the isaac#266 repro room (640x360; noise metric = mean absolute
# difference between horizontally neighbouring pixels, which a smooth shading
# gradient barely registers on):
#
#   RealTimePathTracing (default)  noise 53.0   black_fraction 0.068
#   PathTracing,  64 spp           noise  7.3   black_fraction 0.0
#   PathTracing, 512 spp           noise  2.1   black_fraction 0.0
#
# How much of the budget a capture actually spends depends on whether the scene
# holds still between renders. ``world.render()`` does not advance physics, so
# an MP4 frame accumulates the full budget while the sim is paused. A capture
# driven by ``app.update()`` on a PLAYING timeline moves the scene every tick
# and restarts accumulation, so it lands at one iteration -- 64 spp, the second
# row above. That is still an order of magnitude off the default mode, which is
# why the recipe is worth applying either way; stopping the timeline before the
# read is what buys the rest.
#
# Raising ``samplesPerIteration`` to force one-shot convergence does NOT work:
# at 512 samples in a single 1280x720 iteration the render never completes
# inside a normal warmup and the annotator returns a black frame.
CONVERGED_RENDER_MODE = "PathTracing"

# 512 spp = 8 accumulation renders at the default 64 samples per iteration.
DEFAULT_SAMPLES_PER_PIXEL = 512

# Renders to spin after a scene change before the annotator holds a converged
# frame: 8 to burn the budget plus margin for the annotator's own lag.
CONVERGE_RENDER_TICKS = 16

# Sdf type per recipe key, used only when a render product does not already
# carry the attribute (a replicator product authors all three at creation).
RENDER_VAR_SDF_TYPE_NAMES = {
    "omni:rtx:rendermode": "String",
    "omni:rtx:pt:samplesPerPixel": "Int",
    "omni:rtx:pt:clampSpp": "Int",
}


def converged_still_render_vars(samples_per_pixel=DEFAULT_SAMPLES_PER_PIXEL):
    """RenderProduct-prim attributes that make a still converge (isaac#266).

    Pure: returns the ``omni:rtx:*`` attribute -> value mapping, no Isaac
    import. See the module comment for why these are prim attributes and not
    ``/rtx/*`` carb keys.
    """
    budget = int(samples_per_pixel)
    if budget < 1:
        raise ValueError(
            f"samples_per_pixel must be >= 1, got {samples_per_pixel!r}"
        )
    return {
        "omni:rtx:rendermode": CONVERGED_RENDER_MODE,
        "omni:rtx:pt:samplesPerPixel": budget,
        "omni:rtx:pt:clampSpp": budget,
    }


def apply_converged_render_settings(render_product_path, stage=None,
                                    samples_per_pixel=DEFAULT_SAMPLES_PER_PIXEL):
    """Author the converged-still recipe on one render product's prim.

    ``stage`` defaults to the current USD context stage. Returns the mapping
    that was applied. Raises ``ValueError`` if the path is not a live prim --
    a silent miss here reads as "the fix did nothing".
    """
    if stage is None:
        import omni.usd

        stage = omni.usd.get_context().get_stage()

    path = str(render_product_path)
    prim = stage.GetPrimAtPath(path)
    if not prim or not prim.IsValid():
        raise ValueError(f"no RenderProduct prim at {path!r}")

    applied = converged_still_render_vars(samples_per_pixel)
    for name, value in applied.items():
        attr = prim.GetAttribute(name)
        if not attr:
            from pxr import Sdf

            attr = prim.CreateAttribute(
                name, getattr(Sdf.ValueTypeNames, RENDER_VAR_SDF_TYPE_NAMES[name])
            )
        attr.Set(value)
    return applied


def create_converged_render_product(cam_path, width, height,
                                    samples_per_pixel=DEFAULT_SAMPLES_PER_PIXEL):
    """``rep.create.render_product`` + the converged-still recipe.

    The one way to make a render product in this repo. Creating one without
    the recipe silently reintroduces isaac#266 for whatever it captures.
    """
    import omni.replicator.core as rep

    render_product = rep.create.render_product(cam_path, (width, height))
    apply_converged_render_settings(
        render_product.path, samples_per_pixel=samples_per_pixel
    )
    return render_product


def apply_clean_render_settings():
    """Global stochastic-effect knobs, applied before any product is made.

    These are carb DEFAULTS: they only reach a render product created after
    this call. The render mode is deliberately absent -- it is per product
    (:func:`apply_converged_render_settings`), and the carb write for it is
    rejected outright on 6.0.1.
    """
    import carb

    s = carb.settings.get_settings()
    s.set("/rtx/post/histogram/enabled", False)
    s.set("/rtx/indirectDiffuse/enabled", False)
    s.set("/rtx/ambientOcclusion/enabled", False)
    s.set("/rtx/reflections/enabled", False)
    s.set("/rtx/directLighting/sampledLighting/enabled", False)
    s.set("/rtx/shadows/enabled", False)
    s.set("/rtx/post/aa/op", 2)   # spatial FXAA -> no per-frame temporal jitter


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


def material(stage, path, rgb, flat=True):
    """UsdPreviewSurface. flat/unlit (default) = diffuse 0 + emissive rgb: the
    surface emits its own colour, bypassing the per-pixel denoiser-less lighting
    integral -> deterministic clean flat colour (no salt-and-pepper). Also hide
    any huge ground plane (grazing-angle aliasing) rather than lighting it."""
    from pxr import Gf, Sdf, UsdShade

    m = UsdShade.Material.Define(stage, path)
    s = UsdShade.Shader.Define(stage, path + "/S")
    s.CreateIdAttr("UsdPreviewSurface")
    diffuse = (0.0, 0.0, 0.0) if flat else rgb
    s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*diffuse))
    s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(1.0)
    s.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
    if flat:
        s.CreateInput("emissiveColor", Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(*rgb))
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

    def __init__(self, world, cam_path, width, height,
                 accumulate=CONVERGE_RENDER_TICKS):
        import omni.replicator.core as rep

        self.world = world
        self.accumulate = accumulate
        self._rp = create_converged_render_product(cam_path, width, height)
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
