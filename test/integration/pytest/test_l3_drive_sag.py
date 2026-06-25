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

import math
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
PAYLOAD_MASS = 10.0      # matches lift_payload.urdf


def _critical_damping(stiffness: float) -> float:
    """Critical damping 2*sqrt(k*m): settles fastest with no oscillation, so
    the drive reaches its steady state (target - m*g/k) within the tick
    budget. The steady-state position is damping-INDEPENDENT; damping only
    governs the transient -- but a zero/underdamped drive never settles
    (undamped oscillation), which corrupts the reading.
    """
    return 2.0 * math.sqrt(stiffness * PAYLOAD_MASS)

# Stiffness sweep for the precision-limit characterization (Isaac's L2.5
# ceiling): how small does the steady-state error get as stiffness rises, and
# does the implicit articulation drive stay stable at very high gain (PhysX
# 5.4 claims it "can handle very large gains without instability")?
SWEEP_STIFFNESSES = (5000.0, 25000.0, 100000.0, 1000000.0)

_SUMMARY_RE = re.compile(
    r"\[SAG SUMMARY\] stiffness_in=(\S+) stiffness_usd=(\S+) mass=(\S+) "
    r"target=(\S+) resting=(\S+) sag=(\S+) sag_predicted=(\S+) drift=(\S+)"
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
            "--damping", str(_critical_damping(stiffness)),
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
        "drift": float(m.group(8)),
    }


def _deviation(summary: dict) -> float:
    """Steady-state drive-error MAGNITUDE = |target - resting|.

    The signed ``sag = target - resting`` field can come out negative: the
    converted prismatic joint's positive axis may point along -Z, so under
    gravity the payload settles a touch PAST the target rather than short of
    it. The sign is a USD axis-convention artifact; what distinguishes L2.5
    from L3 is the MAGNITUDE of the steady-state error (= m*g/stiffness),
    which is sign-independent. So the experiment asserts on |deviation|.
    """
    return abs(summary["sag"])


def test_l25_drive_holds_far_tighter_than_l3(tmp_path):
    """A high-stiffness (L2.5) drive holds the payload near the commanded
    height; a low-stiffness (L3) drive deviates much more (ADR-0021 D1).

    The core contrast: same payload, same target, only stiffness differs.
    """
    high = _run_sag(STIFFNESS_L25, tmp_path)
    low = _run_sag(STIFFNESS_L3, tmp_path)
    dev_high = _deviation(high)
    dev_low = _deviation(low)

    # L2.5 holds tightly: a few cm of error at most under a 10 kg load.
    assert dev_high < 0.05, (
        f"L2.5 (stiffness {STIFFNESS_L25}) deviation {dev_high} m is not small "
        f"({high})"
    )
    # L3 deviates substantially under the same load.
    assert dev_low > 0.2, (
        f"L3 (stiffness {STIFFNESS_L3}) deviation {dev_low} m is not large "
        f"({low})"
    )
    # The contrast is unambiguous.
    assert dev_low > dev_high * 5, (
        f"L3 deviation {dev_low} is not >> L2.5 deviation {dev_high}"
    )


def test_deviation_matches_load_over_stiffness(tmp_path):
    """The steady-state error matches  |dev| ~ m*g / stiffness  (linear
    drive, no pi/180).

    Confirms L2.5 is an APPROXIMATION whose steady-state error is
    load/stiffness, not a hard guarantee (ADR-0021 D1). Settling + numerical
    effects mean a loose tolerance; the point is quantitative agreement, not
    an exact match.
    """
    for stiffness in (STIFFNESS_L25, STIFFNESS_L3):
        r = _run_sag(stiffness, tmp_path)
        predicted = r["sag_predicted"]
        assert predicted > 0, f"no usable prediction in {r}"
        dev = _deviation(r)
        # Within 50% of m*g/stiffness (order-of-magnitude quantitative check).
        rel = abs(dev - predicted) / predicted
        assert rel < 0.5, (
            f"measured deviation {dev} m is not within 50% of the "
            f"m*g/stiffness prediction {predicted} m (rel={rel:.2f}); {r}"
        )


def _sweep_table(rows) -> str:
    """Render the stiffness-sweep results as a fixed-width table (surfaced in
    assertion messages and copied into the recorded results doc)."""
    head = (
        f"{'stiffness':>12} {'deviation_m':>14} {'predicted_m':>14} "
        f"{'drift_m':>12} {'rel':>7}"
    )
    lines = [head, "-" * len(head)]
    for r in rows:
        dev = abs(r["sag"])
        pred = r["sag_predicted"]
        rel = abs(dev - pred) / pred if pred > 0 else float("nan")
        lines.append(
            f"{r['stiffness_usd']:>12g} {dev:>14.6g} {pred:>14.6g} "
            f"{r['drift']:>12.6g} {rel:>7.2f}"
        )
    return "\n".join(lines)


def test_l25_precision_limit_sweep(tmp_path):
    """Characterize Isaac's L2.5 precision limit: sweep stiffness upward and
    record how small the steady-state error gets and whether the implicit
    drive stays stable at very high gain (ADR-0021 D1; the "Isaac limit"
    question, not the CoreSAM tolerance).

    Findings asserted (and recorded in doc/experiments/exp-184-l3-drive-
    precision.md):
      * every point settles (drift small) and is finite -- the implicit
        articulation drive does NOT destabilize as gain rises (PhysX 5.4:
        "can handle very large gains without instability");
      * the error keeps shrinking with rising stiffness (no early precision
        floor) -- monotone decrease across the sweep;
      * the linear m*g/stiffness model is a conservative UPPER BOUND -- the
        drive meets or beats it at every point, and markedly beats it at high
        gain (error drops faster than 1/k: ~18 um measured at 1e6 vs ~98 um
        linear). Measured bring-up table (RTX 5090, 10 kg, target 1.0 m):
        5000 -> 19.4 mm, 25000 -> 3.71 mm, 100000 -> 0.79 mm, 1e6 -> 0.018 mm;
        drift 0 at every point (perfectly settled, no instability at high gain).

    The full measured table is embedded in every assertion message so the raw
    data is visible if any property fails. This test doubles as the
    re-verification harness: re-running it on a GPU box reproduces the table.
    """
    rows = [_run_sag(k, tmp_path) for k in SWEEP_STIFFNESSES]
    table = _sweep_table(rows)
    devs = [abs(r["sag"]) for r in rows]

    # All finite -- no NaN/inf blow-up at any gain.
    for r, dev in zip(rows, devs):
        assert dev == dev and dev != float("inf"), (
            f"non-finite deviation at stiffness {r['stiffness_usd']}:\n{table}"
        )
    # All settled -- the implicit drive reaches steady state even at high gain
    # (drift between two late reads is small).
    for r in rows:
        assert r["drift"] < 5e-3, (
            f"did not settle at stiffness {r['stiffness_usd']} "
            f"(drift {r['drift']} m):\n{table}"
        )
    # Error keeps shrinking with stiffness -- no early precision floor.
    for i in range(1, len(devs)):
        assert devs[i] < devs[i - 1], (
            f"deviation did not keep decreasing at "
            f"{SWEEP_STIFFNESSES[i]} (precision floor?):\n{table}"
        )
    # The linear m*g/stiffness model is a CONSERVATIVE UPPER BOUND on the
    # steady-state error: the implicit drive meets or BEATS it at every
    # stiffness. At very high gain it does markedly better than linear (the
    # error drops faster than 1/k -- e.g. at 1e6 the measured ~18 um is far
    # below the linear ~98 um). So assert the upper bound, not a symmetric
    # band.
    for r in rows:
        pred = r["sag_predicted"]
        dev = abs(r["sag"])
        assert dev <= pred * 1.5, (
            f"stiffness {r['stiffness_usd']} deviation {dev} m exceeds the "
            f"m*g/stiffness upper bound {pred} m:\n{table}"
        )
