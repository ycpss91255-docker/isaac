"""Hosted tests for ``isaac_devkit.sim_version`` (isaac#295).

Every experiment driver records which Isaac Sim produced its numbers in an
``isaac_variant`` field. Until the 6.2.0 upgrade that field was the string
literal ``"6.0.1"`` in every driver script, so re-running the physics re-validation on
a new base image would have written 6.2.0 results labelled 6.0.1 -- exactly
the comparison the re-validation exists to make. The version now comes from
the image itself (``/isaac-sim/VERSION``), and the last test stops a literal
from coming back.
"""

import re
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(_REPO_ROOT / "framework"))

from isaac_devkit import sim_version  # noqa: E402

pytestmark = pytest.mark.core


@pytest.mark.parametrize(
    ("content", "expected"),
    [
        # What NGC's nvcr.io/nvidia/isaac-sim:6.2.0.1 ships.
        ("6.2.0-rc.15+release.53422.03030206.gl", "6.2.0"),
        # What nvcr.io/nvidia/isaac-sim:6.0.1 ships.
        ("6.0.1-rc.7+release.42383.32955d8d.gl\n", "6.0.1"),
        # A bare release number, as a source build may write it.
        ("5.1.0\n", "5.1.0"),
    ],
)
def test_release_is_read_from_the_version_file(tmp_path, content, expected):
    version_file = tmp_path / "VERSION"
    version_file.write_text(content, encoding="utf-8")
    assert sim_version.isaac_sim_version(version_file) == expected


def test_missing_version_file_reports_unknown(tmp_path):
    # A hosted box has no Isaac Sim. The driver must still write its JSON, and
    # "unknown" is honest where a guessed version would not be.
    assert sim_version.isaac_sim_version(tmp_path / "absent") == "unknown"


def test_empty_version_file_reports_unknown(tmp_path):
    version_file = tmp_path / "VERSION"
    version_file.write_text("\n", encoding="utf-8")
    assert sim_version.isaac_sim_version(version_file) == "unknown"


def test_default_reads_the_image_install():
    assert sim_version.DEFAULT_VERSION_FILE == Path("/isaac-sim/VERSION")


_VARIANT_LITERAL = re.compile(r"""["']isaac_variant["']\s*:\s*["']""")


def _find_hardcoded_variants(root: Path) -> list[str]:
    """Return repo-relative paths of driver scripts with an isaac_variant literal."""
    scripts = []
    # isaac#360: an empty glob would make the scan pass checking nothing. The
    # test/verify_*.py family moved to isaac_physics_test, so only src/script
    # remains in scope.
    for base, pattern in (("src/script", "*.py"),):
        matched = sorted((root / base).glob(pattern))
        assert matched, f"scan glob matched nothing: {base}/{pattern}"
        scripts += matched
    return [
        str(path.relative_to(root))
        for path in scripts
        if _VARIANT_LITERAL.search(path.read_text(encoding="utf-8"))
    ]


def test_no_driver_hardcodes_the_isaac_variant():
    offenders = _find_hardcoded_variants(_REPO_ROOT)
    assert not offenders, (
        "isaac_variant must come from isaac_sim_version(), not a literal: "
        + ", ".join(offenders)
    )


def _plant(root: Path, rel: str, text: str = "x = 1\n") -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


@pytest.mark.parametrize(
    "present",
    [
        [],
        ["test/verify_a.py"],
    ],
    ids=["no-script", "only-moved-verify-family"],
)
def test_scan_fails_when_a_script_glob_matches_nothing(tmp_path, present):
    # isaac#360: a scan over an empty file set used to pass vacuously, so
    # moving a script family away would leave the guard green and checking
    # nothing. Each glob must be non-empty on its own, not just the union.
    for rel in present:
        _plant(tmp_path, rel)
    with pytest.raises(AssertionError):
        _find_hardcoded_variants(tmp_path)


def test_scan_reports_a_planted_variant_literal(tmp_path):
    # isaac#360: pin the detection itself, not only "passes on the real repo".
    _plant(tmp_path, "src/script/clean.py")
    _plant(tmp_path, "src/script/bad.py", '{"isaac_variant": "6.0.1"}\n')
    assert _find_hardcoded_variants(tmp_path) == ["src/script/bad.py"]
