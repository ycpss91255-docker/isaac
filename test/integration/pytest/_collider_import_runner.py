"""Kit-side runner: import a URDF with a chosen collider_type and report the
collision-prim structure (#167, ADR-0020 decision 2).

Not a pytest test (leading underscore so pytest skips collection). Boots ONE
headless ``SimulationApp`` (pinning the 2.4.31-importer experience via
``model_import._simulation_app_kwargs``, #177), converts the concave U-shape
fixture with the requested ``collider_type`` via ``model_import._convert_urdf``
(so the convert AND the stage inspection happen under the SAME live Kit -- the
USD plugins are loaded), then opens the produced USD and emits a marker line
counting the convex collider prims.

The pytest layer spawns this runner TWICE (one ``SimulationApp`` is a
process-global singleton, so one import per process) -- once per
collider_type -- and asserts the contrast:

    convex_hull           -> ONE convex collider piece (the open-top notch is
                             filled into a single hull).
    convex_decomposition  -> MULTIPLE convex collider pieces (the concavity
                             is preserved as several convex hulls).

A "convex collider piece" is counted as a prim that carries a
``UsdPhysics.CollisionAPI`` AND a Physx convex-hull /
convex-decomposition collision schema, or (importer-version tolerant) a
collision-bearing ``Mesh`` prim. The marker reports both the raw
collision-prim count and the convex-piece count.

Marker line::

    [COLLIDER SUMMARY] type=<collider_type> collision_prims=<n> \
        convex_pieces=<n> root=<path>
    [EXIT CLEAN]
    [RAISED] <type>: <msg>

CLI::

    /isaac-sim/python.sh _collider_import_runner.py \\
        --repo-root <repo> --collider-type convex_decomposition \\
        --out /tmp/ushape_decomp.usd
"""

import argparse
import sys
from pathlib import Path


def _main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument(
        "--collider-type",
        required=True,
        choices=("convex_hull", "convex_decomposition"),
    )
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    framework_dir = repo_root / "framework"
    if str(framework_dir) not in sys.path:
        sys.path.insert(0, str(framework_dir))

    urdf = (
        repo_root / "test" / "fixtures" / "urdf" / "concave_ushape.urdf"
    )
    out_usd = Path(args.out).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaac_devkit import model_import

    # One live Kit for convert + inspect (the #177 experience pin loads the
    # 2.4.31 importer). model_import imports stay function-local; we own the
    # SimulationApp here so the produced stage can be opened with the USD
    # plugins still loaded.
    from isaacsim import SimulationApp

    app = SimulationApp(model_import._simulation_app_kwargs())
    try:
        from pxr import PhysxSchema, Usd, UsdPhysics

        produced = model_import._convert_urdf(
            urdf,
            out_usd,
            fix_base=True,
            merge_fixed_joints=True,
            collider_type=args.collider_type,
        )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        stage = Usd.Stage.Open(str(produced))
        records = [
            (str(prim.GetPath()), str(prim.GetTypeName()))
            for prim in stage.Traverse()
        ]
        summary = model_import._summarize_prim_records(
            records, str(produced)
        )

        convex_apis = [
            getattr(PhysxSchema, "PhysxConvexHullCollisionAPI", None),
            getattr(
                PhysxSchema, "PhysxConvexDecompositionCollisionAPI", None
            ),
        ]
        collision_prims = 0
        convex_pieces = 0
        for prim in stage.Traverse():
            has_collision = prim.HasAPI(UsdPhysics.CollisionAPI)
            if has_collision:
                collision_prims += 1
            is_convex = any(
                api is not None and prim.HasAPI(api) for api in convex_apis
            )
            if is_convex or (
                has_collision and prim.GetTypeName() == "Mesh"
            ):
                convex_pieces += 1

        print(
            f"[COLLIDER SUMMARY] type={args.collider_type} "
            f"collision_prims={collision_prims} "
            f"convex_pieces={convex_pieces} root={summary.root_prim}",
            flush=True,
        )
        print("[EXIT CLEAN]", flush=True)
    except Exception as exc:  # noqa: BLE001
        import traceback

        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        print("[TRACEBACK]\n" + traceback.format_exc(), flush=True)
        raise
    finally:
        app.close()


if __name__ == "__main__":
    _main()
