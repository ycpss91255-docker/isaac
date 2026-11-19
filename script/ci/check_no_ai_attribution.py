#!/usr/bin/env python3
"""Fail when a commit in a PR range carries an AI attribution (isaac#413).

Usage:
  check_no_ai_attribution.py <base>..<head>   # runs git log over the range
  git log --format=... | check_no_ai_attribution.py --stdin

Checked per commit: the message, author name/email, committer name/email.
Patterns (case-insensitive): a Co-authored-by trailer naming Claude or an
anthropic.com address, "Generated with Claude Code", a Claude-Session
trailer, and any author / committer address at anthropic.com.

Commits already on the base branch are outside the range and are not
examined.
"""

import argparse
import re
import subprocess
import sys

FIELD_SEP = "\x1f"
RECORD_SEP = "\x1e"
GIT_FORMAT = FIELD_SEP.join(["%H", "%an", "%ae", "%cn", "%ce", "%B"]) + RECORD_SEP

_MESSAGE_PATTERNS = (
    ("Co-authored-by trailer naming Claude or anthropic.com",
     re.compile(r"^\s*co-authored-by:.*(claude|anthropic\.com)", re.I | re.M)),
    ("Generated with Claude Code",
     re.compile(r"generated with \[?claude code", re.I)),
    ("Claude-Session trailer",
     re.compile(r"^\s*claude-session:", re.I | re.M)),
)
_IDENTITY_PATTERN = re.compile(r"@anthropic\.com\b", re.I)


def parse_log(text):
    """Parse GIT_FORMAT output into a list of commit dicts."""
    commits = []
    for record in text.split(RECORD_SEP):
        record = record.strip("\n")
        if not record:
            continue
        sha, an, ae, cn, ce, message = record.split(FIELD_SEP, 5)
        commits.append({"sha": sha.strip(), "author": (an, ae),
                        "committer": (cn, ce), "message": message})
    return commits


def find_violations(commits):
    """Return [(sha, reason)] for every offending commit."""
    found = []
    for commit in commits:
        reason = None
        for label, pattern in _MESSAGE_PATTERNS:
            if pattern.search(commit["message"]):
                reason = label
                break
        if reason is None:
            for role in ("author", "committer"):
                if _IDENTITY_PATTERN.search(commit[role][1]):
                    reason = f"{role} address at anthropic.com"
                    break
        if reason is not None:
            found.append((commit["sha"], reason))
    return found


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("range", nargs="?", help="git revision range, base..head")
    parser.add_argument("--stdin", action="store_true",
                        help="read git log records from stdin")
    args = parser.parse_args(argv)
    if args.stdin:
        text = sys.stdin.read()
    elif args.range:
        proc = subprocess.run(["git", "log", f"--format={GIT_FORMAT}", args.range],
                              capture_output=True, text=True, check=False)
        if proc.returncode != 0:
            print(f"error: git log {args.range} failed: {proc.stderr.strip()}",
                  file=sys.stderr)
            return 2
        text = proc.stdout
    else:
        parser.error("give a revision range or --stdin")
    violations = find_violations(parse_log(text))
    for sha, reason in violations:
        print(f"AI attribution in commit {sha}: {reason}", file=sys.stderr)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
