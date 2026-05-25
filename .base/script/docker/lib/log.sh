#!/usr/bin/env bash
#
# log.sh - Log level helpers (#278).
#
# Three functions for tagged, level-prefixed output with optional ANSI
# color and consistent stream routing. Honor NO_COLOR
# (https://no-color.org/) and auto-disable color on non-TTY destinations.
# FORCE_COLOR=1 overrides auto-detect.
#
# Args (all three log_* functions):
#   $1: tag (short script identifier, e.g. "build", "setup")
#   $2..: message components (joined with spaces)
#
# Stream routing:
#   _log_err / _log_warn -> stderr (fd 2)
#   _log_info            -> stdout (fd 1)
#
# Split out from _lib.sh in #284 so lighter callers (init.sh / upgrade.sh
# / ci.sh) can source just this file without pulling compose / config
# summary surface. The umbrella _lib.sh still sources this and the other
# sub-libs for the build / run / exec / stop full-set callers.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_LOG_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_LOG_SOURCED=1

# _log_color_enabled <fd>
# Returns 0 if color should be emitted to file descriptor <fd>.
_log_color_enabled() {
  local fd="${1:?_log_color_enabled requires fd}"
  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ -n "${FORCE_COLOR:-}" ]] && return 0
  test -t "${fd}"
}

_log_err() {
  local tag="${1:?_log_err requires tag}"
  shift
  if _log_color_enabled 2; then
    printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "${tag}" "$*" >&2
  else
    printf '[%s] ERROR: %s\n' "${tag}" "$*" >&2
  fi
}

_log_warn() {
  local tag="${1:?_log_warn requires tag}"
  shift
  if _log_color_enabled 2; then
    printf '\033[33m[%s] WARNING:\033[0m %s\n' "${tag}" "$*" >&2
  else
    printf '[%s] WARNING: %s\n' "${tag}" "$*" >&2
  fi
}

_log_info() {
  local tag="${1:?_log_info requires tag}"
  shift
  # INFO uses the terminal's default colour — no ANSI wrapping. ERROR
  # and WARNING keep their bright (red bold / yellow) styles because
  # those levels need to draw the user's eye; INFO is the same visual
  # weight as the unstyled summary lines printed by `printf '[%s] ...'`
  # callers (e.g. setup.sh's USER=... GPU=... GUI=... summary), so
  # dimming INFO was an inconsistency that surfaced when users compared
  # the WARNING / INFO / summary lines side-by-side in real terminals.
  printf '[%s] INFO: %s\n' "${tag}" "$*"
}

# _log_plain <tag> <style> <msg...>
#
# Tagged stdout line WITHOUT a level keyword. Wraps the message in ANSI
# iff _log_color_enabled 1 is true AND <style> is non-empty.
#
# <style>: "bold" | "dim" | "" (no color)
#
# Use for structured stdout (config summaries, dividers, section headers)
# where adding "INFO:" to every line would be noise but TTY-aware visual
# weight is still useful. The "[<tag>]" prefix stays unstyled so grep-based
# filtering against the tag is unaffected; only the message bytes change.
_log_plain() {
  local tag="${1:?_log_plain requires tag}"
  local style="${2-}"
  shift 2
  local prefix="" suffix=""
  if _log_color_enabled 1 && [[ -n "${style}" ]]; then
    case "${style}" in
      bold) prefix=$'\033[1m'; suffix=$'\033[0m' ;;
      dim)  prefix=$'\033[2m'; suffix=$'\033[0m' ;;
    esac
  fi
  printf '[%s] %s%s%s\n' "${tag}" "${prefix}" "$*" "${suffix}"
}
