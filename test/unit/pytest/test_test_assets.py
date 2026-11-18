"""Hosted unit tests for the official Isaac test-asset fetch helper (#324).

The helper (``test/test_assets.py``) downloads a pinned NVIDIA Jetbot USD
from the public Omniverse S3 bucket on first use and caches it locally.
Tests verify: the URL and version are pinned, a cache hit avoids a second
download, and an empty cache with no network gives a clear error.

Pure -- filesystem + HTTP (mocked for the cache/offline tests), no Isaac.
"""

import importlib
import sys
from pathlib import Path
from unittest import mock

import pytest

# Ensure test/ is importable so ``import test_assets`` works.
_TEST_DIR = Path(__file__).resolve().parents[2]
if str(_TEST_DIR) not in sys.path:
    sys.path.insert(0, str(_TEST_DIR))

import test_assets  # noqa: E402


# -- Pinning tests --------------------------------------------------------


class TestAssetPinning:
    """The asset registry pins an exact URL, version and expected size."""

    def test_jetbot_url_is_pinned(self):
        """The Jetbot URL points at the Omniverse S3 bucket."""
        info = test_assets.ASSETS["jetbot"]
        assert "omniverse-content-production" in info["url"]
        assert info["url"].endswith(".usd")

    def test_jetbot_url_contains_version_segment(self):
        """The URL contains a version segment so it is reproducible."""
        info = test_assets.ASSETS["jetbot"]
        assert "/4.2/" in info["url"] or "/4.5/" in info["url"]

    def test_jetbot_sha256_is_pinned(self):
        """A sha256 digest is recorded for integrity verification."""
        info = test_assets.ASSETS["jetbot"]
        assert "sha256" in info
        assert len(info["sha256"]) == 64  # hex-encoded SHA-256

    def test_registry_is_not_empty(self):
        """At least one asset is registered."""
        assert len(test_assets.ASSETS) >= 1


# -- Cache behaviour tests ------------------------------------------------


class TestCacheBehaviour:
    """fetch_test_asset uses a local cache directory."""

    def test_cache_hit_skips_download(self, tmp_path):
        """When the file already exists in the cache, no HTTP call is made."""
        cache_dir = tmp_path / "cache"
        cache_dir.mkdir()
        info = test_assets.ASSETS["jetbot"]
        cached_file = cache_dir / "jetbot.usd"
        cached_file.write_bytes(b"fake-usd-content")

        with mock.patch.object(
            test_assets, "_download", side_effect=AssertionError("must not download")
        ):
            # Should NOT call _download because the file exists.
            result = test_assets.fetch_test_asset(
                "jetbot", cache_dir=cache_dir, verify=False,
            )

        assert result == cached_file
        assert result.exists()

    def test_download_called_on_cache_miss(self, tmp_path):
        """When the cache is empty, _download is invoked."""
        cache_dir = tmp_path / "cache"
        cache_dir.mkdir()

        downloaded = []

        def fake_download(url, dest):
            downloaded.append(url)
            dest.write_bytes(b"fake-usd")

        with mock.patch.object(test_assets, "_download", side_effect=fake_download):
            result = test_assets.fetch_test_asset(
                "jetbot", cache_dir=cache_dir, verify=False,
            )

        assert len(downloaded) == 1
        assert result.exists()

    def test_returns_path_object(self, tmp_path):
        """The return value is a Path."""
        cache_dir = tmp_path / "cache"
        cache_dir.mkdir()
        cached_file = cache_dir / "jetbot.usd"
        cached_file.write_bytes(b"fake")

        result = test_assets.fetch_test_asset(
            "jetbot", cache_dir=cache_dir, verify=False,
        )
        assert isinstance(result, Path)


# -- Offline error tests ---------------------------------------------------


class TestOfflineError:
    """An empty cache with no network gives a clear, actionable error."""

    def test_offline_empty_cache_raises(self, tmp_path):
        """ConnectionError from urllib -> RuntimeError with asset name."""
        cache_dir = tmp_path / "cache"
        cache_dir.mkdir()

        with mock.patch.object(
            test_assets,
            "_download",
            side_effect=ConnectionError("simulated network failure"),
        ):
            with pytest.raises(RuntimeError, match="jetbot"):
                test_assets.fetch_test_asset(
                    "jetbot", cache_dir=cache_dir, verify=False,
                )

    def test_unknown_asset_name_raises(self, tmp_path):
        """An unregistered asset name raises KeyError."""
        with pytest.raises(KeyError, match="no_such_asset"):
            test_assets.fetch_test_asset(
                "no_such_asset", cache_dir=tmp_path,
            )
