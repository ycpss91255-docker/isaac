"""GPU integration: a captured frame is actually converged (isaac#266).

The hosted companion (``test/unit/pytest/test_render_settings.py``) pins the
recipe's SHAPE -- the mode, the sample budget, and that it is expressed as
RenderProduct prim attributes rather than the ``/rtx/*`` carb keys that turned
out to be inert. It cannot see whether the resulting frame is clean, which is
the only thing anyone cares about, so this test renders one.

``_capture_noise_runner.py`` builds one lit room and captures it twice through
the SAME render product: once as replicator creates it (Isaac Sim 6.0 defaults
to ``RealTimePathTracing`` -- one path-traced sample per pixel, denoised by
NGX / DLSS ray reconstruction), then again after the recipe is authored on the
prim. Both legs are gathered from one Kit boot because
``SimulationApp`` is a process-global singleton.

The metric is the mean absolute difference between horizontally neighbouring
pixels. Sampling noise dominates it; smooth shading barely registers. Frame
``std`` -- what isaac#266 reported -- is NOT usable as the objective on its
own: it is dominated by scene contrast and moves when the render mode
legitimately changes the image, which is exactly why every failed hypothesis in
that issue "left std unchanged" and looked equally inert.

Reference measurements on the RTX 5090 runner. Before isaac#285 the container
lacked the ``ngx`` driver capability, NGX could not be created, and the default
leg was raw single-sample noise: default ~53 (6.8% fully black pixels),
converged ~2.1. Since #285 (``gpu_capabilities = all``) NGX denoises the
default leg: default ~0.41, converged ~1.53 (CI run 34233956492, isaac#294).
Both legs are now clean, so the old relative check ("converged is 5x cleaner
than default") no longer holds and is gone. Each leg is held to an absolute
ceiling instead: the default leg regressing to ~53 means NGX dropped out of the
container again, the converged leg regressing means the recipe stopped landing.

Runtime requirement: the Isaac Sim devel-test GPU container
(``/isaac-sim/python.sh -m pytest``).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_capture_noise_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
CAPTURE_TIMEOUT_SEC = 600

_MARKER_RE = re.compile(
    r"\[CAPTURE NOISE\] leg=(\S+) mode=(\S+) noise=([0-9.]+) "
    r"std=([0-9.]+) black=([0-9.]+)"
)

# The default leg is NGX-denoised single-sample path tracing; measured ~0.41 on
# the reference runner, versus ~53 when NGX was missing (pre-#285). A ceiling
# of 10 sits far from both, so a lost NGX context fails loudly while a
# different GPU / driver still passes.
DEFAULT_CEILING = 10.0
# The converged leg measured ~1.53 (without the OptiX weights, isaac#293) and
# ~2.1 historically. A ceiling of 10 leaves room for a different GPU / driver
# without admitting a frame anyone would call speckled.
CONVERGED_CEILING = 10.0


@pytest.fixture(scope="module")
def legs():
    """Run the two-leg capture once; return {leg name: parsed marker}."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    result = subprocess.run(
        [PYTHON_SH, str(RUNNER)],
        capture_output=True,
        text=True,
        timeout=CAPTURE_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[CAPTURE NOISE]" not in result.stdout:
        sys.stderr.write(
            f"\n--- capture runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    parsed = {
        m.group(1): {
            "mode": m.group(2),
            "noise": float(m.group(3)),
            "std": float(m.group(4)),
            "black": float(m.group(5)),
        }
        for m in _MARKER_RE.finditer(result.stdout)
    }
    assert set(parsed) == {"default", "converged"}, (
        f"expected both capture legs, got {sorted(parsed)}"
    )
    return parsed


def test_default_render_product_is_denoised_by_ngx(legs):
    """The unconfigured real-time frame must come out clean (isaac#285).

    ``RealTimePathTracing`` renders one sample per pixel and relies on NGX to
    denoise it. Before #285 the container never received the ``ngx`` driver
    capability and this leg measured ~53. A regression of the capability list
    (or anything else that stops NGX coming up) sends it back there.
    """
    default = legs["default"]
    assert default["mode"] == "RealTimePathTracing"
    assert default["noise"] < DEFAULT_CEILING, (
        f"the unconfigured render product is speckled "
        f"(noise={default['noise']:.3f}); NGX is probably not available in "
        f"the container (check gpu_capabilities, isaac#279 / #285)"
    )


def test_recipe_lands_on_the_render_product_prim(legs):
    """The mode must read back as PathTracing off the live prim.

    A carb ``/rtx/rendermode`` write reads back unchanged on 6.0.1 -- this is
    the assertion that separates "applied" from "attempted".
    """
    assert legs["converged"]["mode"] == "PathTracing"


def test_converged_capture_is_clean(legs):
    """The frame the fix produces, measured rather than eyeballed."""
    converged = legs["converged"]
    assert converged["noise"] < CONVERGED_CEILING, (
        f"converged capture is still speckled (noise={converged['noise']:.3f})"
    )
    assert converged["black"] == 0.0, (
        f"converged capture still has fully black pixels "
        f"({converged['black']:.5f}); single-sample misses read as black"
    )
