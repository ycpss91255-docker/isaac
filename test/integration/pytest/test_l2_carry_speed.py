"""GPU experiment: kinematic carry speed limit (#201 sub-issue).

Milestone "Physics: L2 true-kinematic + hybrid". The PR #215 follow-up: a
true-L2 kinematic body HOLDS a load with zero error, but the two kinematic
write paths carry a resting dynamic payload very differently (ADR-0008):

  * ``dc.set_rigid_body_pose`` (``setGlobalPose``) is a teleport that BYPASSES
    the contact integrator -- it NEVER carries a resting dynamic payload at any
    ramp step (the mover passes straight through; the payload is left at its
    start). This is the negative control.
  * ``dc.set_kinematic_target`` (``setKinematicTarget``) feeds the kinematic
    target through the contact solver, so the mover PUSHES the payload via
    contact -- it carries the payload UP TO an effective per-tick speed limit:
    ramp the mover up slowly and the payload rides along; ramp it too fast and
    contact cannot keep up, so the payload is left behind / tunnels and falls.

This experiment sweeps the per-tick ramp step under ``set_kinematic_target``
and measures the threshold (slow carry / fast drop), and confirms the
``set_rigid_body_pose`` teleport never carries. The mover starts at z=0.5 with
the payload resting at z=0.70 and is ramped to z=1.0; a carried payload ends
near z=1.20.

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

# Per-tick ramp steps swept (m / tick), spanning 200x. The slowest is ~0.06 m/s
# at 60 Hz (well within the contact-respecting carry limit); the fastest is
# ~12 m/s (far past it). The threshold is between the largest carried and the
# smallest dropped step.
SLOWEST_STEP = 0.001
FASTEST_STEP = 0.2
SWEEP_STEPS = (0.001, 0.003, 0.01, 0.05, 0.2)

_SUMMARY_RE = re.compile(
    r"\[CARRY SUMMARY\] write_mode=(\S+) ramp_step=(\S+) target=(\S+) "
    r"mover_z=(\S+) payload_z=(\S+) payload_carried=(\S+)"
)


def _run_carry(ramp_step: float, write_mode: str = "kinematic_target") -> dict:
    """Run the carry-speed runner once; parse the [CARRY SUMMARY] marker."""
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--ramp-step", str(ramp_step),
            "--write-mode", write_mode,
            "--target-z", str(TARGET_Z),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[CARRY SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- carry runner stdout ({write_mode}, ramp_step={ramp_step}) "
            f"---\n{result.stdout}\n--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, (
        f"no [CARRY SUMMARY] marker for {write_mode} ramp_step {ramp_step}"
    )
    return {
        "write_mode": m.group(1),
        "ramp_step": float(m.group(2)),
        "target": float(m.group(3)),
        "mover_z": float(m.group(4)),
        "payload_z": float(m.group(5)),
        "payload_carried": m.group(6) == "True",
    }


def _sweep_table(rows, title: str) -> str:
    """Render a ramp-step sweep as a fixed-width table (surfaced on stderr and
    copied into the recorded results doc)."""
    head = (
        f"{'write_mode':>16} {'ramp_step_m':>14} {'mover_z':>10} "
        f"{'payload_z':>12} {'carried':>9}"
    )
    lines = [f"[{title}]", head, "-" * len(head)]
    for r in rows:
        lines.append(
            f"{r['write_mode']:>16} {r['ramp_step']:>14.6g} "
            f"{r['mover_z']:>10.4f} {r['payload_z']:>12.4f} "
            f"{str(r['payload_carried']):>9}"
        )
    return "\n".join(lines)


def _surface(table: str) -> None:
    """Print a sweep table on stderr so it lands in the (passing) CI log."""
    sys.stderr.write("\n" + table + "\n")


def test_global_pose_teleport_never_carries():
    """The ``set_rigid_body_pose`` teleport never carries the payload (ADR-0008).

    ``setGlobalPose`` bypasses the contact integrator, so the kinematic mover
    passes straight through the resting dynamic payload at EVERY ramp step --
    even the slowest. The payload is left at its start (well below the carried
    floor). This is the negative control that isolates the carry mechanism to
    the ``set_kinematic_target`` contact path.
    """
    rows = [_run_carry(s, "global_pose") for s in SWEEP_STEPS]
    table = _sweep_table(rows, "global_pose (teleport, negative control)")
    _surface(table)
    for r in rows:
        assert not r["payload_carried"], (
            f"global_pose ramp_step {r['ramp_step']} m/tick carried the "
            f"payload (payload_z {r['payload_z']:.4f} m); a teleport "
            f"(setGlobalPose) must never carry -- it bypasses contact "
            f"(ADR-0008):\n{table}"
        )


def test_kinematic_target_carry_speed_threshold_is_bracketed():
    """The ``set_kinematic_target`` sweep brackets the carry speed threshold.

    Sweeps every ramp step under the contact-respecting ``set_kinematic_target``
    path, builds the carried/dropped table, and asserts:

      * the slowest step (~0.06 m/s) CARRIES the payload up onto the raised
        mover (payload_z > CARRIED_Z_FLOOR) -- contact keeps up;
      * the fastest step (~12 m/s) DROPS it -- the target outruns contact;
      * the carried/dropped split is monotone, so the threshold is bracketed
        (largest carried step < smallest dropped step).

    The bracketing per-tick displacements are reported (and recorded in
    doc/experiments/exp-201-l2-carry-speed.md).
    """
    rows = [_run_carry(s, "kinematic_target") for s in SWEEP_STEPS]
    table = _sweep_table(rows, "kinematic_target sweep")
    _surface(table)
    by_step = {r["ramp_step"]: r for r in rows}

    slow = by_step[SLOWEST_STEP]
    assert slow["payload_carried"] and slow["payload_z"] > CARRIED_Z_FLOOR, (
        f"slowest step {SLOWEST_STEP} m/tick failed to carry (payload_z "
        f"{slow['payload_z']:.4f} m); the contact path should carry here:\n"
        f"{table}"
    )
    fast = by_step[FASTEST_STEP]
    assert not fast["payload_carried"], (
        f"fastest step {FASTEST_STEP} m/tick unexpectedly carried (payload_z "
        f"{fast['payload_z']:.4f} m); it should outrun contact:\n{table}"
    )

    carried = [r["ramp_step"] for r in rows if r["payload_carried"]]
    dropped = [r["ramp_step"] for r in rows if not r["payload_carried"]]
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
