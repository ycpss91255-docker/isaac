#!/usr/bin/env python3
"""Import a URDF into a single Isaac Lab instanceable USD.

Run inside the Isaac Sim 5.1 / Isaac Lab 2.3 container:

    PYTHONPATH=/home/yunchien/work/framework /isaac-sim/python.sh \\
        -m isaac_devkit.model_import \\
        --urdf /home/yunchien/work/src/model/urdf/robot/openbase/openbase_minimal.urdf \\
        --output /home/yunchien/work/src/model/usd/robot/openbase/ \\
        --name openbase

Output (ADR-0018 decision 6 -- a single instanceable USD):

    <output>/
    └── <name>.usd      # Isaac-Lab-produced instanceable USD (the whole artifact)

Re-import with ``--force`` regenerates ``<name>.usd`` cleanly. There is no
longer a separate geometry / material / textures layout (the old "Asset
Structure 3.0" sublayer chain is dropped; material color is now a spawn-time
cfg parameter, see ``isaac_devkit.materials``).

Besides the CLI, this module exposes the ADR-0017 section 9 contract:

    import_urdf(urdf_path, out_usd_path) -> PrimSummary

Import-safety invariant (ADR-0017 section 8 / PRD A1): pure functions
live at module top; every ``omni`` / ``pxr`` / ``isaacsim`` / ``isaaclab``
import is function-local so this module imports cleanly on hosts without
Isaac Sim. (``isaaclab`` transitively pulls in ``omni``, so its imports
must be function-local too.)

URDF -> USD conversion is delegated to Isaac Lab's
``isaaclab.sim.converters.UrdfConverterCfg`` / ``UrdfConverter``
(ADR-0018 decision 6), which wraps the same
``isaacsim.asset.importer.urdf`` engine the legacy ``omni.kit.commands``
path drove, while producing an instanceable USD (the format ADR-0018's
deferred "C" scene cloning needs).
"""

import argparse
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from typing import NamedTuple

# Built-in collision approximations exposed by ``UrdfConverterCfg.collider_type``
# (ADR-0020 decision 2). ``"convex_hull"`` is Isaac Lab's default: the whole
# part's convex hull, which fills in every concavity. ``"convex_decomposition"``
# breaks the mesh into multiple convex pieces, preserving a concavity (e.g. the
# gap between a forklift's forks). Neither is a full-resolution triangle-mesh
# collider; full-mesh (static-only) and SDF colliders are out of scope (#167).
_COLLIDER_TYPES = ("convex_hull", "convex_decomposition")
_DEFAULT_COLLIDER_TYPE = "convex_hull"

# Isaac Lab's Kit experience file (cloned to /opt/IsaacLab in the image,
# ADR-0018 decision 4 / 5). It pins the URDF importer extension
# "isaacsim.asset.importer.urdf" to {version = "2.4.31", exact = true}
# (Isaac Lab PR #4000, shipped in v2.3.1+). model_import boots its
# SimulationApp with this experience so the converter loads the 2.4.31
# importer (which restores merge_fixed_joints; ADR-0020 decision 4)
# instead of the default Isaac Sim 5.1 experience, which loads the bundled
# 2.4.30 importer FIRST and then makes the manager's swap to 2.4.31 a
# constraint conflict ("isaacsim.asset.importer.urdf-2.4.31 is incompatible
# with other constraints"). Pinning the experience means 2.4.30 is never
# loaded, so UrdfConverter's enable of 2.4.31 resolves cleanly (the GPU
# runner HAS network and fetches it from the Kit extension registry).
# Overridable via ISAACLAB_KIT_EXPERIENCE for a non-default install path.
_ISAACLAB_KIT_EXPERIENCE = "/opt/IsaacLab/apps/isaaclab.python.kit"


def _simulation_app_kwargs():
    """SimulationApp kwargs that pin Isaac Lab's 2.4.31-importer experience.

    Boots Kit with Isaac Lab's ``isaaclab.python.kit`` experience (which
    pins ``isaacsim.asset.importer.urdf-2.4.31`` exact) instead of the
    default Isaac Sim experience that pre-loads the bundled 2.4.30 importer
    -- the pre-load is the root cause of the ``set_merge_fixed_ignore_inertia``
    ``AttributeError`` (#177): with 2.4.30 already resolved, the manager
    cannot swap to 2.4.31 and ``UrdfConverter`` runs against the older
    importer that lacks the merge method.

    The experience path is taken from ``ISAACLAB_KIT_EXPERIENCE`` if set,
    else the baked default ``/opt/IsaacLab/apps/isaaclab.python.kit``. If
    the file does not exist (e.g. a hosted/dev box with no Isaac Lab clone),
    the experience key is omitted so ``SimulationApp`` falls back to its
    default experience rather than failing on a missing file.
    """
    kwargs = {"headless": True}
    experience = os.environ.get(
        "ISAACLAB_KIT_EXPERIENCE", _ISAACLAB_KIT_EXPERIENCE
    )
    if experience and Path(experience).exists():
        kwargs["experience"] = experience
    return kwargs


def _parse_args():
    parser = argparse.ArgumentParser(
        description="Import a URDF into a single Isaac Lab instanceable USD.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--urdf",
        required=True,
        help="Path to URDF file (inside container).",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Output directory for the produced <name>.usd.",
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Model name (used for the output file name: <name>.usd).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite an existing <name>.usd.",
    )
    parser.add_argument(
        "--no-fix-base",
        action="store_true",
        help="Allow root link to free-fall (default: fix to world).",
    )
    parser.add_argument(
        "--no-merge-fixed",
        action="store_true",
        help="Keep fixed-joint links separate (default: merge into rigid body).",
    )
    parser.add_argument(
        "--collider-type",
        choices=_COLLIDER_TYPES,
        default=_DEFAULT_COLLIDER_TYPE,
        help=(
            "Collision approximation (ADR-0020 decision 2). Default "
            "'convex_hull' fills concavities (the whole part's hull); a "
            "concave part (e.g. forklift forks) must opt into "
            "'convex_decomposition' (multiple convex pieces) or supply a "
            "hand-authored simplified collision mesh. Importing the visual "
            "mesh does NOT give full-resolution collision."
        ),
    )
    parser.add_argument(
        "--joint-drive-stiffness",
        type=float,
        default=None,
        help=(
            "Import-time default-drive position Kp (ADR-0020 decision 3). "
            "Maps to UrdfConverterCfg.joint_drive=JointDriveCfg(position/"
            "force). Must be paired with --joint-drive-damping; omit both "
            "to keep the fixed-joint-safe joint_drive=None default."
        ),
    )
    parser.add_argument(
        "--joint-drive-damping",
        type=float,
        default=None,
        help="Import-time default-drive velocity Kd (pairs with stiffness).",
    )
    return parser.parse_args()


def _resolve_paths(args):
    """Resolve and validate paths, return a dict of output paths.

    The single produced artifact is ``<output>/<name>.usd`` (ADR-0018
    decision 6). The old multi-file Asset Structure 3.0 keys
    (geometry / material / textures) are gone.
    """
    urdf_path = Path(args.urdf).resolve()
    if not urdf_path.exists():
        print(f"error: URDF not found: {urdf_path}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output).resolve()
    name = args.name

    return {
        "urdf": urdf_path,
        "out_dir": out_dir,
        "usd": out_dir / f"{name}.usd",
    }


def _check_existing(paths, force):
    """Block on an existing <name>.usd unless --force is given."""
    if paths["usd"].exists() and not force:
        print(
            f"error: {paths['usd']} already exists. Use --force to overwrite.",
            file=sys.stderr,
        )
        sys.exit(1)


def _ensure_dirs(paths):
    """Create the output directory."""
    paths["out_dir"].mkdir(parents=True, exist_ok=True)


_PACKAGE_URI_RE = re.compile(r'filename="package://([^/]+)/([^"]+)"')

# Heuristic threshold for the URDF units sanity check (#170, ADR-0020
# decision 6). URDF carries NO units field -- it is meters by convention
# (ROS REP-103). A hard "assert meters" is therefore impossible from
# metadata, so this is a best-effort WARNING, not a hard failure.
#
# A mm-export looks like a metre-export with every length multiplied by
# ~1000. We flag a URDF whose largest length magnitude (joint origin xyz,
# box/cylinder/sphere geometry dims, or a <mesh scale="...">) exceeds this
# threshold. 100.0 metres is chosen so a generously large real robot
# (e.g. a 30 m gantry, or a few-metre forklift with margin) never trips
# it, while an mm export of even a 10 cm part (0.1 m -> 100 mm == 100.0)
# sits right at the boundary and a realistic robot (sub-metre to several
# metres of geometry) in mm (hundreds to thousands) trips it cleanly. It
# is a heuristic for a likely-mm export, not a precise unit detector.
_UNIT_WARN_MAGNITUDE_M = 100.0


def _check_urdf_units(urdf_path):
    """Best-effort sanity check that a URDF looks like meters (REP-103).

    URDF has no unit field; it is meters by convention (ROS REP-103).
    A CAD exporter can silently emit millimetres, which produces a
    wrongly-sized USD. The reference SolidWorks exporter emits meters,
    so this guard is cheap insurance against a mis-exported URDF.

    Because there is no metadata to assert against, this is a documented
    HEURISTIC that emits a WARNING (it does not raise): if the largest
    length magnitude in the model -- joint ``<origin xyz=...>``,
    primitive ``<box>``/``<cylinder>``/``<sphere>`` dimensions, or a
    ``<mesh scale=...>`` factor -- exceeds ``_UNIT_WARN_MAGNITUDE_M``
    metres, the URDF is most likely a millimetre (or otherwise mis-scaled)
    export. The threshold (100 m) is far above any plausible single robot
    dimension in meters yet well below the hundreds/thousands a mm export
    produces. The user normalizes units upstream if their exporter does
    not emit meters.

    Args:
        urdf_path: Path to the (already xacro-expanded) URDF file.

    Returns:
        ``True`` if a likely-mm / mis-scaled magnitude was found and a
        warning was emitted; ``False`` if the URDF looks like meters.
    """
    return _check_urdf_units_text(urdf_path.read_text())


def _check_urdf_units_text(content):
    """Units sanity check on URDF XML text; see ``_check_urdf_units``."""
    try:
        root = ElementTree.fromstring(content)
    except ElementTree.ParseError:
        # Malformed XML is the importer's problem to report, not the
        # unit check's; do not mask it with a unit warning.
        return False

    max_mag = 0.0
    worst = ""

    def consider(values, label):
        nonlocal max_mag, worst
        for token in values:
            try:
                mag = abs(float(token))
            except (TypeError, ValueError):
                continue
            if mag > max_mag:
                max_mag = mag
                worst = label

    for origin in root.iter("origin"):
        xyz = origin.get("xyz")
        if xyz:
            consider(xyz.split(), f"<origin xyz=\"{xyz}\">")
    for box in root.iter("box"):
        size = box.get("size")
        if size:
            consider(size.split(), f"<box size=\"{size}\">")
    for cyl in root.iter("cylinder"):
        consider([cyl.get("radius"), cyl.get("length")],
                 "<cylinder radius/length>")
    for sphere in root.iter("sphere"):
        consider([sphere.get("radius")], "<sphere radius>")
    for mesh in root.iter("mesh"):
        scale = mesh.get("scale")
        if scale:
            consider(scale.split(), f"<mesh scale=\"{scale}\">")

    if max_mag > _UNIT_WARN_MAGNITUDE_M:
        print(
            "  warning: URDF unit sanity check -- largest length magnitude "
            f"{max_mag:g} (from {worst}) exceeds {_UNIT_WARN_MAGNITUDE_M:g} m; "
            "URDF is assumed meters (REP-103) and this looks like a "
            "millimetre or mis-scaled export. If your CAD exporter does not "
            "emit meters, normalize units upstream before import.",
            file=sys.stderr,
            flush=True,
        )
        return True
    return False


def _is_xacro(urdf_path, content):
    """Detect a xacro input by extension or by xacro namespace/tags.

    A xacro URDF is either named ``*.xacro`` or carries the xacro XML
    namespace (``xmlns:xacro=...``) / ``xacro:`` element prefixes. The
    Isaac importer cannot read xacro, so a positive detection means the
    preprocess must expand it to plain URDF first (#169).
    """
    if urdf_path.suffix == ".xacro" or urdf_path.name.endswith(".urdf.xacro"):
        return True
    return "xmlns:xacro" in content or "xacro:" in content


def _expand_xacro(urdf_path):
    """Expand a xacro URDF to plain-URDF text (offline, no ROS env).

    Uses the standalone ``xacro`` PyPI package: ``xacro.process_file``
    expands macros and properties without a live ROS environment
    (verified in a plain ``python:3.11-slim`` container). Only declared
    property/macro defaults are resolved -- runtime ROS launch args are
    out of scope (#169); a passed ``mappings`` dict is the supported way
    to override defaults, not a full ROS launch context.

    Args:
        urdf_path: Path to the ``.xacro`` (or xacro-tagged) URDF.

    Returns:
        Plain-URDF XML as a string, with all ``xacro:`` macros/properties
        expanded.

    Raises:
        RuntimeError: If the ``xacro`` package is not importable, with an
            actionable message (it is a pure-Python PyPI dep; install it
            in the offline commit environment).
    """
    try:
        import xacro
    except ImportError as exc:
        raise RuntimeError(
            "xacro input detected but the 'xacro' package is not installed. "
            "Install it in the offline commit environment "
            "('pip install xacro'), or expand manually with "
            f"'xacro {urdf_path} > expanded.urdf' before import."
        ) from exc

    doc = xacro.process_file(str(urdf_path))
    return doc.toprettyxml(indent="  ")


def _preprocess_urdf(urdf_path):
    """Expand xacro, sanity-check units, and resolve ``package://`` URIs.

    The deterministic, offline cleanup of a CAD-exported URDF
    (ADR-0020 decision 6), in order:

    1. **xacro (#169)**: if the input is a xacro (``.xacro`` extension or
       ``xmlns:xacro`` / ``xacro:`` tags), expand it to plain URDF first
       -- the Isaac importer cannot read xacro. Expansion is standalone
       (the ``xacro`` PyPI package, no live ROS).
    2. **units (#170)**: a best-effort meters sanity check on the
       expanded URDF (REP-103); a likely-mm / mis-scaled export emits a
       WARNING (does not raise).
    3. **``package://``**: substitute ``package://<name>/<rel>`` mesh URIs
       with resolved file paths (DAE refs kept intact, ADR-0020
       decision 1).

    Isaac Sim's URDF importer resolves package:// via ROS_PACKAGE_PATH,
    which is not set in our container. The URDFs in this repo use names
    like 'open_base' (underscore) but the directory is 'openbase' (no
    underscore), so even ROS_PACKAGE_PATH wouldn't help.

    Strategy: search for the referenced mesh file in <urdf_dir>/<rel>
    first (most common layout), then <urdf_dir>/../<rel>. If found,
    replace the URI with the absolute path. If not, leave unchanged
    (importer will warn).

    Returns a Path to a temporary URDF in /tmp; caller is responsible
    for cleanup (or rely on /tmp being scratch).
    """
    urdf_dir = urdf_path.parent
    content = urdf_path.read_text()

    if _is_xacro(urdf_path, content):
        print(f"  xacro input detected: expanding {urdf_path.name}",
              flush=True)
        content = _expand_xacro(urdf_path)

    # Units sanity check (#170) runs on the expanded URDF, before the
    # path substitution (which does not change any magnitudes).
    _check_urdf_units_text(content)

    unresolved = []

    def resolve(match):
        rel = match.group(2)
        candidates = [
            urdf_dir / rel,
            urdf_dir.parent / rel,
        ]
        for c in candidates:
            if c.exists():
                return f'filename="{c.resolve()}"'
        unresolved.append(match.group(0))
        return match.group(0)

    new_content = _PACKAGE_URI_RE.sub(resolve, content)
    if unresolved:
        print(f"  warning: {len(unresolved)} package URI(s) unresolved, "
              f"first: {unresolved[0]}", flush=True)

    fd, tmp_path = tempfile.mkstemp(
        suffix=".urdf", prefix=f"{urdf_path.stem}_resolved_"
    )
    os.close(fd)
    tmp = Path(tmp_path)
    tmp.write_text(new_content)
    print(f"  preprocessed URDF: {tmp}", flush=True)
    return tmp


def _validate_collider_type(collider_type):
    """Validate a ``collider_type`` against the built-in approximations.

    Pure (host-runnable): the plumbing guard that fails fast before any
    Isaac import if a caller passes an unsupported collision approximation.
    Only Isaac Lab's two built-ins are accepted (ADR-0020 decision 2);
    full-resolution triangle-mesh and SDF colliders are out of scope (#167).

    Args:
        collider_type: One of ``"convex_hull"`` / ``"convex_decomposition"``.

    Returns:
        The validated ``collider_type`` unchanged.

    Raises:
        ValueError: If ``collider_type`` is not a built-in approximation.
    """
    if collider_type not in _COLLIDER_TYPES:
        raise ValueError(
            f"unsupported collider_type {collider_type!r}; expected one of "
            f"{_COLLIDER_TYPES} (ADR-0020 decision 2; full-mesh / SDF "
            "colliders are out of scope, #167)"
        )
    return collider_type


def _resolve_joint_drive_gains(stiffness, damping):
    """Normalize import-time joint-drive gains into a ``(stiffness, damping)``.

    Pure (host-runnable): the scalar plumbing that maps a CLI / kwarg
    stiffness+damping pair into the gains a ``JointDriveCfg`` needs, without
    importing Isaac Lab. The actual ``JointDriveCfg`` is built function-local
    in ``_build_joint_drive_cfg`` from this validated pair.

    Both must be supplied together or both omitted: a position drive needs a
    Kp (stiffness) and a Kd (damping). ``None`` for both means "no import-time
    drive" -- the fixed-joint-safe default (ADR-0020 decision 3).

    Args:
        stiffness: Position-control Kp, or ``None`` for no drive.
        damping: Velocity Kd, or ``None`` for no drive.

    Returns:
        ``None`` if both are ``None`` (no drive), else the validated
        ``(stiffness, damping)`` float pair.

    Raises:
        ValueError: If exactly one of the two is supplied, or a supplied
            gain is negative.
    """
    if stiffness is None and damping is None:
        return None
    if stiffness is None or damping is None:
        raise ValueError(
            "joint drive needs BOTH stiffness and damping (got "
            f"stiffness={stiffness!r}, damping={damping!r}); supply both for "
            "a position drive or neither for the fixed-joint-safe default"
        )
    stiffness = float(stiffness)
    damping = float(damping)
    if stiffness < 0.0 or damping < 0.0:
        raise ValueError(
            f"joint drive gains must be non-negative (got stiffness="
            f"{stiffness}, damping={damping})"
        )
    return (stiffness, damping)


def _build_joint_drive_cfg(stiffness, damping):
    """Build an import-time ``JointDriveCfg`` from stiffness/damping scalars.

    Returns ``None`` (the fixed-joint-safe default, ADR-0020 decision 3) when
    both gains are ``None``. Otherwise maps the validated pair to::

        JointDriveCfg(
            gains=PDGainsCfg(stiffness=..., damping=...),
            drive_type="force",
            target_type="position",
        )

    a position drive in force mode -- the survey-confirmed import-time form
    (#168). Deliberately does NOT use ``ImplicitActuatorCfg``: that needs a
    constructed ``Articulation`` + a playing ``SimulationContext`` to reach
    sim, re-introducing the #151 shutdown-hang surface.

    The ``isaaclab`` import is function-local (ADR-0017 section 8); this
    helper is therefore only callable inside a Kit-running context, while the
    pure ``_resolve_joint_drive_gains`` validation stays host-runnable.

    Args:
        stiffness: Position Kp, or ``None`` for no drive.
        damping: Velocity Kd, or ``None`` for no drive.

    Returns:
        A ``JointDriveCfg`` for a position drive, or ``None`` for no drive.
    """
    gains = _resolve_joint_drive_gains(stiffness, damping)
    if gains is None:
        return None
    # JointDriveCfg / PDGainsCfg are NESTED configclasses on
    # UrdfConverterCfg in Isaac Lab v2.3.2
    # (UrdfConverterCfg.JointDriveCfg.PDGainsCfg), not module-top classes.
    from isaaclab.sim.converters import UrdfConverterCfg

    drive_cfg = UrdfConverterCfg.JointDriveCfg
    return drive_cfg(
        gains=drive_cfg.PDGainsCfg(stiffness=gains[0], damping=gains[1]),
        drive_type="force",
        target_type="position",
    )


def apply_joint_drive(
    prim_path, stiffness, damping, *, drive_type="force"
):
    """Apply a per-joint drive to an already-imported joint prim (runtime).

    The "set Kp/Kd on an existing joint" path the driver / scene adapter
    calls after import. Delegates to Isaac Lab's
    ``isaaclab.sim.schemas.modify_joint_drive_properties`` -- its typed
    wrapper over ``UsdPhysics.DriveAPI`` (ADR-0020 decision 3 / #168 survey).
    That function operates **stage-only**: it applies the ``DriveAPI`` to the
    joint prim (auto-detecting the ``"angular"`` axis for a revolute joint /
    ``"linear"`` for a prismatic one from the prim's USD type) and writes the
    gains -- no ``Articulation``, no PhysX view, no ``SimulationContext``, so
    it does NOT touch the #151 shutdown-hang surface. (Do NOT reach for
    ``ImplicitActuatorCfg`` here: its gains only reach sim through
    ``Articulation.write_joint_*_to_sim``, which needs a playing
    ``SimulationContext``.)

    The ``isaaclab`` import is function-local (ADR-0017 section 8): this
    module still imports cleanly on a host without Isaac Sim.

    NOTE: this CONFIGURES the drive (applies the DriveAPI + sets gains). A
    joint physically reaching / holding a commanded target needs stepped
    physics (a ``SimulationContext``, deferred #151) and is out of scope
    here -- the structural "DriveAPI present with the right gains" check is
    what is verified.

    Args:
        prim_path: USD prim path of the joint to drive. The angular /
            linear DriveAPI axis is auto-detected from the prim's joint
            type by Isaac Lab.
        stiffness: Position-control Kp.
        damping: Velocity Kd.
        drive_type: ``UsdPhysics`` drive mode, ``"force"`` (default) or
            ``"acceleration"`` -- how the joint effort is applied (NOT the
            angular/linear axis, which is auto-detected).

    Returns:
        The truthy result of ``modify_joint_drive_properties`` (``True`` when
        the DriveAPI was applied; ``False`` if the prim is not a
        revolute/prismatic joint).

    Raises:
        ValueError: If a gain is missing/negative (validated host-side
            first).
    """
    gains = _resolve_joint_drive_gains(stiffness, damping)
    if gains is None:
        raise ValueError(
            "apply_joint_drive needs both stiffness and damping"
        )
    from isaaclab.sim.schemas import (
        JointDrivePropertiesCfg,
        modify_joint_drive_properties,
    )

    cfg = JointDrivePropertiesCfg(
        drive_type=drive_type,
        stiffness=gains[0],
        damping=gains[1],
    )
    return modify_joint_drive_properties(prim_path, cfg)


def _convert_urdf(
    urdf_path,
    usd_path,
    *,
    fix_base,
    merge_fixed_joints,
    collider_type=_DEFAULT_COLLIDER_TYPE,
    joint_drive_stiffness=None,
    joint_drive_damping=None,
):
    """Convert a URDF to a single instanceable USD via Isaac Lab.

    Preprocesses the URDF to resolve ``package://`` URIs, then delegates
    the conversion to ``isaaclab.sim.converters.UrdfConverterCfg`` /
    ``UrdfConverter`` (ADR-0018 decision 6) -- the same engine the legacy
    ``omni.kit.commands`` path drove, now via Isaac Lab's config-driven
    interface, producing a single instanceable USD at ``usd_path``.

    The caller is responsible for creating and closing the
    ``SimulationApp`` (Kit) before/after this runs: the converters
    submodule pulls in omni modules that need a running Kit app. All
    Isaac imports stay function-local (ADR-0017 section 8); isaaclab
    transitively pulls in omni, so its imports are local too.

    Args:
        collider_type: Collision approximation passed to
            ``UrdfConverterCfg.collider_type`` (ADR-0020 decision 2, #167).
            ``"convex_hull"`` (default) fills concavities; a concave part
            (e.g. a forklift's forks) needs ``"convex_decomposition"`` so
            the gap is preserved as multiple convex pieces.
        joint_drive_stiffness: Position-control Kp for the import-time
            default drive (#168), or ``None`` for no drive.
        joint_drive_damping: Velocity Kd for the import-time default drive,
            or ``None`` for no drive. Both gains must be supplied together
            or both omitted; both ``None`` keeps the fixed-joint-safe
            ``joint_drive=None`` default (ADR-0020 decision 3).

    Returns:
        Path to the produced USD (``converter.usd_path``, the
        authoritative ``usd_dir / usd_file_name`` location).
    """
    from isaaclab.sim.converters import UrdfConverter, UrdfConverterCfg

    _validate_collider_type(collider_type)
    resolved_urdf = _preprocess_urdf(urdf_path)

    cfg = UrdfConverterCfg(
        asset_path=str(resolved_urdf),
        usd_dir=str(usd_path.parent),
        usd_file_name=usd_path.name,
        fix_base=fix_base,
        merge_fixed_joints=merge_fixed_joints,
        # Collision approximation (ADR-0020 decision 2, #167). The Isaac Lab
        # default "convex_hull" fills concavities; "convex_decomposition"
        # preserves them as multiple convex pieces.
        collider_type=collider_type,
        # Import-time default drive (#168). None leaves drives unconfigured
        # -- the fixed-joint-safe default (a fixed-joint robot fails with an
        # under-specified JointDriveCfg, "Missing values for ...
        # joint_drive.gains.stiffness"). A JointDriveCfg(position/force) is
        # built only when stiffness+damping are supplied.
        joint_drive=_build_joint_drive_cfg(
            joint_drive_stiffness, joint_drive_damping
        ),
        # Always regenerate: the offline commit step wants a fresh,
        # deterministic artifact, not a cache hit.
        force_usd_conversion=True,
    )
    converter = UrdfConverter(cfg)

    # ``converter.usd_path`` is the produced USD file path
    # (AssetConverterBase property = usd_dir / usd_file_name). Trust it
    # over a precomputed path in case Isaac Lab normalizes the name.
    return Path(converter.usd_path)


class PrimSummary(NamedTuple):
    """Structural summary of an imported USD stage (ADR-0017 section 9).

    Returned by ``import_urdf``. The pure-side "expected" counterpart is
    built by ``parse_urdf_expected`` straight from the URDF XML; the L1
    contract assertion (URDF-parse-expected vs PrimSummary-actual
    diff = 0) runs GPU-side at M2.

    Attributes:
        prim_count: Total number of prims summarized from the stage
            (for the pure expected side: root prim + kept links + kept
            joints).
        joint_count: Number of joint prims (USD type name contains
            "Joint").
        link_paths: Absolute prim paths of the robot links (Xform prims
            that are direct children of ``root_prim``).
        root_prim: Absolute path of the robot root prim
            (``/<robot_name>``).
        usd_path: Filesystem path of the produced USD file.
    """

    prim_count: int
    joint_count: int
    link_paths: list
    root_prim: str
    usd_path: str


def parse_urdf_expected(urdf_path, usd_path="", merge_fixed_joints=True):
    """Build the URDF-parse-expected ``PrimSummary`` (pure, host-runnable).

    Parses the URDF XML directly (no Isaac) and derives the structural
    expectation against which the GPU-side ``import_urdf`` actual is
    compared (ADR-0017 section 7, L1 "diff = 0" -- M2 scope).

    NOTE (ADR-0018 decision 6 -- L1 recalibration pending GPU run): the
    actual import is now done by Isaac Lab's ``UrdfConverter`` (see
    ``import_urdf``), which MAY name prims, scope the instanceable
    wrapper, or count synthetic fixed joints (e.g. the ``fix_base``
    ``root_joint``) differently from both this pure prediction and the
    legacy ``omni.kit.commands`` importer. The authoritative L1 diff=0
    assertion is committed-USD-vs-fresh-import (see
    ``test_l1_urdf_to_usd_diff_zero``); this pure helper intentionally
    stays the looser structural prediction. The camera_bot baseline the
    GPU suite asserts (2 links / 2 joints / root ``/camera_bot``) may
    need a ONE-LINE recalibration here or in the GPU test's
    ``EXPECTED_*`` constants once the first Isaac-Lab GPU integration run
    reports actual-vs-expected. Do not pre-emptively change the pure unit
    expectations without that GPU evidence.

    Conventions mirrored from the Isaac URDF importer:

    * the robot root prim is ``/<robot_name>``;
    * each kept link becomes an Xform prim directly under the root;
    * with ``merge_fixed_joints`` (importer default), every link that is
      the child of a fixed joint merges into its parent rigid body, and
      fixed joints emit no joint prim;
    * ``prim_count`` is the structural expectation: 1 (root) + kept
      links + kept joints.

    Args:
        urdf_path: Path to the URDF file.
        usd_path: Value to record in ``PrimSummary.usd_path`` (the
            comparison target's output path; empty by default).
        merge_fixed_joints: Mirror of the importer's
            ``merge_fixed_joints`` flag.

    Returns:
        The expected ``PrimSummary``.

    Raises:
        FileNotFoundError: If ``urdf_path`` does not exist.
        ValueError: If the XML root is not ``<robot>``, a joint lacks
            parent/child links, or the link graph has no unique root.
    """
    urdf = Path(urdf_path)
    if not urdf.exists():
        raise FileNotFoundError(f"URDF not found: {urdf}")

    root = ElementTree.parse(str(urdf)).getroot()
    if root.tag != "robot":
        raise ValueError(f"not a URDF (root element <{root.tag}>): {urdf}")
    robot_name = root.get("name", "")

    link_names = [link.get("name") for link in root.findall("link")]
    joints = []
    for joint in root.findall("joint"):
        parent = joint.find("parent")
        child = joint.find("child")
        if parent is None or child is None:
            raise ValueError(
                f"joint {joint.get('name')!r} missing <parent>/<child>: {urdf}"
            )
        joints.append(
            (joint.get("type"), parent.get("link"), child.get("link"))
        )

    child_links = {child for _, _, child in joints}
    root_links = [name for name in link_names if name not in child_links]
    if len(root_links) != 1:
        raise ValueError(
            f"URDF link graph has {len(root_links)} roots (expected 1): {urdf}"
        )

    kept_links = list(link_names)
    kept_joints = list(joints)
    if merge_fixed_joints:
        merged = {child for jtype, _, child in joints if jtype == "fixed"}
        kept_links = [name for name in link_names if name not in merged]
        kept_joints = [j for j in joints if j[0] != "fixed"]

    root_prim = f"/{robot_name}"
    return PrimSummary(
        prim_count=1 + len(kept_links) + len(kept_joints),
        joint_count=len(kept_joints),
        link_paths=[f"{root_prim}/{name}" for name in kept_links],
        root_prim=root_prim,
        usd_path=str(usd_path),
    )


def _summarize_prim_records(prim_records, usd_path):
    """Fold ``(prim_path, type_name)`` records into a ``PrimSummary`` (pure).

    Classification rules:

    * ``root_prim`` = the first record at the minimum path depth (a
      URDF import produces exactly one robot root);
    * joints = records whose USD type name contains ``"Joint"`` (e.g.
      ``PhysicsRevoluteJoint``);
    * ``link_paths`` = Xform-typed records that are direct children of
      ``root_prim``;
    * ``prim_count`` = total number of records.

    Args:
        prim_records: Iterable of ``(prim_path, type_name)`` pairs, in
            stage traversal order. GPU-side, ``import_urdf`` collects
            them from ``Usd.Stage.Traverse()``; hosted tests inject
            synthetic records.
        usd_path: Filesystem path recorded in ``PrimSummary.usd_path``.

    Returns:
        The actual ``PrimSummary``.

    Raises:
        ValueError: If ``prim_records`` is empty.
    """
    records = [(str(path), str(type_name)) for path, type_name in prim_records]
    if not records:
        raise ValueError("empty prim record list; stage has no prims")

    min_depth = min(path.count("/") for path, _ in records)
    root_prim = next(
        path for path, _ in records if path.count("/") == min_depth
    )
    child_depth = root_prim.count("/") + 1
    link_paths = [
        path
        for path, type_name in records
        if type_name == "Xform"
        and path.startswith(f"{root_prim}/")
        and path.count("/") == child_depth
    ]
    joint_count = sum(1 for _, type_name in records if "Joint" in type_name)

    return PrimSummary(
        prim_count=len(records),
        joint_count=joint_count,
        link_paths=link_paths,
        root_prim=root_prim,
        usd_path=str(usd_path),
    )


def import_urdf(
    urdf_path,
    out_usd_path,
    *,
    collider_type=_DEFAULT_COLLIDER_TYPE,
    joint_drive_stiffness=None,
    joint_drive_damping=None,
):
    """Import a URDF into a single instanceable USD; return its ``PrimSummary``.

    ADR-0017 section 9 contract (greenfield -- not ported behavior),
    re-based onto Isaac Lab per ADR-0018 decision 6: the URDF -> USD
    conversion is delegated to ``isaaclab.sim.converters.UrdfConverterCfg``
    / ``UrdfConverter`` (which wraps the same
    ``isaacsim.asset.importer.urdf`` engine the legacy ``omni.kit.commands``
    path used), instead of the hand-rolled ``URDFParseFile`` /
    ``URDFImportRobot`` command pair, and producing a single instanceable
    USD (Isaac Lab default) at ``out_usd_path``.

    The importer defaults mirror the legacy CLI path
    (``merge_fixed_joints=True``, ``fix_base=True``) and ``package://``
    URIs are preprocessed via ``_preprocess_urdf``.
    ``force_usd_conversion=True`` makes ``import_urdf`` always regenerate
    (the commit step wants a deterministic fresh artifact).

    Must run inside the Isaac Sim / Isaac Lab container; the URDF-existence
    precondition is checked before any Isaac import so hosted callers fail
    fast with a normal Python error.

    Args:
        urdf_path: Path to the URDF file.
        out_usd_path: Output USD file path (parent dirs are created). The
            converter writes to this file's directory and name; the
            traversal uses ``converter.usd_path``.
        collider_type: Collision approximation (ADR-0020 decision 2, #167):
            ``"convex_hull"`` (default, fills concavities) or
            ``"convex_decomposition"`` (preserves them). Validated before
            any Isaac import.
        joint_drive_stiffness: Import-time default-drive Kp (#168), or
            ``None`` for no drive.
        joint_drive_damping: Import-time default-drive Kd, or ``None`` for
            no drive. Both gains are supplied together or both omitted; both
            ``None`` keeps the fixed-joint-safe default.

    Returns:
        ``PrimSummary`` describing the produced stage.

    Raises:
        FileNotFoundError: If ``urdf_path`` does not exist (raised
            before Isaac Sim is touched).
        ValueError: If ``collider_type`` is unsupported, the joint-drive
            gains are inconsistent, or the converter produces no output
            file (all validated before / around the Isaac import).
    """
    urdf = Path(urdf_path).resolve()
    if not urdf.exists():
        raise FileNotFoundError(f"URDF not found: {urdf}")
    # Validate the plumbing inputs BEFORE booting Kit so a hosted caller
    # fails fast with a normal Python error (no Isaac import touched).
    _validate_collider_type(collider_type)
    _resolve_joint_drive_gains(joint_drive_stiffness, joint_drive_damping)
    out_usd = Path(out_usd_path).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    # SimulationApp (Kit) must be created BEFORE importing isaaclab.sim:
    # the converters submodule pulls in omni modules that need a running
    # Kit app (same ordering the Isaac Lab AppLauncher runners rely on).
    # All Isaac imports are function-local (ADR-0017 section 8): isaaclab
    # transitively pulls in omni, so its imports must be local too. The
    # experience pins the 2.4.31 URDF importer (see _simulation_app_kwargs
    # / #177); without it the default experience pre-loads 2.4.30 and the
    # converter raises AttributeError: set_merge_fixed_ignore_inertia.
    from isaacsim import SimulationApp

    app = SimulationApp(_simulation_app_kwargs())
    try:
        from pxr import Usd

        produced = _convert_urdf(
            urdf,
            out_usd,
            fix_base=True,
            merge_fixed_joints=True,
            collider_type=collider_type,
            joint_drive_stiffness=joint_drive_stiffness,
            joint_drive_damping=joint_drive_damping,
        )
        if not produced.exists():
            raise ValueError(
                f"UrdfConverter did not produce {produced} "
                f"(requested {out_usd})"
            )

        stage = Usd.Stage.Open(str(produced))
        prim_records = [
            (str(prim.GetPath()), str(prim.GetTypeName()))
            for prim in stage.Traverse()
        ]
        produced_path = str(produced)
    finally:
        app.close()

    return _summarize_prim_records(prim_records, produced_path)


def main():
    args = _parse_args()
    paths = _resolve_paths(args)

    print(f"import_model: {paths['urdf']} -> {paths['usd']}")
    print(f"  name: {args.name}")
    print(f"  force: {args.force}")
    print(f"  collider_type: {args.collider_type}")
    if args.joint_drive_stiffness is not None or \
            args.joint_drive_damping is not None:
        print(
            f"  joint_drive: stiffness={args.joint_drive_stiffness} "
            f"damping={args.joint_drive_damping}"
        )

    # Fail fast on inconsistent joint-drive gains before booting Kit.
    _resolve_joint_drive_gains(
        args.joint_drive_stiffness, args.joint_drive_damping
    )

    _check_existing(paths, args.force)
    _ensure_dirs(paths)

    # SimulationApp (Kit) must be created BEFORE importing isaaclab.sim.
    # The experience pins the 2.4.31 URDF importer (see
    # _simulation_app_kwargs / #177).
    from isaacsim import SimulationApp

    app = SimulationApp(_simulation_app_kwargs())
    produced = None
    try:
        produced = _convert_urdf(
            paths["urdf"],
            paths["usd"],
            fix_base=not args.no_fix_base,
            merge_fixed_joints=not args.no_merge_fixed,
            collider_type=args.collider_type,
            joint_drive_stiffness=args.joint_drive_stiffness,
            joint_drive_damping=args.joint_drive_damping,
        )
    except Exception as exc:  # noqa: BLE001
        # The converter can raise on mesh-resolution warnings while still
        # producing a valid USD; trust file existence as the authoritative
        # signal (same policy the legacy URDFImportRobot path used).
        print(
            f"  warning: UrdfConverter raised, trusting file existence: {exc}",
            file=sys.stderr,
            flush=True,
        )
        produced = paths["usd"]
    finally:
        app.close()

    ok = produced is not None and Path(produced).exists()
    if ok:
        size = Path(produced).stat().st_size
        print("done: single instanceable USD produced", flush=True)
        print(f"  usd: {produced} ({size} bytes)", flush=True)
    else:
        print(
            f"error: URDF import did not produce {paths['usd']}",
            file=sys.stderr,
            flush=True,
        )

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
