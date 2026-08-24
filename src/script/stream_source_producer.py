"""Deterministic WebRTC stream-source producer for the owv visual e2e.

isaac#223  -- publish this as a pullable, pinned GHCR image
              (`ghcr.io/ycpss91255-docker/isaac-stream-source:<tag>`) so the
              downstream visual e2e always has a real, reproducible WebRTC
              source without a live desktop Isaac session.
owv#48      -- the omniverse_web_viewer visual e2e that connects a browser to
              this stream and asserts a guaranteed non-black frame.
isaac#173   -- the Tier B browser-frames smoke that builds on the Tier A
              stream smoke (isaac#172) and consumes this producer.

Boots the WebRTC streaming Kit experience on an EMPTY, lit stage (a dome for
a non-black background + a distant key light + a deterministic checkerboard
floor) and livestreams FOREVER, so a browser can connect at any time and
always see a deterministic, guaranteed-non-black frame. It renders no
external asset -- the whole scene is authored programmatically, so the image
is self-contained and the frame is byte-reproducible across boots.

Reuses the proven streaming boot from the standalone livestream smoke
(`standalone_livestream_smoke.py`, isaac#19 / #21 fix-B / ADR-0007):
  - pin the streaming experience (isaacsim.exp.base.python.streaming.kit) --
    the default/importer experiences lack the WebRTC exts;
  - inject publicEndpointAddress + signaling port + quitOnSessionEnded so a
    remote browser connects and the app does not self-quit with no client;
  - disable RTX auto-exposure so the lit stage reads true, not washed white.

Container contract: `--public-ip` / `--port` default from the `PUBLIC_IP` /
`ISAAC_SIGNAL_PORT` env vars (what the Dockerfile `producer` CMD and
`docker run --network=host -e PUBLIC_IP=<ip> <image>` rely on). Runs forever
by default; `--run-seconds N` (>0) bounds a boot for a test / smoke.

Style follows the repo's other standalone drivers (see
`standalone_livestream_smoke.py`): every isaac/omni/pxr/carb import is
function-local so a hosted import stays Isaac-free (test_import_safety.py
invariant), and `app.close()` runs in `finally` (#151-safe).
"""

import argparse
import os
import sys
import time

STREAM_EXPERIENCE = "/isaac-sim/apps/isaacsim.exp.base.python.streaming.kit"

DEFAULT_SIGNAL_PORT = 49100


def _build_arg_parser():
    """Argparse surface for the producer.

    Pure and Isaac-free so it is host-testable. `--public-ip` / `--port`
    default from the `PUBLIC_IP` / `ISAAC_SIGNAL_PORT` env vars (the
    container contract); an explicit flag always overrides the env.
    """
    env_ip = os.environ.get("PUBLIC_IP", "")
    env_port_raw = os.environ.get("ISAAC_SIGNAL_PORT", "")
    try:
        env_port = int(env_port_raw) if env_port_raw else DEFAULT_SIGNAL_PORT
    except ValueError:
        env_port = DEFAULT_SIGNAL_PORT

    ap = argparse.ArgumentParser(
        description=(
            "Boot a deterministic non-black checkerboard stage and "
            "livestream it over WebRTC as a stream source (isaac#223 / "
            "owv#48 / isaac#173)."
        )
    )
    ap.add_argument(
        "--public-ip",
        default=env_ip,
        help="publicEndpointAddress for the WebRTC signaling handshake "
             "(default: $PUBLIC_IP, else the container address).",
    )
    ap.add_argument(
        "--port",
        type=int,
        default=env_port,
        help="WebRTC signaling port "
             f"(default: $ISAAC_SIGNAL_PORT, else {DEFAULT_SIGNAL_PORT}).",
    )
    ap.add_argument(
        "--run-seconds",
        type=float,
        default=0.0,
        help="0 = run forever (producer); >0 = bounded run (test / smoke).",
    )
    return ap


def _build_empty_lit_stage():
    """Author the deterministic empty-but-lit checkerboard stage."""
    import omni.usd
    from pxr import Gf, Sdf, UsdGeom, UsdLux, UsdPhysics, UsdShade

    ctx = omni.usd.get_context()
    ctx.new_stage()
    stage = ctx.get_stage()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)

    # Gravity scene (harmless; nothing to fall, keeps physics init happy).
    scene = UsdPhysics.Scene.Define(stage, "/physicsScene")
    scene.CreateGravityDirectionAttr().Set((0.0, 0.0, -1.0))
    scene.CreateGravityMagnitudeAttr().Set(9.81)

    # Dome fills the background so the frame is never black; distant key for
    # a bit of shading on the floor.
    dome = UsdLux.DomeLight.Define(stage, "/World/DomeLight")
    dome.CreateIntensityAttr(250.0)
    key = UsdLux.DistantLight.Define(stage, "/World/KeyLight")
    key.CreateIntensityAttr(700.0)
    key.CreateAngleAttr(0.53)
    UsdGeom.Xformable(key.GetPrim()).AddRotateXYZOp().Set(
        Gf.Vec3f(-45.0, 30.0, 0.0)
    )

    # A checkerboard floor (alternating light/dark tiles) -- a clearly-lit
    # reference surface that reads far better than a flat pale plane, and is
    # deterministic (no external texture asset). Built as an N x N grid of
    # flat tiles bound to two UsdPreviewSurface materials by parity.
    def _mat(path, rgb):
        m = UsdShade.Material.Define(stage, path)
        s = UsdShade.Shader.Define(stage, path + "/Shader")
        s.CreateIdAttr("UsdPreviewSurface")
        s.CreateInput("diffuseColor", Sdf.ValueTypeNames.Color3f).Set(
            Gf.Vec3f(*rgb)
        )
        s.CreateInput("roughness", Sdf.ValueTypeNames.Float).Set(0.7)
        s.CreateInput("metallic", Sdf.ValueTypeNames.Float).Set(0.0)
        m.CreateSurfaceOutput().ConnectToSource(s.ConnectableAPI(), "surface")
        return m

    light_tile = _mat("/World/Looks/TileLight", (0.62, 0.62, 0.64))
    dark_tile = _mat("/World/Looks/TileDark", (0.15, 0.15, 0.17))

    UsdGeom.Xform.Define(stage, "/World/Ground")
    n_tiles = 12
    tile_m = 1.0
    half = n_tiles * tile_m / 2.0
    for i in range(n_tiles):
        for j in range(n_tiles):
            t = UsdGeom.Cube.Define(stage, f"/World/Ground/tile_{i}_{j}")
            t.CreateSizeAttr(1.0)
            tx = UsdGeom.Xformable(t.GetPrim())
            cx = -half + (i + 0.5) * tile_m
            cy = -half + (j + 0.5) * tile_m
            tx.AddTranslateOp().Set(Gf.Vec3d(cx, cy, -0.01))
            tx.AddScaleOp().Set(Gf.Vec3f(tile_m, tile_m, 0.02))
            UsdShade.MaterialBindingAPI.Apply(t.GetPrim()).Bind(
                light_tile if (i + j) % 2 == 0 else dark_tile
            )


def _frame_camera():
    """Pull the default perspective camera back + up to frame the 12x12
    checkerboard. Non-fatal if the viewport helper is absent."""
    try:
        from isaacsim.core.utils.viewports import set_camera_view
    except Exception:  # noqa: BLE001
        from omni.isaac.core.utils.viewports import set_camera_view
    set_camera_view(
        eye=[15.0, -15.0, 11.0],
        target=[0.0, 0.0, 0.0],
        camera_prim_path="/OmniverseKit_Persp",
    )


def main():
    # parse_known_args (not parse_args) so any Kit `--/app/...` args a caller
    # already put on the command line are ignored by argparse rather than
    # erroring out.
    args, _ = _build_arg_parser().parse_known_args()

    # Kit args must be injected into sys.argv before SimulationApp() reads
    # them. This is idempotent when the caller passed them directly.
    for kit_arg in (
        "--/app/livestream/nvcf/quitOnSessionEnded=false",
        f"--/app/livestream/port={args.port}",
    ):
        if kit_arg not in sys.argv:
            sys.argv.append(kit_arg)
    if args.public_ip:
        pe = f"--/app/livestream/publicEndpointAddress={args.public_ip}"
        if pe not in sys.argv:
            sys.argv.append(pe)

    from isaacsim import SimulationApp

    app = SimulationApp(
        {"headless": True, "livestream": 2},
        experience=STREAM_EXPERIENCE,
    )
    try:
        import carb
        import omni.timeline

        carb.settings.get_settings().set("/rtx/post/histogram/enabled", False)

        _build_empty_lit_stage()

        timeline = omni.timeline.get_timeline_interface()
        timeline.play()
        for _ in range(60):
            app.update()

        try:
            _frame_camera()
            for _ in range(15):
                app.update()
        except Exception as cam_exc:  # noqa: BLE001
            print(f"[PRODUCER] camera framing skipped: {cam_exc}", flush=True)

        print("[PRODUCER] empty lit stage streaming; "
              f"port={args.port} public_ip={args.public_ip or '(container)'}",
              flush=True)

        if args.run_seconds > 0:
            t_end = time.monotonic() + args.run_seconds
            while time.monotonic() < t_end:
                app.update()
        else:
            while True:
                app.update()
        print("[EXIT CLEAN]", flush=True)
    except Exception as exc:  # noqa: BLE001
        import traceback
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        raise
    finally:
        app.close()


if __name__ == "__main__":
    main()
