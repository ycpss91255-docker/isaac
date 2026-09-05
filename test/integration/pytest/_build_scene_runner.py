"""Kit-side runner: spawn the example scene via the framework build_scene
adapter (#152, ADR-0018 decisions 1 + 3).

Not a pytest test (leading underscore so pytest skips collection). Boots a
headless ``SimulationApp``, loads the example three-file scene, and calls
the FRAMEWORK ``isaac_devkit.scene.build_scene`` -- the new
``to_isaaclab_cfg`` -> ``sim_utils`` cfg -> ``cfg.func()`` spawn path --
then reports the spawned prims as marker lines. This is the dedicated GPU
coverage for the adapter (the example driver still uses its own raw-pxr
``_build_scene`` until #154, so the example GPU test does not exercise the
adapter; this runner does).

Marker lines (the pytest layer asserts on these)::

    [ADAPTER PRIM] path=<p> valid=<bool>     ground / light / robot root
    [ADAPTER OBJECT] path=<p> valid=<bool> rigidbody=<bool>
    [ADAPTER BASE_LINK] valid=<bool>         loose (depends on committed USD)
    [ADAPTER OK] ground=<bool> light=<bool> robot=<bool> objects=<N>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _build_scene_runner.py --repo-root <repo>
"""

import argparse
import os
import sys
from pathlib import Path


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    example_dir = repo_root / "example" / "sim"
    for d in (framework_dir, example_dir):
        if str(d) not in sys.path:
            sys.path.insert(0, str(d))

    # Headless, no livestream (ROS 2 bridge + livestream in one Kit process
    # segfaults randomly, IsaacSim#228); this runner does no ROS 2 anyway.
    os.environ["ISAAC_LIVESTREAM"] = "0"

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})
    # Default to failure so any escape that skips both branches below still
    # exits non-zero (the pytest layer asserts returncode == 0).
    exit_code = 1
    try:
        import omni.usd
        from pxr import UsdPhysics

        from example_driver import ExampleDriver, load_three_file_scene
        from isaac_devkit.scene import build_scene

        scene = load_three_file_scene(repo_root / ExampleDriver.SCENE)

        ctx = omni.usd.get_context()
        stage = ctx.get_stage()
        if stage is None:
            ctx.new_stage()
            stage = ctx.get_stage()

        # The example scene's model paths resolve under example/sim/model/usd.
        build_scene(scene, stage, example_dir)

        def _valid(path: str) -> bool:
            return bool(stage.GetPrimAtPath(path).IsValid())

        ground = _valid("/World/ground")
        light = _valid("/World/light")
        robot = _valid("/World/Robot")
        for path in ("/World/ground", "/World/light", "/World/Robot"):
            print(f"[ADAPTER PRIM] path={path} valid={_valid(path)}", flush=True)

        # base_link resolves now that the committed camera_bot.usd carries a
        # defaultPrim (/camera_bot, set in #154's fb6f580): the adapter's
        # UsdFileCfg reference brings in the referenced content, so
        # /World/Robot/base_link is valid. Asserted strictly by the test.
        base_link = _valid("/World/Robot/base_link")
        print(f"[ADAPTER BASE_LINK] valid={base_link}", flush=True)

        # The spawned orientation is what a quaternion-order mistake shows up
        # in: the scene YAML says rpy [0,0,0], so every spawned prim must
        # carry an IDENTITY orient. Sending (w,x,y,z) into a spawner that
        # documents (x,y,z,w) writes (0,1,0,0) instead -- 180 degrees about X,
        # the whole scene upside-down. Structure assertions cannot see that;
        # this can.
        from pxr import UsdGeom

        for path in ("/World/Robot", "/World/light"):
            prim = stage.GetPrimAtPath(path)
            quat = None
            if prim.IsValid():
                for op in UsdGeom.Xformable(prim).GetOrderedXformOps():
                    if op.GetOpName().endswith("orient"):
                        q = op.Get()
                        img = q.GetImaginary()
                        quat = (q.GetReal(), img[0], img[1], img[2])
                        break
            print(f"[ADAPTER ORIENT] path={path} quat={quat}", flush=True)

        objects_root = stage.GetPrimAtPath("/World/Objects")
        obj_children = (
            list(objects_root.GetChildren()) if objects_root.IsValid() else []
        )
        for prim in obj_children:
            p = str(prim.GetPath())
            has_rb = bool(prim.HasAPI(UsdPhysics.RigidBodyAPI))
            print(
                f"[ADAPTER OBJECT] path={p} valid=True rigidbody={has_rb}",
                flush=True,
            )

        print(
            f"[ADAPTER OK] ground={ground} light={light} robot={robot} "
            f"objects={len(obj_children)}",
            flush=True,
        )
        print("[EXIT CLEAN]", flush=True)
        exit_code = 0
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        # Full traceback to stdout (the pytest layer captures stdout; stderr
        # gets truncated in the CompletedProcess repr) so a spawn failure
        # reports its exact frame.
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        exit_code = 1
    finally:
        # Deterministic teardown (isaac#248 round 9). Do NOT fall through to
        # SimulationApp.close(): under Isaac Sim 6.0.1, in a cold/headless CI
        # container the Omniverse Hub connector cannot launch -- the base
        # image bakes HUB__CACHE__PATH=/var/cache/hub (root-owned, unwritable
        # by the container user) and HUB__ARGS__DETECT_ONLY=true, so the hub
        # child exits 1 ("Permission denied ... without writing file
        # /tmp/hub-<user>-<hash>.config.json") and carb.omniclient spins a
        # background reconnect task that keeps retrying. If that task is still
        # in flight when close() drains Kit, carb aborts the process with
        #   TaskGroup::~TaskGroup(): Assertion (empty()) failed:
        #   Destroying busy TaskGroup!  ->  SIGABRT, returncode 1
        # even though the adapter work already finished ([ADAPTER OK] /
        # [EXIT CLEAN]). Warm local runs miss the race because the retry loop
        # has backed off by shutdown; CI hits it deterministically. close()
        # already _exit(0)s on success anyway (Isaac's fast-shutdown path), so
        # an explicit os._exit reaches the same clean exit deterministically
        # while skipping the asserting carb teardown. This throwaway
        # subprocess holds nothing that needs graceful release -- the OS
        # reclaims the GPU context and threads on exit -- and asset access is
        # unaffected because the Isaac assets root resolves over HTTPS (S3),
        # not through Hub. Flush first so the pytest layer still parses every
        # marker line off stdout.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(exit_code)


if __name__ == "__main__":
    _main()
