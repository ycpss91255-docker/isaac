"""GPU experiment: multi-joint coupling in a serial position-drive chain
(Physics milestone, issue #226; ADR-0021).

The single-DOF experiments (EXP-184 sag / #180 tracking / #193 hold) each
drive ONE joint, so they cannot answer two multi-joint questions:

  1. SAG ACCUMULATION -- does a position-drive's steady-state error COMPOUND
     down a serial chain? With N joints in series, the base-most joint bears
     all the links above it (sags most) and each child inherits its parent's
     sag, so the chain-TIP total error should be the SUM of the per-joint
     mg/k sags. This test measures the tip error and compares it to the
     summed single-joint prediction.

  2. CROSS-JOINT DISTURBANCE -- step-move joint 0 while joints 1 and 2 hold.
     Does a held joint deviate during the transient (reaction / inertial
     coupling through the articulation solver), and does it settle back? This
     test measures the peak transient deviation and the residual steady-state
     error of the held joints.

Both are PhysX articulation-solver properties, so the synthetic,
license-clean primitive-box chain (`test/fixtures/urdf/multi_joint_chain.urdf`
-- three prismatic Z-lift joints, 5 kg links) is a faithful probe. It is NOT
the real forklift model.

The Kit side runs in `_multijoint_runner.py` (one `SimulationApp` per
process -- the singleton constraint; `pxr` is not importable in the bare
pytest process). One runner invocation prints BOTH marker lines
(`[CHAIN SUMMARY]` and `[COUPLING SUMMARY]`); this module parses them and
asserts with DELIBERATELY LOOSE bands -- the point is to RECORD the numbers
(into `doc/experiments/exp-226-multijoint-coupling.md`), not to gate tightly.

Stepping is `dynamic_control` + `omni.timeline` + `app.update()` (the proven
example / L2-stability path), NOT a `SimulationContext` (the #151
shutdown-hang surface). Runtime: inside the Isaac Sim / Isaac Lab devel-test
GPU container (`./script/run.sh -t test -- /isaac-sim/python.sh -m pytest`).
"""

import math
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_multijoint_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 600

# Chain drive gains for the recorded run. A moderate stiffness so the sag is
# clearly measurable (~cm) and ordered base > middle > tip, well inside the
# +/- 1.5 m joint limits.
STIFFNESS = 5000.0
# Link masses declared in multi_joint_chain.urdf (base -> tip).
LINK_MASSES = (5.0, 5.0, 5.0)
TOTAL_MASS = sum(LINK_MASSES)  # the load the base-most joint bears
SAG_TARGET = 0.0   # every joint commanded to hold at its home extension
STEP_TARGET = 0.5  # joint 0 step-move for the disturbance measurement

# Only run where Isaac Sim is present (inside the devel-test GPU container);
# on a plain host the module is collected but skipped (no subprocess spawn).
requires_isaac = pytest.mark.skipif(
    not Path("/isaac-sim").is_dir(),
    reason="GPU integration: requires Isaac Sim (/isaac-sim) -- skipped on host",
)
pytestmark = requires_isaac


def _critical_damping(stiffness: float, mass: float) -> float:
    """Critical damping 2*sqrt(k*m): settles fastest with no oscillation so
    the chain reaches steady state within the tick budget. The steady-state
    position is damping-INDEPENDENT; damping only governs the transient. Use
    the base-most joint's borne mass (the whole chain) as the reference so no
    joint is left underdamped.
    """
    return 2.0 * math.sqrt(stiffness * mass)


_CHAIN_RE = re.compile(
    r"\[CHAIN SUMMARY\] stiffness_usd=(\S+) masses=(\S+) target=(\S+) "
    r"restings=(\S+) sags=(\S+) tip_error=(\S+) per_joint_pred=(\S+) "
    r"sag_predicted_sum=(\S+)"
)
_COUPLING_RE = re.compile(
    r"\[COUPLING SUMMARY\] step_target=(\S+) j0_final=(\S+) holds=(\S+) "
    r"peak_dev=(\S+) residual=(\S+) max_peak_dev=(\S+) max_residual=(\S+)"
)


def _floats(csv: str) -> list:
    return [float(x) for x in csv.split(",")]


@pytest.fixture(scope="module")
def chain_run():
    """Run the chain runner ONCE (one SimulationApp), share its stdout.

    A single invocation performs both sub-measurements and prints both
    `[CHAIN SUMMARY]` and `[COUPLING SUMMARY]` marker lines.
    """
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--out", "/tmp/multi_joint_chain.usd",
            "--stiffness", str(STIFFNESS),
            "--damping", str(_critical_damping(STIFFNESS, TOTAL_MASS)),
            "--sag-target", str(SAG_TARGET),
            "--step-target", str(STEP_TARGET),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[CHAIN SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- multijoint runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    return result


def _parse_chain(stdout: str) -> dict:
    m = _CHAIN_RE.search(stdout)
    assert m, f"no [CHAIN SUMMARY] marker:\n{stdout}"
    return {
        "stiffness_usd": float(m.group(1)),
        "masses": _floats(m.group(2)),
        "target": float(m.group(3)),
        "restings": _floats(m.group(4)),
        "sags": _floats(m.group(5)),
        "tip_error": float(m.group(6)),
        "per_joint_pred": _floats(m.group(7)),
        "sag_predicted_sum": float(m.group(8)),
    }


def _parse_coupling(stdout: str) -> dict:
    m = _COUPLING_RE.search(stdout)
    assert m, f"no [COUPLING SUMMARY] marker:\n{stdout}"
    return {
        "step_target": float(m.group(1)),
        "j0_final": float(m.group(2)),
        "holds": _floats(m.group(3)),
        "peak_dev": _floats(m.group(4)),
        "residual": _floats(m.group(5)),
        "max_peak_dev": float(m.group(6)),
        "max_residual": float(m.group(7)),
    }


def test_runner_clean_exit(chain_run):
    """The chain runner boots, measures, and exits cleanly (no [RAISED])."""
    assert chain_run.returncode == 0, "multijoint runner exited non-zero"
    assert "[EXIT CLEAN]" in chain_run.stdout
    assert "[RAISED]" not in chain_run.stdout


def test_sag_accumulates_down_chain(chain_run):
    """Drive error COMPOUNDS down the chain: the base-most joint sags more
    than the tip-most joint, and the chain-TIP total error EXCEEDS any single
    joint's sag (accumulation, ADR-0021).

    Loose properties (recorded, not tightly gated): every per-joint sag is
    finite; the base joint (bears 15 kg) sags more than the tip joint (bears
    5 kg); the cumulative tip error is larger than the largest single-joint
    sag -- the definition of accumulation.
    """
    c = _parse_chain(chain_run.stdout)
    sags = [abs(s) for s in c["sags"]]
    assert len(sags) == 3, f"expected 3 joint sags, got {c['sags']}"
    for s in sags:
        assert s == s and s != float("inf"), f"non-finite sag in {c}"
    # Base-most joint bears the most mass -> sags more than the tip joint.
    assert sags[0] > sags[2], (
        f"base joint sag {sags[0]} not greater than tip joint sag {sags[2]} "
        f"(expected accumulation of borne load); {c}"
    )
    # The tip's cumulative error exceeds any single joint's local sag.
    assert c["tip_error"] > max(sags), (
        f"tip_error {c['tip_error']} does not exceed the largest single-joint "
        f"sag {max(sags)} -- no accumulation? {c}"
    )


def test_tip_error_matches_summed_prediction(chain_run):
    """The chain-tip error tracks the SUMMED single-joint mg/k prediction
    (ADR-0021: drive error compounds linearly down a serial chain).

    Deliberately LOOSE band: the articulation solver's coupling, settling,
    and the drive beating the linear model at the extremes mean the tip error
    need only be the right order of magnitude of the summed prediction -- the
    point is to record quantitative agreement, not to gate.
    """
    c = _parse_chain(chain_run.stdout)
    pred = c["sag_predicted_sum"]
    assert pred > 0, f"no usable summed prediction in {c}"
    tip = c["tip_error"]
    # Linear mg/k is a conservative UPPER bound; the drive may beat it. Keep a
    # wide two-sided band so the recorded number is what is asserted.
    assert tip <= pred * 1.6, (
        f"tip_error {tip} m far exceeds the summed mg/k prediction {pred} m; "
        f"{c}"
    )
    assert tip >= pred * 0.3, (
        f"tip_error {tip} m is far below the summed mg/k prediction {pred} m "
        f"(unexpected -- accumulation should be near the summed model); {c}"
    )


def test_cross_joint_disturbance_is_bounded_and_settles(chain_run):
    """A step-move of joint 0 disturbs the held joints only TRANSIENTLY: they
    may deviate during the transient but SETTLE BACK (bounded coupling, not a
    permanent offset) (ADR-0021: cross-joint coupling is bounded).

    Loose properties (recorded, not tightly gated): the step actually moved
    joint 0 (so the disturbance was real); the peak deviation of the held
    joints is finite; the residual steady-state deviation is small in
    absolute terms AND no larger than the peak transient -- the held joints
    return toward where they were holding.
    """
    cp = _parse_coupling(chain_run.stdout)
    # The disturbance was real: joint 0 actually moved toward its step target.
    assert cp["j0_final"] > cp["step_target"] * 0.5, (
        f"joint 0 did not move toward its step target {cp['step_target']} "
        f"(final {cp['j0_final']}) -- no disturbance applied; {cp}"
    )
    assert cp["max_peak_dev"] == cp["max_peak_dev"], (
        f"non-finite peak deviation in {cp}"
    )
    # Held joints return: residual is small in absolute terms.
    assert cp["max_residual"] < 0.05, (
        f"held-joint residual deviation {cp['max_residual']} m is not small "
        f"-- the coupling left a permanent offset, not a transient; {cp}"
    )
    # And the residual is no larger than the peak: the joints settled BACK
    # (a small numerical margin so a near-zero peak does not flake).
    assert cp["max_residual"] <= cp["max_peak_dev"] + 1e-3, (
        f"residual {cp['max_residual']} m exceeds peak {cp['max_peak_dev']} m "
        f"-- the held joints diverged instead of settling back; {cp}"
    )
