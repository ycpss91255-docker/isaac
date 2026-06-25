"""GPU integration: true-L2 zero-error kinematic hold under load (#193/#194).

ADR-0021 D1/D2, milestone "Physics: L2 true-kinematic + hybrid". The true-L2
endpoint of the L2 / L2.5 / L3 continuum: a STANDALONE kinematic rigid body
(NOT an articulation link -- PhysX forbids kinematic articulation links,
ADR-0021 D2) commanded to a target height via ``dc.set_rigid_body_pose`` holds
that height with ESSENTIALLY ZERO steady-state error EVEN UNDER LOAD. A dynamic
10 kg payload rests on the platform under gravity, yet PhysX moves the kinematic
actor to its target "regardless of external forces, gravity, collision", so the
error stays at the epsilon floor.

This is the direct CONTRAST to EXP-184's L2.5 articulation high-stiffness
position drive, whose steady-state error is the load/stiffness sag
``m*g/stiffness`` (EXP-184 measured 19.4 mm at k=5000 / 0.79 mm at k=1e5 /
18 um at k=1e6 for the same 10 kg payload; ADR-0021 D1a). True-L2 has NO such
floor -- the error is zero regardless of load, because there is no "force"
concept (the kinematic limit ``k -> infinity``).

Subprocess-per-run / marker-line pattern (``SimulationApp`` is a process-global
singleton; ``pxr`` / ``omni`` are not importable in the bare pytest process).
Runtime: the GPU-enabled Isaac Sim ``test`` compose service.

  Run:  ./script/run.sh -t test -- \
          /isaac-sim/python.sh -m pytest \
          test/integration/pytest/test_l2_kinematic_hold.py
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).parent / "_l2_hold_runner.py"
FIXTURE = REPO_ROOT / "test" / "fixtures" / "usd" / "l2_kinematic_hold.usda"
PYTHON_SH = "/isaac-sim/python.sh"
HOLD_TIMEOUT_SEC = 300

# Commanded target height (m) for the kinematic platform.
TARGET_Z = 1.0
# Kinematic hold is EXACT; the only error is float / readback noise. Tight,
# banded epsilon -- true-L2 is the zero-error endpoint, not "small".
ERROR_EPS_M = 1e-4

# EXP-184 L2.5 reference (ADR-0021 D1a): the high-stiffness articulation drive
# sags by m*g/stiffness under load. At the lowest swept stiffness (k=5000) the
# 10 kg payload gave 19.4 mm. The kinematic error must be ORDERS smaller.
EXP184_PAYLOAD_KG = 10.0
EXP184_K5000 = 5000.0
_G = 9.81
EXP184_SAG_K5000_M = (EXP184_PAYLOAD_KG * _G) / EXP184_K5000  # ~0.01962 m

_SUMMARY_RE = re.compile(
    r"\[L2HOLD SUMMARY\] target=(\S+) resting=(\S+) error=(\S+) "
    r"payload_mass=(\S+) payload_z=(\S+) payload_on_platform=(\S+) "
    r"l25_sag_mm_k5000=(\S+)"
)


def _run_hold() -> dict:
    """Run the L2-hold runner once; parse the [L2HOLD SUMMARY] marker."""
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--target-z", str(TARGET_Z),
        ],
        capture_output=True,
        text=True,
        timeout=HOLD_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[L2HOLD SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- l2-hold runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, "no [L2HOLD SUMMARY] marker in runner output"
    # TEMP: surface the marker on stderr so it appears in the green CI log
    # (pytest suppresses captured stdout on pass); reverted after recording.
    sys.stderr.write(f"\n[L2HOLD MEASURED] {m.group(0)}\n")
    return {
        "target": float(m.group(1)),
        "resting": float(m.group(2)),
        "error": float(m.group(3)),
        "payload_mass": float(m.group(4)),
        "payload_z": float(m.group(5)),
        "payload_on_platform": m.group(6) == "True",
        "l25_sag_mm_k5000": float(m.group(7)),
    }


def test_kinematic_body_holds_target_with_zero_error_under_load():
    """A kinematic platform holds its commanded height under a 10 kg load.

    The standalone kinematic body is commanded to ``TARGET_Z`` each tick while
    a dynamic payload rests on it under gravity. PhysX places the kinematic
    actor at the target regardless of the load, so the steady-state position
    error is at the epsilon floor (< ``ERROR_EPS_M``) -- and the payload is
    actually resting on the raised platform, confirming the load is real.
    """
    summary = _run_hold()
    assert summary["payload_on_platform"], (
        "payload is not resting on the raised platform -- the kinematic body "
        f"is not carrying the load: {summary}"
    )
    assert summary["error"] < ERROR_EPS_M, (
        f"kinematic hold error {summary['error']:.3e} m >= {ERROR_EPS_M} m -- "
        f"a true-L2 kinematic body must hold its target exactly: {summary}"
    )


def test_kinematic_hold_error_dwarfed_by_l25_sag():
    """The true-L2 error is orders smaller than the L2.5 mg/k sag (EXP-184).

    Contrast assertion: the kinematic body's steady-state error is far below
    EXP-184's L2.5 articulation-drive sag for the SAME 10 kg load at the lowest
    swept stiffness (k=5000 -> m*g/k ~= 19.6 mm). True-L2 has no load/stiffness
    floor; L2.5 does. We require the kinematic error to be at least 100x
    smaller than that L2.5 sag (it is in practice ~1e6x smaller).
    """
    summary = _run_hold()
    # The runner recomputes the same mg/k model; cross-check it against ours.
    expected_sag_mm = EXP184_SAG_K5000_M * 1000.0
    assert abs(summary["l25_sag_mm_k5000"] - expected_sag_mm) < 1e-3, (
        f"runner L2.5 sag {summary['l25_sag_mm_k5000']} mm != "
        f"mg/k model {expected_sag_mm} mm"
    )
    assert summary["error"] < (EXP184_SAG_K5000_M / 100.0), (
        f"kinematic error {summary['error']:.3e} m is not << the L2.5 sag "
        f"{EXP184_SAG_K5000_M:.3e} m (m*g/k, k=5000, 10 kg, EXP-184): the "
        "true-L2 endpoint must dwarf the L2.5 load/stiffness droop"
    )
