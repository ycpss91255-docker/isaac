"""ROS 2 inbound I/O via OmniGraph Subscribe nodes (ADR-0017 sections 6, 9).

Greenfield module (isaac#130): no predecessor exists in ``src/script/``.
Inbound ROS 2 traffic reaches the simulation through an OmniGraph ROS 2
Subscribe node whose outputs are read from graph attributes -- **no rclpy
executor is spun up**, which sidesteps the rclpy/Kit signal-init ordering
conflict (see ``src/script/diag_graph_bridge.py`` lineage).

Contract surface (ADR-0017 section 9)::

    setup_ros2_io(stage, scene: dict) -> RosIo
    RosIo.latest(topic: str) -> Msg | None   # non-blocking; None when no
                                             # message; a message is fresh
                                             # once (no re-mark); reads an
                                             # OmniGraph attr, not rclpy

Pure / Isaac split (PRD A1):

* Pure (module level, hosted-testable): scene-config parsing
  (``parse_ros2_io_config``), expected attribute-path computation
  (``expected_attr_paths``), graph-topology computation
  (``_build_graph_topology`` -- strings only, no ``pxr``), and the
  ``RosIo.latest`` freshness bookkeeping against an injected attribute
  reader.
* Isaac (function-local imports only): the OmniGraph attribute reader
  (``_og_attr_reader``) and the graph build inside ``setup_ros2_io``.
  The graph build path raises ``NotImplementedError`` until the
  ``/cmd_vel`` example wires it end-to-end (isaac#131).

Scene-config schema consumed here (single-YAML schema, v1)::

    ros2_io:
      subscriptions:
        - topic: /cmd_vel
          type: twist

Freshness mechanism: each subscription chains the Subscribe node's
``outputs:execOut`` into a Counter node; the counter value is 0 until the
first message and increments once per received message. ``RosIo.latest``
reports a message exactly once by remembering the last counter value seen
per topic and treating any *changed* value as fresh (a counter reset is
therefore also treated as fresh; the counter returning to the exact
last-seen value between two calls is undetectable -- counters are
monotonic in practice).

Example::

    from isaac_devkit.ros_io import setup_ros2_io

    ros_io = setup_ros2_io(stage, scene)
    msg = ros_io.latest("/cmd_vel")
    if msg is not None:
        linear = msg.fields["linear"]
"""

from __future__ import annotations

import re
from typing import Callable, Dict, List, NamedTuple, Optional, Tuple

# Default OmniGraph path hosting all ros_io subscribe chains.
GRAPH_PATH = "/World/Ros2IoGraph"

# ROS 2 topic name: one or more /-prefixed tokens, each starting with a
# letter or underscore (no trailing slash, no empty token).
_TOPIC_RE = re.compile(r"^(/[A-Za-z_][A-Za-z0-9_]*)+$")

# Allowed keys for one subscriptions[] entry (strict: typos fail loud).
_SUBSCRIPTION_KEYS = frozenset({"topic", "type"})

# Supported message types -> OmniGraph node type + data output attributes.
# Field-name keys become Msg.fields keys; values are node-relative attrs.
_MSG_TYPE_SPECS: Dict[str, Dict[str, object]] = {
    "twist": {
        "node_type": "isaacsim.ros2.bridge.ROS2SubscribeTwist",
        "fields": {
            "linear": "outputs:linearVelocity",
            "angular": "outputs:angularVelocity",
        },
    },
}

# Freshness chain: Subscribe.outputs:execOut -> Counter; latest() polls
# the counter's count output (0 until the first message).
_FRESHNESS_NODE_TYPE = "omni.graph.action.Counter"
_FRESHNESS_ATTR = "outputs:count"

# Shared tick source driving every subscribe chain in the graph.
_TICK_NODE = "OnTick"
_TICK_NODE_TYPE = "omni.graph.action.OnPlaybackTick"


class Msg(NamedTuple):
    """One message snapshot read from OmniGraph subscribe attributes.

    Attributes:
        topic: ROS 2 topic the message arrived on.
        fields: Field name -> value, per the message-type spec (for
            ``twist``: ``linear`` and ``angular``).
        seq: Freshness counter value at read time (per-topic message
            count since graph start).
    """

    topic: str
    fields: Dict[str, object]
    seq: int


class TopicAttrPaths(NamedTuple):
    """Expected OmniGraph attribute paths for one subscribed topic.

    Attributes:
        freshness: Full path of the Counter ``outputs:count`` attribute.
        fields: Field name -> full path of the data output attribute.
    """

    freshness: str
    fields: Dict[str, str]


def parse_ros2_io_config(scene: dict) -> List[Dict[str, str]]:
    """Extract and validate the ``ros2_io.subscriptions`` scene section.

    Pure (hosted-testable). A missing ``ros2_io`` section or an empty
    ``subscriptions`` list means "no inbound topics" and returns ``[]``.

    Args:
        scene: Validated scene dict (output of ``scene.load_scene``).

    Returns:
        Normalized subscription entries, order preserved:
        ``[{"topic": "/cmd_vel", "msg_type": "twist"}, ...]``.

    Raises:
        ValueError: Malformed section, entry, topic name, unsupported or
            missing message type, unknown entry key, or duplicate topic.
    """
    section = scene.get("ros2_io")
    if section is None:
        return []
    if not isinstance(section, dict):
        raise ValueError("ros2_io: must be a mapping")

    subscriptions = section.get("subscriptions", [])
    if not isinstance(subscriptions, list):
        raise ValueError("ros2_io.subscriptions: must be a list")

    normalized: List[Dict[str, str]] = []
    seen_topics = set()
    for index, entry in enumerate(subscriptions):
        where = f"ros2_io.subscriptions[{index}]"
        if not isinstance(entry, dict):
            raise ValueError(f"{where}: must be a mapping")

        unknown = set(entry) - _SUBSCRIPTION_KEYS
        if unknown:
            raise ValueError(
                f"{where}: unknown key(s) {sorted(unknown)}; "
                f"allowed: {sorted(_SUBSCRIPTION_KEYS)}"
            )

        topic = entry.get("topic")
        if not isinstance(topic, str) or not _TOPIC_RE.match(topic):
            raise ValueError(
                f"{where}: 'topic' must be an absolute ROS 2 topic name "
                f"(e.g. '/cmd_vel'), got {topic!r}"
            )
        if topic in seen_topics:
            raise ValueError(f"{where}: duplicate topic {topic!r}")
        seen_topics.add(topic)

        msg_type = entry.get("type")
        if msg_type not in _MSG_TYPE_SPECS:
            raise ValueError(
                f"{where}: unsupported 'type' {msg_type!r}; "
                f"supported: {sorted(_MSG_TYPE_SPECS)}"
            )

        normalized.append({"topic": topic, "msg_type": msg_type})
    return normalized


def _sanitize_topic(topic: str) -> str:
    """Turn a /-separated topic into an OmniGraph-safe node-name stem."""
    return topic.strip("/").replace("/", "_")


def _subscribe_node_name(topic: str) -> str:
    """OmniGraph node name of the Subscribe node for ``topic``."""
    return f"Sub_{_sanitize_topic(topic)}"


def _freshness_node_name(topic: str) -> str:
    """OmniGraph node name of the freshness Counter node for ``topic``."""
    return f"Seq_{_sanitize_topic(topic)}"


def expected_attr_paths(
    topic: str, msg_type: str, graph_path: str = GRAPH_PATH
) -> TopicAttrPaths:
    """Compute the OmniGraph attribute paths ``latest()`` will read.

    Pure (hosted-testable): string computation from naming rules only;
    no stage access (the Isaac-side existence check is M2 scope).

    Args:
        topic: Absolute ROS 2 topic name (e.g. ``"/cmd_vel"``).
        msg_type: Key into the supported message-type specs.
        graph_path: OmniGraph prim path hosting the subscribe chains.

    Returns:
        TopicAttrPaths with the freshness-counter path and the per-field
        data output paths.

    Raises:
        ValueError: ``msg_type`` is not supported.
    """
    spec = _MSG_TYPE_SPECS.get(msg_type)
    if spec is None:
        raise ValueError(
            f"unsupported msg_type {msg_type!r}; "
            f"supported: {sorted(_MSG_TYPE_SPECS)}"
        )
    sub_node = _subscribe_node_name(topic)
    fields = {
        name: f"{graph_path}/{sub_node}.{attr}"
        for name, attr in spec["fields"].items()
    }
    freshness = (
        f"{graph_path}/{_freshness_node_name(topic)}.{_FRESHNESS_ATTR}"
    )
    return TopicAttrPaths(freshness=freshness, fields=fields)


def _build_graph_topology(
    subscriptions: List[Dict[str, str]],
) -> Tuple[
    List[Tuple[str, str]],
    List[Tuple[str, str]],
    List[Tuple[str, str]],
]:
    """Action Graph topology: 1 OnTick -> N (Subscribe -> Counter).

    Pure (strings only, no ``pxr``): the (nodes, set_values, connects)
    triple feeds ``og.Controller.edit`` on the Isaac side (#131). One
    Counter per subscription gives ``latest()`` its freshness signal.

    Args:
        subscriptions: Normalized entries from ``parse_ros2_io_config``.

    Returns:
        ``(nodes, set_values, connects)`` -- each a list of pairs in the
        ``og.Controller.Keys`` format.
    """
    nodes: List[Tuple[str, str]] = [(_TICK_NODE, _TICK_NODE_TYPE)]
    set_values: List[Tuple[str, str]] = []
    connects: List[Tuple[str, str]] = []

    for entry in subscriptions:
        topic = entry["topic"]
        spec = _MSG_TYPE_SPECS[entry["msg_type"]]
        sub_node = _subscribe_node_name(topic)
        seq_node = _freshness_node_name(topic)

        nodes.extend(
            [
                (sub_node, spec["node_type"]),
                (seq_node, _FRESHNESS_NODE_TYPE),
            ]
        )
        set_values.append((f"{sub_node}.inputs:topicName", topic))
        connects.extend(
            [
                (f"{_TICK_NODE}.outputs:tick", f"{sub_node}.inputs:execIn"),
                (f"{sub_node}.outputs:execOut", f"{seq_node}.inputs:execIn"),
            ]
        )
    return nodes, set_values, connects


def _og_attr_reader(attr_path: str) -> object:
    """Read one OmniGraph attribute value (Isaac side, function-local).

    Production ``RosIo`` instances are constructed with this reader by
    ``setup_ros2_io`` once the graph build lands (#131); hosted tests
    inject a fake reader instead.
    """
    import omni.graph.core as og

    return og.Controller.get(og.Controller.attribute(attr_path))


def _fail_reader(attr_path: str) -> object:
    """Defensive reader for a RosIo with no subscribed topics."""
    raise RuntimeError(
        f"ros_io: attribute read for {attr_path!r} but no topics are "
        "configured (ros2_io.subscriptions is empty)"
    )


class RosIo:
    """Non-blocking accessor for inbound ROS 2 messages (ADR-0017 §9).

    Reads OmniGraph subscribe-node output attributes through an injected
    reader -- never an rclpy executor. Construct via ``setup_ros2_io``;
    hosted tests construct directly with a fake reader.
    """

    def __init__(
        self,
        attr_reader: Callable[[str], object],
        topic_paths: Dict[str, TopicAttrPaths],
    ):
        """Initializes bookkeeping for the configured topics.

        Args:
            attr_reader: Callable mapping a full OmniGraph attribute
                path to its current value.
            topic_paths: Topic name -> TopicAttrPaths to poll.
        """
        self._attr_reader = attr_reader
        self._topic_paths = dict(topic_paths)
        # Last freshness counter value already reported per topic
        # (0 = nothing reported yet, matching the Counter's
        # pre-first-message value).
        self._last_seq = {topic: 0 for topic in self._topic_paths}

    def latest(self, topic: str) -> Optional[Msg]:
        """Return the newest unreported message on ``topic``, else None.

        Non-blocking: a single freshness-attribute read decides; data
        attributes are only read when a new message is present. A message
        is reported exactly once -- subsequent calls return ``None``
        until the freshness counter changes again.

        Args:
            topic: A topic configured in ``ros2_io.subscriptions``.

        Returns:
            The fresh ``Msg``, or ``None`` when no unreported message.

        Raises:
            ValueError: ``topic`` was not configured (programming error;
                fails loud instead of silently returning None forever).
        """
        paths = self._topic_paths.get(topic)
        if paths is None:
            raise ValueError(
                f"ros_io: unknown topic {topic!r}; configured: "
                f"{sorted(self._topic_paths)}"
            )
        seq = int(self._attr_reader(paths.freshness))
        if seq == self._last_seq[topic]:
            return None
        self._last_seq[topic] = seq
        fields = {
            name: self._attr_reader(path)
            for name, path in paths.fields.items()
        }
        return Msg(topic=topic, fields=fields, seq=seq)


def setup_ros2_io(stage, scene: dict) -> RosIo:
    """Wire inbound ROS 2 topics into OmniGraph and return the accessor.

    Contract entry (ADR-0017 section 9). Pure work first (config parse +
    attribute-path computation, hosted-testable); the Isaac-side graph
    build (``og.Controller.edit`` over ``_build_graph_topology`` output,
    function-local imports) is unimplemented until the ``/cmd_vel``
    example wires and verifies it end-to-end (isaac#131).

    Args:
        stage: USD stage (reserved for the #131 graph build; unused
            while the scene has no subscriptions).
        scene: Validated scene dict; ``ros2_io.subscriptions`` selects
            the inbound topics (missing section = no inbound I/O).

    Returns:
        A ``RosIo``; with no subscriptions configured it is an empty
        accessor whose ``latest()`` raises ValueError for any topic.

    Raises:
        ValueError: Malformed ``ros2_io`` configuration.
        NotImplementedError: Subscriptions are configured but the graph
            build path is not wired yet (#131).
    """
    subscriptions = parse_ros2_io_config(scene)
    if not subscriptions:
        return RosIo(attr_reader=_fail_reader, topic_paths={})
    raise NotImplementedError(
        "ros_io: OmniGraph subscribe wiring (OnPlaybackTick -> "
        "ROS2Subscribe* -> Counter) lands with the /cmd_vel example "
        "(isaac#131); hosted surface covers config parsing, attr-path "
        "computation, and latest() bookkeeping only"
    )
