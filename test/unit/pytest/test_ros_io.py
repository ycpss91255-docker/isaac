"""Unit tests for isaac_devkit.ros_io -- host-runnable, no Isaac Sim.

ros_io is greenfield (ADR-0017 sections 6, 9): no predecessor in
src/script. These cover the pure surface -- scene-config parsing,
expected attribute-path computation, the graph-topology string builder,
and the ``RosIo.latest`` non-blocking freshness bookkeeping against an
injected fake attribute reader (the Isaac OmniGraph build is M2 scope and
raises NotImplementedError until #131).

ADR-0017 section 7 ros_io contract verified here: ``latest()`` returns a
matching message once a counter advances, returns it exactly once
(re-call yields None), and never blocks when no message is present.
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "framework"))
from isaac_devkit import ros_io


class TestParseRos2IoConfig:
    def test_missing_section_is_empty(self):
        assert ros_io.parse_ros2_io_config({}) == []

    def test_missing_subscriptions_is_empty(self):
        assert ros_io.parse_ros2_io_config({"ros2_io": {}}) == []

    def test_single_twist_subscription_normalized(self):
        scene = {"ros2_io": {"subscriptions": [{"topic": "/cmd_vel", "type": "twist"}]}}
        assert ros_io.parse_ros2_io_config(scene) == [
            {"topic": "/cmd_vel", "msg_type": "twist"}
        ]

    def test_order_preserved(self):
        scene = {
            "ros2_io": {
                "subscriptions": [
                    {"topic": "/cmd_vel", "type": "twist"},
                    {"topic": "/cmd_vel_aux", "type": "twist"},
                ]
            }
        }
        topics = [e["topic"] for e in ros_io.parse_ros2_io_config(scene)]
        assert topics == ["/cmd_vel", "/cmd_vel_aux"]

    def test_section_not_mapping_raises(self):
        with pytest.raises(ValueError, match="must be a mapping"):
            ros_io.parse_ros2_io_config({"ros2_io": []})

    def test_subscriptions_not_list_raises(self):
        with pytest.raises(ValueError, match="must be a list"):
            ros_io.parse_ros2_io_config({"ros2_io": {"subscriptions": {}}})

    def test_entry_not_mapping_raises(self):
        with pytest.raises(ValueError, match="must be a mapping"):
            ros_io.parse_ros2_io_config({"ros2_io": {"subscriptions": ["x"]}})

    def test_unknown_key_raises(self):
        scene = {"ros2_io": {"subscriptions": [{"topic": "/x", "type": "twist", "qos": 1}]}}
        with pytest.raises(ValueError, match="unknown key"):
            ros_io.parse_ros2_io_config(scene)

    def test_bad_topic_raises(self):
        scene = {"ros2_io": {"subscriptions": [{"topic": "cmd_vel", "type": "twist"}]}}
        with pytest.raises(ValueError, match="absolute ROS 2 topic"):
            ros_io.parse_ros2_io_config(scene)

    def test_duplicate_topic_raises(self):
        scene = {
            "ros2_io": {
                "subscriptions": [
                    {"topic": "/cmd_vel", "type": "twist"},
                    {"topic": "/cmd_vel", "type": "twist"},
                ]
            }
        }
        with pytest.raises(ValueError, match="duplicate topic"):
            ros_io.parse_ros2_io_config(scene)

    def test_unsupported_type_raises(self):
        scene = {"ros2_io": {"subscriptions": [{"topic": "/x", "type": "pose"}]}}
        with pytest.raises(ValueError, match="unsupported 'type'"):
            ros_io.parse_ros2_io_config(scene)


class TestExpectedAttrPaths:
    def test_paths_follow_naming_rules(self):
        paths = ros_io.expected_attr_paths("/cmd_vel", "twist")
        assert paths.freshness == (
            f"{ros_io.GRAPH_PATH}/Seq_cmd_vel.{ros_io._FRESHNESS_ATTR}"
        )
        assert paths.fields["linear"] == (
            f"{ros_io.GRAPH_PATH}/Sub_cmd_vel.outputs:linearVelocity"
        )
        assert paths.fields["angular"] == (
            f"{ros_io.GRAPH_PATH}/Sub_cmd_vel.outputs:angularVelocity"
        )

    def test_nested_topic_sanitized(self):
        paths = ros_io.expected_attr_paths("/robot/cmd_vel", "twist")
        assert "Sub_robot_cmd_vel" in paths.fields["linear"]

    def test_custom_graph_path(self):
        paths = ros_io.expected_attr_paths("/cmd_vel", "twist", graph_path="/G")
        assert paths.freshness.startswith("/G/")

    def test_unsupported_type_raises(self):
        with pytest.raises(ValueError, match="unsupported msg_type"):
            ros_io.expected_attr_paths("/cmd_vel", "pose")


class TestBuildGraphTopology:
    def test_empty_yields_only_tick(self):
        nodes, set_values, connects = ros_io._build_graph_topology([])
        assert nodes == [(ros_io._TICK_NODE, ros_io._TICK_NODE_TYPE)]
        assert set_values == []
        assert connects == []

    def test_one_subscription_adds_sub_and_counter(self):
        subs = [{"topic": "/cmd_vel", "msg_type": "twist"}]
        nodes, set_values, connects = ros_io._build_graph_topology(subs)
        node_names = [n for n, _ in nodes]
        assert "Sub_cmd_vel" in node_names
        assert "Seq_cmd_vel" in node_names
        assert ("Sub_cmd_vel.inputs:topicName", "/cmd_vel") in set_values
        # Tick -> Subscribe -> Counter chain wired.
        assert ("OnTick.outputs:tick", "Sub_cmd_vel.inputs:execIn") in connects
        assert (
            "Sub_cmd_vel.outputs:execOut",
            "Seq_cmd_vel.inputs:execIn",
        ) in connects


class _FakeReader:
    """Injectable attribute reader backed by a mutable dict."""

    def __init__(self, values):
        self.values = values
        self.reads = []

    def __call__(self, attr_path):
        self.reads.append(attr_path)
        return self.values[attr_path]


def _ros_io_for_cmd_vel(reader):
    paths = ros_io.expected_attr_paths("/cmd_vel", "twist")
    return ros_io.RosIo(attr_reader=reader, topic_paths={"/cmd_vel": paths})


class TestRosIoLatest:
    def test_no_message_returns_none_without_reading_data(self):
        paths = ros_io.expected_attr_paths("/cmd_vel", "twist")
        reader = _FakeReader({paths.freshness: 0})
        rio = ros_io.RosIo(attr_reader=reader, topic_paths={"/cmd_vel": paths})
        assert rio.latest("/cmd_vel") is None
        # Only the freshness attr was read; data attrs were not touched.
        assert reader.reads == [paths.freshness]

    def test_fresh_message_returned_once(self):
        paths = ros_io.expected_attr_paths("/cmd_vel", "twist")
        reader = _FakeReader(
            {
                paths.freshness: 1,
                paths.fields["linear"]: (1.0, 0.0, 0.0),
                paths.fields["angular"]: (0.0, 0.0, 0.5),
            }
        )
        rio = ros_io.RosIo(attr_reader=reader, topic_paths={"/cmd_vel": paths})
        msg = rio.latest("/cmd_vel")
        assert msg is not None
        assert msg.topic == "/cmd_vel"
        assert msg.seq == 1
        assert msg.fields["linear"] == (1.0, 0.0, 0.0)
        # Same counter on the next call -> reported exactly once.
        assert rio.latest("/cmd_vel") is None

    def test_counter_advance_marks_fresh_again(self):
        paths = ros_io.expected_attr_paths("/cmd_vel", "twist")
        values = {
            paths.freshness: 1,
            paths.fields["linear"]: 1,
            paths.fields["angular"]: 2,
        }
        reader = _FakeReader(values)
        rio = ros_io.RosIo(attr_reader=reader, topic_paths={"/cmd_vel": paths})
        assert rio.latest("/cmd_vel").seq == 1
        assert rio.latest("/cmd_vel") is None
        values[paths.freshness] = 2
        assert rio.latest("/cmd_vel").seq == 2

    def test_unknown_topic_raises(self):
        rio = ros_io.RosIo(attr_reader=ros_io._fail_reader, topic_paths={})
        with pytest.raises(ValueError, match="unknown topic"):
            rio.latest("/nope")


class TestSetupRos2Io:
    def test_no_subscriptions_returns_empty_accessor(self):
        rio = ros_io.setup_ros2_io(stage=None, scene={})
        assert isinstance(rio, ros_io.RosIo)
        with pytest.raises(ValueError, match="unknown topic"):
            rio.latest("/cmd_vel")

    def test_configured_subscriptions_raise_not_implemented(self):
        scene = {"ros2_io": {"subscriptions": [{"topic": "/cmd_vel", "type": "twist"}]}}
        with pytest.raises(NotImplementedError):
            ros_io.setup_ros2_io(stage=None, scene=scene)
