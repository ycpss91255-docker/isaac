"""Unit tests for the greenfield PrimSummary surface of
isaac_devkit.model_import -- host-runnable, no Isaac Sim.

ADR-0017 section 9 greenfield contract (not ported behavior): the
``PrimSummary`` NamedTuple, the pure URDF-XML expectation builder
(``parse_urdf_expected``), and the pure stage-record folder
(``_summarize_prim_records``). The GPU-side L1 "diff = 0" assertion
(URDF-parse-expected vs import_urdf-actual) runs at M2; here we test the
two pure halves that feed it.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import model_import


_TWO_LINK_URDF = """\
<robot name="bot">
  <link name="base_link"/>
  <link name="wheel"/>
  <joint name="j1" type="revolute">
    <parent link="base_link"/>
    <child link="wheel"/>
  </joint>
</robot>
"""

_FIXED_JOINT_URDF = """\
<robot name="bot">
  <link name="base_link"/>
  <link name="sensor"/>
  <link name="wheel"/>
  <joint name="mount" type="fixed">
    <parent link="base_link"/>
    <child link="sensor"/>
  </joint>
  <joint name="drive" type="continuous">
    <parent link="base_link"/>
    <child link="wheel"/>
  </joint>
</robot>
"""


def _write(tmp_path, text):
    p = tmp_path / "robot.urdf"
    p.write_text(text)
    return p


class TestPrimSummaryShape:
    def test_named_tuple_fields_match_adr(self):
        assert model_import.PrimSummary._fields == (
            "prim_count",
            "joint_count",
            "link_paths",
            "root_prim",
            "usd_path",
        )


class TestParseUrdfExpected:
    def test_two_link_one_joint(self, tmp_path):
        urdf = _write(tmp_path, _TWO_LINK_URDF)
        summary = model_import.parse_urdf_expected(urdf, usd_path="/out.usd")
        assert summary.root_prim == "/bot"
        assert summary.joint_count == 1
        # root + 2 links + 1 joint.
        assert summary.prim_count == 4
        assert summary.link_paths == ["/bot/base_link", "/bot/wheel"]
        assert summary.usd_path == "/out.usd"

    def test_fixed_joint_merged_by_default(self, tmp_path):
        urdf = _write(tmp_path, _FIXED_JOINT_URDF)
        summary = model_import.parse_urdf_expected(urdf)
        # fixed-jointed 'sensor' link merges into base_link; the fixed
        # joint emits no joint prim. Kept: base_link, wheel + 1 joint.
        assert summary.joint_count == 1
        assert "/bot/sensor" not in summary.link_paths
        assert summary.link_paths == ["/bot/base_link", "/bot/wheel"]
        assert summary.prim_count == 4

    def test_no_merge_keeps_fixed_joint(self, tmp_path):
        urdf = _write(tmp_path, _FIXED_JOINT_URDF)
        summary = model_import.parse_urdf_expected(
            urdf, merge_fixed_joints=False
        )
        assert summary.joint_count == 2
        assert "/bot/sensor" in summary.link_paths

    def test_missing_file_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            model_import.parse_urdf_expected(tmp_path / "nope.urdf")

    def test_not_a_robot_raises(self, tmp_path):
        urdf = _write(tmp_path, "<thing name='x'/>")
        with pytest.raises(ValueError, match="not a URDF"):
            model_import.parse_urdf_expected(urdf)

    def test_multiple_roots_raises(self, tmp_path):
        urdf = _write(
            tmp_path,
            "<robot name='x'><link name='a'/><link name='b'/></robot>",
        )
        with pytest.raises(ValueError, match="roots"):
            model_import.parse_urdf_expected(urdf)

    def test_joint_missing_child_raises(self, tmp_path):
        urdf = _write(
            tmp_path,
            "<robot name='x'><link name='a'/>"
            "<joint name='j' type='fixed'><parent link='a'/></joint></robot>",
        )
        with pytest.raises(ValueError, match="missing"):
            model_import.parse_urdf_expected(urdf)


class TestSummarizePrimRecords:
    def test_folds_records_into_summary(self):
        records = [
            ("/bot", "Xform"),
            ("/bot/base_link", "Xform"),
            ("/bot/wheel", "Xform"),
            ("/bot/base_link/j1", "PhysicsRevoluteJoint"),
        ]
        summary = model_import._summarize_prim_records(records, "/out.usd")
        assert summary.root_prim == "/bot"
        assert summary.prim_count == 4
        assert summary.joint_count == 1
        assert summary.link_paths == ["/bot/base_link", "/bot/wheel"]
        assert summary.usd_path == "/out.usd"

    def test_empty_records_raise(self):
        with pytest.raises(ValueError, match="no prims"):
            model_import._summarize_prim_records([], "/out.usd")

    def test_parse_and_summarize_agree_diff_zero(self, tmp_path):
        """The ADR L1 'diff = 0' invariant on matching pure inputs.

        Build the expected summary from the URDF and a synthetic actual
        record set that mirrors the importer's output; the structural
        fields must agree.
        """
        urdf = _write(tmp_path, _TWO_LINK_URDF)
        expected = model_import.parse_urdf_expected(urdf, usd_path="/out.usd")
        actual = model_import._summarize_prim_records(
            [
                ("/bot", "Xform"),
                ("/bot/base_link", "Xform"),
                ("/bot/wheel", "Xform"),
                ("/bot/base_link/j1", "PhysicsRevoluteJoint"),
            ],
            "/out.usd",
        )
        assert expected.prim_count == actual.prim_count
        assert expected.joint_count == actual.joint_count
        assert sorted(expected.link_paths) == sorted(actual.link_paths)
        assert expected.root_prim == actual.root_prim
