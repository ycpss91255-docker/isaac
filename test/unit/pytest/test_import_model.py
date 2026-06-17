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
