#!/usr/bin/env python3
"""Regenerate the producer version table in the four READMEs.

WHY THIS IS A SCRIPT
--------------------
The four READMEs carried `isaac-stream-source:0.0.1` for as long as `:0.0.2`
existed. A table a human has to remember to update is a table that goes
stale, and a stale table about which Isaac Sim you are running is worse than
no table: it is confidently wrong, and the reader has no way to tell.

So nobody maintains it. This regenerates it from the registry, and CI runs
the same script with `--check`, which makes a stale table a red build rather
than something a reader discovers months later.

WHERE THE TRUTH LIVES
---------------------
The image's own `org.opencontainers.image.base.name` label, read from the
registry WITHOUT pulling (these images are ~18-35 GB; a doc job must not pull
one). The table is a convenience view of that label, and says so in its own
footer -- a reader who has a specific image in hand should ask the image, not
the table.

Images published before the label existed have no answer to give. Rather than
guess or leave a hole, their Isaac Sim version is DECLARED below and rendered
as `declared` so the table never presents a hand-asserted value as if the
image had reported it.

Usage:
  sync_producer_versions.py --check    exit 1 if any README is out of date
  sync_producer_versions.py --write    regenerate the block in all four
"""

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

REGISTRY = "ghcr.io"
OWNER = "ycpss91255-docker"
PACKAGE = "isaac-stream-source"

REPO_ROOT = Path(__file__).resolve().parents[2]
READMES = (
    REPO_ROOT / "README.md",
    REPO_ROOT / "doc" / "README.zh-TW.md",
    REPO_ROOT / "doc" / "README.zh-CN.md",
    REPO_ROOT / "doc" / "README.ja.md",
)

START = "<!-- producer-versions:start -->"
END = "<!-- producer-versions:end -->"

# Images published before the LABEL landed. They cannot report their own base
# image, so it is asserted here and rendered as `declared`. Nothing is added
# to this map going forward -- every new image answers for itself.
PRE_LABEL_BASES = {
    "0.0.1": "nvcr.io/nvidia/isaac-sim:5.1.0",
    "0.0.2": "nvcr.io/nvidia/isaac-sim:6.0.1",
}

_ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


def _get(url, token=None, accept=None):
    request = urllib.request.Request(url)
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if accept:
        request.add_header("Accept", accept)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def anonymous_token():
    url = (
        "https://{r}/token?scope=repository:{o}/{p}:pull&service={r}"
    ).format(r=REGISTRY, o=OWNER, p=PACKAGE)
    return _get(url).get("token", "")


def list_tags(token):
    url = "https://{r}/v2/{o}/{p}/tags/list".format(r=REGISTRY, o=OWNER, p=PACKAGE)
    return sorted(_get(url, token).get("tags") or [], key=_version_key)


def _version_key(tag):
    """Sort 0.0.10 after 0.0.9, and keep anything unparseable at the end."""
    parts = []
    for chunk in tag.replace("-", ".").split("."):
        parts.append((0, int(chunk)) if chunk.isdigit() else (1, chunk))
    return parts


def base_image_of(token, tag):
    """The image's declared base, or None when it carries no such label."""
    manifest = _get(
        "https://{r}/v2/{o}/{p}/manifests/{t}".format(
            r=REGISTRY, o=OWNER, p=PACKAGE, t=tag
        ),
        token,
        _ACCEPT,
    )
    if "manifests" in manifest:  # an index: pick linux/amd64
        digest = next(
            (
                entry["digest"]
                for entry in manifest["manifests"]
                if entry.get("platform", {}).get("architecture") == "amd64"
            ),
            None,
        )
        if digest is None:
            return None
        manifest = _get(
            "https://{r}/v2/{o}/{p}/manifests/{d}".format(
                r=REGISTRY, o=OWNER, p=PACKAGE, d=digest
            ),
            token,
            _ACCEPT,
        )
    config_digest = manifest.get("config", {}).get("digest")
    if not config_digest:
        return None
    config = _get(
        "https://{r}/v2/{o}/{p}/blobs/{d}".format(
            r=REGISTRY, o=OWNER, p=PACKAGE, d=config_digest
        ),
        token,
    )
    labels = (config.get("config") or {}).get("Labels") or {}
    return labels.get("org.opencontainers.image.base.name")


def collect(token):
    rows = []
    for tag in list_tags(token):
        base = base_image_of(token, tag)
        if base:
            rows.append({"tag": tag, "base": base, "source": "label"})
        else:
            rows.append(
                {
                    "tag": tag,
                    "base": PRE_LABEL_BASES.get(tag, "unknown"),
                    "source": "declared",
                }
            )
    return rows


def render_table(rows):
    """The generated block. Pure, so it is testable without a network."""
    lines = [
        "| Tag | Isaac Sim | Source |",
        "|---|---|---|",
    ]
    for row in rows:
        isaac = row["base"].rsplit(":", 1)[-1] if ":" in row["base"] else row["base"]
        note = "image label" if row["source"] == "label" else "declared (predates the label)"
        lines.append("| `{t}` | {i} | {n} |".format(t=row["tag"], i=isaac, n=note))
    lines += [
        "",
        "Generated by `script/ci/sync_producer_versions.py`; do not edit by hand.",
        "",
        "The table is a convenience view. The authority is the image itself --",
        "ask it directly when it matters:",
        "",
        "```bash",
        "docker inspect ghcr.io/{o}/{p}:<tag> \\".format(o=OWNER, p=PACKAGE),
        "  --format '{{index .Config.Labels \"org.opencontainers.image.base.name\"}}'",
        "```",
    ]
    return "\n".join(lines)


def splice(document, block):
    """Replace whatever is between the markers. Idempotent by construction."""
    if START not in document or END not in document:
        raise SystemExit(
            "missing {s} / {e} markers -- add them where the table belongs".format(
                s=START, e=END
            )
        )
    head, rest = document.split(START, 1)
    _, tail = rest.split(END, 1)
    return "{h}{s}\n{b}\n{e}{t}".format(h=head, s=START, b=block, e=END, t=tail)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check", action="store_true", help="exit 1 if any README is out of date"
    )
    mode.add_argument(
        "--write", action="store_true", help="regenerate the block in all four READMEs"
    )
    args = parser.parse_args(argv)

    try:
        rows = collect(anonymous_token())
    except (urllib.error.URLError, OSError) as err:
        sys.stderr.write("cannot reach the registry: {}\n".format(err))
        return 2

    block = render_table(rows)
    stale = []
    for readme in READMES:
        current = readme.read_text(encoding="utf-8")
        updated = splice(current, block)
        if current == updated:
            continue
        stale.append(readme)
        if args.write:
            readme.write_text(updated, encoding="utf-8")

    if args.write:
        print("updated {} file(s)".format(len(stale)))
        return 0
    if stale:
        sys.stderr.write(
            "producer version table is out of date in:\n{}\n"
            "run: python3 script/ci/sync_producer_versions.py --write\n".format(
                "\n".join("  " + str(p.relative_to(REPO_ROOT)) for p in stale)
            )
        )
        return 1
    print("producer version table is current")
    return 0


if __name__ == "__main__":
    sys.exit(main())
