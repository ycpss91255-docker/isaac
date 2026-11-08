"""The Isaac Sim release the running image ships (isaac#295).

Experiment drivers record which Isaac Sim produced their numbers. Reading it
from the image keeps a result honest across base-image bumps; a literal in the
driver would silently label a 6.2.0 run as 6.0.1.

Pure stdlib: safe to import on a host without Isaac Sim (ADR-0017 section 8).
"""

from pathlib import Path

DEFAULT_VERSION_FILE = Path("/isaac-sim/VERSION")


def isaac_sim_version(version_file=DEFAULT_VERSION_FILE) -> str:
    """Return the Isaac Sim release, e.g. ``"6.2.0"``.

    The image's ``VERSION`` file reads ``<release>-rc.<n>+<build>`` (e.g.
    ``6.2.0-rc.15+release.53422.03030206.gl``); only the release is returned.

    Args:
        version_file: Path to Isaac Sim's ``VERSION`` file.

    Returns:
        The release number, or ``"unknown"`` when the file is absent or empty
        (a host without Isaac Sim).
    """
    try:
        content = Path(version_file).read_text(encoding="utf-8").strip()
    except OSError:
        return "unknown"
    release = content.split("-", 1)[0].split("+", 1)[0]
    return release or "unknown"
