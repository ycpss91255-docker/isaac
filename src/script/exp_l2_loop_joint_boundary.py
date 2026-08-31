#!/usr/bin/env python3
"""L2/L3 hybrid loop-joint boundary compliance + force transfer on Isaac Sim 6.0.1 (isaac#197).

Quantifies the ADR-0008 hybrid seam: a standalone true-L2 KINEMATIC body joined to a
standalone L3 DYNAMIC body / articulation by a maximal-coordinate (loop / rigid-body)
FIXED joint. ADR-0008 coexistence rule 4 forbids kinematic links INSIDE an articulation;
the supported hybrid is a standalone kinematic anchor + a standalone dynamic side, tied by
a standalone rigid-body joint ("loops 機制"). PhysX #308 warns that a maximal-coordinate
fixed joint is *weak* -- the seam is COMPLIANT, it gives under load. This experiment builds
the minimal scene that measures both halves the issue asks for at once:

  (a) FORCE TRANSFER across the boundary. The kinematic anchor is swept in +X by a TRUE
      PhysX kinematic target (RigidBodyView.set_kinematic_targets on the physics tensor
      view -- computes solver velocity, so the constraint genuinely drags the dynamic side;
      SingleRigidPrim.set_world_pose is only a setGlobalPose teleport, ADR-0008 L2 clause 3
      / isaac#217). If the joint transmits force, the dynamic body follows: follow_ratio =
      (dynamic +X travel) / (anchor +X travel) ~ 1. A severed / non-transmitting joint
      leaves the dynamic body behind (ratio ~ 0).

  (b) BOUNDARY COMPLIANCE (give). The fixed joint pins the dynamic body to a fixed offset
      below the anchor (0.6 m in -Z), so the joint must hold the dynamic weight m*g against
      gravity. The give is the position error across the seam: boundary_give =
      ||D_actual - (K_actual + offset)||, where K_actual + offset is where a perfectly rigid
      weld would keep D. Measured statically (end of a warm-up hold: pure gravity load) and
      dynamically (peak during the +X sweep: gravity + inertial drag). A stiff seam gives
      ~0; a weak maximal joint gives a measurable, load-dependent amount.

Two side variants, each swept over payload mass [1, 10, 100] kg (the mass-ratio stress,
sub-issue #200 -- a heavier dynamic side loads the constraint harder):

  * "rigid": anchor + a plain free DYNAMIC rigid cube + maximal fixed joint. Unambiguously
    a maximal-coordinate joint (no articulation to reduce-coordinate fold), the direct
    PhysX #308 case.
  * "artic": anchor + a standalone floating L3 ARTICULATION (base link carrying
    ArticulationRootAPI + one child link on an internal fixed articulation joint, so the
    articulation is internally rigid and only the K<->base seam is under test) + maximal
    fixed joint from the anchor to the articulation base link. The literal ADR-0008 hybrid.
    NOTE (6.0.1 finding): this realization CRASHES the PhysX tensor backend with a native
    SIGSEGV (exit 139) inside libomni.physx.tensors at physics-view init -- a standalone
    articulation welded to a kinematic anchor by a *maximal-coordinate* loop joint is a
    topology the 6.0.1 tensor backend cannot build. The crash is a native abort, not a
    Python exception, so it takes the whole process down (no per-lane guard can catch it and
    no JSON is written). ``--variants`` therefore defaults to ``rigid`` only; the plain
    DYNAMIC rigid body (the "dynamic body" half of the issue's "dynamic body/articulation")
    is the supported, non-crashing realization of the same hybrid seam. Pass
    ``--variants artic`` to reproduce the crash.

Each (variant, mass) pair sits in its own y-lane (4 m apart), anchors only ever move +X, so
lanes never interact. Warm-up holds every anchor still while the dynamic sides settle on
their joints (static give), then the sweep advances every anchor by a constant per-tick
displacement (constant velocity, force transfer + dynamic give).

Metric per lane: static_give_norm_m / static_give_z_m (sag under gravity), follow_ratio
(force transfer), max_give_norm_motion_m + max_lag_x_m (dynamic compliance), stable (no NaN,
give bounded). Aggregate: force_transfer_ok (all follow_ratio > 0.9), compliant_confirmed
(any static give measurably > 0, i.e. the seam is weak as PhysX #308 predicts),
give_rises_with_mass per variant (compliance is load-dependent), stable_all (no blow-up).

There is NO committed 5.1 numeric baseline for the loop-joint give; this is a first-run
6.0.1 characterization. Prior expectation (ADR-0008 + PhysX #308): force TRANSFERS, the seam
is COMPLIANT (nonzero give rising with load -- the "weak" maximal fixed joint), stable at
reasonable mass ratios. MEASURED on 6.0.1 (rigid variant, masses 1/10/100/1000 kg): force
transfers PERFECTLY (follow_ratio 0.9999999), and the seam is NOT measurably compliant --
static give and dynamic give sit at the float32 read-back floor (~2.4e-8 m static, ~3.6e-7 m
peak during the sweep, lag ~3.6e-7 m), IDENTICAL across a 1000x mass range, with no blow-up.
So for a UsdPhysics.FixedJoint the 6.0.1 maximal-coordinate loop joint behaves as
effectively RIGID up to at least 1000 kg -- the "weak fixed joint" reputation of PhysX #308
does not bite at these static / quasi-static loads. The hybrid is usable and stiff at the
seam for a fixed weld; genuine compliance would require a softened (D6 / spring) joint.

Results are JSON to ``--out`` (a MOUNTED path) for the host to read back; stdout through the
docker run wrapper is not reliably captured. Teardown is an explicit ``os._exit`` (isaac#248
round 9): a cold headless 6.0.1 container's Omniverse Hub connector aborts
SimulationApp.close() with a busy-TaskGroup SIGABRT; os._exit reaches the same clean exit
while skipping that asserting teardown.

CLI::

    /isaac-sim/python.sh exp_l2_loop_joint_boundary.py \\
        --out /home/<user>/work/worktree/<wt>/test/.l2-loopjoint.json \\
        [--warmup 90] [--motion-steps 240] [--speed 0.5] [--dt 0.016667]
"""

import argparse
import json
import math
import os
import sys
import traceback
from pathlib import Path

GRAVITY = 9.81

# Payload masses swept (kg) -- the mass-ratio stress (heavier => harder constraint load).
# The anchor is kinematic (effectively infinite mass), so mass IS the mass ratio; 1000 kg
# is an extreme stress well past any "reasonable" hybrid load.
_MASSES = [1.0, 10.0, 100.0, 1000.0]
_VARIANTS = ("rigid", "artic")

# Geometry (metres).
_ANCHOR_SIZE = 0.3            # kinematic anchor cube edge
_BODY_SIZE = 0.3             # dynamic side cube edge
_ANCHOR_Z = 2.0             # anchor centre z (floats high; body hangs clear of ground)
_OFFSET = (0.0, 0.0, -0.6)  # rigid-weld offset of the dynamic body below the anchor
_LANE_SPACING_Y = 4.0        # y gap between independent lanes
_CHILD_DX = 0.3             # +X offset of the articulation child link from the base
_BLOWUP_M = 5.0             # give above this => treated as blow-up (unstable)


def _body_world0(y):
    """Authored world position of the dynamic side (anchor + offset) in lane y."""
    return (_OFFSET[0], y + _OFFSET[1], _ANCHOR_Z + _OFFSET[2])


def _add_fixed_joint(stage, path, body0_path, body1_path, local_pos0, local_pos1):
    """Maximal-coordinate fixed joint welding body1 to body0 at the given local anchors."""
    from pxr import Gf, UsdPhysics

    joint = UsdPhysics.FixedJoint.Define(stage, path)
    joint.CreateBody0Rel().SetTargets([body0_path])
    joint.CreateBody1Rel().SetTargets([body1_path])
    joint.CreateLocalPos0Attr().Set(Gf.Vec3f(*local_pos0))
    joint.CreateLocalPos1Attr().Set(Gf.Vec3f(*local_pos1))
    joint.CreateLocalRot0Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    joint.CreateLocalRot1Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    return joint


def _build_scene(stage, variants):
    """Author ground/light + one (kinematic anchor, dynamic side, fixed joint) per lane.

    Returns (specs, artic_errors): specs is the per-lane spec list, artic_errors maps a
    failed artic tag to its error string (that lane's dynamic side falls back to absent).
    """
    from pxr import Gf, PhysxSchema, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    UsdGeom.Xform.Define(stage, "/World")
    light = UsdLux.DistantLight.Define(stage, "/World/SunLight")
    light.CreateIntensityAttr(3000.0)

    # Static ground far below (catches a body only if the joint fully severs).
    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(400.0, 400.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    specs = []
    artic_errors = {}
    lane = 0
    for variant in variants:
        for mass in _MASSES:
            y0 = lane * _LANE_SPACING_Y
            tag = f"{variant}_m{int(round(mass)):03d}"
            bx, by, bz = _body_world0(y0)

            # Kinematic anchor (standalone true-L2 body). NB: no XformOp scale on any
            # jointed prim -- USD scales a joint's LocalPos anchors, which would corrupt
            # the weld offset; size is set on the Cube instead so LocalPos is true metres.
            anchor_path = f"/World/anchor_{tag}"
            anchor = UsdGeom.Cube.Define(stage, anchor_path)
            anchor.GetSizeAttr().Set(_ANCHOR_SIZE)
            anchor.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                Gf.Vec3d(0.0, y0, _ANCHOR_Z)
            )
            aprim = anchor.GetPrim()
            arb = UsdPhysics.RigidBodyAPI.Apply(aprim)
            arb.CreateKinematicEnabledAttr(True)  # <-- L2 standalone kinematic anchor
            UsdPhysics.MassAPI.Apply(aprim).CreateMassAttr(1.0)

            body_path = f"/World/body_{tag}"
            built = True
            if variant == "rigid":
                body = UsdGeom.Cube.Define(stage, body_path)
                body.GetSizeAttr().Set(_BODY_SIZE)
                body.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                    Gf.Vec3d(bx, by, bz)
                )
                cprim = body.GetPrim()
                UsdPhysics.RigidBodyAPI.Apply(cprim)  # dynamic
                UsdPhysics.MassAPI.Apply(cprim).CreateMassAttr(float(mass))
                PhysxSchema.PhysxRigidBodyAPI.Apply(cprim).CreateLinearDampingAttr(0.05)
            else:
                try:
                    # Standalone floating L3 articulation: base link (root) + child on
                    # an internal fixed articulation joint (internally rigid), so only
                    # the K<->base maximal seam is the compliance under test.
                    base = UsdGeom.Cube.Define(stage, body_path)
                    base.GetSizeAttr().Set(_BODY_SIZE)
                    base.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                        Gf.Vec3d(bx, by, bz)
                    )
                    bprim = base.GetPrim()
                    UsdPhysics.RigidBodyAPI.Apply(bprim)
                    UsdPhysics.MassAPI.Apply(bprim).CreateMassAttr(float(mass))
                    UsdPhysics.ArticulationRootAPI.Apply(bprim)
                    PhysxSchema.PhysxArticulationAPI.Apply(bprim)

                    child_path = f"/World/child_{tag}"
                    child = UsdGeom.Cube.Define(stage, child_path)
                    child.GetSizeAttr().Set(_BODY_SIZE)
                    child.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(
                        Gf.Vec3d(bx + _CHILD_DX, by, bz)
                    )
                    chprim = child.GetPrim()
                    UsdPhysics.RigidBodyAPI.Apply(chprim)
                    UsdPhysics.MassAPI.Apply(chprim).CreateMassAttr(float(mass) * 0.5)
                    # Internal fixed articulation joint (base -> child), 0-DOF.
                    _add_fixed_joint(
                        stage, f"/World/artjoint_{tag}", body_path, child_path,
                        (_CHILD_DX, 0.0, 0.0), (0.0, 0.0, 0.0),
                    )
                except Exception as exc:  # noqa: BLE001
                    built = False
                    artic_errors[tag] = f"{type(exc).__name__}: {exc}"

            if built:
                # Maximal-coordinate (loop / rigid-body) fixed joint: anchor -> body.
                # Weld the body origin to the anchor point _OFFSET away, so the rest
                # configuration is exactly the authored one and the give is measured
                # against (anchor + offset).
                _add_fixed_joint(
                    stage, f"/World/loopjoint_{tag}", anchor_path, body_path,
                    _OFFSET, (0.0, 0.0, 0.0),
                )

            specs.append({
                "tag": tag,
                "variant": variant,
                "mass": mass,
                "y0": y0,
                "anchor_path": anchor_path,
                "body_path": body_path if built else None,
                "built": built,
            })
            lane += 1
    return specs, artic_errors


def run(args):
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    ramp_step = args.speed * args.dt  # per-tick +X displacement of every anchor
    variants = tuple(v.strip() for v in args.variants.split(",") if v.strip())
    result = {
        "issue": "isaac#197",
        "adr": "ADR-0008 hybrid: standalone L2 kinematic + standalone L3 via maximal loop joint",
        "isaac_variant": "6.0.1",
        "warmup_steps": args.warmup,
        "motion_steps": args.motion_steps,
        "physics_dt": args.dt,
        "gravity": GRAVITY,
        "anchor_speed_mps": args.speed,
        "ramp_step_m": ramp_step,
        "weld_offset_m": list(_OFFSET),
        "masses_kg": list(_MASSES),
        "variants": list(variants),
        "metric": (
            "per (variant, mass): static_give_norm_m / static_give_z_m (seam give under "
            "gravity hold), follow_ratio (dynamic +X travel / anchor +X travel = force "
            "transfer), max_give_norm_motion_m + max_lag_x_m (dynamic give during sweep), "
            "stable (no NaN, give < blow-up); boundary_give = ||D - (anchor + offset)||"
        ),
        "expectation_5_1_baseline": (
            "none committed -- first-run 6.0.1 characterization. Per ADR-0008 + PhysX #308: "
            "force TRANSFERS (follow_ratio ~1, anchor carries the dynamic side), the maximal "
            "fixed joint is COMPLIANT ('weak', nonzero give rising with load), system STABLE "
            "(no blow-up) at reasonable mass ratios -> hybrid usable but soft at the seam"
        ),
        "drive_api": None,
        "blowup_threshold_m": _BLOWUP_M,
        "artic_build_errors": {},
        "lanes": [],
        "force_transfer_ok": None,
        "compliant_confirmed": None,
        "give_rises_with_mass": {},
        "stable_all": None,
        "error": None,
    }

    try:
        import numpy as np
        import omni.usd
        import warp as wp
        from isaacsim.core.api import World
        from isaacsim.core.prims import SingleRigidPrim

        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()

        specs, artic_errors = _build_scene(stage, variants)
        result["artic_build_errors"] = artic_errors

        world = World(stage_units_in_meters=1.0, physics_dt=args.dt,
                      rendering_dt=args.dt)
        world.reset()

        sim_view = world.physics_sim_view
        wp_device = sim_view.device
        wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)

        anchor_view = {
            s["tag"]: sim_view.create_rigid_body_view(s["anchor_path"])
            for s in specs
        }
        # Dynamic-side pose reader: SingleRigidPrim reads the PhysX pose of the body
        # (the articulation base link for the artic variant). Guarded per lane.
        body_reader = {}
        for s in specs:
            if not s["built"]:
                body_reader[s["tag"]] = None
                continue
            try:
                body_reader[s["tag"]] = SingleRigidPrim(s["body_path"])
            except Exception:  # noqa: BLE001
                body_reader[s["tag"]] = None
        result["drive_api"] = (
            "physics tensor RigidBodyView.set_kinematic_targets (pos xyz + quat xyzw) per "
            "tick on the physics:kinematicEnabled anchor -> true PhysX kinematic target with "
            "solver velocity; SingleRigidPrim.get_world_pose reads the dynamic body back; "
            "connection is a UsdPhysics.FixedJoint (maximal-coordinate loop joint)"
        )

        def _anchor_pos(tag):
            tf = np.asarray(anchor_view[tag].get_transforms()).reshape(-1)
            return tf[:3].astype(float)

        def _body_pos(tag):
            r = body_reader[tag]
            if r is None:
                return None
            try:
                pos, _ = r.get_world_pose()
                return np.asarray(pos, dtype=float).reshape(-1)
            except Exception:  # noqa: BLE001
                return None

        total_steps = args.warmup + args.motion_steps
        offset = np.asarray(_OFFSET, dtype=float)

        # Accumulators.
        static_give = {}          # tag -> (give_vec, give_norm) at end of warmup
        body_base = {}            # tag -> body pos at end of warmup (for travel)
        anchor_base = {}          # tag -> anchor pos at end of warmup
        max_give_motion = {s["tag"]: 0.0 for s in specs}
        max_lag_x = {s["tag"]: 0.0 for s in specs}
        nan_seen = {s["tag"]: False for s in specs}

        for step_i in range(total_steps):
            in_motion = step_i >= args.warmup
            k = 0 if not in_motion else (step_i - args.warmup + 1)
            for s in specs:
                tag = s["tag"]
                x_cmd = 0.0 + ramp_step * k
                target = wp.array(
                    [[x_cmd, s["y0"], _ANCHOR_Z, 0.0, 0.0, 0.0, 1.0]],
                    dtype=wp.float32, device=wp_device,
                )
                anchor_view[tag].set_kinematic_targets(target, wp_idx)
            world.step(render=False)

            for s in specs:
                tag = s["tag"]
                if not s["built"]:
                    continue
                apos = _anchor_pos(tag)
                bpos = _body_pos(tag)
                if bpos is None:
                    continue
                if not (np.all(np.isfinite(apos)) and np.all(np.isfinite(bpos))):
                    nan_seen[tag] = True
                    continue
                rigid_expected = apos + offset
                give_vec = bpos - rigid_expected
                give_norm = float(np.linalg.norm(give_vec))

                if step_i == args.warmup - 1:
                    static_give[tag] = (give_vec.copy(), give_norm)
                    body_base[tag] = bpos.copy()
                    anchor_base[tag] = apos.copy()
                if in_motion:
                    max_give_motion[tag] = max(max_give_motion[tag], give_norm)
                    lag_x = float(rigid_expected[0] - bpos[0])  # body trailing in +X
                    max_lag_x[tag] = max(max_lag_x[tag], lag_x)

        # Per-lane summary.
        by_variant = {v: [] for v in variants}
        force_ok = True
        compliant = False
        stable_all = True
        for s in specs:
            tag = s["tag"]
            if not s["built"]:
                result["lanes"].append({
                    "tag": tag, "variant": s["variant"], "mass": s["mass"],
                    "built": False, "note": "artic build failed; see artic_build_errors",
                })
                continue
            apos = _anchor_pos(tag)
            bpos = _body_pos(tag)
            sg_vec, sg_norm = static_give.get(tag, (np.zeros(3), float("nan")))
            a_base = anchor_base.get(tag)
            b_base = body_base.get(tag)
            anchor_travel = (
                float(apos[0] - a_base[0]) if a_base is not None else float("nan")
            )
            body_travel = (
                float(bpos[0] - b_base[0]) if (b_base is not None and bpos is not None)
                else float("nan")
            )
            follow_ratio = (
                body_travel / anchor_travel
                if anchor_travel not in (0.0, float("nan")) and not math.isnan(anchor_travel)
                and abs(anchor_travel) > 1e-9 else float("nan")
            )
            give_bounded = bool(max_give_motion[tag] < _BLOWUP_M)
            stable = bool((not nan_seen[tag]) and give_bounded)
            lane = {
                "tag": tag,
                "variant": s["variant"],
                "mass_kg": s["mass"],
                "built": True,
                "static_give_z_m": float(sg_vec[2]),
                "static_give_norm_m": sg_norm,
                "anchor_travel_x_m": anchor_travel,
                "body_travel_x_m": body_travel,
                "follow_ratio": follow_ratio,
                "max_give_norm_motion_m": max_give_motion[tag],
                "max_lag_x_m": max_lag_x[tag],
                "nan_seen": bool(nan_seen[tag]),
                "give_bounded": give_bounded,
                "stable": stable,
            }
            result["lanes"].append(lane)
            by_variant[s["variant"]].append(lane)
            if not (not math.isnan(follow_ratio) and follow_ratio > 0.9):
                force_ok = False
            if not math.isnan(sg_norm) and sg_norm > 1e-4:
                compliant = True
            if not stable:
                stable_all = False

        # Give rises with mass, per variant (compliance is load-dependent).
        for v in variants:
            rows = sorted(
                [r for r in by_variant[v] if not math.isnan(r["static_give_norm_m"])],
                key=lambda r: r["mass_kg"],
            )
            gives = [r["static_give_norm_m"] for r in rows]
            masses = [r["mass_kg"] for r in rows]
            monotonic = all(gives[i] <= gives[i + 1] + 1e-9 for i in range(len(gives) - 1))
            result["give_rises_with_mass"][v] = {
                "masses_kg": masses,
                "static_give_norm_m": gives,
                "monotonic_nondecreasing": bool(monotonic) if len(gives) > 1 else None,
            }

        result["force_transfer_ok"] = bool(force_ok)
        result["compliant_confirmed"] = bool(compliant)
        result["stable_all"] = bool(stable_all)

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
    p.add_argument("--variants", default="rigid",
                   help="Comma-separated dynamic-side variants (rigid[,artic]). Default "
                        "'rigid'; 'artic' crashes the 6.0.1 tensor backend (see module docstring).")
    p.add_argument("--warmup", type=int, default=90,
                   help="Warm-up steps (anchor held; dynamic side settles on the joint).")
    p.add_argument("--motion-steps", type=int, default=240,
                   help="Motion steps (anchor sweeps +X at constant speed).")
    p.add_argument("--speed", type=float, default=0.5,
                   help="Anchor +X sweep speed (m/s).")
    p.add_argument("--dt", type=float, default=1.0 / 60.0, help="Physics dt.")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
