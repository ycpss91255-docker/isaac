#!/usr/bin/env bats
#
# Tests for the S6 (#506) deploy-generator primitives in
# script/docker/wrapper/setup.sh. S6a delivers _emit_docker_run_flags:
# the pure mapping from a resolved docker-flag record (the
# _resolve_docker_flags S5 output, plus the top-level-only fields
# devices / caps / security_opt / shm_size / dri_groups / cgroup_rules /
# restart) to a `docker run` argv fragment for the field launcher.
#
# [environment] is intentionally NOT mapped (it is baked into the image
# as ENV by S3), and gui is out of scope (the field launcher targets
# headless run; gui / X11 is a dev-only compose concern).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh
}

# Helper: join the emitted argv array into a single space-separated line
# so tests can assert on substrings without caring about element count.
_run_line() {
  printf '%s ' "${@}"
}

@test "_emit_docker_run_flags: privileged=true emits --privileged (#506)" {
  local -A _f=([privileged]="true")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--privileged"
}

@test "_emit_docker_run_flags: gpu count=0 emits --gpus all (#506)" {
  local -A _f=([gpu]="true" [gpu_count]="0" [gpu_caps]="gpu")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--gpus all"
}

@test "_emit_docker_run_flags: gpu count>0 emits count+capabilities spec (#506)" {
  local -A _f=([gpu]="true" [gpu_count]="2" [gpu_caps]="gpu compute")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--gpus count=2,capabilities=gpu,compute"
}

@test "_emit_docker_run_flags: gpu=false emits no --gpus (#506)" {
  local -A _f=([gpu]="false" [gpu_count]="2")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "--gpus"
}

@test "_emit_docker_run_flags: runtime=nvidia emits --runtime=nvidia (#506)" {
  local -A _f=([runtime]="nvidia")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--runtime=nvidia"
}

@test "_emit_docker_run_flags: runtime off/auto/empty emits no --runtime (#506)" {
  local _m
  for _m in "off" "auto" ""; do
    local -A _f=([runtime]="${_m}")
    local -a _out=()
    _emit_docker_run_flags _f _out
    run _run_line "${_out[@]}"
    refute_output --partial "--runtime"
  done
}

@test "_emit_docker_run_flags: net host emits --network=host (#506)" {
  local -A _f=([net_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--network=host"
}

@test "_emit_docker_run_flags: net bridge + name emits --network=<name> (#506)" {
  local -A _f=([net_mode]="bridge" [net_name]="mynet")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--network=mynet"
}

@test "_emit_docker_run_flags: net bridge without name emits no --network (default bridge) (#506)" {
  local -A _f=([net_mode]="bridge")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "--network"
}

@test "_emit_docker_run_flags: ipc host emits --ipc=host; private is skipped (#506)" {
  local -A _f=([ipc_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--ipc=host"
  local -A _f2=([ipc_mode]="private")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--ipc"
}

@test "_emit_docker_run_flags: pid host emits --pid=host (#506)" {
  local -A _f=([pid_mode]="host")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--pid=host"
}

@test "_emit_docker_run_flags: shm_size emitted only when ipc \!= host (#506)" {
  local -A _f=([shm_size]="256m" [ipc_mode]="private")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--shm-size=256m"
  local -A _f2=([shm_size]="256m" [ipc_mode]="host")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--shm-size"
}

@test "_emit_docker_run_flags: restart emitted only when set and \!= no (#506)" {
  local -A _f=([restart]="on-failure")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--restart=on-failure"
  local -A _f2=([restart]="no")
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "--restart"
}

@test "_emit_docker_run_flags: volumes each emit -v (#506)" {
  local -A _f=([volumes]=$'./a:/a\nstate:/srv/state')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "-v ./a:/a"
  assert_output --partial "-v state:/srv/state"
}

@test "_emit_docker_run_flags: ports emit -p only under bridge (#506)" {
  local -A _f=([net_mode]="bridge" [ports]=$'8080:80')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "-p 8080:80"
  local -A _f2=([net_mode]="host" [ports]=$'8080:80')
  local -a _out2=()
  _emit_docker_run_flags _f2 _out2
  run _run_line "${_out2[@]}"
  refute_output --partial "-p 8080:80"
}

@test "_emit_docker_run_flags: plain device -> --device, propagation device -> -v (#506)" {
  local -A _f=([devices]=$'/dev/ttyUSB0\n/dev:/dev:rslave')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--device /dev/ttyUSB0"
  assert_output --partial "-v /dev:/dev:rslave"
  refute_output --partial "--device /dev:/dev:rslave"
}

@test "_emit_docker_run_flags: caps + security_opt map to docker run flags (#506)" {
  local -A _f=([cap_add]=$'SYS_ADMIN\nNET_ADMIN' [cap_drop]=$'MKNOD' [security_opt]=$'seccomp:unconfined')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--cap-add SYS_ADMIN"
  assert_output --partial "--cap-add NET_ADMIN"
  assert_output --partial "--cap-drop MKNOD"
  assert_output --partial "--security-opt seccomp:unconfined"
}

@test "_emit_docker_run_flags: dri_groups (space-sep) each map to --group-add (#506)" {
  local -A _f=([dri_groups]="44 110")
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--group-add 44"
  assert_output --partial "--group-add 110"
}

@test "_emit_docker_run_flags: cgroup_rules map to --device-cgroup-rule (#506)" {
  local -A _f=([cgroup_rules]=$'c 81:* rmw')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  assert_output --partial "--device-cgroup-rule c 81:* rmw"
}

@test "_emit_docker_run_flags: environment and gui are NOT mapped (baked / dev-only) (#506)" {
  local -A _f=([gui]="true" [environment]=$'FOO=bar')
  local -a _out=()
  _emit_docker_run_flags _f _out
  run _run_line "${_out[@]}"
  refute_output --partial "FOO=bar"
  refute_output --partial "DISPLAY"
  refute_output --partial "X11"
}

@test "_emit_docker_run_flags: empty record emits nothing (#506)" {
  local -A _f=()
  local -a _out=()
  _emit_docker_run_flags _f _out
  assert_equal "${#_out[@]}" "0"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context (S6b, #506) — the shared conf-resolution layer
# used by both apply and the deploy generator. Loads setup.conf sections
# and resolves the docker/build scalars + list strings into one record.
# ════════════════════════════════════════════════════════════════════

_write_conf() {
  local _dir="${1}"; shift
  mkdir -p "${_dir}/config/docker"
  printf '%s\n' "$@" > "${_dir}/config/docker/setup.conf"
}

@test "_resolve_deploy_context: resolves scalars + list strings from setup.conf (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" \
    "[deploy]" "gpu_mode = force" "gpu_count = 2" "gpu_capabilities = gpu compute" "gpu_runtime = nvidia" \
    "[network]" "mode = bridge" "ipc = private" "network_name = mynet" "port_1 = 8080:80" \
    "[security]" "privileged = true" \
    "[devices]" "device_1 = /dev/ttyUSB0" \
    "[environment]" "env_1 = FOO=bar" \
    "[resources]" "shm_size = 256m" \
    "[lifecycle]" "restart = on-failure"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_mode]}" "force"
  assert_equal "${_ctx[gpu_count]}" "2"
  assert_equal "${_ctx[gpu_caps]}" "gpu compute"
  assert_equal "${_ctx[gpu_runtime_mode]}" "nvidia"
  assert_equal "${_ctx[net_mode]}" "bridge"
  assert_equal "${_ctx[ipc_mode]}" "private"
  assert_equal "${_ctx[network_name]}" "mynet"
  assert_equal "${_ctx[privileged]}" "true"
  assert_equal "${_ctx[devices_str]}" "/dev/ttyUSB0"
  assert_equal "${_ctx[env_str]}" "FOO=bar"
  assert_equal "${_ctx[ports_str]}" "8080:80"
  assert_equal "${_ctx[shm_size]}" "256m"
  assert_equal "${_ctx[restart_policy]}" "on-failure"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: applies effective defaults for a minimal repo conf (#506)" {
  # A repo conf that omits [deploy]/[network]/... still resolves through
  # the template-merged effective config (_load_setup_conf merges template
  # + per-repo), matching what apply produces. gpu_capabilities is omitted
  # here because its value is template-driven (not a bare _get_conf_value
  # fallback); the keys below are stable across template + bare default.
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[image_name]" "name = placeholder"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_mode]}" "auto"
  assert_equal "${_ctx[gpu_count]}" "all"
  assert_equal "${_ctx[gpu_runtime_mode]}" "auto"
  assert_equal "${_ctx[gui_mode]}" "auto"
  assert_equal "${_ctx[net_mode]}" "host"
  assert_equal "${_ctx[ipc_mode]}" "host"
  assert_equal "${_ctx[pid_mode]}" "private"
  assert_equal "${_ctx[privileged]}" "false"
  assert_equal "${_ctx[restart_policy]}" "no"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode (#506/#481)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "runtime = nvidia"
  local -A _ctx=()
  _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[gpu_runtime_mode]}" "nvidia"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: dri_groups auto detects host GIDs via SETUP_DETECT_DRI_GROUPS (#506/#496)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "dri_groups = auto"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44 110" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" "44 110"
  rm -rf "${_d}"
}

@test "_resolve_deploy_context: dri_groups off yields empty (#506/#496)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "dri_groups = off"
  local -A _ctx=()
  SETUP_DETECT_DRI_GROUPS="44 110" _resolve_deploy_context "${_d}" _ctx
  assert_equal "${_ctx[dri_groups_str]}" ""
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_sh (S6b-gen, #506) — writes the self-contained field
# launcher by tying _resolve_deploy_context + _resolve_docker_flags +
# _emit_docker_run_flags together. Generated file is chmod +x and
# ShellCheck-clean; carries docker-level flags only (no -e / no -v).
# ════════════════════════════════════════════════════════════════════

@test "_generate_deploy_sh: writes an executable launcher with the expected skeleton (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "local/myrepo:runtime" "myrepo-field" "${_out}"
  [ -x "${_out}" ]
  run cat "${_out}"
  assert_output --partial "/usr/bin/env bash"
  assert_output --partial "set -euo pipefail"
  assert_output --partial 'IMAGE="${DEPLOY_IMAGE:-local/myrepo:runtime}"'
  assert_output --partial 'CONTAINER_NAME="${DEPLOY_CONTAINER_NAME:-myrepo-field}"'
  assert_output --partial "exec docker run"
  assert_output --partial '"${IMAGE}"'
  assert_output --partial '"$@"'
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: inlines global [security] privileged + caps + devices (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[security]" "privileged = true" "cap_add_1 = SYS_ADMIN" \
    "[devices]" "device_1 = /dev/ttyUSB0"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "--privileged"
  assert_output --partial "--cap-add"
  assert_output --partial "SYS_ADMIN"
  assert_output --partial "--device"
  assert_output --partial "/dev/ttyUSB0"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: gpu force inlines --gpus count + capabilities + runtime (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = force" "gpu_count = 2" \
    "gpu_capabilities = gpu compute" "gpu_runtime = nvidia" "dri_groups = off"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "--gpus"
  assert_output --partial "count=2"
  # %q escapes the comma in the generated file (count=2\,capabilities=gpu\,compute);
  # the shell unescapes it back to a comma at field run time.
  assert_output --partial "capabilities=gpu"
  assert_output --partial "--runtime=nvidia"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: network host inlines --network=host (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[network]" "mode = host"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "--network=host"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: omits -e (env baked) and -v (no dev binds) (#506)" {
  local _d; _d="$(mktemp -d)"
  # SC2016: the literal ${WS_PATH} is intentional -- it is the portable
  # workspace-bind form written verbatim into setup.conf, not a shell expansion.
  # shellcheck disable=SC2016
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[environment]" "env_1 = FOO=bar" \
    "[volumes]" 'mount_1 = ${WS_PATH}:/work'
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  refute_output --partial "FOO=bar"
  refute_output --partial " -e "
  refute_output --partial " -v "
  refute_output --partial "/work"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: [lifecycle] restart inlines --restart (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" "[lifecycle]" "restart = on-failure"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "--restart=on-failure"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: per-stage [stage:runtime] override is applied (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[network]" "mode = host" \
    "[stage:runtime]" "network.mode = bridge" "network.network_name = fieldnet"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "--network=fieldnet"
  refute_output --partial "--network=host"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: per-stage security.cap_add_inherit=false clears inherited caps (#526)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[security]" "cap_add_1 = SYS_ADMIN" "security_opt_1 = seccomp:unconfined" \
    "[stage:runtime]" "security.cap_add_inherit = false" "security.security_opt_inherit = false"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  refute_output --partial "SYS_ADMIN"
  refute_output --partial "seccomp:unconfined"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: per-stage security.cap_add_N appends to inherited caps (#526)" {
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[security]" "cap_add_1 = SYS_ADMIN" \
    "[stage:runtime]" "security.cap_add_1 = MKNOD"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run cat "${_out}"
  assert_output --partial "SYS_ADMIN"
  assert_output --partial "MKNOD"
  rm -rf "${_d}"
}

@test "_generate_deploy_sh: generated launcher is ShellCheck-clean (#506)" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  local _d; _d="$(mktemp -d)"
  _write_conf "${_d}" "[deploy]" "gpu_mode = force" "gpu_count = 2" \
    "gpu_capabilities = gpu compute" "gpu_runtime = nvidia" "dri_groups = off" \
    "[security]" "privileged = true" "cap_add_1 = SYS_ADMIN" \
    "[devices]" "device_1 = /dev:/dev:rslave" \
    "[lifecycle]" "restart = on-failure"
  local _out="${_d}/deploy.sh"
  SETUP_DETECT_DRI_GROUPS="" _generate_deploy_sh "${_d}" "runtime" "img" "name" "${_out}"
  run shellcheck "${_out}"
  assert_success
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _bake_config_copy (S4 deploy half) + _generate_deploy_bundle (S6c, #506)
# orchestrator. The bundle orchestration's docker / tar steps run through
# _dry_run_cmd, so DRY_RUN=true asserts the plan without building.
# ════════════════════════════════════════════════════════════════════

@test "_bake_config_copy: splices COPY config/app into the target stage (#506/#504)" {
  local _d; _d="$(mktemp -d)"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/out"
  run cat "${_d}/out"
  assert_output --partial "COPY config/app /opt/app/config"
  # COPY lands inside the runtime stage (after its FROM, before CMD).
  local _from _copy _cmd
  _from="$(grep -n 'AS runtime' "${_d}/out" | head -1 | cut -d: -f1)"
  _copy="$(grep -n 'COPY config/app' "${_d}/out" | head -1 | cut -d: -f1)"
  _cmd="$(grep -n 'CMD' "${_d}/out" | head -1 | cut -d: -f1)"
  (( _from < _copy )) && (( _copy < _cmd ))
  rm -rf "${_d}"
}

@test "_bake_config_copy: handles src == out in place (#506/#504)" {
  local _d; _d="$(mktemp -d)"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS runtime
CMD ["/app"]
DOCK
  _bake_config_copy "${_d}/Dockerfile" "runtime" "${_d}/Dockerfile"
  run cat "${_d}/Dockerfile"
  assert_output --partial "COPY config/app /opt/app/config"
  assert_output --partial "FROM scratch AS runtime"
  rm -rf "${_d}"
}

@test "_generate_deploy_bundle: dry-run plans build --target + save + tar.xz (#506)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/docker"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[environment]" "env_1 = ROS_DOMAIN_ID=42" > "${_d}/config/docker/setup.conf"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
  local _bundle="${_d}/myrepo-runtime.deploy.tar.xz"
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_bundle}"
  unset DRY_RUN
  assert_success
  assert_output --partial "docker build --target runtime"
  assert_output --partial "docker save"
  assert_output --partial "tar -C"
  assert_output --partial "-cJf"
  assert_output --partial "${_bundle}"
  rm -rf "${_d}"
}

@test "_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set (#506/#503)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/docker"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[environment]" "env_1 = ROS_DOMAIN_ID=42" > "${_d}/config/docker/setup.conf"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "runtime" "${_d}/b.tar.xz"
  unset DRY_RUN
  assert_success
  assert_output --partial "Dockerfile.deploy"
  rm -rf "${_d}"
}

@test "_generate_deploy_bundle: dry-run builds from the plain Dockerfile when no runtime bake applies (#506)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/docker"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" > "${_d}/config/docker/setup.conf"
  cat > "${_d}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
DOCK
  export DRY_RUN=true
  SETUP_DETECT_DRI_GROUPS="" run _generate_deploy_bundle "${_d}" "devel" "${_d}/b.tar.xz"
  unset DRY_RUN
  assert_success
  assert_output --partial "-f ${_d}/Dockerfile "
  refute_output --partial "Dockerfile.deploy"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _setup_deploy (S6d, #506) — the `setup.sh deploy` subcommand: preview +
# confirmation + _generate_deploy_bundle. Plus dispatch wiring in main().
# ════════════════════════════════════════════════════════════════════

_write_deploy_repo() {
  local _dir="${1}"
  mkdir -p "${_dir}/config/docker"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[environment]" "env_1 = ROS_DOMAIN_ID=42" \
    "[security]" "privileged = true" > "${_dir}/config/docker/setup.conf"
  cat > "${_dir}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
}

@test "_setup_deploy: --dry-run previews the launcher + prints the build plan (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  assert_output --partial "field launcher to be generated"
  assert_output --partial "--privileged"
  assert_output --partial "docker build --target runtime"
  assert_output --partial "docker save"
  assert_output --partial "-cJf"
  rm -rf "${_d}"
}

@test "_setup_deploy: refuses in a non-interactive shell without -y (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}"
  assert_failure
  assert_output --partial "non-interactive shell"
  rm -rf "${_d}"
}

@test "_setup_deploy: errors when the repo has no Dockerfile (#506)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/docker"
  printf '%s\n' "[deploy]" "gpu_mode = off" > "${_d}/config/docker/setup.conf"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --dry-run
  assert_failure
  assert_output --partial "no Dockerfile"
  rm -rf "${_d}"
}

@test "_setup_deploy: rejects an unknown flag (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --bogus
  assert_failure
  rm -rf "${_d}"
}

@test "_setup_deploy: --stage selects the target stage (#506)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" --stage devel --dry-run
  assert_success
  assert_output --partial "docker build --target devel"
  rm -rf "${_d}"
}

@test "main deploy routes to _setup_deploy (#506 dispatch)" {
  local _d; _d="$(mktemp -d)"
  _write_deploy_repo "${_d}"
  SETUP_DETECT_DRI_GROUPS="" run main deploy --base-path "${_d}" --dry-run
  assert_success
  assert_output --partial "deploy plan: stage=runtime"
  rm -rf "${_d}"
}
