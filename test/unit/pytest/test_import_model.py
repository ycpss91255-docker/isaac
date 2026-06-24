"""Unit tests for isaac_devkit.model_import — host-runnable, no Isaac Sim.

ADR-0018 decision 6: model_import produces a SINGLE Isaac Lab
instanceable USD at ``<output>/<name>.usd`` (the old multi-file "Asset
Structure 3.0" geometry/material/textures layout is dropped). These
tests cover the pure CLI plumbing that survives that change: path
resolution, the single-USD existing-file check, output-dir creation, and
the ``package://`` URDF preprocessing. The pure ``PrimSummary`` surface
(``parse_urdf_expected`` / ``_summarize_prim_records``) is covered in
``test_prim_summary.py``; the Isaac-Lab-produced USD structure is
asserted GPU-side in ``test/integration/pytest/test_model_import.py``.
"""

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import model_import as import_model


@pytest.fixture
def tmp_model(tmp_path):
    """Create a minimal URDF and output dir for testing."""
    urdf_dir = tmp_path / "urdf"
    urdf_dir.mkdir()
    urdf_file = urdf_dir / "test_robot.urdf"
    urdf_file.write_text("<robot name='test'/>")

    out_dir = tmp_path / "usd" / "robot" / "test_robot"
    return {"urdf": urdf_file, "out_dir": out_dir, "name": "test_robot"}


class TestResolvePaths:
    def test_returns_single_usd_keys(self, tmp_model):
        args = SimpleNamespace(
            urdf=str(tmp_model["urdf"]),
            output=str(tmp_model["out_dir"]),
            name=tmp_model["name"],
        )
        paths = import_model._resolve_paths(args)
        # ADR-0018: single-USD output, no geometry/material/textures keys.
        assert set(paths.keys()) == {"urdf", "out_dir", "usd"}

    def test_usd_uses_name(self, tmp_model):
        args = SimpleNamespace(
            urdf=str(tmp_model["urdf"]),
            output=str(tmp_model["out_dir"]),
            name="mybot",
        )
        paths = import_model._resolve_paths(args)
        assert paths["usd"].name == "mybot.usd"

    def test_urdf_not_found_exits(self, tmp_path):
        args = SimpleNamespace(
            urdf=str(tmp_path / "nonexistent.urdf"),
            output=str(tmp_path / "out"),
            name="x",
        )
        with pytest.raises(SystemExit):
            import_model._resolve_paths(args)

    def test_paths_are_absolute(self, tmp_model):
        args = SimpleNamespace(
            urdf=str(tmp_model["urdf"]),
            output=str(tmp_model["out_dir"]),
            name="test_robot",
        )
        paths = import_model._resolve_paths(args)
        for key, p in paths.items():
            assert Path(p).is_absolute(), f"{key} is not absolute: {p}"


class TestCheckExisting:
    def test_blocks_when_usd_exists_no_force(self, tmp_model):
        out_dir = tmp_model["out_dir"]
        out_dir.mkdir(parents=True)
        usd = out_dir / "test_robot.usd"
        usd.write_text("existing")

        paths = {"usd": usd}
        with pytest.raises(SystemExit):
            import_model._check_existing(paths, force=False)

    def test_allows_when_usd_exists_with_force(self, tmp_model):
        out_dir = tmp_model["out_dir"]
        out_dir.mkdir(parents=True)
        usd = out_dir / "test_robot.usd"
        usd.write_text("existing")

        paths = {"usd": usd}
        import_model._check_existing(paths, force=True)

    def test_allows_when_no_existing_usd(self, tmp_model):
        out_dir = tmp_model["out_dir"]
        paths = {"usd": out_dir / "test_robot.usd"}
        import_model._check_existing(paths, force=False)


class TestEnsureDirs:
    def test_creates_output_dir(self, tmp_model):
        paths = {"out_dir": tmp_model["out_dir"]}
        assert not paths["out_dir"].exists()
        import_model._ensure_dirs(paths)
        assert paths["out_dir"].is_dir()

    def test_idempotent_on_existing_dir(self, tmp_model):
        paths = {"out_dir": tmp_model["out_dir"]}
        paths["out_dir"].mkdir(parents=True)
        # Must not raise on an already-existing output dir.
        import_model._ensure_dirs(paths)
        assert paths["out_dir"].is_dir()


class TestPreprocessUrdf:
    def test_resolves_package_uri_to_absolute(self, tmp_path):
        urdf_dir = tmp_path / "robot" / "openbase"
        urdf_dir.mkdir(parents=True)
        mesh_dir = urdf_dir / "mesh"
        mesh_dir.mkdir()
        (mesh_dir / "base.stl").write_text("fake stl")

        urdf = urdf_dir / "openbase.urdf"
        urdf.write_text(
            '<robot name="x"><mesh filename="package://open_base/mesh/base.stl"/></robot>'
        )

        resolved = import_model._preprocess_urdf(urdf)
        try:
            content = resolved.read_text()
            assert "package://" not in content
            assert str(mesh_dir / "base.stl") in content
        finally:
            resolved.unlink()

    def test_leaves_unresolvable_uri_unchanged(self, tmp_path):
        urdf_dir = tmp_path / "robot" / "openbase"
        urdf_dir.mkdir(parents=True)
        urdf = urdf_dir / "openbase.urdf"
        urdf.write_text(
            '<robot name="x"><mesh filename="package://x/missing.stl"/></robot>'
        )

        resolved = import_model._preprocess_urdf(urdf)
        try:
            content = resolved.read_text()
            assert "package://x/missing.stl" in content
        finally:
            resolved.unlink()

    def test_resolves_parent_dir_fallback(self, tmp_path):
        urdf_dir = tmp_path / "robot" / "openbase"
        urdf_dir.mkdir(parents=True)
        parent_mesh = tmp_path / "robot" / "mesh"
        parent_mesh.mkdir()
        (parent_mesh / "wheel.stl").write_text("fake stl")

        urdf = urdf_dir / "openbase.urdf"
        urdf.write_text(
            '<robot name="x"><mesh filename="package://open_base/mesh/wheel.stl"/></robot>'
        )

        resolved = import_model._preprocess_urdf(urdf)
        try:
            content = resolved.read_text()
            assert str(parent_mesh / "wheel.stl") in content
        finally:
            resolved.unlink()

    def test_writes_to_tmp(self, tmp_path):
        urdf_dir = tmp_path / "robot" / "openbase"
        urdf_dir.mkdir(parents=True)
        urdf = urdf_dir / "openbase.urdf"
        urdf.write_text("<robot/>")

        resolved = import_model._preprocess_urdf(urdf)
        try:
            assert str(resolved).startswith("/tmp/")
            assert resolved.suffix == ".urdf"
        finally:
            resolved.unlink()


class TestImportUrdfPrecondition:
    def test_missing_urdf_raises_before_isaac(self, tmp_path):
        # The URDF-existence precondition is checked before any Isaac
        # import, so this fails fast with a normal Python error on a host
        # with no Isaac Sim installed.
        with pytest.raises(FileNotFoundError):
            import_model.import_urdf(
                tmp_path / "nope.urdf", tmp_path / "out.usd"
            )


class TestColliderType:
    """#167 (ADR-0020 d2): collider_type is exposed and validated.

    Pure plumbing: the value is validated before any Isaac import; only the
    two built-in approximations are accepted (full-mesh / SDF are out of
    scope). The cfg-build path (UrdfConverterCfg.collider_type=...) is GPU
    territory; here we only assert the host-runnable guard.
    """

    def test_default_is_convex_hull(self):
        # The default must keep current behavior (no concavity preserved).
        assert import_model._DEFAULT_COLLIDER_TYPE == "convex_hull"

    def test_built_in_types(self):
        assert import_model._COLLIDER_TYPES == (
            "convex_hull", "convex_decomposition"
        )

    @pytest.mark.parametrize(
        "value", ["convex_hull", "convex_decomposition"]
    )
    def test_validate_accepts_built_ins(self, value):
        assert import_model._validate_collider_type(value) == value

    @pytest.mark.parametrize(
        "value", ["triangle_mesh", "sdf", "", "Convex_Hull", None]
    )
    def test_validate_rejects_unsupported(self, value):
        with pytest.raises(ValueError, match="collider_type"):
            import_model._validate_collider_type(value)

    def test_import_urdf_rejects_bad_collider_before_isaac(self, tmp_path):
        # An unsupported collider_type fails fast (no Isaac import) on a
        # host without Isaac Sim -- a ValueError, not a missing-module error.
        urdf = tmp_path / "r.urdf"
        urdf.write_text("<robot name='r'/>")
        with pytest.raises(ValueError, match="collider_type"):
            import_model.import_urdf(
                urdf, tmp_path / "out.usd", collider_type="triangle_mesh"
            )


class TestJointDriveGains:
    """#168 (ADR-0020 d3): import-time joint-drive gain plumbing.

    Pure plumbing: the stiffness/damping pair is normalized / validated
    host-side; the JointDriveCfg(position/force) build and the runtime
    modify_joint_drive_properties application are GPU territory.
    """

    def test_both_none_is_no_drive(self):
        # Both None -> the fixed-joint-safe default (joint_drive stays None).
        assert import_model._resolve_joint_drive_gains(None, None) is None

    def test_both_supplied_returns_float_pair(self):
        assert import_model._resolve_joint_drive_gains(800, 40) == (
            800.0, 40.0
        )

    @pytest.mark.parametrize(
        "stiffness,damping",
        [(800.0, None), (None, 40.0)],
    )
    def test_one_sided_gains_raise(self, stiffness, damping):
        with pytest.raises(ValueError, match="BOTH stiffness and damping"):
            import_model._resolve_joint_drive_gains(stiffness, damping)

    @pytest.mark.parametrize(
        "stiffness,damping",
        [(-1.0, 10.0), (10.0, -1.0)],
    )
    def test_negative_gains_raise(self, stiffness, damping):
        with pytest.raises(ValueError, match="non-negative"):
            import_model._resolve_joint_drive_gains(stiffness, damping)

    def test_import_urdf_rejects_one_sided_drive_before_isaac(self, tmp_path):
        # A one-sided drive fails fast (no Isaac import) on a host without
        # Isaac Sim -- the gain validation runs before SimulationApp.
        urdf = tmp_path / "r.urdf"
        urdf.write_text("<robot name='r'/>")
        with pytest.raises(ValueError, match="BOTH stiffness and damping"):
            import_model.import_urdf(
                urdf, tmp_path / "out.usd", joint_drive_stiffness=800.0
            )


class TestCliPlumbing:
    """#167/#168: the CLI flows collider_type + joint drive into the cfg.

    Parse the CLI without spawning Kit; assert the namespace carries the
    values _convert_urdf consumes (the flag -> kwarg flow), and the
    defaults keep current behavior.
    """

    def _parse(self, monkeypatch, extra):
        argv = [
            "model_import",
            "--urdf", "/x/r.urdf",
            "--output", "/x/out",
            "--name", "r",
        ] + extra
        monkeypatch.setattr(sys, "argv", argv)
        return import_model._parse_args()

    def test_collider_default_is_convex_hull(self, monkeypatch):
        args = self._parse(monkeypatch, [])
        assert args.collider_type == "convex_hull"

    def test_collider_flag_sets_decomposition(self, monkeypatch):
        args = self._parse(
            monkeypatch, ["--collider-type", "convex_decomposition"]
        )
        assert args.collider_type == "convex_decomposition"

    def test_collider_flag_rejects_unsupported(self, monkeypatch):
        # argparse choices reject an out-of-scope collider at the CLI.
        with pytest.raises(SystemExit):
            self._parse(monkeypatch, ["--collider-type", "triangle_mesh"])

    def test_joint_drive_defaults_none(self, monkeypatch):
        args = self._parse(monkeypatch, [])
        assert args.joint_drive_stiffness is None
        assert args.joint_drive_damping is None

    def test_joint_drive_flags_parse_as_floats(self, monkeypatch):
        args = self._parse(
            monkeypatch,
            ["--joint-drive-stiffness", "800", "--joint-drive-damping", "40"],
        )
        assert args.joint_drive_stiffness == 800.0
        assert args.joint_drive_damping == 40.0


_XACRO_FIXTURE = (
    '<?xml version="1.0"?>\n'
    '<robot name="bot" xmlns:xacro="http://www.ros.org/wiki/xacro">\n'
    '  <xacro:property name="w" value="0.5"/>\n'
    '  <xacro:macro name="box_link" params="lname size">\n'
    '    <link name="${lname}">\n'
    '      <visual><geometry><box size="${size}"/></geometry></visual>\n'
    '    </link>\n'
    '  </xacro:macro>\n'
    '  <xacro:box_link lname="base_link" size="${w} ${w} 0.1"/>\n'
    '</robot>\n'
)

xacro = pytest.importorskip("xacro")


class TestXacroDetection:
    """#169: xacro inputs are detected by extension or namespace/tags."""

    def test_detects_dot_xacro_extension(self, tmp_path):
        p = tmp_path / "robot.xacro"
        assert import_model._is_xacro(p, "<robot/>") is True

    def test_detects_urdf_xacro_suffix(self, tmp_path):
        p = tmp_path / "robot.urdf.xacro"
        assert import_model._is_xacro(p, "<robot/>") is True

    def test_detects_xacro_namespace(self, tmp_path):
        p = tmp_path / "robot.urdf"
        assert import_model._is_xacro(p, _XACRO_FIXTURE) is True

    def test_plain_urdf_not_xacro(self, tmp_path):
        p = tmp_path / "robot.urdf"
        assert import_model._is_xacro(p, "<robot name='x'/>") is False


class TestXacroExpansion:
    """#169: a xacro URDF expands to plain, well-formed URDF."""

    def test_expand_resolves_macros_and_properties(self, tmp_path):
        src = tmp_path / "robot.urdf.xacro"
        src.write_text(_XACRO_FIXTURE)
        out = import_model._expand_xacro(src)
        assert "xacro:" not in out
        assert "${" not in out
        assert 'name="base_link"' in out
        assert 'size="0.5 0.5 0.1"' in out

    def test_expand_output_is_well_formed_xml(self, tmp_path):
        import xml.etree.ElementTree as ET

        src = tmp_path / "robot.urdf.xacro"
        src.write_text(_XACRO_FIXTURE)
        out = import_model._expand_xacro(src)
        root = ET.fromstring(out)
        assert root.tag == "robot"

    def test_preprocess_expands_xacro_input(self, tmp_path):
        src = tmp_path / "robot.urdf.xacro"
        src.write_text(_XACRO_FIXTURE)
        resolved = import_model._preprocess_urdf(src)
        try:
            content = resolved.read_text()
            assert "xacro:" not in content
            assert "${" not in content
            assert 'name="base_link"' in content
        finally:
            resolved.unlink()

    def test_missing_xacro_package_raises_actionable_error(
        self, tmp_path, monkeypatch
    ):
        # If the standalone xacro package is unavailable, expansion raises
        # a clear, actionable RuntimeError (the offline-commit fallback the
        # ADR's raise-path describes) rather than a bare ImportError.
        import builtins

        real_import = builtins.__import__

        def fake_import(name, *args, **kwargs):
            if name == "xacro":
                raise ImportError("no xacro")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", fake_import)
        src = tmp_path / "robot.urdf.xacro"
        src.write_text(_XACRO_FIXTURE)
        with pytest.raises(RuntimeError, match="pip install xacro"):
            import_model._expand_xacro(src)

    def test_preprocess_leaves_plain_urdf_unexpanded(self, tmp_path):
        # A plain URDF (no xacro markers) passes through unchanged by the
        # xacro stage (still package://-resolved).
        urdf_dir = tmp_path / "robot"
        urdf_dir.mkdir()
        src = urdf_dir / "robot.urdf"
        src.write_text("<robot name='plain'/>")
        resolved = import_model._preprocess_urdf(src)
        try:
            assert resolved.read_text() == "<robot name='plain'/>"
        finally:
            resolved.unlink()


class TestUnitSanityCheck:
    """#170: best-effort meters heuristic (REP-103), warns not raises."""

    _METERS = (
        '<robot name="m">'
        '<link name="l"><visual><geometry>'
        '<box size="0.2 0.3 0.1"/></geometry></visual></link>'
        '<joint name="j" type="fixed">'
        '<origin xyz="0.0 0.5 1.2"/>'
        '<parent link="l"/><child link="l2"/></joint>'
        '<link name="l2"/></robot>'
    )
    _MILLIMETERS = (
        '<robot name="mm">'
        '<link name="l"><visual><geometry>'
        '<box size="200 300 100"/></geometry></visual></link>'
        '<joint name="j" type="fixed">'
        '<origin xyz="0 500 1200"/>'
        '<parent link="l"/><child link="l2"/></joint>'
        '<link name="l2"/></robot>'
    )

    def test_meters_urdf_no_warning(self, capsys):
        flagged = import_model._check_urdf_units_text(self._METERS)
        assert flagged is False
        assert "unit sanity check" not in capsys.readouterr().err

    def test_millimeter_urdf_warns(self, capsys):
        flagged = import_model._check_urdf_units_text(self._MILLIMETERS)
        assert flagged is True
        err = capsys.readouterr().err
        assert "unit sanity check" in err
        assert "meters" in err

    def test_large_mesh_scale_warns(self, capsys):
        urdf = (
            '<robot name="s"><link name="l"><visual><geometry>'
            '<mesh filename="x.dae" scale="1000 1000 1000"/>'
            '</geometry></visual></link></robot>'
        )
        assert import_model._check_urdf_units_text(urdf) is True
        assert "unit sanity check" in capsys.readouterr().err

    def test_malformed_xml_does_not_warn(self, capsys):
        # Malformed XML is the importer's problem; the unit check stays
        # silent rather than masking it.
        assert import_model._check_urdf_units_text("<robot>") is False
        assert "unit sanity check" not in capsys.readouterr().err

    def test_check_urdf_units_path_wrapper(self, tmp_path, capsys):
        p = tmp_path / "mm.urdf"
        p.write_text(self._MILLIMETERS)
        assert import_model._check_urdf_units(p) is True
        assert "unit sanity check" in capsys.readouterr().err


class TestSimulationAppKwargs:
    """The SimulationApp boot config that pins the 2.4.31 URDF importer.

    Pure (env + filesystem only, no Isaac import): boots Kit with Isaac
    Lab's experience so the 2.4.31 importer loads instead of the default
    experience's bundled 2.4.30 (#177, ADR-0020 decision 4).
    """

    def test_always_headless(self, monkeypatch):
        # Point at a non-existent path so the experience key is omitted;
        # headless must still be set.
        monkeypatch.setenv(
            "ISAACLAB_KIT_EXPERIENCE", "/no/such/isaaclab.python.kit"
        )
        kwargs = import_model._simulation_app_kwargs()
        assert kwargs["headless"] is True

    def test_missing_experience_omits_key(self, monkeypatch):
        # A hosted/dev box with no Isaac Lab clone must NOT pass a missing
        # experience file (SimulationApp would fail); fall back to default.
        monkeypatch.setenv(
            "ISAACLAB_KIT_EXPERIENCE", "/no/such/isaaclab.python.kit"
        )
        assert "experience" not in import_model._simulation_app_kwargs()

    def test_existing_experience_is_pinned(self, monkeypatch, tmp_path):
        kit = tmp_path / "isaaclab.python.kit"
        kit.write_text("[package]\n")
        monkeypatch.setenv("ISAACLAB_KIT_EXPERIENCE", str(kit))
        kwargs = import_model._simulation_app_kwargs()
        assert kwargs["experience"] == str(kit)
        assert kwargs["headless"] is True

    def test_env_overrides_default_path(self, monkeypatch, tmp_path):
        # The env var takes precedence over the baked default constant.
        kit = tmp_path / "custom.kit"
        kit.write_text("[package]\n")
        monkeypatch.setenv("ISAACLAB_KIT_EXPERIENCE", str(kit))
        assert import_model._simulation_app_kwargs()["experience"] == str(kit)

    def test_default_path_is_isaaclab_kit(self):
        # The baked default is Isaac Lab's python experience (which pins
        # the 2.4.31 importer); the constant must not drift.
        assert import_model._ISAACLAB_KIT_EXPERIENCE == (
            "/opt/IsaacLab/apps/isaaclab.python.kit"
        )
