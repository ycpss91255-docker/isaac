#!/usr/bin/env bash
#
# _tui_backend.sh — dialog / whiptail abstraction.
#
# After _backend_detect succeeds, ${TUI_BACKEND} holds the selected binary
# name ("dialog" or "whiptail"). All wrapper functions:
#   * write the user's selection to stdout (not stderr, not the TTY)
#   * return 0 on confirm, non-zero on cancel / Esc / missing backend
#
# Style: Google Shell Style Guide.

if [[ -n "${_DOCKER_TUI_BACKEND_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_TUI_BACKEND_SOURCED=1

TUI_BACKEND=""
TUI_HEIGHT="${TUI_HEIGHT:-20}"
TUI_WIDTH="${TUI_WIDTH:-70}"

# _backend_detect
#
# Sets ${TUI_BACKEND} to "dialog" or "whiptail" (preferring dialog).
# If neither is available prints an install hint to stderr and returns 2.
_backend_detect() {
  if command -v dialog >/dev/null 2>&1; then
    TUI_BACKEND="dialog"
    return 0
  fi
  if command -v whiptail >/dev/null 2>&1; then
    TUI_BACKEND="whiptail"
    return 0
  fi
  printf "[tui] ERROR: neither 'dialog' nor 'whiptail' is installed.\n" >&2
  printf "[tui] Install one with: sudo apt install dialog\n" >&2
  return 2
}

# _tui_guard
#
# Ensures ${TUI_BACKEND} is set. Callers use `_tui_guard || return $?`.
_tui_guard() {
  if [[ -z "${TUI_BACKEND}" ]]; then
    printf "[tui] ERROR: backend not initialized. Call _backend_detect first.\n" >&2
    return 2
  fi
}

# _tui_msgbox <title> <message>
_tui_msgbox() {
  _tui_guard || return $?
  "${TUI_BACKEND}" --title "${1}" --msgbox "${2}" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}

# _tui_yesno <title> <message>
#
# Returns 0 on Yes, 1 on No, non-zero on Esc.
_tui_yesno() {
  _tui_guard || return $?
  "${TUI_BACKEND}" --title "${1}" --yesno "${2}" "${TUI_HEIGHT}" "${TUI_WIDTH}"
}

# _tui_run <dialog-args...>
#
# Internal helper. dialog/whiptail draw the UI via curses on the
# controlling terminal. Callers typically invoke this inside a command
# substitution ($(…)), which replaces the child's stdout with a pipe —
# dialog then detects stdout is not a TTY and may refuse to draw. We
# reattach stdin/stdout to /dev/tty (when available) so the UI renders
# regardless of how the caller captures our stdout; the selection
# result is routed via --output-fd 3 into a temp file that we echo
# back on stdout afterwards.
_tui_run() {
  local _tmp _rc=0
  _tmp="$(mktemp)"
  # Session-level OK / Cancel button i18n (env var hooks). Applied to
  # every dialog/whiptail invocation so sub-menus inherit the label the
  # main menu set up.
  #
  # dialog and whiptail spell these flags differently:
  #   dialog   uses --ok-label / --cancel-label
  #   whiptail uses --ok-button / --cancel-button (rejects --*-label)
  # Translate the spelling here so callers stay backend-agnostic and
  # whiptail-only hosts (Ubuntu 22.04 minimal, Jetson arm64) don't abort
  # with `--ok-label: unknown option` on the very first menu (#136).
  local _ok_flag="--ok-label" _cancel_flag="--cancel-label"
  if [[ "${TUI_BACKEND}" == "whiptail" ]]; then
    _ok_flag="--ok-button"
    _cancel_flag="--cancel-button"
  fi
  local -a _labels=()
  [[ -n "${TUI_OK_LABEL:-}" ]]     && _labels+=("${_ok_flag}"     "${TUI_OK_LABEL}")
  [[ -n "${TUI_CANCEL_LABEL:-}" ]] && _labels+=("${_cancel_flag}" "${TUI_CANCEL_LABEL}")
  # Reattach to /dev/tty only when the caller is actually running inside
  # an interactive terminal (stdin is a TTY). In bats / non-interactive
  # containers /dev/tty may exist but opening it fails; -t 0 is the
  # reliable signal that a real TTY is available.
  if [[ -t 0 ]]; then
    "${TUI_BACKEND}" "${_labels[@]}" --output-fd 3 "$@" \
      3>"${_tmp}" </dev/tty >/dev/tty || _rc=$?
  else
    "${TUI_BACKEND}" "${_labels[@]}" --output-fd 3 "$@" 3>"${_tmp}" || _rc=$?
  fi
  cat "${_tmp}"
  rm -f "${_tmp}"
  return "${_rc}"
}

# _tui_inputbox <title> <prompt> [initial]
_tui_inputbox() {
  _tui_guard || return $?
  _tui_run --title "${1}" --inputbox "${2}" \
    "${TUI_HEIGHT}" "${TUI_WIDTH}" "${3:-}"
}

# _tui_menu <title> <prompt> <tag1> <label1> [<tag2> <label2> ...]
#
# Env var hooks (all optional):
#   TUI_OK_LABEL / TUI_CANCEL_LABEL — handled globally in `_tui_run`
#   TUI_NO_TAGS — when set, hide the tag column (`--no-tags`)
# Return codes:
#   0 → OK (echoed tag is the selected menu entry)
#   1 → Cancel
#   Other non-zero → Esc or backend error
#
# Note: the legacy `TUI_EXTRA_LABEL` hook (which forwarded
# `--extra-button --extra-label` on dialog and produced exit 3) was
# removed in #178. dialog supported it; whiptail did not (newt has no
# third button at all). The UX divergence broke shared screenshots and
# docs, so callers now inject a synthetic menu entry (e.g. `__save`)
# instead, giving identical layout across backends.
_tui_menu() {
  _tui_guard || return $?
  local _title="${1}" _prompt="${2}"; shift 2
  local _n_items=$(( $# / 2 ))
  local -a _extra_args=()
  if [[ -n "${TUI_NO_TAGS:-}" ]]; then
    # Hide the tag column (keeps the tag as the return value, but only
    # labels render on-screen — useful for list editors where the tag
    # is an internal id like `mount_1` / `rule_1`).
    _extra_args+=(--no-tags)
  fi
  _tui_run "${_extra_args[@]}" --title "${_title}" --menu "${_prompt}" \
    "${TUI_HEIGHT}" "${TUI_WIDTH}" "${_n_items}" "$@"
}

# _tui_radiolist <title> <prompt> <tag1> <label1> <on1> [<tag2> <label2> <on2> ...]
_tui_radiolist() {
  _tui_guard || return $?
  local _title="${1}" _prompt="${2}"; shift 2
  local _n_items=$(( $# / 3 ))
  _tui_run --title "${_title}" --radiolist "${_prompt}" \
    "${TUI_HEIGHT}" "${TUI_WIDTH}" "${_n_items}" "$@"
}

# _tui_select <title> <prompt> <tag1> <label1> <on1> [<tag2> <label2> <on2> ...]
#
# Single-choice selector implemented via --menu so that pressing Enter
# immediately submits the cursor item — no need for the user to press
# Space first (which was --radiolist's footgun). The current tag
# (on=ON) gets a leading "* " in its label; others get "  ", and
# `--default-item <tag>` makes the cursor start at the current value
# so pressing Enter without moving preserves the existing choice.
_tui_select() {
  _tui_guard || return $?
  local _title="${1}" _prompt="${2}"; shift 2
  local -a _menu_args=()
  local _default_tag=""
  while (( $# >= 3 )); do
    local _tag="${1}" _label="${2}" _state="${3}"; shift 3
    if [[ "${_state}" == "ON" ]]; then
      _default_tag="${_tag}"
      _menu_args+=("${_tag}" "* ${_label}")
    else
      _menu_args+=("${_tag}" "  ${_label}")
    fi
  done
  local _n_items=$(( ${#_menu_args[@]} / 2 ))
  local -a _dflt_args=()
  [[ -n "${_default_tag}" ]] && _dflt_args=(--default-item "${_default_tag}")
  # Bypass _tui_menu so sub-section selectors are pure --menu calls.
  # OK/Cancel labels still apply via _tui_run.
  _tui_run "${_dflt_args[@]}" --title "${_title}" --menu "${_prompt}" \
    "${TUI_HEIGHT}" "${TUI_WIDTH}" "${_n_items}" "${_menu_args[@]}"
}

# _tui_checklist <title> <prompt> <tag1> <label1> <on1> [<tag2> <label2> <on2> ...]
_tui_checklist() {
  _tui_guard || return $?
  local _title="${1}" _prompt="${2}"; shift 2
  local _n_items=$(( $# / 3 ))
  _tui_run --separate-output --title "${_title}" --checklist \
    "${_prompt}" "${TUI_HEIGHT}" "${TUI_WIDTH}" "${_n_items}" "$@"
}

# _tui_clear
#
# Returns the terminal to a clean state after TUI use.
_tui_clear() {
  if command -v clear >/dev/null 2>&1; then
    clear
  fi
}
