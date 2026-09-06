"""GPU integration: a captured frame is actually converged (isaac#266).

The hosted companion (``test/unit/pytest/test_render_settings.py``) pins the
recipe's SHAPE -- the mode, the sample budget, and that it is expressed as
RenderProduct prim attributes rather than the ``/rtx/*`` carb keys that turned
out to be inert. It cannot see whether the resulting frame is clean, which is
the only thing anyone cares about, so this test renders one.

``_capture_noise_runner.py`` builds one lit room and captures it twice through
the SAME render product: once as replicator creates it (Isaac Sim 6.0 defaults
to ``RealTimePathTracing`` -- one path-traced sample per pixel, denoised by an
NGX context the headless container cannot create), then again after the recipe
is authored on the prim. Both legs are gathered from one Kit boot because
``SimulationApp`` is a process-global singleton.

The metric is the mean absolute difference between horizontally neighbouring
pixels. Sampling noise dominates it; smooth shading barely registers. Frame
``std`` -- what isaac#266 reported -- is NOT usable as the objective on its
own: it is dominated by scene contrast and moves when the render mode
legitimately changes the image, which is exactly why every failed hypothesis in
that issue "left std unchanged" and looked equally inert.

Reference measurement on the RTX 5090 runner: default noise ~53, converged
~2.1, and the default leg renders 6.8% fully black pixels where the converged
leg renders none.

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

# The default leg is raw single-sample path tracing; measured ~53 on the
# reference runner. A floor well under that still fails if the defect is gone
# without the fix, which would mean this test proves nothing.
NOISY_FLOOR = 20.0
# The converged leg measured ~2.1. A ceiling of 10 leaves room for a different
# GPU / driver without admitting a frame anyone would call speckled.
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


def test_default_render_product_is_the_noisy_one(legs):
    """Guard the guard: without the recipe the frame must still be speckled.

    If this ever passes cheaply (a driver / Kit update brings NGX up headless),
    the comparison below stops proving anything and should be revisited.
    """
    default = legs["default"]
    assert default["mode"] == "RealTimePathTracing"
    assert default["noise"] > NOISY_FLOOR, (
        f"the unconfigured render product rendered a clean frame "
        f"(noise={default['noise']:.3f}); this test no longer proves the fix"
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
    default = legs["default"]
    assert converged["noise"] < CONVERGED_CEILING, (
        f"converged capture is still speckled (noise={converged['noise']:.3f})"
    )
    assert converged["noise"] * 5 < default["noise"], (
        f"converged capture is not materially cleaner: "
        f"{converged['noise']:.3f} vs default {default['noise']:.3f}"
    )
    assert converged["black"] == 0.0, (
        f"converged capture still has fully black pixels "
        f"({converged['black']:.5f}); single-sample misses read as black"
    )
