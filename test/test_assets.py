"""Cached fetch helper for official NVIDIA Isaac test assets (#324).

Downloads a pinned asset (USD model) from the public Omniverse content S3
bucket on first use and caches it locally.  Subsequent calls return the
cached path without any network access.

The asset registry (``ASSETS``) pins every asset by URL, version segment
and SHA-256 digest so CI builds are reproducible.

Usage::

    from test.test_assets import fetch_test_asset

    jetbot_usd = fetch_test_asset("jetbot")
    # -> Path("<cache_dir>/jetbot.usd"), downloaded once

The default ``cache_dir`` is ``$ISAAC_TEST_ASSET_CACHE`` (if set) or
``<repo_root>/.cache/test-assets/``.  The cache directory is
``.gitignore``-d.
"""

from __future__ import annotations

import hashlib
import os
import urllib.request
from pathlib import Path

# -- Asset registry --------------------------------------------------------
# Each entry pins: url, filename, sha256 hex digest.
# The Jetbot is a ~32 MB self-contained USD (chassis + camera prim),
# hosted on the public Omniverse content S3 bucket.  The 4.2 path is the
# same binary as 4.5 (identical ETag).  It covers what camera_bot covers
# today: a robot with a camera prim, loadable headless.
#
# Source: NVIDIA Isaac Sim built-in assets
# License: NVIDIA Omniverse License Agreement (asset redistribution
#   prohibited; downloaded at test time, not committed)
# Version: Isaac 4.2 asset collection (S3 path /Assets/Isaac/4.2/)

ASSETS: dict[str, dict[str, str]] = {
    "jetbot": {
        "url": (
            "https://omniverse-content-production.s3-us-west-2.amazonaws.com"
            "/Assets/Isaac/4.2/Isaac/Robots/Jetbot/jetbot.usd"
        ),
        "filename": "jetbot.usd",
        "sha256": (
            "4bc3d23936b2677f1274e450933855f4d7edce85032fd0ec02d7191c4b25f6f1"
        ),
    },
    # ~8 KB geometry-only cube (defaultPrim, no physics schemas): the
    # object the build_scene adapter GPU test marks ``mobility: dynamic``
    # (#325).  Same bucket / version / license as the Jetbot above.
    "nvidia_cube": {
        "url": (
            "https://omniverse-content-production.s3-us-west-2.amazonaws.com"
            "/Assets/Isaac/4.2/Isaac/Props/Blocks/nvidia_cube.usd"
        ),
        "filename": "nvidia_cube.usd",
        "sha256": (
            "0d0f5cc395883c4e81b6ef11aa5f0fa3732b467e3860d139466142d60bd0d803"
        ),
    },
}

_REPO_ROOT = Path(__file__).resolve().parents[1]


def _default_cache_dir() -> Path:
    """Return the default cache directory for test assets."""
    env = os.environ.get("ISAAC_TEST_ASSET_CACHE")
    if env:
        return Path(env)
    return _REPO_ROOT / ".cache" / "test-assets"


def _download(url: str, dest: Path) -> None:
    """Download *url* to *dest* (blocking, no retry)."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    urllib.request.urlretrieve(url, str(dest))


def _verify_sha256(path: Path, expected: str) -> None:
    """Raise if *path*'s SHA-256 does not match *expected*."""
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise RuntimeError(
            f"SHA-256 mismatch for {path.name}: "
            f"expected {expected}, got {actual}"
        )


def fetch_test_asset(
    name: str,
    *,
    cache_dir: Path | None = None,
    verify: bool = True,
) -> Path:
    """Return the local path to a pinned test asset, downloading on first use.

    Args:
        name: Registered asset name (a key in ``ASSETS``).
        cache_dir: Override the cache directory (default: see module doc).
        verify: When *True* (the default), verify the SHA-256 digest after
            download and on every cache hit.  Pass *False* in unit tests
            that mock ``_download`` with fake content.

    Returns:
        A ``Path`` to the cached USD file.

    Raises:
        KeyError: *name* is not in the asset registry.
        RuntimeError: Download failed or SHA-256 mismatch.
    """
    if name not in ASSETS:
        raise KeyError(
            f"Unknown test asset {name!r}: "
            f"registered assets are {sorted(ASSETS)}"
        )

    info = ASSETS[name]
    if cache_dir is None:
        cache_dir = _default_cache_dir()

    dest = cache_dir / info["filename"]

    if dest.exists():
        if verify:
            _verify_sha256(dest, info["sha256"])
        return dest

    try:
        _download(info["url"], dest)
    except Exception as exc:
        raise RuntimeError(
            f"Failed to download test asset {name!r} from {info['url']}: {exc}"
        ) from exc

    if verify:
        _verify_sha256(dest, info["sha256"])

    return dest
