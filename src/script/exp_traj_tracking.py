#!/usr/bin/env python3
"""L3 single-joint trajectory-tracking precision on Isaac Sim 6.0.1 (isaac#180).

Characterizes the intrinsic control precision of an articulation (L3) joint
drive in ISOLATION -- one actuated joint, NO external load, NO contact with any
other model -- by commanding a time-varying trajectory and measuring how the
measured joint state lags the command. Answers the three #180 sub-issues:

    #181 tracking error over a trajectory  -> max + RMS |command - measured|
                                              over a step transient + a smooth
                                              sinusoid.
    #182 steady-state error at rest        -> residual |target - settled| after
                                              a step settles, no load.
    #183 repeatability across runs/resets  -> the same sinusoid re-commanded
                                              across R SimulationContext.reset()
                                              cycles; report the spread (must be
                                              deterministic).

There is no Isaac Sim 5.1 baseline for #180 in the repo: ADR-0021 only records
EXP-184 (the L2.5 steady-state DROOP-under-load sweep, re-validated separately
by ``exp_l25_sag_sweep.py``). Droop-under-load and transient-tracking-no-load
are different metrics, so #180 is a fresh characterization; the numbers this
driver records become the pass/fail thresholds the sub-issues ask to "set from
first run".

Physical setup -- WHY a VERTICAL-axis revolute joint
----------------------------------------------------
#180 wants the joint ISOLATED with NO external load. A revolute link has its own
mass, and if the joint axis were horizontal, gravity would apply a pose-
dependent torque about the axis -- an external load that would contaminate the
pure-tracking measurement (it is what the SEPARATE sag experiment measures). So
this driver orients the single revolute joint's axis along +Z (vertical,
parallel to gravity): gravity then produces ZERO torque about the axis, leaving
the drive to track its command with no gravitational load -- exactly "isolated,
no external load". (The repo's own ``two_link_revolute`` fixture uses this same
vertical axis for the same reason, noted in ``exp_l25_sag_sweep.py``.)

Revolute (not prismatic) is chosen deliberately: the prismatic path is already
covered by the sag sweep, and the revolute drive exercises the ``*pi/180``
angular-gain scaling the ADR-0021 flags as a "needs experiment" L3 limitation
(#168). Command and measurement both go through the articulation DOF API in
RADIANS, so the tracking error is unit-consistent regardless of the internal
per-degree DriveAPI convention; the ``*pi/180`` only rescales the EFFECTIVE
stiffness, which is why this driver SWEEPS stiffness (500 / 5000 / 50000 stored)
and reports tracking error vs gain -- the "characterize precision vs gain"
answer, mirroring the sag sweep's stiffness sweep.

The URDF is authored INLINE (written to /tmp at runtime) so this one committed
file is self-contained, and imported through the migrated framework pipeline
(``isaac_devkit.model_import._convert_urdf`` -- the same URDF->USD converter the
#168 joint-drive integration test exercises on 6.0.1). The joint drive is set on
the revolute joint's ``UsdPhysics.DriveAPI("angular")`` (a USD physics schema,
settable in pure Python per ADR-0021 D4).

Per stiffness k the driver: writes k + critical damping (2*sqrt(k*I)) onto the
DriveAPI, ``SimulationContext.reset()`` (re-parses the USD so PhysX picks up the
gains), then runs two trajectory phases, updating the DOF POSITION TARGET each
physics step through the live articulation view (a mid-sim USD attr write would
NOT reach the running PhysX DOF -- only the articulation view's
``set_joint_position_targets`` does):

  * STEP     : hold 0 rad, jump to ``--step-rad``, settle. -> #182 residual +
               overshoot / settle diagnostics.
  * SINUSOID : target(t) = A*sin(2*pi*f*t). -> #181 max + RMS tracking error and
               the amplitude-ratio / phase-lag of the tracked response.

Repeatability (#183) re-runs the sinusoid across ``--repeat`` reset cycles at a
fixed reference stiffness and reports the spread of RMS + steady-state.

Results are written as JSON to ``--out`` (a MOUNTED path, so the host reads it
back) -- stdout through the docker run wrapper is not reliably captured, so the
file is the source of truth. Runs headless in the 6.0.1 devel-test container.
Teardown is an explicit ``os._exit(0)`` on success / ``os._exit(1)`` on error
(isaac#248 round 9): under 6.0.1 a cold headless container's Omniverse Hub
connector cannot launch and carb's reconnect task aborts SimulationApp.close()
with a busy-TaskGroup SIGABRT; os._exit reaches the same clean exit while
skipping that asserting teardown.

CLI::

    PYTHONPATH=/home/<user>/work/worktree/<wt>/framework \\
    /isaac-sim/python.sh exp_traj_tracking.py \\
        --out /home/<user>/work/worktree/<wt>/test/.traj-tracking.json \\
        [--step-rad 0.5] [--amp-rad 0.5] [--freq-hz 0.5] \\
        [--settle-steps 180] [--sine-steps 240] [--repeat 3] \\
        [--stiffness 500 5000 50000] [--ref-stiffness 5000]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

# Minimal single-DOF revolute fixture. base_link is fixed to the world
# (fix_base=True at conversion); arm_link swings about a VERTICAL (+Z) axis so
# gravity makes zero torque about it -> no external load (see module docstring).
# High effort limit so the drive never saturates at the target (ADR-0021 A3: an
# effort clamp would masquerade as tracking error). izz is the axis inertia.
_URDF = """<?xml version="1.0"?>
<robot name="revolute_tracker">
  <link name="base_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.01" ixy="0" ixz="0" iyy="0.01" iyz="0" izz="0.01"/>
    </inertial>
    <visual>
      <geometry><box size="0.1 0.1 0.1"/></geometry>
    </visual>
  </link>
  <link name="arm_link">
    <inertial>
      <origin xyz="0 0 0" rpy="0 0 0"/>
      <mass value="1.0"/>
      <inertia ixx="0.1" ixy="0" ixz="0" iyy="0.1" iyz="0" izz="0.1"/>
    </inertial>
    <visual>
      <geometry><box size="0.4 0.1 0.1"/></geometry>
    </visual>
  </link>
  <joint name="arm_joint" type="revolute">
    <origin xyz="0 0 0.2" rpy="0 0 0"/>
    <parent link="base_link"/>
    <child link="arm_link"/>
    <axis xyz="0 0 1"/>
    <limit lower="-3.14159" upper="3.14159" effort="100000.0" velocity="100.0"/>
    <dynamics damping="0.0" friction="0.0"/>
  </joint>
</robot>
"""

# arm_link izz -- the inertia about the vertical joint axis (matches the URDF).
_AXIS_INERTIA = 0.1


def _find_revolute_joint(stage):
    """Path of the first revolute joint prim (or a Revolute-typed prim)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.IsA(UsdPhysics.RevoluteJoint):
            return str(prim.GetPath())
    for prim in stage.Traverse():
        if "Revolute" in str(prim.GetTypeName()):
            return str(prim.GetPath())
    return None


def _find_articulation_root(stage):
    """Path of the prim carrying ArticulationRootAPI (or None)."""
    from pxr import UsdPhysics

    for prim in stage.Traverse():
        if prim.HasAPI(UsdPhysics.ArticulationRootAPI):
            return str(prim.GetPath())
    return None


def _set_angular_drive(stage, joint_path, stiffness, damping):
    """Author an angular (revolute) DriveAPI with the given gains, target 0.

    Angular drive: PhysX consumes the stiffness/damping attrs in a per-DEGREE
    convention (#168), so the EFFECTIVE per-radian gain is scaled by 180/pi.
    Both gains scale identically, so the critical-damping RATIO the caller
    computes in stored units is preserved. The per-step position TARGET is NOT
    written here (a mid-sim USD attr write would not reach PhysX) -- it is
    driven live through the articulation view. Returns the read-back
    (stiffness, damping) so the caller can confirm what PhysX will parse.
    """
    from pxr import UsdPhysics

    prim = stage.GetPrimAtPath(joint_path)
    drive = UsdPhysics.DriveAPI.Get(prim, "angular")
    if not drive:
        drive = UsdPhysics.DriveAPI.Apply(prim, "angular")
    drive.CreateTypeAttr().Set("force")
    drive.CreateStiffnessAttr().Set(float(stiffness))
    drive.CreateDampingAttr().Set(float(damping))
    drive.CreateTargetPositionAttr().Set(0.0)
    drive.CreateMaxForceAttr().Set(float("inf"))
    return (drive.GetStiffnessAttr().Get(), drive.GetDampingAttr().Get())


def _make_articulation(root_path):
    """Best-effort articulation view over root_path across 6.0.x API names."""
    import isaacsim.core.prims as prims

    errors = []
    for cls_name in ("SingleArticulation", "Articulation"):
        cls = getattr(prims, cls_name, None)
        if cls is None:
            errors.append(f"{cls_name}: absent")
            continue
        try:
            return cls(root_path), cls_name
        except Exception as exc:  # noqa: BLE001
            errors.append(f"{cls_name}: {type(exc).__name__}: {exc}")
    raise RuntimeError("no usable Articulation class: " + " | ".join(errors))


def _joint_position(art, dof_idx):
    """Scalar joint position for dof_idx from a get_joint_positions() call."""
    import numpy as np

    pos = art.get_joint_positions()
    arr = np.asarray(pos).reshape(-1)
    return float(arr[dof_idx])


def _make_target_setter(art, dof_idx):
    """Return a ``set_target(value_rad)`` closure over whatever API the

    articulation view exposes in this 6.0.x build. Tries, in order:
    ``set_joint_position_targets`` (full-vector), then an ``ArticulationAction``
    via ``apply_action``. The chosen path name is recorded so the JSON says how
    the trajectory was driven. Raises if none is usable.
    """
    import numpy as np

    # Shape a full target vector matching get_joint_positions() so the setter
    # writes every DOF (only dof_idx changes) regardless of view arity.
    base = np.asarray(art.get_joint_positions()).reshape(-1).astype(float)

    setter = getattr(art, "set_joint_position_targets", None)
    if setter is not None:
        def _set(value, _setter=setter, _base=base):
            vec = _base.copy()
            vec[dof_idx] = float(value)
            _setter(vec.reshape(1, -1))
        try:
            _set(base[dof_idx])
            return _set, "set_joint_position_targets(1,N)"
        except Exception:  # noqa: BLE001
            def _set_flat(value, _setter=setter, _base=base):
                vec = _base.copy()
                vec[dof_idx] = float(value)
                _setter(vec)
            try:
                _set_flat(base[dof_idx])
                return _set_flat, "set_joint_position_targets(N,)"
            except Exception:  # noqa: BLE001
                pass

    # ArticulationAction fallback.
    try:
        from isaacsim.core.utils.types import ArticulationAction

        def _set_action(value, _base=base):
            vec = _base.copy()
            vec[dof_idx] = float(value)
            art.apply_action(ArticulationAction(joint_positions=vec))

        _set_action(base[dof_idx])
        return _set_action, "apply_action(ArticulationAction)"
    except Exception as exc:  # noqa: BLE001
        raise RuntimeError(
            f"no usable joint-target setter on {type(art).__name__}: {exc}"
        )


def _stats(errors):
    """max abs, RMS, and mean of an error list (radians)."""
    import numpy as np

    a = np.asarray(errors, dtype=float)
    return {
        "max_abs_rad": float(np.max(np.abs(a))),
        "rms_rad": float(np.sqrt(np.mean(a * a))),
        "mean_rad": float(np.mean(a)),
    }


def _resolve_dof_idx(art):
    """(dof_idx, dof_names) for the arm_joint, defaulting to index 0."""
    dof_idx = 0
    names = None
    try:
        names = list(art.dof_names)
        if "arm_joint" in names:
            dof_idx = names.index("arm_joint")
    except Exception:  # noqa: BLE001
        names = None
    return dof_idx, names


def _run_step_phase(sim, art, set_target, dof_idx, step_rad, settle_steps):
    """Command a 0 -> step_rad step; return steady-state + transient metrics.

    Steady-state error (#182) = target - mean(last-30 measured). Also reports
    overshoot (max measured beyond target, as a fraction of the step) and the
    settle step (first step within 2% of the step that stays within band).
    """
    import numpy as np

    set_target(step_rad)
    traj = []
    for _ in range(settle_steps):
        sim.step(render=False)
        traj.append(_joint_position(art, dof_idx))
    traj = np.asarray(traj, dtype=float)

    tail = traj[-30:] if traj.size >= 30 else traj
    settled = float(np.mean(tail))
    ss_error_rad = step_rad - settled
    ss_drift_rad = float(np.max(tail) - np.min(tail))
    overshoot = float(np.max(traj) - step_rad)
    overshoot_frac = overshoot / step_rad if step_rad else float("nan")

    band = 0.02 * abs(step_rad)
    settle_step = None
    for i in range(traj.size):
        if np.all(np.abs(traj[i:] - step_rad) <= band):
            settle_step = i
            break

    return {
        "step_rad": step_rad,
        "settled_rad": settled,
        "steady_state_error_rad": ss_error_rad,
        "steady_state_error_mrad": ss_error_rad * 1000.0,
        "residual_drift_mrad": ss_drift_rad * 1000.0,
        "overshoot_rad": overshoot,
        "overshoot_frac": overshoot_frac,
        "settle_step": settle_step,
        "has_nan": bool(np.any(np.isnan(traj))),
    }


def _run_sine_phase(sim, art, set_target, dof_idx, amp, freq, dt, sine_steps):
    """Command target(t)=amp*sin(2*pi*freq*t); return tracking-error metrics.

    Returns #181 max + RMS |command - measured| plus the tracked amplitude
    ratio and phase-lag estimated from the last full cycle.
    """
    import numpy as np

    # Start from target 0 (the step phase left the joint at step_rad; re-seat).
    set_target(0.0)
    for _ in range(30):
        sim.step(render=False)

    cmd = []
    meas = []
    for i in range(sine_steps):
        t = i * dt
        target = amp * math.sin(2.0 * math.pi * freq * t)
        set_target(target)
        sim.step(render=False)
        cmd.append(target)
        meas.append(_joint_position(art, dof_idx))

    cmd = np.asarray(cmd, dtype=float)
    meas = np.asarray(meas, dtype=float)
    err = cmd - meas
    stats = _stats(err)

    # Amplitude ratio + phase lag over the last full cycle.
    steps_per_cycle = int(round(1.0 / (freq * dt))) if freq * dt > 0 else 0
    amp_ratio = float("nan")
    phase_lag_rad = float("nan")
    if steps_per_cycle and meas.size >= steps_per_cycle:
        c = cmd[-steps_per_cycle:]
        m = meas[-steps_per_cycle:]
        m_amp = float((np.max(m) - np.min(m)) / 2.0)
        amp_ratio = m_amp / amp if amp else float("nan")
        # phase lag from cross-correlation peak of the two zero-mean signals.
        cz = c - np.mean(c)
        mz = m - np.mean(m)
        if np.any(cz) and np.any(mz):
            xcorr = np.correlate(mz, np.concatenate([cz, cz]), mode="valid")
            lag_steps = int(np.argmax(xcorr))
            phase_lag_rad = 2.0 * math.pi * (lag_steps / steps_per_cycle)

    return {
        "amp_rad": amp,
        "freq_hz": freq,
        "sine_steps": sine_steps,
        "max_tracking_error_rad": stats["max_abs_rad"],
        "max_tracking_error_mrad": stats["max_abs_rad"] * 1000.0,
        "rms_tracking_error_rad": stats["rms_rad"],
        "rms_tracking_error_mrad": stats["rms_rad"] * 1000.0,
        "amplitude_ratio": amp_ratio,
        "phase_lag_rad": phase_lag_rad,
        "phase_lag_deg": (
            math.degrees(phase_lag_rad)
            if not math.isnan(phase_lag_rad)
            else float("nan")
        ),
        "has_nan": bool(np.any(np.isnan(meas))),
    }


def _configure_and_reset(sim, art, stage, joint_path, k):
    """Set the drive gains for stiffness k, reset PhysX, re-init the view.

    Returns (stored_gains, damping). Critical damping is 2*sqrt(k*I) in the
    stored-unit space (both angular gains carry the same #168 scale, so the
    ratio is preserved).
    """
    damping = 2.0 * math.sqrt(k * _AXIS_INERTIA)
    stored = _set_angular_drive(stage, joint_path, k, damping)
    sim.reset()
    try:
        art.initialize()
    except Exception:  # noqa: BLE001
        pass
    return stored, damping


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "issue": "isaac#180",
        "isaac_variant": "6.0.1",
        "joint_type": "revolute",
        "axis": "+Z (vertical, gravity-parallel -> zero axis torque, isolated)",
        "axis_inertia_izz": _AXIS_INERTIA,
        "physics_dt": args.dt,
        "step_rad": args.step_rad,
        "amp_rad": args.amp_rad,
        "freq_hz": args.freq_hz,
        "note_5_1_baseline": (
            "none: #180 (transient tracking, no load) is a fresh metric; "
            "ADR-0021 EXP-184 only records L2.5 droop-under-load, a different "
            "quantity handled by exp_l25_sag_sweep.py"
        ),
        "stiffness_sweep": [],
        "repeatability": None,
        "api": {},
        "error": None,
    }
    try:
        from isaacsim.core.api import SimulationContext
        from pxr import Usd, UsdPhysics  # noqa: F401

        from isaac_devkit import model_import

        # 1. Author + convert the revolute fixture (migrated pipeline).
        urdf_path = Path("/tmp/revolute_tracker.urdf")
        urdf_path.write_text(_URDF)
        out_usd = Path("/tmp/revolute_tracker.usd")
        produced = model_import._convert_urdf(
            urdf_path, out_usd, fix_base=True, merge_fixed_joints=True
        )
        if not produced.exists():
            raise RuntimeError(f"converter produced no USD at {produced}")

        import omni.usd

        omni.usd.get_context().open_stage(str(produced))
        stage = omni.usd.get_context().get_stage()

        joint_path = _find_revolute_joint(stage)
        if joint_path is None:
            raise RuntimeError("no revolute joint in produced USD")
        root_path = _find_articulation_root(stage) or joint_path
        result["api"]["joint_path"] = joint_path
        result["api"]["root_path"] = root_path

        # 2. Physics context (default gravity -Z; zero torque about +Z axis).
        sim = SimulationContext(
            stage_units_in_meters=1.0,
            physics_dt=args.dt,
            rendering_dt=args.dt,
        )
        art, art_cls = _make_articulation(root_path)
        result["api"]["articulation_cls"] = art_cls

        # 3. Stiffness sweep -- step + sinusoid tracking per gain.
        for k in args.stiffness:
            stored, damping = _configure_and_reset(
                sim, art, stage, joint_path, k
            )
            dof_idx, names = _resolve_dof_idx(art)
            set_target, setter_api = _make_target_setter(art, dof_idx)
            result["api"]["target_setter"] = setter_api
            result["api"]["dof_names"] = names

            step_metrics = _run_step_phase(
                sim, art, set_target, dof_idx, args.step_rad, args.settle_steps
            )
            sine_metrics = _run_sine_phase(
                sim, art, set_target, dof_idx,
                args.amp_rad, args.freq_hz, args.dt, args.sine_steps,
            )
            result["stiffness_sweep"].append({
                "stiffness_stored": stored[0],
                "damping_stored": stored[1],
                "damping_critical_target": damping,
                "dof_index": dof_idx,
                "step_phase": step_metrics,
                "sine_phase": sine_metrics,
            })
            Path(args.out).write_text(json.dumps(result, indent=2))
            sim.stop()

        # 4. Repeatability (#183): same sinusoid across reset cycles at the
        #    reference stiffness; deterministic PhysX -> spread ~ 0.
        rms_runs = []
        ss_runs = []
        for _ in range(args.repeat):
            _configure_and_reset(sim, art, stage, joint_path, args.ref_stiffness)
            dof_idx, _ = _resolve_dof_idx(art)
            set_target, _ = _make_target_setter(art, dof_idx)
            step_m = _run_step_phase(
                sim, art, set_target, dof_idx, args.step_rad, args.settle_steps
            )
            sine_m = _run_sine_phase(
                sim, art, set_target, dof_idx,
                args.amp_rad, args.freq_hz, args.dt, args.sine_steps,
            )
            rms_runs.append(sine_m["rms_tracking_error_rad"])
            ss_runs.append(step_m["steady_state_error_rad"])
            sim.stop()

        import numpy as np

        rms_arr = np.asarray(rms_runs, dtype=float)
        ss_arr = np.asarray(ss_runs, dtype=float)
        result["repeatability"] = {
            "ref_stiffness": args.ref_stiffness,
            "runs": args.repeat,
            "rms_tracking_error_rad_per_run": rms_runs,
            "rms_spread_mrad": float(
                (np.max(rms_arr) - np.min(rms_arr)) * 1000.0
            ),
            "rms_std_mrad": float(np.std(rms_arr) * 1000.0),
            "steady_state_error_rad_per_run": ss_runs,
            "ss_spread_mrad": float((np.max(ss_arr) - np.min(ss_arr)) * 1000.0),
            "ss_std_mrad": float(np.std(ss_arr) * 1000.0),
            "deterministic": bool(
                (np.max(rms_arr) - np.min(rms_arr)) < 1e-9
                and (np.max(ss_arr) - np.min(ss_arr)) < 1e-9
            ),
        }
        Path(args.out).write_text(json.dumps(result, indent=2))

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
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    p.add_argument("--step-rad", type=float, default=0.5, help="Step target.")
    p.add_argument("--amp-rad", type=float, default=0.5, help="Sinusoid amp.")
    p.add_argument("--freq-hz", type=float, default=0.5, help="Sinusoid freq.")
    p.add_argument(
        "--settle-steps", type=int, default=180, help="Steps in step phase."
    )
    p.add_argument(
        "--sine-steps", type=int, default=240, help="Steps in sine phase."
    )
    p.add_argument(
        "--repeat", type=int, default=3, help="Repeatability reset cycles."
    )
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    p.add_argument(
        "--stiffness",
        type=float,
        nargs="+",
        default=[500.0, 5000.0, 50000.0],
        help="Stored angular stiffness values to sweep.",
    )
    p.add_argument(
        "--ref-stiffness",
        type=float,
        default=5000.0,
        help="Stiffness used for the repeatability phase.",
    )
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
