"""Hosted tests for the converged-still render recipe (isaac#266).

Frames captured through the `omni.replicator.core` rgb-annotator path came out
speckled, and EVERY render knob that was tried left the frame statistically --
twice byte- -- identical. The reason both halves of that symptom exist is one
fact about Kit 108 / Isaac Sim 6.0.1:

  * a render product's RTX settings live on the RenderProduct PRIM as
    ``omni:rtx:*`` USD attributes, not in the global ``/rtx/*`` carb settings.
    The carb keys seed a product when it is created; writing them afterwards
    changes nothing, which is why every post-boot write was inert. On top of
    that ``/rtx/rendermode`` REJECTS ``"RaytracedLighting"`` on 6.0.1 -- the
    write is silently dropped and the mode stays ``RealTimePathTracing``.
  * ``RealTimePathTracing`` (the 6.0 default, and what "RTX Real-Time" now
    means) is a ONE-sample-per-pixel path tracer that leans on NGX / DLSS ray
    reconstruction to denoise. The headless container cannot create an NGX
    context, so the annotator reads the raw single-sample buffer.

The fix is the ``PathTracing`` mode -- the one that ACCUMULATES samples across
renders -- authored per render product. These tests pin the pure half of that
recipe: the mode, the sample budget, and (the part that actually encodes the
root cause) the fact that the recipe is expressed as render-product attribute
names rather than carb setting paths. The "a converged frame is measurably
clean" half needs a GPU and lives in
``test/integration/pytest/test_capture_noise.py``.

The last two tests are structural: they stop a SECOND capture path from
appearing that does not apply the recipe, and stop the inert
``/rtx/rendermode`` carb write from coming back.
"""

import importlib.util
import re
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
_MODULE = _REPO_ROOT / "src" / "script" / "viz_render.py"

# Top-level Isaac namespaces that must never load on a hosted import.
_ISAAC_TOP_LEVEL = ("omni", "pxr", "isaacsim", "isaaclab", "carb")

# Every source that may create a replicator render product.
_CAPTURE_SOURCE_DIRS = (
    _REPO_ROOT / "src" / "script",
    _REPO_ROOT / "test",
)

_CREATE_RP_RE = re.compile(r"rep\.create\.render_product\s*\(")
_CARB_RENDERMODE_RE = re.compile(r"""\.set\(\s*["']/rtx/rendermode["']""")


def _load_module():
    """Import the shared render helper by file path (it is not a package)."""
    spec = importlib.util.spec_from_file_location("viz_render", _MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _leaked_isaac_modules():
    return sorted(
        name for name in sys.modules
        if name.partition(".")[0] in _ISAAC_TOP_LEVEL
    )


def _capture_sources():
    """Every committed .py under src/script/ and test/ (no build artifacts)."""
    files = []
    for root in _CAPTURE_SOURCE_DIRS:
        for path in sorted(root.rglob("*.py")):
            if "__pycache__" in path.parts:
                continue
            files.append(path)
    return files


class _FakeAttribute:
    """Stands in for a Usd.Attribute: truthy, records what was Set()."""

    def __init__(self):
        self.value = None

    def Set(self, value):  # noqa: N802 - mirrors the pxr API
        self.value = value


class _FakePrim:
    def __init__(self, valid=True):
        self._valid = valid
        self.attributes = {}

    def IsValid(self):  # noqa: N802 - mirrors the pxr API
        return self._valid

    def GetAttribute(self, name):  # noqa: N802 - mirrors the pxr API
        return self.attributes.setdefault(name, _FakeAttribute())


class _FakeStage:
    def __init__(self, prim):
        self._prim = prim
        self.requested = None

    def GetPrimAtPath(self, path):  # noqa: N802 - mirrors the pxr API
        self.requested = path
        return self._prim


def test_module_file_exists():
    assert _MODULE.is_file(), f"missing shared render helper at {_MODULE}"


def test_hosted_import_leaves_sys_modules_isaac_free():
    """The recipe must be readable on a bare host (it is pure data)."""
    _load_module()
    leaked = _leaked_isaac_modules()
    assert leaked == [], (
        f"hosted import of viz_render leaked Isaac modules: {leaked}; "
        "every omni/pxr/carb import must be function-local"
    )


def test_render_mode_is_the_accumulating_one():
    """PathTracing accumulates across renders; the two alternatives cannot.

    ``RealTimePathTracing`` is 1 spp + an NGX denoiser that headless cannot
    create, and ``RaytracedLighting`` no longer exists on 6.0.1 (the write is
    silently rejected).
    """
    module = _load_module()
    assert module.CONVERGED_RENDER_MODE == "PathTracing"


def test_recipe_is_render_product_attributes_not_carb_keys():
    """The root cause, restated as an assertion.

    Every entry must be an ``omni:rtx:*`` attribute name on the RenderProduct
    prim. A ``/rtx/...`` carb path here would be the exact inert write that
    made isaac#266 look unfixable.
    """
    module = _load_module()
    keys = list(module.converged_still_render_vars())
    assert keys, "the recipe is empty"
    offenders = [k for k in keys if not k.startswith("omni:rtx:")]
    assert offenders == [], (
        f"{offenders} are not RenderProduct prim attributes; carb /rtx/* "
        "writes do not reach an existing render product"
    )


def test_recipe_sets_the_mode_and_the_sample_budget():
    module = _load_module()
    recipe = module.converged_still_render_vars()
    assert recipe["omni:rtx:rendermode"] == "PathTracing"
    budget = module.DEFAULT_SAMPLES_PER_PIXEL
    assert recipe["omni:rtx:pt:samplesPerPixel"] == budget
    # clampSpp is the accumulation ceiling; leaving it at its 64 default caps
    # the budget no matter what samplesPerPixel asks for.
    assert recipe["omni:rtx:pt:clampSpp"] == budget


def test_sample_budget_is_configurable():
    module = _load_module()
    recipe = module.converged_still_render_vars(samples_per_pixel=128)
    assert recipe["omni:rtx:pt:samplesPerPixel"] == 128
    assert recipe["omni:rtx:pt:clampSpp"] == 128


@pytest.mark.parametrize("bad", [0, -1])
def test_rejects_a_non_positive_sample_budget(bad):
    module = _load_module()
    with pytest.raises(ValueError):
        module.converged_still_render_vars(samples_per_pixel=bad)


def test_every_recipe_key_declares_its_usd_type():
    """A key with no declared Sdf type cannot be authored if it is missing."""
    module = _load_module()
    declared = module.RENDER_VAR_SDF_TYPE_NAMES
    missing = [k for k in module.converged_still_render_vars()
               if k not in declared]
    assert missing == [], f"no Sdf type declared for {missing}"
    assert set(declared.values()) <= {"String", "Int", "Bool", "Float"}


def test_apply_authors_every_recipe_key_on_the_render_product_prim():
    module = _load_module()
    prim = _FakePrim()
    stage = _FakeStage(prim)

    applied = module.apply_converged_render_settings(
        "/Render/OmniverseKit/HydraTextures/Replicator",
        stage=stage,
        samples_per_pixel=256,
    )

    assert stage.requested == "/Render/OmniverseKit/HydraTextures/Replicator"
    assert applied == module.converged_still_render_vars(256)
    authored = {name: attr.value for name, attr in prim.attributes.items()}
    assert authored == applied


def test_apply_rejects_a_missing_render_product_prim():
    module = _load_module()
    stage = _FakeStage(_FakePrim(valid=False))
    with pytest.raises(ValueError):
        module.apply_converged_render_settings("/Render/nope", stage=stage)


def test_every_render_product_call_site_applies_the_recipe():
    """No second capture path: creating a product means configuring it.

    A driver that creates its own ``rep.create.render_product`` and skips the
    recipe silently reintroduces isaac#266 for whatever it captures.
    """
    offenders = []
    for path in _capture_sources():
        text = path.read_text()
        if not _CREATE_RP_RE.search(text):
            continue
        if ("apply_converged_render_settings" not in text
                and "create_converged_render_product" not in text):
            offenders.append(str(path.relative_to(_REPO_ROOT)))
    assert offenders == [], (
        f"{offenders} create a render product without applying the "
        "converged-still recipe (isaac#266)"
    )


def test_no_source_writes_the_rejected_carb_render_mode():
    """Writing the render mode through a carb setting is a no-op on 6.0.1.

    The value reads back as whatever it already was, so a driver that "sets
    the render mode" that way is lying to its own JSON report.
    """
    offenders = [
        str(path.relative_to(_REPO_ROOT))
        for path in _capture_sources()
        if _CARB_RENDERMODE_RE.search(path.read_text())
    ]
    assert offenders == [], (
        f"{offenders} write /rtx/rendermode through carb; that write is "
        "silently dropped on 6.0.1 -- author omni:rtx:rendermode on the "
        "render product instead"
    )
