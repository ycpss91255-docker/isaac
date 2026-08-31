#!/usr/bin/env python3
"""L2 kinematic carry speed limit on Isaac Sim 6.0.1 (isaac#217).

Measures the per-tick displacement at which a kinematic mover stops carrying a
resting DYNAMIC payload -- i.e. the speed at which the payload slips off / is
left behind. Parent #201; follows #193 (HOLD-under-load zero error) and #215
(HOLD works, but LIFT-via-``dc.set_rigid_body_pose`` -- a ``setGlobalPose``
teleport -- left the payload behind because the teleport BYPASSES the contact
integrator; ADR-0008 L2 contract clause 3).

Why horizontal drag, not a vertical lift
----------------------------------------
The #215 lift failure was an API artifact: ``setGlobalPose`` never gives the
mover a solver velocity, so it is left behind at ANY speed. Driven by a TRUE
kinematic target (``RigidBodyView.set_kinematic_targets``, below), a vertical
lift is carried by the NORMAL contact force and is essentially friction-
independent -- it only fails by contact tunnelling at absurd per-tick steps (a
geometry limit, not a speed limit). The physically real, friction-limited carry
speed limit lives in the
TANGENTIAL direction: a payload resting on a horizontally moving platform is held
only by friction (max tangential accel a_max = mu*g). Start the platform moving
too fast in one tick and friction cannot accelerate the payload to match; the
platform slides forward under it, the payload lags backward, and once the lag
exceeds the platform half-length it slides off the back edge and falls. This is
the "slips off a kinematic mover" of the issue title, and it is the case where a
threshold per-tick displacement AND a friction dependence actually exist.

Scene (one SimulationApp, a grid of independent lanes, #193 parallel-body style)
--------------------------------------------------------------------------------
For every (ramp_step d, friction mu) pair: a KINEMATIC platform plate floating
with its top at z=0.7 (so a slipped payload falls ~0.5 m to the ground and its z
drops unambiguously), and a DYNAMIC payload cube resting centred on top. Each
pair sits in its own y-lane (3 m apart) and the platform only ever moves +X, so
lanes never interact. A physics material with static=dynamic friction = mu is
bound to BOTH the platform and the payload collider, so the contact friction
coefficient is mu.

Drive: a warm-up window holds the platform still while the payload settles into
friction contact, then the CARRY phase advances the platform target by exactly d
each tick (constant velocity v = d/dt, impulsive start from rest -- so d, the
per-tick displacement, is the controlled variable exactly as the issue frames
it). The plate is driven by a TRUE PhysX kinematic target
(``RigidBodyView.set_kinematic_targets`` on the physics tensor view), which
computes the solver velocity friction acts on so the payload genuinely feels the
drag -- ``SingleRigidPrim.set_world_pose`` is only a setGlobalPose teleport
(ADR-0008 clause 3): it moves the plate but leaves its velocity 0, and a resting
payload is then dragged NOWHERE at any friction (verified). Isaac 6.0.1 core
prim wrappers expose no kinematic-target setter, so the tensor view is required.

Metric per pair
---------------
- ``payload_carried``: payload_z_final still up on the platform top (> 0.45,
  midway between the ~0.8 carried height and the ~0.1 fell-to-ground height).
- ``lag_m``: commanded platform +X travel minus payload +X travel (how far the
  payload fell behind). ~0 when carried, grows to platform-length+ when it slips.
- ``payload_z_final_m``: ~0.8 carried (rides on top) vs ~0.1 slipped (on ground).
- ``payload_rel_x_m``: payload x minus platform-centre x at the end (inside
  [-1.1, +0.1] means still over the plate).

Result
------
Per friction mu, the threshold ramp_step is the smallest swept d whose payload
slips (carried flips True->False, verified monotonic). An analytic prediction
d_crit ~= dt * sqrt(2*mu*g*L_back), L_back = plate_half + payload_half = 1.1 m
(total slip before the payload matches platform speed, v^2/(2*mu*g), reaching the
back edge), is reported alongside for cross-check -- the threshold must RISE with
mu (higher friction carries faster). There is NO committed 5.1 baseline for this
measurement; this is a first-run 6.0.1 characterization.

Results are JSON to ``--out`` (a MOUNTED path) for the host to read back; stdout
through the docker run wrapper is not reliably captured. Teardown is an explicit
``os._exit`` (isaac#248 round 9): a cold headless 6.0.1 container's Omniverse Hub
connector aborts SimulationApp.close() with a busy-TaskGroup SIGABRT; os._exit
reaches the same clean exit while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_l2_carry_speed_limit.py \\
        --out /home/<user>/work/worktree/<wt>/test/.l2-carry.json \\
        [--warmup 60] [--carry-steps 300] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# Swept per-tick displacements (m/tick) and friction coefficients.
_RAMP_STEPS = [0.003, 0.01, 0.02, 0.03, 0.04, 0.05, 0.06, 0.075, 0.1, 0.2]
_FRICTIONS = [0.2, 0.5, 1.0]

# Geometry (metres).
_PLATE_DIMS = (2.0, 0.6, 0.2)   # sx, sy, sz -> half-length in X = 1.0
_PLATE_TOP_Z = 0.7              # top surface height (floating kinematic plate)
_PAYLOAD_SIZE = 0.2             # dynamic payload cube edge
_LANE_SPACING_Y = 3.0           # y gap between independent lanes
_CARRIED_Z_THRESHOLD = 0.45     # payload_z above this => still on the plate
# Back-edge reach a payload can lag before sliding off the -X end of the plate.
_L_BACK = _PLATE_DIMS[0] * 0.5 + _PAYLOAD_SIZE * 0.5   # 1.0 + 0.1 = 1.1


def _plate_center_z():
    """Plate centre z so its top surface sits at _PLATE_TOP_Z."""
    return _PLATE_TOP_Z - _PLATE_DIMS[2] * 0.5


def _build_scene(stage):
    """Author ground + light + one (kinematic plate, dynamic payload) per lane.

    Returns the list of per-pair spec dicts.
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    UsdGeom.Xform.Define(stage, "/World")
    light = UsdLux.DistantLight.Define(stage, "/World/SunLight")
    light.CreateIntensityAttr(3000.0)

    # Static ground collider at z=0 (catches slipped payloads).
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(400.0, 400.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    plate_cz = _plate_center_z()
    payload_cz0 = _PLATE_TOP_Z + _PAYLOAD_SIZE * 0.5 + 0.005  # a hair above top
    specs = []
    lane = 0
    for mu in _FRICTIONS:
        for d in _RAMP_STEPS:
            y0 = lane * _LANE_SPACING_Y
            x0 = 0.0
            tag = f"mu{int(round(mu * 100)):03d}_d{int(round(d * 1000)):04d}"

            # Kinematic platform plate.
            plate_path = f"/World/plate_{tag}"
            plate = UsdGeom.Cube.Define(stage, plate_path)
            plate.GetSizeAttr().Set(1.0)
            plate.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(x0, y0, plate_cz)
            )
            plate.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
                Gf.Vec3f(*_PLATE_DIMS)
            )
            pprim = plate.GetPrim()
            prb = UsdPhysics.RigidBodyAPI.Apply(pprim)
            prb.CreateKinematicEnabledAttr(True)  # <-- L2: standalone kinematic
            UsdPhysics.CollisionAPI.Apply(pprim)
            UsdPhysics.MassAPI.Apply(pprim).CreateMassAttr(1.0)

            # Dynamic payload cube resting centred on the plate top.
            payload_path = f"/World/payload_{tag}"
            payload = UsdGeom.Cube.Define(stage, payload_path)
            payload.GetSizeAttr().Set(1.0)
            payload.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(x0, y0, payload_cz0)
            )
            payload.AddXformOp(UsdGeom.XformOp.TypeScale).Set(
                Gf.Vec3f(_PAYLOAD_SIZE, _PAYLOAD_SIZE, _PAYLOAD_SIZE)
            )
            cprim = payload.GetPrim()
            UsdPhysics.RigidBodyAPI.Apply(cprim)  # dynamic (kinematic default off)
            UsdPhysics.CollisionAPI.Apply(cprim)
            UsdPhysics.MassAPI.Apply(cprim).CreateMassAttr(1.0)
            # Small linear damping so a carried payload settles rather than
            # skating; far below what would mask a friction-limited slip.
            PhysxSchema.PhysxRigidBodyAPI.Apply(cprim).CreateLinearDampingAttr(0.05)

            specs.append({
                "tag": tag,
                "mu": mu,
                "ramp_step_m": d,
                "x0": x0,
                "y0": y0,
                "plate_path": plate_path,
                "payload_path": payload_path,
                "plate_cz": plate_cz,
            })
            lane += 1
    return specs


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    result = {
        "issue": "isaac#217",
        "adr": "ADR-0008 L2 kinematic contract (clause 3: kinematic target, not teleport)",
        "isaac_variant": "6.0.1",
        "warmup_steps": args.warmup,
        "carry_steps": args.carry_steps,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "plate_dims_m": list(_PLATE_DIMS),
        "payload_size_m": _PAYLOAD_SIZE,
        "back_edge_reach_m": _L_BACK,
        "ramp_steps_m": list(_RAMP_STEPS),
        "frictions": list(_FRICTIONS),
        "metric": (
            "per (ramp_step d, friction mu): payload_carried (payload z stays on "
            "the plate top vs falls to ground), lag_m (commanded plate +X travel "
            "minus payload +X travel), payload_z_final_m, payload_rel_x_m; "
            "threshold ramp_step per mu = smallest d whose payload slips"
        ),
        "analytic_prediction": (
            "d_crit ~= dt*sqrt(2*mu*g*L_back), L_back=1.1 m: total tangential slip "
            "v^2/(2*mu*g) before the payload matches plate speed reaches the back "
            "edge; threshold must RISE with mu"
        ),
        "baseline_5_1": (
            "none committed -- first-run 6.0.1 characterization of the carry speed "
            "limit (prior work #193/#215 covered HOLD-under-load, not carry speed)"
        ),
        "drive_api": None,
        "pairs": [],
        "threshold_by_friction": {},
        "friction_monotonic": None,
        "error": None,
    }

    try:
        import numpy as np
        import omni.usd
        import warp as wp
        from isaacsim.core.api import World
        from isaacsim.core.api.materials import PhysicsMaterial
        from isaacsim.core.prims import SingleGeometryPrim, SingleRigidPrim

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()

        specs = _build_scene(stage)

        # Friction: one PhysicsMaterial per mu, applied (via Isaac core, which
        # writes the physics-purpose binding PhysX actually reads) to BOTH the
        # plate and the payload collider so the contact friction coefficient is
        # mu. A raw UsdShade "physics"-purpose Bind did NOT attach (payload rode
        # frictionless); this path is the reliable one.
        materials = {}
        for mu in _FRICTIONS:
            materials[mu] = PhysicsMaterial(
                prim_path=f"/World/PhysMat_mu{int(round(mu * 100)):03d}",
                name=f"physmat_mu{int(round(mu * 100)):03d}",
                static_friction=float(mu),
                dynamic_friction=float(mu),
                restitution=0.0,
            )
        for s in specs:
            SingleGeometryPrim(s["plate_path"]).apply_physics_material(
                materials[s["mu"]]
            )
            SingleGeometryPrim(s["payload_path"]).apply_physics_material(
                materials[s["mu"]]
            )
        result["friction_api"] = (
            "isaacsim.core.api.materials.PhysicsMaterial + "
            "SingleGeometryPrim.apply_physics_material on plate AND payload"
        )

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        # The plate MUST be driven by a true PhysX kinematic TARGET so the solver
        # gives it a velocity the friction contact can act on. Isaac 6.0.1 core
        # prim wrappers expose only set_world_pose (a setGlobalPose teleport, no
        # velocity -> zero tangential drag; verified: payload never moved at any
        # mu) and set_linear_velocity (ignored on a kinematic body). The real
        # primitive, set_kinematic_targets, lives on the physics TENSOR view.
        sim_view = world.physics_sim_view
        wp_device = sim_view.device
        plate_view = {
            s["tag"]: sim_view.create_rigid_body_view(s["plate_path"])
            for s in specs
        }
        payload = {s["tag"]: SingleRigidPrim(s["payload_path"]) for s in specs}
        wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)
        result["drive_api"] = (
            "physics tensor RigidBodyView.set_kinematic_targets (pos xyz + quat "
            "xyzw) per tick on a physics:kinematicEnabled plate -> real PhysX "
            "kinematic target with solver velocity, so friction drags the payload; "
            "+ World.step. (SingleRigidPrim.set_world_pose was a no-drag teleport.)"
        )

        total_steps = args.warmup + args.carry_steps

        # Baseline payload x captured on the last warm-up frame (after settling).
        payload_x_base = {}

        for step_i in range(total_steps):
            in_carry = step_i >= args.warmup
            carry_k = 0 if not in_carry else (step_i - args.warmup + 1)
            for s in specs:
                tag = s["tag"]
                x_cmd = s["x0"] + s["ramp_step_m"] * carry_k
                # Kinematic target = pos xyz + identity quat (xyzw) for the plate.
                target = wp.array(
                    [[x_cmd, s["y0"], s["plate_cz"], 0.0, 0.0, 0.0, 1.0]],
                    dtype=wp.float32, device=wp_device,
                )
                plate_view[tag].set_kinematic_targets(target, wp_idx)
            world.step(render=False)
            if step_i == args.warmup - 1:
                for s in specs:
                    tag = s["tag"]
                    ppos, _ = payload[tag].get_world_pose()
                    payload_x_base[tag] = float(
                        np.asarray(ppos, dtype=float).reshape(-1)[0]
                    )

        # If there was no warm-up window, baseline from x0.
        for s in specs:
            payload_x_base.setdefault(s["tag"], s["x0"])

        # Collect per-pair outcomes.
        by_mu_sorted = {mu: [] for mu in _FRICTIONS}
        for s in specs:
            tag = s["tag"]
            plate_tf = np.asarray(plate_view[tag].get_transforms()).reshape(-1)
            plate_pos = plate_tf[:3].astype(float)  # pos xyz (quat follows, xyzw)
            pay_pos, _ = payload[tag].get_world_pose()
            pay_pos = np.asarray(pay_pos, dtype=float).reshape(-1)

            plate_travel = float(plate_pos[0] - s["x0"])
            payload_travel = float(pay_pos[0] - payload_x_base[tag])
            lag = plate_travel - payload_travel
            payload_z = float(pay_pos[2])
            rel_x = float(pay_pos[0] - plate_pos[0])
            carried = bool(payload_z > _CARRIED_Z_THRESHOLD)

            pair = {
                "tag": tag,
                "mu": s["mu"],
                "ramp_step_m": s["ramp_step_m"],
                "commanded_velocity_mps": s["ramp_step_m"] / args.dt,
                "plate_travel_x_m": plate_travel,
                "payload_travel_x_m": payload_travel,
                "lag_m": lag,
                "payload_z_final_m": payload_z,
                "payload_rel_x_m": rel_x,
                "payload_carried": carried,
            }
            result["pairs"].append(pair)
            by_mu_sorted[s["mu"]].append(pair)

        # Threshold ramp_step per friction: smallest d whose payload slips.
        thresholds = {}
        for mu in _FRICTIONS:
            rows = sorted(by_mu_sorted[mu], key=lambda r: r["ramp_step_m"])
            first_slip = None
            last_carried = None
            for r in rows:
                if r["payload_carried"]:
                    last_carried = r["ramp_step_m"]
                elif first_slip is None:
                    first_slip = r["ramp_step_m"]
            monotonic = True
            seen_slip = False
            for r in rows:
                if not r["payload_carried"]:
                    seen_slip = True
                elif seen_slip:
                    monotonic = False  # a carried case after a slip => non-monotone
            d_crit_pred = args.dt * math.sqrt(2.0 * mu * GRAVITY * _L_BACK)
            thresholds[f"mu_{mu}"] = {
                "mu": mu,
                "max_carried_ramp_step_m": last_carried,
                "min_slipped_ramp_step_m": first_slip,
                "threshold_between_m": [last_carried, first_slip],
                "analytic_d_crit_m": d_crit_pred,
                "carried_slipped_monotonic": monotonic,
            }
        result["threshold_by_friction"] = thresholds

        # Friction dependence: the slip threshold must rise with mu.
        order = []
        for mu in sorted(_FRICTIONS):
            fs = thresholds[f"mu_{mu}"]["min_slipped_ramp_step_m"]
            order.append(fs if fs is not None else float("inf"))
        result["friction_monotonic"] = bool(
            all(order[i] <= order[i + 1] for i in range(len(order) - 1))
        )

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
    p.add_argument("--warmup", type=int, default=60,
                   help="Warm-up steps (plate held; payload settles).")
    p.add_argument("--carry-steps", type=int, default=300,
                   help="Carry-phase steps (plate advances d each tick).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
