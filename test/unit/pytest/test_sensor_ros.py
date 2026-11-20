"""Unit tests for isaac_devkit.sensor_ros -- host-runnable, no Isaac Sim.

Tests cover the sensor_ros module after the sensors.py three-layer split:
the ``_build_graph_topology`` helper (host-pure graph-spec builder) and
the ``_role_to_helper_type`` mapping that it uses.

The ``setup_sensor_publish`` orchestrator needs a live Kit stage and is
tested in integration tests only.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import sensor_ros

pytestmark = pytest.mark.core


class TestBuildGraphTopology:
    """``build_graph_topology`` builds OmniGraph topology specs for the
    camera publish chain.  It is host-pure (needs only pxr.Sdf which is
    mocked here via monkeypatch)."""

    @pytest.fixture(autouse=True)
    def _patch_sdf(self, monkeypatch):
        """Replace pxr.Sdf.Path with a plain string wrapper so the
        host test can run without Isaac Sim."""
        import types

        pxr_mod = types.ModuleType("pxr")
        sdf_mod = types.ModuleType("pxr.Sdf")

        class FakePath(str):
            pass

        sdf_mod.Path = FakePath
        pxr_mod.Sdf = sdf_mod
        monkeypatch.setitem(sys.modules, "pxr", pxr_mod)
        monkeypatch.setitem(sys.modules, "pxr.Sdf", sdf_mod)

    def test_single_stream_topology(self):
        stream_map = {
            "color": ("/Root/Camera_Color", "rgb", "color_optical_frame"),
        }
        nodes, values, connects = sensor_ros.build_graph_topology(
            stream_map, ["color"], {}, "/camera", "cam",
        )
        # OnTick + 3 per stream (RP, Helper, Info) = 4 nodes
        assert len(nodes) == 4
        node_names = [n[0] for n in nodes]
        assert "OnTick" in node_names
        assert "RP_color" in node_names
        assert "Helper_color" in node_names
        assert "Info_color" in node_names

    def test_multi_stream_topology(self):
        stream_map = {
            "color": ("/Root/Camera_Color", "rgb", "color_optical_frame"),
            "depth": ("/Root/Camera_Depth", "depth", "depth_optical_frame"),
        }
        nodes, values, connects = sensor_ros.build_graph_topology(
            stream_map, ["color", "depth"], {}, "/camera", "cam",
        )
        # OnTick + 3 per stream * 2 = 7 nodes
        assert len(nodes) == 7

    def test_resolution_override(self):
        stream_map = {
            "color": ("/Root/Camera_Color", "rgb", "color_optical_frame"),
        }
        overrides = {"color": {"width": 1280, "height": 720}}
        nodes, values, connects = sensor_ros.build_graph_topology(
            stream_map, ["color"], overrides, "/camera", "cam",
        )
        value_dict = {v[0]: v[1] for v in values}
        assert value_dict.get("RP_color.inputs:width") == 1280
        assert value_dict.get("RP_color.inputs:height") == 720

    def test_topic_names(self):
        stream_map = {
            "color": ("/Root/Camera_Color", "rgb", "color_optical_frame"),
        }
        nodes, values, connects = sensor_ros.build_graph_topology(
            stream_map, ["color"], {}, "/camera", "cam",
        )
        value_dict = {v[0]: v[1] for v in values}
        assert value_dict["Helper_color.inputs:topicName"] == "/camera/color/image_raw"
        assert value_dict["Info_color.inputs:topicName"] == "/camera/color/camera_info"

    def test_frame_id(self):
        stream_map = {
            "color": ("/Root/Camera_Color", "rgb", "color_optical_frame"),
        }
        nodes, values, connects = sensor_ros.build_graph_topology(
            stream_map, ["color"], {}, "/camera", "cam",
        )
        value_dict = {v[0]: v[1] for v in values}
        assert value_dict["Helper_color.inputs:frameId"] == "cam_color_optical_frame"


class TestModuleExists:
    """Verify the module exposes the expected public interface."""

    def test_has_build_graph_topology(self):
        assert callable(sensor_ros.build_graph_topology)

    def test_has_setup_sensor_publish(self):
        assert callable(sensor_ros.setup_sensor_publish)
