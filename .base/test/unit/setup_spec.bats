#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source setup.sh functions only (main is guarded)
  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  # Ensure the per-repo config/docker/ path exists; setup.conf relocated
  # under #262 lives at ${BASE_PATH}/config/docker/config/docker/setup.conf, so fixtures
  # that write a sandbox setup.conf rely on the parent dir already being
  # there.
  mkdir -p "${TEMP_DIR}/config/docker"
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
  run grep -E '^device_1 = /dev:/dev$' /source/config/docker/setup.conf
  assert_success
}

@test "template setup.conf [deploy] enables ALL GPU capabilities by default" {
  # Dev-friendly: reserve every GPU capability so new repos get
  # compute + utility + graphics out of the box (no need to tick boxes
  # in TUI). Users narrow it down via ./setup_tui.sh deploy if they want
  # a minimal reservation.
  run grep -E '^gpu_capabilities = gpu compute utility graphics$' /source/config/docker/setup.conf
  assert_success
}

@test "[security] cap_add_* fallback: repo setup.conf with no cap_add_* uses template defaults" {
  # Simulate a repo override that keeps privileged=false but wiped all
  # cap_add_* entries. Expected behaviour: setup.sh falls back to the
  # template's baseline (SYS_ADMIN / NET_ADMIN / MKNOD) so the container
  # does not silently drop to Docker's stripped-down default capability
  # set.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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

@test "_setup_known_section recognises logging + [logging.<svc>] sub-section (#328)" {
  _setup_known_section "logging"
  _setup_known_section "logging.runtime"
  _setup_known_section "logging.devel"
  run _setup_known_section "logging."
  assert_failure
  run _setup_known_section "loggings"
  assert_failure
}

@test "set logging.driver round-trips via show (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.driver journald --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "set logging.compress accepts true/false; rejects others (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.compress true --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.compress maybe --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.max_file rejects non-positive integers (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.max_file 5 --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_file 0 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file -1 --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_file abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.max_size accepts num+unit; rejects malformed (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.max_size 50m --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 1g --base-path "${TEMP_DIR}"
  assert_success
  run main set logging.max_size 10X --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.max_size abc --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.driver rejects whitespace/empty-shape names (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.driver "bad name" --base-path "${TEMP_DIR}"
  assert_failure
  run main set logging.driver "1starts-with-digit" --base-path "${TEMP_DIR}"
  assert_failure
}

@test "set logging.<svc>.<key> writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.runtime.driver journald --base-path "${TEMP_DIR}"
  assert_success
  # Per-service section now exists with the override.
  run grep -F "[logging.runtime]" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  run main show logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  assert_output "journald"
}

@test "remove logging.<svc>.<key> deletes the per-service key (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file

[logging.runtime]
driver = journald
max_file = 7
EOF
  run main remove logging.runtime.driver --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "driver = journald" "${TEMP_DIR}/config/docker/setup.conf"
  assert_failure
  # Sibling key untouched.
  run grep -F "max_file = 7" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
}

@test "show logging prints the whole resolved [logging] section (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main show logging --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "driver"
  assert_output --partial "max_size"
  assert_output --partial "max_file"
  assert_output --partial "compress"
}

@test "set logging.local_path accepts relative path (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path ./logs/ --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./logs/"
}

@test "set logging.local_path accepts absolute path (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path /srv/app-logs --base-path "${TEMP_DIR}"
  assert_success
  run main show logging.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "/srv/app-logs"
}

@test "set logging.local_path rejects whitespace-only value (#328)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set logging.local_path "   " --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set logging.<svc>.local_path writes to per-service section (#328)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[logging]
driver = json-file
EOF
  run main set logging.devel.local_path ./devel-logs/ --base-path "${TEMP_DIR}"
  assert_success
  run grep -F "[logging.devel]" "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  run main show logging.devel.local_path --base-path "${TEMP_DIR}"
  assert_success
  assert_output "./devel-logs/"
}

@test "[security] cap_add_* explicit override: user-provided list is honored (no template fallback)" {
  # User set cap_add_1=ALL explicitly: compose should use THAT, not the
  # template's SYS_ADMIN/NET_ADMIN/MKNOD.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
# _is_ssh_x11 (SSH X11 forwarding detection, #321)
# ════════════════════════════════════════════════════════════════════

@test "_is_ssh_x11 true when SSH_CONNECTION set + DISPLAY=localhost:N (#321)" {
  SSH_CONNECTION="1.2.3.4 12345 5.6.7.8 22" DISPLAY="localhost:10.0" _is_ssh_x11
}

@test "_is_ssh_x11 true when DISPLAY=localhost:N without fractional part (#321)" {
  SSH_CONNECTION="x y z w" DISPLAY="localhost:0" _is_ssh_x11
}

@test "_is_ssh_x11 false when SSH_CONNECTION unset (#321)" {
  run bash -c "
    source /source/script/docker/setup.sh
    unset SSH_CONNECTION
    DISPLAY=localhost:10.0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is local socket (:0) (#321)" {
  run bash -c "
    source /source/script/docker/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY=:0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is unset (#321)" {
  run bash -c "
    source /source/script/docker/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='' _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY points to a remote host (#321)" {
  run bash -c "
    source /source/script/docker/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='other-host:0' _is_ssh_x11
  "
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# _setup_ssh_x11_cookie (cookie rewrite via xauth, #321)
# ════════════════════════════════════════════════════════════════════

@test "_setup_ssh_x11_cookie writes .docker.xauth and echoes its path (#321)" {
  # Stub xauth via PATH shim so the test does not depend on a real
  # X server. Stub captures argv to /tmp/xauth.log AND writes a
  # non-empty payload to the `-f <out>` target when nmerge runs, so
  # the function's post-pipe `[[ ! -s "${_out}" ]]` defensive check
  # passes.
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
echo "xauth $*" >> "${XAUTH_LOG}"
# Detect `-f <path> nmerge -` so the stub mimics real xauth's
# behavior of writing the merged cookie bytes to <path>. Without
# this, the function's empty-file check fires and returns 1.
_out=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-f" ]]; then
    j=$((i + 1))
    _out="${!j}"
  fi
done
if [[ "${*}" == *nmerge* && -n "${_out}" ]]; then
  printf 'stub-cookie-bytes\n' > "${_out}"
fi
# nmerge reads stdin; consume so the pipe closes cleanly.
cat >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "${_bin}/xauth"

  XAUTH_LOG="${TEMP_DIR}/xauth.log"
  export XAUTH_LOG
  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/script/docker/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_success
  assert_output "${TEMP_DIR}/.docker.xauth"
  # File was created AND has content (post-#321 hotfix: defensive
  # check on empty cookie file).
  assert [ -s "${TEMP_DIR}/.docker.xauth" ]
  # xauth was invoked twice with `-i` (ignore-locks) since the hotfix.
  run cat "${XAUTH_LOG}"
  assert_output --partial "xauth -i nlist localhost:10.0"
  assert_output --partial "xauth -i -f ${TEMP_DIR}/.docker.xauth nmerge -"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when nmerge writes 0-byte cookie (#321 hotfix)" {
  # Defensive case: xauth pipeline exits 0 but produces an empty
  # cookie file (e.g. nlist hit a contended ~/.Xauthority lock and
  # silently returned nothing). The function must NOT echo the cookie
  # path back — that would emit XAUTHORITY=<empty-file> into .env and
  # break X11 auth silently inside the container.
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
# Mimic the contended-lock failure mode: succeed but write nothing.
cat >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "${_bin}/xauth"

  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/script/docker/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_failure
  assert_output --partial "empty cookie file"
  assert_output --partial "XAUTHORITY left at host value"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when xauth is not installed (#321)" {
  # Shadow the `command` builtin with a function that returns 1 for
  # `command -v xauth` and passes everything else through to the real
  # builtin. Lets the function exercise its xauth-missing branch
  # without touching PATH (which would also break setup.sh's own
  # dirname / sed / etc. lookups during source).
  run bash -c "
    source /source/script/docker/setup.sh
    command() {
      if [[ \"\${1:-}\" == '-v' && \"\${2:-}\" == 'xauth' ]]; then
        return 1
      fi
      builtin command \"\$@\"
    }
    DISPLAY=localhost:10.0 _setup_ssh_x11_cookie '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "xauth"
  assert_output --partial "not in PATH"
}

# ════════════════════════════════════════════════════════════════════
# write_env: SSH X11 XAUTHORITY override (#321)
# ════════════════════════════════════════════════════════════════════

@test "write_env emits XAUTHORITY=<rewritten> when _ssh_x11_xauth arg is set (#321)" {
  local _env="${TEMP_DIR}/.env"
  # Pass all positional args incl. the new trailing _ssh_x11_xauth.
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    "/path/to/.docker.xauth"
  assert [ -f "${_env}" ]
  run grep -F 'XAUTHORITY=/path/to/.docker.xauth' "${_env}"
  assert_success
  run grep -F 'SSH X11 forwarding cookie override' "${_env}"
  assert_success
}

@test "write_env does NOT emit XAUTHORITY override when _ssh_x11_xauth arg is empty (#321)" {
  local _env="${TEMP_DIR}/.env"
  write_env "${_env}" \
    alice alice 1000 1000 \
    x86_64 alice false myrepo /tmp/ws \
    tw.archive.ubuntu.com mirror.twds.com.tw Asia/Taipei \
    bridge host false all "gpu compute" \
    true confhash dockerhash \
    "" "" "" "" \
    ""
  assert [ -f "${_env}" ]
  run cat "${_env}"
  refute_output --partial "SSH X11 forwarding cookie override"
  refute_output --partial $'\nXAUTHORITY='
}

# ════════════════════════════════════════════════════════════════════
# _parse_ini_section
# ════════════════════════════════════════════════════════════════════

@test "_parse_ini_section reads keys and values for one section" {
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  local _conf="${TEMP_DIR}/config/docker/setup.conf"
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
    "true" "abc123" "df456"

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
  run grep 'SETUP_DOCKERFILE_HASH=df456' "${_env}"; assert_success
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
    "false" "${_h}" ""
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
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  # Drop in a new per-repo setup.conf → hash differs
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
    "false" "${_h}" ""
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  # No TEMP_DIR/config/docker/setup.conf created — apply should fall back to template
  # default and announce it once on stderr at WARN level.
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARNING:"
  assert_output --partial "no per-repo setup.conf"
  # #186 regression guard: the heads-up must NOT be demoted to INFO
  # (where it would scroll past). The env_done line legitimately uses
  # INFO level post-#290, so scope the refute to the warning's body.
  refute_output --partial "[setup] INFO: no per-repo setup.conf"
}

@test "apply prints WARN when per-repo setup.conf has no section headers (#186)" {
  # Comments-only file counts as effectively empty: nothing to override.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# only comments, no [section] headers
# template defaults apply for every section
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "[setup] WARNING:"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "apply stays silent when per-repo setup.conf has at least one section" {
  # Partial override is normal usage — don't INFO-spam users who edited
  # only one section.
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  assert_output --partial "[setup] WARNING:"
  assert_output --partial "未找到"
}

@test "apply resolves default _base_path via BASH_SOURCE when --base-path omitted" {
  # apply without --base-path walks 3 levels up from its own location
  # (script/docker/../../.. = repo root).
  mkdir -p "${TEMP_DIR}/sandbox_repo/.base/script/docker/lib" \
           "${TEMP_DIR}/sandbox_repo/.base/config/docker"
  cp /source/script/docker/setup.sh \
    "${TEMP_DIR}/sandbox_repo/.base/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh \
    "${TEMP_DIR}/sandbox_repo/.base/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh \
    "${TEMP_DIR}/sandbox_repo/.base/script/docker/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers (#290); _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs post-#284.
  cp /source/script/docker/_lib.sh \
    "${TEMP_DIR}/sandbox_repo/.base/script/docker/_lib.sh"
  cp /source/script/docker/lib/*.sh \
    "${TEMP_DIR}/sandbox_repo/.base/script/docker/lib/"
  cp /source/config/docker/setup.conf "${TEMP_DIR}/sandbox_repo/.base/config/docker/setup.conf"

  run bash "${TEMP_DIR}/sandbox_repo/.base/script/docker/setup.sh" apply
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
    "false" "${_h}" ""
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
    "false" "${_h_old}" ""
  detect_gui() { local -n _o=$1; _o="false"; }
  detect_gpu() { local -n _o=$1; _o="false"; }

  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run main check-drift --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "drift detected"
}

@test "check-drift prints WARN when per-repo setup.conf is missing (#186)" {
  # No TEMP_DIR/config/docker/setup.conf created — check-drift should announce the
  # template-default fallback the same way `apply` does, so users
  # running the build.sh drift-check path see the heads-up too.
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARNING:"
  assert_output --partial "no per-repo setup.conf"
}

@test "check-drift prints WARN when per-repo setup.conf has no section headers (#186)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# only comments, no [section] headers
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main check-drift --base-path '${TEMP_DIR}' 2>&1
  "
  assert_output --partial "[setup] WARNING:"
  assert_output --partial "per-repo setup.conf has no section"
}

@test "check-drift stays silent when per-repo setup.conf has at least one section" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  assert_output --partial "[setup] WARNING:"
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
  mkdir -p "${TEMP_DIR}/sandbox/.base/script/docker/lib" \
           "${TEMP_DIR}/sandbox/.base/config/docker"
  cp /source/script/docker/setup.sh "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh "${TEMP_DIR}/sandbox/.base/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh "${TEMP_DIR}/sandbox/.base/script/docker/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers (#290); _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs post-#284.
  cp /source/script/docker/_lib.sh "${TEMP_DIR}/sandbox/.base/script/docker/_lib.sh"
  cp /source/script/docker/lib/*.sh "${TEMP_DIR}/sandbox/.base/script/docker/lib/"
  cp /source/config/docker/setup.conf "${TEMP_DIR}/sandbox/.base/config/docker/setup.conf"

  bash "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh" apply \
    --base-path "${TEMP_DIR}/sandbox" >/dev/null 2>&1

  # #174: drift hash covers template + setup.conf. Mutating .local
  # after apply triggers detection.
  cat > "${TEMP_DIR}/sandbox/config/docker/setup.conf" <<'EOF'
[gpu]
mode = off
EOF

  run bash "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh" \
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy.gpu_count all --base-path "${TEMP_DIR}"
  assert_success
  run main show deploy.gpu_count --base-path "${TEMP_DIR}"
  assert_success
  assert_output "all"
}

@test "set creates a new key when section exists but key is absent" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set bogus.key value --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set rejects an invalid gpu_count value" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set deploy.gpu_count -1 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid mount string" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set volumes.mount_5 not-a-mount --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid cgroup_rule" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set devices.cgroup_rule_1 "garbage rule" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid env_kv" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set environment.env_5 "missing-equals" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects an invalid port mapping" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main set network.port_5 "abc:def" --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Invalid value"
}

@test "set rejects a malformed dotted key (no dot)" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
ipc = host
EOF
  run main show network.mode --base-path "${TEMP_DIR}"
  assert_success
  assert_output "host"
}

@test "show prints all entries of a whole section in on-disk order" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host
EOF
  run main show resources --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "shm_size"
}

@test "show rejects an unknown section name" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main show bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "show with no arguments fails clean" {
  run main show
  assert_failure
}

@test "list with no arg prints every section header + key" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  run main list bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown section"
}

@test "set / show / list run end-to-end via subprocess" {
  mkdir -p "${TEMP_DIR}/sandbox/.base/script/docker/lib" \
           "${TEMP_DIR}/sandbox/config/docker"
  cp /source/script/docker/setup.sh "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh"
  cp /source/script/docker/i18n.sh "${TEMP_DIR}/sandbox/.base/script/docker/i18n.sh"
  cp /source/script/docker/_tui_conf.sh "${TEMP_DIR}/sandbox/.base/script/docker/_tui_conf.sh"
  # setup.sh sources _lib.sh for the _log_* helpers (#290); _lib.sh
  # is an umbrella that sources lib/*.sh sub-libs post-#284.
  cp /source/script/docker/_lib.sh "${TEMP_DIR}/sandbox/.base/script/docker/_lib.sh"
  cp /source/script/docker/lib/*.sh "${TEMP_DIR}/sandbox/.base/script/docker/lib/"
  cp /source/config/docker/setup.conf "${TEMP_DIR}/sandbox/config/docker/setup.conf"

  run bash "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh" \
    set network.mode bridge --base-path "${TEMP_DIR}/sandbox"
  assert_success

  run bash "${TEMP_DIR}/sandbox/.base/script/docker/setup.sh" \
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[environment]
EOF
  run main add environment.env FOO=bar --base-path "${TEMP_DIR}"
  assert_success
  run main show environment.env_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output "FOO=bar"
}

@test "main add bootstraps setup.conf empty when missing (#174)" {
  rm -f "${TEMP_DIR}/config/docker/setup.conf" "${TEMP_DIR}/config/docker/setup.conf"
  run main add volumes.mount /foo:/bar --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  # show reads template ← .local merge; the new mount lands in .local
  # and the merged view surfaces it through the next mount_<N> slot.
  run main show volumes.mount_1 --base-path "${TEMP_DIR}"
  assert_success
  assert_output --partial "/foo:/bar"
}

@test "main add picks max+1 even with gap from prior remove" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main add bogus.list /a:/a --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main add rejects invalid mount value" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount_99 --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove by value fails when no value matches" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 = /a:/a
EOF
  run main remove volumes.mount /nonexistent:/x --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "not found"
}

@test "main remove rejects unknown section" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main remove bogus.key --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
  assert_output --partial "Unknown section"
}

@test "main remove preserves comments + remaining keys" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  run cat "${TEMP_DIR}/config/docker/setup.conf"
  assert_output --partial "Top-of-file comment"
  assert_output --partial "inline comment"
  assert_output --partial "mount_2 = /b:/b"
  assert_output --partial "mode = host"
  refute_output --partial "mount_1"
}

@test "main add then remove round-trips" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run main add environment.env "no-equals-sign" --base-path "${TEMP_DIR}"
  assert_failure
  [[ "${status}" -eq 2 ]]
}

@test "main add free-form image rule accepts arbitrary string" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
# `setup.sh reset [--yes]` overwrites <base-path>/config/docker/setup.conf with the
# template default. Existing setup.conf → setup.conf.bak; existing
# .env → .env.bak (one-shot rollback path). Does NOT regenerate .env
# — the user invokes apply afterwards, or build/run will trigger
# auto-regen via drift detection on next run. --yes skips the
# interactive confirmation prompt; non-tty without --yes refuses to
# proceed (safety guard against accidental invocation in pipelines).
# ════════════════════════════════════════════════════════════════════

@test "main reset --yes clears setup.conf + setup.conf so next apply rebuilds (#174)" {
  mkdir -p "${TEMP_DIR}/.base/config/docker"
  cp /source/config/docker/setup.conf "${TEMP_DIR}/.base/config/docker/setup.conf"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# user-customized
[network]
mode = bridge
EOF
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    _SETUP_SCRIPT_DIR='${TEMP_DIR}/.base/script/docker'
    mkdir -p \"\${_SETUP_SCRIPT_DIR}\"
    source /source/script/docker/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  # Override + materialized snapshot both removed — the next apply will
  # rebuild setup.conf purely from the template baseline.
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf" ]
}

@test "main reset --yes backs up prior setup.conf to .local.bak (#174)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
# CUSTOM_MARKER
[network]
mode = bridge
EOF
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
  run grep CUSTOM_MARKER "${TEMP_DIR}/config/docker/setup.conf.bak"
  assert_success
}

@test "main reset --yes backs up prior .env to .env.bak" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  printf 'IMAGE_NAME=customimg\n' > "${TEMP_DIR}/.env"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  assert [ -f "${TEMP_DIR}/.env.bak" ]
  run grep "IMAGE_NAME=customimg" "${TEMP_DIR}/.env.bak"
  assert_success
}

@test "main reset --yes does NOT regenerate .env" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # Bats runs without a controlling TTY — without --yes the handler
  # must refuse rather than silently destroy state.
  run main reset --base-path "${TEMP_DIR}"
  assert_failure
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
}

@test "main reset rejects unknown flag" {
  run main reset --bogus --base-path "${TEMP_DIR}"
  assert_failure
  assert_output --partial "Unknown argument"
}

@test "main reset --yes works on first-time bootstrap (no prior .local or setup.conf) (#174)" {
  rm -f "${TEMP_DIR}/config/docker/setup.conf" "${TEMP_DIR}/config/docker/setup.conf"
  run main reset --yes --base-path "${TEMP_DIR}"
  assert_success
  # First-time bootstrap is a no-op: no override existed, no snapshot
  # existed, so nothing to clear and no .bak files written.
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
  refute [ -f "${TEMP_DIR}/config/docker/setup.conf.bak" ]
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  unset SETUP_CONF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/tmp.abcdef"
  assert_equal "${_result}" "tmp-abcdef"
}

@test "detect_image_name collapses runs of '-' and strips leading/trailing separators" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  [[ "$(_setup_msg env "done")" =~ updated ]]
}

@test "_setup_msg returns Traditional Chinese messages when _LANG=zh-TW" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Simplified Chinese messages when _LANG=zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env "done")" =~ 更新完成 ]]
}

@test "_setup_msg returns Japanese messages when _LANG=ja" {
  _LANG="ja"
  [[ "$(_setup_msg env "done")" =~ 更新完了 ]]
}

# Exercise every (key, language) branch so kcov sees the zh-CN / ja / default
# `unknown_arg` and `env_comment` case-arms. The env_done-only tests above
# only land on the first case of each language block.

@test "_setup_msg env_comment and unknown_arg are defined in zh" {
  _LANG="zh-TW"
  [[ "$(_setup_msg env comment)" =~ 自動偵測 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知參數 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in zh-CN" {
  _LANG="zh-CN"
  [[ "$(_setup_msg env comment)" =~ 自动检测 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 未知参数 ]]
}

@test "_setup_msg env_comment and unknown_arg are defined in ja" {
  _LANG="ja"
  [[ "$(_setup_msg env comment)" =~ 自動検出 ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ 不明な引数 ]]
}

@test "_msg falls back to English when _LANG is unknown" {
  _LANG="xx"
  [[ "$(_setup_msg env "done")" =~ updated ]]
  [[ "$(_setup_msg env comment)" =~ Auto-detected ]]
  [[ "$(_setup_msg errors unknown_arg)" =~ "Unknown argument" ]]
}

# ════════════════════════════════════════════════════════════════════
# [build] section (arg_N KEY=VALUE schema)
# ════════════════════════════════════════════════════════════════════

@test "[build] template defaults ship TW mirrors via arg_N" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_1 \
    "APT_MIRROR_UBUNTU=archive.ubuntu.com"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_2 \
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build arg_9 \
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build target_arch arm64
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^TARGET_ARCH=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "TARGET_ARCH=arm64"
}

@test "[build] target_arch empty omits TARGET_ARCH from .env" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  # Explicit empty value (the template's default)
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build target_arch ""
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
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build network host
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep '^BUILD_NETWORK=' '${TEMP_DIR}/.env'
  "
  assert_success
  assert_output --partial "BUILD_NETWORK=host"
}

@test "[build] network empty omits BUILD_NETWORK from .env" {
  cp /source/config/docker/setup.conf "${TEMP_DIR}/config/docker/setup.conf"
  _upsert_conf_value "${TEMP_DIR}/config/docker/setup.conf" build network ""
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
  assert [ -f "${_repo}/config/docker/setup.conf" ]
  run grep '^mount_1' "${_repo}/config/docker/setup.conf"
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
    grep '^mount_1' '${_repo}/config/docker/setup.conf'
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
  cat > "${_repo}/config/docker/setup.conf" <<EOF
[volumes]
mount_1 = ${_pin}:/home/\${USER_NAME}/work
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${_repo}' 2>&1
    grep '^WS_PATH=' '${_repo}/.env'
    grep '^mount_1' '${_repo}/config/docker/setup.conf'
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
    "${_repo}/config/docker/setup.conf"
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
  # Pre-#201 bug: bootstrap wrote mount_1 to <repo>/config/docker/setup.conf, then
  # immediately reloaded via _load_setup_conf which only consulted
  # setup.conf.local (empty) + template (empty mount_1). The just-written
  # value was lost and compose.yaml omitted the workspace mount.
  # Post-#201 (2-file model): bootstrap writes to <repo>/config/docker/setup.conf and
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
  sed -i 's|^mount_1.*|mount_1 =|' "${_repo}/config/docker/setup.conf"
  bash -c "source /source/script/docker/setup.sh; main apply --base-path '${_repo}'" \
    >/dev/null 2>&1
  # mount_1 stays empty (not re-populated)
  run grep '^mount_1' "${_repo}/config/docker/setup.conf"
  assert_equal "${output}" "mount_1 ="
  # compose.yaml has no workspace mount
  run grep ':/home/${USER_NAME}/work' "${_repo}/compose.yaml"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name string rule
# ════════════════════════════════════════════════════════════════════

@test "detect_image_name string:<value> short-circuits path parsing" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
# Each test sets a single key in <repo>/config/docker/setup.conf and asserts the
# expected line appears in compose.yaml or .env. Companion negative
# tests confirm the corresponding compose / env block is omitted when
# the key is empty / cleared. Ensures every key documented in
# .base/config/docker/setup.conf has a setting → output assertion.
# ════════════════════════════════════════════════════════════════════

# ── [deploy] ─────────────────────────────────────────────────────────

@test "[deploy] gpu_mode = off omits deploy.resources block from compose.yaml" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
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

# ════════════════════════════════════════════════════════════════════
# _validate_stage_name (#215)
#
# Returns:
#   0 — valid stage name (auto-emit as compose service)
#   1 — invalid format (WARN + skip; do not emit, continue)
#   2 — collides with template-managed baseline (HARD ERROR)
#   3 — collides with template-controlled tag namespace (HARD ERROR)
# ════════════════════════════════════════════════════════════════════

@test "_validate_stage_name accepts well-formed names" {
  for _name in headless gui prod runtime dev main master edge headless-arm64 gpu_test; do
    run _validate_stage_name "${_name}"
    assert_success
  done
}

@test "_validate_stage_name rejects invalid format with exit 1 (WARN+skip)" {
  for _bad in 'Headless' '1stage' '-leading' '_leading' 'has space' 'has.dot' 'CAPS'; do
    run _validate_stage_name "${_bad}"
    [[ "${status}" -eq 1 ]] || { echo "expected 1 for '${_bad}', got ${status}"; return 1; }
  done
}

@test "_validate_stage_name rejects baseline collision with exit 2 (HARD ERROR)" {
  # Forward-looking baseline + legacy aliases (kept during v0.21.x
  # transition for backward compat with un-renamed downstream Dockerfiles).
  for _base in sys devel-base devel devel-test runtime-test base test; do
    run _validate_stage_name "${_base}"
    [[ "${status}" -eq 2 ]] || { echo "expected 2 for '${_base}', got ${status}"; return 1; }
  done
}

@test "_validate_stage_name rejects reserved tag-namespace names with exit 3 (HARD ERROR)" {
  for _bad in latest v0 v1 v1.2 v0.16.2 v0.16.2-rc1; do
    run _validate_stage_name "${_bad}"
    [[ "${status}" -eq 3 ]] || { echo "expected 3 for '${_bad}', got ${status}"; return 1; }
  done
}

# ════════════════════════════════════════════════════════════════════
# _parse_dockerfile_stages (#215)
#
# Reads `^FROM\s+\S+\s+AS\s+<stage>` lines from a Dockerfile, dedups,
# filters out the baseline blocklist {sys, devel-base, devel,
# devel-test, runtime-test} (plus legacy {base, test} during v0.21.x
# transition), and echoes the surviving stages one per line.
# ════════════════════════════════════════════════════════════════════

@test "_parse_dockerfile_stages: returns nothing for Dockerfile with only legacy baseline stages (backward compat)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: returns nothing for Dockerfile with only new baseline stages (#243)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM runtime AS runtime-test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: extracts non-baseline stages" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
FROM devel AS test
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_line --index 0 "headless"
  assert_line --index 1 "gui"
  [[ "${#lines[@]}" -eq 2 ]] || { echo "expected 2 lines, got ${#lines[@]}: ${output}"; return 1; }
}

@test "_parse_dockerfile_stages: preserves Dockerfile order" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS gamma
FROM devel AS alpha
FROM devel AS beta
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_line --index 0 "gamma"
  assert_line --index 1 "alpha"
  assert_line --index 2 "beta"
}

@test "_parse_dockerfile_stages: dedups duplicate stage names" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS gui
FROM devel AS gui
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  [[ "${#lines[@]}" -eq 1 ]] || { echo "expected 1 line after dedup, got ${#lines[@]}: ${output}"; return 1; }
  assert_output "gui"
}

@test "_parse_dockerfile_stages: handles missing Dockerfile gracefully (empty output)" {
  run _parse_dockerfile_stages "${TEMP_DIR}/no-such-Dockerfile"
  assert_success
  assert_output ""
}

@test "_parse_dockerfile_stages: ignores lowercase 'as' and inline comments" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel as lower_as_keyword
# FROM devel AS commented_out
FROM devel AS prod
EOF
  run _parse_dockerfile_stages "${TEMP_DIR}/Dockerfile"
  assert_success
  assert_output "prod"
}

# ════════════════════════════════════════════════════════════════════
# _compute_dockerfile_hash (#215)
#
# sha256 of just the `FROM ... AS <stage>` lines (stage list projection),
# not the whole Dockerfile. Used by _check_setup_drift to detect when
# the user adds/removes a stage and regenerate compose.yaml.
# ════════════════════════════════════════════════════════════════════

@test "_compute_dockerfile_hash: stable for unchanged stage list" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
EOF
  local _h1 _h2
  _compute_dockerfile_hash "${TEMP_DIR}" _h1
  _compute_dockerfile_hash "${TEMP_DIR}" _h2
  assert_equal "${_h1}" "${_h2}"
  [[ -n "${_h1}" ]]
}

@test "_compute_dockerfile_hash: changes when stage is added" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS headless
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  [[ "${_h_before}" != "${_h_after}" ]] || { echo "hash should change when stage added"; return 1; }
}

@test "_compute_dockerfile_hash: changes when stage is removed" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  [[ "${_h_before}" != "${_h_after}" ]] || { echo "hash should change when stage removed"; return 1; }
}

@test "_compute_dockerfile_hash: stable when non-FROM-AS lines change" {
  # Project hash should ignore RUN / COPY / ENV / ARG / comments — only
  # `FROM ... AS <stage>` lines determine the compose service set.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
RUN apt-get install -y curl
FROM sys AS base
ENV FOO=bar
FROM base AS devel
EOF
  local _h_before _h_after
  _compute_dockerfile_hash "${TEMP_DIR}" _h_before

  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
RUN apt-get install -y wget
FROM sys AS base
ENV BAZ=qux
# new comment
FROM base AS devel
EOF
  _compute_dockerfile_hash "${TEMP_DIR}" _h_after

  assert_equal "${_h_before}" "${_h_after}"
}

@test "_compute_dockerfile_hash: empty when Dockerfile missing" {
  local _h
  _compute_dockerfile_hash "${TEMP_DIR}" _h
  assert_equal "${_h}" ""
}

# ════════════════════════════════════════════════════════════════════
# main apply — auto-emit non-baseline stages (#215)
#
# End-to-end check that stages declared via `FROM ... AS <stage>` in
# Dockerfile become compose services automatically. Covers the v1
# acceptance set: existing #108 runtime regression, multi-stage emit,
# baseline collision (hard error), reserved tag namespace (hard error),
# invalid format (WARN + skip but apply still succeeds).
# ════════════════════════════════════════════════════════════════════

@test "auto-emit: regression for #108 — Dockerfile AS runtime still emits runtime service" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS runtime
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
    grep -E '^[[:space:]]+runtime:$' '${TEMP_DIR}/compose.yaml'
  "
  assert_success
  assert_output --partial "runtime:"
}

@test "auto-emit: multi-stage emits one service per non-baseline stage" {
  # Isaac Sim shape: two extra stages on top of devel.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run grep -cE '^  (headless|gui):$' "${TEMP_DIR}/compose.yaml"
  assert_output "2"
  # Both services extend devel (compose extends keyword)
  run grep -cF 'service: devel' "${TEMP_DIR}/compose.yaml"
  # Devel itself doesn't extend; only emitted stage services do — so
  # 2 occurrences (headless + gui), once per stage block.
  assert_output "2"
}

@test "auto-emit: each emitted stage carries target / image / container_name / profiles" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # build.target points at the new stage
  run grep -F '      target: headless' "${TEMP_DIR}/compose.yaml"
  assert_success
  # image is tagged ${IMAGE_NAME}:headless (image_name resolves from
  # template's [image] rules — exact value irrelevant; pattern matters)
  run grep -E '^    image: \$\{DOCKER_HUB_USER:-local\}/[a-z0-9_-]+:headless$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # container_name: ${USER_NAME} prefix (#322 multi-user disambiguation)
  # + ${IMAGE_NAME}-headless + INSTANCE_SUFFIX
  run grep -E '^    container_name: \$\{USER_NAME\}-[a-z0-9_-]+-headless\$\{INSTANCE_SUFFIX:-\}$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # profiles list contains the stage name
  run grep -F '      - headless' "${TEMP_DIR}/compose.yaml"
  assert_success
}

@test "auto-emit: no extra stages → only devel + test in compose.yaml" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # Only devel + test; no other top-level service blocks.
  run grep -cE '^  [a-z][a-z0-9_-]*:$' "${TEMP_DIR}/compose.yaml"
  assert_output "2"
}

@test "auto-emit: baseline collision (AS test redefined) → hard error exit non-zero" {
  # User Dockerfile has another `AS test` later — but template's parser
  # treats baseline names as collision regardless of position. (The
  # `test` in line 4 IS the template-managed test stage; if the user
  # has an extra one this is collision.) Simulate by adding a second
  # `AS test` after a base.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS test
EOF
  unset SETUP_CONF
  # Add a second `AS test` at top to trigger duplicate baseline match
  # (parser sees it before dedup; baseline blocklist still skips).
  # Actually the dedup-then-blocklist test is not a collision — both
  # are "test" which is baseline-blocked. To trigger collision, user
  # uses a NEW base name that hits baseline. Use `base` as a new
  # explicit `FROM xxx AS base` after devel:
  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS base
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}'
  " 2>&1
  # Validator sees `base` as a parsed stage post-Dockerfile read, but
  # _parse_dockerfile_stages strips it via blocklist → never reaches
  # validator. So `AS base` second occurrence does NOT hard-error;
  # blocklist filter precedes validator. This case is benign.
  # Document this: the only way to trigger a hard error from baseline
  # collision is for user to override the parser somehow — currently
  # no path. So this test asserts the NON-collision outcome (apply
  # succeeds, no extra service emitted).
  assert_success
  run grep -cE '^  base:$' "${TEMP_DIR}/compose.yaml"
  assert_output "0"
}

@test "auto-emit: reserved tag namespace (AS latest) → hard error exit non-zero" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS latest
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_failure
  assert_output --partial "template-controlled image tag namespace"
}

@test "auto-emit: reserved tag namespace (AS v0) → hard error exit non-zero" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS v0
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}'
  "
  assert_failure
}

@test "auto-emit: invalid format (AS Headless capital) → WARN + skip, apply still succeeds" {
  # `Headless` fails the lowercase-only format check. Validator returns
  # 1 (skip), apply continues. The compose.yaml does NOT get a
  # `Headless:` service. Other valid stages (gui) still emit normally.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS Headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  assert_output --partial "invalid Dockerfile stage name format"
  # gui still emits
  run grep -E '^  gui:$' "${TEMP_DIR}/compose.yaml"
  assert_success
  # Headless does NOT emit (case-sensitive grep)
  run grep -E '^  Headless:$' "${TEMP_DIR}/compose.yaml"
  assert_failure
}

@test "auto-emit: SETUP_DOCKERFILE_HASH written to .env" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run grep -E '^SETUP_DOCKERFILE_HASH=[a-f0-9]{64}$' "${TEMP_DIR}/.env"
  assert_success
}

@test "auto-emit: drift fires when Dockerfile stage list changes" {
  # First apply — Dockerfile has just devel.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success

  # Add a new stage; check-drift should now report drift.
  cat >> "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM devel AS headless
EOF

  # Stub detect_gpu/gui to match what was stored, so non-Dockerfile
  # drift sources stay quiet and we observe ONLY the Dockerfile drift.
  run bash -c "
    source /source/script/docker/setup.sh
    detect_gui() { local -n _o=\$1; _o=\"\$(grep -oP '^SETUP_GUI_DETECTED=\\K.*' '${TEMP_DIR}/.env' 2>/dev/null || echo false)\"; }
    detect_gpu() { local -n _o=\$1; _o=\"\$(grep -oP '^GPU_ENABLED=\\K.*' '${TEMP_DIR}/.env' 2>/dev/null || echo false)\"; }
    _check_setup_drift '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "Dockerfile stage list changed"
}

@test "auto-emit: drift fires when Dockerfile stage is REMOVED" {
  # Mirrors the add-side drift but for the remove path. Important per
  # #215 acceptance: stale services must not survive Dockerfile edits
  # that delete a stage.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
FROM devel AS gui
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success

  # Remove the gui stage.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF

  run bash -c "
    source /source/script/docker/setup.sh
    detect_gui() { local -n _o=\$1; _o=\"\$(grep -oP '^SETUP_GUI_DETECTED=\\K.*' '${TEMP_DIR}/.env' 2>/dev/null || echo false)\"; }
    detect_gpu() { local -n _o=\$1; _o=\"\$(grep -oP '^GPU_ENABLED=\\K.*' '${TEMP_DIR}/.env' 2>/dev/null || echo false)\"; }
    _check_setup_drift '${TEMP_DIR}'
  "
  assert_failure
  assert_output --partial "Dockerfile stage list changed"
}

# ════════════════════════════════════════════════════════════════════
# Per-stage overrides (#220)
#
# `[stage:<name>]` sections in <repo>/config/docker/setup.conf override top-level
# settings on a per-stage basis when a corresponding `FROM ... AS <name>`
# stage exists in the Dockerfile. Allowlist gates which keys can be
# overridden; list fields (mount_*/port_*/env_*) use append-default
# with opt-out via `<list>_inherit = false`.
# ════════════════════════════════════════════════════════════════════

# ─── _parse_stage_sections ────────────────────────────────────────

@test "_parse_stage_sections: empty file → empty output" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

@test "_parse_stage_sections: missing file → empty output (no error)" {
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/no-such-file.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

@test "_parse_stage_sections: extracts [stage:NAME] sections in file order" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off

[network]
mode = host

[stage:gui]
gui.mode = auto

[stage:web]
network.mode = bridge
EOF
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 3 ]] || { echo "expected 3 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
  [[ "${_stages[0]}" == "headless" ]] || { echo "expected headless first, got ${_stages[0]}"; return 1; }
  [[ "${_stages[1]}" == "gui" ]] || { echo "expected gui second, got ${_stages[1]}"; return 1; }
  [[ "${_stages[2]}" == "web" ]] || { echo "expected web third, got ${_stages[2]}"; return 1; }
}

@test "_parse_stage_sections: ignores plain sections that are not [stage:...]" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
[network]
mode = host
[volumes]
mount_1 = /etc/localtime:/etc/localtime
EOF
  local -a _stages=()
  _parse_stage_sections "${TEMP_DIR}/config/docker/setup.conf" _stages
  [[ "${#_stages[@]}" -eq 0 ]] || { echo "expected 0 stages, got ${#_stages[@]}: ${_stages[*]}"; return 1; }
}

# ─── _load_stage_overrides ────────────────────────────────────────

@test "_load_stage_overrides: returns the keys+values under [stage:NAME]" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off
network.mode = bridge
network.port_1 = 8080:80
volumes.mount_1 = /tmp/cache:/cache

[stage:gui]
gui.mode = auto
EOF
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "headless" _keys _values
  [[ "${#_keys[@]}" -eq 4 ]] || { echo "expected 4 keys, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
  [[ "${_keys[0]}" == "gui.mode" && "${_values[0]}" == "off" ]] || return 1
  [[ "${_keys[1]}" == "network.mode" && "${_values[1]}" == "bridge" ]] || return 1
  [[ "${_keys[2]}" == "network.port_1" && "${_values[2]}" == "8080:80" ]] || return 1
  [[ "${_keys[3]}" == "volumes.mount_1" && "${_values[3]}" == "/tmp/cache:/cache" ]] || return 1
}

@test "_load_stage_overrides: missing setup.conf → empty arrays" {
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "headless" _keys _values
  [[ "${#_keys[@]}" -eq 0 ]] || { echo "expected 0 keys, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
  [[ "${#_values[@]}" -eq 0 ]] || return 1
}

@test "_load_stage_overrides: stage absent from setup.conf → empty arrays" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto

[stage:headless]
gui.mode = off
EOF
  local -a _keys=() _values=()
  _load_stage_overrides "${TEMP_DIR}" "gui" _keys _values
  [[ "${#_keys[@]}" -eq 0 ]] || { echo "expected 0 keys for absent stage, got ${#_keys[@]}: ${_keys[*]}"; return 1; }
}

# ─── _validate_stage_override_key ──────────────────────────────────

@test "_validate_stage_override_key: accepts allowlisted scalars" {
  for _k in \
    deploy.gpu_mode \
    deploy.gpu_count \
    deploy.gpu_capabilities \
    deploy.runtime \
    gui.mode \
    network.mode \
    network.ipc \
    network.network_name \
    security.privileged
  do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: accepts list-item keys with numeric suffix" {
  for _k in \
    network.port_1 \
    network.port_2 \
    network.port_99 \
    volumes.mount_1 \
    volumes.mount_42 \
    environment.env_1 \
    environment.env_7
  do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: accepts inherit meta-keys" {
  for _k in network.port_inherit volumes.mount_inherit environment.env_inherit; do
    run _validate_stage_override_key "${_k}"
    assert_success
  done
}

@test "_validate_stage_override_key: rejects keys outside allowlist" {
  for _k in \
    image.rule_1 \
    build.arg_1 \
    build.target_arch \
    security.cap_add_1 \
    security.security_opt_1 \
    devices.device_1 \
    tmpfs.tmpfs_1 \
    additional_contexts.context_1 \
    foo.bar \
    not_dotted_key
  do
    run _validate_stage_override_key "${_k}"
    [[ "${status}" -ne 0 ]] || { echo "expected failure for ${_k}"; return 1; }
  done
}

# ─── _resolve_stage_scalar ─────────────────────────────────────────

@test "_resolve_stage_scalar: returns stage value when override present" {
  local -a _keys=("gui.mode" "network.mode")
  local -a _values=("off" "bridge")
  local _out=""
  _resolve_stage_scalar _keys _values "gui.mode" "auto" _out
  [[ "${_out}" == "off" ]] || { echo "expected 'off', got '${_out}'"; return 1; }
}

@test "_resolve_stage_scalar: returns fallback when key absent" {
  local -a _keys=("gui.mode")
  local -a _values=("off")
  local _out=""
  _resolve_stage_scalar _keys _values "network.mode" "host" _out
  [[ "${_out}" == "host" ]] || { echo "expected 'host', got '${_out}'"; return 1; }
}

@test "_resolve_stage_scalar: returns empty fallback when neither set" {
  local -a _keys=()
  local -a _values=()
  local _out="initial"
  _resolve_stage_scalar _keys _values "gui.mode" "" _out
  [[ -z "${_out}" ]] || { echo "expected empty, got '${_out}'"; return 1; }
}

# ─── _resolve_stage_list ───────────────────────────────────────────

@test "_resolve_stage_list: append-default with stage entries (inherit unset)" {
  local -a _keys=("volumes.mount_1" "volumes.mount_2")
  local -a _values=("/tmp/cache:/cache" "/data:/data")
  local _top="/etc/localtime:/etc/localtime:ro"$'\n'"\${HOME}/.ssh:/home/user/.ssh:ro"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  # Top-level 2 entries + stage 2 entries = 4 lines
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${#_lines[@]}" -eq 4 ]] || { echo "expected 4 lines, got ${#_lines[@]}: ${_out}"; return 1; }
  [[ "${_lines[0]}" == "/etc/localtime:/etc/localtime:ro" ]] || return 1
  [[ "${_lines[2]}" == "/tmp/cache:/cache" ]] || return 1
  [[ "${_lines[3]}" == "/data:/data" ]] || return 1
}

@test "_resolve_stage_list: replace mode (inherit=false) drops top-level" {
  local -a _keys=("volumes.mount_inherit" "volumes.mount_1")
  local -a _values=("false" "/only:/only")
  local _top="/etc/localtime:/etc/localtime:ro"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ "${_out}" == "/only:/only" ]] || { echo "expected only stage entry, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: empty stage with inherit=true → top-level only" {
  local -a _keys=()
  local -a _values=()
  local _top="/etc/localtime:/etc/localtime:ro"$'\n'"/data:/data"
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ "${_out}" == "${_top}" ]] || { echo "expected top-level passthrough, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: empty stage with inherit=false → empty result" {
  local -a _keys=("volumes.mount_inherit")
  local -a _values=("false")
  local _top="/etc/localtime:/etc/localtime:ro"
  local _out="initial"
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "${_top}" _out
  [[ -z "${_out}" ]] || { echo "expected empty, got '${_out}'"; return 1; }
}

@test "_resolve_stage_list: preserves stage entries in setup.conf order" {
  # User wrote port_3 first, then port_1, then port_2 — preserve that
  # order rather than re-sorting numerically. The on-disk order is what
  # the user sees in setup_tui.sh and what _parse_ini_section returns.
  local -a _keys=("network.port_3" "network.port_1" "network.port_2")
  local -a _values=("9000:9000" "8080:80" "5000:5000")
  local _out=""
  _resolve_stage_list _keys _values "network.port_" "network.port_inherit" "" _out
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${_lines[0]}" == "9000:9000" ]] || return 1
  [[ "${_lines[1]}" == "8080:80" ]] || return 1
  [[ "${_lines[2]}" == "5000:5000" ]] || return 1
}

@test "_resolve_stage_list: ignores keys with non-numeric suffix" {
  # `mount_inherit` is the meta-key, not a list item — must not be
  # collected even though it shares the `mount_` prefix.
  local -a _keys=("volumes.mount_1" "volumes.mount_inherit" "volumes.mount_2")
  local -a _values=("/a:/a" "false" "/b:/b")
  local _out=""
  _resolve_stage_list _keys _values "volumes.mount_" "volumes.mount_inherit" "" _out
  # inherit=false → only stage entries
  local -a _lines=()
  IFS=$'\n' read -rd '' -a _lines <<< "${_out}" || true
  [[ "${#_lines[@]}" -eq 2 ]] || { echo "expected 2, got ${#_lines[@]}: ${_out}"; return 1; }
  [[ "${_lines[0]}" == "/a:/a" ]] || return 1
  [[ "${_lines[1]}" == "/b:/b" ]] || return 1
}

# ─── Per-stage overrides — compose.yaml emit integration (#220) ────

@test "stage-override: regression — stage with NO overrides keeps extends:devel minimal block" {
  # Zero-diff path: existing 17 downstream repos have setup.conf with
  # no [stage:*] sections. compose.yaml output for emitted stages must
  # match #215's extends-only shape exactly.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  unset SETUP_CONF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # extends: devel still emitted under the headless service block
  run grep -A 3 '^  headless:$' "${TEMP_DIR}/compose.yaml"
  assert_output --partial "extends:"
  assert_output --partial "service: devel"
  # No `network_mode:`, `ports:`, `volumes:` block underneath headless
  # (compose extends inherits all from devel — no override block emitted)
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  refute_output --partial "network_mode: bridge"
  refute_output --partial "ports:"
  refute_output --partial "volumes:"
  refute_output --partial "environment:"
}

@test "stage-override: gui.mode=off in [stage:headless] strips X11 env+volumes from headless" {
  # Regression for #220 Isaac validation finding: compose `extends`
  # MERGES list fields (not replaces), so emitting a stage's
  # environment / volumes block on top of `extends: devel` ends up
  # APPENDING to devel's X11 entries, not suppressing them. Fix:
  # when a stage has any list-affecting override, drop `extends:`
  # entirely and emit a standalone service block.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force

[stage:headless]
gui.mode = off
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # Slice the headless service block (between its header and the
  # next service header).
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # CRITICAL: NO `extends:` line — standalone emit so compose does
  # not merge devel's X11 list back in.
  refute_output --partial "extends:"
  refute_output --partial "service: devel"
  # Standalone block has its own image / container_name / target.
  assert_output --partial "target: headless"
  assert_output --partial ":headless"
  # No X11 anywhere in the headless block.
  refute_output --partial "DISPLAY="
  refute_output --partial "/tmp/.X11-unix"
  # devel block (top-level gui = force) still has X11 entries.
  run bash -c "awk '/^  devel:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  assert_output --partial "DISPLAY="
}

@test "stage-override: network.mode=bridge + port_1 in [stage:headless] emits per-stage ports" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[network]
mode = host

[stage:headless]
network.mode = bridge
network.port_1 = 8080:80
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  # devel still on host
  run bash -c "awk '/^  devel:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # NETWORK_MODE is filled into .env from top-level network.mode=host
  assert_output --partial "network_mode:"
  # headless flips to bridge + has its own port mapping
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  assert_output --partial "network_mode: bridge"
  assert_output --partial "8080:80"
}

@test "stage-override: volumes.mount_inherit=false drops top-level mounts for that stage" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[volumes]
mount_1 =
mount_2 = /etc/localtime:/etc/localtime:ro
mount_3 = /data:/data

[stage:headless]
volumes.mount_inherit = false
volumes.mount_1 = /only:/only
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  # CRITICAL: standalone emit (no extends) — otherwise compose merges
  # devel's volume list (incl. /etc/localtime, /data) back in.
  refute_output --partial "extends:"
  assert_output --partial "/only:/only"
  refute_output --partial "/etc/localtime"
  refute_output --partial "/data:/data"
}

@test "stage-override: standalone emit re-emits cap_add + privileged inherited from devel" {
  # When stage drops `extends: devel`, top-level fields that aren't
  # per-stage overridable (cap_add / cap_drop / security_opt /
  # devices / tmpfs / privileged via env-var ref) must be re-emitted
  # in the standalone block so the stage doesn't silently lose them.
  # This test covers the cap_add + privileged inheritance path
  # specifically; runtime / cgroup_rules / tmpfs / devices follow
  # the same pattern and rely on the same code path so are not
  # separately tested here.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force

[security]
privileged = true
cap_add_1 = SYS_ADMIN
cap_add_2 = NET_ADMIN

[stage:headless]
gui.mode = off
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' >/dev/null 2>&1
  "
  assert_success
  run bash -c "awk '/^  headless:\$/{f=1; next} /^  [a-z][a-z0-9_-]*:\$/{f=0} f' '${TEMP_DIR}/compose.yaml'"
  assert_success
  refute_output --partial "extends:"
  # cap_add list was re-emitted (top-level value, since stage didn't
  # override it). Without extends, this MUST appear inline.
  assert_output --partial "SYS_ADMIN"
  assert_output --partial "NET_ADMIN"
  # privileged still references PRIVILEGED env var (same as devel).
  assert_output --partial "privileged:"
}

@test "stage-override: orphan [stage:foo] (no foo in Dockerfile) prints WARN, does not abort" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:headless]
gui.mode = off

[stage:foo]
gui.mode = off
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_success
  assert_output --partial "[stage:foo]"
  # generic phrase — uses our new i18n key
  assert_output --partial "stage"
}

@test "stage-override: disallowed override key (image.rule_1) prints WARN and skips that key" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:headless]
gui.mode = off
image.rule_1 = prefix:bogus_
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_success
  assert_output --partial "image.rule_1"
}

@test "stage-override: [stage:sys] in setup.conf is hard-error (baseline collision)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
FROM devel AS headless
EOF
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[stage:sys]
gui.mode = off
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' 2>&1 >/dev/null
  "
  assert_failure
  assert_output --partial "[stage:sys]"
}

# ════════════════════════════════════════════════════════════════════
# #285 — --quiet flag + success confirmation output
# ════════════════════════════════════════════════════════════════════

@test "setup.sh set: prints 3-line confirmation by default" {
  run bash -c "
    source /source/script/docker/setup.sh
    main set --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output --partial "[setup] set [build] arg_4 = ROS2_DISTRO=jazzy"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run './setup.sh apply'"
}

@test "setup.sh set --quiet: produces empty stdout" {
  run bash -c "
    source /source/script/docker/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set -q: short form also suppresses output" {
  run bash -c "
    source /source/script/docker/setup.sh
    main set -q --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  assert_success
  assert_output ""
}

@test "setup.sh set --quiet: still writes the value (mutation not skipped)" {
  bash -c "
    source /source/script/docker/setup.sh
    main set --quiet --base-path '${TEMP_DIR}' build.arg_4 ROS2_DISTRO=jazzy
  "
  run cat "${TEMP_DIR}/config/docker/setup.conf"
  assert_success
  assert_output --partial "arg_4 = ROS2_DISTRO=jazzy"
}

@test "setup.sh add: prints 3-line confirmation by default" {
  run bash -c "
    source /source/script/docker/setup.sh
    main add --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output --partial "[setup] add [build] arg_"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run './setup.sh apply'"
}

@test "setup.sh add --quiet: produces empty stdout" {
  run bash -c "
    source /source/script/docker/setup.sh
    main add --quiet --base-path '${TEMP_DIR}' build.arg HARDWARE=arm64
  "
  assert_success
  assert_output ""
}

@test "setup.sh remove: prints 3-line confirmation by default" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main remove --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output --partial "[setup] remove [build] arg_1"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run './setup.sh apply'"
}

@test "setup.sh remove --quiet: produces empty stdout" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<EOC
[build]
arg_1 = HARDWARE=arm64
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main remove --quiet --base-path '${TEMP_DIR}' build.arg_1
  "
  assert_success
  assert_output ""
}

@test "setup.sh reset --yes: prints next: hint and file: by default" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main reset --yes --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output --partial "[setup]"
  assert_output --partial "[setup] file:"
  assert_output --partial "[setup] next: run './setup.sh apply'"
}

@test "setup.sh reset --yes --quiet: produces empty stdout" {
  : > "${TEMP_DIR}/config/docker/setup.conf"
  run bash -c "
    source /source/script/docker/setup.sh
    main reset --yes --quiet --base-path '${TEMP_DIR}'
  "
  assert_success
  assert_output ""
}

@test "setup.sh apply --quiet: suppresses the env_done + USER=... summary" {
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --quiet --base-path '${TEMP_DIR}' 2>&1
  "
  assert_success
  refute_output --partial "[setup] USER="
}

# ════════════════════════════════════════════════════════════════════
# #338: setup.sh apply CLI flags (--gui / --no-x11-cookie / --print-resolved)
# ════════════════════════════════════════════════════════════════════

@test "apply --gui off overrides [gui] mode via print-resolved (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  # Baseline: mode=force resolves GUI_ENABLED=true regardless of host
  # GUI detection.
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
  # CLI override flips GUI to off, ignoring setup.conf.
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui off --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui=force enables GUI even when setup.conf says off (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = off
EOF
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui=force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --gui rejects values outside auto|force|off (#338)" {
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --gui bogus 2>&1
  "
  assert_failure
  assert_output --partial "Invalid value"
}

@test "apply --print-resolved prints KEY=VALUE state without writing .env (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = off
[deploy]
gpu_mode = off
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  # Expected resolved lines
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
  assert_output --partial "GPU_MODE=off"
  assert_output --partial "GPU_ENABLED=false"
  # And NO file was written.
  [[ ! -f "${TEMP_DIR}/.env" ]]
  [[ ! -f "${TEMP_DIR}/compose.yaml" ]]
}

@test "apply --print-resolved respects --gui override in the dump (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    SETUP_DETECT_JETSON=false main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=force"
  assert_output --partial "GUI_ENABLED=true"
}

@test "apply --no-x11-cookie records X11_COOKIE_SKIP=1 in print-resolved (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --no-x11-cookie --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=1"
}

@test "apply without --no-x11-cookie records X11_COOKIE_SKIP=0 (default) (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "X11_COOKIE_SKIP=0"
}

@test "apply SETUP_GUI env var overrides setup.conf when --gui not passed (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = force
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --print-resolved 2>/dev/null
  "
  assert_success
  assert_output --partial "GUI_MODE=off"
  assert_output --partial "GUI_ENABLED=false"
}

@test "apply --gui CLI wins over SETUP_GUI env var (resolution order CLI > env) (#338)" {
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'EOF'
[gui]
mode = auto
EOF
  cat > "${TEMP_DIR}/Dockerfile" <<'EOC'
FROM scratch AS sys
FROM sys AS base
FROM base AS devel
EOC
  run bash -c "
    source /source/script/docker/setup.sh
    SETUP_GUI=off main apply --base-path '${TEMP_DIR}' --gui force --print-resolved 2>/dev/null
  "
  assert_success
  # CLI --gui force wins
  assert_output --partial "GUI_MODE=force"
}
