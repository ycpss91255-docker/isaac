#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source setup.sh functions only (main is guarded)
  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# detect_user_info
# ════════════════════════════════════════════════════════════════════

@test "detect_user_info uses USER env when set" {
  local _user _group _uid _gid
  USER="mockuser" detect_user_info _user _group _uid _gid
  assert_equal "${_user}" "mockuser"
}

@test "detect_user_info falls back to id -un when USER unset" {
  local _user _group _uid _gid
  mock_cmd "id" '
case "$1" in
  -un) echo "fallbackuser" ;;
  -u)  echo "1001" ;;
  -gn) echo "fallbackgroup" ;;
  -g)  echo "1001" ;;
esac'
  unset USER
  detect_user_info _user _group _uid _gid
  assert_equal "${_user}" "fallbackuser"
}

@test "detect_user_info sets group uid gid correctly" {
  local _user _group _uid _gid
  mock_cmd "id" '
case "$1" in
  -un) echo "testuser" ;;
  -u)  echo "1234" ;;
  -gn) echo "testgroup" ;;
  -g)  echo "5678" ;;
esac'
  USER="testuser" detect_user_info _user _group _uid _gid
  assert_equal "${_group}" "testgroup"
  assert_equal "${_uid}" "1234"
  assert_equal "${_gid}" "5678"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
# ════════════════════════════════════════════════════════════════════

@test "detect_hardware returns uname -m output" {
  local _hw
  mock_cmd "uname" 'echo "aarch64"'
  detect_hardware _hw
  assert_equal "${_hw}" "aarch64"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
# ════════════════════════════════════════════════════════════════════

@test "detect_docker_hub_user uses docker info username when logged in" {
  local _result
  mock_cmd "docker" 'echo " Username: dockerhubuser"'
  detect_docker_hub_user _result
  assert_equal "${_result}" "dockerhubuser"
}

@test "detect_docker_hub_user falls back to USER when docker returns empty" {
  local _result
  mock_cmd "docker" 'echo "no username line here"'
  USER="localuser" detect_docker_hub_user _result
  assert_equal "${_result}" "localuser"
}

@test "detect_docker_hub_user falls back to id -un when USER also unset" {
  local _result
  mock_cmd "docker" 'echo "no username line here"'
  mock_cmd "id" '
case "$1" in
  -un) echo "iduser" ;;
esac'
  unset USER
  detect_docker_hub_user _result
  assert_equal "${_result}" "iduser"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
# ════════════════════════════════════════════════════════════════════

@test "detect_gpu returns true when nvidia-container-toolkit is installed" {
  local _result
  mock_cmd "dpkg-query" 'echo "ii"'
  detect_gpu _result
  assert_equal "${_result}" "true"
}

@test "detect_gpu returns false when nvidia-container-toolkit is not installed" {
  local _result
  mock_cmd "dpkg-query" 'echo "un"'
  detect_gpu _result
  assert_equal "${_result}" "false"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu_count
# ════════════════════════════════════════════════════════════════════

@test "detect_gpu_count returns count of GPUs from nvidia-smi -L output" {
  mock_cmd "nvidia-smi" '
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: NVIDIA A100 (UUID: ...)"
  echo "GPU 1: NVIDIA A100 (UUID: ...)"
  echo "GPU 2: NVIDIA A100 (UUID: ...)"
fi'
  local _n=0
  detect_gpu_count _n
  assert_equal "${_n}" "3"
}

@test "detect_gpu_count returns 0 when nvidia-smi is missing" {
  # Point PATH at MOCK_DIR only (no nvidia-smi stub installed) so the
  # command -v check fails.
  local _saved_path="${PATH}"
  PATH="${MOCK_DIR}"
  local _n=99
  detect_gpu_count _n
  PATH="${_saved_path}"
  assert_equal "${_n}" "0"
}

@test "detect_gpu_count returns 0 when nvidia-smi fails (driver broken)" {
  mock_cmd "nvidia-smi" 'exit 9'
  local _n=99
  detect_gpu_count _n
  assert_equal "${_n}" "0"
}

@test "template setup.conf ships [devices] device_1 = /dev:/dev by default" {
  # Dev-friendly default: new repos get full /dev tree bound without
  # needing to run TUI. Template source-of-truth.
  run grep -E '^device_1 = /dev:/dev$' /source/setup.conf
  assert_success
}

@test "template setup.conf [deploy] enables ALL GPU capabilities by default" {
  # Dev-friendly: reserve every GPU capability so new repos get
  # compute + utility + graphics out of the box (no need to tick boxes
  # in TUI). Users narrow it down via ./setup_tui.sh deploy if they want
  # a minimal reservation.
  run grep -E '^gpu_capabilities = gpu compute utility graphics$' /source/setup.conf
  assert_success
}

@test "[security] cap_add_* fallback: repo setup.conf with no cap_add_* uses template defaults" {
  # Simulate a repo override that keeps privileged=false but wiped all
  # cap_add_* entries. Expected behaviour: setup.sh falls back to the
  # template's baseline (SYS_ADMIN / NET_ADMIN / MKNOD) so the container
  # does not silently drop to Docker's stripped-down default capability
  # set.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- NET_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '- MKNOD' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[security] security_opt_* fallback: missing security_opt_* uses template defaults" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- seccomp:unconfined' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] omitted by default (back-compat: no block in compose.yaml)" {
  # Default template setup.conf has [additional_contexts] section but no
  # entries. Generated compose.yaml must NOT contain `additional_contexts:`
  # so existing repos see zero diff.
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "[additional_contexts] context_1 = NAME=PATH emits block under devel/test build" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 = vendor=../third_party
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Block appears at least once (devel + test, runtime is conditional on
  # Dockerfile having `AS runtime` which TEMP_DIR doesn't ship).
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  [ "${output}" -ge 2 ]
  run grep -F -- '        repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- '        vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "[additional_contexts] runtime service inherits the block when Dockerfile declares AS runtime" {
  # Stub a Dockerfile with `AS runtime` so generate_compose_yaml emits
  # the runtime service. Then assert additional_contexts: appears 3 times
  # (once under each of devel / runtime / test).
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS runtime
EOF
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -c -F -- '      additional_contexts:' "${TEMP_DIR}/compose.yaml"
  assert_success
  assert_output "3"
}

@test "[additional_contexts] entries sort by numeric suffix (context_2 / context_10)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[additional_contexts]
context_10 = ten=../ten
context_2 = two=../two
context_1 = one=../one
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  # Extract first occurrence of the additional_contexts block (devel
  # service) and check the order of name lines within it.
  local _block
  _block="$(awk '
    /^      additional_contexts:$/ { in_block=1; next }
    in_block && /^[^ ]/             { exit }
    in_block && /^      [^ ]/       { exit }
    in_block                         { print }
  ' "${TEMP_DIR}/compose.yaml")"
  local _first _second _third
  _first="$(printf '%s\n'  "${_block}" | sed -n '1p')"
  _second="$(printf '%s\n' "${_block}" | sed -n '2p')"
  _third="$(printf '%s\n'  "${_block}" | sed -n '3p')"
  assert_equal "${_first}"  "        one: ../one"
  assert_equal "${_second}" "        two: ../two"
  assert_equal "${_third}"  "        ten: ../ten"
}

@test "[additional_contexts] empty value (cleared slot) is skipped" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[additional_contexts]
context_1 = repo=..
context_2 =
context_3 = vendor=../third_party
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- 'repo: ..' "${TEMP_DIR}/compose.yaml"
  assert_success
  run grep -F -- 'vendor: ../third_party' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "_setup_known_section recognises additional_contexts" {
  _setup_known_section "additional_contexts"
}

@test "[security] cap_add_* explicit override: user-provided list is honored (no template fallback)" {
  # User set cap_add_1=ALL explicitly: compose should use THAT, not the
  # template's SYS_ADMIN/NET_ADMIN/MKNOD.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
cap_add_1 = ALL
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  run grep -F -- '- ALL' "${TEMP_DIR}/compose.yaml"
  assert_success
  # Template's SYS_ADMIN/NET_ADMIN/MKNOD should NOT appear.
  run grep -F -- '- SYS_ADMIN' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "detect_gpu_count nameref survives caller-local named '_line' (regression)" {
  # Regression: previously detect_gpu_count used `local _line` internally,
  # which shadowed a caller-local also named `_line`; the nameref outvar
  # then silently wrote to the function-local `_line`, never reaching the
  # caller. The fix uses `__dgc_`-prefixed locals.
  mock_cmd "nvidia-smi" '
if [[ "$1" == "-L" ]]; then
  echo "GPU 0: A"
  echo "GPU 1: B"
fi'
  local _line=99
  detect_gpu_count _line
  assert_equal "${_line}" "2"
}

# ════════════════════════════════════════════════════════════════════
# detect_gui
# ════════════════════════════════════════════════════════════════════

@test "detect_gui returns true when DISPLAY is set" {
  local _result
  DISPLAY=":0" WAYLAND_DISPLAY="" detect_gui _result
  assert_equal "${_result}" "true"
}

@test "detect_gui returns true when WAYLAND_DISPLAY is set" {
  local _result
  DISPLAY="" WAYLAND_DISPLAY="wayland-0" detect_gui _result
  assert_equal "${_result}" "true"
}

@test "detect_gui returns false when both DISPLAY and WAYLAND_DISPLAY unset" {
  local _result
  DISPLAY="" WAYLAND_DISPLAY="" detect_gui _result
  assert_equal "${_result}" "false"
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
# ════════════════════════════════════════════════════════════════════

@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/setup.conf"
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
  local _conf="${TEMP_DIR}/setup.conf"
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
  local _conf="${TEMP_DIR}/setup.conf"
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
  local _conf="${TEMP_DIR}/setup.conf"
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
  local _conf="${TEMP_DIR}/setup.conf"
  cat > "${_conf}" <<'EOF'
[gpu]
mode = auto
EOF
  local -a _k=() _v=()
  _parse_ini_section "${_conf}" "gui" _k _v
  assert_equal "${#_k[@]}" "0"
}

# ════════════════════════════════════════════════════════════════════
# _load_setup_conf (per-repo replace / template fallback)
# ════════════════════════════════════════════════════════════════════

@test "_load_setup_conf honors SETUP_CONF env var override" {
  local _override="${TEMP_DIR}/override.conf"
  cat > "${_override}" <<'EOF'
[gpu]
mode = off
count = 0
EOF
  local -a _k=() _v=()
  SETUP_CONF="${_override}" _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${#_k[@]}" "2"
  assert_equal "${_v[0]}" "off"
}

@test "_load_setup_conf uses per-repo setup.conf when section present" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  assert_equal "${_v[0]}" "force"
}

@test "_load_setup_conf falls back to template when section absent per-repo" {
  # Per-repo setup.conf has [gpu] but NOT [gui]
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = force
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gui" _k _v
  # Template default has [gui] mode = auto
  assert_equal "${_v[0]}" "auto"
}

@test "_load_setup_conf replace strategy: per-repo section fully replaces template section" {
  # Template [gpu] has mode+count+capabilities; per-repo only sets mode=off
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  unset SETUP_CONF
  local -a _k=() _v=()
  _load_setup_conf "${TEMP_DIR}" "gpu" _k _v
  # Replace strategy: only "mode" — no count, no capabilities inherited
  assert_equal "${#_k[@]}" "1"
  assert_equal "${_k[0]}" "mode"
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
# _resolve_gpu / _resolve_gui
# ════════════════════════════════════════════════════════════════════

@test "_resolve_gpu auto + detected=true => enabled" {
  local _out
  _resolve_gpu "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu auto + detected=false => disabled" {
  local _out
  _resolve_gpu "auto" "false" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gpu force => enabled regardless of detection" {
  local _out
  _resolve_gpu "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gpu off => disabled regardless of detection" {
  local _out
  _resolve_gpu "off" "true" _out
  assert_equal "${_out}" "false"
}

@test "_resolve_gui auto + detected=true => enabled" {
  local _out
  _resolve_gui "auto" "true" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui force => enabled regardless" {
  local _out
  _resolve_gui "force" "false" _out
  assert_equal "${_out}" "true"
}

@test "_resolve_gui off => disabled regardless" {
  local _out
  _resolve_gui "off" "true" _out
  assert_equal "${_out}" "false"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_runtime / _detect_jetson (Jetson NVIDIA runtime)
# ════════════════════════════════════════════════════════════════════

@test "_detect_jetson honors SETUP_DETECT_JETSON=true override" {
  SETUP_DETECT_JETSON=true _detect_jetson
}

@test "_detect_jetson honors SETUP_DETECT_JETSON=false override" {
  ! SETUP_DETECT_JETSON=false _detect_jetson
}

@test "_resolve_runtime auto on Jetson => nvidia" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "auto" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime nvidia => always nvidia" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_runtime "nvidia" _out
  assert_equal "${_out}" "nvidia"
}

@test "_resolve_runtime off => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "off" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime empty => empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_runtime unknown mode falls through to empty (safe default)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_runtime "garbage" _out
  assert_equal "${_out}" ""
}

# ════════════════════════════════════════════════════════════════════
# _resolve_build_network (Jetson build-net auto-detect, issue #102)
# ════════════════════════════════════════════════════════════════════

@test "_resolve_build_network auto on Jetson => host" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "auto" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network auto off Jetson => empty" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "auto" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network host => always host (explicit override wins)" {
  local _out
  SETUP_DETECT_JETSON=false _resolve_build_network "host" _out
  assert_equal "${_out}" "host"
}

@test "_resolve_build_network bridge / none / default pass through" {
  local _out
  _resolve_build_network "bridge" _out
  assert_equal "${_out}" "bridge"
  _resolve_build_network "none" _out
  assert_equal "${_out}" "none"
  _resolve_build_network "default" _out
  assert_equal "${_out}" "default"
}

@test "_resolve_build_network off / empty => empty (explicitly suppressed)" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "off" _out
  assert_equal "${_out}" ""
  SETUP_DETECT_JETSON=true _resolve_build_network "" _out
  assert_equal "${_out}" ""
}

@test "_resolve_build_network unknown mode falls through to empty" {
  local _out
  SETUP_DETECT_JETSON=true _resolve_build_network "garbage" _out
  assert_equal "${_out}" ""
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name (now reads [image] rules from setup.conf)
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name uses template default rules (prefix:docker_ → strip)" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/docker_myapp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name uses template default rules (suffix:_ws → strip)" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/projects/myapp_ws"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name template default falls through to @basename for generic paths" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/plainproject"
  assert_equal "${_result}" "plainproject"
}

@test "detect_image_name honors per-repo setup.conf [image] rules" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:foo_
rule_2 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/foo_bar"
  assert_equal "${_result}" "bar"
}

@test "detect_image_name rules apply in order (first match wins)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:docker_
rule_2 = suffix:_ws
rule_3 = @default:unused
EOF
  unset SETUP_CONF
  local _result
  # path has docker_ prefix AND _ws somewhere — prefix wins
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/myapp_ws/src/docker_nav"
  assert_equal "${_result}" "nav"
}

@test "detect_image_name @default:<value> used when no rule matches" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
rule_2 = @default:myfallback
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plain"
  assert_equal "${_result}" "myfallback"
}

@test "detect_image_name lowercases the result" {
  local _result
  unset SETUP_CONF
  detect_image_name _result "/home/user/docker_MyApp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name returns unknown when no rule matches and no @default" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plain"
  assert_equal "${_result}" "unknown"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
# ════════════════════════════════════════════════════════════════════

@test "detect_ws_path strategy 1: docker_* finds sibling *_ws" {
  local _ws_parent="${TEMP_DIR}/projects"
  mkdir -p "${_ws_parent}/docker_myapp" "${_ws_parent}/myapp_ws"
  local _result
  detect_ws_path _result "${_ws_parent}/docker_myapp"
  assert_equal "${_result}" "${_ws_parent}/myapp_ws"
}

@test "detect_ws_path strategy 1: docker_* without sibling falls through" {
  local _parent="${TEMP_DIR}/projects"
  mkdir -p "${_parent}/docker_myapp"
  local _result
  detect_ws_path _result "${_parent}/docker_myapp"
  assert_equal "${_result}" "${_parent}"
}

@test "detect_ws_path strategy 2: finds _ws component in path" {
  local _ws="${TEMP_DIR}/myapp_ws"
  mkdir -p "${_ws}/src"
  local _result
  detect_ws_path _result "${_ws}/src"
  assert_equal "${_result}" "${_ws}"
}

@test "detect_ws_path strategy 3: falls back to parent directory" {
  local _plain="${TEMP_DIR}/plain/project"
  mkdir -p "${_plain}"
  local _result
  detect_ws_path _result "${_plain}"
  assert_equal "${_result}" "${TEMP_DIR}/plain"
}

@test "detect_ws_path fails with ERROR when base_path does not exist" {
  run -1 detect_ws_path _r "${TEMP_DIR}/nope"
  assert_output --partial "base_path does not exist"
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash
# ════════════════════════════════════════════════════════════════════

@test "_compute_conf_hash returns a sha256-shaped hex string" {
  local _h
  _compute_conf_hash "${TEMP_DIR}" _h
  [[ "${_h}" =~ ^[0-9a-f]{64}$ ]]
}

@test "_compute_conf_hash differs when per-repo setup.conf changes" {
  local _h1 _h2
  _compute_conf_hash "${TEMP_DIR}" _h1
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF
  _compute_conf_hash "${TEMP_DIR}" _h2
  [[ "${_h1}" != "${_h2}" ]]
}

# ════════════════════════════════════════════════════════════════════
# write_env
# ════════════════════════════════════════════════════════════════════

@test "write_env creates .env with all required variables and SETUP_* metadata" {
  local _env="${TEMP_DIR}/.env"
  write_env "${_env}" \
    "testuser" "testgroup" "1001" "1001" \
    "x86_64" "dockerhub" "true" \
    "ros_noetic" "/workspace" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" \
    "all" "gpu" \
    "true" "abc123"

  assert [ -f "${_env}" ]
  run grep 'USER_NAME=testuser' "${_env}"; assert_success
  run grep 'USER_UID=1001'      "${_env}"; assert_success
  run grep 'GPU_ENABLED=true'   "${_env}"; assert_success
  run grep 'IMAGE_NAME=ros_noetic' "${_env}"; assert_success
  run grep 'NETWORK_MODE=host'  "${_env}"; assert_success
  run grep 'IPC_MODE=host'      "${_env}"; assert_success
  run grep 'PRIVILEGED=true'    "${_env}"; assert_success
  run grep 'GPU_COUNT=all'      "${_env}"; assert_success
  run grep -F 'GPU_CAPABILITIES="gpu"' "${_env}"; assert_success
  run grep 'SETUP_CONF_HASH=abc123' "${_env}"; assert_success
  run grep 'SETUP_GUI_DETECTED=true' "${_env}"; assert_success
  run grep -E '^SETUP_TIMESTAMP=' "${_env}"; assert_success
  run grep 'APT_MIRROR_UBUNTU=tw.archive.ubuntu.com' "${_env}"; assert_success
  run grep 'APT_MIRROR_DEBIAN=mirror.twds.com.tw' "${_env}"; assert_success
  run grep 'TZ=Asia/Taipei' "${_env}"; assert_success
  # bash-source round-trip: re-loading the file must not raise a
  # "command not found" on any multi-word value (regression: previously
  # GPU_CAPABILITIES="gpu compute utility graphics" was unquoted).
  run bash -c "set -o allexport; source '${_env}'"
  assert_success
  refute_output --partial "command not found"
}

# ════════════════════════════════════════════════════════════════════
# _check_setup_drift
# ════════════════════════════════════════════════════════════════════

@test "_check_setup_drift no-op when .env missing" {
  run _check_setup_drift "${TEMP_DIR}"
  assert_success
}

@test "_check_setup_drift silent when nothing changed" {
  # Prime .env by running a full setup cycle (write_env + _compute_conf_hash)
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h}"
  # stub detect_gui/detect_gpu to match stored false
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_success
  refute_output --partial "WARNING"
}

@test "_check_setup_drift returns non-zero when conf hash changes" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h_old}"
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.conf → hash differs
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run _check_setup_drift "${TEMP_DIR}"
  # Non-zero exit lets build.sh/run.sh trigger auto-regen (v0.9.5+).
  assert_failure
  assert_output --partial "drift detected"
  assert_output --partial "setup.conf modified"
}

@test "_check_setup_drift returns non-zero when GPU detection changes" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  # Store with GPU=false
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h}"
  # Now detection says true
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="true"; }

  run _check_setup_drift "${TEMP_DIR}"
  assert_failure
  assert_output --partial "GPU detection changed"
}

# ════════════════════════════════════════════════════════════════════
# main --lang + error paths (unchanged behaviour)
# ════════════════════════════════════════════════════════════════════

@test "main rejects bare flag without subcommand (#49 Phase B-4 BREAKING)" {
  # Pre-B-4 the legacy fall-through aliased flag-only invocation to
  # `apply`. B-4 removes that — the user must now type the subcommand
  # explicitly. Hits the unknown-subcommand path of the dispatcher.
  run main --bogus
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "apply subcommand returns error when --base-path value is missing" {
  run -127 bash -c "source /source/script/docker/setup.sh; main apply --base-path"
}

@test "apply subcommand returns error when --lang value is missing" {
  run -127 bash -c "source /source/script/docker/setup.sh; main apply --lang"
}

@test "apply --lang zh-TW sets Chinese messages for full run" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "更新完成"
}

# ── Per-repo setup.conf missing / empty INFO (issue #150) ────────────────
# When the per-repo setup.conf is absent, or present but has no section
# headers, every _load_setup_conf call falls back to the template default.
# That fallback used to be silent — surfacing one WARN line at apply()
# entry tells the user the entire run is template-default driven, without
# spamming a notice per section (11 sections would be noisy). #186
# promoted this from INFO to WARN so the heads-up doesn't scroll past.

@test "apply prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/setup.conf created — apply should fall back to template
  # default and announce it once on stderr at WARN level.
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN:"
  assert_output --partial "no per-repo setup.conf"
  refute_output --partial "[setup] INFO:"
}

@test "apply prints WARN when per-repo setup.conf has no section headers (#186)" {
  # Comments-only file counts as effectively empty: nothing to override.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
# only comments, no [section] headers
# template defaults apply for every section
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN:"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "apply stays silent when per-repo setup.conf has at least one section" {
  # Partial override is normal usage — don't INFO-spam users who edited
  # only one section.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = auto
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "no per-repo setup.conf"
  refute_output --partial "per-repo setup.conf has no section"
}

@test "apply --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)" {
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARN:"
  assert_output --partial "未找到"
}

@test "apply resolves default _base_path via BASH_SOURCE when --base-path omitted" {
  # apply without --base-path walks 3 levels up from its own location
  # (script/docker/../../.. = repo root).
  mkdir -p "${TEMP_DIR}/sandbox_repo/template/script/docker"
  cp /source/script/docker/setup.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh \
    "${TEMP_DIR}/sandbox_repo/template/script/docker/_tui_conf.sh"
  cp /source/setup.conf "${TEMP_DIR}/sandbox_repo/template/setup.conf"

  run bash "${TEMP_DIR}/sandbox_repo/template/script/docker/setup.sh" apply
  assert_success
  assert [ -f "${TEMP_DIR}/sandbox_repo/.env" ]
}

# ════════════════════════════════════════════════════════════════════
# Subcommand dispatch (#49 Phase B-1)
#
# setup.sh grew a git-style subcommand dispatcher so build.sh / run.sh
# stop sourcing it (which historically caused #101's _msg shadow bug).
# Subcommands wired in B-1: `apply` (default) + `check-drift`. Legacy
# flag-only invocation (`setup.sh --base-path X --lang Y`) still maps
# to apply for backward compat.
# ════════════════════════════════════════════════════════════════════

@test "main no-arg prints help and exits 0 (#49 Phase B-4 BREAKING)" {
  # Pre-B-4 the no-arg path silently aliased to `apply`. Now it prints
  # the same help screen as -h, so accidental invocations don't
  # clobber .env / compose.yaml without an explicit subcommand.
  run main
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "Subcommands:"
}

@test "main legacy flag-only invocation now errors (#49 Phase B-4 BREAKING)" {
  # `setup.sh --base-path X --lang Y` (no subcommand) used to alias to
  # apply. B-4 removes that; the user must type `apply` explicitly.
  run main --base-path "${TEMP_DIR}" --lang en
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "main apply subcommand regenerates .env + compose.yaml" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert [ -f "${TEMP_DIR}/.env" ]
  assert [ -f "${TEMP_DIR}/compose.yaml" ]
}

@test "main rejects unknown subcommand" {
  run main bogus-subcommand
  assert_failure
  assert_output --partial "Unknown subcommand"
}

@test "main check-drift returns 0 when .env missing (no-op)" {
  run main check-drift --base-path "${TEMP_DIR}"
  assert_success
}

@test "main check-drift returns 0 when nothing changed" {
  local _h=""
  _compute_conf_hash "${TEMP_DIR}" _h
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h}"
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  run main check-drift --base-path "${TEMP_DIR}"
  assert_success
}

@test "main check-drift returns non-zero when conf hash drifts" {
  local _h_old=""
  _compute_conf_hash "${TEMP_DIR}" _h_old
  write_env "${TEMP_DIR}/.env" \
    "user" "group" "$(id -u)" "$(id -g)" \
    "x86_64" "hub" "false" \
    "img" "${TEMP_DIR}" \
    "tw.archive.ubuntu.com" "mirror.twds.com.tw" "Asia/Taipei" \
    "host" "host" "true" "all" "gpu" \
    "false" "${_h_old}"
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run main check-drift --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "drift detected"
}

@test "check-drift prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/setup.conf created — check-drift should announce the
  # template-default fallback the same way `apply` does, so users
  # running the build.sh drift-check path see the heads-up too.
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARN:"
  assert_output --partial "no per-repo setup.conf"
}

@test "check-drift prints WARN when per-repo setup.conf has no section headers (#186)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
# only comments, no [section] headers
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARN:"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "check-drift stays silent when per-repo setup.conf has at least one section" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gpu]
mode = auto
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  refute_output --partial "no per-repo setup.conf"
  refute_output --partial "per-repo setup.conf has no section"
}

@test "check-drift --lang zh-TW prints WARN in Traditional Chinese when setup.conf missing (#186)" {
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' --lang zh-TW 2>&1
  "
  assert_output --partial "[setup] WARN:"
  assert_output --partial "未找到"
}

@test "main check-drift rejects unknown flag" {
  run main check-drift --bogus
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "setup.sh check-drift via subprocess emits stderr + non-zero exit on drift" {
  # End-to-end: invoke the script as a subprocess (the way build.sh / run.sh
  # do after B-1) instead of `source` + function call. Validates the
  # subcommand dispatch path actually works when the script is executed.
  mkdir -p "${TEMP_DIR}/sandbox/template/script/docker"
  cp /source/script/docker/setup.sh "${TEMP_DIR}/sandbox/template/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh "${TEMP_DIR}/sandbox/template/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh "${TEMP_DIR}/sandbox/template/script/docker/_tui_conf.sh"
  cp /source/setup.conf "${TEMP_DIR}/sandbox/template/setup.conf"

  bash "${TEMP_DIR}/sandbox/template/script/docker/setup.sh" apply \
    --base-path "${TEMP_DIR}/sandbox" >/dev/null 2>&1

  # #174: drift hash covers template + setup.conf. Mutating .local
  # after apply triggers detection.
  cat > "${TEMP_DIR}/sandbox/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run bash "${TEMP_DIR}/sandbox/template/script/docker/setup.sh" \
    check-drift --base-path "${TEMP_DIR}/sandbox"
  assert_failure
  assert_output --partial "drift detected"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: set / show / list (#49 Phase B-2)
#
# `setup.sh set <section>.<key> <value>` writes to setup.conf via
# `_upsert_conf_value` (no .env regen — `apply` is the explicit gate).
# `show` and `list` read setup.conf via `_load_setup_conf_full` so
# they share the TUI's view of the file.
# ════════════════════════════════════════════════════════════════════

@test "set writes a value into an existing section, round-trip via show" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set deploy.gpu_count all --base-path "${TEMP_DIR}"
  assert_success
  run main show deploy.gpu_count --base-path "${TEMP_DIR}"
  assert_success
  assert_output "all"
}

@test "set creates a new key when section exists but key is absent" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main set network.privileged true --base-path "${TEMP_DIR}"
  assert_success
  run main show network.privileged --base-path "${TEMP_DIR}"
  assert_success
  assert_output "true"
}

@test "set creates section + key when section is absent" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  run main set resources.shm_size 512m --base-path "${TEMP_DIR}"
  assert_success
  run main show resources.shm_size --base-path "${TEMP_DIR}"
  assert_success
  assert_output "512m"
}

@test "set rejects an unknown section with non-zero exit + Unknown section stderr" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set bogus.key value --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set rejects an invalid gpu_count value" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set deploy.gpu_count -1 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid mount string" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set volumes.mount_5 not-a-mount --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid cgroup_rule" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set devices.cgroup_rule_1 "garbage rule" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid env_kv" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set environment.env_5 "missing-equals" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid port mapping" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set network.port_5 "abc:def" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects a malformed dotted key (no dot)" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main set deploy_gpu_count all --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set with no arguments fails clean (no shell error)" {
  run main set
  assert_failure
  refute_output --partial "unbound variable"
  refute_output --partial "syntax error"
}

@test "set does NOT regenerate .env (mtime unchanged after set)" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  # Seed .env via apply so it exists.
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  assert [ -f "${TEMP_DIR}/.env" ]
  local _before
  _before="$(stat -c %Y "${TEMP_DIR}/.env")"
  # Wait one second so mtime resolution can register a difference if regen happened.
  sleep 1
  run main set network.mode host --base-path "${TEMP_DIR}"
  assert_success
  local _after
  _after="$(stat -c %Y "${TEMP_DIR}/.env")"
  assert_equal "${_before}" "${_after}"
}

@test "show prints the value of a single key" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  run main show network.mode --base-path "${TEMP_DIR}"
  assert_success
  assert_output "host"
}

@test "show prints all entries of a whole section in on-disk order" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
privileged = true
EOF
  run main show network --base-path "${TEMP_DIR}"
  assert_success
  assert_line --index 0 "mode = host"
  assert_line --index 1 "ipc = host"
  assert_line --index 2 "privileged = true"
}

@test "show returns non-zero on a missing key" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main show network.nope --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "show falls back to template baseline when section absent in .local (#174)" {
  # Pre-#174 this test asserted that show fails when the requested
  # section is missing from the per-repo file. After #174, show reads
  # the merged view (template ← .local), so the template baseline
  # always provides the section even when .local omits it. Switching
  # the assertion: show succeeds and surfaces the template's keys.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main show resources --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "shm_size"
}

@test "show rejects an unknown section name" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main show bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "show with no arguments fails clean" {
  run main show
  assert_failure
}

@test "list with no arg prints every section header + key" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename

[network]
mode = host
ipc = host
EOF
  run main list --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "[image]"
  assert_output --partial "rule_1 = @basename"
  assert_output --partial "[network]"
  assert_output --partial "mode = host"
}

@test "list <section> mirrors show <section>" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  run main list network --base-path "${TEMP_DIR}"
  assert_success
  assert_line --index 0 "mode = host"
  assert_line --index 1 "ipc = host"
}

@test "list <section> rejects an unknown section" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run main list bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set / show / list run end-to-end via subprocess" {
  mkdir -p "${TEMP_DIR}/sandbox/template/script/docker"
  cp /source/script/docker/setup.sh "${TEMP_DIR}/sandbox/template/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh "${TEMP_DIR}/sandbox/template/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh "${TEMP_DIR}/sandbox/template/script/docker/_tui_conf.sh"
  cp /source/setup.conf "${TEMP_DIR}/sandbox/setup.conf"

  run bash "${TEMP_DIR}/sandbox/template/script/docker/setup.sh" \
    set network.mode bridge --base-path "${TEMP_DIR}/sandbox"
  assert_success

  run bash "${TEMP_DIR}/sandbox/template/script/docker/setup.sh" \
    show network.mode --base-path "${TEMP_DIR}/sandbox"
  assert_success
  assert_output "bridge"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: add / remove (#49 Phase B-3)
#
# `setup.sh add <section>.<list> <value>` finds the next `<list>_N`
# (max+1) and writes via `_upsert_conf_value`.
# `setup.sh remove <section>.<key>` deletes a single keyed entry.
# `setup.sh remove <section>.<list> <value>` deletes the first key
# under <section> matching `<list>_*` whose value equals <value>.
# Validators wired through the same `_setup_validate_kv` table B-2
# uses for `set`. No .env regen — `apply` is still the explicit gate.
# ════════════════════════════════════════════════════════════════════

@test "main add appends mount to next available slot" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main add volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/b:/b"
}

@test "main add to empty section creates _1" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[environment]
EOF
  run main add environment.env FOO=bar --base-path "${TEMP_DIR}"
  assert_success
  run main show environment.env_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "FOO=bar"
}

@test "main add bootstraps setup.conf empty when missing (#174)" {
  rm -f "${TEMP_DIR}/setup.conf" "${TEMP_DIR}/setup.conf"
  run main add volumes.mount /foo:/bar --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.conf" ]
  # show reads template ← .local merge; the new mount lands in .local
  # and the merged view surfaces it through the next mount_<N> slot.
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "/foo:/bar"
}

@test "main add picks max+1 even with gap from prior remove" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_3 = /c:/c
EOF
  run main add volumes.mount /d:/d --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_4 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/d:/d"
}

@test "main add rejects unknown section" {
  : > "${TEMP_DIR}/setup.conf"
  run main add bogus.list /a:/a --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main add rejects invalid mount value" {
  : > "${TEMP_DIR}/setup.conf"
  run main add volumes.mount not-a-mount --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "main add rejects missing list / value" {
  run main add --base-path "${TEMP_DIR}"
  assert_failure
  run main add volumes.mount --base-path "${TEMP_DIR}"
  assert_failure
}

@test "main add does not regen .env" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  : > "${TEMP_DIR}/.env"
  local _before
  _before="$(stat -c '%Y' "${TEMP_DIR}/.env")"
  sleep 1
  run main add volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  local _after
  _after="$(stat -c '%Y' "${TEMP_DIR}/.env")"
  assert_equal "${_before}" "${_after}"
}

@test "main remove drops keyed entry" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
EOF
  run main remove volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_failure
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/b:/b"
}

@test "main remove by value finds matching key in list" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
mount_2 = /b:/b
mount_3 = /c:/c
EOF
  run main remove volumes.mount /b:/b --base-path "${TEMP_DIR}"
  assert_success
  run main show volumes.mount_2 --base-path "${TEMP_DIR}"
  assert_failure
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/a:/a"
}

@test "main remove fails when key missing" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount_99 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove by value fails when no value matches" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount /nonexistent:/x --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove rejects unknown section" {
  : > "${TEMP_DIR}/setup.conf"
  run main remove bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main remove preserves comments + remaining keys" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
# Top-of-file comment
[volumes]
# inline comment
mount_1 = /a:/a
mount_2 = /b:/b

[network]
mode = host
EOF
  run main remove volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  # #174: remove modifies setup.conf in-place; comments and
  # untouched keys survive the rewrite.
  run cat "${TEMP_DIR}/setup.conf"
  assert_output --partial "Top-of-file comment"
  assert_output --partial "inline comment"
  assert_output --partial "mount_2 = /b:/b"
  assert_output --partial "mode = host"
  refute_output --partial "mount_1"
}

@test "main add then remove round-trips" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[environment]
EOF
  run main add environment.env FOO=bar --base-path "${TEMP_DIR}"
  assert_success
  run main add environment.env BAZ=qux --base-path "${TEMP_DIR}"
  assert_success
  run main show environment --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "env_1 = FOO=bar"
  assert_output --partial "env_2 = BAZ=qux"
  run main remove environment.env_1 --base-path "${TEMP_DIR}"
  assert_success
  run main add environment.env NEW=val --base-path "${TEMP_DIR}"
  assert_success
  run main show environment.env_3 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "NEW=val"
}

@test "main add validates env_kv format" {
  : > "${TEMP_DIR}/setup.conf"
  run main add environment.env "no-equals-sign" --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "main add free-form image rule accepts arbitrary string" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  run main add image.rule "prefix:my_" --base-path "${TEMP_DIR}"
  assert_success
  run main show image.rule_2 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "prefix:my_"
}

# ════════════════════════════════════════════════════════════════════
# Subcommand: reset (#49 Phase B-4)
#
# `setup.sh reset [--yes]` overwrites <base-path>/setup.conf with the
# template default. Existing setup.conf → setup.conf.bak; existing
# .env → .env.bak (one-shot rollback path). Does NOT regenerate .env
# — the user invokes apply afterwards, or build/run will trigger
# auto-regen via drift detection on next run. --yes skips the
# interactive confirmation prompt; non-tty without --yes refuses to
# proceed (safety guard against accidental invocation in pipelines).
# ════════════════════════════════════════════════════════════════════

@test "main reset --yes clears setup.conf + setup.conf so next apply rebuilds (#174)" {
  mkdir -p "${TEMP_DIR}/template"
  cp /source/setup.conf "${TEMP_DIR}/template/setup.conf"
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
# user-customized
[network]
mode = bridge
EOF
  : > "${TEMP_DIR}/setup.conf"
  run bash -c "
    _SETUP_SCRIPT_DIR='${TEMP_DIR}/template/script/docker'
    mkdir -p \"\${_SETUP_SCRIPT_DIR}\"
    source /source/script/docker/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  # Override + materialized snapshot both removed — the next apply will
  # rebuild setup.conf purely from the template baseline.
  refute [ -f "${TEMP_DIR}/setup.conf" ]
  refute [ -f "${TEMP_DIR}/setup.conf" ]
}

@test "main reset --yes backs up prior setup.conf to .local.bak (#174)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
# CUSTOM_MARKER
[network]
mode = bridge
EOF
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/setup.conf.bak" ]
  run grep CUSTOM_MARKER "${TEMP_DIR}/setup.conf.bak"
  assert_success
}

@test "main reset --yes backs up prior .env to .env.bak" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  printf 'IMAGE_NAME=customimg\n' > "${TEMP_DIR}/.env"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.bak" ]
  run grep "IMAGE_NAME=customimg" "${TEMP_DIR}/.env.bak"
  assert_success
}

@test "main reset --yes does NOT regenerate .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  : > "${TEMP_DIR}/.env"
  local _before
  _before="$(stat -c '%Y' "${TEMP_DIR}/.env")"
  sleep 1
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # Either .env still has its prior mtime (file untouched), or it was
  # moved to .env.bak — but a fresh derived .env should NOT exist yet.
  if [[ -f "${TEMP_DIR}/.env" ]]; then
    local _after
    _after="$(stat -c '%Y' "${TEMP_DIR}/.env")"
    assert_equal "${_before}" "${_after}"
  fi
}

@test "main reset without --yes refuses non-tty (no confirmation possible)" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  # Bats runs without a controlling TTY — without --yes the handler
  # must refuse rather than silently destroy state.
  run main reset --base-path "${TEMP_DIR}"
  assert_failure
  refute [ -f "${TEMP_DIR}/setup.conf.bak" ]
}

@test "main reset rejects unknown flag" {
  run main reset --bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "main reset --yes works on first-time bootstrap (no prior .local or setup.conf) (#174)" {
  rm -f "${TEMP_DIR}/setup.conf" "${TEMP_DIR}/setup.conf"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # First-time bootstrap is a no-op: no override existed, no snapshot
  # existed, so nothing to clear and no .bak files written.
  refute [ -f "${TEMP_DIR}/setup.conf.bak" ]
  refute [ -f "${TEMP_DIR}/setup.conf.bak" ]
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

@test "detect_image_name uses @basename rule alone (exercises _rule_basename)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plainname"
  assert_equal "${_result}" "plainname"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name sanitization
#
# docker compose project names + image tags forbid '.' and anything
# outside [a-z0-9_-]. detect_image_name must normalise whatever the
# rules produce so downstream `docker compose -p <name>` doesn't
# reject the generated project name.
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name replaces '.' with '-' (regression: tmp.abcdef → tmp-abcdef)" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/tmp.abcdef"
  assert_equal "${_result}" "tmp-abcdef"
}

@test "detect_image_name collapses runs of '-' and strips leading/trailing separators" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/..weird..name.."
  [[ "${_result}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
  assert_equal "${_result}" "weird-name"
}

# ════════════════════════════════════════════════════════════════════
# i18n
# ════════════════════════════════════════════════════════════════════

@test "_setup_msg returns English messages by default" {
  _LANG="en"
  [[ "$(_setup_msg env_done)" =~ updated ]]
}

@test "_setup_msg returns Traditional Chinese messages when _LANG=zh-TW" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env_done)" =~ 更新完成 ]]
}

@test "_setup_msg returns Simplified Chinese messages when _LANG=zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env_done)" =~ 更新完成 ]]
}

@test "_setup_msg returns Japanese messages when _LANG=ja" {
  _LANG="ja"
  [[ "$(_setup_msg env_done)" =~ 更新完了 ]]
}

# Exercise every (key, language) branch so kcov sees the zh-CN / ja / default
# `unknown_arg` and `env_comment` case-arms. The env_done-only tests above
# only land on the first case of each language block.

@test "_setup_msg env_comment and unknown_arg are defined in zh" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env_comment)" =~ 自動偵測 ]]
  [[ "$(_setup_msg unknown_arg)" =~ 未知參數 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env_comment)" =~ 自动检测 ]]
  [[ "$(_setup_msg unknown_arg)" =~ 未知参数 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in ja" {
  _LANG="ja"
  [[ "$(_setup_msg env_comment)" =~ 自動検出 ]]
  [[ "$(_setup_msg unknown_arg)" =~ 不明な引数 ]]
}

@test "_msg falls back to English when _LANG is unknown" {
  _LANG="xx"
  [[ "$(_setup_msg env_done)" =~ updated ]]
  [[ "$(_setup_msg env_comment)" =~ Auto-detected ]]
  [[ "$(_setup_msg unknown_arg)" =~ "Unknown argument" ]]
}

# ════════════════════════════════════════════════════════════════════
# [build] section (arg_N KEY=VALUE schema)
# ════════════════════════════════════════════════════════════════════

@test "[build] template defaults ship TW mirrors via arg_N" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=tw.archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=mirror.twds.com.tw"
}

@test "[build] arg_N override replaces TW default when set" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_1 \
    "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_2 \
    "APT_MIRROR_DEBIAN=deb.debian.org"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^APT_MIRROR_DEBIAN=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  assert_output --partial "APT_MIRROR_DEBIAN=deb.debian.org"
}

@test "[build] back-compat: old apt_mirror_* named keys still read" {
  # Legacy repo setup.conf with the pre-arg_N schema must keep working
  # so users can upgrade template without rewriting setup.conf first.
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[build]
apt_mirror_ubuntu = mirror.example.com
tz = Asia/Tokyo
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^APT_MIRROR_UBUNTU=' '${TEMP_DIR}/.env'
    grep '^TZ=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "APT_MIRROR_UBUNTU=mirror.example.com"
  assert_output --partial "TZ=Asia/Tokyo"
}

@test "[build] user-added arg_N propagates to .env" {
  # Dockerfile with `ARG PYTHON_VERSION` can pick up a user-added
  # build arg. Extra args land in .env so compose build.args can
  # reference them.
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build arg_9 \
    "PYTHON_VERSION=3.12"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
    grep '^PYTHON_VERSION=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "PYTHON_VERSION=3.12"
}

@test "[build] target_arch = arm64 writes TARGET_ARCH to .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build target_arch arm64
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^TARGET_ARCH=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "TARGET_ARCH=arm64"
}

@test "[build] target_arch empty omits TARGET_ARCH from .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  # Explicit empty value (the template's default)
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build target_arch ""
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^TARGET_ARCH=' '${TEMP_DIR}/.env'
  "
  # grep -c prints "0" and exits 1 when pattern missing; we want exactly that.
  assert_failure
  assert_output "0"
}

@test "[build] network = host writes BUILD_NETWORK to .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build network host
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^BUILD_NETWORK=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "BUILD_NETWORK=host"
}

@test "[build] network empty omits BUILD_NETWORK from .env" {
  cp /source/setup.conf "${TEMP_DIR}/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/setup.conf" build network ""
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^BUILD_NETWORK=' '${TEMP_DIR}/.env'
  "
  assert_failure
  assert_output "0"
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

# ════════════════════════════════════════════════════════════════════
# Workspace writeback (first-time / user edit / opt-out)
# ════════════════════════════════════════════════════════════════════

@test "workspace first-time: writes \${WS_PATH} variable form (portable)" {
  # Regression (v0.9.4): writeback used to bake the absolute host path
  # into setup.conf. Committing that file broke other machines whose
  # filesystem layout differed. Now we write the \${WS_PATH} variable
  # form so docker-compose resolves it per-machine from .env.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  assert [ -f "${_repo}/setup.conf" ]
  run grep '^mount_1' "${_repo}/setup.conf"
  assert_output --partial '${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: \${WS_PATH} form re-detects per machine" {
  # Round-trip: first-time writes \${WS_PATH} form → second run reads
  # setup.conf, sees the variable reference, and re-runs detect_ws_path
  # so WS_PATH in .env reflects THIS machine (not the one that first
  # committed the file).
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
    grep '^mount_1' '${_repo}/setup.conf'
  "
  assert_success
  # WS_PATH is a non-empty absolute path — exact value depends on the
  # sandbox, but it must not be the literal variable string.
  refute_output --partial 'WS_PATH=${WS_PATH}'
  assert_output --regexp 'WS_PATH=/[^[:space:]]+'
  # mount_1 stays as the portable variable form.
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "workspace second-run: respects user-pinned absolute path via setup.conf (#174)" {
  local _repo="${TEMP_DIR}/repo"
  local _pin="${TEMP_DIR}/custom_ws"
  mkdir -p "${_repo}" "${_pin}"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # #174: user pins go into the override file (.local), not the
  # materialized snapshot.
  cat > "${_repo}/setup.conf" <<EOF
[volumes]
mount_1 = ${_pin}:/home/\${USER_NAME}/work
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
    grep '^mount_1' '${_repo}/setup.conf'
  "
  assert_success
  # Effective WS_PATH on this machine is the user-pinned absolute path.
  assert_output --partial "WS_PATH=${_pin}"
  # The override file (.local) keeps the pinned form verbatim — apply
  # doesn't rewrite user intent.
  assert_output --partial "mount_1 = ${_pin}:"
}

@test "workspace second-run: stale setup.conf path is harmlessly overwritten (#174)" {
  # Pre-#174 setup.conf was tracked → cross-machine clones inherited
  # alice's absolute path on bob's checkout, forcing setup.sh to
  # detect-and-rewrite. Post-#174 setup.conf is gitignored + a derived
  # snapshot, so the only way a "stale" path lands is a manual edit
  # between applies. Apply now silently regenerates setup.conf from
  # template + .local (which contain the portable form) — no warning
  # needed, the stale value is gone after one apply.
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  sed -i 's|^mount_1.*|mount_1 = /nonexistent/stale/ws:/home/${USER_NAME}/work|' \
    "${_repo}/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
  "
  assert_success
  # Stale path does not leak into .env (apply regenerates from .local +
  # template + fresh ws_path detection, ignoring the manually-mutated
  # setup.conf entry for [volumes]).
  refute_output --partial "WS_PATH=/nonexistent/stale/ws"
}

@test "fresh bootstrap: empty dir + main apply emits workspace mount in compose.yaml (#201 regression)" {
  # Pre-#201 bug: bootstrap wrote mount_1 to <repo>/setup.conf, then
  # immediately reloaded via _load_setup_conf which only consulted
  # setup.conf.local (empty) + template (empty mount_1). The just-written
  # value was lost and compose.yaml omitted the workspace mount.
  # Post-#201 (2-file model): bootstrap writes to <repo>/setup.conf and
  # _load_setup_conf reads from the same file, so the reload picks up
  # the freshly-written mount_1.
  local _repo="${TEMP_DIR}/fresh"
  mkdir -p "${_repo}"
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
  "
  assert_success
  # compose.yaml contains the workspace mount line (portable form)
  run grep -F -- '${WS_PATH}:/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_success
}

@test "workspace opt-out: cleared mount_1 means no workspace mount in compose" {
  local _repo="${TEMP_DIR}/repo"
  mkdir -p "${_repo}"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # User clears mount_1 (opt-out)
  sed -i 's|^mount_1.*|mount_1 =|' "${_repo}/setup.conf"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # mount_1 stays empty (not re-populated)
  run grep '^mount_1' "${_repo}/setup.conf"
  assert_equal "${output}" "mount_1 ="
  # compose.yaml has no workspace mount
  run grep ':/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name string rule
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name string:<value> short-circuits path parsing" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = string:my_app
rule_2 = prefix:docker_
rule_3 = @default:should_not_reach
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/docker_something"
  assert_equal "${_result}" "my_app"
}

@test "detect_image_name string value is still lowercased + sanitized" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[image]
rule_1 = string:My.App.Name
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/whatever"
  assert_equal "${_result}" "my-app-name"
}

# ════════════════════════════════════════════════════════════════════
# Per-section setup.conf parameter end-to-end coverage (#202)
#
# Each test sets a single key in <repo>/setup.conf and asserts the
# expected line appears in compose.yaml or .env. Companion negative
# tests confirm the corresponding compose / env block is omitted when
# the key is empty / cleared. Ensures every key documented in
# template/setup.conf has a setting → output assertion.
# ════════════════════════════════════════════════════════════════════

# ── [deploy] ─────────────────────────────────────────────────────────

@test "[deploy] gpu_mode = off omits deploy.resources block from compose.yaml" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'deploy:' '${TEMP_DIR}/compose.yaml' | head -1
  "
  assert_output ""
}

@test "[deploy] gpu_mode = force emits deploy.resources GPU block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = all
gpu_capabilities = gpu compute
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'driver: nvidia' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] gpu_count = 2 emits count: 2 in compose deploy block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = 2
gpu_capabilities = gpu
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'count: 2$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] gpu_capabilities multi-value emits as YAML array" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = force
gpu_count = all
gpu_capabilities = gpu compute utility
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'capabilities: [gpu, compute, utility]' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] runtime = nvidia emits runtime: nvidia at service level" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
runtime = nvidia
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^    runtime: nvidia$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[deploy] runtime = off omits runtime line entirely" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[deploy]
gpu_mode = off
runtime = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    runtime:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [gui] ────────────────────────────────────────────────────────────

@test "[gui] mode = off omits X11 / DISPLAY env from compose" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gui]
mode = off
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'DISPLAY' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

@test "[gui] mode = force emits X11 environment + /tmp/.X11-unix mount" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/tmp/.X11-unix:/tmp/.X11-unix:ro' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [network] ────────────────────────────────────────────────────────

@test "[network] mode = host writes NETWORK_MODE=host to .env" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^NETWORK_MODE=' '${TEMP_DIR}/.env'
  "
  assert_output "NETWORK_MODE=host"
}

@test "[network] ipc = private writes IPC_MODE=private to .env" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = private
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^IPC_MODE=' '${TEMP_DIR}/.env'
  "
  assert_output "IPC_MODE=private"
}

@test "[network] network_name = my_bridge under mode=bridge emits external network ref" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = bridge
ipc = private
network_name = my_bridge
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^networks:' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[network] port_1 = 8080:80 emits ports: block under bridge mode" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = bridge
ipc = private
port_1 = 8080:80
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '8080:80' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[network] port_* under mode=host is silently dropped" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
port_1 = 8080:80
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '8080:80' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [resources] ──────────────────────────────────────────────────────

@test "[resources] shm_size = 2gb under ipc=private emits shm_size: 2gb" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[network]
ipc = private
[resources]
shm_size = 2gb
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E 'shm_size: 2gb' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[resources] shm_size empty omits shm_size line" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[resources]
shm_size =
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c 'shm_size:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [environment] ────────────────────────────────────────────────────

@test "[environment] env_1 = ROS_DOMAIN_ID=7 emits environment: block in compose" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[environment]
env_1 = ROS_DOMAIN_ID=7
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'ROS_DOMAIN_ID=7' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[environment] empty section omits environment: block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[environment]
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    environment:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [tmpfs] ──────────────────────────────────────────────────────────

@test "[tmpfs] tmpfs_1 = /tmp emits tmpfs: block with the entry" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[tmpfs]
tmpfs_1 = /tmp
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^      - /tmp$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[tmpfs] tmpfs_1 with size= suffix preserved verbatim" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[tmpfs]
tmpfs_1 = /tmp/cache:size=1g
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/tmp/cache:size=1g' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[tmpfs] empty section omits tmpfs: block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[tmpfs]
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -c '^    tmpfs:' '${TEMP_DIR}/compose.yaml' || true
  "
  assert_output "0"
}

# ── [devices] ────────────────────────────────────────────────────────

@test "[devices] device_1 = /dev/video0:/dev/video0 emits devices: block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[devices]
device_1 = /dev/video0:/dev/video0
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E -- '- /dev/video0:/dev/video0' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[devices] cgroup_rule_1 emits device_cgroup_rules: block" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[devices]
device_1 = /dev:/dev
cgroup_rule_1 = c 189:* rwm
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F 'c 189:* rwm' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [volumes] mount_2..N ─────────────────────────────────────────────

@test "[volumes] mount_2 = /data:/data emits as additional volume entry" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /data:/data
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E -- '- /data:/data' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

@test "[volumes] mount_N supports :ro suffix" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /etc/machine-id:/etc/machine-id:ro
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -F '/etc/machine-id:/etc/machine-id:ro' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
}

# ── [security] privileged toggle ─────────────────────────────────────

@test "[security] privileged = false writes PRIVILEGED=false to .env" {
  cat > "${TEMP_DIR}/setup.conf" <<'EOF'
[security]
privileged = false
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^PRIVILEGED=' '${TEMP_DIR}/.env'
  "
  assert_output "PRIVILEGED=false"
}
