"""Hosted guard: Dockerfile stage tree and per-stage GUI config (isaac#427).

Target tree:  devel-base -> devel -> {gui, stream, headless}.  `devel` is the
shared layer (isaac code + common config); only the `gui` stage mounts X11.
The Dockerfile is not changed to add X11 packages: the GUI mount is a compose
runtime setting, so the guard reads `.setup.conf` (`[gui]` and `[stage:*]`).
No docker, no GPU.
"""

import configparser
import pathlib
import re

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_DOCKERFILE = _REPO_ROOT / "Dockerfile"
_SETUP_CONF = _REPO_ROOT / ".setup.conf"

_LEAVES = ("gui", "stream", "headless")


def _stage_parents():
    """Map active (uncommented) stage name -> parent reference."""
    pattern = re.compile(r"^FROM\s+(\S+)\s+AS\s+(\S+)\s*$", re.MULTILINE)
    text = _DOCKERFILE.read_text(encoding="utf-8")
    return {m.group(2): m.group(1) for m in pattern.finditer(text)}


def _header_stages():
    """Stage names listed in the `# Stages:` block at the top of Dockerfile."""
    names = []
    in_block = False
    for line in _DOCKERFILE.read_text(encoding="utf-8").splitlines():
        if line.startswith("# Stages:"):
            in_block = True
            continue
        if in_block:
            m = re.match(r"^#   ([a-z][a-z0-9_-]*)\s+- ", line)
            if m:
                names.append(m.group(1))
            elif not line.startswith("#   "):
                break  # continuation lines are indented further; stop at the first non-stage line
    return names


def _setup_conf():
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    parser.read_string(_SETUP_CONF.read_text(encoding="utf-8"))
    return parser


def test_devel_is_the_shared_layer_above_devel_base():
    assert _stage_parents()["devel"] == "devel-base"


def test_gui_stream_headless_all_build_from_devel():
    parents = _stage_parents()
    for stage in _LEAVES:
        assert parents.get(stage) == "devel", stage


def test_header_stage_list_matches_active_stages():
    assert set(_header_stages()) >= set(_stage_parents()), (
        "Dockerfile header '# Stages:' block is missing active stages"
    )


def test_only_gui_stage_enables_gui_mount():
    conf = _setup_conf()
    assert conf["gui"]["mode"] == "off"
    assert conf["stage:gui"]["gui.mode"] == "auto"
    for stage in ("stream", "headless", "devel-test"):
        assert conf[f"stage:{stage}"]["gui.mode"] == "off", stage
