#!/usr/bin/env python3
"""Verdict of the required-check summary job `gate` (isaac#434).

Branch protection requires only `gate`. It runs `always()` after every other
job and reads their results from ``NEEDS_JSON`` (``toJSON(needs)``):

* ``success`` and ``skipped`` pass -- a path-filtered job that did not need to
  run must not hold the required check (GitHub's own guidance);
* ``failure`` / ``cancelled`` fail the gate;
* ``changes`` must have succeeded, or every downstream job was skipped
  because nothing was selected and the gate would pass having checked nothing.

Exit codes: 0 pass, 1 fail, 2 no ``NEEDS_JSON``.
"""

import json
import os
import sys

_PASS = ("success", "skipped")


def evaluate(needs):
    """Return ``(ok, report_lines)`` for a ``needs`` mapping."""
    lines = []
    ok = True
    if not needs:
        return False, ["no upstream jobs: the gate has nothing to judge"]
    if needs.get("changes", {}).get("result") != "success":
        ok = False
        lines.append(
            "FAIL changes: "
            f"{needs.get('changes', {}).get('result', 'missing')} "
            "(scope selection must succeed or nothing was checked)"
        )
    for name in sorted(needs):
        result = needs[name].get("result", "missing")
        if result in _PASS:
            lines.append(f"ok   {name}: {result}")
        elif name != "changes":
            ok = False
            lines.append(f"FAIL {name}: {result}")
    return ok, lines


def main():
    raw = os.environ.get("NEEDS_JSON")
    if not raw:
        print("error: NEEDS_JSON is not set", file=sys.stderr)
        return 2
    ok, lines = evaluate(json.loads(raw))
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
