#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/wrapper/stop.sh argument handling and i18n log lines.
# Sandbox tree mirrors build_sh_spec.bats. A PATH-shimmed `docker` stub
# lets tests control `docker ps -a` output without a real docker daemon.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/dist/script/docker/lib"

  cp /source/dist/script/docker/lib/_lib.sh  "${SANDBOX}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh  "${SANDBOX}/.base/dist/script/docker/lib/i18n.sh"
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  ln -s /source/dist/script/docker/wrapper/stop.sh "${SANDBOX}/stop.sh"

  # Seed .env so _load_env succeeds.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env.generated"

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

@test "stop.sh stops the single project via docker compose down" {
  run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  assert_output --partial "down"
}

# ── --remove-orphans + COMPOSE_PROFILES='*' for profile-gated services ─

@test "stop.sh passes --remove-orphans to compose down (#341)" {
  # Profile-gated services (auto-emitted headless / gui / test stages)
  # are silently skipped by a bare `compose down`. --remove-orphans catches
  # containers from prior compose.yaml shapes the current file no longer
  # declares; COMPOSE_PROFILES='*' (env, not argv) activates every profile.
  run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  assert_output --partial "--remove-orphans"
}

# ── -v / --verbose lists project containers before down ────────────────

@test "stop.sh -v lists project containers before down (#345)" {
  # Seed the docker stub so _down_project's ps filter returns a non-empty list.
  printf 'mockuser-mockimg (running)\n' > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" -v --dry-run
  assert_success
  assert_output --partial "Tearing down containers in project"
  assert_output --partial "mockuser-mockimg (running)"
}

@test "stop.sh -v with no matching containers prints empty-project hint (#345)" {
  : > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" -v --dry-run
  assert_success
  assert_output --partial "No containers found for project"
  refute_output --partial "Tearing down containers in project"
}

@test "stop.sh without -v does NOT emit the verbose container listing (#345 default)" {
  printf 'mockuser-mockimg (running)\n' > "${DOCKER_PS_A_FILE}"
  run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  refute_output --partial "Tearing down containers in project"
  refute_output --partial "No containers found for project"
}

@test "stop.sh: an ambient VERBOSE does not reach the flag's behaviour (#895)" {
  # Every sibling flag in the wrapper family is declared `local` in the arg
  # parser; this one was assigned bare, which made the environment a second,
  # undeclared way to switch the listing on. The flag is the only input
  # surface: an inherited VERBOSE from some unrelated tool must not change
  # what the teardown prints.
  printf 'mockuser-mockimg (running)\n' > "${DOCKER_PS_A_FILE}"
  VERBOSE=true run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  refute_output --partial "Tearing down containers in project"
  refute_output --partial "No containers found for project"
}

# ── /lint/-layout _detect_lang (flat dir with _lib.sh + i18n.sh,) ─────

@test "stop.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/stop.sh "${_tmp}/stop.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/stop.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "stop.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/stop.sh "${_tmp}/stop.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/stop.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "stop.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/stop.sh "${_tmp}/stop.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
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
  mkdir -p "${ALT}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${ALT}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${ALT}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${ALT}/.base/dist/script/docker/lib/"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg"
    echo "DOCKER_HUB_USER=altuser"
  } > "${ALT}/.env.generated"

  run bash "${SANDBOX}/stop.sh" -C "${ALT}" --dry-run
  assert_success
  # docker compose down's project name comes from .env; alt path proves
  # FILE_PATH was redirected to ALT.
  assert_output --partial "altuser-altimg"
  refute_output --partial "mockuser-mockimg"
}

@test "stop.sh --chdir <dir> long form is equivalent to -C" {
  local ALT="${TEMP_DIR}/alt2"
  mkdir -p "${ALT}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${ALT}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${ALT}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${ALT}/.base/dist/script/docker/lib/"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg2"
    echo "DOCKER_HUB_USER=altuser2"
  } > "${ALT}/.env.generated"

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

# ════════════════════════════════════════════════════════════════════
# -v / --verbose / -vv / --very-verbose (BUILDKIT_PROGRESS=plain,)
# ════════════════════════════════════════════════════════════════════

@test "stop.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)" {
  run bash "${SANDBOX}/stop.sh" --help
  assert_success
  assert_output --partial "-v, --verbose"
  assert_output --partial "-vv, --very-verbose"
  assert_output --partial "BUILDKIT_PROGRESS=plain"
}

@test "stop.sh -v --dry-run is accepted and exits 0 (#311)" {
  run bash "${SANDBOX}/stop.sh" -v --dry-run
  assert_success
}

@test "stop.sh --verbose long form is accepted (#311)" {
  run bash "${SANDBOX}/stop.sh" --verbose --dry-run
  assert_success
}

@test "stop.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)" {
  run --separate-stderr bash "${SANDBOX}/stop.sh" -vv --dry-run
  assert_success
  # kcov instruments bash (set -x/PS4), so the wrapper's `-vv` trace
  # prefix `+ ` does not reach stderr under coverage; the real -vv
  # behaviour is covered by the normal (non-kcov) job. Skip the fragile
  # observation under kcov.
  [ "${COVERAGE:-0}" = 1 ] && skip "set -x trace not observable under kcov instrumentation (#613)"
  [[ "${stderr}" == *"+ "* ]]
}

# ════════════════════════════════════════════════════════════════════
# --prune flag (lightweight opt-in cleanup after down,)
# ════════════════════════════════════════════════════════════════════

@test "stop.sh --prune is mentioned in usage help (#319)" {
  run bash "${SANDBOX}/stop.sh" --help
  assert_success
  assert_output --partial "--prune"
  assert_output --partial "until=10m"
  assert_output --partial "until=24h"
}

@test "stop.sh --prune --dry-run prints down + network prune + image prune (#319)" {
  run bash "${SANDBOX}/stop.sh" --prune --dry-run
  assert_success
  assert_output --partial "down"
  assert_output --partial "docker network prune -f --filter until=10m"
  assert_output --partial "docker image prune -f --filter until=24h"
}

@test "stop.sh without --prune does NOT emit prune commands (#319)" {
  run bash "${SANDBOX}/stop.sh" --dry-run
  assert_success
  refute_output --partial "docker network prune"
  refute_output --partial "docker image prune"
}

@test "stop.sh --prune --dry-run runs prune after compose down (#319)" {
  run bash "${SANDBOX}/stop.sh" --prune --dry-run
  assert_success
  assert_output --partial "docker network prune -f --filter until=10m"
}

# ════════════════════════════════════════════════════════════════════
# Pre-stop hook abort
#
# stop.sh guards its teardown with `_run_pre_hook stop "$@" || exit $?`
# (after env load, before `_down_project` → `docker compose down`). A
# failing pre-hook must abort with the hook's rc AND must NOT run
# compose down. Locked here so a refactor that drops/reorders the
# `|| exit $?` cannot silently tear the project down after a pre-hook
# said 'do not proceed'. Real mode (the hook no-ops under --dry-run).
@test "stop.sh aborts on a failing pre-stop hook and skips compose down (#690)" {
  mkdir -p "${SANDBOX}/script/hooks/pre"
  cat > "${SANDBOX}/script/hooks/pre/stop.sh" <<'HOOK'
#!/usr/bin/env bash
echo "PRE_STOP_HOOK_FIRED"
exit 7
HOOK
  chmod +x "${SANDBOX}/script/hooks/pre/stop.sh"
  run -7 bash "${SANDBOX}/stop.sh"
  assert_output --partial "PRE_STOP_HOOK_FIRED"
  refute_output --partial "docker compose"
  refute_output --partial "down --remove-orphans"
}
