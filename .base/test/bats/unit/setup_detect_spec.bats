#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load "${BATS_TEST_DIRNAME}/setup_spec_helper"

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

@test "detect_gpu: a dpkg-query still writing cannot report an installed toolkit as missing (#905)" {
  # `dpkg-query ... | <reader>` where the reader stops reading: it leaves
  # on the `ii` line, the dpkg-query still writing takes SIGPIPE and exits
  # 141, `pipefail` makes 141 the pipeline's status, and the `if` reads an
  # INSTALLED toolkit as missing. Nothing fails; setup just writes a
  # GPU-less .env on a GPU host, and the container comes up without the
  # device.
  #
  # setup.sh carries `set -euo pipefail` at file scope, but bats' `run`
  # does not, and a sourced function inherits the harness's options -- so
  # the strict shell has to be re-established here. It is a script FILE:
  # under kcov the xtrace PS4 expands ${BASH_SOURCE}, which is EMPTY at
  # the top level of a `bash -c` string, and `set -u` would abort the
  # harness before detect_gpu ran at all.
  local _shim="${TEMP_DIR}/shim"
  shim_late_writer "${_shim}" "dpkg-query" "ii " "un  some-other-package"

  local _runner="${TEMP_DIR}/detect_gpu_strict.sh"
  cat > "${_runner}" << 'EOF'
set -euo pipefail
source /source/dist/script/docker/lib/setup_detect.sh
PATH="${SHIM_DIR}:${PATH}"
_gpu=""
detect_gpu _gpu
printf 'gpu=%s\n' "${_gpu}"
EOF

  run env SHIM_DIR="${_shim}" bash "${_runner}"
  assert_success
  assert_output "gpu=true"
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

# ── [deploy] runtime -> gpu_runtime (W3 permanent alias) ────────────────
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
# _is_ssh_x11 (SSH X11 forwarding detection,)
# ════════════════════════════════════════════════════════════════════
@test "_is_ssh_x11 true when SSH_CONNECTION set + DISPLAY=localhost:N (#321)" {
  SSH_CONNECTION="1.2.3.4 12345 5.6.7.8 22" DISPLAY="localhost:10.0" _is_ssh_x11
}

@test "_is_ssh_x11 true when DISPLAY=localhost:N without fractional part (#321)" {
  SSH_CONNECTION="x y z w" DISPLAY="localhost:0" _is_ssh_x11
}

@test "_is_ssh_x11 false when SSH_CONNECTION unset (#321)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    unset SSH_CONNECTION
    DISPLAY=localhost:10.0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is local socket (:0) (#321)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY=:0 _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY is unset (#321)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='' _is_ssh_x11
  "
  assert_failure
}

@test "_is_ssh_x11 false when DISPLAY points to a remote host (#321)" {
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
    SSH_CONNECTION='x y z w' DISPLAY='other-host:0' _is_ssh_x11
  "
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name (now reads [image] rules from setup.conf)
# ════════════════════════════════════════════════════════════════════
@test "detect_image_name uses template default rules (prefix:docker_ → strip)" {
  local _result
  detect_image_name _result "/home/user/docker_myapp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name uses template default rules (suffix:_ws → strip)" {
  local _result
  detect_image_name _result "/home/user/projects/myapp_ws"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name template default falls through to @basename for generic paths" {
  local _result
  detect_image_name _result "/home/user/plainproject"
  assert_equal "${_result}" "plainproject"
}

@test "detect_image_name honors per-repo setup.conf [image] rules" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:foo_
rule_2 = @basename
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/foo_bar"
  assert_equal "${_result}" "bar"
}

@test "detect_image_name rules apply in order (first match wins)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:docker_
rule_2 = suffix:_ws
rule_3 = @default:unused
EOF
  local _result
  # path has docker_ prefix AND _ws somewhere — prefix wins
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/myapp_ws/src/docker_nav"
  assert_equal "${_result}" "nav"
}

@test "detect_image_name @default:<value> used when no rule matches" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
rule_2 = @default:myfallback
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/plain"
  assert_equal "${_result}" "myfallback"
}

@test "detect_image_name lowercases the result" {
  local _result
  detect_image_name _result "/home/user/docker_MyApp"
  assert_equal "${_result}" "myapp"
}

@test "detect_image_name returns unknown when no rule matches and no @default" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = prefix:nonexistent_
EOF
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
  # No sibling *_ws -> strategy-3 fallback, which now returns base_path
  # itself (base-based repos keep scaffolding at the repo root).
  assert_equal "${_result}" "${_parent}/docker_myapp"
}

@test "detect_ws_path strategy 2: finds _ws component in path" {
  local _ws="${TEMP_DIR}/myapp_ws"
  mkdir -p "${_ws}/src"
  local _result
  detect_ws_path _result "${_ws}/src"
  assert_equal "${_result}" "${_ws}"
}

@test "detect_ws_path strategy 3: falls back to base_path itself" {
  local _plain="${TEMP_DIR}/plain/project"
  mkdir -p "${_plain}"
  local _result
  detect_ws_path _result "${_plain}"
  # base-based repos keep the docker scaffolding at the repo root, so the
  # final fallback resolves to base_path itself, not its parent.
  assert_equal "${_result}" "${_plain}"
}

@test "detect_ws_path fails with ERROR when base_path does not exist" {
  run -1 detect_ws_path _r "${TEMP_DIR}/nope"
  assert_output --partial "base_path does not exist"
}

# ════════════════════════════════════════════════════════════════════
# _rule_basename
# ════════════════════════════════════════════════════════════════════
@test "detect_image_name uses @basename rule alone (exercises _rule_basename)" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
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
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/tmp.abcdef"
  assert_equal "${_result}" "tmp-abcdef"
}

@test "detect_image_name collapses runs of '-' and strips leading/trailing separators" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = @basename
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/..weird..name.."
  [[ "${_result}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
  assert_equal "${_result}" "weird-name"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name string rule
# ════════════════════════════════════════════════════════════════════
@test "detect_image_name string:<value> short-circuits path parsing" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = string:my_app
rule_2 = prefix:docker_
rule_3 = @default:should_not_reach
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/home/user/docker_something"
  assert_equal "${_result}" "my_app"
}

@test "detect_image_name string value is still lowercased + sanitized" {
  cat > "${TEMP_DIR}/.setup.conf" <<'EOF'
[image]
rule_1 = string:My.App.Name
EOF
  local _result
  BASE_PATH="${TEMP_DIR}" detect_image_name _result "/tmp/whatever"
  assert_equal "${_result}" "my-app-name"
}

# ════════════════════════════════════════════════════════════════════
# _reconcile_workspace_path — the WS_PATH / mount_1 reconciliation
# state machine extracted from _setup_apply into a testable seam. The 4
# (+empty) branches become direct unit tests instead of being reachable
# only through a full apply. detect_ws_path is deterministic here: with no
# *_ws sibling on the fixture path it falls back to base_path itself.
# ════════════════════════════════════════════════════════════════════
@test "_reconcile_workspace_path: portable form detects WS_PATH locally, mount_1 untouched (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  # shellcheck disable=SC2016  # literal ${WS_PATH} is the portable form stored in setup.conf
  printf '[volumes]\nmount_1 = ${WS_PATH}:/home/${USER_NAME}/work\n' \
    > "${_base}/.setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/.setup.conf" _vk _vv _ws
  # detect_ws_path fallback = base_path itself = ${_base}.
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
  # mount_1 stays the portable form (no rewrite).
  run cat "${_base}/.setup.conf"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
}

@test "_reconcile_workspace_path: absolute existing host path is honored as WS_PATH (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  local _pinned="${TEMP_DIR}/pinned_ws"
  mkdir -p "${_pinned}"
  printf '[volumes]\nmount_1 = %s:/work\n' "${_pinned}" \
    > "${_base}/.setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/.setup.conf" _vk _vv _ws
  assert_equal "${_ws}" "${_pinned}"
  # conf untouched (absolute path honored, not rewritten).
  run cat "${_base}/.setup.conf"
  assert_output --partial "mount_1 = ${_pinned}:/work"
}

@test "_reconcile_workspace_path: stale absolute path warns + rewrites mount_1 to portable (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  printf '[volumes]\nmount_1 = /nonexistent/contributor-a/repo:/work\n' \
    > "${_base}/.setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  run _reconcile_workspace_path "${_base}" "${_base}/.setup.conf" _vk _vv _ws
  assert_success
  assert_output --partial "stale"
  # mount_1 migrated back to the portable form.
  run cat "${_base}/.setup.conf"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
  refute_output --partial "/nonexistent/contributor-a/repo"
}

@test "_reconcile_workspace_path: empty mount_1 detects WS_PATH only, conf untouched (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  printf '[volumes]\nmount_1 =\n' > "${_base}/.setup.conf"
  local -a _vk=() _vv=()
  _load_setup_conf "${_base}" "volumes" _vk _vv
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_base}/.setup.conf" _vk _vv _ws
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
  run cat "${_base}/.setup.conf"
  assert_output --partial "mount_1 ="
}

@test "_reconcile_workspace_path: first-time bootstrap copies template + writes portable mount_1 (#569)" {
  local _base="${TEMP_DIR}/repo"
  mkdir -p "${_base}"
  local _repo_conf="${_base}/.setup.conf"
  # No repo conf yet -> bootstrap from the real template.
  [ ! -f "${_repo_conf}" ]
  local -a _vk=() _vv=()
  local _ws=""
  _reconcile_workspace_path "${_base}" "${_repo_conf}" _vk _vv _ws
  # template was copied into place + mount_1 written portable.
  assert [ -f "${_repo_conf}" ]
  run cat "${_repo_conf}"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'
  assert_equal "${_ws}" "$(cd "${_base}" && pwd -P)"
}

# ════════════════════════════════════════════════════════════════════
# _setup_ssh_x11_cookie (cookie rewrite via xauth,)
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
      source /source/dist/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_success
  assert_output "${TEMP_DIR}/.docker.xauth"
  # File was created AND has content (hotfix: defensive
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
      source /source/dist/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_failure
  assert_output --partial "empty cookie file"
  assert_output --partial "XAUTHORITY left at host value"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when nmerge pipe exits non-zero (#688)" {
  # Distinct from the 0-byte branch: here the nlist|sed|nmerge pipeline
  # itself exits non-zero (the `xauth_rewrite_failed` middle branch). A
  # regression that swallowed this failure would silently emit a bogus
  # XAUTHORITY into .env, so the function must surface it: return 1 and
  # warn "cookie rewrite failed".
  local _bin="${TEMP_DIR}/bin"
  mkdir -p "${_bin}"
  cat > "${_bin}/xauth" <<'EOS'
#!/usr/bin/env bash
# nlist succeeds (emits a line so the pipe has data); nmerge fails.
case "$*" in
  *nmerge*) cat >/dev/null 2>&1 || true; exit 1 ;;
  *nlist*)  echo "localhost:10  MIT-MAGIC-COOKIE-1  deadbeef"; exit 0 ;;
  *)        exit 0 ;;
esac
EOS
  chmod +x "${_bin}/xauth"

  PATH="${_bin}:${PATH}" DISPLAY="localhost:10.0" \
    run bash -c "
      source /source/dist/script/docker/wrapper/setup.sh
      _setup_ssh_x11_cookie '${TEMP_DIR}'
    "
  assert_failure
  assert_output --partial "cookie rewrite failed"
  assert_output --partial "XAUTHORITY left at host value"
}

@test "_setup_ssh_x11_cookie returns 1 with warning when xauth is not installed (#321)" {
  # Shadow the `command` builtin with a function that returns 1 for
  # `command -v xauth` and passes everything else through to the real
  # builtin. Lets the function exercise its xauth-missing branch
  # without touching PATH (which would also break setup.sh's own
  # dirname / sed / etc. lookups during source).
  run bash -c "
    source /source/dist/script/docker/wrapper/setup.sh
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
