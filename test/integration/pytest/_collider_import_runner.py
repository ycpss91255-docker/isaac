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

The Isaac Lab importer emits an INSTANCEABLE USD: the visual and collision
mesh prims are pushed into a USD prototype (instancing is done on meshes so
properties do not differ across environments). A plain ``stage.Traverse()``
does NOT descend into a prototype, so the collision-bearing mesh prims are
invisible to it -- which is why the first GPU run reported
``collision_prims=0``. This runner therefore traverses WITH instance proxies
(``Usd.TraverseInstanceProxies()``) so the collision schemas inside the
prototype are visited.

The convex_hull vs convex_decomposition contrast does NOT show up as a
different number of USD prims: the native URDF importer writes ONE collision
``Mesh`` per ``<collision>`` element either way and records the
simplification as the ``UsdPhysics.MeshCollisionAPI`` approximation attribute
(``"convexHull"`` vs ``"convexDecomposition"``) -- the multiple convex pieces
of a decomposition are cooked at sim time by PhysX, not authored as separate
USD prims. The deterministic, stage-level structural difference is therefore
the approximation token, which the marker reports as ``approximation=<token>``
alongside the collision-prim count.

Marker line::

    [COLLIDER SUMMARY] type=<collider_type> collision_prims=<n> \
        approximation=<token> root=<path>
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
        # The importer emits an instanceable USD: the collision mesh prims
        # live inside a prototype, so a plain Traverse() (which does not
        # descend into prototypes) sees zero of them. Traverse WITH instance
        # proxies so the collision schemas in the prototype are visited.
        proxy_range = Usd.PrimRange.Stage(
            stage, Usd.TraverseInstanceProxies()
        )
        records = [
            (str(prim.GetPath()), str(prim.GetTypeName()))
            for prim in stage.Traverse()
        ]
        summary = model_import._summarize_prim_records(
            records, str(produced)
        )

        decomp_api = getattr(
            PhysxSchema, "PhysxConvexDecompositionCollisionAPI", None
        )
        collision_prims = 0
        approximation = "none"
        for prim in proxy_range:
            if not prim.HasAPI(UsdPhysics.CollisionAPI):
                continue
            collision_prims += 1
            # The convex_hull vs convex_decomposition difference is recorded
            # as the MeshCollisionAPI approximation token (the decomposition
            # pieces are cooked at sim time, not authored as USD prims). Read
            # the collision mesh's approximation as the contrast signal.
            mesh_api = UsdPhysics.MeshCollisionAPI(prim)
            token = None
            if mesh_api:
                attr = mesh_api.GetApproximationAttr()
                token = attr.Get() if attr else None
            # Fallback (importer-version tolerant): if the approximation attr
            # is unset but the PhysX convex-decomposition schema is applied,
            # the collider is a decomposition. This makes the hull-vs-decomp
            # contrast robust even if a future importer leaves the
            # approximation token at its default.
            if not token and decomp_api is not None and prim.HasAPI(
                decomp_api
            ):
                token = "convexDecomposition"
            if token:
                approximation = str(token)

        print(
            f"[COLLIDER SUMMARY] type={args.collider_type} "
            f"collision_prims={collision_prims} "
            f"approximation={approximation} root={summary.root_prim}",
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
