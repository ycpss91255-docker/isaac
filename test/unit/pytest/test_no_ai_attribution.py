"""Contract for the PR commit AI-attribution check (isaac#413).

The local hooks only see what an agent types on this machine. A commit that
reaches a PR branch another way, or the message GitHub assembles at merge
time, is invisible to them; main carried one such `Co-authored-by: Claude`
trailer (commit 52978e2) and the repo's Contributors list showed it. CI is the
only place that sees every commit of the PR, so the check lives there.

The script reads `git log` records on stdin (or runs git for a revision
range), so these tests feed records directly and need no git binary in the
slim hosted-unit container.
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.docs

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPT = _REPO_ROOT / "script" / "ci" / "check_no_ai_attribution.py"

_FS = "\x1f"
_RS = "\x1e"
_USER = ("cyc", "54975526+ycpss91255@users.noreply.github.com")


def _load():
    spec = importlib.util.spec_from_file_location("check_no_ai_attribution", _SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _record(sha, message, author=_USER, committer=_USER):
    fields = [sha, author[0], author[1], committer[0], committer[1], message]
    return _FS.join(fields) + _RS


def _run(stdin_text):
    return subprocess.run(
        [sys.executable, str(_SCRIPT), "--stdin"],
        input=stdin_text,
        capture_output=True,
        text=True,
        check=False,
    )


def test_clean_commit_exits_zero():
    result = _run(_record("a" * 40, "fix(ci): ordinary change\n\nbody text"))
    assert result.returncode == 0, result.stderr


def test_co_authored_by_anthropic_email_fails_and_prints_sha():
    sha = "b" * 40
    message = (
        "feat: x\n\nCo-authored-by: Claude Opus 4.8 <noreply@anthropic.com>\n"
    )
    result = _run(_record(sha, message))
    assert result.returncode != 0
    assert sha in result.stderr + result.stdout


def test_co_authored_by_claude_name_with_other_email_fails():
    result = _run(_record("c" * 40, "x\n\nCo-authored-by: Claude <a@b.c>\n"))
    assert result.returncode != 0


def test_generated_with_claude_code_fails_case_insensitive():
    result = _run(_record("d" * 40, "x\n\ngenerated WITH claude code\n"))
    assert result.returncode != 0


def test_claude_session_trailer_fails():
    result = _run(_record("e" * 40, "x\n\nClaude-Session: abc123\n"))
    assert result.returncode != 0


def test_anthropic_author_email_fails():
    bot = ("Claude", "noreply@anthropic.com")
    result = _run(_record("f" * 40, "clean message", author=bot))
    assert result.returncode != 0


def test_anthropic_committer_email_fails():
    bot = ("someone", "noreply@anthropic.com")
    result = _run(_record("1" * 40, "clean message", committer=bot))
    assert result.returncode != 0


def test_mentioning_claude_without_attribution_form_passes():
    # A bare word is not attribution; only the trailer / marker forms are.
    result = _run(_record("2" * 40, "docs: explain the claude.md layout"))
    assert result.returncode == 0, result.stderr


def test_reports_every_offending_commit():
    bad = "Co-authored-by: Claude <noreply@anthropic.com>"
    stdin = _record("3" * 40, "a\n\n" + bad) + _record("4" * 40, "ok") + _record(
        "5" * 40, "b\n\n" + bad
    )
    result = _run(stdin)
    assert result.returncode != 0
    assert "3" * 40 in result.stderr and "5" * 40 in result.stderr
    assert "4" * 40 not in result.stderr


def test_find_violations_returns_sha_and_reason():
    module = _load()
    commits = module.parse_log(_record("6" * 40, "x\n\nClaude-Session: z"))
    found = module.find_violations(commits)
    assert [sha for sha, _ in found] == ["6" * 40]
