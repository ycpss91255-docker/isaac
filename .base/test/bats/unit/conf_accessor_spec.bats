#!/usr/bin/env bats
#
# Unit tests for the conf.sh opaque accessor interface.
#
# The accessor verbs (_conf_load / _conf_get / _conf_list / _conf_sections)
# hide conf.sh's internal parallel-array + namespacing representation: callers
# load a handle once and query it by (section, key) without touching arrays.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=dist/script/docker/lib/conf.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/conf.sh
  FIX="$(mktemp)"
  cat > "${FIX}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 2

[network]
net = host
EOF
  # The _parse_ini_section / _ini_tokenize specs write fixtures under
  # ${TEMP_DIR}/config/docker/; mirror the path setup the shared
  # setup_spec_helper provides so those tests resolve their conf files.
  TEMP_DIR="$(mktemp -d)"
  mkdir -p "${TEMP_DIR}"
}

teardown() {
  rm -f "${FIX}"
  rm -rf "${TEMP_DIR}"
}

@test "_conf_get returns a value by section and key" {
  _conf_load "${FIX}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "auto"
}

@test "_conf_get_into writes the value into the named outvar, no subshell (#742)" {
  # Outvar variant of _conf_get: lets a hot resolver read many keys from one
  # parsed handle without a $() fork per lookup. Same lookup + default
  # semantics as _conf_get.
  _conf_load "${FIX}" H
  local _v="sentinel"
  _conf_get_into H deploy gpu_runtime "" _v
  assert_equal "${_v}" "auto"
  # default applies when the key is absent
  _conf_get_into H deploy nope "fallback" _v
  assert_equal "${_v}" "fallback"
}

@test "_conf_sections lists section names in first-appearance order" {
  _conf_load "${FIX}" H
  run _conf_sections H
  assert_success
  assert_line --index 0 "deploy"
  assert_line --index 1 "network"
}

@test "_conf_list lists a section's keys in file order" {
  _conf_load "${FIX}" H
  run _conf_list H deploy
  assert_success
  assert_line --index 0 "gpu_runtime"
  assert_line --index 1 "gpu_count"
}

@test "_conf_load_merged: repo section replaces template section wholesale" {
  local _tpl _repo
  _tpl="$(mktemp)"; _repo="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_count = 0

[build]
arg_1 = FROM_TEMPLATE
EOF
  cat > "${_repo}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  _conf_load_merged "${_tpl}" "${_repo}" M
  run _conf_get M deploy gpu_runtime
  assert_success
  assert_output "nvidia"
  run _conf_get M deploy gpu_count missing
  assert_output "missing"
  run _conf_get M build arg_1
  assert_output "FROM_TEMPLATE"
  rm -f "${_tpl}" "${_repo}"
}

@test "_conf_get: duplicate key within a section -- last occurrence wins (#689)" {
  # _conf_get documents 'Last occurrence wins (override semantics)'. The
  # setup.conf merge + re-save legitimately produce duplicate keys within
  # one section, so this is load-bearing. Pin it so a regression returning
  # the FIRST value (or concatenating) is caught.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = auto
gpu_runtime = nvidia
EOF
  _conf_load "${_f}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "nvidia"
  rm -f "${_f}"
}

@test "_conf_list: a section reopened later in the file keeps entries from both occurrences (#689)" {
  # A reopened [deploy] header appends to the same section. _conf_load /
  # _conf_list must surface keys from both occurrences in file order.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = auto

[network]
net = host

[deploy]
gpu_count = 2
EOF
  _conf_load "${_f}" H
  run _conf_list H deploy
  assert_success
  assert_line --index 0 "gpu_runtime"
  assert_line --index 1 "gpu_count"
  # Section header is deduped (listed once).
  run _conf_sections H
  assert_line --index 0 "deploy"
  assert_line --index 1 "network"
  assert_equal "${#lines[@]}" 2
  rm -f "${_f}"
}

@test "_conf_get: inline '#' comment text is KEPT in the value (no inline-comment support) (#689)" {
  # _ini_tokenize strips only lines that START with optional-ws-then-#
  # (conf.sh leading-# rule); a TRAILING inline comment is NOT stripped.
  # Inline comments are intentionally unsupported, so the literal value
  # (including ` # ...`) is the pinned contract -- a future 'fix' to strip
  # inline comments would then be a conscious, test-breaking choice.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy]
gpu_runtime = nvidia # use jetson
EOF
  _conf_load "${_f}" H
  run _conf_get H deploy gpu_runtime
  assert_success
  assert_output "nvidia # use jetson"
  rm -f "${_f}"
}

@test "_conf_sections: section header with internal whitespace is NOT trimmed ([ deploy ] != deploy) (#689)" {
  # The greedy `^\[(.+)\]$` capture runs AFTER trimming the whole line,
  # but only the LINE's outer whitespace is trimmed -- the captured name
  # keeps interior spaces. So `[ deploy ]` yields section ` deploy ` and
  # silently does NOT match `deploy`. Pin so a hand-edited stray space is
  # a known (surfaceable) failure, not a silent surprise.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[ deploy ]
gpu_runtime = auto
EOF
  _conf_load "${_f}" H
  run _conf_sections H
  assert_success
  assert_output " deploy "
  # The canonical name does not resolve...
  run _conf_get H deploy gpu_runtime MISS
  assert_output "MISS"
  # ...only the spaced literal does.
  run _conf_get H " deploy " gpu_runtime MISS
  assert_output "auto"
  rm -f "${_f}"
}

@test "_conf_load: an unterminated section header ([deploy without ]) drops its keys (#689)" {
  # A line missing its closing bracket is not a header match and (having
  # no `=`) is not a key line either, so it is dropped -- and because no
  # section is open, every key under it is lost. Pin this so a hand-edited
  # dropped bracket is a known behaviour: the keys vanish (no section,
  # no crash) rather than silently attaching somewhere.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[deploy
gpu_runtime = auto
gpu_count = 2
EOF
  _conf_load "${_f}" H
  # No section was opened.
  run _conf_sections H
  assert_success
  assert_output ""
  # Keys under the broken header are lost (treated as pre-section lines).
  run _conf_get H deploy gpu_runtime MISS
  assert_output "MISS"
  rm -f "${_f}"
}

@test "_conf_list_sorted returns prefix_N values in numeric order, skipping empties" {
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_2 = b
mount_10 = c
mount_1 = a
mount_3 =
EOF
  _conf_load "${_f}" H
  local -a out=()
  _conf_list_sorted H volumes mount_ out
  assert_equal "${#out[@]}" 3
  assert_equal "${out[0]}" a
  assert_equal "${out[1]}" b
  assert_equal "${out[2]}" c
  rm -f "${_f}"
}

@test "_conf_list_sorted skips non-numeric list suffixes (mount_x / mount_ / mount_2b) (#689)" {
  # The `=~ ^[0-9]+$` guard's reject path: a user/template typo like
  # `mount_abc`, a bare `mount_` (empty suffix), or `mount_2b` (trailing
  # junk) must be SKIPPED, not crash or be mis-sorted into the numeric
  # set. Pin so a regression dropping the numeric guard (which would feed
  # `mount_abc:val` into `sort -t: -k1,1n` and silently misorder) is
  # caught.
  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_2 = b
mount_x = junk
mount_1 = a
mount_ = bare
mount_2b = bad
mount_3 = c
EOF
  _conf_load "${_f}" H
  local -a out=()
  _conf_list_sorted H volumes mount_ out
  assert_equal "${#out[@]}" 3
  assert_equal "${out[0]}" a
  assert_equal "${out[1]}" b
  assert_equal "${out[2]}" c
  rm -f "${_f}"
}

# ── Destructive-failure guards for the INI writers ─────────────────────────
#
# Both writers must fail SAFELY: a failed temp-file creation (read-only
# dir / no inodes) or a mid-write error must never clobber or truncate
# the user's existing setup.conf. conf.sh references _log_err but does
# not define it (it is provided by the umbrella _lib.sh loader in
# production), so these tests stub it locally to capture the diagnostic.

@test "_upsert_conf_value leaves the original file intact when mktemp fails (#700)" {
  # Skipped under kcov: the test overrides `mktemp` with a failing shell
  # function inside the sourced shell to simulate a no-inodes / read-only
  # temp-file creation; kcov's instrumentation perturbs that path.
  [ "${COVERAGE:-0}" = 1 ] && skip "mktemp-failure stub is kcov-fragile (#613)"

  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_1 = /a:/b
EOF
  local _orig
  _orig="$(cat "${_f}")"

  # Force the writer's internal `mktemp "${_file}.XXXXXX"` to fail without
  # touching the real filesystem. The bare `mktemp -d`-style fixture call
  # above already ran, so override only for the writer invocation.
  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mktemp() { return 1; }
    _upsert_conf_value '${_f}' volumes mount_1 /c:/d
  "
  assert_failure
  assert_output --partial "cannot create temp file"
  # The original file must survive completely unchanged (not truncated).
  run cat "${_f}"
  assert_output "${_orig}"
  rm -f "${_f}"
}

@test "_write_setup_conf leaves the destination intact when its temp file cannot be created (#700)" {
  # Skipped under kcov: overrides `mktemp` with a failing shell function
  # to simulate temp-file-creation failure.
  [ "${COVERAGE:-0}" = 1 ] && skip "mktemp-failure stub is kcov-fragile (#613)"

  local _tpl _dst
  _tpl="$(mktemp)"
  _dst="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
EOF
  cat > "${_dst}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  local _orig
  _orig="$(cat "${_dst}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mktemp() { return 1; }
    declare -a _sections=() _keys=() _values=()
    _write_setup_conf '${_dst}' '${_tpl}' _sections _keys _values
  "
  assert_failure
  assert_output --partial "cannot create temp file"
  # The destination must NOT be truncated by an in-place `: > dst`.
  run cat "${_dst}"
  assert_output "${_orig}"
  rm -f "${_tpl}" "${_dst}"
}

# ── Atomic-mv failure guards for the INI writers ───────────────────────────
#
# The full rewrite goes to a sibling temp; the final `mv tmp dst` is what
# makes it visible. A failed mv (e.g. dst on a read-only mount) must NOT
# leave the orphan temp behind silently AND must surface a clear error,
# while the original file stays untouched. Stub `mv` to fail.

@test "_upsert_conf_value cleans the orphan temp + errors when the final mv fails (#702)" {
  # Skipped under kcov: overrides `mv` with a failing shell function to
  # simulate a read-only destination; kcov's instrumentation perturbs
  # that stub path.
  [ "${COVERAGE:-0}" = 1 ] && skip "mv-failure stub is kcov-fragile (#613)"

  local _f
  _f="$(mktemp)"
  cat > "${_f}" <<'EOF'
[volumes]
mount_1 = /a:/b
EOF
  local _orig
  _orig="$(cat "${_f}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mv() { return 1; }
    _upsert_conf_value '${_f}' volumes mount_1 /c:/d
  "
  assert_failure
  assert_output --partial "could not replace"
  # The original file must survive completely unchanged.
  run cat "${_f}"
  assert_output "${_orig}"
  # No orphan temp left next to the destination.
  run bash -c "ls '${_f}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -f "${_f}"
}

@test "_write_setup_conf cleans the orphan temp + errors when the final mv fails (#702)" {
  # Skipped under kcov: overrides `mv` with a failing shell function to
  # simulate a read-only destination.
  [ "${COVERAGE:-0}" = 1 ] && skip "mv-failure stub is kcov-fragile (#613)"

  local _tpl _dst
  _tpl="$(mktemp)"
  _dst="$(mktemp)"
  cat > "${_tpl}" <<'EOF'
[deploy]
gpu_runtime = auto
EOF
  cat > "${_dst}" <<'EOF'
[deploy]
gpu_runtime = nvidia
EOF
  local _orig
  _orig="$(cat "${_dst}")"

  run bash -c "
    source /source/dist/script/docker/lib/conf.sh
    _log_err() { printf 'ERR: %s\n' \"\${*:3}\" >&2; }
    mv() { return 1; }
    declare -a _sections=() _keys=() _values=()
    _write_setup_conf '${_dst}' '${_tpl}' _sections _keys _values
  "
  assert_failure
  assert_output --partial "could not replace"
  # The destination must survive completely unchanged.
  run cat "${_dst}"
  assert_output "${_orig}"
  # No orphan temp left next to the destination.
  run bash -c "ls '${_dst}'.* 2>/dev/null | wc -l"
  assert_output "0"
  rm -f "${_tpl}" "${_dst}"
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
# ════════════════════════════════════════════════════════════════════
@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
count = all
capabilities = gpu
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "auto"
  assert_equal "${_k[1]}" "count"
  assert_equal "${_v[1]}" "all"
}

@test "_parse_ini_section isolates sections (entries from other sections ignored)" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "off"
}

@test "_parse_ini_section skips comment and empty lines" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
# top comment
[network]
# inside comment
mode = host

ipc = host

# trailing
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "network" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_k[1]}" "ipc"
}

@test "_parse_ini_section trims whitespace around key and value" {
  local _conf="${TEMP_DIR}/.setup.conf"
  printf '[gpu]\n  mode  =  force  \n' > "${_conf}"
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gpu" _k _v
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_v[0]}" "force"
}

@test "_parse_ini_section returns empty arrays for missing file" {
  local -a _k=() _v=()
  _parse_ini_section "${TEMP_DIR}/missing.conf" "gpu" _k _v
  assert_equal "${#_k[@]}" "0"
  assert_equal "${#_v[@]}" "0"
}

@test "_parse_ini_section returns empty arrays for absent section" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "0"
}

# A section like [logging] must NOT absorb entries from a distinct
# dotted sub-section [logging.web]. Section matching is exact, not
# prefix-based. conf_logging.sh relies on this: it reads the global
# [logging] block and per-service [logging.<svc>] blocks separately.
@test "_parse_ini_section does not absorb dotted sub-sections" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging" _k _v
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "json-file"
}

@test "_parse_ini_section reads a dotted section name" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[logging]
driver = json-file

[logging.web]
driver = local
max_size = 5m
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "logging.web" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_k[0]}" "driver"
  assert_equal "${_v[0]}" "local"
  assert_equal "${_k[1]}" "max_size"
  assert_equal "${_v[1]}" "5m"
}

# Duplicate keys and a reopened section are preserved in file order
# (the original single-pass reader appended every matching line).
@test "_parse_ini_section preserves duplicate keys and reopened sections in order" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[volumes]
mount_1 = a:a

[other]
x = y

[volumes]
mount_1 = b:b
mount_2 = c:c
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "volumes" _k _v
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_k[0]}" "mount_1"
  assert_equal "${_v[0]}" "a:a"
  assert_equal "${_k[1]}" "mount_1"
  assert_equal "${_v[1]}" "b:b"
  assert_equal "${_k[2]}" "mount_2"
  assert_equal "${_v[2]}" "c:c"
}

# ════════════════════════════════════════════════════════════════════
# _ini_tokenize (shared single-pass core)
# ════════════════════════════════════════════════════════════════════
@test "_ini_tokenize tracks the owning section per entry and dedups headers" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto

[gui]
mode = off

[gpu]
count = all
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  # sections[] dedups by first appearance.
  assert_equal "${#_s[@]}" "2"
  assert_equal "${_s[0]}" "gpu"
  assert_equal "${_s[1]}" "gui"
  # entries keep their owning section even across a reopened header.
  assert_equal "${#_k[@]}" "3"
  assert_equal "${_es[0]}" "gpu"
  assert_equal "${_k[0]}" "mode"
  assert_equal "${_es[1]}" "gui"
  assert_equal "${_es[2]}" "gpu"
  assert_equal "${_k[2]}" "count"
}

@test "_ini_tokenize keeps dotted keys verbatim (per-stage override keys)" {
  local _conf="${TEMP_DIR}/.setup.conf"
  cat > "${_conf}" <<'EOF'
[stage:headless]
gui.mode = off
deploy.gpu_mode = force
EOF
  local -a _s=() _es=() _k=() _v=()
  _ini_tokenize "${_conf}" _s _es _k _v
  assert_equal "${_es[0]}" "stage:headless"
  assert_equal "${_k[0]}" "gui.mode"
  assert_equal "${_v[0]}" "off"
  assert_equal "${_k[1]}" "deploy.gpu_mode"
  assert_equal "${_v[1]}" "force"
}
