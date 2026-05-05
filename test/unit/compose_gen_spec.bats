#!/usr/bin/env bats
#
# Tests for generate_compose_yaml() in script/docker/setup.sh.
# Verifies conditional emission of GPU deploy block, GUI env/volumes,
# extra volumes list, and baseline structural elements.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
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
  # positional: out name gui gpu count caps extras net_name devices env tmpfs ports shm net_mode ipc_mode cap_add cap_drop sec_opt
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "${_cap_add}" "" ""
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
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "" "ALL" ""
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
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "" "" "${_sec_opt}"
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

@test "generate_compose_yaml emits TARGETARCH line in both services when target_arch set" {
  local _extras=()
  # Positional args up to #20 are optional (defaults via ${N:-}); pos #21 is target_arch.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras \
    "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "arm64"
  # Must appear under both devel + test service build.args blocks.
  run grep -cF 'TARGETARCH: ${TARGET_ARCH}' "${COMPOSE_OUT}"
  assert_success
  assert_output "2"
}

@test "generate_compose_yaml omits TARGETARCH line when target_arch empty (BuildKit auto-fill)" {
  local _extras=()
  # Omit the final target_arch arg entirely — default is empty.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras
  run grep -F 'TARGETARCH:' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits build.network line in both services when build_network set" {
  local _extras=()
  # Pos #22 is build_network (new).
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras \
    "" "" "" "" "" "" "host" "host" \
    "" "" "" "" "" "" "host"
  # Must appear under both devel + test service build blocks.
  run grep -cE '^      network: host$' "${COMPOSE_OUT}"
  assert_success
  assert_output "2"
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
  # shm_size net_mode ipc_mode cap_add cap_drop sec_opt cgroup_rules
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" \
    "" "" "" "" \
    "" "host" "host" "" "" "" \
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
  # positional args 1..22 unchanged; 23rd is _runtime.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "true" "all" "gpu" _extras "" \
    "" "" "" "" \
    "" "host" "host" "" "" "" \
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
    "" "host" "host" "SYS_ADMIN" "" "" \
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
  # container_name uses -runtime suffix + INSTANCE_SUFFIX support
  run grep -F 'container_name: myrepo-runtime${INSTANCE_SUFFIX:-}' "${COMPOSE_OUT}"
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
