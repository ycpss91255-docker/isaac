"""Byte-buffer helper for message ``uint8[]`` fields (isaac#365).

Pure stdlib: no numpy, ROS or Isaac import. Any object exposing the
buffer protocol (numpy array, ``array.array``, ``bytes``) is accepted.
"""

import array


def to_u8_buffer(arr) -> array.array:
    """Return the raw bytes of *arr* as ``array.array('B')``.

    Uses the buffer protocol, which is much faster than building a
    ``bytes`` object per element for rclpy-style ``uint8[]`` fields.
    ``cast("B")`` makes a float32 depth image come out as 4 bytes per
    pixel instead of one entry per element.

    Args:
        arr: A C-contiguous buffer-protocol object.

    Returns:
        ``array.array('B')`` holding the bytes in memory order.

    Raises:
        ValueError: *arr* is not C-contiguous (a strided slice or a
            Fortran-ordered array). Pass ``np.ascontiguousarray(arr)``;
            the helper never copies silently.
    """
    view = memoryview(arr)
    if not view.c_contiguous:
        raise ValueError(
            "to_u8_buffer requires a C-contiguous buffer; "
            "pass numpy.ascontiguousarray(arr)"
        )
    out = array.array("B")
    out.frombytes(view.cast("B"))
    return out
