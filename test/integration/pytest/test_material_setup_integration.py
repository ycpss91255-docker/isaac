"""L2 Asset Structure integration test.

End-to-end coverage for ``isaac_devkit.materials`` against an openbase
USD freshly produced by ``isaac_devkit.model_import``. The Kit side of
the work happens in ``_apply_materials_runner.py`` (subprocess so
SimulationApp can start fresh); this file owns fixture setup and
assertions on the resulting on-disk USD.

The contract verified (#35 L2 slice):

- ``apply_materials`` in variant mode creates a USD Variant Set named
  ``color`` with all declared variants (ADR-0010 L2 variant pattern).
- The default variant ends up selected (so opening the USD in Isaac
  Sim shows a sensible appearance with no extra click).
- The Kit invocation exits 0 (so material binding side effects
  actually executed, not just placeholder writes).
"""

import os
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
OPENBASE_URDF = REPO_ROOT / "src" / "model" / "urdf" / "robot" / "openbase" / "openbase_minimal.urdf"
RUNNER_SCRIPT = Path(__file__).parent / "_apply_materials_runner.py"
FRAMEWORK_DIR = REPO_ROOT / "framework"
PYTHON_SH = "/isaac-sim/python.sh"
SUBPROC_TIMEOUT_SEC = 240


def _run(cmd):
    env = dict(os.environ)
    env["PYTHONPATH"] = str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    return subprocess.run(
        cmd, capture_output=True, text=True, timeout=SUBPROC_TIMEOUT_SEC, env=env
    )


def _assert_ok(result, label):
    if result.returncode != 0:
        sys.stderr.write(
            f"\n--- {label} stdout ---\n{result.stdout}\n--- stderr ---\n{result.stderr}\n"
        )
    assert result.returncode == 0, f"{label} exit {result.returncode}"


@pytest.fixture
def openbase_model(tmp_path):
    """Import openbase into ``tmp_path`` and return the model directory."""
    out = tmp_path / "openbase"
    out.mkdir()
    result = _run([
        PYTHON_SH, "-m", "isaac_devkit.model_import",
        "--urdf", str(OPENBASE_URDF),
        "--output", str(out),
        "--name", "openbase",
    ])
    _assert_ok(result, "import_model")
    return out


def _write_variant_yaml(model_dir: Path) -> Path:
    yaml_path = model_dir / "material.yaml"
    yaml_path.write_text(textwrap.dedent("""\
        # Minimal variant fixture for the L2 integration test.
        # Two solid OmniPBR materials on base_link so the variant set
        # has at least one prim binding to verify.
        default_variant: red
        variants:
          red:
            /open_base/base_link:
              shader: OmniPBR
              diffuse: [1.0, 0.0, 0.0]
          blue:
            /open_base/base_link:
              shader: OmniPBR
              diffuse: [0.0, 0.0, 1.0]
        """), encoding="utf-8")
    return yaml_path


def test_apply_materials_creates_variant_set(openbase_model):
    yaml_path = _write_variant_yaml(openbase_model)
    root_usd = openbase_model / "openbase.usd"

    result = _run([
        PYTHON_SH, str(RUNNER_SCRIPT),
        "--usd-root", str(root_usd),
        "--yaml", str(yaml_path),
        "--model-dir", str(openbase_model),
        "--script-dir", str(FRAMEWORK_DIR),
    ])
    _assert_ok(result, "apply_materials_runner")

    material_text = (openbase_model / "openbase_material.usda").read_text(encoding="utf-8")

    # Variant set named "color" carrying both declared variants.
    assert 'variantSet "color"' in material_text or 'variantSet \'color\'' in material_text, (
        "apply_materials did not write a 'color' variant set into the "
        "material sublayer. Material content head:\n" + material_text[:500]
    )
    assert '"red"' in material_text, "variant 'red' missing from saved material .usda"
    assert '"blue"' in material_text, "variant 'blue' missing from saved material .usda"


def test_apply_materials_selects_default_variant(openbase_model):
    yaml_path = _write_variant_yaml(openbase_model)
    root_usd = openbase_model / "openbase.usd"

    result = _run([
        PYTHON_SH, str(RUNNER_SCRIPT),
        "--usd-root", str(root_usd),
        "--yaml", str(yaml_path),
        "--model-dir", str(openbase_model),
        "--script-dir", str(FRAMEWORK_DIR),
    ])
    _assert_ok(result, "apply_materials_runner")

    # USD ASCII serializes the per-prim variant selection as
    # ``variants = { string <set_name> = "<variant_name>" }`` block on the
    # prim spec. apply_materials sets the selection to default_variant
    # after AddVariant; with YAML's default_variant: red, the saved layer
    # should carry exactly that selection for the ``color`` variant set.
    material_text = (openbase_model / "openbase_material.usda").read_text(encoding="utf-8")
    assert 'string color = "red"' in material_text, (
        "default_variant 'red' selection not persisted on base_link in "
        "the material sublayer. Content head:\n" + material_text[:600]
    )
