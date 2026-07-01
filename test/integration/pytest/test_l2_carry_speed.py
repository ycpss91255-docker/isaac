"""GPU experiment: kinematic carry speed limit (#201 sub-issue).

Milestone "Physics: L2 true-kinematic + hybrid". The PR #215 follow-up: a
true-L2 kinematic body HOLDS a load with zero error, but the two kinematic
write paths carry a resting dynamic payload very differently (ADR-0008). Measured
on the self-hosted GPU (CI run 28174325301):

  * ``dc.set_rigid_body_pose`` (``setGlobalPose``) is a teleport that BYPASSES
    the contact integrator -- it NEVER carries a resting dynamic payload at any
    ramp step (the mover passes straight through; the payload is left at its
    start z=0.70). This is the negative control.
  * the contact-respecting kinematic TARGET write (``dc.set_kinematic_target``
    where the dc build exposes it -- this build does NOT, so a USD
    ``xformOp:translate`` write while physics plays) feeds the mover's motion
    through the contact solver, so it PUSHES the payload via contact and CARRIES
    it at every swept step. The carry OUTCOME changes with speed, though: at slow
    steps the payload settles cleanly on the mover top (payload_z ~ 1.20), while
    at the fastest step (0.2 m/tick) the contact impulse FLINGS the payload far
    above the mover (payload_z ~ 5.19). So the speed limit is a CLEAN-carry limit
    (seat vs launch), not a carry/drop limit -- the contact path never drops.

This experiment sweeps the per-tick ramp step under both write paths, confirms
the teleport never carries, and brackets the clean-carry speed limit (slow seat
/ fast launch) under the contact path. The mover starts at z=0.5 with the
payload resting at z=0.70 and is ramped to z=1.0; a cleanly carried payload ends
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
# A carried payload sits ON the raised mover top (mover top 1.05 + payload
# half-height 0.15 = 1.20); at/below target_z + 0.05 = 1.05 the payload was
# left behind (the teleport bypass). Anything above the floor was carried.
CARRIED_Z_FLOOR = TARGET_Z + 0.05
# Clean carry: the payload rests on the mover top (~1.20 m) within this band.
# Above the band the contact impulse LAUNCHED the payload off the mover.
CLEAN_REST_Z = 1.20
CLEAN_REST_BAND = 0.10  # payload_z in [1.10, 1.30] == seated on the mover

# Per-tick ramp steps swept (m / tick), spanning 200x. The slowest is ~0.06 m/s
# at 60 Hz; the fastest is ~12 m/s. Measured (CI run 28174325301): the
# contact-respecting kinematic target CARRIES at every step (the payload is
# never left behind), but the carry transitions from a CLEAN rest at slow steps
# (payload settles at ~1.20 on the mover) to a violent LAUNCH at the fastest
# step (the contact impulse flings the payload to ~5.19, far above the mover).
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


def _is_clean_rest(payload_z: float) -> bool:
    """The payload is seated on the mover top (a clean carry) iff its final Z is
    within ``CLEAN_REST_BAND`` of the resting height ``CLEAN_REST_Z`` (~1.20)."""
    return abs(payload_z - CLEAN_REST_Z) <= CLEAN_REST_BAND


def test_kinematic_target_carries_and_clean_carry_limit_is_bracketed():
    """The contact path carries at every step, and the CLEAN-carry speed limit
    is bracketed: slow steps seat the payload, a fast step LAUNCHES it.

    Sweeps every ramp step under the contact-respecting kinematic target
    (``dc.set_kinematic_target`` where available, else a USD ``xformOp:translate``
    write while physics plays) and asserts:

      * the payload is CARRIED at every step (payload_z above the carried floor)
        -- the direct contrast to ``test_global_pose_teleport_never_carries``
        (same fixture, same steps, only the write path differs);
      * the OUTCOME changes with speed -- at slow steps the payload settles
        cleanly on the mover top (payload_z ~ 1.20, ``_is_clean_rest``), at the
        fastest step the contact impulse FLINGS it well above the mover
        (measured ~5.19 m at 0.2 m/tick);
      * the slowest step is a clean rest, the fastest step is a launch, and the
        clean/launch split is monotone (the clean-carry speed limit is
        bracketed).

    So there is an effective clean-carry per-tick speed limit: below it the
    payload rides quietly; above it the kinematic motion launches it off the
    mover. The bracketing per-tick displacements are reported (and recorded in
    doc/experiments/exp-201-l2-carry-speed.md).
    """
    rows = [_run_carry(s, "kinematic_target") for s in SWEEP_STEPS]
    table = _sweep_table(rows, "kinematic_target sweep")
    _surface(table)
    by_step = {r["ramp_step"]: r for r in rows}

    # (1) The contact path carries at every step (unlike the teleport).
    for r in rows:
        assert r["payload_carried"] and r["payload_z"] > CARRIED_Z_FLOOR, (
            f"kinematic_target ramp_step {r['ramp_step']} m/tick failed to "
            f"carry the payload (payload_z {r['payload_z']:.4f} m); the "
            f"contact path should carry at every step:\n{table}"
        )

    # (2) The clean-carry speed limit: slow seats, fast launches.
    slow = by_step[SLOWEST_STEP]
    assert _is_clean_rest(slow["payload_z"]), (
        f"slowest step {SLOWEST_STEP} m/tick was not a clean rest (payload_z "
        f"{slow['payload_z']:.4f} m, expected ~{CLEAN_REST_Z}):\n{table}"
    )
    fast = by_step[FASTEST_STEP]
    assert not _is_clean_rest(fast["payload_z"]), (
        f"fastest step {FASTEST_STEP} m/tick did not launch the payload "
        f"(payload_z {fast['payload_z']:.4f} m, still within the rest band); "
        f"the contact impulse should fling it well above the mover:\n{table}"
    )

    clean = [r["ramp_step"] for r in rows if _is_clean_rest(r["payload_z"])]
    launched = [
        r["ramp_step"] for r in rows if not _is_clean_rest(r["payload_z"])
    ]
    max_clean = max(clean)
    min_launched = min(launched)
    assert max_clean < min_launched, (
        f"clean-carry limit is not bracketed: largest clean step {max_clean} "
        f"m/tick >= smallest launched step {min_launched} m/tick "
        f"(non-monotone):\n{table}"
    )
    # Monotone split: every step at or below max_clean is a clean rest, every
    # step at or above min_launched launches.
    for r in rows:
        if r["ramp_step"] <= max_clean:
            assert _is_clean_rest(r["payload_z"]), (
                f"non-monotone: ramp_step {r['ramp_step']} <= max clean "
                f"{max_clean} but launched:\n{table}"
            )
        if r["ramp_step"] >= min_launched:
            assert not _is_clean_rest(r["payload_z"]), (
                f"non-monotone: ramp_step {r['ramp_step']} >= min launched "
                f"{min_launched} but was a clean rest:\n{table}"
            )
