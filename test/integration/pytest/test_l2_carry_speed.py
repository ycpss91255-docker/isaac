"""GPU experiment: kinematic carry speed limit (#201 sub-issue).

Milestone "Physics: L2 true-kinematic + hybrid". The PR #215 follow-up: a
true-L2 kinematic body HOLDS a load with zero error, but ``dc.set_rigid_body_
pose`` is a teleport (``setGlobalPose``) that BYPASSES the contact integrator
(ADR-0008: "must use setKinematicTarget not setGlobalPose"). So when a
kinematic mover LIFTS a resting dynamic payload, there is an effective
per-timestep carry speed limit: ramp the mover up slowly and the payload rides
along; ramp it too fast and the payload is left behind / tunnels and falls.

This experiment sweeps the per-tick ramp step and measures the threshold:
slow steps carry the payload (it rises with the mover to the target), fast
steps drop it. The mover starts at z=0.5 with the payload resting at z=0.70 and
is ramped to z=1.0; a carried payload ends near z=1.20.

Subprocess-per-run / marker-line pattern (``SimulationApp`` is a process-global
singleton; ``pxr`` / ``omni`` are not importable in the bare pytest process).
Runtime: the GPU-enabled Isaac Sim ``test`` compose service.

  Run:  ./script/run.sh -t test -- \
          /isaac-sim/python.sh -m pytest \
          test/integration/pytest/test_l2_carry_speed.py
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).parent / "_l2_carry_speed_runner.py"
FIXTURE = REPO_ROOT / "test" / "fixtures" / "usd" / "l2_carry_speed.usda"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 300

# Target height the mover is ramped up to (m). The payload starts at z=0.70.
TARGET_Z = 1.0
# A carried payload rests on the raised mover top (mover top 1.05 + payload
# half-height 0.15 = 1.20); anything at/below target_z + 0.05 = 1.05 means the
# payload was left behind.
CARRIED_Z_FLOOR = TARGET_Z + 0.05

# Per-tick ramp steps swept (m / tick). The small steps keep the payload in
# contact every tick (carried); the large steps teleport the mover past the
# payload in one tick (dropped). The threshold is between the largest carried
# and the smallest dropped step.
SLOW_STEPS = (0.001, 0.003, 0.01)
FAST_STEPS = (0.05, 0.2)
SWEEP_STEPS = SLOW_STEPS + FAST_STEPS

_SUMMARY_RE = re.compile(
    r"\[CARRY SUMMARY\] ramp_step=(\S+) target=(\S+) mover_z=(\S+) "
    r"payload_z=(\S+) payload_carried=(\S+)"
)


def _run_carry(ramp_step: float) -> dict:
    """Run the carry-speed runner at one ramp step; parse the [CARRY SUMMARY]."""
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--ramp-step", str(ramp_step),
            "--target-z", str(TARGET_Z),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[CARRY SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- carry runner stdout (ramp_step={ramp_step}) ---\n"
            f"{result.stdout}\n--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [CARRY SUMMARY] marker for ramp_step {ramp_step}"
    return {
        "ramp_step": float(m.group(1)),
        "target": float(m.group(2)),
        "mover_z": float(m.group(3)),
        "payload_z": float(m.group(4)),
        "payload_carried": m.group(5) == "True",
    }


def _sweep_table(rows) -> str:
    """Render the ramp-step sweep as a fixed-width table (surfaced in assertion
    messages and copied into the recorded results doc)."""
    head = (
        f"{'ramp_step_m':>14} {'mover_z':>10} {'payload_z':>12} "
        f"{'carried':>9}"
    )
    lines = [head, "-" * len(head)]
    for r in rows:
        lines.append(
            f"{r['ramp_step']:>14.6g} {r['mover_z']:>10.4f} "
            f"{r['payload_z']:>12.4f} {str(r['payload_carried']):>9}"
        )
    return "\n".join(lines)


def test_slow_ramp_carries_payload():
    """Slow per-tick ramp steps carry the resting payload up with the mover.

    At small ``ramp_step`` the kinematic mover never jumps past the payload in
    a single tick, so the payload stays in contact and rides up to rest on the
    raised mover (payload_z > CARRIED_Z_FLOOR).
    """
    rows = [_run_carry(s) for s in SLOW_STEPS]
    table = _sweep_table(rows)
    for r in rows:
        assert r["payload_carried"], (
            f"slow ramp_step {r['ramp_step']} m/tick failed to carry the "
            f"payload (payload_z {r['payload_z']:.4f} m); the mover should "
            f"carry the load at this speed:\n{table}"
        )
        assert r["payload_z"] > CARRIED_Z_FLOOR, (
            f"payload_z {r['payload_z']:.4f} m not above the carried floor "
            f"{CARRIED_Z_FLOOR} m at ramp_step {r['ramp_step']}:\n{table}"
        )


def test_fast_ramp_drops_payload():
    """Fast per-tick ramp steps leave the payload behind (carry FAILS).

    At large ``ramp_step`` the kinematic mover teleports past the payload in a
    single tick (``set_rigid_body_pose`` is ``setGlobalPose`` and bypasses the
    contact integrator, ADR-0008), so the payload cannot follow -- it is left
    behind / tunnels and falls (payload_z <= CARRIED_Z_FLOOR).
    """
    rows = [_run_carry(s) for s in FAST_STEPS]
    table = _sweep_table(rows)
    for r in rows:
        assert not r["payload_carried"], (
            f"fast ramp_step {r['ramp_step']} m/tick unexpectedly carried the "
            f"payload (payload_z {r['payload_z']:.4f} m); a one-tick teleport "
            f"this large should leave the payload behind:\n{table}"
        )


def test_carry_speed_threshold_is_bracketed():
    """The full sweep brackets the carry speed threshold (slow carry, fast drop).

    Sweeps every ramp step, builds the carried/dropped table, and asserts the
    threshold is bracketed: there is at least one carried step and at least one
    dropped step, the largest carried step is below the smallest dropped step,
    and the carried/dropped split is monotone (no carried step above a dropped
    step). The bracketing per-tick displacements are reported (and recorded in
    doc/experiments/exp-201-l2-carry-speed.md).
    """
    rows = [_run_carry(s) for s in SWEEP_STEPS]
    table = _sweep_table(rows)

    carried = [r["ramp_step"] for r in rows if r["payload_carried"]]
    dropped = [r["ramp_step"] for r in rows if not r["payload_carried"]]

    assert carried, f"no ramp step carried the payload:\n{table}"
    assert dropped, f"no ramp step dropped the payload:\n{table}"

    max_carried = max(carried)
    min_dropped = min(dropped)
    assert max_carried < min_dropped, (
        f"carry threshold is not bracketed: largest carried step "
        f"{max_carried} m/tick >= smallest dropped step {min_dropped} m/tick "
        f"(non-monotone carry):\n{table}"
    )
    # Monotone split: every step at or below max_carried carries, every step
    # at or above min_dropped drops.
    for r in rows:
        if r["ramp_step"] <= max_carried:
            assert r["payload_carried"], (
                f"non-monotone: ramp_step {r['ramp_step']} <= max carried "
                f"{max_carried} but was dropped:\n{table}"
            )
        if r["ramp_step"] >= min_dropped:
            assert not r["payload_carried"], (
                f"non-monotone: ramp_step {r['ramp_step']} >= min dropped "
                f"{min_dropped} but was carried:\n{table}"
            )
