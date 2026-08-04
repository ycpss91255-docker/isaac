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

# --- livestream.ports resolver (#231) -------------------------------------
# resolve_port <file> <signal|media|serve|api> echoes a validated numeric
# port, or nothing when the key is absent / present-but-empty (the "omit"
# case, which the caller maps to today's default behavior). A present but
# non-numeric / out-of-range value fails fast, mirroring resolve_public_ip.

@test "host_yaml: resolve_port reads a numeric livestream port" {
  printf 'livestream:\n  ports:\n    signal: 49200\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" signal
  [ "$status" -eq 0 ]
  [ "${output}" = "49200" ]
}

@test "host_yaml: resolve_port resolves each of signal/media/serve/api" {
  printf 'livestream:\n  ports:\n    signal: 49200\n    media: 47998\n    serve: 5273\n    api: 8111\n' \
    > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" media
  [ "${output}" = "47998" ]
  run --separate-stderr resolve_port "${YAML}" serve
  [ "${output}" = "5273" ]
  run --separate-stderr resolve_port "${YAML}" api
  [ "${output}" = "8111" ]
}

@test "host_yaml: resolve_port strips a trailing inline comment" {
  printf 'livestream:\n  ports:\n    signal: 49200  # override\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" signal
  [ "${output}" = "49200" ]
}

@test "host_yaml: resolve_port absent key -> empty, rc 0, no warning" {
  printf 'network:\n  public_ip: "127.0.0.1"\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" signal
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
  [ -z "${stderr}" ]
}

@test "host_yaml: resolve_port present-but-empty -> empty, rc 0 (omit => default)" {
  printf 'livestream:\n  ports:\n    media:\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" media
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "host_yaml: resolve_port absent file -> empty, rc 0" {
  run --separate-stderr resolve_port "/no/such/host.yaml" signal
  [ "$status" -eq 0 ]
  [ -z "${output}" ]
}

@test "host_yaml: resolve_port non-numeric -> rc 1 + error" {
  printf 'livestream:\n  ports:\n    signal: abc\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" signal
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *ERROR* ]]
}

@test "host_yaml: resolve_port out-of-range -> rc 1 + error" {
  printf 'livestream:\n  ports:\n    signal: 99999\n' > "${YAML}"
  run --separate-stderr resolve_port "${YAML}" signal
  [ "$status" -eq 1 ]
  [[ "${stderr}" == *ERROR* ]]
}
