"""Contract for the producer version table and its generator.

The table in the four READMEs says which Isaac Sim each published producer
image was built on. It is NOT hand-maintained: `script/ci/sync_producer_versions.py`
regenerates it from the registry, and CI runs the same script with `--check`
so a stale table is a red build rather than something a reader discovers.

Why a script at all: the four READMEs already carried `:0.0.1` long after
`:0.0.2` shipped. A table a human has to remember to update is a table that
goes stale, and a stale table about which Isaac Sim you are running is worse
than no table -- it is confidently wrong.

The AUTHORITY is the image's own `org.opencontainers.image.base.name` label,
read from the registry without pulling 18 GB. The table is a convenience view
of that; the script says so in the generated text.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT = _REPO_ROOT / "script" / "ci" / "sync_producer_versions.py"
_READMES = (
    _REPO_ROOT / "README.md",
    _REPO_ROOT / "doc" / "README.zh-TW.md",
    _REPO_ROOT / "doc" / "README.zh-CN.md",
    _REPO_ROOT / "doc" / "README.ja.md",
)
_START = "<!-- producer-versions:start -->"
_END = "<!-- producer-versions:end -->"


def _load():
    spec = importlib.util.spec_from_file_location("sync_producer_versions", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_script_exists():
    assert _SCRIPT.is_file(), f"{_SCRIPT} is missing"


def test_every_readme_carries_the_generated_block():
    for readme in _READMES:
        text = readme.read_text(encoding="utf-8")
        assert _START in text and _END in text, (
            f"{readme.name} has no producer-versions block; the table must be "
            "generated into all four languages, not just English"
        )


def test_render_marks_the_label_as_the_authority():
    module = _load()
    rendered = module.render_table(
        [
            {"tag": "0.0.1", "base": "nvcr.io/nvidia/isaac-sim:5.1.0", "source": "declared"},
            {"tag": "0.0.2", "base": "nvcr.io/nvidia/isaac-sim:6.0.1", "source": "label"},
        ]
    )
    assert "0.0.1" in rendered and "5.1.0" in rendered
    assert "0.0.2" in rendered and "6.0.1" in rendered
    # The table is a view; the label is the truth. A reader who trusts a stale
    # table and skips the inspect is the failure this sentence prevents.
    assert "org.opencontainers.image.base.name" in rendered


def test_render_flags_images_that_predate_the_label():
    module = _load()
    rendered = module.render_table(
        [{"tag": "0.0.1", "base": "nvcr.io/nvidia/isaac-sim:5.1.0", "source": "declared"}]
    )
    # A value we asserted by hand must not be presented as if the image said it.
    assert "declared" in rendered.lower()


def test_splice_is_idempotent():
    module = _load()
    doc = f"intro\n\n{_START}\nOLD\n{_END}\n\ntail\n"
    once = module.splice(doc, "NEW")
    twice = module.splice(once, "NEW")
    assert once == twice
    assert "OLD" not in once and "NEW" in once
    assert "intro" in once and "tail" in once


def test_check_mode_is_the_ci_gate():
    result = subprocess.run(
        [sys.executable, str(_SCRIPT), "--help"], capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr
    for flag in ("--check", "--write"):
        assert flag in result.stdout
