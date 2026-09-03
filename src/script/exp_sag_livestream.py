#!/usr/bin/env python3
"""#212 single-joint sag scene under Isaac Lab AppLauncher, with live WebRTC view.

This is the committed successor to the AppLauncher-livestream de-risk spike
(isaac#248 follow-up). It renders the ADR-0021 / isaac#212 single-DOF
prismatic-lift sag scene (fixed base + a loaded lift link held against gravity
by a linear position drive) on Isaac Sim 6.0.1 / Isaac Lab 3.0 through NVIDIA's
Isaac Lab ``AppLauncher`` -- so a human can WATCH the experiment render in a
browser (WebRTC) while it prints its JSON physics number.

WHY AppLauncher (not a raw SimulationApp + custom kit/stream control): the repo
standardises on Isaac Lab ``AppLauncher`` (ADR-0018) for the Kit lifecycle, and
its ``livestream`` arg brings up the supported WebRTC stack (the three
``omni.kit.livestream.{app,core,webrtc}`` extensions + NVCF signaling) with no
hand-rolled Dockerfile / kit-file stream wiring. The launch reuses the exact
isaac#248 mitigation the framework driver uses (``parse_livestream_applauncher``
+ ``boot_extension_kit_args`` from ``isaac_devkit.driver``): needed isaacsim
extensions are enabled at Kit BOOT (via ``--enable`` argv AppLauncher forwards
to Kit) so no runtime ``enable_extension`` re-runs the render experience and
tears the app down.

The ``--livestream {0,1,2}`` flag (default ``0``) selects the mode:

  0  headless, NO stream -- behaves like the existing headless exp drivers:
     step the sim, write the droop number to ``--out``, exit. Number only.
  1  native (legacy) Kit streaming + rendering.
  2  WebRTC streaming + rendering -- the browser live-view path. Brings the
     WebRTC signaling listener up (port 49100) + the NVCF HTTP server (8011),
     steps WITH render so the browser sees frames, STILL writes the droop
     number to ``--out``, then holds the app alive (``--watch-seconds``, 0 =
     until SIGINT) so a human can connect and watch the settled scene.

The same ``--livestream`` flag generalises to the other exp drivers: any driver
that adopts this launch shim (``parse_livestream_applauncher`` +
``boot_extension_kit_args`` + ``isaaclab.sim.SimulationContext``) gains a browser
live-view for free. (Extracting the shim into a shared helper is deferred to the
third such driver -- Rule of Three; CLAUDE.md anti-pattern #2.)

Scene source (``--scene``):

  urdf  DEFAULT. Build the scene by converting an inline URDF in-process via
        ``isaac_devkit.model_import._convert_urdf`` -- the FAITHFUL path the
        other exp drivers use, so the live-view reproduces the real acceptance
        pipeline. ``UrdfConverter`` ENABLES ``isaacsim.asset.importer.urdf`` at
        runtime, which is exactly the isaac#248 teardown trigger under the
        AppLauncher rendering experience; this path pre-empts it by boot-enabling
        that importer extension (auto-added to ``--boot-ext``) so the runtime
        enable is a no-op. VERIFIED on 6.0.1: with the importer boot-enabled the
        in-process conversion SURVIVES under AppLauncher + render + livestream=2
        (no teardown; droop 0.79 mm; stream up; non-black frame captured).
  usd   author the prismatic-lift scene DIRECTLY in USD in-process (pxr), no
        URDF importer at all. The importer-free FALLBACK: zero extension-enable
        risk, self-contained, slightly faster boot. Identical physics to the
        urdf path. Use it if a future Isaac build regresses the importer survival
        (the isaac#248 mitigation) or for a quick importer-independent live-view.

Both scene paths produce the identical physics (same masses, same prismatic
joint, same linear drive), so the measured steady-state droop matches the raw-
SimulationApp ``exp_l25_sag_sweep`` baseline (droop = m*g/k; ~0.79 mm at k=1e5,
10 kg). The drive is set via ``UsdPhysics.DriveAPI("linear")`` and the sim runs
on Isaac Lab's native ``isaaclab.sim.SimulationContext`` (NOT the deprecated
``isaacsim.core.api`` stack, whose ``SimulationContext`` is version-incompatible
with the AppLauncher/isaaclab experience -- SimulationManager.set_backend
AttributeError).

WATCH FLOW (acceptance live-view of #212)
-----------------------------------------
Reproduces doc/experiments/REPRODUCE.md's live-view section. From the repo root
(the ``just`` recipes forward to the compose ``stream`` service; ``network_mode:
host`` so the container's listen ports == the host's):

    # 1. Bring up the idle stream container + browser web-viewer sidecar.
    just run -t stream -d

    # 2. Launch this driver into it with WebRTC streaming on. It settles the
    #    sag, prints the droop to --out, then holds the scene live.
    just exec -t stream /isaac-sim/python.sh \\
        /home/<user>/work/worktree/<wt>/src/script/exp_sag_livestream.py \\
        --livestream 2 --out /home/<user>/work/worktree/<wt>/test/.sag-live.json

    # 3. Open Chrome -> http://<host-ip>:5173  (boots straight into the stream).
    #    Verify the listeners from the server:
    #        ss -tln | grep -E ':8011|:49100'   -> both LISTEN.

    # Headless number-only (no stream), e.g. for CI / a quick check:
    docker compose --env-file .env.generated --profile test run --rm -T test \\
        /isaac-sim/python.sh <this-script> --livestream 0 --out <path>.json

Clean exit is ``os._exit(0)`` (isaac#248 round 9 / the sag sweep): a cold
headless container's Omniverse Hub connector aborts SimulationApp.close() with a
busy-TaskGroup SIGABRT; os._exit reaches the same clean exit without it. The
results JSON is written BEFORE the (optional, time-boxed) frame capture and
before the watch loop, so neither a capture hang nor a Ctrl+C can lose the data.
"""

import argparse
import json
import math
import os
import signal
import socket
import sys
import time
import traceback
from pathlib import Path

# Make the worktree's framework importable regardless of PYTHONPATH (the
# committed env var may point at the MAIN checkout's framework, not this
# worktree). framework/ is two levels up from src/script/.
_FRAMEWORK = Path(__file__).resolve().parents[2] / "framework"
if str(_FRAMEWORK) not in sys.path:
    sys.path.insert(0, str(_FRAMEWORK))

GRAVITY = 9.81

# #212 single-DOF prismatic lift, verbatim from exp_l25_sag_sweep.py so the
# --scene urdf path converts the exact same scene -> same steady-state sag.
# base_link is fixed to the world (fix_base=True); lift_link is the loaded mass,
# free to slide along +Z under a prismatic linear drive. High effort limit so
# the drive never saturates at the target (ADR-0021 A3).
_URDF_TEMPLATE = """<?xml version="1.0"?>
<robot name="prismatic_lift">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
  <link name="lift_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="{mass}"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
  <joint name="lift_joint" type="prismatic">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="base_link"/>
    <child link="lift_link"/>
    <axis xyz="0 0 1"/>
    <limit lower="-1.0" upper="1.0" effort="100000.0" velocity="10.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
</robot>
"""

# Prim paths for the directly-authored USD scene (--scene usd). Kept in sync
# with the URDF's link/joint names so both paths look the same to the reader.
_USD_ROOT = "/prismatic_lift"
_USD_BASE = _USD_ROOT + "/base_link"
_USD_LIFT = _USD_ROOT + "/lift_link"
_USD_JOINT = _USD_ROOT + "/lift_joint"


def _log(msg):
    print(f"[sag-live] {msg}", flush=True)


# --- scene discovery / drive helpers (shape from exp_l25_sag_sweep.py) --------


def _find_prismatic_joint(stage):
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.PrismaticJoint):
            return str(prim.GetPath())
    for prim in stage.Traverse():
        if "Prismatic" in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _find_articulation_root(stage):
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            return str(prim.GetPath())
    return None


def _set_linear_drive(stage, joint_path, stiffness, damping, target):
    """Author a linear (prismatic) DriveAPI with the given gains + target.

    Prismatic drive: stiffness is plain N/m and target is meters -- NO pi/180
    (that conversion is angular-only). Returns the read-back (stiffness,
    damping, target) so the caller confirms what PhysX will parse.
    """
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "linear")
    if not drive:
        drive = UsdPhysics.DriveAPI.Apply(prim, "linear")
    drive.CreateTypeAttr().Set("force")
    drive.CreateStiffnessAttr().Set(float(stiffness))
    drive.CreateDampingAttr().Set(float(damping))
    drive.CreateTargetPositionAttr().Set(float(target))
    drive.CreateMaxForceAttr().Set(float("inf"))
    return (
        drive.GetStiffnessAttr().Get(),
        drive.GetDampingAttr().Get(),
        drive.GetTargetPositionAttr().Get(),
    )


# --- scene builders -----------------------------------------------------------


def _build_scene_urdf(app, args, result):
    """Faithful path: convert the inline URDF in-process, open the produced USD.

    ``isaac_devkit.model_import._convert_urdf`` constructs an
    ``isaaclab.sim.converters.UrdfConverter``, which ENABLES the
    ``isaacsim.asset.importer.urdf`` extension at runtime. Under AppLauncher's
    rendering experience that runtime enable is the isaac#248 teardown trigger;
    boot-enabling the importer (``--boot-ext`` includes it for this path) is the
    mitigation. This function records whether the conversion survived.
    """
    from isaac_devkit import model_import

    urdf_path = Path("/tmp/sag_live_prismatic_lift.urdf")
    urdf_path.write_text(_URDF_TEMPLATE.format(mass=args.mass))
    out_usd = Path("/tmp/sag_live_prismatic_lift.usd")
    produced = model_import._convert_urdf(
        urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
    )
    result["urdf_convert_survived"] = True
    result["converted_usd"] = str(produced)
    _log(f"urdf conversion survived under AppLauncher render: {produced}")

    import omni.usd

    ctx = omni.usd.get_context()
    if not ctx.open_stage(str(produced)):
        raise RuntimeError(f"open_stage returned False for {produced}")
    for _ in range(120):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    return ctx.get_stage()


def _build_scene_usd(app, args, result):
    """Robust path: author the prismatic-lift scene directly in USD (no importer).

    Builds the same physics as the URDF (fixed base + a loaded lift link + a
    +Z prismatic joint carrying the mass) with pure ``pxr`` schema calls, so no
    extension is enabled at runtime and the AppLauncher render/stream stack is
    never disturbed. The lift link's mass is set to ``args.mass``; the base is
    the fixed articulation root.
    """
    import omni.usd
    from pxr import Gf, PhysxSchema, Usd, UsdGeom, UsdPhysics

    ctx = omni.usd.get_context()
    ctx.new_stage()
    for _ in range(30):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()
    stage = ctx.get_stage()
    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    # Physics scene (default gravity -Z at 9.81 m/s^2, matching the sweep).
    scene = UsdPhysics.Scene.Define(stage, "/physicsScene")
    scene.CreateGravityDirectionAttr().Set(Gf.Vec3f(0.0, 0.0, -1.0))
    scene.CreateGravityMagnitudeAttr().Set(GRAVITY)

    # Root xform carrying the articulation.
    root = UsdGeom.Xform.Define(stage, _USD_ROOT)
    UsdPhysics.ArticulationRootAPI.Apply(root.GetPrim())

    def _box(path, size, mass, z):
        cube = UsdGeom.Cube.Define(stage, path)
        cube.CreateSizeAttr(size)
        UsdGeom.Xformable(cube).AddTranslateOp().Set(Gf.Vec3d(0.0, 0.0, z))
        prim = cube.GetPrim()
        UsdPhysics.CollisionAPI.Apply(prim)
        UsdPhysics.RigidBodyAPI.Apply(prim)
        mass_api = UsdPhysics.MassAPI.Apply(prim)
        mass_api.CreateMassAttr().Set(float(mass))
        return prim

    # base_link at z=0 (fixed to world), lift_link at the target height offset
    # (z=0.2 origin like the URDF joint origin; drive target adds on top).
    base_prim = _box(_USD_BASE, 0.1, 1.0, 0.0)
    _box(_USD_LIFT, 0.1, args.mass, 0.2)

    # Fix the base to the world so it cannot free-fall (URDF fix_base=True).
    fixed = UsdPhysics.FixedJoint.Define(stage, _USD_ROOT + "/base_fixed")
    fixed.CreateBody1Rel().SetTargets([base_prim.GetPath()])

    # Prismatic joint: base_link -> lift_link along +Z.
    joint = UsdPhysics.PrismaticJoint.Define(stage, _USD_JOINT)
    joint.CreateAxisAttr().Set("Z")
    joint.CreateBody0Rel().SetTargets([_USD_BASE])
    joint.CreateBody1Rel().SetTargets([_USD_LIFT])
    joint.CreateLocalPos0Attr().Set(Gf.Vec3f(0.0, 0.0, 0.2))
    joint.CreateLocalPos1Attr().Set(Gf.Vec3f(0.0, 0.0, 0.0))
    joint.CreateLowerLimitAttr().Set(-1.0)
    joint.CreateUpperLimitAttr().Set(1.0)

    # A light so the browser view is not pitch black.
    from pxr import UsdLux

    UsdLux.DistantLight.Define(stage, "/World/SunLight")

    # Keep unused imports referenced (schema modules loaded for their side
    # effect of registering the USD types above).
    _ = (Usd, PhysxSchema)

    result["urdf_convert_survived"] = None  # not applicable on the usd path
    result["authored_usd_direct"] = True
    _log("authored prismatic-lift scene directly in USD (no importer)")
    return stage


# --- streaming verification ---------------------------------------------------


def _enabled_livestream_exts():
    try:
        import omni.kit.app

        mgr = omni.kit.app.get_app().get_extension_manager()
        out = []
        for e in mgr.get_extensions():
            eid = e.get("id", "") if isinstance(e, dict) else getattr(e, "id", "")
            enabled = (
                e.get("enabled", False)
                if isinstance(e, dict)
                else getattr(e, "enabled", False)
            )
            if enabled and ("livestream" in eid or "webrtc" in eid):
                out.append(eid)
        return sorted(out)
    except Exception as exc:  # noqa: BLE001
        return [f"<ext-query-failed: {type(exc).__name__}: {exc}>"]


def _port_listening(port, host="127.0.0.1"):
    """True if something accepts a TCP connection on host:port right now."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.5)
        return s.connect_ex((host, port)) == 0


def _scan_tcp(ports):
    return sorted(p for p in ports if _port_listening(p))


class _Timeout(Exception):
    pass


def _try_capture_frame(app, timeout_s=45):
    """Best-effort: render a camera product and check the frame is non-black.

    Time-boxed with SIGALRM so a hang never blocks the clean exit; the physics
    + streaming results are already persisted before this runs.
    """
    info = {"attempted": True, "captured": False, "detail": None}

    def _alarm(_signum, _frame):
        raise _Timeout()

    old = signal.signal(signal.SIGALRM, _alarm)
    signal.alarm(int(timeout_s))
    try:
        import numpy as np
        import omni.replicator.core as rep

        cam = rep.create.camera(position=(3.0, 3.0, 2.0), look_at=(0.0, 0.0, 0.3))
        rp = rep.create.render_product(cam, (256, 256))
        annot = rep.AnnotatorRegistry.get_annotator("rgb")
        annot.attach(rp)
        # The offscreen render product can take several frames to populate,
        # especially while the livestream render is running concurrently. Warm
        # up, then poll get_data() across update cycles until it is non-empty
        # (bounded; the whole attempt is SIGALRM-boxed above).
        for _ in range(20):
            app.update()
        arr = np.asarray([])
        for _ in range(60):
            app.update()
            arr = np.asarray(annot.get_data())
            if arr.size:
                break
        if arr.size:
            rgb = arr[..., :3].astype("float64")
            info.update(
                captured=True,
                shape=list(arr.shape),
                max_pixel=float(rgb.max()),
                mean_pixel=float(rgb.mean()),
                nonblack=bool(rgb.max() > 1.0),
            )
        else:
            info["detail"] = "annotator returned empty array after 80 frames"
    except _Timeout:
        info["detail"] = f"frame capture timed out after {timeout_s}s"
    except Exception as exc:  # noqa: BLE001
        info["detail"] = f"{type(exc).__name__}: {exc}"
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old)
    return info


# --- AppLauncher boot (reuses framework driver's isaac#248 pattern) -----------


def _stream_port_args(args):
    out = []
    if args.signal_port is not None:
        out.append(
            "--/exts/omni.kit.livestream.app/primaryStream/signalPort="
            f"{args.signal_port}"
        )
    if args.stream_port is not None:
        out.append(
            "--/exts/omni.kit.livestream.app/primaryStream/streamPort="
            f"{args.stream_port}"
        )
    return out


def _ext_folder_args(args):
    out = []
    for folder in args.ext_folder or ():
        out += ["--ext-folder", folder]
    return out


def _launch_applauncher(livestream, boot_exts, extra_kit_args):
    """Construct Isaac Lab AppLauncher exactly as the framework driver does.

    boot_exts are enabled at Kit boot (``--enable`` argv) so runtime enables are
    no-ops (isaac#248). extra_kit_args (stream port overrides, ext folders) are
    forwarded to Kit. sys.argv is spliced only for the construction call.
    """
    from isaac_devkit.driver import (
        boot_extension_kit_args,
        parse_livestream_applauncher,
    )
    from isaaclab.app import AppLauncher

    launcher_args = parse_livestream_applauncher(str(livestream))
    _log(f"AppLauncher args: {launcher_args}")
    _log(f"boot extensions: {boot_exts}")
    _log(f"extra kit args: {extra_kit_args}")

    saved_argv = list(sys.argv)
    sys.argv += boot_extension_kit_args(boot_exts)
    sys.argv += list(extra_kit_args)
    try:
        app_launcher = AppLauncher(launcher_args)
    finally:
        sys.argv[:] = saved_argv
    return app_launcher, app_launcher.app


# --- main ---------------------------------------------------------------------


def _read_dof_pos_factory(art_view, dof_idx):
    import numpy as np

    def _read_pos():
        raw = art_view.get_dof_positions()
        for conv in (
            lambda x: np.asarray(x),
            lambda x: x.numpy(),
            lambda x: x.cpu().numpy(),
        ):
            try:
                return float(conv(raw).reshape(-1)[dof_idx])
            except Exception:  # noqa: BLE001
                continue
        raise RuntimeError(f"cannot read dof positions from {type(raw)}")

    return _read_pos


_SHOULD_QUIT = {"flag": False}


def _on_signal(signum, _frame):
    _log(f"signal {signum} received; leaving watch loop")
    _SHOULD_QUIT["flag"] = True


def run(args):
    render = args.livestream > 0
    result = {
        "experiment": "sag-livestream",
        "isaac_variant": "6.0.1",
        "launcher": "isaaclab.app.AppLauncher",
        "livestream": args.livestream,
        "scene": args.scene,
        "mass_kg": args.mass,
        "stiffness": args.stiffness,
        "target_m": args.target,
        "settle_steps": args.settle_steps,
        "render": render,
        "signal_port": args.signal_port,
        "stream_port": args.stream_port,
        "launch_ok": False,
        "scene_ok": False,
        "stepped": False,
        "droop_mm": None,
        "predicted_mm": (args.mass * GRAVITY / args.stiffness) * 1000.0,
        "error": None,
    }

    boot_exts = list(args.boot_ext)
    if args.scene == "urdf":
        # UrdfConverter enables this at runtime; boot-enable it so the runtime
        # enable is a no-op and cannot re-run the render experience (isaac#248).
        if "isaacsim.asset.importer.urdf" not in boot_exts:
            boot_exts.append("isaacsim.asset.importer.urdf")
    extra = _stream_port_args(args) + _ext_folder_args(args)

    try:
        _app_launcher, app = _launch_applauncher(args.livestream, boot_exts, extra)
        result["launch_ok"] = True
        for _ in range(60):
            app.update()
        result["livestream_exts_enabled"] = _enabled_livestream_exts()
        _log(f"launched. livestream exts: {result['livestream_exts_enabled']}")

        # Build the scene (this is where the URDF-conversion survival question
        # is answered on the --scene urdf path).
        if args.scene == "urdf":
            stage = _build_scene_urdf(app, args, result)
        else:
            stage = _build_scene_usd(app, args, result)

        joint_path = _find_prismatic_joint(stage)
        if joint_path is None:
            raise RuntimeError("no prismatic joint in stage")
        root_path = _find_articulation_root(stage) or joint_path
        result["joint_path"] = joint_path
        result["root_path"] = root_path
        result["scene_ok"] = True

        # Isaac Lab's NATIVE sim stack -- NOT the deprecated isaacsim.core.api,
        # whose SimulationContext is version-incompatible with the AppLauncher /
        # isaaclab experience (SimulationManager.set_backend AttributeError).
        from isaaclab.sim import SimulationCfg, SimulationContext

        k = args.stiffness
        damping = 2.0 * math.sqrt(k * args.mass)  # critical (linear)
        stored = _set_linear_drive(stage, joint_path, k, damping, args.target)
        result["stored_stiffness"] = stored[0]
        result["stored_target"] = stored[2]
        result["damping_critical"] = damping

        sim = SimulationContext(SimulationCfg(dt=args.dt, device="cuda:0"))
        sim.reset()

        art_view = None
        for pattern in (root_path, root_path + "*", _USD_ROOT + ".*"):
            try:
                v = sim.physics_sim_view.create_articulation_view(pattern)
                if v.count >= 1:
                    art_view, result["art_pattern"] = v, pattern
                    break
            except Exception as exc:  # noqa: BLE001
                result.setdefault("art_view_errors", []).append(
                    f"{pattern}: {type(exc).__name__}: {exc}"
                )
        if art_view is None:
            raise RuntimeError("could not build a physics articulation view")

        try:
            names = list(art_view.shared_metatype.dof_names)
        except Exception:  # noqa: BLE001
            names = None
        result["dof_names"] = names
        dof_idx = names.index("lift_joint") if names and "lift_joint" in names else 0
        _read_pos = _read_dof_pos_factory(art_view, dof_idx)

        # Step to steady state. render=True under livestream so the browser sees
        # the sim; render=False headless (livestream 0) for the number-only run.
        tail = []
        for step_i in range(args.settle_steps):
            sim.step(render=render)
            if step_i >= args.settle_steps - 60:
                tail.append(_read_pos())
        result["stepped"] = True

        settled = tail[-1] if tail else _read_pos()
        result["settled_position_m"] = settled
        result["droop_mm"] = (args.target - settled) * 1000.0
        result["drift_mm"] = (max(tail) - min(tail)) * 1000.0 if tail else None
        _log(f"droop_mm={result['droop_mm']:.4f} (pred {result['predicted_mm']:.4f})")

        if args.livestream > 0:
            result["signal_port_listening"] = _port_listening(
                args.signal_port if args.signal_port is not None else 49100
            )
            result["http_ports_8000_8100_open"] = _scan_tcp(range(8000, 8101))
            result["signal_ports_49100_49120_open"] = _scan_tcp(range(49100, 49121))
            _log(f"signal port listening={result['signal_port_listening']} "
                 f"http={result['http_ports_8000_8100_open']} "
                 f"signal={result['signal_ports_49100_49120_open']}")

        # Persist BEFORE the optional frame capture + watch loop so neither a
        # capture hang nor a Ctrl+C can lose the physics/streaming results.
        _write(args.out, result)

        if args.capture_frame:
            result["frame_capture"] = _try_capture_frame(app)
            _log(f"frame_capture: {result['frame_capture']}")
            _write(args.out, result)

        # Live-view hold: keep the app rendering so a human can connect a browser
        # and watch the settled scene. Bounded by --watch-seconds (0 = until
        # SIGINT). Headless mode (livestream 0) skips this entirely.
        if args.livestream > 0 and args.watch_seconds != 0:
            signal.signal(signal.SIGINT, _on_signal)
            signal.signal(signal.SIGTERM, _on_signal)
            deadline = None if args.watch_seconds < 0 else (
                time.monotonic() + args.watch_seconds
            )
            _log(f"holding live view (watch_seconds={args.watch_seconds}); "
                 "connect a browser to :5173")
            while not _SHOULD_QUIT["flag"] and app.is_running():
                sim.step(render=True)
                if deadline is not None and time.monotonic() >= deadline:
                    break

    except SystemExit as exc:
        result["error"] = f"SystemExit({exc.code}) -- likely isaac#248 teardown"
        result["traceback"] = traceback.format_exc()
    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
    finally:
        _write(args.out, result)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(0)


def _write(out, result):
    try:
        p = Path(out)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(result, indent=2))
    except Exception as exc:  # noqa: BLE001
        _log(f"could not write {out}: {exc}")


def _parse_args():
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--out", required=True, help="JSON result path (mounted).")
    p.add_argument(
        "--livestream",
        type=int,
        choices=(0, 1, 2),
        default=0,
        help="0 headless number-only (default), 1 native stream, 2 WebRTC.",
    )
    p.add_argument(
        "--scene",
        choices=("urdf", "usd"),
        default="urdf",
        help="urdf = in-process URDF conversion (default, faithful; boot-enables "
             "the importer, survival verified on 6.0.1); usd = author the scene "
             "directly in USD (importer-free fallback).",
    )
    p.add_argument("--mass", type=float, default=10.0, help="Payload kg.")
    p.add_argument("--target", type=float, default=0.3, help="Target lift m.")
    p.add_argument("--stiffness", type=float, default=1e5, help="Drive Kp N/m.")
    p.add_argument("--settle-steps", type=int, default=600, help="Sim steps.")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument(
        "--watch-seconds",
        type=float,
        default=-1.0,
        help="Live-view hold after settling (livestream>0): <0 until SIGINT "
             "(default), 0 disables the hold, >0 bounds it in seconds.",
    )
    p.add_argument(
        "--capture-frame",
        action="store_true",
        help="Best-effort non-black rendered-frame check (livestream>0).",
    )
    p.add_argument(
        "--signal-port",
        type=int,
        default=None,
        help="Override livestream signalPort (default: kit default 49100).",
    )
    p.add_argument(
        "--stream-port",
        type=int,
        default=None,
        help="Override livestream streamPort (default: kit default).",
    )
    p.add_argument(
        "--boot-ext",
        nargs="*",
        default=["isaacsim.core.nodes"],
        help="Extensions to --enable at Kit boot (isaac#248 mitigation).",
    )
    p.add_argument(
        "--ext-folder",
        nargs="*",
        default=[],
        help="Extra Kit --ext-folder search paths.",
    )
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
