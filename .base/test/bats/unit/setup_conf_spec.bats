#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf (per-repo replace / template fallback)
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf returns every entry of the per-repo section" {
  # Was the SETUP_CONF fixture seam; the conf surface is the fixed pair of
  # real files, so the fixture is a real file at the path the resolver reads.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = off
count = 0
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_v[0]}" "off"
}

# ════════════════════════════════════════════════════════════════════
# An ambient SETUP_CONF must not steer config resolution
#
# SETUP_CONF was a test seam that replaced the WHOLE resolution with one
# unchecked path. The two assertions below are the two ways that bites a
# user: a stale value silently swaps the config out from under the repo,
# and a path that does not exist silently resolves to an EMPTY config --
# a silent failure, which invariant 2 forbids.
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf ignores an ambient SETUP_CONF pointing at another file" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/elsewhere.conf" <<'EOF'
[gui]
mode = off
EOF
  local -a _k=() _v=()
  SETUP_CONF="${TEMP_DIR}/elsewhere.conf" _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf does not resolve to an empty config when an ambient SETUP_CONF path is absent" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  local -a _k=() _v=()
  SETUP_CONF="${TEMP_DIR}/typo-nowhere.conf" _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_v[0]}" "force"
}

@test "_setup_conf_handle ignores an ambient SETUP_CONF" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/elsewhere.conf" <<'EOF'
[gui]
mode = off
EOF
  SETUP_CONF="${TEMP_DIR}/elsewhere.conf" _setup_conf_handle "${TEMP_DIR}" _SCH
  run _conf_get _SCH gui mode
  assert_success
  assert_output "force"
}

@test "_compute_conf_hash ignores an ambient SETUP_CONF" {
  # The hash names the config that was actually resolved. Folding a file
  # resolution never read into it makes the drift signal describe something
  # else entirely.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/elsewhere.conf" <<'EOF'
[gui]
mode = off
EOF
  local _plain="" _ambient=""
  _compute_conf_hash "${TEMP_DIR}" _plain
  SETUP_CONF="${TEMP_DIR}/elsewhere.conf" _compute_conf_hash "${TEMP_DIR}" _ambient
  assert_equal "${_ambient}" "${_plain}"
}

@test "_load_setup_conf uses per-repo setup.conf when section present" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf reads the per-repo override from repo-root .setup.conf" {
  # The tool-managed override lives at the repo root as a dotfile,
  # out of the hand-editable config/ surface.
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf ignores a legacy config/docker/setup.conf override" {
  # After the relocation the old nested path is dead: an override left
  # there must NOT win over the template default.
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = legacy_should_be_ignored
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default [gui] mode = auto -- proves the legacy file is unread.
  assert_equal "${_v[0]}" "auto"
}

# ════════════════════════════════════════════════════════════════════
# Post-relocation path names in user-facing help / comments
# ════════════════════════════════════════════════════════════════════
@test "setup_tui.sh usage names the repo-root .setup.conf in every language (#842)" {
  # Help that names a path the user cannot find is worse than no help:
  # all four heredocs must advertise the dotfile the TUI actually edits.
  #
  # Driving usage() means SOURCING the wrapper. That used to be
  # kcov-only-fatal and carried a COVERAGE skip here: the wrapper enabled
  # `set -euo pipefail` unconditionally, so the strict mode outlived the
  # source and the NEXT top-level command in this `bash -c` died inside
  # kcov's own PS4 (which expands an array that is empty at that level).
  # The wrapper now gates its strict mode on being executed directly, like
  # every sibling, so the skip is gone and this assertion runs in the
  # coverage shard too -- sourceable_scripts_spec.bats holds that property.
  local _lang
  for _lang in zh-TW zh-CN ja en; do
    run bash -c "
      # shellcheck disable=SC1091
      source /source/dist/script/docker/wrapper/setup_tui.sh
      _LANG='${_lang}' usage
    "
    assert_success
    assert_output --partial ".setup.conf"
    refute_output --partial "<repo>/setup.conf"
  done
}

@test "no shipped dist/ text still points at the pre-relocation <repo>/setup.conf (#842)" {
  run grep -rn 'repo>/setup\.conf' /source/dist
  assert_failure
}

@test "no shipped dist/ text names the non-existent .base/setup.conf default (#842)" {
  # The template baseline resolves to .base/dist/.setup.conf; the old
  # shorthand points at a path that never existed post-relocation.
  run grep -rn '\.base/setup\.conf' /source/dist
  assert_failure
}

@test "_load_setup_conf falls back to template when section absent per-repo" {
  # Per-repo setup.conf has [gpu] but NOT [gui]
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default has [gui] mode = auto
  assert_equal "${_v[0]}" "auto"
}

@test "_load_setup_conf replace strategy: per-repo section fully replaces template section" {
  # Template [gpu] has mode+count+capabilities; per-repo only sets mode=off
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  # Replace strategy: only "mode" — no count, no capabilities inherited
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
}

# ════════════════════════════════════════════════════════════════════
# .setup.conf.local -- the gitignored per-worktree layer
#
# Third layer of the same chain, with the same section-replace rule:
# template <- <repo>/.setup.conf <- <repo>/.setup.conf.local. It may
# override ANY section, because per-key merge over the eight `<prefix>_N`
# ordered-list sections is not merely inconsistent but broken (an item
# cannot be removed, and adding one needs the highest N of a layer the
# user cannot see).
# ════════════════════════════════════════════════════════════════════
@test "_load_setup_conf: .setup.conf.local overrides the per-repo section" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "off"
}

@test "_load_setup_conf: .setup.conf.local overrides the template for a section the repo omits" {
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  assert_equal "${_v[0]}" "off"
}

@test "_load_setup_conf: .setup.conf.local replaces a section wholesale, never per-key" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[network]
mode = bridge
ipc = private
port_1 = 8080:80
port_2 = 9090:90
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[network]
mode = bridge
port_1 = 18080:80
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "network" _k _v
  # Two entries, both the local layer's: no ipc, and no port_2 leaking
  # back in from the layer underneath to make one list out of two.
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_k[1]}" "port_1"
  assert_equal "${_v[1]}" "18080:80"
}

@test "_load_setup_conf: sections .setup.conf.local omits keep the layer below" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_setup_conf_handle: .setup.conf.local wins over the per-repo layer" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  _setup_conf_handle "${TEMP_DIR}" _LOCAL_H
  run _conf_get _LOCAL_H gui mode
  assert_success
  assert_output "off"
}

@test "_compute_conf_hash: editing .setup.conf.local is drift" {
  # The hash must describe the config that was actually resolved -- a
  # layer that changes the resolved value and leaves the hash alone means
  # the wrapper reuses artifacts generated from something else.
  local _before="" _after=""
  _compute_conf_hash "${TEMP_DIR}" _before
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  _compute_conf_hash "${TEMP_DIR}" _after
  [[ "${_before}" != "${_after}" ]] || { echo "hash unchanged: ${_before}"; return 1; }
}

@test "_setup_effective_full: show/list read the local layer too" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off
EOF
  local -a _s=() _k=() _v=()
  _setup_effective_full "${TEMP_DIR}" _s _k _v
  local _i _seen=""
  for (( _i = 0; _i < ${#_k[@]}; _i++ )); do
    [[ "${_k[_i]}" == "gui.mode" ]] && _seen="${_v[_i]}"
  done
  assert_equal "${_seen}" "off"
}

@test "_setup_conf_local_sections: names the sections the local layer shadows" {
  # Nothing may be silently shadowed: the callers that warn / announce need
  # the section list, not just a boolean.
  cat > "${TEMP_DIR}/.setup.conf.local" <<'EOF'
[gui]
mode = off

[network]
mode = bridge
EOF
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "2"
  assert_equal "${_sects[0]}" "gui"
  assert_equal "${_sects[1]}" "network"
}

@test "_setup_conf_local_sections: empty when no local layer is present" {
  local -a _sects=()
  _setup_conf_local_sections "${TEMP_DIR}" _sects
  assert_equal "${#_sects[@]}" "0"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_value / _get_conf_list_sorted
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_value returns value for present key" {
  local -a _k=("mode" "count") _v=("auto" "all")
  local _out
  _get_conf_value _k _v "mode" "DEFAULT" _out
  assert_equal "${_out}" "auto"
}

@test "_get_conf_value returns default for absent key" {
  local -a _k=("mode") _v=("auto")
  local _out
  _get_conf_value _k _v "missing" "DEFAULT" _out
  assert_equal "${_out}" "DEFAULT"
}

@test "_get_conf_list_sorted returns values sorted by numeric suffix" {
  local -a _k=("mount_3" "mount_1" "mount_10" "mount_2")
  local -a _v=("/three:/three" "/one:/one" "/ten:/ten" "/two:/two")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "4"
  assert_equal "${_out[0]}" "/one:/one"
  assert_equal "${_out[1]}" "/two:/two"
  assert_equal "${_out[2]}" "/three:/three"
  assert_equal "${_out[3]}" "/ten:/ten"
}

@test "_get_conf_list_sorted skips non-matching keys" {
  local -a _k=("mount_1" "mode" "mount_2")
  local -a _v=("/a:/a" "auto" "/b:/b")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "2"
  assert_equal "${_out[0]}" "/a:/a"
  assert_equal "${_out[1]}" "/b:/b"
}

# ════════════════════════════════════════════════════════════════════
# _rule_basename
# ════════════════════════════════════════════════════════════════════
@test "_rule_basename returns last non-empty path component" {
  result="$(_rule_basename "/home/user/my_project")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename skips trailing slashes" {
  result="$(_rule_basename "/home/user/my_project/")"
  assert_equal "${result}" "my_project"
}

@test "_rule_basename handles single-component path" {
  result="$(_rule_basename "justname")"
  assert_equal "${result}" "justname"
}

# ════════════════════════════════════════════════════════════════════
# _get_conf_list_sorted skips empty values
# ════════════════════════════════════════════════════════════════════
@test "_get_conf_list_sorted skips entries with empty value" {
  local -a _k=("mount_1" "mount_2" "mount_3") _v=("" "/b:/b" "")
  local -a _out=()
  _get_conf_list_sorted _k _v "mount_" _out
  assert_equal "${#_out[@]}" "1"
  assert_equal "${_out[0]}" "/b:/b"
}
