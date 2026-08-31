#!/usr/bin/env bash
# logging.sh -- host-side log tee helper for [logging] local_path.
#
# Source this from a repo's `script/entrypoint.sh` so container stdout/
# stderr is duplicated to the host-side log dir mounted via the
# [logging] `local_path` setup.conf key. The tee preserves the original
# stdout stream, so `docker logs <container>` continues to return
# identical content -- this is "host file is the current run, the daemon
# json-file driver keeps rolling history" rather than a hijack.
#
# Glog-style per-start files + stable symlink (ADR-00000021):
# `LOG_FILE_PATH` is `/var/log/<repo>/<svc>.log`, treated as the STABLE
# SYMLINK. On each container start the helper writes a fresh per-start
# real file `/var/log/<repo>/<svc>_<ts>.log` and repoints the <svc>.log
# symlink at it, so `tail <svc>.log` always follows the current run while
# earlier runs stay on disk (no truncate-on-restart -- run history is
# retained). Old per-start files are pruned by keep-count AND age
# (stricter wins) via the shared runtime/logrotate.sh primitives, the
# same rotate/symlink/prune logic the wrapper transcript uses.
#
# Contract with setup.sh (the compose-emit side):
#   - When [logging] / [logging.<svc>] local_path is set, setup.sh emits
#     into the service's `environment:` block:
#       LOG_FILE_PATH=/var/log/<repo>/<svc>.log   (the stable symlink)
#       CONTAINER_LOG_KEEP=<n>                     (keep-count retention)
#       CONTAINER_LOG_DAYS=<d>                     (age retention, days)
#     plus a `<host>:/var/log/<repo>` bind mount under `volumes:`.
#   - CONTAINER_LOG_KEEP / _DAYS come from the [logging] container_log_keep
#     / container_log_days setup.conf keys (fallback 20 / 14); the helper
#     re-validates them and clamps a non-positive value back to the
#     default, so a hand-edited compose can never wipe every log.
#   - When local_path is unset, none of these are emitted; this helper
#     becomes a no-op when sourced -- safe to drop into every repo
#     entrypoint regardless of whether the repo opts in.
#
# Failure modes (all non-fatal -- entrypoint continues without tee):
#   - LOG_FILE_PATH unset/empty -> no-op
#   - mkdir of the log dir fails (permission, FS readonly) -> warn, no-op
#   - per-start file cannot be written -> warn, no-op
#   - tee binary missing -> warn, no-op
#
# Usage (downstream `script/entrypoint.sh`):
#   #!/usr/bin/env bash
#   set -euo pipefail
#   # shellcheck source=/dev/null
#   . /usr/local/lib/base/logging.sh
#   exec "$@"
#
# The helper is COPY'd into the image at /usr/local/lib/base/logging.sh
# (with its sibling logrotate.sh) by the Dockerfile's devel stage, so the
# source line works the same at build-time, runtime, and across every
# workspace layout with no `$USER` deref or path arithmetic.

# Shared glog-style rotate/symlink/prune primitives. Sourced from
# the sibling path so it works both in-image (/usr/local/lib/base/) and
# from the source tree (bats unit specs). Defensive: a missing helper
# (e.g. a partially-upgraded downstream image) must not abort a caller
# running under `set -e` -- the tee then degrades without rotation/prune.
_logging_helper_dir="$(dirname -- "${BASH_SOURCE[0]:-$0}")"
if [[ -r "${_logging_helper_dir}/logrotate.sh" ]]; then
  # shellcheck source=dist/script/docker/runtime/logrotate.sh
  . "${_logging_helper_dir}/logrotate.sh"
fi
unset _logging_helper_dir

# Allow safe sourcing under any shell mode. We don't propagate strict
# mode locally because the caller may set its own and we shouldn't
# override.
_entrypoint_logging_setup() {
  local _link_path="${LOG_FILE_PATH:-}"
  [[ -z "${_link_path}" ]] && return 0

  local _dir _base _stem
  _dir="$(dirname -- "${_link_path}")"
  _base="$(basename -- "${_link_path}")"   # <svc>.log (the stable symlink)
  _stem="${_base%.log}"                    # <svc>
  if ! mkdir -p -- "${_dir}" 2>/dev/null; then
    printf '[entrypoint-logging] WARN: cannot create %s, skipping tee\n' \
      "${_dir}" >&2
    return 0
  fi

  # Per-start real file: <svc>_<ts>.log alongside the stable symlink. The
  # timestamp is second-granular, so two starts in the SAME wall-clock
  # second (a crash-loop restart with sub-second backoff) would resolve to
  # the same path and the second would TRUNCATE the first run's file --
  # reintroducing the truncate-on-restart footgun. Guard it: if the name is
  # already taken, probe a `-<n>` suffix so each start keeps its own file
  # (the disambiguator the transcript gets from its <ts>-<traceid8> shape).
  local _ts _real
  _ts="$(date -u '+%Y%m%dT%H%M%SZ' 2>/dev/null || printf 'unknown')"
  _real="${_dir}/${_stem}_${_ts}.log"
  local _seq=1
  while [[ -e "${_real}" ]]; do
    _real="${_dir}/${_stem}_${_ts}-${_seq}.log"
    _seq=$(( _seq + 1 ))
  done
  if ! : > "${_real}" 2>/dev/null; then
    printf '[entrypoint-logging] WARN: cannot write %s, skipping tee\n' \
      "${_real}" >&2
    return 0
  fi
  if ! command -v tee >/dev/null 2>&1; then
    printf '[entrypoint-logging] WARN: tee binary missing, skipping tee\n' >&2
    return 0
  fi

  # Glog-style: point the stable <svc>.log symlink at this run's file, then
  # prune old per-start files by keep-count AND age (stricter wins). Both
  # reuse the shared logrotate primitives; guard on their presence so a
  # partially-upgraded image still tees (just without rotation/prune).
  if declare -F _logrotate_repoint >/dev/null 2>&1; then
    _logrotate_repoint "${_real}" "${_base}"
  fi
  if declare -F _logrotate_prune >/dev/null 2>&1; then
    # Retention knobs from compose (from the [logging] container_log_* keys)
    # with fallback defaults; clamp a non-positive hand-edit back to the
    # default so prune can never wipe every log (mirrors transcript.sh).
    local _keep="${CONTAINER_LOG_KEEP:-20}" _days="${CONTAINER_LOG_DAYS:-14}"
    [[ "${_keep}" =~ ^[1-9][0-9]*$ ]] || _keep=20
    [[ "${_days}" =~ ^[1-9][0-9]*$ ]] || _days=14
    _logrotate_prune "${_dir}" "${_base}" "${_keep}" "${_days}"
  fi

  # The actual redirection must run in the caller's shell context (exec
  # rebinds the caller's stdout/stderr), so we exit here and the caller
  # does the exec. Signal "OK to tee" via return 0 with side-channel
  # globals so the caller can branch.
  _ENTRYPOINT_LOGGING_READY=1
  _ENTRYPOINT_LOGGING_PATH="${_real}"
  return 0
}

# Run setup, then -- if ready -- rebind stdout/stderr through tee in the
# caller's shell. `exec > >(...)` cannot live inside a function (the
# redirection ends with the function's subshell), so we keep the rebind
# here at source-time. The tee target is the per-start real file; the
# <svc>.log symlink (repointed above) resolves to it for `tail`/`docker
# logs` parity.
_entrypoint_logging_setup
if [[ "${_ENTRYPOINT_LOGGING_READY:-0}" == "1" ]]; then
  # shellcheck disable=SC2094  # tee both writes to file and echoes to stdout
  exec > >(tee -a -- "${_ENTRYPOINT_LOGGING_PATH}") 2>&1
fi
