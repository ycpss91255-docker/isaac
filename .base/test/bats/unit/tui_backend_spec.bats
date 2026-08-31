#!/usr/bin/env bats
#
# tui_backend_spec.bats — backend detection + stub-driven wrapper tests.
# Uses a fake "dialog" / "whiptail" binary prepended to PATH so we can
# assert exactly which args and positional params reach the backend.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_tui_backend.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  TUI_LOG="${TEMP_DIR}/tui.log"
  export TUI_LOG
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# Fake dialog/whiptail: log argv to TUI_LOG, emit TUI_STUB_RESPONSE on
# fd 3 when `--output-fd 3` is passed (matching _tui_run), falling back
# to stderr otherwise. Exit with TUI_STUB_EXIT (default 0).
_install_stub() {
  local _bin="${1:?}"
  cat > "${MOCK_DIR}/${_bin}" <<'EOF'
#!/bin/bash
: >> "${TUI_LOG}"
for _arg in "$@"; do
  printf '%s\n' "${_arg}" >> "${TUI_LOG}"
done
if printf '%s' "${TUI_STUB_RESPONSE:-}" >&3 2>/dev/null; then
  :
else
  printf '%s' "${TUI_STUB_RESPONSE:-}" >&2
fi
exit "${TUI_STUB_EXIT:-0}"
EOF
  chmod +x "${MOCK_DIR}/${_bin}"
}

# ════════════════════════════════════════════════════════════════════
# _backend_detect
# ════════════════════════════════════════════════════════════════════

@test "_backend_detect picks dialog when present" {
  _install_stub dialog
  _install_stub whiptail
  run _backend_detect
  assert_success
  # Re-source and detect to verify TUI_BACKEND assignment
  _backend_detect
  assert_equal "${TUI_BACKEND}" "dialog"
}

@test "_backend_detect falls back to whiptail when dialog absent" {
  _install_stub whiptail
  run _backend_detect
  assert_success
  _backend_detect
  assert_equal "${TUI_BACKEND}" "whiptail"
}

@test "_backend_detect prints install hint and exits 2 when neither present" {
  # Scrub real dialog/whiptail from PATH too, but keep core utilities reachable
  # so the bats teardown hook (which uses `rm`) still works.
  local _saved_path="${PATH}"
  export PATH="${MOCK_DIR}"  # only MOCK_DIR; no stubs installed
  run _backend_detect
  PATH="${_saved_path}"
  [ "${status}" -eq 2 ]
  assert_output --partial "neither 'dialog' nor 'whiptail'"
  assert_output --partial "apt install dialog"
}

# ════════════════════════════════════════════════════════════════════
# _tui_guard
# ════════════════════════════════════════════════════════════════════

@test "_tui_guard fails when backend not initialized" {
  TUI_BACKEND=""
  run _tui_guard
  [ "${status}" -eq 2 ]
  assert_output --partial "backend not initialized"
}

# ════════════════════════════════════════════════════════════════════
# _tui_inputbox
# ════════════════════════════════════════════════════════════════════

@test "_tui_inputbox passes title, prompt, initial to backend and echoes response" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="user_typed_this"
  run _tui_inputbox "Title" "Prompt?" "init_val"
  assert_success
  assert_output "user_typed_this"
  # Check args reached backend (positional last: initial value)
  run cat "${TUI_LOG}"
  assert_output --partial "--title"
  assert_output --partial "Title"
  assert_output --partial "--inputbox"
  assert_output --partial "Prompt?"
  assert_output --partial "init_val"
}

@test "_tui_inputbox non-zero when backend exits non-zero (cancel)" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_EXIT="1"
  run _tui_inputbox "T" "P"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _tui_menu
# ════════════════════════════════════════════════════════════════════

@test "_tui_menu computes item count and passes tag/label pairs" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="tag2"
  run _tui_menu "Title" "Pick one" tag1 Label1 tag2 Label2 tag3 Label3
  assert_success
  assert_output "tag2"
  run grep -c '^tag' "${TUI_LOG}"
  assert_output "3"
}

@test "_tui_menu never emits --extra-button on dialog even when TUI_EXTRA_LABEL is set (#178)" {
  # — TUI_EXTRA_LABEL is no longer plumbed through to either
  # backend. setup_tui.sh injects a synthetic `__save` menu entry instead,
  # giving identical UX across dialog / whiptail. _tui_menu must therefore
  # ignore TUI_EXTRA_LABEL completely (used to forward `--extra-button` on
  # dialog, kept only as a no-op alias for backwards-compat in env).
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_EXTRA_LABEL="Save & Exit"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA tagB LabelB
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--extra-button"
  refute_output --partial "--extra-label"
  unset TUI_EXTRA_LABEL
}

@test "_tui_menu still omits --extra-button when TUI_EXTRA_LABEL is unset" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  unset TUI_EXTRA_LABEL
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--extra-button"
}

@test "_tui_menu forwards --no-tags when _TUI_NO_TAGS is set" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export _TUI_NO_TAGS=1
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA tagB LabelB
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--no-tags"
  unset _TUI_NO_TAGS
}

@test "_tui_menu omits --no-tags when _TUI_NO_TAGS unset" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  unset _TUI_NO_TAGS
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  run cat "${TUI_LOG}"
  refute_output --partial "--no-tags"
}

@test "_tui_menu forwards --ok-label when _TUI_OK_LABEL set" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export _TUI_OK_LABEL="Enter"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-label"
  assert_output --partial "Enter"
  unset _TUI_OK_LABEL
}

@test "_tui_menu forwards --cancel-label when _TUI_CANCEL_LABEL set" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export _TUI_CANCEL_LABEL="放棄"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--cancel-label"
  assert_output --partial "放棄"
  unset _TUI_CANCEL_LABEL
}

@test "_tui_select marks current tag with '*' and dispatches via --menu" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="private"
  run _tui_select "Title" "Pick" \
    host      "host label"      on \
    private   "private label"   ON \
    shareable "shareable label" off
  assert_success
  assert_output "private"
  run cat "${TUI_LOG}"
  assert_output --partial "--menu"
  refute_output --partial "--radiolist"
  assert_output --partial "* private label"
  assert_output --partial "  host label"
  assert_output --partial "  shareable label"
}

@test "_tui_select passes --default-item with the current ON tag" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="private"
  run _tui_select "Title" "Pick" \
    host    "host"    off \
    private "private" ON \
    none    "none"    off
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--default-item"
  assert_output --partial "private"
}

@test "_tui_run forwards --ok-label / --cancel-label from env vars" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export _TUI_OK_LABEL="進入" _TUI_CANCEL_LABEL="取消"
  export TUI_STUB_RESPONSE=""
  run _tui_run --msgbox "hi" 10 40
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-label"
  assert_output --partial "進入"
  assert_output --partial "--cancel-label"
  assert_output --partial "取消"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
}

@test "_tui_select with no ON item still forwards tags" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="b"
  run _tui_select "T" "P" a "label a" off b "label b" off
  assert_success
  assert_output "b"
}

@test "_tui_menu omits ok-label / cancel-label when env vars unset" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
}

# ════════════════════════════════════════════════════════════════════
# _tui_radiolist
# ════════════════════════════════════════════════════════════════════

@test "_tui_radiolist forwards tag/label/state triples" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE="host"
  run _tui_radiolist "Network" "Mode" host "Host mode" ON bridge "Bridge" off none "None" off
  assert_success
  assert_output "host"
  run grep -cE '^(ON|off)$' "${TUI_LOG}"
  assert_output "3"
}

# ════════════════════════════════════════════════════════════════════
# _tui_checklist
# ════════════════════════════════════════════════════════════════════

@test "_tui_checklist uses --separate-output" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_RESPONSE=$'gpu\nutility'
  run _tui_checklist "GPU caps" "Pick" gpu "Basic" ON compute "Compute" off utility "Utility" ON
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--separate-output"
}

# ════════════════════════════════════════════════════════════════════
# _tui_msgbox / _tui_yesno
# ════════════════════════════════════════════════════════════════════

@test "_tui_msgbox invokes backend with --msgbox" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  run _tui_msgbox "Hi" "Hello there"
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--msgbox"
  assert_output --partial "Hello there"
}

@test "_tui_yesno passes --yesno and returns backend exit code" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_STUB_EXIT="1"
  run _tui_yesno "Confirm" "Really?"
  [ "${status}" -eq 1 ]
  run cat "${TUI_LOG}"
  assert_output --partial "--yesno"
}

# ════════════════════════════════════════════════════════════════════
# whiptail flag-spelling compatibility + Save-button unification
#
# whiptail rejects dialog's --ok-label / --cancel-label spellings (its
# equivalents are --ok-button / --cancel-button). _tui_run translates
# these per ${TUI_BACKEND} so whiptail-only hosts (Ubuntu 22.04 minimal,
# Jetson arm64) don't abort with `unknown option` on the very first menu.
#
# whiptail also has no --extra-button / --extra-label at all (newt
# library limitation). After dialog stops using them too, so the
# Save & Exit affordance lives in the menu body for both backends; the
# tests below pin both halves of that contract.
# ════════════════════════════════════════════════════════════════════

@test "_tui_run forwards --ok-button / --cancel-button spelling on whiptail" {
  _install_stub whiptail
  TUI_BACKEND="whiptail"
  export _TUI_OK_LABEL="Enter" _TUI_CANCEL_LABEL="Cancel"
  export TUI_STUB_RESPONSE=""
  run _tui_run --msgbox "hi" 10 40
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-button"
  assert_output --partial "Enter"
  assert_output --partial "--cancel-button"
  assert_output --partial "Cancel"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
}

@test "_tui_run keeps --ok-label / --cancel-label spelling on dialog" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export _TUI_OK_LABEL="Enter" _TUI_CANCEL_LABEL="Cancel"
  export TUI_STUB_RESPONSE=""
  run _tui_run --msgbox "hi" 10 40
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-label"
  assert_output --partial "--cancel-label"
  refute_output --partial "--ok-button"
  refute_output --partial "--cancel-button"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
}

@test "_tui_msgbox does not leak --ok-label / --cancel-label onto whiptail" {
  # _tui_msgbox bypasses _tui_run (it has no Cancel button), so it never
  # emits OK/Cancel label flags regardless of backend. The regression
  # guard here is purely that no dialog-spelled flag ever leaks through
  # to whiptail (which would crash with `unknown option`).
  _install_stub whiptail
  TUI_BACKEND="whiptail"
  export _TUI_OK_LABEL="Enter"
  run _tui_msgbox "Hi" "Hello there"
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
  unset _TUI_OK_LABEL
}

@test "_tui_inputbox uses --ok-button / --cancel-button on whiptail" {
  _install_stub whiptail
  TUI_BACKEND="whiptail"
  export _TUI_OK_LABEL="Enter" _TUI_CANCEL_LABEL="Cancel"
  export TUI_STUB_RESPONSE="x"
  run _tui_inputbox "T" "P" "init"
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-button"
  assert_output --partial "--cancel-button"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
}

@test "_tui_menu uses --ok-button / --cancel-button on whiptail" {
  _install_stub whiptail
  TUI_BACKEND="whiptail"
  export _TUI_OK_LABEL="Enter" _TUI_CANCEL_LABEL="Cancel"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA tagB LabelB
  assert_success
  run cat "${TUI_LOG}"
  assert_output --partial "--ok-button"
  assert_output --partial "--cancel-button"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
  unset _TUI_OK_LABEL _TUI_CANCEL_LABEL
}

# ════════════════════════════════════════════════════════════════════
# The knobs are internal parameterisation, not an ambient user surface
# ════════════════════════════════════════════════════════════════════
#
# Geometry and button captions parameterise this backend wrapper for the
# menus setup_tui.sh draws. They were readable from the environment, so a
# value nobody validated -- a zero width, a non-numeric height -- reached
# dialog(1) and produced an unusable menu with no diagnostic. The names
# are private now (the file's own `_tui_*` convention), which is what
# takes the environment out of the picture.

@test "_tui_backend: an ambient TUI_WIDTH / TUI_HEIGHT does not reach the backend (#895)" {
  # Sourced in a child shell so the ambient value is present at the point
  # the geometry is established, which is file scope.
  _install_stub dialog
  run env TUI_WIDTH=0 TUI_HEIGHT=0 TUI_STUB_RESPONSE=tagA bash -c '
    # shellcheck disable=SC1091
    source /source/dist/script/docker/lib/_tui_backend.sh
    TUI_BACKEND=dialog
    _tui_menu "Title" "Pick" tagA LabelA
  '
  assert_success
  run cat "${TUI_LOG}"
  refute_line "0"
  assert_line "70"
  assert_line "20"
}

@test "_tui_backend: an ambient TUI_NO_TAGS does not reach the backend (#895)" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_NO_TAGS=1
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA tagB LabelB
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--no-tags"
  unset TUI_NO_TAGS
}

@test "_tui_backend: an ambient TUI_OK_LABEL / TUI_CANCEL_LABEL does not reach the backend (#895)" {
  _install_stub dialog
  TUI_BACKEND="dialog"
  export TUI_OK_LABEL="Ambient" TUI_CANCEL_LABEL="Ambient"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--ok-label"
  refute_output --partial "--cancel-label"
  refute_output --partial "Ambient"
  unset TUI_OK_LABEL TUI_CANCEL_LABEL
}

@test "_tui_menu omits --extra-button / --extra-label on whiptail even when TUI_EXTRA_LABEL is set" {
  # whiptail has no --extra-button at all (newt limitation). This test
  # has held since and remains valid after
  _install_stub whiptail
  TUI_BACKEND="whiptail"
  export TUI_EXTRA_LABEL="Save"
  export TUI_STUB_RESPONSE="tagA"
  run _tui_menu "Title" "Pick" tagA LabelA tagB LabelB
  assert_success
  run cat "${TUI_LOG}"
  refute_output --partial "--extra-button"
  refute_output --partial "--extra-label"
  unset TUI_EXTRA_LABEL
}
