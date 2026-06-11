"""Declarative scene composition from YAML config.

Reads a Scene YAML that lists robot + objects + sensors, resolves
model paths relative to repo root, and assembles the scene at runtime.

Host-side functions (load_scene, resolve_model_path, generate_instances,
resolve_sensor_configs) work without Isaac Sim. The build_scene()
function requires Isaac Sim (adds USD references to stage).

Usage from an IsaacDriver subclass:

    from isaac_devkit.scene import load_scene, build_scene
    scene = load_scene("scene/warehouse_pushback.yaml", repo_root)
    build_scene(scene, stage, repo_root)
"""

from pathlib import Path

import yaml


def load_scene(path, repo_root):
    """Load and validate a Scene YAML config."""
    p = Path(path).expanduser().resolve()
    if not p.exists():
        raise FileNotFoundError(f"scene config not found: {p}")
    with p.open() as f:
        scene = yaml.safe_load(f)
    _validate_scene(scene, source=str(p))
    return scene


def _validate_scene(scene, source):
    if "robot" not in scene:
        raise ValueError(f"{source}: missing 'robot' section")

    robot = scene["robot"]
    if "model" not in robot:
        raise ValueError(f"{source}: robot needs 'model'")
    if "pose" not in robot:
        raise ValueError(f"{source}: robot needs 'pose'")

    for i, obj in enumerate(scene.get("objects", [])):
        if "model" not in obj:
            raise ValueError(f"{source}: objects[{i}] needs 'model'")
        if "pose" not in obj:
            raise ValueError(f"{source}: objects[{i}] needs 'pose'")


def resolve_model_path(model_rel, repo_root):
    """Resolve a repo-relative model path to absolute.

    model_rel is relative to model/usd/, e.g. "robot/openbase/openbase.usd".
    """
    resolved = Path(repo_root) / "model" / "usd" / model_rel
    if not resolved.exists():
        raise FileNotFoundError(
            f"model not found: {resolved} "
            f"(from model_rel='{model_rel}', repo_root='{repo_root}')"
        )
    return resolved


def generate_instances(entry):
    """Expand a single object entry into N instances with spacing applied.

    Returns a list of dicts, each with 'model', 'pose', and optionally
    'variant'. The original entry is not modified.
    """
    count = entry.get("count", 1)
    spacing = entry.get("spacing", [0, 0, 0])
    base_xyz = list(entry["pose"]["xyz"])
    rpy = entry["pose"]["rpy"]
    variant = entry.get("variant")
    model = entry["model"]

    instances = []
    for i in range(count):
        xyz = [
            base_xyz[0] + spacing[0] * i,
            base_xyz[1] + spacing[1] * i,
            base_xyz[2] + spacing[2] * i,
        ]
        inst = {
            "model": model,
            "pose": {"xyz": xyz, "rpy": list(rpy)},
        }
        if variant is not None:
            inst["variant"] = variant
        instances.append(inst)
    return instances


def resolve_sensor_configs(scene, repo_root):
    """Resolve sensor config paths relative to repo root.

    Returns a list of absolute Path objects for each sensor YAML.
    """
    sensor_refs = scene.get("sensors", [])
    resolved = []
    for ref in sensor_refs:
        p = Path(repo_root) / ref
        if not p.exists():
            raise FileNotFoundError(
                f"sensor config not found: {p} (from ref='{ref}')"
            )
        resolved.append(p)
    return resolved


def build_scene(scene, stage, repo_root):
    """Assemble the scene on a live USD stage. Requires Isaac Sim.

    1. Add robot USD as reference, apply pose
    2. For each object: generate instances, add references, apply poses,
       select variants
    3. Resolve and setup sensors via isaac_devkit.sensors
    """
    robot = scene["robot"]
    robot_usd = resolve_model_path(robot["model"], repo_root)
    robot_prim_path = "/World/Robot"
    robot_prim = stage.DefinePrim(robot_prim_path, "Xform")
    robot_prim.GetReferences().AddReference(str(robot_usd))
    _apply_pose(robot_prim, robot["pose"])

    for idx, obj_entry in enumerate(scene.get("objects", [])):
        instances = generate_instances(obj_entry)
        for inst_idx, inst in enumerate(instances):
            obj_usd = resolve_model_path(inst["model"], repo_root)
            prim_name = Path(inst["model"]).stem
            prim_path = f"/World/Objects/{prim_name}_{idx}_{inst_idx}"
            obj_prim = stage.DefinePrim(prim_path, "Xform")
            obj_prim.GetReferences().AddReference(str(obj_usd))
            _apply_pose(obj_prim, inst["pose"])

            if "variant" in inst:
                for vs_name, vs_value in inst["variant"].items():
                    vs = obj_prim.GetVariantSets().GetVariantSet(vs_name)
                    if vs:
                        vs.SetVariantSelection(vs_value)

    sensor_paths = resolve_sensor_configs(scene, repo_root)
    if sensor_paths:
        from isaac_devkit.sensors import load_config, setup_sensor
        for sp in sensor_paths:
            cfg = load_config(sp)
            setup_sensor(cfg, stage)


def _apply_pose(prim, pose):
    """Apply translate + rotateXYZ to a USD prim."""
    from pxr import Gf, UsdGeom
    xformable = UsdGeom.Xformable(prim)
    xformable.ClearXformOpOrder()

    translate_op = xformable.AddTranslateOp()
    x, y, z = pose["xyz"]
    translate_op.Set(Gf.Vec3d(float(x), float(y), float(z)))

    rotate_op = xformable.AddRotateXYZOp()
    r, p, yaw = pose["rpy"]
    rotate_op.Set(Gf.Vec3f(float(r), float(p), float(yaw)))
