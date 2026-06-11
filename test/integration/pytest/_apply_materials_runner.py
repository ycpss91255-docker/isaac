"""Kit-side runner for L2 integration test.

Not a pytest test (filename intentionally starts with ``_`` so pytest
does not collect it). Invoked by ``test_material_setup_integration.py``
as a subprocess so the ``SimulationApp`` singleton starts fresh per
invocation. The test asserts on side effects (saved USD content); this
runner does the Kit work and exits with a clear status code.

CLI:

    /isaac-sim/python.sh _apply_materials_runner.py \\
        --usd-root <path to <name>.usd> \\
        --yaml <path to material.yaml> \\
        --model-dir <model directory> \\
        --script-dir <repo>/framework
"""

import argparse
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--usd-root", required=True)
    parser.add_argument("--yaml", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--script-dir", required=True)
    args = parser.parse_args()

    sys.path.insert(0, args.script_dir)

    # Boot Kit BEFORE importing isaac_devkit.materials -- apply_materials
    # inside materials imports omni.kit.commands / pxr.UsdShade at call
    # time, both of which require an active Kit instance.
    from isaacsim import SimulationApp
    app = SimulationApp({"headless": True})

    try:
        import omni.usd  # noqa: E402

        from isaac_devkit.materials import apply_materials, load_material_config

        ctx = omni.usd.get_context()
        if not ctx.open_stage(args.usd_root):
            print(f"[FAIL] open_stage returned False for {args.usd_root}", flush=True)
            return 1

        # Wait for the stage to fully open before mutating it.
        for _ in range(600):
            if ctx.get_stage_state() == omni.usd.StageState.OPENED:
                break
            app.update()
        else:
            print("[FAIL] stage never reached OPENED state", flush=True)
            return 1

        stage = ctx.get_stage()
        cfg = load_material_config(args.yaml)

        # ADR-0010 L2: material edits (variant set + OmniPBR binds) MUST
        # land in the material sublayer, not the root. Without retargeting
        # they default to the root layer and we lose the
        # geometry-vs-material separation that ADR-0010 demands. Find the
        # material sublayer by filename suffix and set it as the edit
        # target for the apply_materials call.
        from pxr import Usd
        material_layer = next(
            (
                layer
                for layer in stage.GetUsedLayers()
                if layer.identifier.endswith("_material.usda")
            ),
            None,
        )
        if material_layer is None:
            print("[FAIL] material sublayer not found in stage", flush=True)
            return 1

        with Usd.EditContext(stage, Usd.EditTarget(material_layer)):
            apply_materials(cfg, stage, args.model_dir)

        # Persist both layers so the test process can inspect them.
        stage.GetRootLayer().Save()
        material_layer.Save()
        print("[OK] apply_materials completed and saved", flush=True)
        return 0
    finally:
        # SimulationApp.close() can prune subsequent prints, so flush + close last.
        sys.stdout.flush()
        sys.stderr.flush()
        app.close()


if __name__ == "__main__":
    sys.exit(main())
