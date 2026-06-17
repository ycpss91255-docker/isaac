"""Declarative scene composition from YAML config.

Reads a Scene YAML that lists robot + objects + sensors, resolves model
paths relative to repo root, and assembles the scene at runtime via Isaac
Lab ``sim_utils`` config-dataclass spawners (ADR-0018 decisions 1, 3).

The host-side surface is pure (no Isaac / pxr import): ``load_scene``,
``resolve_model_path``, ``generate_instances``, ``resolve_sensor_configs``
and the new ``to_isaaclab_cfg`` adapter, which maps a validated scene dict
to a neutral, JSON-serializable list of ``SpawnSpec`` records. Only
``build_scene`` materializes those specs into real ``isaaclab.sim`` cfg
objects and spawns them, and it imports ``isaaclab.sim`` function-locally
(ADR-0017 section 8 import-safety invariant).

``SpawnSpec`` is the stable seam (ADR-0018 decision 1): the same spec list
can later be collected into an ``InteractiveSceneCfg`` ("C") without
changing the YAML schema or this adapter contract.

Usage from an IsaacDriver subclass:

    from isaac_devkit.scene import load_scene, build_scene
    scene = load_scene("scene/warehouse_pushback.yaml", repo_root)
    build_scene(scene, stage, repo_root)
"""

import math
from pathlib import Path
from typing import NamedTuple, Optional

import yaml


class SpawnSpec(NamedTuple):
    """A neutral, GPU-free description of one prim to spawn.

    Pure / JSON-serializable: ``to_isaaclab_cfg`` returns these so a hosted
    unit test can assert the YAML -> cfg mapping without a live stage.
    ``build_scene`` materializes each into the matching ``isaaclab.sim``
    cfg dataclass and spawns it via ``cfg.func``.

    Fields:
        prim_path: USD prim path the spec spawns at (e.g. "/World/Robot").
        kind: One of "ground_plane", "distant_light", "usd".
        kwargs: Constructor kwargs for the cfg dataclass (incl. any
            ``spawn_overrides`` and, for "usd", ``usd_path``).
        translation: (x, y, z) in meters.
        orientation: (w, x, y, z) quaternion.
        mobility: "dynamic" / "static" / None (physics-prop selection for
            "usd" specs; ignored for environment specs).
    """

    prim_path: str
    kind: str
    kwargs: dict
    translation: tuple
    orientation: tuple
    mobility: Optional[str]


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
    'variant'. Curated extras the adapter forwards (``mobility``,
    ``spawn_overrides``, ``material``) are carried through unchanged so a
    multi-instance object behaves like its single-instance form. The
    original entry is not modified.
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
        for key in ("mobility", "spawn_overrides", "material"):
            if key in entry:
                inst[key] = entry[key]
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


def rpy_to_quat(rpy_deg):
    """Convert roll/pitch/yaw degrees to a (w, x, y, z) quaternion.

    Rotation order is XYZ intrinsic (roll about X, then pitch about Y,
    then yaw about Z), matching the old ``UsdGeom.AddRotateXYZOp`` the
    raw-pxr path used. Pure math (no numpy): each axis rotation is a
    quaternion and they are composed q = qz * qy * qx so that, read as
    intrinsic body-frame rotations, X is applied first.

    Args:
        rpy_deg: (roll, pitch, yaw) in degrees.

    Returns:
        (w, x, y, z) unit quaternion tuple of floats.
    """
    roll, pitch, yaw = (math.radians(float(a)) for a in rpy_deg)
    cr, sr = math.cos(roll / 2.0), math.sin(roll / 2.0)
    cp, sp = math.cos(pitch / 2.0), math.sin(pitch / 2.0)
    cy, sy = math.cos(yaw / 2.0), math.sin(yaw / 2.0)

    # q = qz * qy * qx (XYZ intrinsic; X applied first).
    w = cr * cp * cy + sr * sp * sy
    x = sr * cp * cy - cr * sp * sy
    y = cr * sp * cy + sr * cp * sy
    z = cr * cp * sy - sr * sp * cy
    return (w, x, y, z)


def _material_diffuse_for(entry, repo_root):
    """Return an (r, g, b) diffuse color for an entry, or None.

    The entry may carry a ``material`` key pointing to a material YAML
    (repo-relative) plus an optional ``variant`` selection. We reuse the
    pure ``materials.material_cfg_from_yaml`` mapper (#153) and take the
    diffuse color of the FIRST prim that declares one -- the minimal hook
    so ``build_scene`` can attach a ``PreviewSurfaceCfg``. Full per-prim
    material GPU coverage is #154. No material key -> None (skip).
    """
    material_rel = entry.get("material")
    if not material_rel:
        return None

    from isaac_devkit.materials import (
        load_material_config,
        material_cfg_from_yaml,
    )

    material_path = Path(repo_root) / material_rel
    cfg = load_material_config(material_path)
    variant = entry.get("variant")
    if isinstance(variant, dict):
        # A variant dict (e.g. {"color": "blue"}) selects by its value.
        variant = next(iter(variant.values()), None)
    spawn_cfg = material_cfg_from_yaml(cfg, variant=variant)
    for props in spawn_cfg.values():
        if "diffuse_color" in props:
            return tuple(props["diffuse_color"])
    return None


def _usd_spec(prim_path, entry, usd_abs, repo_root, mobility=None):
    """Build a "usd" SpawnSpec from a curated entry + resolved USD path.

    Curated -> kwargs: ``model`` -> ``usd_path`` (the absolute path str),
    ``pose.xyz`` -> ``translation``, ``pose.rpy`` (deg) -> ``orientation``
    quaternion, ``variant`` -> ``variants`` kwarg (structurally-distinct
    variant selection, ADR-0018 decision 7), and an optional material
    diffuse color recorded under ``visual_material_diffuse``.

    ``spawn_overrides`` (raw passthrough) is spread onto kwargs LAST so
    overrides win over curated fields (intentional power-user control,
    ADR-0018 decision 3).
    """
    pose = entry["pose"]
    kwargs = {"usd_path": str(usd_abs)}

    variant = entry.get("variant")
    if variant is not None:
        kwargs["variants"] = variant

    diffuse = _material_diffuse_for(entry, repo_root)
    if diffuse is not None:
        kwargs["visual_material_diffuse"] = diffuse

    # Raw passthrough wins over curated fields (overrides-win).
    kwargs.update(entry.get("spawn_overrides", {}))

    return SpawnSpec(
        prim_path=prim_path,
        kind="usd",
        kwargs=kwargs,
        translation=tuple(float(c) for c in pose["xyz"]),
        orientation=rpy_to_quat(pose["rpy"]),
        mobility=mobility,
    )


def to_isaaclab_cfg(scene, repo_root):
    """Map a validated scene dict to a neutral list of ``SpawnSpec``.

    PURE: imports no Isaac module. Emits, in order:

    1. environment ground plane (if ``environment.ground_plane`` truthy)
       at ``/World/ground``;
    2. a distant light at ``/World/light`` from ``environment.light``
       (curated optional ``intensity`` / ``color`` / ``angle``); if
       ``environment.light`` is absent a sensible default SunLight is
       still emitted so "ground + light spawn via the adapter" holds
       (DoD) -- the driver's ``_ensure_scene_defaults`` defers to this;
    3. the robot USD at ``/World/Robot``;
    4. one USD spec per object instance at
       ``/World/Objects/<modelstem>_<idx>_<instidx>``, carrying mobility.

    ``spawn_overrides`` on any entry is spread onto that spec's kwargs
    (overrides-win). The returned list is the stable seam (ADR-0018
    decision 1): a hosted unit test asserts on it without a live stage.
    """
    specs = []

    environment = scene.get("environment", {}) or {}
    if environment.get("ground_plane"):
        ground_kwargs = dict(environment.get("ground_overrides", {}))
        specs.append(
            SpawnSpec(
                prim_path="/World/ground",
                kind="ground_plane",
                kwargs=ground_kwargs,
                translation=(0.0, 0.0, 0.0),
                orientation=(1.0, 0.0, 0.0, 0.0),
                mobility=None,
            )
        )

    light = environment.get("light")
    light_kwargs = {}
    if isinstance(light, dict):
        for key in ("intensity", "color", "angle"):
            if key in light:
                light_kwargs[key] = light[key]
        light_kwargs.update(light.get("spawn_overrides", {}))
    else:
        # Default SunLight: enough to keep headless debug renders readable.
        light_kwargs = {"intensity": 3000.0}
    specs.append(
        SpawnSpec(
            prim_path="/World/light",
            kind="distant_light",
            kwargs=light_kwargs,
            translation=(0.0, 0.0, 10.0),
            orientation=(1.0, 0.0, 0.0, 0.0),
            mobility=None,
        )
    )

    robot = scene["robot"]
    robot_usd = resolve_model_path(robot["model"], repo_root)
    specs.append(
        _usd_spec("/World/Robot", robot, robot_usd, repo_root)
    )

    for idx, obj_entry in enumerate(scene.get("objects", [])):
        instances = generate_instances(obj_entry)
        for inst_idx, inst in enumerate(instances):
            obj_usd = resolve_model_path(inst["model"], repo_root)
            prim_name = Path(inst["model"]).stem
            prim_path = f"/World/Objects/{prim_name}_{idx}_{inst_idx}"
            specs.append(
                _usd_spec(
                    prim_path,
                    inst,
                    obj_usd,
                    repo_root,
                    mobility=inst.get("mobility"),
                )
            )

    return specs


def build_scene(scene, stage, repo_root):
    """Assemble the scene on the active USD stage. Requires Isaac Lab.

    Rewritten (ADR-0018 decisions 1, 3) to spawn via Isaac Lab
    ``sim_utils`` config-dataclass spawners instead of raw ``pxr``
    ``DefinePrim`` / ``GetReferences().AddReference``. The pure
    ``to_isaaclab_cfg`` adapter produces the spec list; this function
    materializes each ``SpawnSpec`` into the matching cfg dataclass and
    calls ``cfg.func(prim_path, cfg, translation=, orientation=)``.

    Physics props (ADR-0018):
      * ``mobility == "dynamic"`` -> rigid body + mass + collision props.
      * ``mobility == "static"``  -> collision props only (static
        collider, no rigid body).
      * ``mobility is None``      -> no physics props.

    The ``stage`` param is retained for signature stability (the spawners
    use the active USD context, not an explicit stage handle); it is set
    as the active stage when a context is available.

    Sensors (unchanged) are resolved and set up via ``isaac_devkit.sensors``.
    """
    import isaaclab.sim as sim_utils

    _set_active_stage(stage)

    for spec in to_isaaclab_cfg(scene, repo_root):
        cfg = _materialize_cfg(sim_utils, spec)
        cfg.func(
            spec.prim_path,
            cfg,
            translation=spec.translation,
            orientation=spec.orientation,
        )

    sensor_paths = resolve_sensor_configs(scene, repo_root)
    if sensor_paths:
        from isaac_devkit.sensors import load_config, setup_sensor
        for sp in sensor_paths:
            cfg = load_config(sp)
            setup_sensor(cfg, stage)


def _set_active_stage(stage):
    """Make ``stage`` the active USD context stage, best-effort.

    The ``sim_utils`` spawners author into the active USD context; the
    driver already opens the stage on that context, so this is normally a
    no-op. Guarded so a None / detached stage does not break spawning.
    """
    if stage is None:
        return
    try:
        import omni.usd

        ctx = omni.usd.get_context()
        if ctx.get_stage() is not stage:
            ctx.attach_stage(stage)
    except Exception:  # noqa: BLE001  (best-effort; spawners use the context)
        pass


def _materialize_cfg(sim_utils, spec):
    """Turn a SpawnSpec into the concrete ``sim_utils`` cfg dataclass."""
    if spec.kind == "ground_plane":
        return sim_utils.GroundPlaneCfg(**spec.kwargs)

    if spec.kind == "distant_light":
        return sim_utils.DistantLightCfg(**spec.kwargs)

    if spec.kind == "usd":
        kwargs = dict(spec.kwargs)
        diffuse = kwargs.pop("visual_material_diffuse", None)
        if diffuse is not None:
            kwargs["visual_material"] = sim_utils.PreviewSurfaceCfg(
                diffuse_color=tuple(diffuse)
            )
        if spec.mobility == "dynamic":
            kwargs.setdefault(
                "rigid_props", sim_utils.RigidBodyPropertiesCfg()
            )
            kwargs.setdefault("mass_props", sim_utils.MassPropertiesCfg())
            kwargs.setdefault(
                "collision_props", sim_utils.CollisionPropertiesCfg()
            )
        elif spec.mobility == "static":
            kwargs.setdefault(
                "collision_props", sim_utils.CollisionPropertiesCfg()
            )
        return sim_utils.UsdFileCfg(**kwargs)

    raise ValueError(f"unknown SpawnSpec kind: {spec.kind!r}")
