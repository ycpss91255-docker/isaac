#!/usr/bin/env python3
"""Test-group bookkeeping (isaac#434): one scope per test, checked statically.

CI runs per scope. The scopes are the five groups below; every pytest module
and every bats spec belongs to exactly one:

* pytest: a module-level ``pytestmark = pytest.mark.<group>``;
* bats:   a ``# bats file_tags=<group>`` line (other non-group tags allowed).

This module is the host-side half of the guard (it only parses text, so it
needs neither pytest collection nor bats). The collection-time half lives in
``test/group_markers.py``.

Usage:
  scope_groups.py check     # exit 1 and list every ungrouped / multi-group test
  scope_groups.py counts    # bats count per group (JSON)
"""

import ast
import json
import re
import sys
from pathlib import Path

GROUPS = ("core", "gui", "stream", "headless", "docs")

_REPO_ROOT = Path(__file__).resolve().parents[2]
_BATS_DIR = _REPO_ROOT / "test" / "bats" / "smoke"
_PYTEST_DIRS = (
    _REPO_ROOT / "test" / "unit" / "pytest",
    _REPO_ROOT / "test" / "integration" / "pytest",
)

_FILE_TAGS_RE = re.compile(r"^#\s*bats\s+file_tags\s*=\s*(.*?)\s*$")
_TEST_TAGS_RE = re.compile(r"^#\s*bats\s+test_tags\s*=\s*(.*?)\s*$")
_BATS_TEST_RE = re.compile(r"^@test\b")


# -- pytest -------------------------------------------------------------------


def pytest_modules(dirs):
    """Every ``test_*.py`` directly under each directory, sorted."""
    found = []
    for directory in dirs:
        found.extend(sorted(Path(directory).glob("test_*.py")))
    return found


def _group_of_mark(node):
    """Return the group name when ``node`` is ``pytest.mark.<group>``."""
    if (
        isinstance(node, ast.Attribute)
        and isinstance(node.value, ast.Attribute)
        and node.value.attr == "mark"
        and isinstance(node.value.value, ast.Name)
        and node.value.value.id == "pytest"
        and node.attr in GROUPS
    ):
        return node.attr
    return None


def _module_groups(tree):
    """Groups named by the module-level ``pytestmark`` assignment(s)."""
    groups = []
    for stmt in tree.body:
        if not isinstance(stmt, ast.Assign):
            continue
        if not any(isinstance(t, ast.Name) and t.id == "pytestmark" for t in stmt.targets):
            continue
        value = stmt.value
        elements = value.elts if isinstance(value, (ast.List, ast.Tuple)) else [value]
        for element in elements:
            node = element.func if isinstance(element, ast.Call) else element
            group = _group_of_mark(node)
            if group:
                groups.append(group)
    return groups


def check_pytest_modules(dirs):
    """Return one error string per module that is not in exactly one group."""
    errors = []
    for path in pytest_modules(dirs):
        tree = ast.parse(path.read_text(), filename=str(path))
        groups = _module_groups(tree)
        if not groups:
            errors.append(
                f"{path}: no group; add `pytestmark = pytest.mark.<group>` "
                f"(one of {', '.join(GROUPS)})"
            )
        elif len(set(groups)) != 1 or len(groups) != 1:
            errors.append(
                f"{path}: belongs to {sorted(set(groups))}; a test module "
                "belongs to exactly one group"
            )
        module_level = {id(n) for stmt in tree.body if isinstance(stmt, ast.Assign) for n in ast.walk(stmt)}
        for node in ast.walk(tree):
            if id(node) in module_level:
                continue
            if _group_of_mark(node):
                errors.append(
                    f"{path}:{node.lineno}: group marker `{node.attr}` is "
                    "only allowed at module level (pytestmark)"
                )
    return errors


# -- bats ---------------------------------------------------------------------


def bats_specs(directory):
    """Every ``*.bats`` file directly under the directory, sorted."""
    return sorted(Path(directory).glob("*.bats"))


def _split_tags(raw):
    return [t.strip() for t in raw.split(",") if t.strip()]


def bats_file_groups(path):
    """Group names in the spec's ``file_tags`` lines (empty if none)."""
    groups = []
    for line in Path(path).read_text().splitlines():
        match = _FILE_TAGS_RE.match(line)
        if match:
            groups.extend(t for t in _split_tags(match.group(1)) if t in GROUPS)
    return groups


def check_bats(directory):
    """Return one error string per spec that is not in exactly one group."""
    errors = []
    for path in bats_specs(directory):
        text = path.read_text().splitlines()
        has_file_tags = any(_FILE_TAGS_RE.match(line) for line in text)
        groups = bats_file_groups(path)
        if not groups:
            errors.append(
                f"{path}: no group; add `# bats file_tags=<group>` "
                f"(file_tags, one of {', '.join(GROUPS)})"
                if not has_file_tags
                else f"{path}: file_tags names no group (one of {', '.join(GROUPS)})"
            )
        elif len(groups) != 1:
            errors.append(
                f"{path}: belongs to {sorted(set(groups))}; a spec belongs to exactly one group"
            )
        for lineno, line in enumerate(text, 1):
            match = _TEST_TAGS_RE.match(line)
            if match and any(t in GROUPS for t in _split_tags(match.group(1))):
                errors.append(
                    f"{path}:{lineno}: a group may only be set with file_tags, not test_tags"
                )
    return errors


def count_bats(directory):
    """``@test`` count per group; every group key is present."""
    counts = {g: 0 for g in GROUPS}
    for path in bats_specs(directory):
        groups = bats_file_groups(path)
        if len(groups) != 1:
            continue
        n = sum(1 for line in path.read_text().splitlines() if _BATS_TEST_RE.match(line))
        counts[groups[0]] += n
    return counts


# -- baseline / TEST.md -------------------------------------------------------


def read_baseline(path):
    """Parse ``KEY = N`` lines of the baseline file (comments ignored)."""
    values = {}
    for line in Path(path).read_text().splitlines():
        match = re.match(r"^\s*([A-Z0-9_]+)\s*=\s*(\d+)\b", line)
        if match:
            values[match.group(1)] = int(match.group(2))
    return values


def parse_test_md_groups(path):
    """Rows of the 'Tests by group' table: ``{group: {bats, hosted, gpu}}``."""
    rows = {}
    for line in Path(path).read_text().splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) == 5 and cells[0] in GROUPS and all(c.isdigit() for c in cells[1:]):
            rows[cells[0]] = {
                "bats": int(cells[1]),
                "hosted": int(cells[2]),
                "gpu": int(cells[3]),
                "total": int(cells[4]),
            }
    missing = [g for g in GROUPS if g not in rows]
    if missing:
        raise ValueError(f"{path}: 'Tests by group' table lacks rows for {missing}")
    return rows


def main(argv):
    command = argv[1] if len(argv) > 1 else "check"
    if command == "check":
        errors = check_pytest_modules(_PYTEST_DIRS) + check_bats(_BATS_DIR)
        for error in errors:
            print(error, file=sys.stderr)
        if errors:
            return 1
        print("OK: every test belongs to exactly one group")
        return 0
    if command == "counts":
        print(json.dumps(count_bats(_BATS_DIR), indent=2))
        return 0
    print(f"usage: {argv[0]} check|counts", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
