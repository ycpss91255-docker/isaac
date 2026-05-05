#!/usr/bin/env bats
#
# tui_spec.bats — pure-logic unit tests for the TUI support libraries.
# Focuses on validators, INI round-trip, and mount-string parsing. No
# interactive dialog/whiptail calls are exercised here (see
# tui_backend_spec.bats and tui_flow.bats for those).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/_tui_conf.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# _validate_mount
# ════════════════════════════════════════════════════════════════════

@test "_validate_mount accepts simple host:container" {
  _validate_mount "/data:/data"
}

@test "_validate_mount accepts host:container:ro" {
  _validate_mount "/etc/machine-id:/etc/machine-id:ro"
}

@test "_validate_mount accepts host:container:rw" {
  _validate_mount "/cache:/cache:rw"
}

@test "_validate_mount accepts paths with env var expansion" {
  _validate_mount '${HOME}/.ssh:/root/.ssh:ro'
}

@test "_validate_mount rejects empty string" {
  run _validate_mount ""
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects missing colon" {
  run _validate_mount "/data"
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects invalid mode" {
  run _validate_mount "/data:/data:xx"
  [ "${status}" -ne 0 ]
}

@test "_validate_mount rejects too many colons" {
  run _validate_mount "/a:/b:/c:/d"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_shm_size
# ════════════════════════════════════════════════════════════════════

@test "_validate_shm_size accepts sizes with units (2gb, 512mb, 1024k, 8g, 100b)" {
  _validate_shm_size "2gb"
  _validate_shm_size "512mb"
  _validate_shm_size "1024k"
  _validate_shm_size "8g"
  _validate_shm_size "100b"
}

@test "_validate_shm_size accepts uppercase units (2GB, 512MB)" {
  _validate_shm_size "2GB"
  _validate_shm_size "512MB"
  _validate_shm_size "8G"
}

@test "_validate_shm_size rejects missing unit" {
  run _validate_shm_size "2"
  [ "${status}" -ne 0 ]
}

@test "_validate_shm_size rejects non-numeric / bad unit / empty" {
  run _validate_shm_size "abc"
  [ "${status}" -ne 0 ]
  run _validate_shm_size "2xy"
  [ "${status}" -ne 0 ]
  run _validate_shm_size "2 gb"
  [ "${status}" -ne 0 ]
  run _validate_shm_size ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_port_mapping
# ════════════════════════════════════════════════════════════════════

@test "_validate_port_mapping accepts host:container" {
  _validate_port_mapping "8080:80"
  _validate_port_mapping "5000:5000"
  _validate_port_mapping "65535:1"
}

@test "_validate_port_mapping accepts optional /tcp or /udp" {
  _validate_port_mapping "8080:80/tcp"
  _validate_port_mapping "5000:5000/udp"
}

@test "_validate_port_mapping rejects bad formats" {
  run _validate_port_mapping "8080"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping "a:b"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping "8080:80/sctp"
  [ "${status}" -ne 0 ]
  run _validate_port_mapping ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_env_kv
# ════════════════════════════════════════════════════════════════════

@test "_validate_env_kv accepts KEY=VALUE and KEY= (empty value)" {
  _validate_env_kv "ROS_DOMAIN_ID=7"
  _validate_env_kv "DEBUG="
  _validate_env_kv "FOO_BAR=quoted value"
  _validate_env_kv "_UNDERSCORE=ok"
  _validate_env_kv "lower=case_ok"
}

@test "_validate_env_kv rejects missing = or bad key start" {
  run _validate_env_kv "NO_EQUALS"
  [ "${status}" -ne 0 ]
  run _validate_env_kv "123BAD=val"
  [ "${status}" -ne 0 ]
  run _validate_env_kv "=value"
  [ "${status}" -ne 0 ]
  run _validate_env_kv ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_additional_context
# ════════════════════════════════════════════════════════════════════

@test "_validate_additional_context accepts <name>=<relative-path>" {
  _validate_additional_context "repo=.."
  _validate_additional_context "vendor=../third_party"
  _validate_additional_context "data=./local/data"
}

@test "_validate_additional_context accepts BuildKit context schemes" {
  _validate_additional_context "base=docker-image://debian:bookworm-slim"
  _validate_additional_context "remote=https://github.com/example/repo.git"
  _validate_additional_context "oci=oci-layout:///tmp/foo"
}

@test "_validate_additional_context accepts names with allowed punctuation" {
  _validate_additional_context "my.context=.."
  _validate_additional_context "my-ctx=.."
  _validate_additional_context "my_ctx=.."
  _validate_additional_context "1abc=.."
}

@test "_validate_additional_context rejects empty / missing pieces" {
  run _validate_additional_context ""
  [ "${status}" -ne 0 ]
  run _validate_additional_context "noequals"
  [ "${status}" -ne 0 ]
  run _validate_additional_context "=novalue"
  [ "${status}" -ne 0 ]
  run _validate_additional_context "noname="
  [ "${status}" -ne 0 ]
}

@test "_validate_additional_context rejects invalid name shapes" {
  run _validate_additional_context "-leading-dash=.."
  [ "${status}" -ne 0 ]
  run _validate_additional_context ".leading-dot=.."
  [ "${status}" -ne 0 ]
  run _validate_additional_context "name with space=.."
  [ "${status}" -ne 0 ]
  run _validate_additional_context "name/slash=.."
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_network_name
# ════════════════════════════════════════════════════════════════════

@test "_validate_network_name accepts docker-compatible names" {
  _validate_network_name "my_bridge"
  _validate_network_name "bridge-1"
  _validate_network_name "prod.env"
  _validate_network_name "a"
}

@test "_validate_network_name rejects invalid leading chars / spaces" {
  run _validate_network_name "bad name"
  [ "${status}" -ne 0 ]
  run _validate_network_name "-starts-with-dash"
  [ "${status}" -ne 0 ]
  run _validate_network_name ".leading-dot"
  [ "${status}" -ne 0 ]
  run _validate_network_name "with/slash"
  [ "${status}" -ne 0 ]
  run _validate_network_name ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_capability
# ════════════════════════════════════════════════════════════════════

@test "_validate_capability accepts ALL_CAPS names" {
  _validate_capability "SYS_ADMIN"
  _validate_capability "NET_ADMIN"
  _validate_capability "ALL"
  _validate_capability "MKNOD"
}

@test "_validate_capability rejects lowercase / mixed case" {
  run _validate_capability "sys_admin"
  [ "${status}" -ne 0 ]
  run _validate_capability "Sys_Admin"
  [ "${status}" -ne 0 ]
}

@test "_validate_capability rejects digits / empty" {
  run _validate_capability "SYS_ADMIN1"
  [ "${status}" -ne 0 ]
  run _validate_capability ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_target_arch
# ════════════════════════════════════════════════════════════════════

@test "_validate_target_arch accepts empty (auto-detect)" {
  _validate_target_arch ""
}

@test "_validate_target_arch accepts BuildKit-known arches" {
  _validate_target_arch amd64
  _validate_target_arch arm64
  _validate_target_arch arm
  _validate_target_arch 386
  _validate_target_arch ppc64le
  _validate_target_arch s390x
  _validate_target_arch riscv64
}

@test "_validate_target_arch rejects unknown arches and aliases" {
  run _validate_target_arch "x86_64"   # common typo — BuildKit uses amd64
  [ "${status}" -ne 0 ]
  run _validate_target_arch "aarch64"  # another alias
  [ "${status}" -ne 0 ]
  run _validate_target_arch "foo"
  [ "${status}" -ne 0 ]
  run _validate_target_arch "ARM64"    # case-sensitive
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_build_network
# ════════════════════════════════════════════════════════════════════

@test "_validate_build_network accepts empty (docker default)" {
  _validate_build_network ""
}

@test "_validate_build_network accepts docker-known network modes" {
  _validate_build_network host
  _validate_build_network bridge
  _validate_build_network none
  _validate_build_network default
}

@test "_validate_build_network accepts auto / off (issue #102)" {
  _validate_build_network auto
  _validate_build_network off
}

@test "_validate_build_network rejects unknown values" {
  run _validate_build_network "HOST"   # case-sensitive
  [ "${status}" -ne 0 ]
  run _validate_build_network "container:foo"  # network aliases not supported
  [ "${status}" -ne 0 ]
  run _validate_build_network "my-custom-net"
  [ "${status}" -ne 0 ]
  run _validate_build_network "foo"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_runtime
# ════════════════════════════════════════════════════════════════════

@test "_validate_runtime accepts empty (treated as off)" {
  _validate_runtime ""
}

@test "_validate_runtime accepts auto / nvidia / off" {
  _validate_runtime auto
  _validate_runtime nvidia
  _validate_runtime off
}

@test "_validate_runtime rejects unknown values" {
  run _validate_runtime "NVIDIA"   # case-sensitive
  [ "${status}" -ne 0 ]
  run _validate_runtime "runc"     # not a supported override
  [ "${status}" -ne 0 ]
  run _validate_runtime "sysbox"
  [ "${status}" -ne 0 ]
  run _validate_runtime "true"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _warn_if_lang_rejected — TUI msgbox when --lang fell back to "en"
# ════════════════════════════════════════════════════════════════════
#
# The stderr warning from _sanitize_lang gets eaten by curses once
# dialog/whiptail takes over the terminal. main() captures the bad
# input and hands it to this helper, which opens a visible msgbox
# before entering the main menu.
#
# Source setup_tui.sh directly (not via `bash -c`) because kcov's
# injected tracking code trips `set -u` on BASH_SOURCE when a nested
# bash -c sources a file that enables `set -euo pipefail`.

@test "_warn_if_lang_rejected opens a msgbox when given a bad input" {
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  local _log="${TEMP_DIR}/msgbox.log"
  _tui_msgbox() {
    printf 'title=%s\nbody=%s\n---\n' "$1" "$2" > "${_log}"
  }
  _warn_if_lang_rejected notalang
  run cat "${_log}"
  assert_success
  assert_output --partial "title=Language fallback"
  assert_output --partial "Invalid --lang value: 'notalang'"
  assert_output --partial "Valid values:"
}

@test "_warn_if_lang_rejected is a no-op on empty input" {
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  local _log="${TEMP_DIR}/msgbox.log"
  _tui_msgbox() {
    printf 'CALLED\n' >> "${_log}"
  }
  _warn_if_lang_rejected ''
  assert [ ! -f "${_log}" ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_gpu_count
# ════════════════════════════════════════════════════════════════════

@test "_validate_gpu_count accepts 'all'" {
  _validate_gpu_count "all"
}

@test "_validate_gpu_count accepts positive integer" {
  _validate_gpu_count "1"
  _validate_gpu_count "4"
}

@test "_validate_gpu_count rejects zero" {
  run _validate_gpu_count "0"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects negative" {
  run _validate_gpu_count "-1"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects non-numeric" {
  run _validate_gpu_count "abc"
  [ "${status}" -ne 0 ]
}

@test "_validate_gpu_count rejects empty" {
  run _validate_gpu_count ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_enum
# ════════════════════════════════════════════════════════════════════

@test "_validate_enum accepts matching option" {
  _validate_enum "host" "host" "bridge" "none"
}

@test "_validate_enum rejects non-matching value" {
  run _validate_enum "overlay" "host" "bridge" "none"
  [ "${status}" -ne 0 ]
}

@test "_validate_enum rejects empty value" {
  run _validate_enum "" "a" "b"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _mount_host_path
# ════════════════════════════════════════════════════════════════════

@test "_mount_host_path extracts plain host path" {
  local _host=""
  _mount_host_path "/data:/data" _host
  assert_equal "${_host}" "/data"
}

@test "_mount_host_path extracts host path with mode" {
  local _host=""
  _mount_host_path "/data:/data:ro" _host
  assert_equal "${_host}" "/data"
}

@test "_mount_host_path extracts host path with env var" {
  local _host=""
  _mount_host_path '${WS_PATH}:/home/${USER_NAME}/work' _host
  assert_equal "${_host}" '${WS_PATH}'
}

# ════════════════════════════════════════════════════════════════════
# _mount_container_path
# ════════════════════════════════════════════════════════════════════

@test "_mount_container_path extracts plain container path" {
  local _cont=""
  _mount_container_path "/data:/data" _cont
  assert_equal "${_cont}" "/data"
}

@test "_mount_container_path extracts container path with mode" {
  local _cont=""
  _mount_container_path "/data:/data:ro" _cont
  assert_equal "${_cont}" "/data"
}

@test "_mount_container_path extracts container path with env var" {
  local _cont=""
  _mount_container_path '${WS_PATH}:/home/${USER_NAME}/work' _cont
  assert_equal "${_cont}" '/home/${USER_NAME}/work'
}

@test "_mount_container_path empty when input has no colon" {
  local _cont="sentinel"
  _mount_container_path "/standalone" _cont
  assert_equal "${_cont}" ""
}

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf_full + _write_setup_conf (INI round-trip)
# ════════════════════════════════════════════════════════════════════

@test "_load_setup_conf_full reads all sections preserving order" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rules = @default:foo

[build]
apt_mirror_ubuntu = tw.example.com
apt_mirror_debian = debian.example.com

[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
EOF
  local -a _sections=() _keys=() _values=()
  _load_setup_conf_full "${TEMP_DIR}/setup.conf" _sections _keys _values

  assert_equal "${_sections[0]}" "image"
  assert_equal "${_sections[1]}" "build"
  assert_equal "${_sections[2]}" "volumes"
}

@test "_load_setup_conf_full reads key/value pairs" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = auto
gpu_count = 2
EOF
  local -a _sections=() _keys=() _values=()
  _load_setup_conf_full "${TEMP_DIR}/setup.conf" _sections _keys _values

  # Entries are section-scoped key=value; format is
  #   _keys[i]="<section>.<key>", _values[i]="<value>"
  local _found_mode=""
  local i
  for (( i=0; i<${#_keys[@]}; i++ )); do
    if [[ "${_keys[i]}" == "deploy.gpu_mode" ]]; then
      _found_mode="${_values[i]}"
    fi
  done
  assert_equal "${_found_mode}" "auto"
}

@test "_write_setup_conf preserves template comments and section order" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
# Top comment
# Another line

[image]
# describe rules
rules = @default:orig

[build]
apt_mirror_ubuntu =
EOF
  local -a _sections=(image build) _keys=(image.rules build.apt_mirror_ubuntu) \
    _values=("@default:newval" "tw.archive.example.com")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  [ "${status}" -eq 0 ]
  # Preserves top comment
  [[ "${output}" == *"# Top comment"* ]]
  # Preserves section comment
  [[ "${output}" == *"# describe rules"* ]]
  # Substituted values
  [[ "${output}" == *"rules = @default:newval"* ]]
  [[ "${output}" == *"apt_mirror_ubuntu = tw.archive.example.com"* ]]
}

@test "_write_setup_conf keeps template value when key not in overrides" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[network]
mode = host
ipc = host
privileged = true
EOF
  local -a _sections=(network) _keys=(network.mode) _values=(bridge)
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  [[ "${output}" == *"mode = bridge"* ]]
  [[ "${output}" == *"ipc = host"* ]]          # untouched
  [[ "${output}" == *"privileged = true"* ]]   # untouched
}

@test "_write_setup_conf: dst == tpl (same file) keeps content non-empty (#187 regression)" {
  # Issue #187: setup_tui's `_commit_and_setup` passes `_repo_conf` for
  # both dst and tpl when the per-repo file already exists. The function
  # used to truncate `_dst` BEFORE reading from `_tpl`, so when both
  # pointed at the same file the read got an empty file and the write
  # produced a 0-byte result — silently destroying the user's config.
  cat > "${TEMP_DIR}/conf" <<'EOF'
[image]
rules = string:original

[deploy]
gpu_mode = auto
gpu_count = all
gpu_capabilities = gpu
EOF
  local _before
  _before="$(wc -c < "${TEMP_DIR}/conf")"
  [[ "${_before}" -gt 0 ]] || skip "fixture seed unexpectedly empty"

  local -a _sections=(image) _keys=(image.rules) \
    _values=("string:my_unique_image")
  # dst and tpl point at the same path — the bug's exact trigger.
  _write_setup_conf "${TEMP_DIR}/conf" "${TEMP_DIR}/conf" \
    _sections _keys _values

  # The override must land + the rest of the template content must be
  # preserved. Pre-fix this test produces a 0-byte file.
  local _after
  _after="$(wc -c < "${TEMP_DIR}/conf")"
  [[ "${_after}" -gt 0 ]] || \
    fail "_write_setup_conf wiped the file (${_before} → ${_after} bytes)"

  run cat "${TEMP_DIR}/conf"
  assert_output --partial "rules = string:my_unique_image"
  # [deploy] keys carried over from the original content unchanged.
  assert_output --partial "gpu_mode = auto"
  assert_output --partial "gpu_count = all"
}

@test "_write_setup_conf round-trips via _load_setup_conf_full" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rules = @default:orig

[deploy]
gpu_mode = auto
gpu_count = all
gpu_capabilities = gpu
EOF
  local -a _sections=(image deploy) \
    _keys=(image.rules deploy.gpu_mode deploy.gpu_count) \
    _values=("prefix:docker_, @default:foo" "force" "2")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  local -a _sect2=() _keys2=() _vals2=()
  _load_setup_conf_full "${TEMP_DIR}/out.conf" _sect2 _keys2 _vals2

  local _mode=""
  local i
  for (( i=0; i<${#_keys2[@]}; i++ )); do
    [[ "${_keys2[i]}" == "deploy.gpu_mode" ]] && _mode="${_vals2[i]}"
  done
  assert_equal "${_mode}" "force"
}

# ════════════════════════════════════════════════════════════════════
# _upsert_conf_value — in-place edit of a single key (for setup.sh writeback)
# ════════════════════════════════════════════════════════════════════

@test "_upsert_conf_value updates existing key value" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /dev:/dev
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_1" \
    '/host:/home/${USER_NAME}/work'

  run grep '^mount_1' "${TEMP_DIR}/setup.conf"
  [[ "${output}" == "mount_1 = /host:/home/\${USER_NAME}/work" ]]
}

@test "_write_setup_conf removed_keys drops matching lines" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
mount_3 = /c:/c
EOF
  local -a _sections=(volumes) _keys=() _values=()
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values "volumes.mount_2"

  run cat "${TEMP_DIR}/out.conf"
  [[ "${output}" == *"mount_1 = /a:/a"* ]]
  [[ "${output}" != *"mount_2"* ]]
  [[ "${output}" == *"mount_3 = /c:/c"* ]]
}

@test "_write_setup_conf appends unknown override keys to their section" {
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rule_1 = prefix:docker_

[network]
mode = host
EOF
  local -a _sections=(image) \
    _keys=(image.rule_1 image.rule_2) \
    _values=("prefix:docker_" "@default:fallback")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  # Added rule_2 should appear under [image]
  [[ "${output}" == *"rule_2 = @default:fallback"* ]]
  # [network] section must remain
  [[ "${output}" == *"mode = host"* ]]
}

@test "_upsert_conf_value leaves other sections untouched" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rules = @default:foo

[volumes]
mount_1 =
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_1" "/a:/b"

  run grep '^rules' "${TEMP_DIR}/setup.conf"
  [[ "${output}" == "rules = @default:foo" ]]
}

@test "_upsert_conf_value creates section + key when section absent" {
  # Coverage gap: `Section not found at all → append new section + key`
  # branch at the tail of _upsert_conf_value was never exercised.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @default:foo
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_1" "/a:/b"

  run cat "${TEMP_DIR}/setup.conf"
  assert_output --partial "[volumes]"
  assert_output --partial "mount_1 = /a:/b"
  # Pre-existing section untouched
  assert_output --partial "rule_1 = @default:foo"
}

@test "_upsert_conf_value appends key at EOF when section is the last one without target key" {
  # Coverage gap: "Still in target section at EOF and key not matched →
  # append" branch of _upsert_conf_value.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @default:foo

[volumes]
mount_1 = /a:/a
EOF
  _upsert_conf_value "${TEMP_DIR}/setup.conf" "volumes" "mount_2" "/b:/b"

  run cat "${TEMP_DIR}/setup.conf"
  assert_output --partial "mount_1 = /a:/a"
  assert_output --partial "mount_2 = /b:/b"
}

@test "_write_setup_conf flushes unknown override keys that belong to the final template section" {
  # Coverage gap: the "Flush leftovers belonging to the final section"
  # block fires when an override's key doesn't match any template line
  # AND the override's section is the LAST one in the template. Without
  # that terminal flush, the unknown key would be dropped.
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rule_1 = prefix:docker_

[volumes]
mount_1 = /a:/a
EOF
  # volumes is the last section; mount_9 is a new key not in template.
  local -a _sections=(volumes) \
    _keys=(volumes.mount_9) \
    _values=("/extra:/extra")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values

  run cat "${TEMP_DIR}/out.conf"
  assert_output --partial "mount_1 = /a:/a"
  assert_output --partial "mount_9 = /extra:/extra"
}

@test "_write_setup_conf removed_keys + final-section flush interplay" {
  # Regression: ensure removed_keys suppresses the EOF flush so a key
  # the user explicitly cleared doesn't reappear as a trailing override.
  cat > "${TEMP_DIR}/template.conf" <<'EOF'
[image]
rule_1 = prefix:docker_

[volumes]
mount_1 = /a:/a
EOF
  local -a _sections=(volumes) \
    _keys=(volumes.mount_9) \
    _values=("/extra:/extra")
  _write_setup_conf "${TEMP_DIR}/out.conf" "${TEMP_DIR}/template.conf" \
    _sections _keys _values "volumes.mount_9"

  run cat "${TEMP_DIR}/out.conf"
  refute_output --partial "mount_9"
  assert_output --partial "mount_1 = /a:/a"
}

# ════════════════════════════════════════════════════════════════════
# _edit_list_section — regression tests for B5 (volumes mount_1)
# ════════════════════════════════════════════════════════════════════
#
# Bug: when setup.conf has `mount_1 =` (empty value, e.g. template
# default), `_edit_list_section` correctly hid it from the menu because
# `_cur_v` is empty, but still counted `1` in `_nums` for the `_max`
# calculation — so `add` created `mount_2`, leapfrogging the empty
# slot and leaving a hidden hole. Fix: when counting `_nums`, treat
# keys whose value is empty as free slots so `add` reuses them.

# Shared helper: source setup_tui.sh once, stub interactive wrappers.
_b5_setup_tui() {
  export _LANG="en"
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  _tui_init_lang

  # Reset session state between tests
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()

  # Capture channel for stubbed interactions
  _B5_MENU_ARGS_FILE="${TEMP_DIR}/menu_args.log"
  : > "${_B5_MENU_ARGS_FILE}"
}

@test "_edit_list_section shows mount_1 when value is non-empty" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]="/foo:/bar"

  # Stub _tui_menu: record args + return "back" to exit the loop.
  _tui_menu() {
    printf '%s\n' "$@" > "${_B5_MENU_ARGS_FILE}"
    printf 'back'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run cat "${_B5_MENU_ARGS_FILE}"
  # The menu tag/label stream must include mount_1 with its value.
  assert_output --partial "mount_1"
  assert_output --partial "/foo:/bar"
}

@test "_edit_list_section add reuses empty mount_1 slot instead of leapfrogging" {
  _b5_setup_tui
  # mount_1 cleared (empty value) + mount_2 populated.
  _TUI_CURRENT[volumes.mount_1]=""
  _TUI_CURRENT[volumes.mount_2]="/x:/y"

  # _tui_menu runs inside a command substitution subshell, so a shell
  # counter wouldn't persist across calls. Use a file to sequence the
  # returns: first call returns "add", subsequent ones return "back".
  local _menu_seq="${TEMP_DIR}/menu_seq"
  : > "${_menu_seq}"
  _tui_menu() {
    local _n
    _n="$(wc -l < "${_menu_seq}")"
    echo "" >> "${_menu_seq}"
    if (( _n == 0 )); then
      printf 'add'
    else
      printf 'back'
    fi
    return 0
  }

  # _tui_inputbox supplies a new mount value.
  _tui_inputbox() {
    printf '/new:/new'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  # Expect the new mount to land in mount_1 (the empty slot), not mount_3.
  run _override_get "volumes.mount_1" ""
  assert_output "/new:/new"
  run _override_get "volumes.mount_3" ""
  assert_output ""
}

@test "_edit_list_section add uses max+1 when no empty slots exist" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]="/a:/a"
  _TUI_CURRENT[volumes.mount_2]="/b:/b"

  local _menu_seq="${TEMP_DIR}/menu_seq"
  : > "${_menu_seq}"
  _tui_menu() {
    local _n
    _n="$(wc -l < "${_menu_seq}")"
    echo "" >> "${_menu_seq}"
    if (( _n == 0 )); then
      printf 'add'
    else
      printf 'back'
    fi
    return 0
  }
  _tui_inputbox() {
    printf '/c:/c'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run _override_get "volumes.mount_3" ""
  assert_output "/c:/c"
}

@test "_edit_list_section skips empty value from menu display" {
  _b5_setup_tui
  _TUI_CURRENT[volumes.mount_1]=""
  _TUI_CURRENT[volumes.mount_2]="/x:/y"

  _tui_menu() {
    printf '%s\n' "$@" > "${_B5_MENU_ARGS_FILE}"
    printf 'back'
    return 0
  }

  _edit_list_section volumes mount_ \
    volumes.title volumes.menu volumes.add volumes.back volumes.edit.prompt \
    _validate_mount err.invalid_mount

  run cat "${_B5_MENU_ARGS_FILE}"
  # Empty mount_1 must not appear as an entry row.
  refute_output --partial $'mount_1\n'
  # mount_2 must still appear.
  assert_output --partial "mount_2"
  assert_output --partial "/x:/y"
}

# ════════════════════════════════════════════════════════════════════
# _detect_mig / _list_gpu_instances
#
# MIG (Multi-Instance GPU) mode on A100/H100 splits one physical GPU
# into isolated slices. Docker's `count=N` reservation addresses full
# GPUs, not MIG slices; to pin a specific slice users must set
# NVIDIA_VISIBLE_DEVICES to the MIG UUID via [environment]. The TUI
# detects MIG and advises the user accordingly.
# ════════════════════════════════════════════════════════════════════

@test "_detect_mig returns 0 when nvidia-smi reports Enabled" {
  mock_cmd "nvidia-smi" '
if [[ "$1 $2" == "--query-gpu=mig.mode.current --format=csv,noheader" ]]; then
  echo "Enabled"
fi'
  _detect_mig
}

@test "_detect_mig returns 1 when nvidia-smi reports Disabled" {
  mock_cmd "nvidia-smi" '
if [[ "$1 $2" == "--query-gpu=mig.mode.current --format=csv,noheader" ]]; then
  echo "Disabled"
fi'
  run _detect_mig
  [ "${status}" -ne 0 ]
}

@test "_detect_mig returns 1 when nvidia-smi is missing" {
  # Point PATH at MOCK_DIR only (no nvidia-smi stub) so `command -v` fails.
  local _saved_path="${PATH}"
  PATH="${MOCK_DIR}"
  run _detect_mig
  PATH="${_saved_path}"
  [ "${status}" -ne 0 ]
}

@test "_detect_mig returns 1 when nvidia-smi output has no mode line" {
  # Driver stack broken / unsupported query.
  mock_cmd "nvidia-smi" 'exit 9'
  run _detect_mig
  [ "${status}" -ne 0 ]
}

@test "_list_gpu_instances returns nvidia-smi -L output" {
  mock_cmd "nvidia-smi" '
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-abcd)"
  echo "  MIG 1g.5gb     Device  0: (UUID: MIG-1111)"
  echo "  MIG 1g.5gb     Device  1: (UUID: MIG-2222)"
fi'
  run _list_gpu_instances
  assert_success
  [[ "${output}" == *"GPU 0: NVIDIA A100"* ]]
  [[ "${output}" == *"MIG-1111"* ]]
  [[ "${output}" == *"MIG-2222"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_section_deploy — MIG advisory integration
#
# When the host has MIG mode enabled, _edit_section_deploy must show a
# msgbox that explains `count=N` cannot pin a MIG slice and surfaces the
# available slice UUIDs before proceeding with the normal count /
# capabilities prompts.
# ════════════════════════════════════════════════════════════════════

@test "_edit_section_deploy shows MIG msgbox when host has MIG enabled" {
  # Source setup_tui.sh to get _edit_section_deploy + i18n tables. The
  # BASH_SOURCE guard at the bottom of setup_tui.sh prevents main() from
  # running on source.
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh

  # Stub the interactive backend wrappers. _edit_section_deploy calls
  # _tui_select (mode), _tui_inputbox (count), _tui_checklist (caps),
  # and _tui_msgbox for the MIG warning. We capture msgbox calls to
  # TUI_MSGBOX_LOG so the test can assert the title + body.
  TUI_MSGBOX_LOG="${TEMP_DIR}/msgbox.log"
  : > "${TUI_MSGBOX_LOG}"
  export TUI_MSGBOX_LOG

  _tui_select()    { printf '%s' "auto"; }
  _tui_inputbox()  { printf '%s' "all"; }
  _tui_checklist() { printf '%s\n' "gpu"; }
  _tui_msgbox()    {
    printf 'TITLE=%s\n' "${1}" >> "${TUI_MSGBOX_LOG}"
    printf 'BODY<<<%s>>>\n' "${2}" >> "${TUI_MSGBOX_LOG}"
  }

  # nvidia-smi stub drives both _detect_mig (Enabled) and
  # _list_gpu_instances (-L listing).
  mock_cmd "nvidia-smi" '
case "$1 $2" in
  "--query-gpu=mig.mode.current --format=csv,noheader")
    echo "Enabled" ;;
esac
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: NVIDIA A100-SXM4-40GB (UUID: GPU-abcd)"
  echo "  MIG 1g.5gb     Device  0: (UUID: MIG-1111)"
fi'

  run _edit_section_deploy
  assert_success

  # First msgbox call should be the MIG advisory (title + UUID body).
  run cat "${TUI_MSGBOX_LOG}"
  [[ "${output}" == *"NVIDIA MIG"* ]]
  [[ "${output}" == *"MIG-1111"* ]]
  [[ "${output}" == *"NVIDIA_VISIBLE_DEVICES"* ]]
}

@test "_edit_section_deploy skips MIG msgbox when MIG disabled" {
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh

  TUI_MSGBOX_LOG="${TEMP_DIR}/msgbox.log"
  : > "${TUI_MSGBOX_LOG}"
  export TUI_MSGBOX_LOG

  _tui_select()    { printf '%s' "auto"; }
  _tui_inputbox()  { printf '%s' "all"; }
  _tui_checklist() { printf '%s\n' "gpu"; }
  _tui_msgbox()    {
    printf 'TITLE=%s\n' "${1}" >> "${TUI_MSGBOX_LOG}"
  }

  mock_cmd "nvidia-smi" '
case "$1 $2" in
  "--query-gpu=mig.mode.current --format=csv,noheader")
    echo "Disabled" ;;
esac'

  run _edit_section_deploy
  assert_success

  run cat "${TUI_MSGBOX_LOG}"
  [[ "${output}" != *"NVIDIA MIG"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _edit_image_rule — dedupe-on-write (B6)
#
# Adding a rule that matches an existing rule_M's value should move the
# rule to the new slot rather than leaving two identical copies. Applies
# to both add and in-place edit — the write function dedupes
# unconditionally.
# ════════════════════════════════════════════════════════════════════

_b6_setup_tui() {
  export _LANG="en"
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  _tui_init_lang
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()
}

@test "_edit_image_rule add of duplicate @basename drops old slot" {
  _b6_setup_tui
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"

  # Stub type-select to return "basename" and inputbox (unused for basename)
  _tui_select()    { printf 'basename'; }
  _tui_inputbox()  { printf ''; }

  # Add rule_3 = @basename (dup of rule_2)
  _edit_image_rule 3

  # rule_2 should be marked removed
  local _found=0
  local _r
  for _r in "${_TUI_REMOVED[@]}"; do
    [[ "${_r}" == "image.rule_2" ]] && _found=1
  done
  [ "${_found}" -eq 1 ]

  # rule_3 override has @basename
  local _v
  _v="$(_override_get "image.rule_3" "")"
  [ "${_v}" == "@basename" ]
}

@test "_edit_image_rule add of NEW rule string leaves existing slots untouched" {
  _b6_setup_tui
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"

  # Stub: add @default:unknown (no dup)
  _tui_select()    { printf 'default'; }
  _tui_inputbox()  { printf 'unknown'; }

  _edit_image_rule 3

  # No rules removed
  [ "${#_TUI_REMOVED[@]}" -eq 0 ]
  local _v
  _v="$(_override_get "image.rule_3" "")"
  [ "${_v}" == "@default:unknown" ]
}

@test "_edit_image_rule different prefix values are NOT treated as duplicates" {
  _b6_setup_tui
  _TUI_CURRENT[image.rule_1]="prefix:docker_"

  _tui_select()    { printf 'prefix'; }
  _tui_inputbox()  { printf 'foo_'; }

  _edit_image_rule 2

  # rule_1 untouched, rule_2 = prefix:foo_
  [ "${#_TUI_REMOVED[@]}" -eq 0 ]
  local _v
  _v="$(_override_get "image.rule_2" "")"
  [ "${_v}" == "prefix:foo_" ]
}

# ════════════════════════════════════════════════════════════════════
# _validate_cgroup_rule (B10)
# ════════════════════════════════════════════════════════════════════

@test "_validate_cgroup_rule accepts canonical examples" {
  _validate_cgroup_rule "c 189:* rwm"
  _validate_cgroup_rule "c 81:* rwm"
  _validate_cgroup_rule "b 8:0 rw"
  _validate_cgroup_rule "a *:* rwm"
  _validate_cgroup_rule "c 189:12 m"
}

@test "_validate_cgroup_rule rejects bad format" {
  run _validate_cgroup_rule ""
  [ "${status}" -ne 0 ]
  run _validate_cgroup_rule "c 189"
  [ "${status}" -ne 0 ]
  run _validate_cgroup_rule "c189:* rwm"
  [ "${status}" -ne 0 ]
  run _validate_cgroup_rule "c 189:* xyz"
  [ "${status}" -ne 0 ]
  run _validate_cgroup_rule "d 189:* rwm"
  [ "${status}" -ne 0 ]
  run _validate_cgroup_rule "c abc:* rwm"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _swap_image_rule — Move up / Move down
# ════════════════════════════════════════════════════════════════════

_b_swap_setup() {
  export _LANG="en"
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  _tui_init_lang
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()
}

@test "_swap_image_rule swaps two populated slots" {
  _b_swap_setup
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"
  _swap_image_rule 1 2
  local _v1 _v2
  _v1="$(_override_get "image.rule_1" "")"
  _v2="$(_override_get "image.rule_2" "")"
  [ "${_v1}" == "@basename" ]
  [ "${_v2}" == "prefix:docker_" ]
}

@test "_swap_image_rule moving down from empty neighbour relocates the entry" {
  _b_swap_setup
  _TUI_CURRENT[image.rule_1]="@basename"
  # rule_2 absent → "down" effectively relocates rule_1 → rule_2
  _swap_image_rule 1 2
  local _found=0 _r
  for _r in "${_TUI_REMOVED[@]}"; do
    [[ "${_r}" == "image.rule_1" ]] && _found=1
  done
  [ "${_found}" -eq 1 ]
  local _v
  _v="$(_override_get "image.rule_2" "")"
  [ "${_v}" == "@basename" ]
}

@test "_swap_image_rule target < 1 is a no-op (already at top)" {
  _b_swap_setup
  _TUI_CURRENT[image.rule_1]="@basename"
  _swap_image_rule 1 0
  # No writes, no removals
  [ "${#_TUI_OVR_KEYS[@]}" -eq 0 ]
  [ "${#_TUI_REMOVED[@]}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _edit_image_rule __remove — index compaction (#177)
#
# Removing rule_n must shift rule_(n+1) .. rule_max down by one, so
# the user always sees consecutive indices and the next "add"
# allocates max+1 without leaving a gap.
# ════════════════════════════════════════════════════════════════════

_b_remove_setup() {
  export _LANG="en"
  # shellcheck disable=SC1091
  source /source/script/docker/setup_tui.sh
  _tui_init_lang
  _TUI_OVR_KEYS=()
  _TUI_OVR_VALUES=()
  _TUI_REMOVED=()
  _TUI_CURRENT=()
}

@test "_edit_image_rule __remove first rule shifts later rules down" {
  _b_remove_setup
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"
  _TUI_CURRENT[image.rule_3]="@default:fallback"

  _tui_select() { printf '__remove'; }
  _edit_image_rule 1

  local _v1 _v2 _v3
  _v1="$(_override_get "image.rule_1" "")"
  _v2="$(_override_get "image.rule_2" "")"
  _v3="$(_override_get "image.rule_3" "")"
  [ "${_v1}" == "@basename" ]
  [ "${_v2}" == "@default:fallback" ]
  [ -z "${_v3}" ]
}

@test "_edit_image_rule __remove middle rule shifts higher rules down" {
  _b_remove_setup
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"
  _TUI_CURRENT[image.rule_3]="@default:fallback"

  _tui_select() { printf '__remove'; }
  _edit_image_rule 2

  local _v1 _v2 _v3
  _v1="$(_override_get "image.rule_1" "")"
  _v2="$(_override_get "image.rule_2" "")"
  _v3="$(_override_get "image.rule_3" "")"
  [ "${_v1}" == "prefix:docker_" ]
  [ "${_v2}" == "@default:fallback" ]
  [ -z "${_v3}" ]
}

@test "_edit_image_rule __remove last rule needs no shift" {
  _b_remove_setup
  _TUI_CURRENT[image.rule_1]="prefix:docker_"
  _TUI_CURRENT[image.rule_2]="@basename"
  _TUI_CURRENT[image.rule_3]="@default:fallback"

  _tui_select() { printf '__remove'; }
  _edit_image_rule 3

  local _v1 _v2 _v3
  _v1="$(_override_get "image.rule_1" "")"
  _v2="$(_override_get "image.rule_2" "")"
  _v3="$(_override_get "image.rule_3" "")"
  [ "${_v1}" == "prefix:docker_" ]
  [ "${_v2}" == "@basename" ]
  [ -z "${_v3}" ]
}

@test "_edit_image_rule __remove sole rule just removes" {
  _b_remove_setup
  _TUI_CURRENT[image.rule_1]="@basename"

  _tui_select() { printf '__remove'; }
  _edit_image_rule 1

  local _v1
  _v1="$(_override_get "image.rule_1" "")"
  [ -z "${_v1}" ]
}
