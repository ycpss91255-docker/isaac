"""Regression guard for Makefile.local docker-logs redirect (#75).

With pid=host (compose.yaml `pid: ${PID_MODE}`, .env PID_MODE=host) the
container shares the host PID namespace. Inside the container,
`/proc/1/fd/{1,2}` then point at the host's PID 1 (systemd), not at the
container's PID 1 (sleep infinity). Writes get rejected with EPERM, so
`docker logs <isaac>` stays empty and lazydocker / `docker logs -f` show
nothing while Isaac Sim is actually running.

The fix resolves the container PID 1's host-side PID at run time via
`docker inspect --format '{{.State.Pid}}'` and redirects through
`/proc/$(CONTAINER_PID1)/fd/{1,2}`, which the container is allowed to
write to and which Docker captures into the log pipe.
"""

from pathlib import Path

MAKEFILE_LOCAL = Path(__file__).resolve().parents[3] / "Makefile.local"


def test_no_proc_1_fd_redirect_under_pid_host() -> None:
    text = MAKEFILE_LOCAL.read_text()
    assert "/proc/1/fd/" not in text, (
        "Makefile.local must not redirect to /proc/1/fd/* — under pid=host "
        "that path points at host systemd, not the container's PID 1. Writes "
        "fail with EPERM, so `docker logs` and lazydocker stay empty while "
        "Isaac Sim is running. Use /proc/$(CONTAINER_PID1)/fd/* instead."
    )


def test_container_pid1_resolved_via_state_pid() -> None:
    text = MAKEFILE_LOCAL.read_text()
    assert "CONTAINER_PID1" in text, (
        "Expected a CONTAINER_PID1 make variable in Makefile.local that "
        "captures the container's host-side PID 1 for the FD redirect."
    )
    assert "State.Pid" in text, (
        "Expected CONTAINER_PID1 to be resolved via "
        "`docker inspect ... --format '{{.State.Pid}}'`."
    )
