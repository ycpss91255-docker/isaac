"""Kit-side runner for L3 integration test.

Not a pytest test (leading underscore so pytest skips collection).
Invoked by ``test_sensor_setup_integration.py`` as a subprocess so
``SimulationApp`` boots fresh per invocation.

The runner builds a *minimal* in-memory stage with a single body prim
at ``/World/Robot/base_link`` (either RigidBody or plain Xform,
controlled by ``--body-mode``), then calls ``sensor_setup.setup_sensor``
with the YAML fixture handed in by the test.

Why a minimal stage instead of openbase: openbase carries multi-variant
Physics / Sensor / Robot variantSets, and selecting the right variant
to ensure RigidBodyAPI is applied to base_link adds noise that does not
exercise the L3 contract. The L3 contract being tested is "sensor_setup
dispatches correctly + IMU rejects non-rigid mount"; the parent prim's
RigidBodyAPI presence is the only relevant body-side detail.

CLI:

    /isaac-sim/python.sh _sensor_setup_runner.py \\
        --yaml <path to sensor.yaml> \\
        --script-dir <repo>/framework \\
        --body-mode {rigid,xform}

Exit codes:
    0 = setup_sensor returned without raising
    1 = setup_sensor raised (e.g. IMU on non-rigid parent) -- the test
        layer decides whether that is the expected outcome.
"""

import argparse
import sys
from pathlib import Path


def _build_minimal_stage(stage, body_mode: str):
    from pxr import Sdf, UsdGeom, UsdPhysics
    UsdGeom.Xform.Define(stage, Sdf.Path("/World"))
    UsdGeom.Xform.Define(stage, Sdf.Path("/World/Robot"))
    base_link = UsdGeom.Xform.Define(stage, Sdf.Path("/World/Robot/base_link"))
    if body_mode == "rigid":
        # ApplyAPI on the prim, not the schema class -- matches the
        # imported-URDF shape isaac_devkit.sensors expects in production.
        UsdPhysics.RigidBodyAPI.Apply(base_link.GetPrim())


def _do_setup(args, app) -> int:
    """Inner body: load config + build stage + dispatch + report."""
    import omni.usd  # noqa: E402

    from isaac_devkit.sensors import load_config, setup_sensor

    ctx = omni.usd.get_context()
    ctx.new_stage()
    for _ in range(60):
        if ctx.get_stage_state() == omni.usd.StageState.OPENED:
            break
        app.update()

    stage = ctx.get_stage()
    _build_minimal_stage(stage, args.body_mode)

    cfg = load_config(args.yaml)
    try:
        result = setup_sensor(cfg, stage)
    except Exception as exc:  # noqa: BLE001
        # ValueError from the IMU rigid-body check is the canonical
        # negative-test signal. Catch all and let the test decide via
        # the printed marker line.
        print(f"[RAISED] {type(exc).__name__}: {exc}", flush=True)
        return 1
    print(f"[OK] setup_sensor returned: {result}", flush=True)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--yaml", required=True)
    parser.add_argument("--script-dir", required=True)
    parser.add_argument("--body-mode", required=True, choices=["rigid", "xform"])
    args = parser.parse_args()

    sys.path.insert(0, args.script_dir)

    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    # Capture the exit code BEFORE app.close() because Kit's shutdown
    # path can call _exit(0) on its own, swallowing whatever returncode
    # we would otherwise propagate. Pattern lifted from the existing
    # standalone scripts under script/*.py.
    exit_code = _do_setup(args, app)
    sys.stdout.flush()
    sys.stderr.flush()
    app.close()
    sys.exit(exit_code)
