"""GPU experiment: hybrid kinematic+dynamic loop-joint boundary compliance
(#197, milestone "Physics: L2 true-kinematic + hybrid"; ADR-0008).

A standalone KINEMATIC anchor is joined to a standalone DYNAMIC body by a
rigid-body (MAXIMAL-COORDINATE) ``UsdPhysics.FixedJoint`` -- NOT an
articulation joint. The maximal-coordinate joint is known to be COMPLIANT
("weak"; PhysX #308): it is solved as a soft constraint, so under load the
dynamic body GIVES at the joint rather than holding rigidly.

The POINT of this experiment is to MEASURE that give -- record the number even
if it is loose -- and to verify the two boundary properties:

  * **compliance** -- the hung body settles with a measurable separation from
    the anchor that is finite and bounded (the joint stretches under the 10 kg
    load; the give = settled separation - rest separation).
  * **force transfer** -- when the anchor is raised, the hung body FOLLOWS it
    (the joint transmits the motion, even compliantly): the hung body's rise
    is within a measured band of the anchor's rise, and it stays finite /
    settled.

Stepped physics: ``dynamic_control`` + ``omni.timeline`` + ``app.update()``
(the example / L2 path), NOT a ``SimulationContext`` (#151). The anchor is
driven by writing its pose every tick in small increments via
``dc.set_rigid_body_pose`` (the per-tick kinematic write path proven by
``test_openbase_l2_stability.py``; this Isaac Sim build's dynamic_control does
NOT ship the explicit ``set_kinematic_target`` contact path of ADR-0008) so
the joint transmits the motion.

Subprocess-per-run / marker-line pattern (``SimulationApp`` is a process-global
singleton; ``pxr`` / ``omni`` are not importable in the bare pytest process).
Runtime: the GPU-enabled Isaac Sim ``test`` compose service.
"""

import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
RUNNER = Path(__file__).parent / "_hybrid_boundary_runner.py"
FIXTURE = REPO_ROOT / "test" / "fixtures" / "usd" / "l2_hybrid_loop.usda"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 300

LIFT = 0.5          # how far the anchor is raised (m).
RAMP_STEP = 0.005   # per-tick anchor step (m), small so the joint keeps up.
REST_SEP = 0.5      # joint rest separation (m), matches the fixture.

_SUMMARY_RE = re.compile(r"\[HYBRID SUMMARY\] (.+)")


def _parse_kv(line: str) -> dict:
    """Parse a 'k=v k=v ...' marker tail into a typed dict."""
    out = {}
    for tok in line.split():
        if "=" not in tok:
            continue
        k, v = tok.split("=", 1)
        if v in ("True", "False"):
            out[k] = v == "True"
        else:
            try:
                out[k] = float(v)
            except ValueError:
                out[k] = v
    return out


def _run_hybrid() -> dict:
    """Run the hybrid runner once; parse the [HYBRID SUMMARY] marker."""
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--lift", str(LIFT),
            "--ramp-step", str(RAMP_STEP),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[HYBRID SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- hybrid runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    for line in result.stdout.splitlines():
        if line.startswith("[HYBRID DRIVE]"):
            sys.stderr.write("\n" + line + "\n")
    m = _SUMMARY_RE.search(result.stdout)
    assert m, "no [HYBRID SUMMARY] marker"
    d = _parse_kv(m.group(1))
    # Surface the measured boundary numbers in the (passing) CI log.
    sys.stderr.write(
        "\n[HYBRID MEASURED] "
        f"compliance={d.get('compliance')} m "
        f"settled_sep={d.get('settled_sep')} m "
        f"follow_ratio={d.get('follow_ratio')} "
        f"anchor_rise={d.get('anchor_rise')} hung_rise={d.get('hung_rise')}\n"
    )
    return d


def test_hybrid_loop_joint_compliance_and_force_transfer():
    """The maximal-coordinate FixedJoint is compliant but transmits motion:
    the hung dynamic body settles with a finite, bounded give at the joint
    (compliance) and FOLLOWS the kinematic anchor when it is raised (force
    transfer), staying finite / settled (ADR-0008; PhysX #308).

    The POINT is to MEASURE the give; the bands are loose. A single run drives
    both phases (settle under gravity, then lift) and the marker carries every
    measured field, surfaced on stderr so the raw numbers land in the CI log.
    """
    r = _run_hybrid()

    # The system is finite / settled -- no NaN/inf blow-up at the soft joint.
    assert r["hung_finite"], f"hung body pose went non-finite ({r})"

    # Compliance: the joint holds the hung body at a separation NEAR its rest
    # (0.5 m) -- a soft constraint stretches under load but does not collapse
    # or fly apart. The give is finite and bounded (record it; loose band).
    settled_sep = r["settled_sep"]
    compliance = r["compliance"]
    assert 0.2 < settled_sep < 1.5, (
        f"hung body did not settle near the joint rest separation "
        f"(settled_sep {settled_sep} m vs rest {REST_SEP} m); the joint "
        f"collapsed or flew apart ({r})"
    )
    # The give is bounded -- a maximal-coordinate joint is compliant, not
    # free; the stretch under a 10 kg load stays within a metre.
    assert abs(compliance) < 1.0, (
        f"joint compliance {compliance} m is implausibly large; the "
        f"constraint did not hold ({r})"
    )

    # Force transfer: raising the anchor raises the hung body. The hung body
    # follows within a band of the anchor's rise (a rigid ideal would be
    # exactly 1.0; the compliant joint may lag or lead transiently, so the
    # band is loose -- the POINT is that it FOLLOWS, not that it is rigid).
    anchor_rise = r["anchor_rise"]
    hung_rise = r["hung_rise"]
    follow_ratio = r["follow_ratio"]
    assert anchor_rise > LIFT * 0.5, (
        f"the anchor did not actually rise ({anchor_rise} m for a {LIFT} m "
        f"commanded lift); the kinematic drive failed ({r})"
    )
    # The hung body rose substantially with the anchor (force transfer).
    assert hung_rise > LIFT * 0.3, (
        f"hung body did not follow the anchor's rise (hung_rise {hung_rise} m "
        f"for anchor_rise {anchor_rise} m); the joint did not transmit the "
        f"motion ({r})"
    )
    # The follow ratio is within a loose band of the rigid ideal (1.0). This
    # is the measured boundary -- recorded in doc/experiments/exp-197-hybrid-
    # boundary.md even if loose.
    assert 0.4 < follow_ratio < 1.6, (
        f"hung/anchor follow ratio {follow_ratio} is outside the measured "
        f"compliance band [0.4, 1.6]; the joint neither held nor transmitted "
        f"cleanly ({r})"
    )
