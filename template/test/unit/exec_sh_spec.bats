#!/usr/bin/env bats
#
# Unit tests for script/docker/exec.sh argument handling, i18n log lines,
# and the "container not running" guard. Mirrors the sandbox/mock strategy
# from build_sh_spec.bats / run_sh_spec.bats: a sandbox tree with symlinked
# exec.sh, real _lib.sh / i18n.sh, and a PATH-shimmed `docker` stub whose
# `docker ps` output is controlled by ${DOCKER_PS_FILE} so individual tests
# can toggle "container running" state.

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
  ln -s /source/script/docker/exec.sh "${SANDBOX}/exec.sh"

  # Seed .env so _load_env / _compute_project_name succeed without bootstrap.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  DOCKER_PS_FILE="${TEMP_DIR}/docker_ps.out"
  export DOCKER_PS_FILE
  : > "${DOCKER_PS_FILE}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
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

@test "exec.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  assert_output --partial "exec.sh"
}

@test "exec.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "exec.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "exec.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

@test "exec.sh --lang requires a value" {
  run bash "${SANDBOX}/exec.sh" --lang
  assert_failure
}

@test "exec.sh --target requires a value" {
  run bash "${SANDBOX}/exec.sh" --target
  assert_failure
}

@test "exec.sh --instance requires a value" {
  run bash "${SANDBOX}/exec.sh" --instance
  assert_failure
}

@test "exec.sh fails when container not running (default English)" {
  run bash "${SANDBOX}/exec.sh"
  assert_failure
  assert_output --partial "is not running"
}

@test "exec.sh --lang zh-TW prints Chinese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW
  assert_failure
  assert_output --partial "未在執行中"
}

@test "exec.sh --lang zh-CN prints Simplified Chinese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang zh-CN
  assert_failure
  assert_output --partial "未在运行中"
}

@test "exec.sh --lang ja prints Japanese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang ja
  assert_failure
  assert_output --partial "実行されていません"
}

@test "exec.sh prints instance-specific start hint with --instance" {
  run bash "${SANDBOX}/exec.sh" --instance foo
  assert_failure
  assert_output --partial "./run.sh --instance foo"
}

@test "exec.sh --lang zh-TW instance-specific hint translates" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW --instance foo
  assert_failure
  assert_output --partial "請先以"
  assert_output --partial "./run.sh --instance foo"
}

@test "exec.sh --dry-run bypasses container-running check" {
  # No container running, but --dry-run should short-circuit the guard
  # and fall through to _compose_project exec (which the docker stub logs).
  run bash "${SANDBOX}/exec.sh" --dry-run
  assert_success
}

@test "exec.sh runs docker compose exec when container is running" {
  echo "mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run
  assert_success
  assert_output --partial "exec"
}

# ── /lint/-layout _detect_lang (flat dir with _lib.sh + i18n.sh, #104) ─────

@test "exec.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/exec.sh "${_tmp}/exec.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "exec.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/exec.sh "${_tmp}/exec.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "exec.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/exec.sh "${_tmp}/exec.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}
