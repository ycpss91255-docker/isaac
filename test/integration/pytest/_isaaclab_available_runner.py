"""Isaac Lab availability runner (issue #149, ADR-0018).

Launched as a subprocess by ``test_isaaclab_available.py`` via
``/isaac-sim/python.sh``. Proves the baked Isaac Lab base tool is
importable inside the built container: it launches the Isaac Lab
``AppLauncher`` headless (the same primitive the driver adopts in MR-5,
#151), then imports ``isaaclab.sim`` (the spawn backend MR-3 builds on)
and confirms the spawner + URDF-converter cfg surfaces and the pinned
2.3 version are present.

Marker-line acceptance (Kit ``_exit(0)`` swallows the return code, same
convention as the other integration runners):

    [ISAACLAB OK] version=<v> spawn=<bool> urdf_converter=<bool>
    [EXIT CLEAN]

Run inside the GPU-enabled test container:

    ./script/run.sh -t test -- /isaac-sim/python.sh -m pytest \
        <repo>/test/integration/pytest/test_isaaclab_available.py -s
"""

import sys


def main() -> int:
    # AppLauncher must be created BEFORE importing isaaclab.sim: the sim
    # submodule pulls in omni modules that need the running Kit app.
    from isaaclab.app import AppLauncher

    app_launcher = AppLauncher(headless=True, enable_cameras=False)
    simulation_app = app_launcher.app

    import isaaclab
    import isaaclab.sim as sim_utils

    version = getattr(isaaclab, "__version__", "unknown")
    has_spawn = hasattr(sim_utils, "UsdFileCfg") and hasattr(
        sim_utils, "GroundPlaneCfg"
    )
    # UrdfConverterCfg lives under isaaclab.sim.converters (model_import,
    # MR-2). Importing it here also proves that surface is present.
    try:
        from isaaclab.sim.converters import UrdfConverterCfg  # noqa: F401

        has_urdf_converter = True
    except Exception:
        has_urdf_converter = False

    print(
        f"[ISAACLAB OK] version={version} spawn={has_spawn} "
        f"urdf_converter={has_urdf_converter}",
        flush=True,
    )

    simulation_app.close()
    print("[EXIT CLEAN]", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
