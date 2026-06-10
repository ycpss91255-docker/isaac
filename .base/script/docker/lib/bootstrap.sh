#!/usr/bin/env bash
#
# bootstrap.sh - shared wrapper preamble (#408 sub-task A).
#
# Every user-facing wrapper (build / run / exec / stop / prune /
# setup_tui) used to open with the same ~37-line dance: resolve
# FILE_PATH (the repo root) across the four invocation layouts, honor a
# `-C/--chdir DIR` override, then locate + source _lib.sh. That is
# ~185 duplicated lines across the wrappers; this file hoists it into a
# single `_bootstrap "$@"` call.
#
# Invocation layouts covered (FILE_PATH must always resolve to the repo
# root so ${FILE_PATH}/.base, /config, /.env work):
#   - <repo>/build.sh                      # pre-#330 root-symlink
#   - <repo>/script/build.sh               # post-#330 script/ subfolder
#   - <repo>/.base/script/docker/wrapper/build.sh  # direct
#   - /lint/build.sh  (+ /lint/lib/)       # Dockerfile lint stage (COPY)
#
# Locating bootstrap.sh itself: the wrapper resolves its own real path
# (readlink -f follows the consumer-repo symlink) and tries the
# canonical `../lib/` split first, then the flat `/lint` `lib/` sibling.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_BOOTSTRAP_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_BOOTSTRAP_SOURCED=1

# _bootstrap <wrapper args...>
#
# Resolves and `readonly`-locks the global FILE_PATH, applies the
# `-C/--chdir` override, then sources _lib.sh. MUST be called as
# `_bootstrap "$@"` from the wrapper's file scope so BASH_SOURCE[1] is
# the wrapper (used for FILE_PATH detection + the error tag) and "$@"
# carries the wrapper's args (for the -C/--chdir pre-scan).
#
# Exit codes: `-C/--chdir` argument errors exit 2 (usage error); a
# missing _lib.sh exits 1 (runtime/install error). (#408 sub-task C.)
_bootstrap() {
  local _tag
  _tag="$(basename -- "${BASH_SOURCE[1]}" .sh)"

  # FILE_PATH default: derive the repo root from the wrapper's
  # invocation directory. If that dir has a .base/ sibling we are at the
  # root; if its parent does we are one level deeper (script/ subfolder);
  # if a sibling lib/_lib.sh exists we are in a direct/.base layout one
  # level above lib/; otherwise fall back to the invocation dir (/lint).
  local _invoke_dir
  _invoke_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd -P)"
  if [[ -d "${_invoke_dir}/.base" ]]; then
    FILE_PATH="${_invoke_dir}"
  elif [[ -d "${_invoke_dir}/../.base" ]]; then
    FILE_PATH="$(cd -- "${_invoke_dir}/.." && pwd -P)"
  elif [[ -f "${_invoke_dir}/../lib/_lib.sh" ]]; then
    FILE_PATH="$(cd -- "${_invoke_dir}/.." && pwd -P)"
  else
    FILE_PATH="${_invoke_dir}"
  fi

  # -C/--chdir pre-scan: overrides FILE_PATH so the wrapper operates on a
  # different repo without changing the caller's cwd (keeps the top-level
  # command `./build.sh ...` intact for sandbox excludedCommands
  # matching, refs docker_harness#53). Runs before _lib.sh is sourced so
  # every path-dependent op (including the _lib.sh lookup) honors it.
  local _i=1 _next _arg
  while (( _i <= $# )); do
    case "${!_i}" in
      -C|--chdir)
        _next=$(( _i + 1 ))
        if (( _next > $# )) || [[ -z "${!_next:-}" ]]; then
          printf '[%s] ERROR: -C/--chdir requires a value\n' "${_tag}" >&2
          exit 2
        fi
        _arg="${!_next}"
        if [[ ! -d "${_arg}" ]]; then
          printf '[%s] ERROR: -C target is not a directory: %s\n' "${_tag}" "${_arg}" >&2
          exit 2
        fi
        FILE_PATH="$(cd -- "${_arg}" && pwd -P)"
        _i=$(( _next + 1 ))
        ;;
      *)
        _i=$(( _i + 1 ))
        ;;
    esac
  done
  readonly FILE_PATH

  # _lib.sh lives at .base/script/docker/lib/_lib.sh in consumer repos,
  # or alongside the wrapper under lib/ when the Dockerfile lint stage
  # COPYs scripts into /lint/ (#406: all libs live under lib/).
  if [[ -f "${FILE_PATH}/.base/script/docker/lib/_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${FILE_PATH}/.base/script/docker/lib/_lib.sh"
  elif [[ -f "${FILE_PATH}/lib/_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${FILE_PATH}/lib/_lib.sh"
  else
    printf '[%s] ERROR: cannot find _lib.sh -- expected one of:\n' "${_tag}" >&2
    printf '  %s\n' "${FILE_PATH}/.base/script/docker/lib/_lib.sh" >&2
    printf '  %s\n' "${FILE_PATH}/lib/_lib.sh" >&2
    exit 1
  fi
}
