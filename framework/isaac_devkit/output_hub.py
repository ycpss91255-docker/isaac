"""Python-mode output hub (isaac#365).

The hub fans simulation data out to registered callbacks. Each source is a
``(name, kind, reader)`` tuple; ``reader()`` performs the (GPU to CPU)
copy and is called **only** when at least one registered consumer wants
that ``kind``. The reading is then normalised to the documented payload
shape and delivered as a :class:`Frame`.

Payloads by kind:

* ``rgb``: ``uint8`` ``(H, W, 3)`` C-contiguous, alpha dropped.
* ``depth``: ``float32`` ``(H, W)`` C-contiguous.
* ``joint_state``: ``{"names", "positions", "velocities", "efforts"}``.
* ``imu``: ``{"lin_acc", "ang_vel", "orientation"}``, orientation order
  ``w, x, y, z``.

Pure: no Isaac or ROS import at module top (ADR-0017 section 8 /
ADR-0023); numpy is imported inside the normalisers.
"""

from collections import namedtuple

KINDS = ("rgb", "depth", "joint_state", "imu")

Frame = namedtuple("Frame", "name kind stamp data")


def _normalize_rgb(data):
    import numpy as np

    arr = np.asarray(data)
    if arr.ndim != 3 or arr.shape[2] not in (3, 4):
        raise ValueError(
            f"rgb reading must be (H, W, 3|4), got shape {arr.shape}"
        )
    return np.ascontiguousarray(arr[:, :, :3], dtype=np.uint8)


def _normalize_depth(data):
    import numpy as np

    arr = np.asarray(data)
    if arr.ndim == 3 and arr.shape[2] == 1:
        arr = arr[:, :, 0]
    if arr.ndim != 2:
        raise ValueError(
            f"depth reading must be (H, W) or (H, W, 1), got {arr.shape}"
        )
    return np.ascontiguousarray(arr, dtype=np.float32)


def _normalize_joint_state(data):
    out = {}
    for key in ("names", "positions", "velocities", "efforts"):
        if key not in data:
            raise ValueError(f"joint_state reading is missing {key!r}")
        out[key] = list(data[key])
    sizes = {len(v) for v in out.values()}
    if len(sizes) != 1:
        raise ValueError(f"joint_state fields differ in length: {sizes}")
    return out


def _normalize_imu(data):
    sizes = {"lin_acc": 3, "ang_vel": 3, "orientation": 4}
    out = {}
    for key, size in sizes.items():
        if key not in data:
            raise ValueError(f"imu reading is missing {key!r}")
        values = [float(v) for v in data[key]]
        if len(values) != size:
            raise ValueError(
                f"imu {key!r} needs {size} values, got {len(values)}"
            )
        out[key] = values
    return out


_NORMALIZERS = {
    "rgb": _normalize_rgb,
    "depth": _normalize_depth,
    "joint_state": _normalize_joint_state,
    "imu": _normalize_imu,
}


class OutputHub:
    """Register callbacks per kind; emit one tick of sources."""

    def __init__(self):
        self._subs = []  # list of (callback, frozenset(kinds) or None)

    def register(self, callback, kinds=None):
        """Register *callback*; ``kinds=None`` means every kind.

        Raises:
            ValueError: *kinds* contains a name not in :data:`KINDS`.
        """
        if kinds is not None:
            unknown = [k for k in kinds if k not in KINDS]
            if unknown:
                raise ValueError(
                    f"unknown output kind(s) {unknown}; allowed: {list(KINDS)}"
                )
            kinds = frozenset(kinds)
        self._subs.append((callback, kinds))

    def unregister(self, callback):
        """Remove every registration of *callback* (no-op if absent)."""
        self._subs = [(cb, ks) for cb, ks in self._subs if cb != callback]

    def emit(self, stamp, sources):
        """Deliver one tick.

        Args:
            stamp: Time in seconds attached to every frame of this tick.
            sources: Iterable of ``(name, kind, reader)``.

        Raises:
            ValueError: A wanted source has an unknown kind or a
                malformed reading.
        """
        for name, kind, reader in sources:
            callbacks = [
                cb for cb, ks in self._subs if ks is None or kind in ks
            ]
            if not callbacks:
                continue  # no consumer: no GPU to CPU copy
            if kind not in _NORMALIZERS:
                raise ValueError(
                    f"unknown output kind {kind!r}; allowed: {list(KINDS)}"
                )
            raw = reader()
            if raw is None:
                continue
            frame = Frame(name, kind, stamp, _NORMALIZERS[kind](raw))
            for cb in callbacks:
                cb(frame)
