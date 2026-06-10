#!/usr/bin/env bats
#
# Tests for generate_compose_yaml() in script/docker/wrapper/setup.sh.
# Verifies conditional emission of GPU deploy block, GUI env/volumes,
# extra volumes list, and baseline structural elements.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  # #493 (A1'-b): the `test` service is emitted from the `devel-test`
  # baseline stage via the per-stage loop, so generate_compose_yaml now
  # needs a Dockerfile that declares it. Ship a minimal baseline so the
  # default (no custom Dockerfile) path still produces devel + test.
  # Tests that need extra stages overwrite this file.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
EOF
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# Baseline (always present)
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml outputs AUTO-GENERATED header" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run head -n 1 "${COMPOSE_OUT}"
  assert_output --partial "AUTO-GENERATED"
}

@test "generate_compose_yaml emits top-level name: with literal compose vars (#472)" {
  # Top-level name: lets non-wrapper tools (lazydocker / docker compose ps /
  # IDE panels) resolve the same project name the wrapper pins via -p. The
  # vars are literal so compose interpolates them from .env at parse time.
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'name: ${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX:-}' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml top-level name: precedes services: (#472)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  local _name_ln _svc_ln
  _name_ln="$(grep -n '^name:' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  _svc_ln="$(grep -n '^services:' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  [ -n "${_name_ln}" ]
  [ -n "${_svc_ln}" ]
  (( _name_ln < _svc_ln ))
}

@test "generate_compose_yaml emits exactly one top-level name: (#472)" {
  # Even with stage variants, name: is a single top-level key, never
  # per-service / per-stage.
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -c '^name:' "${COMPOSE_OUT}"
  assert_output "1"
}

# ── #482 top-level volumes: (Option A / D-Strict) ───────────────────────────

@test "generate_compose_yaml named volume mount emits top-level volumes: stub (#482)" {
  local _extras=('my_state:/srv/state')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^volumes:$' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^  my_state:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- my_state:/srv/state' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml bind mounts never enter top-level volumes: (#482)" {
  # /, ./, ~/, ${ prefixes are all binds -> no top-level volumes block.
  local _extras=('/var/log:/log' './data:/data' '~/.ssh:/home/u/.ssh:ro' '${WS_PATH}:/work')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^volumes:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml bind-only repo is zero-diff (no top-level volumes:) (#482)" {
  # Critical: bind-only output must be unchanged for the 17 downstream repos.
  local _extras=('${WS_PATH}:/home/${USER_NAME}/work')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^volumes:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml named volume with :mode strips mode from top-level name (#482)" {
  local _extras=('my_state:/srv/state:rw')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  # top-level stub has the bare name, no :rw
  run grep -E '^  my_state:$' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^  my_state:rw' "${COMPOSE_OUT}"
  assert_failure
  # service level keeps the mode
  run grep -F -- '- my_state:/srv/state:rw' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml dedups a named volume referenced twice (#482)" {
  local _extras=('my_state:/srv/state' 'my_state:/srv/other:rw')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -c '^  my_state:$' "${COMPOSE_OUT}"
  assert_output "1"
}

@test "generate_compose_yaml top-level volumes: stub has no driver/labels (#482)" {
  local _extras=('my_state:/srv/state')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  # the line after `  my_state:` must not be an indented driver/labels key
  run grep -A1 '^  my_state:$' "${COMPOSE_OUT}"
  refute_output --partial "driver"
  refute_output --partial "labels"
}

@test "generate_compose_yaml emits volumes: before networks: (#482)" {
  # network on -> both top-level blocks present; volumes precedes networks.
  local _extras=('my_state:/srv/state')
  NETWORK_MODE=bridge NETWORK_NAME=mynet \
    generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
      "false" "false" "0" "gpu" _extras
  if grep -qE '^networks:$' "${COMPOSE_OUT}"; then
    local _vol_ln _net_ln
    _vol_ln="$(grep -n '^volumes:$' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
    _net_ln="$(grep -n '^networks:$' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
    (( _vol_ln < _net_ln ))
  else
    skip "networks: not emitted in this invocation shape"
  fi
}

@test "generate_compose_yaml emits workspace mount when present in extras" {
  # Workspace is now driven by [volumes] mount_1 (setup.sh writeback),
  # not a hard-coded baseline. Simulate the extras array containing a
  # mount_1 entry (format produced by setup.sh upsert).
  local _extras=('${WS_PATH}:/home/${USER_NAME}/work')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F '${WS_PATH}:/home/${USER_NAME}/work' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml omits workspace when extras is empty (opt-out)" {
  # When the user clears mount_1, no workspace mount appears. GUI is also
  # disabled here, so the volumes block itself should not be emitted.
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F ':/home/${USER_NAME}/work' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml default (no network_name) keeps network_mode env var" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'network_mode: ${NETWORK_MODE}' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'external: true' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml with network_name emits networks list + bridge driver block (compose self-managed)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "mynet"
  # network_mode is replaced
  run grep -F 'network_mode: ${NETWORK_MODE}' "${COMPOSE_OUT}"
  assert_failure
  # service joins the named network
  run grep -F -- '- mynet' "${COMPOSE_OUT}"
  assert_success
  # top-level networks block: compose self-manages (driver: bridge)
  run grep -F 'driver: bridge' "${COMPOSE_OUT}"
  assert_success
  # NOT external (would require user to `docker network create` first)
  run grep -F 'external: true' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml omits devices block when both inputs empty" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" ""
  run grep -E '^    devices:$' "${COMPOSE_OUT}"
  assert_failure
  run grep -E '^    device_cgroup_rules:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits devices: block from device list" {
  local _extras=()
  local _devices
  printf -v _devices '%s\n%s' "/dev/video0:/dev/video0" "/dev/dri"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "${_devices}" ""
  run grep -E '^    devices:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /dev/video0:/dev/video0' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /dev/dri' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml accepts /dev:/dev (full /dev tree bind)" {
  # Default template value; must pass through verbatim.
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev"
  run grep -E '^    devices:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /dev:/dev' "${COMPOSE_OUT}"
  assert_success
}

# ── #450 device propagation → volumes long-form ──────────────────────

@test "generate_compose_yaml: device with propagation emits to volumes long-form (#450 P1)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev:rslave"
  run grep -F 'propagation: rslave' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'source: /dev' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'target: /dev' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml: device without propagation stays in devices: (#450 P1)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev/video0:/dev/video0"
  run grep -E '^    devices:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /dev/video0:/dev/video0' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'propagation:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml: mixed devices split correctly (#450 P1)" {
  local _extras=()
  local _devices
  printf -v _devices '%s\n%s' "/dev/video0:/dev/video0" "/dev:/dev:rslave"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "${_devices}"
  run grep -F -- '- /dev/video0:/dev/video0' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'propagation: rslave' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml: device rw,rslave emits combined propagation (#450 P1)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev:rw,rslave"
  run grep -F 'propagation: rslave' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'read_only: false' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml: device ro,rshared emits read_only + propagation (#450 P1)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/data:/data:ro,rshared"
  run grep -F 'propagation: rshared' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'read_only: true' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml: propagation-only device creates volumes: header even without extras (#450)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev:rslave"
  run grep -E '^    volumes:$' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml: all devices have propagation → no devices: section (#450)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev:rslave"
  run grep -E '^    devices:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits environment block from env_ list" {
  local _extras=()
  local _env
  printf -v _env '%s\n%s' "ROS_DOMAIN_ID=7" "LOG_LEVEL=debug"
  # positional args: ... extras net_name devices env tmpfs ports shm_size net_mode ipc_mode
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -E '^    environment:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- ROS_DOMAIN_ID=7' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- LOG_LEVEL=debug' "${COMPOSE_OUT}"
  assert_success
}

@test "environment env_N expands \${VAR} cross-reference to earlier sibling (refs #236)" {
  # When a later env_N value references an earlier sibling KEY via
  # `\${KEY}`, the emitted compose.yaml line should contain the earlier
  # sibling's value, not a literal `\${KEY}` (which compose's own var
  # substitution does NOT resolve from sibling environment entries).
  local _extras=()
  local _env
  printf -v _env '%s\n%s' "BUILD_TARGET=production" "LD_LIBRARY_PATH=/foo/\${BUILD_TARGET}/lib"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -F -- '- LD_LIBRARY_PATH=/foo/production/lib' "${COMPOSE_OUT}"
  assert_success
  refute grep -F -- '${BUILD_TARGET}' "${COMPOSE_OUT}"
}

@test "environment env_N forward reference is left literal (refs #236)" {
  # Order-sensitive: a value that references a LATER sibling cannot be
  # expanded (the sibling hasn't been parsed yet). The literal `\${VAR}`
  # survives so compose.yaml's own substitution gets a chance from
  # `.env` / shell env, and an unintended footgun surfaces visibly.
  local _extras=()
  local _env
  printf -v _env '%s\n%s' "LD_LIBRARY_PATH=/foo/\${BUILD_TARGET}/lib" "BUILD_TARGET=production"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -F -- '- LD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- BUILD_TARGET=production' "${COMPOSE_OUT}"
  assert_success
}

@test "environment env_N unknown \${VAR} is left literal (refs #236)" {
  # When `\${VAR}` references a name with no matching sibling, leave it
  # as a literal in compose.yaml. compose's own substitution (from
  # `.env` / shell env) gets a chance at file-load; if that also fails
  # the user sees an explicit error, not a silent empty replacement.
  local _extras=()
  local _env
  printf -v _env '%s' "PATH_PREFIX=/foo/\${UNDEFINED_VAR}/bar"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -F -- '- PATH_PREFIX=/foo/${UNDEFINED_VAR}/bar' "${COMPOSE_OUT}"
  assert_success
}

@test "environment env_N supports multiple cross-references in one value (refs #236)" {
  local _extras=()
  local _env
  printf -v _env '%s\n%s\n%s' \
    "BUILD_TARGET=production" \
    "ARCH=aarch64" \
    "PLUGIN_PATH=/opt/\${BUILD_TARGET}/lib/\${ARCH}"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -F -- '- PLUGIN_PATH=/opt/production/lib/aarch64' "${COMPOSE_OUT}"
  assert_success
}

@test "environment env_N transitive cross-reference resolves through chain (refs #236)" {
  # If env_2 references env_1, and env_3 references env_2, env_3 should
  # see the FULLY expanded env_2 (not a chain that needs more expansion).
  local _extras=()
  local _env
  printf -v _env '%s\n%s\n%s' \
    "ROOT=/opt" \
    "BASE=\${ROOT}/lib" \
    "INCLUDE=\${BASE}/include"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "${_env}" "" "" "" "host" "host"
  run grep -F -- '- BASE=/opt/lib' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- INCLUDE=/opt/lib/include' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits tmpfs block from tmpfs_ list" {
  local _extras=()
  local _tmpfs
  printf -v _tmpfs '%s\n%s' "/tmp" "/var/run:size=64m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "${_tmpfs}" "" "" "host" "host"
  run grep -E '^    tmpfs:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /tmp' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /var/run:size=64m' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits ports block only under network_mode=bridge" {
  local _extras=()
  local _ports
  printf -v _ports '%s\n%s' "8080:80" "5000:5000"
  # host mode: ports dropped
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "${_ports}" "" "host" "host"
  run grep -E '^    ports:$' "${COMPOSE_OUT}"
  assert_failure
  # bridge mode: ports emitted
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "${_ports}" "" "bridge" "host"
  run grep -E '^    ports:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "8080:80"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "5000:5000"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits shm_size only when ipc_mode != host" {
  local _extras=()
  # ipc=host: shm_size ignored
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "2gb" "host" "host"
  run grep -E '^    shm_size: 2gb$' "${COMPOSE_OUT}"
  assert_failure
  # ipc=private: shm_size emitted
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "2gb" "host" "private"
  run grep -E '^    shm_size: 2gb$' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits cap_add from security list" {
  local _extras=()
  local _cap_add
  printf -v _cap_add '%s\n%s' "SYS_ADMIN" "NET_ADMIN"
  # positional: out name gui gpu count caps extras net_name devices env tmpfs ports shm net_mode ipc_mode pid_mode cap_add cap_drop sec_opt
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" "${_cap_add}" "" ""
  run grep -E '^    cap_add:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- SYS_ADMIN' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- NET_ADMIN' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits cap_drop from security list" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" "" "ALL" ""
  run grep -E '^    cap_drop:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- ALL' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits security_opt from security list" {
  local _extras=()
  local _sec_opt
  printf -v _sec_opt '%s\n%s' "seccomp:unconfined" "apparmor:unconfined"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" "" "" "${_sec_opt}"
  run grep -E '^    security_opt:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- seccomp:unconfined' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- apparmor:unconfined' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml omits cap_add / cap_drop / security_opt blocks when empty" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^    cap_add:$' "${COMPOSE_OUT}"
  assert_failure
  run grep -E '^    cap_drop:$' "${COMPOSE_OUT}"
  assert_failure
  run grep -E '^    security_opt:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml per-stage security.cap_add_inherit=false clears inherited caps for that stage only (#526)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS probe
DOCK
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[stage:probe]
security.cap_add_inherit = false
security.security_opt_inherit = false
CONF
  local _extras=()
  local _cap_add _sec_opt
  printf -v _cap_add '%s' "SYS_ADMIN"
  printf -v _sec_opt '%s' "seccomp:unconfined"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" "${_cap_add}" "" "${_sec_opt}"
  # devel inherits the top-level caps.
  run awk '/^  devel:/{f=1} f&&/cap_add:/{print; exit}' "${COMPOSE_OUT}"
  assert_output --partial "cap_add:"
  # probe (cleared) carries no cap_add / security_opt.
  local _probe_block
  _probe_block="$(awk '/^  probe:/{f=1;next} /^  [a-z]/{f=0} f' "${COMPOSE_OUT}")"
  refute [ -n "$(grep -F 'SYS_ADMIN' <<< "${_probe_block}")" ]
  refute [ -n "$(grep -F 'seccomp:unconfined' <<< "${_probe_block}")" ]
}

@test "generate_compose_yaml per-stage security.cap_add_N appends to inherited caps (#526)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS flash
DOCK
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[stage:flash]
security.cap_add_1 = MKNOD
CONF
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" "SYS_ADMIN" "" ""
  local _flash_block
  _flash_block="$(awk '/^  flash:/{f=1;next} /^  [a-z]/{f=0} f' "${COMPOSE_OUT}")"
  assert [ -n "$(grep -F 'SYS_ADMIN' <<< "${_flash_block}")" ]
  assert [ -n "$(grep -F 'MKNOD' <<< "${_flash_block}")" ]
}

@test "generate_compose_yaml emits network_mode/ipc/privileged via env var" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'network_mode: ${NETWORK_MODE}' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'ipc: ${IPC_MODE}' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'privileged: ${PRIVILEGED}' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml omits pid when default private" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'pid:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits pid env-var ref when host" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "host"
  run grep -F 'pid: ${PID_MODE}' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits test service with profiles: [test]" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F -- '- test' "${COMPOSE_OUT}"
  assert_success
  run grep -F ':test' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml image field contains repo name" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F "local}/myrepo:devel" "${COMPOSE_OUT}"
  assert_success
  run grep -F "local}/myrepo:test" "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits TZ build arg with Asia/Taipei default" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'TZ: ${TZ:-Asia/Taipei}' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits TARGETARCH build arg on devel (test inherits via extends, #493)" {
  local _extras=()
  # Positional args up to #21 are optional (defaults via ${N:-}); pos #22 is target_arch.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras \
    "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "arm64"
  # #493 (A1'-b): the test service is now an extends:devel stage with no
  # override, so it does not re-emit its own build.args — it inherits
  # devel's TARGETARCH at compose-merge time. The line appears once.
  run grep -cF 'TARGETARCH: ${TARGET_ARCH}' "${COMPOSE_OUT}"
  assert_success
  assert_output "1"
}

@test "generate_compose_yaml omits TARGETARCH line when target_arch empty (BuildKit auto-fill)" {
  local _extras=()
  # Omit the final target_arch arg entirely — default is empty.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'TARGETARCH:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits build.network on devel (test inherits via extends, #493)" {
  local _extras=()
  # Pos #23 is build_network.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras \
    "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "host"
  # #493 (A1'-b): test is an extends:devel stage with no override, so the
  # build.network line is emitted once on devel and inherited by test.
  run grep -cE '^      network: host$' "${COMPOSE_OUT}"
  assert_success
  assert_output "1"
}

@test "generate_compose_yaml omits build.network line when build_network empty" {
  local _extras=()
  # Default = empty → no network key under build.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^      network:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml does NOT emit /dev:/dev by default (not in baseline)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F -- '- /dev:/dev' "${COMPOSE_OUT}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# GPU deploy block — conditional
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml GPU enabled => deploy block present" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "true" "all" "gpu" _extras
  run grep -F 'deploy:' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'driver: nvidia' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'count: all' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml GPU disabled => no deploy block" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'deploy:' "${COMPOSE_OUT}"
  assert_failure
  run grep -F 'driver: nvidia' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml GPU with specific count and capabilities" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "true" "2" "compute utility" _extras
  run grep -F 'count: 2' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'capabilities: [compute, utility]' "${COMPOSE_OUT}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# GUI block — conditional
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml GUI enabled => DISPLAY env + X11 volumes present" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "true" "false" "0" "gpu" _extras
  run grep -F 'DISPLAY=${DISPLAY' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'WAYLAND_DISPLAY' "${COMPOSE_OUT}"
  assert_success
  run grep -F '/tmp/.X11-unix:/tmp/.X11-unix:ro' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'XAUTHORITY' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml GUI disabled => no DISPLAY env + no X11 volumes" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'DISPLAY=${DISPLAY' "${COMPOSE_OUT}"
  assert_failure
  run grep -F '/tmp/.X11-unix:/tmp/.X11-unix:ro' "${COMPOSE_OUT}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Extra volumes ([volumes] section)
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml extra volumes appended after baseline" {
  local _extras=("/dev:/dev" "/data:/data" "/etc/machine-id:/etc/machine-id:ro")
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F -- '- /dev:/dev' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /data:/data' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /etc/machine-id:/etc/machine-id:ro' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml empty extras => no extra mount lines" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F -- '- /data:' "${COMPOSE_OUT}"
  assert_failure
  run grep -F -- '- /dev:/dev' "${COMPOSE_OUT}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Fully loaded — GUI + GPU + extras
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml with GUI+GPU+extras => all sections present" {
  local _extras=("/dev:/dev" "/srv:/srv")
  generate_compose_yaml "${COMPOSE_OUT}" "isaac_sim" \
    "true" "true" "all" "gpu" _extras
  run grep -F 'DISPLAY=${DISPLAY' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'driver: nvidia' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- /srv:/srv' "${COMPOSE_OUT}"
  assert_success
  run grep -F "local}/isaac_sim:devel" "${COMPOSE_OUT}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# [devices] cgroup_rule_* → compose.yaml device_cgroup_rules: (B10)
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml emits device_cgroup_rules: when cgroup rules provided" {
  local _extras=()
  # positional: gui gpu count caps extras net_name devices env tmpfs ports
  # shm_size net_mode ipc_mode pid_mode cap_add cap_drop sec_opt cgroup_rules
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" \
    "" "" "" "" \
    "" "host" "host" "private" "" "" "" \
    $'c 189:* rwm\nc 81:* rwm'
  run grep -F 'device_cgroup_rules:' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "c 189:* rwm"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "c 81:* rwm"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml omits device_cgroup_rules: when rules list is empty" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'device_cgroup_rules:' "${COMPOSE_OUT}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# [deploy] runtime → compose.yaml service-level runtime key (Jetson)
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml omits runtime: when runtime arg is empty (desktop default)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^    runtime:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits runtime: nvidia under devel when runtime=nvidia" {
  local _extras=()
  # positional args 1..23 unchanged; 24th is _runtime.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "true" "all" "gpu" _extras "" \
    "" "" "" "" \
    "" "host" "host" "private" "" "" "" \
    "" "" "" "" \
    "nvidia"
  run grep -F '    runtime: nvidia' "${COMPOSE_OUT}"
  assert_success
  # Only in devel (one occurrence); test service must not get runtime:
  [ "$(grep -c '^    runtime:' "${COMPOSE_OUT}")" = "1" ]
}

@test "generate_compose_yaml placement: runtime: appears between tty and cap_add region" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "true" "all" "gpu" _extras "" \
    "" "" "" "" \
    "" "host" "host" "private" "SYS_ADMIN" "" "" \
    "" "" "" "" \
    "nvidia"
  # runtime: must appear after `tty: true` and before `cap_add:` in devel
  local _tty_line _runtime_line _cap_line
  _tty_line="$(grep -n '^    tty: true' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  _runtime_line="$(grep -n '^    runtime:' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  _cap_line="$(grep -n '^    cap_add:' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  (( _tty_line < _runtime_line ))
  (( _runtime_line < _cap_line ))
}

# ════════════════════════════════════════════════════════════════════
# Runtime service auto-emission (issue #108)
# ════════════════════════════════════════════════════════════════════
#
# When the sibling Dockerfile declares `FROM <base> AS runtime`, setup.sh
# emits a dedicated `runtime` compose service alongside `devel`/`test`.
# Absent that stage, emission is skipped so plain-dev repos don't get a
# broken service entry.

@test "generate_compose_yaml emits runtime service when Dockerfile has AS runtime" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS devel
CMD ["bash"]

FROM devel AS runtime
CMD ["/entrypoint.sh"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^  runtime:' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml skips runtime service when Dockerfile lacks AS runtime" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS devel
CMD ["bash"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -cE '^  runtime:' "${COMPOSE_OUT}"
  assert_output "0"
}

@test "generate_compose_yaml skips runtime service when Dockerfile is absent" {
  # No Dockerfile in TEMP_DIR at all.
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -cE '^  runtime:' "${COMPOSE_OUT}"
  assert_output "0"
}

@test "runtime service extends devel and overrides target/image/tty/profile" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS devel
CMD ["bash"]

FROM devel AS runtime
CMD ["/app"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  # extends → devel (compose merges base volumes, env, caps, etc.)
  run grep -F 'service: devel' "${COMPOSE_OUT}"
  assert_success
  # build target override
  run grep -F 'target: runtime' "${COMPOSE_OUT}"
  assert_success
  # image tag is :runtime (not :devel)
  run grep -E '^    image:.*:runtime$' "${COMPOSE_OUT}"
  assert_success
  # container_name: ${USER_NAME} prefix (#322 multi-user disambiguation)
  # + -runtime stage suffix + INSTANCE_SUFFIX support
  run grep -F 'container_name: ${USER_NAME}-myrepo-runtime${INSTANCE_SUFFIX:-}' "${COMPOSE_OUT}"
  assert_success
  # non-interactive (runtime is headless auto-run, Dockerfile CMD drives)
  run grep -E '^    stdin_open: false$' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^    tty: false$' "${COMPOSE_OUT}"
  assert_success
  # profiles gate prevents plain `compose up` from starting runtime.
  # `--` guards against grep reading the leading `-` as an option.
  run grep -F -- '- runtime' "${COMPOSE_OUT}"
  assert_success
}

@test "runtime service appears between devel and test blocks" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS devel
CMD ["bash"]

FROM devel AS runtime
CMD ["/app"]

FROM devel AS devel-test
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  local _devel _runtime _test
  _devel="$(grep -n '^  devel:'   "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  _runtime="$(grep -n '^  runtime:' "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  _test="$(grep -n '^  test:'    "${COMPOSE_OUT}" | head -1 | cut -d: -f1)"
  (( _devel < _runtime ))
  (( _runtime < _test ))
}

@test "runtime detection is robust against weird whitespace" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04    AS    devel
CMD ["bash"]

FROM   devel   AS   runtime
CMD ["/app"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -E '^  runtime:' "${COMPOSE_OUT}"
  assert_success
}

@test "runtime detection ignores non-runtime stage names" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS runtime-base
FROM runtime-base AS devel
CMD ["bash"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  # "runtime-base" doesn't count as the runtime stage (strict match).
  run grep -cE '^  runtime:' "${COMPOSE_OUT}"
  assert_output "0"
}

# ── #450 P3: per-stage device propagation redirect ───────────────

@test "generate_compose_yaml: runtime stage inherits device propagation from devel (#450 P3)" {
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM ubuntu:24.04 AS devel
CMD ["bash"]

FROM devel AS runtime
CMD ["/app"]
DOCK
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "/dev:/dev:rslave"
  run grep -c 'propagation: rslave' "${COMPOSE_OUT}"
  [[ "${output}" -ge 1 ]]
  run grep -E '^  runtime:' "${COMPOSE_OUT}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# _resolve_docker_flags — single per-stage flag-resolution layer (#505)
#
# Resolves one stage's effective docker flags from its [stage:*]
# overrides (already filtered to the allowlist) layered over the parent
# (devel / top-level) already-resolved values. The ONE resolution layer
# both the compose renderer (generate_compose_yaml per-stage loop) and
# the deploy renderer (S6 #506, runtime stage) call, so the two never
# drift. Modes (gui/gpu) inherit the parent's resolved boolean unless
# the stage forces off/force — no per-stage hardware re-detection.
# ════════════════════════════════════════════════════════════════════

@test "_resolve_docker_flags: no overrides => inherits all parent values (#505)" {
  local -a _k=() _v=()
  local -A _parent=(
    [gui]="true" [gpu]="true" [gpu_count]="2" [gpu_caps]="gpu compute"
    [runtime]="nvidia" [net_mode]="bridge" [ipc_mode]="host"
    [pid_mode]="private" [net_name]="mynet"
    [volumes_top]=$'./a:/a' [env_top]=$'TOP=1' [ports_top]=$'9000:9000'
  )
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[gui]}" "true"
  assert_equal "${_eff[gpu]}" "true"
  assert_equal "${_eff[gpu_count]}" "2"
  assert_equal "${_eff[gpu_caps]}" "gpu compute"
  assert_equal "${_eff[runtime]}" "nvidia"
  assert_equal "${_eff[net_mode]}" "bridge"
  assert_equal "${_eff[ipc_mode]}" "host"
  assert_equal "${_eff[pid_mode]}" "private"
  assert_equal "${_eff[net_name]}" "mynet"
  assert_equal "${_eff[privileged]}" ""
  assert_equal "${_eff[volumes]}" "./a:/a"
  assert_equal "${_eff[environment]}" "TOP=1"
  assert_equal "${_eff[ports]}" "9000:9000"
}

@test "_resolve_docker_flags: gui.mode=off overrides parent gui=true (#505)" {
  local -a _k=("gui.mode") _v=("off")
  local -A _parent=([gui]="true" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[gui]}" "false"
}

@test "_resolve_docker_flags: gui.mode=force overrides parent gui=false (#505)" {
  local -a _k=("gui.mode") _v=("force")
  local -A _parent=([gui]="false" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[gui]}" "true"
}

@test "_resolve_docker_flags: deploy.gpu_mode=off overrides parent gpu=true (#505)" {
  local -a _k=("deploy.gpu_mode") _v=("off")
  local -A _parent=([gui]="false" [gpu]="true" [gpu_count]="2" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[gpu]}" "false"
}

@test "_resolve_docker_flags: deploy.gpu_count + gpu_capabilities overrides win (#505)" {
  local -a _k=("deploy.gpu_count" "deploy.gpu_capabilities") _v=("4" "compute utility")
  local -A _parent=([gui]="false" [gpu]="true" [gpu_count]="1" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[gpu_count]}" "4"
  assert_equal "${_eff[gpu_caps]}" "compute utility"
}

@test "_resolve_docker_flags: deploy.gpu_runtime override wins (#505/#481)" {
  local -a _k=("deploy.gpu_runtime") _v=("nvidia")
  local -A _parent=([gui]="false" [gpu]="true" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[runtime]}" "nvidia"
}

@test "_resolve_docker_flags: legacy deploy.runtime alias used when gpu_runtime absent (#505/#481)" {
  local -a _k=("deploy.runtime") _v=("nvidia")
  local -A _parent=([gui]="false" [gpu]="true" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[runtime]}" "nvidia"
}

@test "_resolve_docker_flags: legacy deploy.runtime overrides gpu_runtime at per-stage scope (resolved last, #505/#481)" {
  # Pre-existing per-stage precedence preserved byte-for-byte by the #505
  # refactor: when BOTH keys appear under [stage:*], deploy.gpu_runtime is
  # resolved first (with the parent as fallback), then the legacy
  # deploy.runtime is resolved with that result as ITS fallback -- so a
  # present deploy.runtime wins. (This per-stage edge case differs from the
  # global resolution where gpu_runtime wins; left unchanged here because
  # S5 is a byte-identical refactor, not a behaviour change.)
  local -a _k=("deploy.gpu_runtime" "deploy.runtime") _v=("nvidia" "off")
  local -A _parent=([gui]="false" [gpu]="true" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[runtime]}" "off"
}

@test "_resolve_docker_flags: network scalars + privileged override (#505)" {
  local -a _k=("network.mode" "network.ipc" "network.pid" "network.network_name" "security.privileged") \
           _v=("bridge" "private" "host" "altnet" "true")
  local -A _parent=([gui]="false" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="default" [volumes_top]="" [env_top]="" [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[net_mode]}" "bridge"
  assert_equal "${_eff[ipc_mode]}" "private"
  assert_equal "${_eff[pid_mode]}" "host"
  assert_equal "${_eff[net_name]}" "altnet"
  assert_equal "${_eff[privileged]}" "true"
}

@test "_resolve_docker_flags: list fields append to top by default (#505)" {
  local -a _k=("volumes.mount_1" "environment.env_1" "network.port_1") \
           _v=("./b:/b" "STAGE=1" "8080:80")
  local -A _parent=([gui]="false" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="bridge" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]=$'./a:/a' [env_top]=$'TOP=1' [ports_top]=$'9000:9000')
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[volumes]}" $'./a:/a\n./b:/b'
  assert_equal "${_eff[environment]}" $'TOP=1\nSTAGE=1'
  assert_equal "${_eff[ports]}" $'9000:9000\n8080:80'
}

@test "_resolve_docker_flags: list *_inherit=false switches to replace mode (#505)" {
  local -a _k=("volumes.mount_inherit" "volumes.mount_1" "environment.env_inherit" "environment.env_1") \
           _v=("false" "./only:/only" "false" "ONLY=1")
  local -A _parent=([gui]="false" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]=$'./a:/a' [env_top]=$'TOP=1' [ports_top]="")
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[volumes]}" "./only:/only"
  assert_equal "${_eff[environment]}" "ONLY=1"
}

@test "_resolve_docker_flags: security cap_add / cap_drop / security_opt append to top by default (#526)" {
  local -a _k=("security.cap_add_1" "security.cap_drop_1" "security.security_opt_1") \
           _v=("MKNOD" "NET_RAW" "apparmor:unconfined")
  local -A _parent=([gui]="false" [gpu]="false" [gpu_count]="0" [gpu_caps]="gpu" [runtime]="" [net_mode]="host" [ipc_mode]="host" [pid_mode]="private" [net_name]="" [volumes_top]="" [env_top]="" [ports_top]="" [cap_add_top]=$'SYS_ADMIN' [cap_drop_top]=$'ALL' [sec_opt_top]=$'seccomp:unconfined')
  local -A _eff=()
  _resolve_docker_flags _k _v _parent _eff
  assert_equal "${_eff[cap_add]}" $'SYS_ADMIN\nMKNOD'
  assert_equal "${_eff[cap_drop]}" $'ALL\nNET_RAW'
  assert_equal "${_eff[security_opt]}" $'seccomp:unconfined\napparmor:unconfined'
}

@test "generate_compose_yaml per-stage emit is byte-identical via _resolve_docker_flags (#505 golden master)" {
  # Full-file golden master guarding the #505 refactor: the per-stage
  # resolution now flows through the single _resolve_docker_flags layer.
  # The fixture exercises a [stage:headless] override hitting every
  # branch -- gui off, gpu off, ipc override (shm emit), privileged
  # override, runtime inherit, net inherit, env replace, volume replace,
  # port append -- so any drift in the assembled compose.yaml fails here.
  cat > "${TEMP_DIR}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS headless
DOCK
  mkdir -p "${TEMP_DIR}/config/docker"
  cat > "${TEMP_DIR}/config/docker/setup.conf" <<'CONF'
[stage:headless]
gui.mode = off
deploy.gpu_mode = off
network.ipc = private
security.privileged = true
volumes.mount_inherit = false
volumes.mount_1 = ./hl-data:/data
environment.env_inherit = false
environment.env_1 = HEADLESS=1
network.port_1 = 8080:80
CONF
  local _extras=('./ws:/workspace' 'state_vol:/srv/state')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "true" "true" "1" "gpu compute" \
    _extras "mynet" \
    "" \
    $'TOP_ENV=1' "" $'9000:9000' \
    "256m" "bridge" "host" "private" \
    "" "" "" \
    "" \
    "" \
    "" \
    "host" \
    "nvidia" \
    "" \
    "" \
    "" \
    "no" \
    ""
  cat > "${TEMP_DIR}/expected.yaml" <<'GOLDEN'
# AUTO-GENERATED BY setup.sh — DO NOT EDIT.
# Edit setup.conf instead. Regenerate via ./build.sh --setup or ./run.sh --setup.
name: ${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX:-}
services:
  devel:
    build:
      context: .
      dockerfile: Dockerfile
      target: devel
      network: host
      args:
        APT_MIRROR_UBUNTU: ${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: ${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: ${TZ:-Asia/Taipei}
        USER_NAME: ${USER_NAME}
        USER_GROUP: ${USER_GROUP}
        USER_UID: ${USER_UID}
        USER_GID: ${USER_GID}
    image: ${DOCKER_HUB_USER:-local}/myrepo:devel
    container_name: ${USER_NAME}-myrepo${INSTANCE_SUFFIX:-}
    privileged: ${PRIVILEGED}
    ipc: ${IPC_MODE}
    stdin_open: true
    tty: true
    env_file:
      - .env
    runtime: nvidia
    networks:
      - mynet
    environment:
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=${XAUTHORITY:-}
      - TOP_ENV=1
    ports:
      - "9000:9000"
    volumes:
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:${XAUTHORITY:-/dev/null}:ro
      - ./ws:/workspace
      - state_vol:/srv/state
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu, compute]

  test:
    extends:
      service: devel
    build:
      context: .
      dockerfile: Dockerfile
      target: devel-test
    image: ${DOCKER_HUB_USER:-local}/myrepo:test
    container_name: ${USER_NAME}-myrepo-test${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - test

  headless:
    build:
      context: .
      dockerfile: Dockerfile
      target: headless
      network: host
      args:
        APT_MIRROR_UBUNTU: ${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: ${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: ${TZ:-Asia/Taipei}
        USER_NAME: ${USER_NAME}
        USER_GROUP: ${USER_GROUP}
        USER_UID: ${USER_UID}
        USER_GID: ${USER_GID}
    image: ${DOCKER_HUB_USER:-local}/myrepo:headless
    container_name: ${USER_NAME}-myrepo-headless${INSTANCE_SUFFIX:-}
    stdin_open: false
    tty: false
    profiles:
      - headless
    env_file:
      - .env
    privileged: true
    ipc: private
    runtime: nvidia
    networks:
      - mynet
    environment:
      - HEADLESS=1
    ports:
      - "9000:9000"
      - "8080:80"
    volumes:
      - ./hl-data:/data
    shm_size: 256m

volumes:
  state_vol:

networks:
  mynet:
    driver: bridge
GOLDEN
  run diff -u "${TEMP_DIR}/expected.yaml" "${COMPOSE_OUT}"
  assert_success
}
