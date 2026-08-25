#!/usr/bin/env bats
#
# Tests for the per-service compose emitter and its shared leaf-emitter
# sub-seams, extracted to top level from generate_compose_yaml.
#
# Before these emitters were nested closures inside
# generate_compose_yaml, only reachable by running the whole ~900-line
# function and grepping its YAML output. Hoisting them to top level lets
# each one be exercised in isolation: build the inputs, call the emitter,
# assert on the small fragment it returns.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
}

# ════════════════════════════════════════════════════════════════════
# _emit_gpu_deploy_block <gui> <count> <caps_yaml>
# ════════════════════════════════════════════════════════════════════

@test "_emit_gpu_deploy_block: gui=false emits nothing" {
  run _emit_gpu_deploy_block false 1 "[gpu]"
  assert_success
  assert_output ""
}

@test "_emit_gpu_deploy_block: gui=true emits deploy reservation with count + caps" {
  run _emit_gpu_deploy_block true 2 "[gpu, compute]"
  assert_line --partial "deploy:"
  assert_line --partial "count: 2"
  assert_line --partial "capabilities: [gpu, compute]"
  assert_line --partial "driver: nvidia"
}

# ════════════════════════════════════════════════════════════════════
# _emit_caps_block <cap_add> <cap_drop> <sec_opt>
# ════════════════════════════════════════════════════════════════════

@test "_emit_caps_block: all empty emits nothing" {
  run _emit_caps_block "" "" ""
  assert_success
  assert_output ""
}

@test "_emit_caps_block: cap_add list emits cap_add block" {
  run _emit_caps_block $'SYS_PTRACE\nNET_ADMIN' "" ""
  assert_line "    cap_add:"
  assert_line "      - SYS_PTRACE"
  assert_line "      - NET_ADMIN"
  refute_line "    cap_drop:"
}

@test "_emit_caps_block: cap_drop + security_opt emit their blocks" {
  run _emit_caps_block "" $'MKNOD' $'no-new-privileges:true'
  assert_line "    cap_drop:"
  assert_line "      - MKNOD"
  assert_line "    security_opt:"
  assert_line "      - no-new-privileges:true"
}

# ════════════════════════════════════════════════════════════════════
# _emit_env_file_block  (constant)
# ════════════════════════════════════════════════════════════════════

@test "_emit_env_file_block: emits the .env workload overlay block" {
  run _emit_env_file_block
  assert_line "    env_file:"
  assert_line "      - .env"
}

# ════════════════════════════════════════════════════════════════════
# Single-value line/block emitters
# ════════════════════════════════════════════════════════════════════

@test "_emit_target_arch_line: empty omits the line; set emits literal TARGET_ARCH ref" {
  run _emit_target_arch_line ""
  assert_output ""
  run _emit_target_arch_line "arm64"
  assert_output '        TARGETARCH: ${TARGET_ARCH}'
}

@test "_emit_build_network_line: empty omits; set emits network line" {
  run _emit_build_network_line ""
  assert_output ""
  run _emit_build_network_line "host"
  assert_output "      network: host"
}

@test "_emit_runtime_line: empty omits; set emits runtime line" {
  run _emit_runtime_line ""
  assert_output ""
  run _emit_runtime_line "nvidia"
  assert_output "    runtime: nvidia"
}

@test "_emit_restart_line: 'no' omits; plain value plain; on-failure:N quoted" {
  run _emit_restart_line "no"
  assert_output ""
  run _emit_restart_line "always"
  assert_output "    restart: always"
  run _emit_restart_line "on-failure:5"
  assert_output '    restart: "on-failure:5"'
}

@test "_emit_init_line: default/true emits init: true; false omits; garbage dropped (#792)" {
  run _emit_init_line
  assert_output "    init: true"
  run _emit_init_line "true"
  assert_output "    init: true"
  run _emit_init_line "false"
  assert_output ""
  run _emit_init_line "garbage"
  assert_output ""
}

@test "_emit_additional_contexts_block: empty omits; entries emit block" {
  run _emit_additional_contexts_block ""
  assert_output ""
  run _emit_additional_contexts_block $'base=../base\nlib=./lib'
  assert_line "      additional_contexts:"
  assert_line "        base: ../base"
  assert_line "        lib: ./lib"
}

@test "_emit_cgroup_rules_block: empty omits; entries emit quoted rules" {
  run _emit_cgroup_rules_block ""
  assert_output ""
  run _emit_cgroup_rules_block $'c 81:* rmw'
  assert_line "    device_cgroup_rules:"
  assert_line '      - "c 81:* rmw"'
}

@test "_emit_tmpfs_block: empty omits; entries emit tmpfs list" {
  run _emit_tmpfs_block ""
  assert_output ""
  run _emit_tmpfs_block $'/run\n/tmp:size=64m'
  assert_line "    tmpfs:"
  assert_line "      - /run"
  assert_line "      - /tmp:size=64m"
}

@test "_emit_group_add_block: gated on gui AND non-empty groups; emits quoted gids" {
  run _emit_group_add_block false "44 video"
  assert_output ""
  run _emit_group_add_block true ""
  assert_output ""
  run _emit_group_add_block true "44 video"
  assert_line "    group_add:"
  assert_line '      - "44"'
  assert_line '      - "video"'
}

@test "_emit_user_build_args: empty omits; entries emit KEY: \${KEY} pairs" {
  run _emit_user_build_args ""
  assert_output ""
  run _emit_user_build_args $'FOO=1\nBAR=two'
  assert_line '        FOO: ${FOO}'
  assert_line '        BAR: ${BAR}'
}

# ════════════════════════════════════════════════════════════════════
# Logging family (hoisted): now take the [logging] strings + repo
# name + base path explicitly instead of closing over them.
#   _logging_svc_kv <svc> <out_assoc> <global_str> <per_svc_str>
#   _emit_logging_block <svc> <global_str> <per_svc_str>
#   _logging_svc_local_path_mount <svc> <out> <name> <base> <global> <per_svc>
# ════════════════════════════════════════════════════════════════════

@test "_logging_svc_kv: seeds from global then overlays per-service (key-level merge)" {
  local -A _kv=()
  _logging_svc_kv test _kv $'driver=json-file\nmax_size=10m' $'test:driver=local'
  [ "${_kv[driver]}" = "local" ]      # per-svc overlay wins
  [ "${_kv[max_size]}" = "10m" ]      # global survives where not overridden
}

@test "_logging_svc_kv: a different service does not pick up another svc overlay" {
  local -A _kv=()
  _logging_svc_kv devel _kv $'driver=json-file' $'test:driver=local'
  [ "${_kv[driver]}" = "json-file" ]
}

@test "_emit_logging_block: empty global + per-svc emits nothing" {
  run _emit_logging_block devel "" ""
  assert_success
  assert_output ""
}

@test "_emit_logging_block: driver + rotation maps to compose options block" {
  run _emit_logging_block devel $'driver=json-file\nmax_size=10m\nmax_file=3\ncompress=true' ""
  assert_line "    logging:"
  assert_line "      driver: json-file"
  assert_line "      options:"
  assert_line '        max-size: "10m"'
  assert_line '        max-file: "3"'
  assert_line '        compress: "true"'
}

@test "_emit_logging_block: keys off the service name for per-svc overrides" {
  run _emit_logging_block test $'driver=json-file' $'test:max_size=5m'
  assert_line "      driver: json-file"
  assert_line '        max-size: "5m"'
}

@test "_logging_svc_local_path_mount: empty local_path yields empty mount" {
  local _m="sentinel"
  _logging_svc_local_path_mount devel _m myrepo /tmp/lpbase "" ""
  [ -z "${_m}" ]
}

@test "_logging_svc_local_path_mount: relative path resolves against base, mounts /var/log/<name>" {
  local _m=""
  _logging_svc_local_path_mount devel _m myrepo /tmp/lpbase $'local_path=logs' ""
  [ "${_m}" = "/tmp/lpbase/logs:/var/log/myrepo" ]
}

@test "_logging_svc_local_path_mount: absolute path passed verbatim (trailing slash stripped)" {
  local _m=""
  _logging_svc_local_path_mount devel _m myrepo /tmp/lpbase $'local_path=/srv/logs/' ""
  [ "${_m}" = "/srv/logs:/var/log/myrepo" ]
}

# ════════════════════════════════════════════════════════════════════
# _emit_stage_service <ctx> <resolved> <svc> <emit_stage> <has_overrides>
#
# The per-service emitter: consumes a resolved-stage value (the
# _dflags_eff record from _resolve_docker_flags) plus a shared static
# context, and emits a single service YAML fragment. Replaces the inline
# per-stage loop body of generate_compose_yaml. Tested here in isolation
# instead of grepping the whole ~900-line emitter's output.
# ════════════════════════════════════════════════════════════════════

# A fully-populated static context (every key the emitter reads).
_mk_ctx() {
  local -n _c="$1"
  _c=(
    [name]=myrepo [setup_base]=/tmp/ess [additional_contexts]=""
    [build_network]="" [target_arch]="" [user_build_args]=""
    [devices]="" [cgroup_rule]="" [tmpfs]="" [shm_size]=""
    [dri_groups]="" [logging_global]="" [logging_per_svc]=""
    [net_mode]=host [ipc_mode]=host [pid_mode]=private
    [any_prop_device]=false
  )
}

@test "_emit_stage_service: zero-diff stage emits the extends:devel shape" {
  local -A _ctx=(); _mk_ctx _ctx
  local -A _res=()
  run _emit_stage_service _ctx _res test devel-test 0
  assert_success
  assert_line "  test:"
  assert_line "    extends:"
  assert_line "      service: devel"
  assert_line "      target: devel-test"
  assert_line '    image: ${DOCKER_HUB_USER:-local}/myrepo:test'
  assert_line "    stdin_open: false"
  assert_line "    profiles:"
  assert_line "      - test"
}

@test "_emit_stage_service: zero-diff stage with per-svc logging override emits logging block" {
  local -A _ctx=(); _mk_ctx _ctx
  _ctx[logging_per_svc]=$'test:driver=local'
  local -A _res=()
  run _emit_stage_service _ctx _res test devel-test 0
  assert_line "    extends:"
  assert_line "      driver: local"
}

@test "_emit_stage_service: stage with overrides emits a standalone block (no extends)" {
  local -A _ctx=(); _mk_ctx _ctx
  local -A _res=(
    [gui]=false [gpu]=false [gpu_count]=0 [gpu_caps]=gpu [runtime]=""
    [net_mode]=host [ipc_mode]=private [pid_mode]=private [net_name]=""
    [privileged]=true [volumes]="./hl:/data" [environment]="HEADLESS=1"
    [ports]="" [cap_add]="" [cap_drop]="" [security_opt]=""
  )
  run _emit_stage_service _ctx _res headless headless 1
  assert_success
  refute_line "    extends:"
  assert_line "  headless:"
  assert_line "      target: headless"
  assert_line "    privileged: true"
  assert_line "    ipc: private"
  assert_line '      - "HEADLESS=1"'
  assert_line "      - ./hl:/data"
  assert_line "    profiles:"
  assert_line "      - headless"
}

@test "_emit_stage_service: override stage GPU resolution emits deploy reservation" {
  local -A _ctx=(); _mk_ctx _ctx
  local -A _res=(
    [gui]=false [gpu]=true [gpu_count]=2 [gpu_caps]="gpu compute" [runtime]=""
    [net_mode]=host [ipc_mode]=host [pid_mode]=private [net_name]=""
    [privileged]="" [volumes]="" [environment]="" [ports]=""
    [cap_add]="" [cap_drop]="" [security_opt]=""
  )
  run _emit_stage_service _ctx _res sim sim 1
  assert_line "    deploy:"
  assert_line "              count: 2"
  assert_line "              capabilities: [gpu, compute]"
}

# ════════════════════════════════════════════════════════════════════
# _yaml_dq <value> <out>
# ════════════════════════════════════════════════════════════════════

@test "_yaml_dq wraps a value as a double-quoted scalar, escaping \\ then \" (#698)" {
  # The compose environment: sink routes each entry through _yaml_dq so a
  # value with YAML-structural chars survives the parse as one string. The
  # escape order is backslash first, then double-quote (so an embedded \"
  # is not double-escaped).
  local _out=""
  _yaml_dq 'MSG=a: b' _out
  [ "${_out}" = '"MSG=a: b"' ]
  _yaml_dq 'Q=a"b\c' _out
  [ "${_out}" = '"Q=a\"b\\c"' ]
  _yaml_dq 'GLOB=*' _out
  [ "${_out}" = '"GLOB=*"' ]
}
