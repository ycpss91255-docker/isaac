#!/usr/bin/env python3
"""Empirical *pi/180 revolute-gain-scaling spot-check on Isaac Sim 6.0.1 (isaac#189).

Re-validation companion to test/integration/pytest/test_joint_drive_integration.py.
That pytest asserts the SCALING at fixed gains (800/40 deg-space); this driver is
a small STANDALONE read-back that boots one live Kit, drives the same migrated
two_link_revolute fixture with several KNOWN deg-space gains through BOTH Isaac
Lab paths, reads the authored UsdPhysics.DriveAPI("angular") attrs straight off
the produced stage, and confirms each stored value == deg_input * pi/180 -- i.e.
the conversion is applied ONCE (not twice, not dropped) and matches 5.1's
per-degree angular convention.

Two paths per gain (both are the Isaac Lab converters the framework wraps):
  import   model_import._convert_urdf(joint_drive_stiffness=, joint_drive_damping=)
           -> UrdfConverterCfg default drive, urdf_converter set_strength(pi/180*k)
  runtime  import with no drive, then model_import.apply_joint_drive(...)
           -> modify_joint_drive_properties (same N-m/rad -> N-m/deg conversion)

Gains chosen to make double-application impossible to miss: 180 deg -> exactly
pi rad (a second *pi/180 would give 0.0548). Results written to a MOUNTED JSON
(--out) so the host reads them back; stdout through the run wrapper is not
reliable. os._exit teardown (isaac#248 round 9).
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

_DEG2RAD = math.pi / 180.0
_REL_TOL = 1e-4

# (stiffness_deg, damping_deg). 800/40 mirrors the pytest; 180/90 lands on
# clean pi / (pi/2) so a doubled or dropped scaling is obvious by eye.
_GAINS = [(800.0, 40.0), (180.0, 90.0)]


def _find_revolute_joint(stage):
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.RevoluteJoint):
            return str(prim.GetPath())
    for prim in stage.Traverse():
        if "Revolute" in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _read_angular_drive(stage, joint_path):
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI(prim, "angular")
    if not drive:
        return (False, float("nan"), float("nan"))
    s = drive.GetStiffnessAttr()
    d = drive.GetDampingAttr()
    return (
        True,
        float(s.Get()) if s and s.Get() is not None else float("nan"),
        float(d.Get()) if d and d.Get() is not None else float("nan"),
    )


def _check(stored, deg_input):
    expected = deg_input * _DEG2RAD
    return {
        "deg_input": deg_input,
        "stored": stored,
        "expected_deg_x_pi_over_180": expected,
        "matches_single_scaling": bool(
            math.isclose(stored, expected, rel_tol=_REL_TOL)
        ),
        "would_be_if_doubled": deg_input * _DEG2RAD * _DEG2RAD,
        "would_be_if_unscaled": deg_input,
    }


def run(args):
    from isaac_devkit import model_import
    from isaacsim import SimulationApp

    result = {
        "issue": "isaac#189",
        "isaac_variant": "6.0.1",
        "joint_type": "revolute",
        "convention": "angular DriveAPI stores per-radian = deg_input * pi/180",
        "deg2rad": _DEG2RAD,
        "rel_tol": _REL_TOL,
        "cases": [],
        "all_pass": None,
        "error": None,
    }

    app = SimulationApp(model_import._simulation_app_kwargs())
    try:
        from pxr import Usd
        import omni.usd

        repo_root = Path(args.repo_root).resolve()
        urdf = (
            repo_root / "test" / "fixtures" / "urdf" / "two_link_revolute.urdf"
        )
        if not urdf.exists():
            raise RuntimeError(f"fixture URDF missing: {urdf}")

        for k_deg, d_deg in _GAINS:
            # ---- import path -------------------------------------------------
            out_imp = Path(args.out_dir) / f"gain_import_{int(k_deg)}.usd"
            out_imp.parent.mkdir(parents=True, exist_ok=True)
            produced = model_import._convert_urdf(
                urdf, out_imp, fix_base=True, merge_fixed_joints=True,
                joint_drive_stiffness=k_deg, joint_drive_damping=d_deg,
            )
            stage = Usd.Stage.Open(str(produced))
            jp = _find_revolute_joint(stage)
            has, s_imp, d_imp = _read_angular_drive(stage, jp)

            # ---- runtime-apply path -----------------------------------------
            out_rt = Path(args.out_dir) / f"gain_runtime_{int(k_deg)}.usd"
            produced_rt = model_import._convert_urdf(
                urdf, out_rt, fix_base=True, merge_fixed_joints=True,
            )
            omni.usd.get_context().open_stage(str(produced_rt))
            jp_rt = _find_revolute_joint(
                omni.usd.get_context().get_stage()
            )
            applied = model_import.apply_joint_drive(jp_rt, k_deg, d_deg)
            stage_rt = omni.usd.get_context().get_stage()
            has_rt, s_rt, d_rt = _read_angular_drive(stage_rt, jp_rt)

            result["cases"].append({
                "gain_deg": {"stiffness": k_deg, "damping": d_deg},
                "import_path": {
                    "joint": jp,
                    "has_drive": has,
                    "stiffness": _check(s_imp, k_deg),
                    "damping": _check(d_imp, d_deg),
                },
                "runtime_apply_path": {
                    "joint": jp_rt,
                    "apply_returned": bool(applied),
                    "has_drive": has_rt,
                    "stiffness": _check(s_rt, k_deg),
                    "damping": _check(d_rt, d_deg),
                },
            })

        flags = []
        for c in result["cases"]:
            for p in ("import_path", "runtime_apply_path"):
                flags.append(c[p]["stiffness"]["matches_single_scaling"])
                flags.append(c[p]["damping"]["matches_single_scaling"])
        result["all_pass"] = all(flags) and len(flags) > 0

    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
    finally:
        try:
            Path(args.out).write_text(json.dumps(result, indent=2))
        except Exception:  # noqa: BLE001
            pass
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1 if result["error"] else 0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo-root", required=True)
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument("--out-dir", default="/tmp/gain_scaling", help="USD scratch.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
