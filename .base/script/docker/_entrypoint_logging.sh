#!/usr/bin/env bash
# _entrypoint_logging.sh -- host-side log tee helper for #328 local_path.
#
# Source this from a repo's `script/entrypoint.sh` so container stdout/
# stderr is duplicated to the host-side file mounted via the [logging]
# `local_path` setup.conf key. The tee preserves the original stdout
# stream, so `docker logs <container>` continues to return identical
# content -- this is "host file is current run, daemon json keeps
# rolling history" rather than a hijack.
#
# Contract with setup.sh (the compose-emit side):
#   - When [logging] / [logging.<svc>] local_path is set, setup.sh
#     emits `LOG_FILE_PATH=/var/log/<repo>/<svc>.log` into the
#     service's `environment:` block AND a `<host>:/var/log/<repo>`
#     bind mount under `volumes:`.
#   - When local_path is unset, neither line is emitted; this helper
#     becomes a no-op when sourced -- safe to drop into every repo
#     entrypoint regardless of whether the repo opts in.
#
# Behaviour when LOG_FILE_PATH is set:
#   1. `mkdir -p $(dirname LOG_FILE_PATH)` so the file's parent exists
#      (the bind-mounted /var/log/<repo> directory should already
#      exist from the host side, but defensive in case the entrypoint
#      runs before the bind takes effect).
#   2. Truncate the file (`: > $LOG_FILE_PATH`) so a fresh container
#      start gives a fresh log -- matches `docker logs` ephemerality
#      (new container = new json-file).
#   3. `exec > >(tee -a $LOG_FILE_PATH) 2>&1` -- redirects shell
#      stdout + stderr through tee. tee writes to the file and echoes
#      to its own stdout, which becomes the new shell stdout (still
#      captured by Docker for `docker logs`).
#
# Failure modes (all non-fatal -- entrypoint continues without tee):
#   - LOG_FILE_PATH unset/empty -> no-op
#   - mkdir / truncate fails (permission, FS readonly) -> warn, no-op
#   - tee binary missing -> warn, no-op (BusyBox-based minimal images
#     should still have it; warn covers the edge case)
#
# Usage (downstream `script/entrypoint.sh`):
#   #!/usr/bin/env bash
#   set -euo pipefail
#   # shellcheck source=/dev/null
#   . /usr/local/lib/base/_entrypoint_logging.sh
#   exec "$@"
#
# Why the in-image path (#368, supersedes the PR #356 example that
# tried to source the helper through the workspace bind mount via
# the entrypoint user's `$HOME` and the `.base/` subtree):
#   - `USER` is unset in the Dockerfile test stage (no login env),
#     so the old source-line crashed `set -u` entrypoints during
#     build-time bats smoke with `USER: unbound variable`.
#   - On multi-repo workspace layouts (the org-wide norm), the
#     workspace bind mount maps the workspace parent dir into the
#     container, so the repo's `.base/` subtree lives one extra
#     directory deeper than the original example assumed and the
#     runtime tee silently never wrote the host-side log file.
#   - The helper is COPY'd into /usr/local/lib/base/ by
#     Dockerfile.example's devel stage, so the source-line works the
#     same at build-time, runtime, and across every workspace layout
#     with no `$USER` deref or path arithmetic.

# Allow safe sourcing under any shell mode. We don't propagate strict
# mode locally because the caller may set its own and we shouldn't
# override.
_entrypoint_logging_setup() {
  local _path="${LOG_FILE_PATH:-}"
  [[ -z "${_path}" ]] && return 0
  local _dir
  _dir="$(dirname -- "${_path}")"
  if ! mkdir -p -- "${_dir}" 2>/dev/null; then
    printf '[entrypoint-logging] WARN: cannot create %s, skipping tee\n' \
      "${_dir}" >&2
    return 0
  fi
  if ! : > "${_path}" 2>/dev/null; then
    printf '[entrypoint-logging] WARN: cannot write %s, skipping tee\n' \
      "${_path}" >&2
    return 0
  fi
  if ! command -v tee >/dev/null 2>&1; then
    printf '[entrypoint-logging] WARN: tee binary missing, skipping tee\n' >&2
    return 0
  fi
  # The actual redirection must run in the caller's shell context
  # (exec rebinds the caller's stdout/stderr), so we exit here and
  # the caller does the exec. We signal "OK to tee" via return 0
  # with a side-channel global so the caller can branch.
  _ENTRYPOINT_LOGGING_READY=1
  _ENTRYPOINT_LOGGING_PATH="${_path}"
  return 0
}

# Run setup, then -- if ready -- rebind stdout/stderr through tee in
# the caller's shell. `exec > >(...)` cannot live inside a function
# (the redirection ends with the function's subshell), so we keep
# the rebind here at source-time.
_entrypoint_logging_setup
if [[ "${_ENTRYPOINT_LOGGING_READY:-0}" == "1" ]]; then
  # shellcheck disable=SC2094  # tee both writes to file and echoes to stdout
  exec > >(tee -a -- "${_ENTRYPOINT_LOGGING_PATH}") 2>&1
fi
