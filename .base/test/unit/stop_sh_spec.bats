#!/usr/bin/env bats
#
# Unit tests for script/docker/stop.sh argument handling and i18n log lines.
# Sandbox tree mirrors build_sh_spec.bats. A PATH-shimmed `docker` stub
# lets tests control `docker ps -a` output so the --all branch can be
# exercised without a real docker daemon.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/template/script/docker"

  cp /source/script/docker/_lib.sh  "${SANDBOX}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh  "${SANDBOX}/template/script/docker/i18n.sh"
  ln -s /source/script/docker/stop.sh "${SANDBOX}/stop.sh"

  # Seed .env so _load_env succeeds.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  DOCKER_PS_A_FILE="${TEMP_DIR}/docker_ps_a.out"
  export DOCKER_PS_A_FILE
  : > "${DOCKER_PS_A_FILE}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_A_FILE}"
  exit 0
fi
printf 'docker'
printf ' %q' "$@"
printf '\n'
EOS
  chmod +x "${BIN_DIR}/docker"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "stop.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/stop.sh" --help
  assert_success
  assert_output --partial "stop.sh"
}

@test "stop.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/stop.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "stop.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/stop.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "stop.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/stop.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

@test "stop.sh --lang requires a value" {
  run bash "${SANDBOX}/stop.sh" --lang
  assert_failure
}

@test "stop.sh --instance requires a value" {
  run bash "${SANDBOX}/stop.sh" --instance
  assert_failure
}

@test "stop.sh default stops default instance via docker compose down" {
  run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  assert_output --partial "down"
}

@test "stop.sh --instance foo stops named instance" {
  run bash "${SANDBOX}/stop.sh" --dry-run --instance foo
  assert_success
  assert_output --partial "mockuser-mockimg-foo"
}

@test "stop.sh --all with no instances prints English no-instances message" {
  # docker_ps_a.out is empty → mapfile builds a single-element array with
  # an empty string. Grep filters out lines not starting with the prefix,
  # leaving an empty list → stop.sh prints the no_instances message.
  : > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --all
  assert_success
  assert_output --partial "No instances found"
}

@test "stop.sh --all --lang zh-TW translates no-instances message" {
  : > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --all --lang zh-TW
  assert_success
  assert_output --partial "未找到"
}

@test "stop.sh --all --lang zh-CN translates no-instances message" {
  : > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --all --lang zh-CN
  assert_success
  assert_output --partial "未找到"
}

@test "stop.sh --all --lang ja translates no-instances message" {
  : > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --all --lang ja
  assert_success
  assert_output --partial "見つかりません"
}

@test "stop.sh --all with multiple projects tears down each one" {
  {
    echo "mockuser-mockimg"
    echo "mockuser-mockimg-foo"
    echo "mockuser-mockimg-bar"
  } > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --all --dry-run
  assert_success
  assert_output --partial "mockuser-mockimg-foo"
  assert_output --partial "mockuser-mockimg-bar"
}

# ── /lint/-layout _detect_lang (flat dir with _lib.sh + i18n.sh, #104) ─────

@test "stop.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/stop.sh "${_tmp}/stop.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/stop.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "stop.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/stop.sh "${_tmp}/stop.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/stop.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "stop.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/stop.sh "${_tmp}/stop.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/stop.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# -C / --chdir flag (issue docker_harness#53) — see build_sh_spec.
# ════════════════════════════════════════════════════════════════════

@test "stop.sh -C <dir> redirects FILE_PATH to <dir>" {
  local ALT="${TEMP_DIR}/alt"
  mkdir -p "${ALT}/template/script/docker"
  cp /source/script/docker/_lib.sh "${ALT}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/template/script/docker/i18n.sh"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg"
    echo "DOCKER_HUB_USER=altuser"
  } > "${ALT}/.env"

  run bash "${SANDBOX}/stop.sh" -C "${ALT}" --dry-run
  assert_success
  # docker compose down's project name comes from .env; alt path proves
  # FILE_PATH was redirected to ALT.
  assert_output --partial "altuser-altimg"
  refute_output --partial "mockuser-mockimg"
}

@test "stop.sh --chdir <dir> long form is equivalent to -C" {
  local ALT="${TEMP_DIR}/alt2"
  mkdir -p "${ALT}/template/script/docker"
  cp /source/script/docker/_lib.sh "${ALT}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/template/script/docker/i18n.sh"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg2"
    echo "DOCKER_HUB_USER=altuser2"
  } > "${ALT}/.env"

  run bash "${SANDBOX}/stop.sh" --chdir "${ALT}" --dry-run
  assert_success
  assert_output --partial "altuser2-altimg2"
}

@test "stop.sh -C without a value exits 2" {
  run bash "${SANDBOX}/stop.sh" -C
  assert_failure 2
  assert_output --partial "requires a value"
}

@test "stop.sh -C with a non-existent directory exits 2" {
  run bash "${SANDBOX}/stop.sh" -C /definitely/does/not/exist
  assert_failure 2
  assert_output --partial "not a directory"
}

@test "stop.sh -C is mentioned in usage help" {
  run bash "${SANDBOX}/stop.sh" --help
  assert_success
  assert_output --partial "-C"
  assert_output --partial "--chdir"
}
