"""GPU experiment: L2.5 (high-stiffness drive) vs L3 (compliant drive) droop
under a payload (Physics milestone "L3 control verification", issue #184 /
sub-issue #185; ADR-0021).

This is the key requirements-deciding experiment: does a high-stiffness
articulation drive (L2.5) hold a commanded position closely enough under load,
or is the droop large enough that true-L2 (a standalone kinematic body, the
hybrid path) is needed? The synthetic ``lift_payload.urdf`` fixture (a fixed
base + one prismatic Z lift + a 10 kg payload) is driven to a target height at
two stiffnesses, and the steady-state droop is measured with stepped physics.

Unlike the structural ``test_joint_drive_integration.py`` (#168, which only
asserts the DriveAPI is configured), this STEPS physics (dynamic_control +
``omni.timeline`` + ``app.update()`` -- the example/L2 path, NOT a
``SimulationContext``, #151) and measures the actual resting position.

Findings asserted:

  * **contrast** -- a low-stiffness (L3) drive sags much more than a
    high-stiffness (L2.5) drive under the same load.
  * **prediction** -- the droop matches the analytic  sag ~ m*g / stiffness
    for a linear/prismatic drive (no pi/180; that is angular-only), confirming
    L2.5 is an APPROXIMATION of command=position whose error is
    load/stiffness, not the PhysX hard guarantee (ADR-0021 D1).

Subprocess-per-run / marker-line pattern (``SimulationApp`` is a process-global
singleton; ``pxr`` is not importable in the bare pytest process). Runtime
requirement: the Isaac Sim / Isaac Lab devel-test GPU container.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_sag_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 300

TARGET = 1.0
STIFFNESS_L25 = 5000.0   # high stiffness -> L2.5 (near command=position)
STIFFNESS_L3 = 200.0     # low stiffness  -> L3 (compliant, sags)

_SUMMARY_RE = re.compile(
    r"\[SAG SUMMARY\] stiffness_in=(\S+) stiffness_usd=(\S+) mass=(\S+) "
    r"target=(\S+) resting=(\S+) sag=(\S+) sag_predicted=(\S+)"
)


def _run_sag(stiffness: float, tmp_path: Path) -> dict:
    """Run the sag runner at a stiffness; parse the [SAG SUMMARY]."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    out = tmp_path / f"lift_{int(stiffness)}.usd"
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--out", str(out),
            "--stiffness", str(stiffness),
            "--damping", "0.0",
            "--target", str(TARGET),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[SAG SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- sag runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [SAG SUMMARY] marker for stiffness {stiffness}"
    return {
        "stiffness_in": float(m.group(1)),
        "stiffness_usd": float(m.group(2)),
        "mass": float(m.group(3)),
        "target": float(m.group(4)),
        "resting": float(m.group(5)),
        "sag": float(m.group(6)),
        "sag_predicted": float(m.group(7)),
    }


def test_l25_drive_sags_far_less_than_l3(tmp_path):
    """A high-stiffness (L2.5) drive holds the payload near the commanded
    height; a low-stiffness (L3) drive sags much more (ADR-0021 D1).

    The core contrast: same payload, same target, only stiffness differs.
    """
    high = _run_sag(STIFFNESS_L25, tmp_path)
    low = _run_sag(STIFFNESS_L3, tmp_path)

    # L2.5 holds tightly: a few cm of droop at most under a 10 kg load.
    assert 0.0 <= high["sag"] < 0.05, (
        f"L2.5 (stiffness {STIFFNESS_L25}) droop {high['sag']} m is not small "
        f"({high})"
    )
    # L3 sags substantially under the same load.
    assert low["sag"] > 0.2, (
        f"L3 (stiffness {STIFFNESS_L3}) droop {low['sag']} m is not large "
        f"({low})"
    )
    # The contrast is unambiguous.
    assert low["sag"] > high["sag"] * 5, (
        f"L3 droop {low['sag']} is not >> L2.5 droop {high['sag']}"
    )


def test_sag_matches_load_over_stiffness(tmp_path):
    """The droop matches  sag ~ m*g / stiffness  (linear drive, no pi/180).

    Confirms L2.5 is an APPROXIMATION whose steady-state error is
    load/stiffness, not a hard guarantee (ADR-0021 D1). Settling + numerical
    effects mean a loose tolerance; the point is quantitative agreement, not
    an exact match.
    """
    for stiffness in (STIFFNESS_L25, STIFFNESS_L3):
        r = _run_sag(stiffness, tmp_path)
        predicted = r["sag_predicted"]
        assert predicted > 0, f"no usable prediction in {r}"
        # Within 50% of m*g/stiffness (order-of-magnitude quantitative check).
        rel = abs(r["sag"] - predicted) / predicted
        assert rel < 0.5, (
            f"measured droop {r['sag']} m is not within 50% of the "
            f"m*g/stiffness prediction {predicted} m (rel={rel:.2f}); {r}"
        )
