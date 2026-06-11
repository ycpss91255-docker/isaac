#!/usr/bin/env python3
"""Import a URDF into Isaac Sim and produce Asset Structure 3.0 output.

Run inside the Isaac Sim 5.1 container:

    PYTHONPATH=/home/yunchien/work/framework /isaac-sim/python.sh \\
        -m isaac_devkit.model_import \\
        --urdf /home/yunchien/work/src/model/urdf/robot/openbase/openbase_minimal.urdf \\
        --output /home/yunchien/work/src/model/usd/robot/openbase/ \\
        --name openbase

Output (Asset Structure 3.0 layout):

    <output>/
    ├── <name>.usd                 # root composition (sublayers geometry + material)
    ├── <name>_geometry.usda       # URDF import output
    ├── <name>_material.usda       # material placeholder (empty 'over' template)
    └── textures/                  # texture directory (empty)

Re-import (--force) overwrites only <name>_geometry.usda; the material
layer and textures/ are preserved.

Besides the CLI, this module exposes the ADR-0017 section 9 contract:

    import_urdf(urdf_path, out_usd_path) -> PrimSummary

Import-safety invariant (ADR-0017 section 8 / PRD A1): pure functions
live at module top; every ``omni`` / ``pxr`` / ``isaacsim`` import is
function-local so this module imports cleanly on hosts without Isaac
Sim.
"""

import argparse
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
from pathlib import Path
from typing import NamedTuple


def _parse_args():
    parser = argparse.ArgumentParser(
        description="Import URDF to USD with Asset Structure 3.0 layout.",
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
        help="Output directory for Asset Structure 3.0 files.",
    )
    parser.add_argument(
        "--name",
        required=True,
        help="Model name (used for file naming: <name>.usd, <name>_geometry.usda, etc.).",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Overwrite existing geometry file. Material layer is always preserved.",
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
    return parser.parse_args()


def _resolve_paths(args):
    """Resolve and validate paths, return a dict of output file paths."""
    urdf_path = Path(args.urdf).resolve()
    if not urdf_path.exists():
        print(f"error: URDF not found: {urdf_path}", file=sys.stderr)
        sys.exit(1)

    out_dir = Path(args.output).resolve()
    name = args.name

    paths = {
        "urdf": urdf_path,
        "out_dir": out_dir,
        "root": out_dir / f"{name}.usd",
        "geometry": out_dir / f"{name}_geometry.usda",
        "material": out_dir / f"{name}_material.usda",
        "textures": out_dir / "textures",
    }
    return paths


def _check_existing(paths, force):
    """Check for existing files and handle --force logic."""
    if paths["geometry"].exists() and not force:
        print(
            f"error: {paths['geometry']} already exists. Use --force to overwrite.",
            file=sys.stderr,
        )
        sys.exit(1)

    if paths["root"].exists() and not force:
        print(
            f"error: {paths['root']} already exists. Use --force to overwrite.",
            file=sys.stderr,
        )
        sys.exit(1)


def _ensure_dirs(paths):
    """Create output directory structure."""
    paths["out_dir"].mkdir(parents=True, exist_ok=True)
    paths["textures"].mkdir(exist_ok=True)


def _write_material_template(paths):
    """Write empty material sublayer if it doesn't exist (never overwrite)."""
    mat_path = paths["material"]
    if mat_path.exists():
        print(f"  material layer exists, preserved: {mat_path}")
        return

    geometry_filename = paths["geometry"].name
    content = (
        '#usda 1.0\n'
        '(\n'
        f'    subLayers = [@./{geometry_filename}@]\n'
        ')\n'
        '\n'
        '# Material overrides go here.\n'
        '# Use USD Variant Sets for color switching.\n'
        '# See ADR-0010 L2 Asset Structure for details.\n'
    )
    mat_path.write_text(content)
    print(f"  material template created: {mat_path}")


def _write_root_composition(paths):
    """Write root .usd that sublayers material (which sublayers geometry)."""
    root_path = paths["root"]
    material_filename = paths["material"].name
    content = (
        '#usda 1.0\n'
        '(\n'
        f'    subLayers = [@./{material_filename}@]\n'
        ')\n'
        '\n'
        '# Root composition file.\n'
        '# Sublayer chain: root -> material -> geometry\n'
        '# Scene YAML points to this file.\n'
    )
    root_path.write_text(content)
    print(f"  root composition created: {root_path}")


_PACKAGE_URI_RE = re.compile(r'filename="package://([^/]+)/([^"]+)"')


def _preprocess_urdf(urdf_path):
    """Substitute package://<name>/<rel> URIs with absolute file paths.

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


def _import_urdf(urdf_path, geometry_path, args):
    """Run URDF import via Isaac Sim API. Must run inside container.

    Preprocesses the URDF to resolve package:// URIs before passing to
    the importer.
    """
    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})

    import omni.kit.commands
    from isaacsim.asset.importer.urdf import _urdf as urdf_loader

    resolved_urdf = _preprocess_urdf(urdf_path)

    config = urdf_loader.ImportConfig()
    config.merge_fixed_joints = not args.no_merge_fixed
    config.fix_base = not args.no_fix_base
    config.import_inertia_tensor = True
    config.distance_scale = 1.0
    config.density = 0.0
    config.default_drive_strength = 1e7
    config.default_position_drive_damping = 1e5

    status, robot = omni.kit.commands.execute(
        "URDFParseFile",
        urdf_path=str(resolved_urdf),
        import_config=config,
    )
    if not status:
        print(f"error: URDF parse failed: {resolved_urdf}", file=sys.stderr, flush=True)
        return False, app

    status, stage_path = omni.kit.commands.execute(
        "URDFImportRobot",
        urdf_path=str(resolved_urdf),
        urdf_robot=robot,
        dest_path=str(geometry_path),
        import_config=config,
    )

    # URDFImportRobot can return status=False on mesh resolution warnings
    # while still producing a valid USD. Trust file existence as the
    # authoritative signal. Do all post-import file work BEFORE
    # app.close() because Kit shutdown can be abrupt on certain Isaac
    # Sim builds (no traceback, just exits).
    return geometry_path.exists(), app


def _validate_output(paths):
    """Validate that all expected files exist."""
    ok = True
    for key in ("root", "geometry", "material"):
        if not paths[key].exists():
            print(f"error: expected file missing: {paths[key]}", file=sys.stderr)
            ok = False
    if not paths["textures"].is_dir():
        print(f"error: textures dir missing: {paths['textures']}", file=sys.stderr)
        ok = False
    return ok


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


def import_urdf(urdf_path, out_usd_path):
    """Import a URDF into a USD file and return its ``PrimSummary``.

    ADR-0017 section 9 contract (greenfield -- not ported behavior).
    Uses the importer defaults of the legacy CLI path
    (``merge_fixed_joints=True``, ``fix_base=True``) and preprocesses
    ``package://`` URIs via ``_preprocess_urdf``. Must run inside the
    Isaac Sim container; the URDF-existence precondition is checked
    before any Isaac import so hosted callers fail fast with a normal
    Python error.

    Args:
        urdf_path: Path to the URDF file.
        out_usd_path: Output USD file path (parent dirs are created).

    Returns:
        ``PrimSummary`` describing the produced stage.

    Raises:
        FileNotFoundError: If ``urdf_path`` does not exist (raised
            before Isaac Sim is touched).
        ValueError: If URDF parsing fails or the import produces no
            output file.
    """
    urdf = Path(urdf_path).resolve()
    if not urdf.exists():
        raise FileNotFoundError(f"URDF not found: {urdf}")
    out_usd = Path(out_usd_path).resolve()
    out_usd.parent.mkdir(parents=True, exist_ok=True)

    from isaacsim import SimulationApp

    app = SimulationApp({"headless": True})
    try:
        import omni.kit.commands
        from isaacsim.asset.importer.urdf import _urdf as urdf_loader
        from pxr import Usd

        resolved_urdf = _preprocess_urdf(urdf)

        config = urdf_loader.ImportConfig()
        config.merge_fixed_joints = True
        config.fix_base = True
        config.import_inertia_tensor = True
        config.distance_scale = 1.0
        config.density = 0.0
        config.default_drive_strength = 1e7
        config.default_position_drive_damping = 1e5

        status, robot = omni.kit.commands.execute(
            "URDFParseFile",
            urdf_path=str(resolved_urdf),
            import_config=config,
        )
        if not status:
            raise ValueError(f"URDF parse failed: {resolved_urdf}")

        omni.kit.commands.execute(
            "URDFImportRobot",
            urdf_path=str(resolved_urdf),
            urdf_robot=robot,
            dest_path=str(out_usd),
            import_config=config,
        )
        # URDFImportRobot can return status=False on mesh resolution
        # warnings while still producing a valid USD; file existence is
        # the authoritative signal (same policy as _import_urdf).
        if not out_usd.exists():
            raise ValueError(f"URDF import did not produce {out_usd}")

        stage = Usd.Stage.Open(str(out_usd))
        prim_records = [
            (str(prim.GetPath()), str(prim.GetTypeName()))
            for prim in stage.Traverse()
        ]
    finally:
        app.close()

    return _summarize_prim_records(prim_records, str(out_usd))


def main():
    args = _parse_args()
    paths = _resolve_paths(args)

    print(f"import_model: {paths['urdf']} -> {paths['out_dir']}/")
    print(f"  name: {args.name}")
    print(f"  force: {args.force}")

    _check_existing(paths, args.force)
    _ensure_dirs(paths)

    ok, app = _import_urdf(paths["urdf"], paths["geometry"], args)
    if ok:
        print(f"  geometry imported: {paths['geometry']} ({paths['geometry'].stat().st_size} bytes)", flush=True)
        _write_material_template(paths)
        _write_root_composition(paths)
        validate_ok = _validate_output(paths)
        if validate_ok:
            print("done: Asset Structure 3.0 output complete", flush=True)
            print(f"  root:     {paths['root']}", flush=True)
            print(f"  geometry: {paths['geometry']}", flush=True)
            print(f"  material: {paths['material']}", flush=True)
            print(f"  textures: {paths['textures']}/", flush=True)
    else:
        print(f"error: URDF import did not produce {paths['geometry']}", file=sys.stderr, flush=True)
        validate_ok = False

    app.close()
    return 0 if (ok and validate_ok) else 1


if __name__ == "__main__":
    sys.exit(main())
