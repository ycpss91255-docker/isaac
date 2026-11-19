"""Byte-buffer helper for message ``uint8[]`` fields (isaac#365, Bug 2).

``memoryview(float32_array)`` is not a byte view: without ``cast("B")``
a float32 depth image yields its element count instead of 4 bytes per
pixel. ``to_u8_buffer`` returns the raw bytes as ``array.array('B')`` and
requires a C-contiguous input; a non-contiguous view raises ``ValueError``
rather than silently copying or producing scrambled bytes.
"""

import array
import sys
from pathlib import Path

import pytest

np = pytest.importorskip("numpy")

_FRAMEWORK_DIR = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK_DIR))

from isaac_devkit.buffers import to_u8_buffer  # noqa: E402


def test_float32_depth_bytes():
    d = np.zeros((480, 640), np.float32)
    out = to_u8_buffer(d)
    assert len(out) == 480 * 640 * 4
    assert bytes(out) == d.tobytes()


def test_float32_depth_bytes_content():
    d = np.arange(12, dtype=np.float32).reshape(3, 4) * 0.25
    assert bytes(to_u8_buffer(d)) == d.tobytes()


def test_uint8_rgb_bytes():
    rgb = np.arange(2 * 3 * 3, dtype=np.uint8).reshape(2, 3, 3)
    out = to_u8_buffer(rgb)
    assert len(out) == rgb.size
    assert bytes(out) == rgb.tobytes()


def test_returns_byte_array():
    out = to_u8_buffer(np.ones(3, np.float32))
    assert isinstance(out, array.array) and out.typecode == "B"


def test_accepts_stdlib_buffers():
    src = array.array("f", [0.5, 1.25, 2.0])
    assert bytes(to_u8_buffer(src)) == src.tobytes()


def test_non_contiguous_contract():
    d = np.arange(24, dtype=np.float32).reshape(4, 6)
    view = d[:, ::2]
    assert not view.flags["C_CONTIGUOUS"]
    with pytest.raises(ValueError, match="C-contiguous"):
        to_u8_buffer(view)
    fixed = np.ascontiguousarray(view)
    assert bytes(to_u8_buffer(fixed)) == fixed.tobytes()


def test_fortran_order_is_non_contiguous():
    d = np.asfortranarray(np.arange(6, dtype=np.float32).reshape(2, 3))
    with pytest.raises(ValueError, match="C-contiguous"):
        to_u8_buffer(d)
