"""Time-stamp split for ROS-style ``(sec, nanosec)`` pairs (isaac#365).

Pure arithmetic: no ROS and no Isaac import (ADR-0017 section 8 /
ADR-0023). A consumer that builds a ``builtin_interfaces/Time`` calls
:func:`split_stamp` and fills the two fields itself.
"""

_NANOS_PER_SEC = 1_000_000_000


def split_stamp(t: float) -> tuple[int, int]:
    """Split a time in seconds into ``(sec, nanosec)``.

    When *t* is within 0.5 ns below an integer second the rounded
    nanoseconds reach 1e9. That is carried into ``sec`` so ``nanosec``
    always stays in ``[0, 1e9)`` and consecutive stamps never go
    backwards.

    Args:
        t: Time in seconds, ``t >= 0``.

    Returns:
        ``(sec, nanosec)`` with ``0 <= nanosec < 1_000_000_000``.
    """
    sec = int(t)
    nanosec = round((t - sec) * _NANOS_PER_SEC)
    if nanosec >= _NANOS_PER_SEC:
        sec += 1
        nanosec -= _NANOS_PER_SEC
    return sec, nanosec
