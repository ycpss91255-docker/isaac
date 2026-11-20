"""Stamp split for ROS-style times (isaac#365, Bug 1 regression).

``split_stamp`` turns a time in seconds into ``(sec, nanosec)``. When the
time is within 0.5 ns below an integer second, ``round(frac * 1e9)``
reaches 1e9; that has to carry into ``sec`` instead of emitting an
invalid (or wrapped, non-monotonic) stamp. The helper is pure arithmetic:
no ROS and no Isaac import.
"""

import random
import sys
from pathlib import Path

_FRAMEWORK_DIR = Path(__file__).resolve().parents[3] / "framework"
sys.path.insert(0, str(_FRAMEWORK_DIR))

from isaac_devkit.stamp import split_stamp  # noqa: E402

import pytest

pytestmark = pytest.mark.core

_NS = 1_000_000_000


def test_nanosec_rounding_to_1e9_carries():
    assert split_stamp(1.0 - 1e-10) == (1, 0)
    assert split_stamp(4.9999999999) == (5, 0)


def test_exact_values_do_not_carry():
    assert split_stamp(0.0) == (0, 0)
    assert split_stamp(3.0) == (3, 0)
    assert split_stamp(2.5) == (2, 500_000_000)


def test_pairs_strictly_monotonic():
    # Includes values within 0.5 ns below integer seconds (the carry
    # case); every value is at least 2 ns apart so the stamps must differ.
    times = [0.0, 0.5, 0.999999998, 1.0 - 1e-10, 1.000000002, 1.5]
    times += [2.0 - 1e-10, 2.000000002, 4.9999999999, 5.000000002]
    times += [i * 0.0333333 for i in range(1, 400)]
    times = sorted(set(times))
    pairs = [split_stamp(t) for t in times]
    flat = [s * _NS + n for s, n in pairs]
    assert all(b > a for a, b in zip(flat, flat[1:]))


def test_nanosec_in_range():
    rng = random.Random(365)
    for _ in range(2000):
        sec, nanosec = split_stamp(rng.uniform(0.0, 1e6))
        assert 0 <= nanosec < _NS
        assert isinstance(sec, int) and isinstance(nanosec, int)
