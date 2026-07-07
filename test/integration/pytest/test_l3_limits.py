"""GPU experiment: L3 drive LIMITATIONS -- effort saturation + joint-limit
clamp (Physics milestone "L3 control verification", issue #188; ADR-0021).

The L3 / L2.5 sag experiment (#184) showed the steady-state error is
``m*g / stiffness`` -- raise stiffness, shrink the error. This experiment
records the LIMITATIONS that stiffness CANNOT overcome:

  * **effort saturation** -- the joint's ``<limit effort>`` caps the drive
    force. When the payload weight ``m*g`` exceeds the cap, the drive simply
    cannot output enough force; the steady-state error is set by the effort
    cap, NOT by stiffness. The same high-stiffness command that fails when
    capped REACHES the target once the cap is raised above ``m*g`` -- so the
    failure is the cap, not the gain. (Raising k does not help: the
    ``m*g/k`` term is already tiny at high k; what dominates is that the
    drive is force-limited below the load.)
  * **joint-limit clamp** -- a command beyond the joint's ``upper`` (or
    below ``lower``) mechanical travel limit clamps at the limit. The joint
    physically cannot pass its stop regardless of the commanded target.

The angular-vs-prismatic gain scaling (``* pi/180`` on revolute joints,
NONE on prismatic) is already confirmed by Isaac #168 / ``test_joint_drive_
integration.py``; it is noted in the results doc, NOT re-tested here.

Unlike the structural ``test_joint_drive_integration.py`` (#168, which only
asserts the DriveAPI is configured), this STEPS physics (dynamic_control +
``omni.timeline`` + ``app.update()`` -- the example/L2 path, NOT a
``SimulationContext``, #151) and measures the actual resting position.

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
RUNNER = Path(__file__).parent / "_l3_limits_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 300

PAYLOAD_MASS = 5.0       # matches lift_capped.urdf
GRAVITY = 9.81
WEIGHT_N = PAYLOAD_MASS * GRAVITY   # ~49.05 N
STIFFNESS = 50000.0      # high enough that m*g/k is sub-mm -- so the gap
                         # measured under the cap is saturation, not droop.
EFFORT_CAP = 30.0        # BELOW the 49 N weight -> the drive saturates.
EFFORT_RAISED = 500.0    # ABOVE the weight -> the drive reaches freely.
TARGET_SATURATE = 0.8    # inside the [0, 1] travel, so the only obstacle is
                         # the effort cap (not the joint limit).
TARGET_CLAMP = 5.0       # WAY past the upper=1.0 limit -> clamp.
UPPER_LIMIT = 1.0        # matches lift_capped.urdf <limit upper>.

_SUMMARY_RE = re.compile(r"\[LIMITS SUMMARY\] (.+)")


def _critical_damping(stiffness: float) -> float:
    """Critical damping 2*sqrt(k*m): settles fastest with no oscillation."""
    return 2.0 * math.sqrt(stiffness * PAYLOAD_MASS)


def _parse_kv(line: str) -> dict:
    """Parse a 'k=v k=v ...' marker tail into a typed dict."""
    out = {}
    for tok in line.split():
        if "=" not in tok:
            continue
        k, v = tok.split("=", 1)
        try:
            out[k] = float(v)
        except ValueError:
            out[k] = v
    return out


def _run_limits(mode: str, target: float, tmp_path: Path) -> dict:
    """Run the limits runner in a mode; parse the [LIMITS SUMMARY]."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    out = tmp_path / f"lift_capped_{mode}.usd"
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--out", str(out),
            "--mode", mode,
            "--stiffness", str(STIFFNESS),
            "--damping", str(_critical_damping(STIFFNESS)),
            "--target", str(target),
            "--effort", str(EFFORT_CAP),
            "--effort-raised", str(EFFORT_RAISED),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[LIMITS SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- limits runner ({mode}) stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [LIMITS SUMMARY] marker for mode {mode}"
    return _parse_kv(m.group(1))


def test_effort_saturation_caps_steady_state_error(tmp_path):
    """When the payload weight exceeds the joint effort cap, the drive
    SATURATES -- it cannot reach the commanded target however high the
    stiffness; and once the cap is raised above the weight the SAME command
    reaches the target (ADR-0021 D1, the saturation limit).

    The failure is the effort cap, not the gain: stiffness is fixed (50000,
    so the m*g/k droop is sub-mm); the only difference between the two reads
    is the effort cap (30 N < 49 N weight, then 500 N > weight).
    """
    r = _run_limits("saturate", TARGET_SATURATE, tmp_path)
    weight = r["weight_n"]
    cap = r["effort_cap"]
    raised = r["effort_raised"]
    gap_capped = r["gap_capped"]
    gap_uncapped = r["gap_uncapped"]

    # Sanity: the regime is genuinely an overload (cap below weight) and the
    # raised cap clears it.
    assert cap < weight, (
        f"effort cap {cap} N is not below the payload weight {weight} N; "
        f"this is not a saturation regime ({r})"
    )
    assert raised > weight, (
        f"raised effort cap {raised} N is not above the weight {weight} N ({r})"
    )

    # Capped: the drive cannot hold the weight, so the payload sits FAR below
    # the target (a large positive gap). It cannot even hold position -- it
    # sags well past any m*g/stiffness droop.
    assert gap_capped > 0.2, (
        f"effort-saturated drive gap {gap_capped} m is not large; the cap "
        f"did not visibly saturate the drive ({r})"
    )
    # Uncapped: the SAME high-stiffness command now reaches the target (small
    # residual = the m*g/stiffness droop only, sub-cm).
    assert abs(gap_uncapped) < 0.05, (
        f"with the effort cap raised above the weight, the drive should "
        f"reach the target; residual gap {gap_uncapped} m is too large ({r})"
    )
    # The contrast is unambiguous: the capped gap dwarfs the uncapped one,
    # at IDENTICAL stiffness -- so the error is set by the effort cap, not k.
    assert abs(gap_capped) > abs(gap_uncapped) * 10, (
        f"capped gap {gap_capped} is not >> uncapped gap {gap_uncapped}; the "
        f"saturation contrast is not established ({r})"
    )


def test_joint_limit_clamps_overshoot_command(tmp_path):
    """A command beyond the joint's upper mechanical limit clamps AT the
    limit -- the joint physically cannot pass its stop, whatever the target
    (ADR-0021 D1, the joint-limit clamp).

    The effort cap is raised above the weight first, so the drive moves
    freely and it is the LIMIT (not saturation) that stops it.
    """
    r = _run_limits("clamp", TARGET_CLAMP, tmp_path)
    upper = r["upper_limit"]
    target = r["target"]
    resting = r["resting"]
    overshoot = r["clamp_overshoot"]

    # The commanded target is well past the travel stop.
    assert target > upper + 1.0, (
        f"clamp target {target} m is not well past the upper limit {upper} m "
        f"-- the test is mis-parameterized ({r})"
    )
    # The joint rests AT (not past) the upper limit: a small band around it,
    # and it did NOT chase the far target.
    assert abs(overshoot) < 0.1, (
        f"joint did not clamp at its upper limit {upper} m: resting {resting} "
        f"m, overshoot {overshoot} m ({r})"
    )
    assert resting < target - 1.0, (
        f"joint resting {resting} m is suspiciously close to the commanded "
        f"target {target} m -- it should have clamped far short at the "
        f"limit {upper} m ({r})"
    )
    # Finite / settled witness: a clamped joint is not oscillating off its
    # stop.
    assert r["drift"] < 5e-3, (
        f"clamped joint did not settle (drift {r['drift']} m) ({r})"
    )
