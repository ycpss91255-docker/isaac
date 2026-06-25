"""GPU experiment: an articulation (L3) joint drive's INTRINSIC tracking
precision in ISOLATION -- one actuated joint, NO contact, NO external payload
(Physics milestone "L3 control verification", issue #180 / sub-issues #181
tracking error / #182 steady-state / #183 repeatability; ADR-0021 D1).

Where the #184 droop experiment (``test_l3_drive_sag.py``) characterizes the
drive's steady-state error UNDER LOAD (the m*g/stiffness sag of a 10 kg
payload), this experiment isolates the drive's OWN precision: a fixed-base
single-prismatic lift (``single_joint_lift.urdf``, a light 1 kg moving link, no
payload, no contact) is driven through a STEP and a SMOOTH multi-point
trajectory, and three properties are measured with stepped physics:

  * **tracking error** (#181) -- max + RMS of |commanded - measured| over a
    smooth cosine-eased multi-waypoint trajectory; small (the drive follows a
    smooth command tightly).
  * **steady-state error at rest** (#182) -- |target - settled| after a step;
    tiny and bounded by the drive's m*g/stiffness floor (here m is just the
    light link mass).
  * **repeatability** (#183) -- the spread of the settled position across
    several reset-to-home / re-command cycles; near-zero (PhysX position
    control is deterministic).

Stepped physics via dynamic_control + ``omni.timeline`` + ``app.update()``
(the example/L2 path, NOT a ``SimulationContext``, #151). Critical damping
``2*sqrt(k*m)`` so the position drive settles (a zero/underdamped drive
oscillates forever). A PRISMATIC (linear) joint stores stiffness as-is (no
pi/180 -- that is angular-only).

Subprocess-per-run / marker-line pattern (``SimulationApp`` is a process-global
singleton; ``pxr`` is not importable in the bare pytest process). Runtime
requirement: the Isaac Sim / Isaac Lab devel-test GPU container. Thresholds are
BANDED (physical settling is not exact); the measured table is embedded in
every assertion message so failures surface the numbers.
"""

import math
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_l3_tracking_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 480

STEP_TARGET = 0.5
STIFFNESS = 5000.0     # moderate stiffness (per the task brief)
LINK_MASS = 1.0        # matches single_joint_lift.urdf moving link
RESET_CYCLES = 3       # repeatability cycles (#183)

# Steady-state floor for this drive: a position drive balances gravity at
# rest, so |error| ~ m*g/stiffness = 1*9.81/5000 = ~1.96 mm. The asserted
# bands are comfortably above that (settling + numerical slack) but still
# "small" -- the point of an isolated, no-payload tracking test.
_SS_FLOOR = LINK_MASS * 9.81 / STIFFNESS


def _critical_damping(stiffness: float) -> float:
    """Critical damping 2*sqrt(k*m): settles fastest with no oscillation, so
    the drive reaches steady state within the tick budget. The steady-state
    position is damping-INDEPENDENT; damping only governs the transient -- but
    a zero/underdamped drive never settles, which corrupts the reading."""
    return 2.0 * math.sqrt(stiffness * LINK_MASS)


_SUMMARY_RE = re.compile(
    r"\[TRACKING SUMMARY\] stiffness=(\S+) link_mass=(\S+) step_target=(\S+) "
    r"step_ss_err=(\S+) traj_max_err=(\S+) traj_rms_err=(\S+) "
    r"repeat_spread=(\S+) cycles=(\S+) npoints=(\S+)"
)


def _run_tracking(tmp_path: Path) -> dict:
    """Run the tracking runner once; parse the [TRACKING SUMMARY] marker."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    out = tmp_path / "single_joint_lift.usd"
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--out", str(out),
            "--stiffness", str(STIFFNESS),
            "--damping", str(_critical_damping(STIFFNESS)),
            "--step-target", str(STEP_TARGET),
            "--reset-cycles", str(RESET_CYCLES),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[TRACKING SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- tracking runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, "no [TRACKING SUMMARY] marker (runner failed; see stderr above)"
    return {
        "stiffness": float(m.group(1)),
        "link_mass": float(m.group(2)),
        "step_target": float(m.group(3)),
        "step_ss_err": float(m.group(4)),
        "traj_max_err": float(m.group(5)),
        "traj_rms_err": float(m.group(6)),
        "repeat_spread": float(m.group(7)),
        "cycles": int(float(m.group(8))),
        "npoints": int(float(m.group(9))),
    }


def _table(r: dict) -> str:
    """Render the measured metrics as a compact table for assertion messages
    (and copied into the recorded results doc)."""
    return (
        "\n  metric            value\n"
        "  ----------------  ---------------\n"
        f"  stiffness         {r['stiffness']:g} N/m\n"
        f"  link_mass         {r['link_mass']:g} kg\n"
        f"  ss_floor (m*g/k)  {_SS_FLOOR * 1e3:.4g} mm\n"
        f"  step_ss_err       {r['step_ss_err'] * 1e3:.4g} mm "
        f"({r['step_ss_err']:g} m)\n"
        f"  traj_max_err      {r['traj_max_err'] * 1e3:.4g} mm "
        f"({r['traj_max_err']:g} m)\n"
        f"  traj_rms_err      {r['traj_rms_err'] * 1e3:.4g} mm "
        f"({r['traj_rms_err']:g} m)\n"
        f"  repeat_spread     {r['repeat_spread'] * 1e6:.4g} um "
        f"({r['repeat_spread']:g} m)\n"
        f"  cycles            {r['cycles']}\n"
        f"  npoints           {r['npoints']}\n"
    )


def test_steady_state_error_is_small_and_near_load_floor(tmp_path):
    """#182: at rest after a step, the drive holds the commanded position with
    a small steady-state error -- of the order of the m*g/stiffness floor for
    the light moving link (NO external payload), not a gross miss (ADR-0021
    D1: L2.5 is an approximation whose error is load/stiffness)."""
    r = _run_tracking(tmp_path)
    tbl = _table(r)
    # Small in absolute terms: well under a centimeter for this light link.
    assert r["step_ss_err"] < 0.01, (
        f"steady-state error {r['step_ss_err']} m is not small (< 10 mm):{tbl}"
    )
    # And of the order of the analytic m*g/stiffness floor (within a generous
    # band -- settling + numerical slack, not an exact equality).
    assert r["step_ss_err"] <= _SS_FLOOR * 4 + 1e-3, (
        f"steady-state error {r['step_ss_err']} m far exceeds the "
        f"m*g/stiffness floor {_SS_FLOOR} m:{tbl}"
    )


def test_trajectory_tracking_error_is_small(tmp_path):
    """#181: over a smooth multi-point trajectory the drive follows the
    command tightly -- max and RMS of |commanded - measured| stay small (a
    well-damped position drive lags a smooth command only slightly)."""
    r = _run_tracking(tmp_path)
    tbl = _table(r)
    # Both error stats are finite and small. The max transient error of a
    # critically-damped drive following a smooth ramp is bounded; band it
    # generously (a few cm) but assert it is NOT a gross failure.
    assert math.isfinite(r["traj_max_err"]), f"non-finite traj_max_err:{tbl}"
    assert math.isfinite(r["traj_rms_err"]), f"non-finite traj_rms_err:{tbl}"
    assert r["traj_max_err"] < 0.08, (
        f"trajectory max error {r['traj_max_err']} m is not small "
        f"(< 80 mm):{tbl}"
    )
    assert r["traj_rms_err"] < 0.04, (
        f"trajectory RMS error {r['traj_rms_err']} m is not small "
        f"(< 40 mm):{tbl}"
    )
    # RMS <= max (sanity: the aggregate cannot exceed the worst point).
    assert r["traj_rms_err"] <= r["traj_max_err"] + 1e-9, (
        f"RMS {r['traj_rms_err']} exceeds max {r['traj_max_err']}:{tbl}"
    )


def test_repeatability_across_resets_is_deterministic(tmp_path):
    """#183: commanding the SAME step after a reset-to-home lands the joint at
    the SAME settled position across cycles -- the run-to-run spread is
    near-zero (PhysX position control is deterministic)."""
    r = _run_tracking(tmp_path)
    tbl = _table(r)
    assert r["cycles"] >= RESET_CYCLES, (
        f"expected >= {RESET_CYCLES} cycles, got {r['cycles']}:{tbl}"
    )
    # The settled position is identical run-to-run to well under a millimeter
    # (deterministic stepping; the spread is numerical noise, not drift).
    assert r["repeat_spread"] < 1e-3, (
        f"repeatability spread {r['repeat_spread']} m across {r['cycles']} "
        f"reset cycles is not deterministic (>= 1 mm):{tbl}"
    )
