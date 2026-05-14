#!/usr/bin/env bats
#
# Unit tests for script/docker/prune.sh argument handling and target
# selection. Mirrors the sandbox/mock strategy from build_sh_spec.bats:
# a sandbox tree with symlinked prune.sh + a PATH-shimmed `docker` stub
# that echoes its argv so tests can assert which prune subcommand was
# invoked with which flags.
#
# Refs issue #319.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/script/docker/lib"

  cp /source/script/docker/_lib.sh  "${SANDBOX}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh  "${SANDBOX}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${SANDBOX}/.base/script/docker/lib/"
  ln -s /source/script/docker/prune.sh "${SANDBOX}/prune.sh"

  # prune.sh doesn't load .env, but a seed file keeps the sandbox layout
  # uniform with stop_sh_spec / exec_sh_spec.
  : > "${SANDBOX}/.env"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
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

# ── usage / help in 4 languages ─────────────────────────────────────────────

@test "prune.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/prune.sh" --help
  assert_success
  assert_output --partial "prune.sh"
}

@test "prune.sh --lang zh-TW prints Traditional Chinese usage text" {
  run bash "${SANDBOX}/prune.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "prune.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/prune.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "prune.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/prune.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

# ── argument validation ─────────────────────────────────────────────────────

@test "prune.sh with no target exits 2 with hint" {
  run bash "${SANDBOX}/prune.sh"
  assert_failure 2
  assert_output --partial "No prune target selected"
}

@test "prune.sh --until without a value exits non-zero" {
  run bash "${SANDBOX}/prune.sh" --networks --until
  assert_failure
}

@test "prune.sh --lang without a value exits non-zero" {
  run bash "${SANDBOX}/prune.sh" --lang
  assert_failure
}

@test "prune.sh unknown flag exits 2 with error" {
  run bash "${SANDBOX}/prune.sh" --networks --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

# ── individual target flags + default until grace ──────────────────────────

@test "prune.sh --networks --dry-run prints network prune with default 10m filter" {
  run bash "${SANDBOX}/prune.sh" --networks --dry-run
  assert_success
  assert_output --partial "docker network prune -f --filter until=10m"
}

@test "prune.sh --images --dry-run prints image prune with default 24h filter" {
  run bash "${SANDBOX}/prune.sh" --images --dry-run
  assert_success
  assert_output --partial "docker image prune -f --filter until=24h"
}

@test "prune.sh --builder --dry-run prints builder prune with default 24h filter" {
  run bash "${SANDBOX}/prune.sh" --builder --dry-run
  assert_success
  assert_output --partial "docker builder prune -f --filter until=24h"
}

@test "prune.sh --volumes -y --dry-run prints volume prune (no filter)" {
  run bash "${SANDBOX}/prune.sh" --volumes -y --dry-run
  assert_success
  assert_output --partial "docker volume prune -f"
  # docker volume prune does not honor --filter until on most engines; we
  # intentionally omit it to avoid a "filter unsupported" warning.
  refute_output --partial "docker volume prune -f --filter"
}

# ── --all aggregator ───────────────────────────────────────────────────────

@test "prune.sh --all --dry-run prints network + image + builder (NOT volumes)" {
  run bash "${SANDBOX}/prune.sh" --all --dry-run
  assert_success
  assert_output --partial "docker network prune -f --filter until=10m"
  assert_output --partial "docker image prune -f --filter until=24h"
  assert_output --partial "docker builder prune -f --filter until=24h"
  refute_output --partial "docker volume prune"
}

# ── --until override applies across selected targets ───────────────────────

@test "prune.sh --networks --until 1h --dry-run overrides default 10m grace" {
  run bash "${SANDBOX}/prune.sh" --networks --until 1h --dry-run
  assert_success
  assert_output --partial "docker network prune -f --filter until=1h"
  refute_output --partial "until=10m"
}

@test "prune.sh --all --until 1h --dry-run overrides all default graces" {
  run bash "${SANDBOX}/prune.sh" --all --until 1h --dry-run
  assert_success
  assert_output --partial "docker network prune -f --filter until=1h"
  assert_output --partial "docker image prune -f --filter until=1h"
  assert_output --partial "docker builder prune -f --filter until=1h"
}

# ── --volumes confirmation prompt ──────────────────────────────────────────

@test "prune.sh --volumes without -y prompts and aborts on 'n'" {
  run bash -c "echo n | bash '${SANDBOX}/prune.sh' --volumes"
  assert_failure 1
  assert_output --partial "Aborted volume prune"
}

@test "prune.sh --volumes -y skips the prompt (dry-run for safety)" {
  run bash "${SANDBOX}/prune.sh" --volumes -y --dry-run
  assert_success
  refute_output --partial "Proceed?"
  refute_output --partial "About to run"
  assert_output --partial "docker volume prune"
}

# ── i18n on the "nothing selected" + "volume prompt" paths ────────────────

@test "prune.sh no target with --lang zh-TW prints Chinese hint" {
  run bash "${SANDBOX}/prune.sh" --lang zh-TW
  assert_failure 2
  assert_output --partial "未指定任何"
}

@test "prune.sh --volumes prompt with --lang zh-TW shows Chinese prompt" {
  run bash -c "echo n | bash '${SANDBOX}/prune.sh' --volumes --lang zh-TW"
  assert_failure 1
  assert_output --partial "永久刪除"
}

# ── -C / --chdir parity with other wrappers (no-op for prune but accepted) ─

@test "prune.sh -C <dir> --networks --dry-run is accepted (chdir parity)" {
  local ALT="${TEMP_DIR}/alt"
  mkdir -p "${ALT}/.base/script/docker/lib"
  cp /source/script/docker/_lib.sh "${ALT}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${ALT}/.base/script/docker/lib/"
  : > "${ALT}/.env"
  run bash "${SANDBOX}/prune.sh" -C "${ALT}" --networks --dry-run
  assert_success
  assert_output --partial "docker network prune"
}

@test "prune.sh -C without a value exits 2" {
  run bash "${SANDBOX}/prune.sh" -C
  assert_failure 2
  assert_output --partial "requires a value"
}

@test "prune.sh -C with a non-existent directory exits 2" {
  run bash "${SANDBOX}/prune.sh" -C /definitely/does/not/exist
  assert_failure 2
  assert_output --partial "not a directory"
}

# ── help mentions all 5 target flags + --until + -y ──────────────────────

@test "prune.sh -h mentions all flag families" {
  run bash "${SANDBOX}/prune.sh" --help
  assert_success
  assert_output --partial "--networks"
  assert_output --partial "--images"
  assert_output --partial "--volumes"
  assert_output --partial "--builder"
  assert_output --partial "--all"
  assert_output --partial "--until"
  assert_output --partial "--dry-run"
  assert_output --partial "-y"
}
