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
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        # Full traceback to stdout (the pytest layer captures stdout; stderr
        # gets truncated in the CompletedProcess repr) so a spawn failure
        # reports its exact frame.
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        raise
    finally:
        app.close()


if __name__ == "__main__":
    _main()
