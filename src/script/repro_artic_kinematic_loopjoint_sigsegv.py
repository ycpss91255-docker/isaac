#!/usr/bin/env python3
"""Minimal reproducer: a standalone ARTICULATION welded to a standalone KINEMATIC
anchor by a MAXIMAL (loop) UsdPhysics FixedJoint NATIVE-SIGSEGVs the PhysX tensor
backend on Isaac Sim 6.0.1 when the anchor's RigidBodyView is read back after a
driven step (isaac#197 re-validation).

Background (from ``exp_l2_loop_joint_boundary.py`` ``--variants artic``): an agent
reported that a standalone floating articulation (a body carrying
``ArticulationRootAPI``) joined to a standalone KINEMATIC rigid-body anchor via a
MAXIMAL-coordinate (loop) fixed joint reproducibly takes the whole process down
with a native SIGSEGV inside ``libomni.physx.tensors`` -- no Python exception, so
no per-lane guard catches it and no JSON is written. The compare agent flagged
this "plausible but unverifiable from the committed artifacts" (a SIGSEGV writes
no JSON). This script is the self-contained confirm/refute.

RESULT: **CONFIRMED** on Isaac Sim 6.0.1 (RTX 5090, image ``yunchien/isaac:test``,
base 6.0.1). Native crash, deterministic across repeated runs:

    libomni.physx.tensors.plugin.so!std::vector<unsigned char, ...>::
        _M_default_append(unsigned long)+0x11e9
    _physicsTensors.cpython-312-x86_64-linux-gnu.so!std::_Rb_tree<
        std::string, std::pair<std::string const, unsigned int>, ...>::
        _M_get_insert_unique_pos(std::string const&)+0x3609
    crashreporter-breakpad: terminatedByAbort = '0'   ->  SIGSEGV, not SIGABRT

The crash does NOT fire at physics-view init as first thought; it fires in the
POST-STEP READBACK. Bisection (each an actual container run):

  * ``artic`` body + anchor ``RigidBodyView.get_transforms()`` readback -> CRASH
    (both 4 lanes and a SINGLE lane).
  * ``dynamic`` body (plain rigid cube, NO ArticulationRootAPI), otherwise identical
    scene / drive / readback -> SURVIVES, exit 0. So the trigger is specifically the
    articulation-via-maximal-joint topology, not the harness or the kinematic weld.
  * ``artic`` body, readback restricted to the BODY (``get_world_pose`` only, no
    anchor ``get_transforms``) -> SURVIVES. The crashing call is precisely
    ``RigidBodyView.get_transforms()`` on the KINEMATIC ANCHOR.
  * ``artic`` body but NO readback at all (build + view creation + ``world.step``
    only) -> SURVIVES. Building the views and stepping is fine; reading the anchor
    transform tensor back is what dereferences into the corrupt tensor state.

PRECISE TRIGGER SCOPE: a standalone kinematic-anchor RigidBodyView whose body is
welded by a maximal-coordinate loop joint to a standalone floating articulation
root; calling ``get_transforms()`` on that anchor view after ``world.step`` reads a
tensor index map the backend built wrong for this topology and segfaults. Present
the same weld to a PLAIN DYNAMIC body and the readback is safe. One lane is enough;
mass, lane count, and the specific reader for the BODY do not matter.

Two body kinds via ``--body-kind``:

  * ``artic``   -- the trigger. Standalone floating articulation: base link
    (RigidBodyAPI + MassAPI + ArticulationRootAPI + PhysxArticulationAPI) + one
    child link + one internal fixed articulation joint, welded to the kinematic
    anchor by a maximal loop FixedJoint. The #197 ``artic`` construct.
  * ``dynamic`` -- the isolation control. Same scene, body is a PLAIN DYNAMIC rigid
    cube (no ArticulationRootAPI). Survives -> proves the articulation is the cause.

The outcome is the process EXIT CODE + native stderr, not the JSON: a clean run
writes ``--out`` (crashed=false) and ``os._exit(0)``; a crash writes nothing and
python.sh reports "There was an error running python" with a nonzero exit and the
breakpad backtrace above on stderr. Stage breadcrumbs go to stderr (flushed) so the
LAST breadcrumb before the native crash pins the failing stage (it is always the
post-step readback). Teardown is ``os._exit`` (isaac#248) so a survive path exits
cleanly without the busy-TaskGroup teardown abort.

CLI (defaults reproduce the crash: artic, 1 lane, drive+anchor readback)::

    # CRASH (native SIGSEGV, no JSON):
    /isaac-sim/python.sh repro_artic_kinematic_loopjoint_sigsegv.py \\
        --body-kind artic \\
        --out /home/<user>/work/worktree/<wt>/test/.repro-artic-loopjoint.artic.json

    # SURVIVES (exit 0, writes JSON) -- the isolation control:
    /isaac-sim/python.sh repro_artic_kinematic_loopjoint_sigsegv.py \\
        --body-kind dynamic \\
        --out /home/<user>/work/worktree/<wt>/test/.repro-artic-loopjoint.dynamic.json

    # isolation knobs: --masses 1,10,100,1000 (per-lane) | --reader {singleprim,
    #   articview,rigidview} | --readback {both,anchor,body,none} | --drive-steps N
"""

import argparse
import json
import os
import sys
import traceback
from pathlib import Path


def _bc(msg):
    """Flushed stderr breadcrumb -- the last one before a native crash pins it."""
    sys.stderr.write(f"[REPRO] {msg}\n")
    sys.stderr.flush()


# Geometry (metres). Mirrors exp_l2_loop_joint_boundary.py so the topology is the
# same one the #197 artic variant crashed on, stripped to a single lane.
_ANCHOR_SIZE = 0.3
_BODY_SIZE = 0.3
_ANCHOR_Z = 2.0
_OFFSET = (0.0, 0.0, -0.6)   # weld offset of the body below the anchor
_CHILD_DX = 0.3
_MASS = 10.0
_LANE_SPACING_Y = 4.0


def _add_fixed_joint(stage, path, body0_path, body1_path, local_pos0, local_pos1):
    """Maximal-coordinate fixed joint welding body1 to body0 at the given anchors."""
    from pxr import Gf, UsdPhysics

    joint = UsdPhysics.FixedJoint.Define(stage, path)
    joint.CreateBody0Rel().SetTargets([body0_path])
    joint.CreateBody1Rel().SetTargets([body1_path])
    joint.CreateLocalPos0Attr().Set(Gf.Vec3f(*local_pos0))
    joint.CreateLocalPos1Attr().Set(Gf.Vec3f(*local_pos1))
    joint.CreateLocalRot0Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    joint.CreateLocalRot1Attr().Set(Gf.Quatf(1.0, 0.0, 0.0, 0.0))
    return joint


def _build_lane(stage, tag, y0, body_kind, mass):
    """One (kinematic anchor, artic|dynamic body, maximal loop joint) lane at y0."""
    from pxr import Gf, PhysxSchema, UsdGeom, UsdPhysics

    bx, by, bz = (_OFFSET[0], y0 + _OFFSET[1], _ANCHOR_Z + _OFFSET[2])

    # Standalone true-L2 KINEMATIC anchor (no XformOp scale on a jointed prim --
    # size is on the Cube so the joint LocalPos anchors stay in true metres).
    anchor_path = f"/World/anchor_{tag}"
    anchor = UsdGeom.Cube.Define(stage, anchor_path)
    anchor.GetSizeAttr().Set(_ANCHOR_SIZE)
    anchor.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, y0, _ANCHOR_Z))
    aprim = anchor.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(aprim).CreateKinematicEnabledAttr(True)
    UsdPhysics.MassAPI.Apply(aprim).CreateMassAttr(1.0)

    body_path = f"/World/body_{tag}"
    body = UsdGeom.Cube.Define(stage, body_path)
    body.GetSizeAttr().Set(_BODY_SIZE)
    body.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(bx, by, bz))
    bprim = body.GetPrim()
    UsdPhysics.RigidBodyAPI.Apply(bprim)
    UsdPhysics.MassAPI.Apply(bprim).CreateMassAttr(float(mass))

    if body_kind == "artic":
        # Standalone floating articulation: root on the base link + one child link
        # on one internal fixed articulation joint (internally rigid), so only the
        # kinematic<->base MAXIMAL seam is exercised. This is the #197 artic case.
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
        _add_fixed_joint(
            stage, f"/World/artjoint_{tag}", body_path, child_path,
            (_CHILD_DX, 0.0, 0.0), (0.0, 0.0, 0.0),
        )
    # else "dynamic": bprim is left a plain DYNAMIC rigid body (no root API).

    # MAXIMAL-coordinate (loop) fixed joint: kinematic anchor -> body(base).
    _add_fixed_joint(
        stage, f"/World/loopjoint_{tag}", anchor_path, body_path,
        _OFFSET, (0.0, 0.0, 0.0),
    )
    return anchor_path, body_path


def _build_scene(stage, body_kind, masses):
    """Ground/light + one (anchor, body, maximal loop joint) lane per mass."""
    from pxr import Gf, UsdGeom, UsdLux, UsdPhysics

    UsdGeom.SetStageUpAxis(stage, UsdGeom.Tokens.z)
    UsdGeom.SetStageMetersPerUnit(stage, 1.0)

    UsdGeom.Xform.Define(stage, "/World")
    UsdLux.DistantLight.Define(stage, "/World/SunLight").CreateIntensityAttr(3000.0)

    ground = UsdGeom.Cube.Define(stage, "/World/Ground")
    ground.GetSizeAttr().Set(1.0)
    ground.AddXformOp(UsdGeom.XformOp.TypeTranslate).Set(Gf.Vec3d(0.0, 0.0, -0.5))
    ground.AddXformOp(UsdGeom.XformOp.TypeScale).Set(Gf.Vec3f(400.0, 400.0, 1.0))
    UsdPhysics.CollisionAPI.Apply(ground.GetPrim())

    pairs = []
    for i, mass in enumerate(masses):
        tag = f"m{int(round(mass)):04d}_{i:02d}"
        pairs.append(_build_lane(stage, tag, i * _LANE_SPACING_Y, body_kind, mass))
    return pairs


def run(args):
    from isaacsim import SimulationApp

    if args.masses.strip():
        masses = [float(m) for m in args.masses.split(",") if m.strip()]
    else:
        masses = [_MASS] * args.lanes

    _bc(f"body_kind={args.body_kind} masses={masses} reader={args.reader} "
        f"drive_steps={args.drive_steps}; booting SimulationApp(headless)")
    app = SimulationApp({"headless": True})

    result = {
        "issue": "isaac#197",
        "purpose": "minimal repro: articulation vs plain-dynamic welded to kinematic "
                   "anchor by a maximal loop FixedJoint on 6.0.1",
        "isaac_variant": "6.0.1",
        "body_kind": args.body_kind,
        "lanes": len(masses),
        "masses_kg": masses,
        "reader": args.reader,
        "drive_steps": args.drive_steps,
        "readback": args.readback,
        "topology": (
            "standalone kinematic anchor + standalone floating articulation "
            "(ArticulationRootAPI base + child + internal fixed joint) + maximal loop "
            "FixedJoint anchor->base"
            if args.body_kind == "artic" else
            "standalone kinematic anchor + PLAIN DYNAMIC rigid body (no "
            "ArticulationRootAPI) + maximal loop FixedJoint anchor->body"
        ),
        "crashed": False,          # if we reach JSON write, we did NOT native-crash
        "stage_reached": None,
        "readers_built": None,
        "step_ok": None,
        "error": None,
    }

    try:
        import omni.usd
        from isaacsim.core.api import World
        from isaacsim.core.prims import SingleRigidPrim

        _bc("creating new stage")
        ctx = omni.usd.get_context()
        ctx.new_stage()
        stage = ctx.get_stage()

        _bc(f"building scene: {len(masses)} lane(s) of {args.body_kind}")
        pairs = _build_scene(stage, args.body_kind, masses)
        result["stage_reached"] = "scene_built"

        _bc("constructing World")
        world = World(stage_units_in_meters=1.0, physics_dt=1.0 / 60.0,
                      rendering_dt=1.0 / 60.0)

        _bc("world.reset()  <-- physics tensor backend builds the physics view here")
        world.reset()
        result["stage_reached"] = "world_reset"

        _bc("fetching physics_sim_view")
        sim_view = world.physics_sim_view
        result["stage_reached"] = "sim_view"

        # Anchor views: create_rigid_body_view on every kinematic anchor ONCE and
        # keep them (exactly what exp_l2_loop_joint_boundary.py does in its dict
        # comprehension; re-creating a view on the same path returns None).
        _bc(f"create_rigid_body_view on {len(pairs)} anchor(s)")
        anchor_views = [sim_view.create_rigid_body_view(ap) for ap, _bp in pairs]
        result["stage_reached"] = "anchor_rigid_body_views"

        # Body readers -- the bisection knob.
        #   singleprim : SingleRigidPrim(body_path) then get_world_pose(). For the
        #                artic body this reads an ARTICULATION-ROOT link through the
        #                RIGID-BODY tensor path -- this is what the #197 exp does.
        #   articview  : sim_view.create_articulation_view(body_path) -- the
        #                type-correct articulation tensor path.
        #   rigidview  : sim_view.create_rigid_body_view(body_path) directly.
        # Body readers -- built ONCE and kept (exactly what the exp does): a
        # SingleRigidPrim per body, or (bisection) an articulation view.
        _bc(f"building body readers via reader={args.reader}")
        body_readers = []
        for _anchor_path, body_path in pairs:
            if args.reader == "singleprim":
                r = SingleRigidPrim(body_path)
                _ = r.get_world_pose()
                body_readers.append(r)
            elif args.reader == "articview" and args.body_kind == "artic":
                body_readers.append(sim_view.create_articulation_view(body_path))
            else:
                body_readers.append(sim_view.create_rigid_body_view(body_path))
        result["readers_built"] = len(body_readers)
        result["stage_reached"] = "body_readers"

        if args.drive_steps > 0:
            # Full exp path: warp kinematic-target drive on every anchor each step
            # (RigidBodyView.set_kinematic_targets), then the exp's POST-STEP READBACK
            # -- anchor_view.get_transforms() on every kinematic anchor AND the reused
            # body reader's get_world_pose(). The instrumented exp crashes here, in the
            # readback after step 0 (last live breadcrumb: "post world.step step_i=0").
            import warp as wp

            wp_device = sim_view.device
            wp_idx = wp.array([0], dtype=wp.int32, device=wp_device)
            _bc(f"driving {args.drive_steps} step(s): set_kinematic_targets + post-step "
                f"get_transforms/get_world_pose readback on {len(anchor_views)} lane(s)")
            ramp = 0.5 * (1.0 / 60.0)
            for step_i in range(args.drive_steps):
                x_cmd = ramp * (step_i + 1)
                for lane_i, av in enumerate(anchor_views):
                    y0 = lane_i * _LANE_SPACING_Y
                    target = wp.array(
                        [[x_cmd, y0, _ANCHOR_Z, 0.0, 0.0, 0.0, 1.0]],
                        dtype=wp.float32, device=wp_device,
                    )
                    av.set_kinematic_targets(target, wp_idx)
                world.step(render=False)
                _bc(f"post world.step step_i={step_i}; readback={args.readback}")
                # POST-STEP READBACK -- the exp's _anchor_pos + _body_pos. The knob
                # isolates which side triggers the crash.
                if args.readback in ("both", "anchor"):
                    for av in anchor_views:
                        _ = av.get_transforms()   # RigidBodyView on kinematic anchor
                if args.readback in ("both", "body"):
                    for r in body_readers:
                        try:
                            _ = r.get_world_pose()
                        except Exception:  # noqa: BLE001
                            pass
            result["step_ok"] = True
            result["stage_reached"] = "driven"
        else:
            _bc("world.step(render=False)")
            world.step(render=False)
            result["step_ok"] = True
            result["stage_reached"] = "stepped"
        _bc("SURVIVED: no native crash (exit 0 path)")

    except Exception as exc:  # noqa: BLE001
        result["error"] = f"{type(exc).__name__}: {exc}"
        result["traceback"] = traceback.format_exc()
        _bc(f"PYTHON EXCEPTION (not a native crash): {result['error']}")
    finally:
        try:
            Path(args.out).write_text(json.dumps(result, indent=2))
            _bc(f"wrote {args.out}")
        except Exception:  # noqa: BLE001
            pass
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(1 if result["error"] else 0)


def _parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--body-kind", choices=("artic", "dynamic"), default="artic",
                   help="artic = suspected crash trigger; dynamic = isolation control.")
    p.add_argument("--lanes", type=int, default=1,
                   help="Number of independent (anchor, body, loop joint) lanes, each "
                        "at mass _MASS. Ignored when --masses is given.")
    p.add_argument("--masses", default="",
                   help="Comma-separated per-lane masses (one lane each), e.g. "
                        "'1,10,100,1000' to match the #197 exp exactly. Overrides --lanes.")
    p.add_argument("--reader", choices=("singleprim", "articview", "rigidview"),
                   default="singleprim",
                   help="How the body pose is read back: singleprim (SingleRigidPrim, "
                        "the #197 exp's path; reads an articulation root through the "
                        "RIGID-body view), articview (create_articulation_view), or "
                        "rigidview (create_rigid_body_view).")
    p.add_argument("--drive-steps", type=int, default=2,
                   help="If >0 (default 2), run the full exp drive: warp "
                        "set_kinematic_targets on every anchor each step for N steps, "
                        "then the post-step readback -- the readback is where the crash "
                        "fires, so the default reproduces it. 0 = single step, no "
                        "readback (survives).")
    p.add_argument("--readback", choices=("both", "anchor", "body", "none"),
                   default="both",
                   help="Post-step tensor readback: both (exp path), anchor "
                        "(RigidBodyView.get_transforms only), body (get_world_pose "
                        "only), or none. Isolates which readback triggers the crash.")
    p.add_argument("--out", required=True, help="JSON results path (mounted).")
    return p.parse_args()


if __name__ == "__main__":
    run(_parse_args())
