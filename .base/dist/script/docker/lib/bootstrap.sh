#!/usr/bin/env bash
#
# bootstrap.sh - shared wrapper preamble (sub-task A).
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
#   - <repo>/build.sh                      # root-symlink
#   - <repo>/script/build.sh               # script/ subfolder
#   - <repo>/.base/dist/script/docker/wrapper/build.sh  # direct
#   - /lint/build.sh  (+ /lint/lib)       # Dockerfile lint stage (COPY)
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
# `-C/--chdir` override, then sources _lib.sh + the wrapper runtime.
# Call as `_bootstrap "$@"` from the wrapper's file scope. The wrapper's
# own BASH_SOURCE frame (used for FILE_PATH detection + the error tag) is
# located by skipping this file's own frames, so the resolution does not
# break if _bootstrap is ever reached through an extra call layer.
#
# Exit codes: `-C/--chdir` argument errors exit 2 (usage error); a
# missing _lib.sh exits 1 (runtime/install error). (sub-task C.)
_bootstrap() {
  # Find the caller wrapper's source: the first BASH_SOURCE frame above
  # this one that is not bootstrap.sh itself (robust against an extra
  # call layer between the wrapper and _bootstrap).
  local _self="${BASH_SOURCE[0]:-$0}"
  local _caller="" _frame
  for _frame in "${BASH_SOURCE[@]:1}"; do
    if [[ "${_frame}" != "${_self}" ]]; then
      _caller="${_frame}"
      break
    fi
  done
  # Last resorts, in order: the immediate caller frame, then $0. Both
  # defaults are load-bearing -- reached from a top-level context there is
  # no frame 1 at all, and an unguarded read would abort the wrapper under
  # the nounset it just enabled.
  : "${_caller:=${BASH_SOURCE[1]:-$0}}"

  local _tag
  _tag="$(basename -- "${_caller}" .sh)"

  # FILE_PATH default: derive the repo root from the wrapper's
  # invocation directory. If that dir has a .base/ sibling we are at the
  # root; if its parent does we are one level deeper (script/ subfolder);
  # if a sibling lib/_lib.sh exists we are in a direct/.base layout one
  # level above lib/; otherwise fall back to the invocation dir (lint).
  local _invoke_dir
  _invoke_dir="$(cd -- "$(dirname -- "${_caller}")" && pwd -P)"
  if [[ -d "${_invoke_dir}/.base" ]]; then
    FILE_PATH="${_invoke_dir}"
  elif [[ -d "${_invoke_dir}/../.base" ]]; then
    FILE_PATH="$(cd -- "${_invoke_dir}/.." && pwd -P)"
  elif [[ -f "${_invoke_dir}/../lib/_lib.sh" ]]; then
    FILE_PATH="$(cd -- "${_invoke_dir}/.." && pwd -P)"
  elif [[ -f "${_invoke_dir}/dist/script/docker/lib/_lib.sh" ]]; then
    # base self-use (root-symlink): base IS the template source, so it has
    # no .base/ subtree -- it ships dist/ at the repo root and uses the very
    # wrapper it ships (ADR-00000011 sec.4).
    FILE_PATH="${_invoke_dir}"
  elif [[ -f "${_invoke_dir}/../dist/script/docker/lib/_lib.sh" ]]; then
    # base self-use (script/ subfolder): script/build.sh -> ../dist/...
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

  # expose the verb (wrapper basename) so transcript.sh, sourced
  # via _lib.sh, can classify it. Only build/setup/stop/prune/upgrade are
  # captured; run/exec/setup_tui stay uncaptured in this slice.
  export _WRAPPER_VERB="${_tag}"

  # _lib.sh lives at .base/dist/script/docker/lib/_lib.sh in consumer repos,
  # or alongside the wrapper under lib/ when the Dockerfile lint stage
  # COPYs scripts into /lint/ (all libs live under lib).
  if [[ -f "${FILE_PATH}/.base/dist/script/docker/lib/_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${FILE_PATH}/.base/dist/script/docker/lib/_lib.sh"
  elif [[ -f "${FILE_PATH}/lib/_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "${FILE_PATH}/lib/_lib.sh"
  elif [[ -f "${FILE_PATH}/dist/script/docker/lib/_lib.sh" ]]; then
    # base self-use: no .base/ subtree; the real lib ships under dist/ at
    # the repo root (ADR-00000011 sec.4).
    # shellcheck disable=SC1091
    source "${FILE_PATH}/dist/script/docker/lib/_lib.sh"
  else
    printf '[%s] ERROR: cannot find _lib.sh -- expected one of:\n' "${_tag}" >&2
    printf '  %s\n' "${FILE_PATH}/.base/dist/script/docker/lib/_lib.sh" >&2
    printf '  %s\n' "${FILE_PATH}/lib/_lib.sh" >&2
    printf '  %s\n' "${FILE_PATH}/dist/script/docker/lib/_lib.sh" >&2
    exit 1
  fi

  # Part B: i18n.sh no longer seeds _LANG at source time. Resolve it
  # once here (SETUP_LANG override else $LANG detection) so every wrapper's
  # _msg works during arg parsing; a later --lang flag overrides it via
  # _sanitize_lang. _LANG is global (no `local` declared in this function).
  _resolve_lang _LANG

  # pull in the wrapper-runtime module (shared _msg dispatcher,
  # --lang pre-pass, setup/drift orchestration). It lives alongside this
  # file under lib/, so resolve it from BASH_SOURCE[0] (this bootstrap.sh)
  # rather than re-deriving from the wrapper layout. Sourced last so the
  # full _lib.sh helper set (_log_*, _load_env, _compose_project, ...) it
  # builds on is already in scope.
  local _wrapper_lib
  _wrapper_lib="$(dirname -- "${BASH_SOURCE[0]:-$0}")/wrapper.sh"
  if [[ -f "${_wrapper_lib}" ]]; then
    # shellcheck source=dist/script/docker/lib/wrapper.sh
    source "${_wrapper_lib}"
  fi
}
