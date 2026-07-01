"""GPU experiment: a kinematic base CARRIES an articulation (#228; ADR-0021).

The MOST COMMON true-L2 use case, distinct from the two experiments already
done:

  * NOT #226 (a serial articulation chain -- all links inside ONE
    articulation).
  * NOT #221 (a kinematic anchor joined to a separate dynamic body by a
    maximal-coordinate FixedJoint -- a soft seam).

Here the base is a STANDALONE kinematic rigid body that MOVES on the floor
(scripted accel -> cruise -> decel -> stop path, true L2 per ADR-0021 D2)
while a small ARTICULATION (a 1-DOF prismatic "arm") rides ON TOP of it. The
arm articulation prim is a CHILD of the base group prim in the USD stage
(topology A -- USD-hierarchy parent, NO joint, NO seam; a PhysX articulation
LINK cannot be kinematic, ADR-0021 D2, so the base cannot be a link of the
arm). Two things are measured:

  1. RIDE-ALONG -- when the kinematic base translates, does the arm follow
     (its world pose tracks the base) or lag / detach? Recorded as the
     ride-along tracking error (arm displacement vs base displacement).

  2. BASE-MOTION DISTURBANCE -- with the arm slide commanded to HOLD, the base
     is driven through accel -> cruise -> decel -> stop; the held slide's PEAK
     deviation during accel/decel and its RESIDUAL after the base stops are
     recorded.

The OPEN QUESTION the GPU run answers: whether topology (A) actually carries
the articulation (rigid hierarchy carry -> ride-along error ~0 AND disturbance
~0; contact-friction carry -> small ride-along error AND a non-zero
disturbance; no carry -> ride-along error ~ base displacement AND disturbance
~0). If (A) does not carry, a FixedJoint (topology B, the #221 seam) is forced.

The Kit side runs in `_base_carry_runner.py` (one `SimulationApp` per process
-- the singleton constraint; `pxr` is not importable in the bare pytest
process). One runner invocation prints BOTH marker lines (`[CARRY SUMMARY]`
and `[BASE COUPLING SUMMARY]`); this module parses them and asserts with
DELIBERATELY LOOSE bands -- the point is to RECORD the numbers (into
`doc/experiments/exp-228-base-carry.md`), not to gate tightly.

Stepping is `dynamic_control` + `omni.timeline` + `app.update()` (the proven
example / L2-stability path), NOT a `SimulationContext` (the #151
shutdown-hang surface). Runtime: inside the Isaac Sim / Isaac Lab devel-test
GPU container (`./script/run.sh -t test -- /isaac-sim/python.sh -m pytest`).
"""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).parent / "_base_carry_runner.py"
FIXTURE = REPO_ROOT / "test" / "fixtures" / "usd" / "l2_base_carry.usda"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 600

# Base translate profile (accel -> cruise -> decel -> stop), passed to the
# runner. A ~1.5 m horizontal path: 2 m/s^2 up to 1 m/s (30 ticks at 60 Hz,
# ~0.25 m), 60 ticks of cruise (~1.0 m), then a symmetric decel (~0.25 m).
BASE_ACCEL = 2.0        # m/s^2 during accel/decel
CRUISE_SPEED = 1.0      # m/s cruise
CRUISE_TICKS = 60       # ticks at cruise
DT = 1.0 / 60.0         # physics step (s)

# Only run where Isaac Sim is present (inside the devel-test GPU container);
# on a plain host the module is collected but skipped (no subprocess spawn).
requires_isaac = pytest.mark.skipif(
    not Path("/isaac-sim").is_dir(),
    reason="GPU integration: requires Isaac Sim (/isaac-sim) -- skipped on host",
)
pytestmark = requires_isaac


_CARRY_RE = re.compile(
    r"\[CARRY SUMMARY\] base_disp=(\S+) arm_disp=(\S+) ride_along_err=(\S+) "
    r"ride_along_peak_err=(\S+) tracked=(\S+)"
)
_COUPLING_RE = re.compile(
    r"\[BASE COUPLING SUMMARY\] hold_target=(\S+) equilibrium=(\S+) "
    r"peak_dev=(\S+) residual=(\S+) base_disp=(\S+) base_accel=(\S+) "
    r"cruise_speed=(\S+)"
)


@pytest.fixture(scope="module")
def carry_run():
    """Run the base-carry runner ONCE (one SimulationApp), share its stdout.

    A single invocation performs both measurements and prints both
    `[CARRY SUMMARY]` and `[BASE COUPLING SUMMARY]` marker lines.
    """
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--accel", str(BASE_ACCEL),
            "--cruise-speed", str(CRUISE_SPEED),
            "--cruise-ticks", str(CRUISE_TICKS),
            "--dt", str(DT),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[CARRY SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- base-carry runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    return result


def _parse_carry(stdout: str) -> dict:
    m = _CARRY_RE.search(stdout)
    assert m, f"no [CARRY SUMMARY] marker:\n{stdout}"
    return {
        "base_disp": float(m.group(1)),
        "arm_disp": float(m.group(2)),
        "ride_along_err": float(m.group(3)),
        "ride_along_peak_err": float(m.group(4)),
        "tracked": m.group(5) == "True",
    }


def _parse_coupling(stdout: str) -> dict:
    m = _COUPLING_RE.search(stdout)
    assert m, f"no [BASE COUPLING SUMMARY] marker:\n{stdout}"
    return {
        "hold_target": float(m.group(1)),
        "equilibrium": float(m.group(2)),
        "peak_dev": float(m.group(3)),
        "residual": float(m.group(4)),
        "base_disp": float(m.group(5)),
        "base_accel": float(m.group(6)),
        "cruise_speed": float(m.group(7)),
    }


def test_runner_clean_exit(carry_run):
    """The base-carry runner boots, measures, and exits cleanly (no [RAISED])."""
    assert carry_run.returncode == 0, "base-carry runner exited non-zero"
    assert "[EXIT CLEAN]" in carry_run.stdout
    assert "[RAISED]" not in carry_run.stdout


def test_ride_along_tracking_recorded(carry_run):
    """The arm's ride-along tracking error is measured and finite (#228).

    Loose properties (RECORDED, not tightly gated -- whether topology A carries
    the articulation is the open question this experiment answers): the base
    displacement, the arm displacement, and the ride-along error are all
    finite; the ride-along error is non-negative; and the arm cannot lag the
    base by MORE than the base actually moved (plus a small slop margin) -- a
    stationary arm gives ride_along_err ~ base_disp, a perfectly carried arm
    gives ~0. The recorded `tracked` flag captures which regime the GPU run
    landed in.
    """
    c = _parse_carry(carry_run.stdout)
    for key in ("base_disp", "arm_disp", "ride_along_err", "ride_along_peak_err"):
        v = c[key]
        assert v == v and v != float("inf"), f"non-finite {key} in {c}"
    assert c["ride_along_err"] >= 0.0, f"negative ride-along error in {c}"
    assert c["ride_along_err"] <= abs(c["base_disp"]) + 0.6, (
        f"ride-along error {c['ride_along_err']} m exceeds the base "
        f"displacement {c['base_disp']} m by more than the slop margin -- the "
        f"arm cannot lag the base by more than the base moved; {c}"
    )


def test_base_motion_disturbance_bounded_and_settles(carry_run):
    """Driving the base through accel/decel disturbs the held slide only
    TRANSIENTLY: it may deviate during the motion but SETTLES BACK after the
    base stops (bounded coupling, not a permanent offset) (#228; ADR-0021).

    Loose properties (RECORDED, not tightly gated): the held-slide peak
    deviation and residual are finite and non-negative; the residual is small
    in absolute terms (the slide returned toward its hold) AND no larger than
    the peak transient (it settled BACK, did not diverge). These hold in every
    carry regime, including the null case where the base does not move the arm
    (peak ~ residual ~ 0).
    """
    cp = _parse_coupling(carry_run.stdout)
    for key in ("peak_dev", "residual"):
        v = cp[key]
        assert v == v and v != float("inf"), f"non-finite {key} in {cp}"
        assert v >= 0.0, f"negative {key} in {cp}"
    # The held slide returns: residual is small in absolute terms.
    assert cp["residual"] < 0.1, (
        f"held-slide residual deviation {cp['residual']} m is not small -- the "
        f"base motion left a permanent offset, not a transient; {cp}"
    )
    # And the residual is no larger than the peak: the slide settled BACK (a
    # small numerical margin so a near-zero peak does not flake).
    assert cp["residual"] <= cp["peak_dev"] + 1e-3, (
        f"residual {cp['residual']} m exceeds peak {cp['peak_dev']} m -- the "
        f"held slide diverged instead of settling back; {cp}"
    )
