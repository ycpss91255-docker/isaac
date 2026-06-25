"""GPU experiment: an L2 KINEMATIC mover pushes a SEPARATE dynamic object
(#201, milestone "Physics: L2 true-kinematic + hybrid"; ADR-0008).

The carry-speed experiment (#201) studied how a kinematic mover carries a
resting dynamic payload via the kinematic write path. This experiment drives a
kinematic mover HORIZONTALLY into a separate dynamic box and verifies the two
interaction properties. The mover pose is written every tick in SMALL
increments via ``dc.set_rigid_body_pose`` (the per-tick kinematic write path
proven by ``test_openbase_l2_stability.py``; this Isaac Sim build's
dynamic_control does not expose ``set_kinematic_target``), which gives PhysX a
per-step velocity it resolves against contact -- so the mover pushes the box
(a single big teleport would jump past it; the per-tick small-step caveat is
the same carry-speed limit as #201):

  * **momentum transfer** -- the box is displaced ahead of the advancing
    mover, while the mover lands on its COMMANDED path (a kinematic body
    ignores the reaction force from the box).
  * **squish / limit** -- pushed into a static wall, the box is trapped
    between the mover and the wall; it stops at the wall (cannot move past it)
    and stays finite / settled.

Horizontal push is deliberately chosen over a vertical carry: it does not
fight gravity through the contact, so it is far less sensitive to the per-tick
speed limit. SMALL per-tick ramp steps are used so contact transfers each tick
(a large per-tick jump teleports the mover through the box -- the same
carry-speed caveat as the #201 carry experiment).

Stepped physics: ``dynamic_control`` + ``omni.timeline`` + ``app.update()``
(the example / L2 path), NOT a ``SimulationContext`` (#151).

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
RUNNER = Path(__file__).parent / "_l2_push_runner.py"
FIXTURE = REPO_ROOT / "test" / "fixtures" / "usd" / "l2_push.usda"
PYTHON_SH = "/isaac-sim/python.sh"
RUN_TIMEOUT_SEC = 300

# Small per-tick step so contact transfers every tick (the contact-respecting
# carry regime; ~0.005 m/tick ~ 0.3 m/s at 60 Hz, well within the limit).
RAMP_STEP = 0.005
# Box starts at x=0.0; wall left face at x = 1.2 - 0.05 = 1.15.
# push: drive the mover to x=0.5 -- the mover (right face 0.65) pushes the box
# ahead but stops short of pinning it on the wall.
PUSH_TARGET_X = 0.5
# squish: drive the mover to x=0.85 -- the box (half 0.15) is pinned against
# the wall (its right face reaches 1.15, centre ~1.0).
SQUISH_TARGET_X = 0.85

_SUMMARY_RE = re.compile(r"\[PUSH SUMMARY\] (.+)")


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


def _run_push(mode: str, target_x: float,
              write_mode: str = "auto") -> dict:
    """Run the push runner once; parse the [PUSH SUMMARY] marker."""
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--usd", str(FIXTURE),
            "--mode", mode,
            "--ramp-step", str(RAMP_STEP),
            "--write-mode", write_mode,
            "--target-x", str(target_x),
        ],
        capture_output=True,
        text=True,
        timeout=RUN_TIMEOUT_SEC,
        env=dict(os.environ),
    )
    if result.returncode != 0 or "[PUSH SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- push runner stdout ({mode}, target_x={target_x}) ---\n"
            f"{result.stdout}\n--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [PUSH SUMMARY] marker for mode {mode}"
    return _parse_kv(m.group(1))


def test_kinematic_push_displaces_box_and_holds_commanded_path():
    """The kinematic mover pushes the dynamic box ahead (momentum transfer)
    and lands on its COMMANDED path -- the box's reaction does not perturb the
    kinematic mover (ADR-0008).
    """
    r = _run_push("push", PUSH_TARGET_X)
    box_disp = r["box_disp"]
    mover_err = r["mover_err"]

    # The box was pushed forward (positive +X displacement) by a clear margin
    # -- momentum transferred through the contact.
    assert box_disp > 0.2, (
        f"box was not pushed forward (displacement {box_disp} m); contact did "
        f"not transfer momentum ({r})"
    )
    assert r["box_finite"], f"box pose went non-finite ({r})"
    # The kinematic mover landed on its commanded path: a kinematic body
    # ignores the reaction force from the box, so it tracks target_x tightly.
    assert mover_err < 0.02, (
        f"kinematic mover did not hold its commanded path (tracking error "
        f"{mover_err} m); the box reaction perturbed it ({r})"
    )


def test_kinematic_push_squishes_box_against_wall():
    """Pushed into the static wall, the box is TRAPPED between the mover and
    the wall: it stops at the wall (cannot move past it) and stays
    finite / settled (the squish / limit case).
    """
    r = _run_push("squish", SQUISH_TARGET_X)
    box_x = r["box_x"]
    wall_x = r["wall_x"]

    # The box advanced toward the wall (it was pushed).
    assert r["box_disp"] > 0.4, (
        f"box was not driven toward the wall (displacement {r['box_disp']} m) "
        f"({r})"
    )
    # The box is pinned just short of the wall -- it cannot pass the static
    # backstop. Box half-extent 0.15, wall left face at wall_x - 0.05 = 1.15,
    # so the box centre cannot exceed ~1.0; assert it stopped before the wall
    # centre and did not tunnel through.
    assert box_x < wall_x, (
        f"box passed through the wall (box_x {box_x} >= wall_x {wall_x}); the "
        f"static backstop did not trap it ({r})"
    )
    assert box_x > 0.7, (
        f"box did not reach the wall region (box_x {box_x}); the squish did "
        f"not occur ({r})"
    )
    # Trapped but stable -- no NaN/inf blow-up under the pin.
    assert r["box_finite"], (
        f"box pose went non-finite under the squish ({r})"
    )
    # The kinematic mover still holds its commanded path even while pinning the
    # box against the wall (it ignores the contact reaction).
    assert r["mover_err"] < 0.02, (
        f"kinematic mover lost its commanded path under the squish "
        f"(tracking error {r['mover_err']} m) ({r})"
    )
