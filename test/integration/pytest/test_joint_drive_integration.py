"""GPU integration: configurable joint drive on a revolute fixture (#168).

ADR-0020 decision 3. The two-link revolute fixture
(test/fixtures/urdf/two_link_revolute.urdf) is driven two ways and the
joint prim's ``UsdPhysics.DriveAPI("angular")`` gains are asserted:

  import-drive   ``import_urdf(joint_drive_stiffness=, joint_drive_damping=)``
                 -> ``UrdfConverterCfg.joint_drive = JointDriveCfg(gains=
                 PDGainsCfg(...), drive_type="force", target_type="position")``
                 -> the imported revolute joint carries a DriveAPI with the
                 configured stiffness/damping.

  runtime-apply  import with NO drive, then
                 ``apply_joint_drive(joint_path, stiffness, damping)``
                 (Isaac Lab ``modify_joint_drive_properties``, stage-only --
                 no Articulation, no SimulationContext, so it does NOT touch
                 the #151 shutdown-hang surface) -> the DriveAPI is applied
                 to the already-imported joint with the configured gains.

Both assertions are STRUCTURAL: the DriveAPI is present with the right gains.
"The joint physically reaches / holds a commanded target" needs STEPPED
physics (a ``SimulationContext``, deferred #151) and is deliberately NOT
exercised -- the drive is verified CONFIGURED, not actuated. The
``ImplicitActuatorCfg`` path (which would need an Articulation + a playing
SimulationContext) is intentionally avoided (#168 survey).

Subprocess-per-import / marker-line pattern (``SimulationApp`` is a
process-global singleton; ``pxr`` is not importable in the bare pytest
process). Runtime requirement: the Isaac Sim / Isaac Lab devel-test GPU
container.
"""

import math
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
FRAMEWORK_DIR = REPO_ROOT / "framework"
RUNNER = Path(__file__).parent / "_joint_drive_runner.py"
PYTHON_SH = "/isaac-sim/python.sh"
IMPORT_TIMEOUT_SEC = 240

# Gains we pass in, in URDF/per-degree convention (what a user types). Both
# the import-time path (Isaac Lab UrdfConverter) and the runtime path
# (modify_joint_drive_properties) treat a configured stiffness/damping on an
# ANGULAR (revolute) joint as per-degree and write the per-radian value onto
# the USD DriveAPI, i.e. they multiply by ``math.pi / 180`` (Isaac Lab
# v2.3.2: urdf_converter ``set_strength(math.pi / 180 * stiffness)`` for a
# non-prismatic joint; schemas ``modify_joint_drive_properties`` applies the
# same N-m/rad -> N-m/deg conversion). This is a DETERMINISTIC unit
# conversion, NOT a dropped input: the gains stay fully user-controllable
# (double the input -> double the stored value); only the storage unit
# differs. The DriveAPI therefore stores ``IN * pi/180``, which is what we
# assert (#168).
STIFFNESS = 800.0
DAMPING = 40.0
_DEG2RAD = math.pi / 180.0
# Expected per-radian gains the angular DriveAPI actually stores.
EXPECTED_STIFFNESS = STIFFNESS * _DEG2RAD
EXPECTED_DAMPING = DAMPING * _DEG2RAD
# Float tolerance: the marker prints with %g (6 sig figs), so compare with a
# relative tolerance rather than exact equality.
_REL_TOL = 1e-4

_SUMMARY_RE = re.compile(
    r"\[DRIVE SUMMARY\] mode=(\S+) joint=(\S+) has_drive=(\S+) "
    r"stiffness=(\S+) damping=(\S+)"
)


def _run_drive(mode: str, out_usd: Path) -> dict:
    """Run the joint-drive runner in a mode; parse the [DRIVE SUMMARY]."""
    env = dict(os.environ)
    env["PYTHONPATH"] = (
        str(FRAMEWORK_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    )
    result = subprocess.run(
        [
            PYTHON_SH, str(RUNNER),
            "--repo-root", str(REPO_ROOT),
            "--mode", mode,
            "--out", str(out_usd),
            "--stiffness", str(STIFFNESS),
            "--damping", str(DAMPING),
        ],
        capture_output=True,
        text=True,
        timeout=IMPORT_TIMEOUT_SEC,
        env=env,
    )
    if result.returncode != 0 or "[DRIVE SUMMARY]" not in result.stdout:
        sys.stderr.write(
            f"\n--- joint-drive runner stdout ---\n{result.stdout}\n"
            f"--- stderr ---\n{result.stderr}\n"
        )
    m = _SUMMARY_RE.search(result.stdout)
    assert m, f"no [DRIVE SUMMARY] marker for mode {mode!r}"
    return {
        "mode": m.group(1),
        "joint": m.group(2),
        "has_drive": m.group(3) == "True",
        "stiffness": float(m.group(4)),
        "damping": float(m.group(5)),
    }


def test_import_time_joint_drive_configures_driveapi(tmp_path):
    """An import-time joint_drive applies a DriveAPI with the set gains.

    UrdfConverterCfg.joint_drive = JointDriveCfg(...) makes the imported
    revolute joint carry a UsdPhysics.DriveAPI("angular") whose stiffness /
    damping match what was passed. Structural CONFIGURED check (reaching a
    target is deferred to a SimulationContext, #151).
    """
    summary = _run_drive("import-drive", tmp_path / "arm_import.usd")
    assert summary["has_drive"], (
        f"import-time joint_drive did not apply a DriveAPI: {summary}"
    )
    assert math.isclose(
        summary["stiffness"], EXPECTED_STIFFNESS, rel_tol=_REL_TOL
    ), (
        f"DriveAPI stiffness {summary['stiffness']} != "
        f"{EXPECTED_STIFFNESS} (= {STIFFNESS} * pi/180, the per-radian value "
        "the angular drive stores for a per-degree input)"
    )
    assert math.isclose(
        summary["damping"], EXPECTED_DAMPING, rel_tol=_REL_TOL
    ), (
        f"DriveAPI damping {summary['damping']} != {EXPECTED_DAMPING} "
        f"(= {DAMPING} * pi/180)"
    )


def test_runtime_apply_joint_drive_sets_driveapi(tmp_path):
    """apply_joint_drive sets a DriveAPI on an already-imported joint.

    The fixture is imported with NO drive, then the runtime helper
    (modify_joint_drive_properties, stage-only) writes the DriveAPI gains on
    the existing joint prim -- the "set Kp/Kd on an already-imported joint"
    path the driver/adapter calls. Structural CONFIGURED check; no stepped
    physics (no SimulationContext, #151).
    """
    summary = _run_drive("runtime-apply", tmp_path / "arm_runtime.usd")
    assert summary["has_drive"], (
        f"apply_joint_drive did not apply a DriveAPI: {summary}"
    )
    assert math.isclose(
        summary["stiffness"], EXPECTED_STIFFNESS, rel_tol=_REL_TOL
    ), (
        f"DriveAPI stiffness {summary['stiffness']} != "
        f"{EXPECTED_STIFFNESS} (= {STIFFNESS} * pi/180; "
        "modify_joint_drive_properties applies the same per-degree -> "
        "per-radian angular conversion as the import path)"
    )
    assert math.isclose(
        summary["damping"], EXPECTED_DAMPING, rel_tol=_REL_TOL
    ), (
        f"DriveAPI damping {summary['damping']} != {EXPECTED_DAMPING} "
        f"(= {DAMPING} * pi/180)"
    )
