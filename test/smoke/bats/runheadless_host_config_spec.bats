#!/usr/bin/env bats
#
# Unit guard for script/runheadless-host-config.sh -- the single place
# that builds the Isaac Sim livestream Kit invocation (base #465/#440;
# replaces the kit_args that lived in the retired run_instance.sh).
#
# Exercised through RUNHEADLESS_DRYRUN=1, which prints the resolved
# command line instead of exec'ing the (absent) Kit launcher. The
# shared parser + per-host config are redirected via HOST_YAML_LIB /
# HOST_YAML_FILE so the script runs outside the container.
#
# Baked into /smoke_test/ next to host_yaml.sh by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WRAP="${BATS_TEST_DIRNAME}/runheadless-host-config.sh"
  export HOST_YAML_LIB="${BATS_TEST_DIRNAME}/host_yaml.sh"
  export RUNHEADLESS_DRYRUN=1
  export HOST_YAML_FILE="/no/such/host.yaml"   # default: no public_ip
  # Default-instance case: no port env set.
  unset ISAAC_SIGNAL_PORT ISAAC_MEDIA_PORT ISAAC_API_PORT
  YAML="$(mktemp)"
}

teardown() {
  rm -f "${YAML}"
}

@test "runheadless: first token is the Kit launcher" {
  assert_file_exists "${WRAP}"
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "${lines[0]}")" = "/isaac-sim/runheadless.sh" ]
}

@test "runheadless: always emits -v + quitOnSessionEnded=false" {
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qx -- '-v'
  echo "${output}" | grep -qx -- '--/app/livestream/nvcf/quitOnSessionEnded=false'
}

@test "runheadless: port env -> livestream port kit-args" {
  export ISAAC_SIGNAL_PORT=49200 ISAAC_MEDIA_PORT=48098 ISAAC_API_PORT=8012
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qx -- '--/app/livestream/port=49200'
  echo "${output}" | grep -qx -- '--/app/livestream/fixedHostPort=48098'
  echo "${output}" | grep -qx -- '--/exts/omni.services.transport.server.http/port=8012'
}

@test "runheadless: no port env -> no port kit-args (default instance)" {
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  ! echo "${output}" | grep -q -- '--/app/livestream/port='
  ! echo "${output}" | grep -q -- '--/app/livestream/fixedHostPort='
  ! echo "${output}" | grep -q -- 'transport.server.http/port='
}

@test "runheadless: host.yaml public_ip -> publicEndpointAddress" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${YAML}"
  export HOST_YAML_FILE="${YAML}"
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qx -- '--/app/livestream/publicEndpointAddress=127.0.0.1'
}

@test "runheadless: no host.yaml -> no publicEndpointAddress" {
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 0 ]
  ! echo "${output}" | grep -q -- 'publicEndpointAddress'
}

@test "runheadless: invalid public_ip -> rc 1 (shared parser rejects)" {
  printf 'network:\n  public_ip: "a;rm -rf /"\n' > "${YAML}"
  export HOST_YAML_FILE="${YAML}"
  run --separate-stderr "${WRAP}"
  [ "$status" -eq 1 ]
}

@test "runheadless: forwards extra args after the built kit-args" {
  run --separate-stderr "${WRAP}" /work/scene.usd --extra-flag
  [ "$status" -eq 0 ]
  echo "${output}" | grep -qx -- '/work/scene.usd'
  echo "${output}" | grep -qx -- '--extra-flag'
}
