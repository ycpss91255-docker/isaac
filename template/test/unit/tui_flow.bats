#!/usr/bin/env bats
#
# tui_flow.bats — interactive-flow tests for setup_tui.sh.
#
# Covers menu navigation (#178 Save & Exit), image rule editor with
# compaction (#177), generic list-section CRUD, and Cancel / Esc abort
# paths. Closes #189: lifts setup_tui.sh per-file coverage from 18% to
# >=70% by exercising the function set the comment in tui_spec.bats
# already promised would live in this file.
#
# Mocking strategy: source setup_tui.sh directly (so _TUI_OVR_KEYS /
# _TUI_OVR_VALUES / _TUI_REMOVED / _TUI_CURRENT live in this shell), then
# override the _tui_* dialog wrappers with bash function definitions
# that pop scripted (exit, response) pairs from a queue. Each test
# pre-loads the queue with the user's intended click path, calls the
# target function, and asserts on the resulting in-memory override
# state — no real dialog / whiptail process ever launches.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh

  # Reset per-test global state. The arrays are declared at module load
  # time (setup_tui.sh declare -gA / declare -ga); zero them out so
  # earlier test cases do not leak overrides into the next case.
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()

  # File-backed queue for the _tui_* stubs. _tui_* are called via
  # `$(...)` command substitution, so any pop counter held in a shell
  # variable would die in the subshell — using a file lets the pop
  # mutate state visibly to the parent. Each line: "<exit>|<response>".
  _QFILE="${BATS_TEST_TMPDIR}/tui_queue"
  : > "${_QFILE}"

  # Override the dialog primitives from _tui_backend.sh AFTER sourcing
  # setup_tui.sh, so our definitions win. (Top-level definitions in the
  # bats file would lose to the source line below.) eval is intentional
  # so the stubs are visible to subshells via export -f.
  _tui_pop() {
    local _line
    _line="$(head -n 1 "${_QFILE}" 2>/dev/null || true)"
    [[ -z "${_line}" ]] && _line="1|"
    sed -i '1d' "${_QFILE}" 2>/dev/null || true
    printf '%s' "${_line#*|}"
    return "${_line%%|*}"
  }
  _tui_menu()      { _tui_pop; }
  _tui_select()    { _tui_pop; }
  _tui_inputbox()  { _tui_pop; }
  _tui_radiolist() { _tui_pop; }
  _tui_checklist() { _tui_pop; }
  _tui_yesno()     {
    local _line
    _line="$(head -n 1 "${_QFILE}" 2>/dev/null || true)"
    [[ -z "${_line}" ]] && _line="1|"
    sed -i '1d' "${_QFILE}" 2>/dev/null || true
    return "${_line%%|*}"
  }
  _tui_msgbox()    { return 0; }
  export -f _tui_pop _tui_menu _tui_select _tui_inputbox \
            _tui_radiolist _tui_checklist _tui_yesno _tui_msgbox
  export _QFILE
}

teardown() {
  return 0
}

# ── Stub helpers ─────────────────────────────────────────────────────────

# Convenience: queue a chain of (exit, response) lines into _QFILE.
queue() {
  : > "${_QFILE}"
  local _e
  for _e in "$@"; do
    printf '%s\n' "${_e}" >> "${_QFILE}"
  done
}

# Look up override key by name, echo value or empty when absent.
ovr_get() {
  local _k="${1}" i
  for (( i=0; i<${#_TUI_OVR_KEYS[@]}; i++ )); do
    [[ "${_TUI_OVR_KEYS[i]}" == "${_k}" ]] && {
      printf '%s' "${_TUI_OVR_VALUES[i]}"
      return 0
    }
  done
  return 1
}

# Did the test mark <key> for removal?
is_removed() {
  local _k="${1}" _r
  for _r in "${_TUI_REMOVED[@]}"; do
    [[ "${_r}" == "${_k}" ]] && return 0
  done
  return 1
}

# ════════════════════════════════════════════════════════════════════
# _load_current
# ════════════════════════════════════════════════════════════════════

@test "_load_current: pulls keys from repo conf when present" {
  local _repo="${BATS_TEST_TMPDIR}/setup.conf"
  cat > "${_repo}" <<'EOF'
[network]
mode = bridge
EOF
  _load_current "${_repo}" "/dev/null"
  [[ "${_TUI_CURRENT[network.mode]}" == "bridge" ]]
}

@test "_load_current: falls back to template conf when repo conf missing" {
  local _tpl="${BATS_TEST_TMPDIR}/setup.conf"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_mode = auto
EOF
  _load_current "${BATS_TEST_TMPDIR}/missing" "${_tpl}"
  [[ "${_TUI_CURRENT[deploy.gpu_mode]}" == "auto" ]]
}

@test "_load_current: returns 0 silently when both files missing" {
  run _load_current "${BATS_TEST_TMPDIR}/x" "${BATS_TEST_TMPDIR}/y"
  assert_success
  [[ "${#_TUI_CURRENT[@]}" -eq 0 ]]
}

# ════════════════════════════════════════════════════════════════════
# _render_main_menu / _render_advanced_menu (#178 Save & Exit unification)
# ════════════════════════════════════════════════════════════════════

@test "_render_main_menu: __save returns 0 (Save & Exit path)" {
  queue "0|__save"
  run _render_main_menu
  assert_success
}

@test "_render_main_menu: empty choice (Cancel) returns 1" {
  queue "0|"
  run _render_main_menu
  [ "${status}" -eq 1 ]
}

@test "_render_main_menu: non-zero rc (Esc) returns 1" {
  queue "1|"
  run _render_main_menu
  [ "${status}" -eq 1 ]
}

@test "_render_main_menu: navigates into _edit_section_<choice> then Save" {
  # First menu pick = network (dispatches into _edit_section_network),
  # which immediately consumes the next two _tui_select responses
  # (mode + ipc) to set them. Second pop after that = __save → exit.
  queue "0|network" "0|host" "0|host" "0|__save"
  run _render_main_menu
  assert_success
}

@test "_render_advanced_menu: __back exits the loop" {
  queue "0|__back"
  run _render_advanced_menu
  assert_success
}

@test "_render_advanced_menu: Cancel (rc!=0) exits via break" {
  queue "1|"
  run _render_advanced_menu
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _edit_image_rule (#177 regression site)
#
# Two-step editor: rule type radiolist → value inputbox (skipped for
# basename / __remove / __move_*).
# ════════════════════════════════════════════════════════════════════

@test "_edit_image_rule: add string rule writes prefix-free value" {
  queue "0|string" "0|myimg"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "string:myimg" ]]
}

@test "_edit_image_rule: add prefix rule prefixes the value" {
  queue "0|prefix" "0|abc"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "prefix:abc" ]]
}

@test "_edit_image_rule: add suffix rule prefixes the value" {
  queue "0|suffix" "0|_dev"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "suffix:_dev" ]]
}

@test "_edit_image_rule: add basename rule writes @basename and skips inputbox" {
  queue "0|basename"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "@basename" ]]
}

@test "_edit_image_rule: add default rule rewrites @default:<value>" {
  queue "0|default" "0|fallback"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "@default:fallback" ]]
}

@test "_edit_image_rule: Cancel from radiolist returns without writing" {
  queue "1|"
  _edit_image_rule 1
  ! ovr_get image.rule_1
}

@test "_edit_image_rule: Cancel from inputbox returns without writing" {
  queue "0|prefix" "1|"
  _edit_image_rule 1
  ! ovr_get image.rule_1
}

@test "_edit_image_rule: __remove triggers compaction (single rule → empty)" {
  _override_set image.rule_1 "string:foo"
  queue "0|__remove"
  _edit_image_rule 1
  is_removed image.rule_1
}

@test "_edit_image_rule: __move_up at n=2 swaps with n=1" {
  _override_set image.rule_1 "string:a"
  _override_set image.rule_2 "string:b"
  queue "0|__move_up"
  _edit_image_rule 2
  [[ "$(ovr_get image.rule_1)" == "string:b" ]]
  [[ "$(ovr_get image.rule_2)" == "string:a" ]]
}

@test "_edit_image_rule: __move_down at n=1 swaps with n=2" {
  _override_set image.rule_1 "string:a"
  _override_set image.rule_2 "string:b"
  queue "0|__move_down"
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "string:b" ]]
  [[ "$(ovr_get image.rule_2)" == "string:a" ]]
}

@test "_edit_image_rule: dedupe — adding existing value drops the duplicate slot" {
  _override_set image.rule_1 "string:foo"
  _override_set image.rule_2 "string:other"
  queue "0|string" "0|other"   # rewrite slot 1 to match slot 2's value
  _edit_image_rule 1
  [[ "$(ovr_get image.rule_1)" == "string:other" ]]
  is_removed image.rule_2
}

# ════════════════════════════════════════════════════════════════════
# _compact_image_rules_after_remove (#177)
# ════════════════════════════════════════════════════════════════════

@test "_compact_image_rules_after_remove: shifts higher rules down by one slot" {
  _override_set image.rule_1 "string:a"
  _override_set image.rule_2 "string:b"
  _override_set image.rule_3 "string:c"
  _compact_image_rules_after_remove 2
  [[ "$(ovr_get image.rule_1)" == "string:a" ]]
  [[ "$(ovr_get image.rule_2)" == "string:c" ]]
  is_removed image.rule_3
}

@test "_compact_image_rules_after_remove: removing last rule just drops it" {
  _override_set image.rule_1 "string:a"
  _override_set image.rule_2 "string:b"
  _compact_image_rules_after_remove 2
  [[ "$(ovr_get image.rule_1)" == "string:a" ]]
  is_removed image.rule_2
}

@test "_compact_image_rules_after_remove: empty list is a no-op" {
  _compact_image_rules_after_remove 1
  [[ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]]
}

@test "_compact_image_rules_after_remove: collapses sparse slots above target" {
  # Pre-existing gap (rule_1, rule_3 — no rule_2) plus a remove at 1
  # should produce a single contiguous rule_1 holding the old rule_3.
  _override_set image.rule_1 "string:a"
  _override_set image.rule_3 "string:c"
  _compact_image_rules_after_remove 1
  [[ "$(ovr_get image.rule_1)" == "string:c" ]]
  is_removed image.rule_3
}

# ════════════════════════════════════════════════════════════════════
# _swap_image_rule
# ════════════════════════════════════════════════════════════════════

@test "_swap_image_rule: both occupied — swaps values" {
  _override_set image.rule_1 "string:a"
  _override_set image.rule_2 "string:b"
  _swap_image_rule 1 2
  [[ "$(ovr_get image.rule_1)" == "string:b" ]]
  [[ "$(ovr_get image.rule_2)" == "string:a" ]]
}

@test "_swap_image_rule: m < 1 is a silent no-op" {
  _override_set image.rule_1 "string:a"
  _swap_image_rule 1 0
  [[ "$(ovr_get image.rule_1)" == "string:a" ]]
}

@test "_swap_image_rule: target empty — moves source into empty slot" {
  _override_set image.rule_1 "string:a"
  _swap_image_rule 1 2
  [[ "$(ovr_get image.rule_2)" == "string:a" ]]
  is_removed image.rule_1
}

@test "_swap_image_rule: source empty — moves target into source slot" {
  _override_set image.rule_2 "string:b"
  _swap_image_rule 1 2
  [[ "$(ovr_get image.rule_1)" == "string:b" ]]
  is_removed image.rule_2
}

@test "_swap_image_rule: both empty is a no-op" {
  _swap_image_rule 1 2
  [[ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_list_section / _edit_list_entry (mount_*, env_*, port_*, ...)
#
# Generic list-section CRUD: pick item from menu, edit value via
# inputbox, optional validator. Empty input deletes; Cancel aborts.
# Exercised here through _edit_section_environment (env_ prefix +
# _validate_env_kv validator) and _edit_section_volumes
# (mount_ prefix + _validate_mount). Coverage flows through the
# generic path either way — same code, just different parameters.
# ════════════════════════════════════════════════════════════════════

@test "_edit_list_section env_: add then back writes env_1" {
  # pick "add" → inputbox accepts "FOO=bar" → loop returns to menu →
  # pick "back" to exit.
  queue "0|add" "0|FOO=bar" "0|back"
  _edit_section_environment
  [[ "$(ovr_get environment.env_1)" == "FOO=bar" ]]
}

@test "_edit_list_section env_: invalid value shows msgbox + retries" {
  # First inputbox = invalid → msgbox + loop continues with the typed
  # value preserved. Second inputbox = valid. Then back.
  queue "0|add" "0|nokey" "0|FOO=bar" "0|back"
  _edit_section_environment
  [[ "$(ovr_get environment.env_1)" == "FOO=bar" ]]
}

@test "_edit_list_section env_: empty input on existing entry marks removed" {
  # Pre-seed env_1, click into it, type empty → delete.
  _override_set environment.env_1 "FOO=bar"
  _TUI_CURRENT[environment.env_1]="FOO=bar"
  queue "0|env_1" "0|" "0|back"
  _edit_section_environment
  is_removed environment.env_1
}

@test "_edit_list_section env_: add → next free index is max+1" {
  _override_set environment.env_1 "FOO=bar"
  _TUI_CURRENT[environment.env_1]="FOO=bar"
  queue "0|add" "0|BAZ=qux" "0|back"
  _edit_section_environment
  [[ "$(ovr_get environment.env_2)" == "BAZ=qux" ]]
}

@test "_edit_list_section env_: empty choice (Cancel) returns 0 immediately" {
  queue "0|"
  run _edit_section_environment
  assert_success
  [[ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]]
}

@test "_edit_list_section env_: rc!=0 (Esc) returns 0 immediately" {
  queue "1|"
  run _edit_section_environment
  assert_success
}

@test "_edit_list_section env_: edits existing entry replacing value" {
  _override_set environment.env_1 "FOO=bar"
  _TUI_CURRENT[environment.env_1]="FOO=bar"
  queue "0|env_1" "0|FOO=baz" "0|back"
  _edit_section_environment
  [[ "$(ovr_get environment.env_1)" == "FOO=baz" ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_additional_contexts — issue #199
#
# Exercises the same _edit_list_section path as environment / volumes
# but with the context_ prefix and the _validate_additional_context
# validator. Confirms add / edit / remove / cancel / invalid-retry all
# wire through correctly so seggpt-style repos can drive the workflow
# from the TUI without hand-editing setup.conf.
# ════════════════════════════════════════════════════════════════════

@test "_edit_section_additional_contexts: add then back writes context_1" {
  queue "0|add" "0|repo=.." "0|back"
  _edit_section_additional_contexts
  [[ "$(ovr_get additional_contexts.context_1)" == "repo=.." ]]
}

@test "_edit_section_additional_contexts: invalid name shows msgbox + retries" {
  # First inputbox = invalid (missing =) → msgbox; loop continues.
  # Second inputbox = valid. Then back.
  queue "0|add" "0|noequals" "0|repo=.." "0|back"
  _edit_section_additional_contexts
  [[ "$(ovr_get additional_contexts.context_1)" == "repo=.." ]]
}

@test "_edit_section_additional_contexts: add → next free index is max+1" {
  _override_set additional_contexts.context_1 "repo=.."
  _TUI_CURRENT[additional_contexts.context_1]="repo=.."
  queue "0|add" "0|vendor=../third_party" "0|back"
  _edit_section_additional_contexts
  [[ "$(ovr_get additional_contexts.context_2)" == "vendor=../third_party" ]]
}

@test "_edit_section_additional_contexts: empty input on existing entry marks removed" {
  _override_set additional_contexts.context_1 "repo=.."
  _TUI_CURRENT[additional_contexts.context_1]="repo=.."
  queue "0|context_1" "0|" "0|back"
  _edit_section_additional_contexts
  is_removed additional_contexts.context_1
}

@test "_edit_section_additional_contexts: edits existing entry replacing value" {
  _override_set additional_contexts.context_1 "repo=.."
  _TUI_CURRENT[additional_contexts.context_1]="repo=.."
  queue "0|context_1" "0|repo=../upstream" "0|back"
  _edit_section_additional_contexts
  [[ "$(ovr_get additional_contexts.context_1)" == "repo=../upstream" ]]
}

@test "_edit_section_additional_contexts: empty choice (Cancel) returns 0 immediately" {
  queue "0|"
  run _edit_section_additional_contexts
  assert_success
  [[ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]]
}

@test "_edit_section_additional_contexts: rc!=0 (Esc) returns 0 immediately" {
  queue "1|"
  run _edit_section_additional_contexts
  assert_success
}

@test "_edit_section_additional_contexts: docker-image:// schemes accepted" {
  queue "0|add" "0|base=docker-image://debian:bookworm-slim" "0|back"
  _edit_section_additional_contexts
  [[ "$(ovr_get additional_contexts.context_1)" == "base=docker-image://debian:bookworm-slim" ]]
}

@test "_render_advanced_menu: additional_contexts choice dispatches to its editor" {
  # Click additional_contexts → its editor immediately Cancels (empty
  # menu pick) → user lands back on advanced menu → __back exits.
  queue "0|additional_contexts" "0|" "0|__back"
  run _render_advanced_menu
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_image — top-level menu dispatch into _edit_image_rule
# ════════════════════════════════════════════════════════════════════

@test "_edit_section_image: add path appends rule at max+1" {
  _override_set image.rule_1 "string:foo"
  _TUI_CURRENT[image.rule_1]="string:foo"
  queue "0|add" "0|string" "0|bar" "0|back"
  _edit_section_image
  [[ "$(ovr_get image.rule_2)" == "string:bar" ]]
}

@test "_edit_section_image: rule_1 click drills into _edit_image_rule" {
  _override_set image.rule_1 "string:foo"
  _TUI_CURRENT[image.rule_1]="string:foo"
  queue "0|rule_1" "0|string" "0|baz" "0|back"
  _edit_section_image
  [[ "$(ovr_get image.rule_1)" == "string:baz" ]]
}

@test "_edit_section_image: back returns immediately" {
  queue "0|back"
  run _edit_section_image
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_network — _tui_select x2 (mode + ipc), conditional
# branches: bridge → network_name + ports; ipc!=host → shm_size.
# ════════════════════════════════════════════════════════════════════

@test "_edit_section_network: host + host writes both modes, no shm prompt" {
  queue "0|host" "0|host"
  _edit_section_network
  [[ "$(ovr_get network.mode)" == "host" ]]
  [[ "$(ovr_get network.ipc)" == "host" ]]
  [[ "$(ovr_get network.network_name)" == "" ]]
}

@test "_edit_section_network: bridge + host prompts for network_name + ports menu" {
  # mode=bridge → name inputbox + ports submenu (back immediately).
  queue "0|bridge" "0|host" "0|mynet" "0|back"
  _edit_section_network
  [[ "$(ovr_get network.mode)" == "bridge" ]]
  [[ "$(ovr_get network.network_name)" == "mynet" ]]
}

@test "_edit_section_network: ipc=private prompts for shm_size" {
  queue "0|host" "0|private" "0|2gb"
  _edit_section_network
  [[ "$(ovr_get network.ipc)" == "private" ]]
  [[ "$(ovr_get resources.shm_size)" == "2gb" ]]
}

@test "_edit_section_network: empty network_name allowed (compose default bridge)" {
  queue "0|bridge" "0|host" "0|" "0|back"
  _edit_section_network
  [[ "$(ovr_get network.network_name)" == "" ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_deploy — gpu_mode select; off short-circuits remaining
# count + capabilities flow.
# ════════════════════════════════════════════════════════════════════

@test "_edit_section_deploy: off short-circuits — only writes gpu_mode" {
  # Stub _detect_mig false so MIG branch does not fire (it would not
  # be reached anyway since off returns early, but make the test
  # robust against future ordering changes).
  _detect_mig() { return 1; }
  queue "0|off"
  _edit_section_deploy
  [[ "$(ovr_get deploy.gpu_mode)" == "off" ]]
  ! ovr_get deploy.gpu_count
}
