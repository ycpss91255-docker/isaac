#!/usr/bin/env bats
#
# Unit guard for script/host_yaml.sh -- the shared host.yaml public_ip
# parser used by both the post-run hook (host) and
# runheadless-host-config.sh (container). #104: the old inline awk did
# not strip trailing inline comments, did not trim, and did not validate,
# so a realistic config (the template encourages inline comments)
# silently broke WebRTC.
#
# host_yaml.sh is baked into /smoke_test/ next to this spec by the
# devel-test stage (same pattern as runheadless-host-config.sh).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck source=/dev/null
  source "${BATS_TEST_DIRNAME}/host_yaml.sh"
  YAML="$(mktemp)"
}

teardown() {
  rm -f "${YAML}"
}

@test "host_yaml: clean quoted value" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "$status" -eq 0 ]
  [ "${output}" = "127.0.0.1" ]
}

@test "host_yaml: strips a trailing inline comment (#104)" {
  printf 'network:\n  public_ip: "127.0.0.1"  # host IP\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "$status" -eq 0 ]
  [ "${output}" = "127.0.0.1" ]
}

@test "host_yaml: trims whitespace on an unquoted value" {
  printf 'network:\n  public_ip:   127.0.0.1   \n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "${output}" = "127.0.0.1" ]
}

@test "host_yaml: accepts a hostname" {
  printf 'network:\n  public_ip: isaac-host.local\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "${output}" = "isaac-host.local" ]
}

@test "host_yaml: absent file -> empty, rc 0" {
  run --separate-stderr resolve_public_ip "/no/such/host.yaml"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "host_yaml: key absent -> empty, no warning" {
  printf 'network:\n  other: 1\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]
}

@test "host_yaml: key present but empty -> empty value + warning (#104)" {
  printf 'network:\n  public_ip: ""\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
  [[ "${stderr}" == *WARN* ]]
}

@test "host_yaml: invalid value (metacharacters) -> rc 1 + error (#104)" {
  printf 'network:\n  public_ip: "a;rm -rf /"\n' > "${YAML}"
  run --separate-stderr resolve_public_ip "${YAML}"
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *ERROR* ]]
}
