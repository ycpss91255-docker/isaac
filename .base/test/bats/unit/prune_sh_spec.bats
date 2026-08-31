#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/wrapper/prune.sh argument handling and target
# selection. Mirrors the sandbox/mock strategy from build_sh_spec.bats:
# a sandbox tree with symlinked prune.sh + a PATH-shimmed `docker` stub
# that echoes its argv so tests can assert which prune subcommand was
# invoked with which flags.
#
# Refs

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
  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  ln -s /source/dist/script/docker/wrapper/prune.sh "${SANDBOX}/prune.sh"

  # prune.sh doesn't load .env, but a seed file keeps the sandbox layout
  # uniform with stop_sh_spec / exec_sh_spec.
  : > "${SANDBOX}/.env.generated"

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

@test "prune.sh --volumes without -y on closed stdin aborts cleanly, no set-e crash (#702, #700)" {
  # EOF path: with no -y and a closed stdin, `read` returns non-zero on
  # EOF. Pre-fix, the bare `read _reply` under `set -e` aborted the
  # script at the read line BEFORE the case could map empty->abort, so a
  # piped/CI invocation died with NO 'Aborted volume prune' diagnostic.
  # Post-fix, EOF maps to an empty reply which the default case treats as
  # an explicit (safe) abort.
  run bash "${SANDBOX}/prune.sh" --volumes </dev/null
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
  mkdir -p "${ALT}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${ALT}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${ALT}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${ALT}/.base/dist/script/docker/lib/"
  : > "${ALT}/.env.generated"
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

# ── --worktree-orphans: surgical removal of removed-worktree images ──
#
# Strategy mirrors build_sh_prune_spec.bats: a per-test docker stub keyed
# on env vars overrides the default arg-echo stub. The orphan flow uses
# 3 docker verbs:
#   docker images --format '...'  → emit DOCKER_IMAGES_OUTPUT (newline list)
#   docker rmi <tag>              → append <tag> to DOCKER_RMI_LOG
#   anything else                 → silent exit 0
# Per-test setup also configures DOCKER_HUB_USER + WS_PATH in .env and
# constructs `<workspace>/worktree/<name>/` directories so the worktree-
# existence check has something real to consult.

# _orphans_setup_stub installs a docker stub honouring DOCKER_IMAGES_OUTPUT
# and DOCKER_RMI_LOG, and primes .env with WS_PATH=$1, DOCKER_HUB_USER=$2.
_orphans_setup_stub() {
  local _ws="${1:-/nonexistent}"
  local _owner="${2:-tester}"
  DOCKER_RMI_LOG="${TEMP_DIR}/rmi.log"
  export DOCKER_RMI_LOG
  : > "${DOCKER_RMI_LOG}"
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "images" ]]; then
  if [[ -n "${DOCKER_IMAGES_OUTPUT:-}" ]]; then
    printf '%s\n' "${DOCKER_IMAGES_OUTPUT}"
  fi
  exit 0
fi
if [[ "${1:-}" == "rmi" ]]; then
  shift
  printf '%s\n' "$*" >> "${DOCKER_RMI_LOG}"
  exit 0
fi
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"
  {
    printf 'WS_PATH=%s\n' "${_ws}"
    printf 'DOCKER_HUB_USER=%s\n' "${_owner}"
  } > "${SANDBOX}/.env.generated"
}

@test "prune.sh --worktree-orphans on empty image list → no rmi" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  unset DOCKER_IMAGES_OUTPUT
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  assert_output --partial "No worktree orphans found."
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans: owner match + missing worktree → rmi" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "tester/repo-99:devel"
}

@test "prune.sh --worktree-orphans: owner match + worktree exists → keep" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree/repo-99"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  assert_output --partial "No worktree orphans found."
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans: main-checkout pattern (no hyphen) → keep" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/ros1_bridge:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  assert_output --partial "No worktree orphans found."
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans: bare-name image (no owner prefix) → SAFETY skip" {
  # Safety gate #1: cannot prove ownership, refuse to delete.
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="repo-99:runtime"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  assert_output --partial "Skipping 1 bare-name image"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans: other-owner image → SAFETY skip" {
  # Safety gate #2: other user's image, not ours to delete.
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" bob
  export DOCKER_IMAGES_OUTPUT="alice/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  assert_output --partial "Skipping 1 image(s) owned by another user"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans --repo <name> filter" {
  # Only ros1_bridge-* should be considered; foo-99 is ignored even though
  # its worktree is missing.
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/ros1_bridge-59:test
tester/foo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans --repo ros1_bridge -y
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "tester/ros1_bridge-59:test"
  refute_output --partial "tester/foo-99:devel"
}

@test "prune.sh --worktree-orphans --dry-run prints plan, no real rmi" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  # --separate-stderr: the `[dry-run] docker rmi ...` plan is printed to
  # stdout by _dry_run_cmd, while scan progress (_log_info) goes to stderr.
  # Asserting the merged stream let a stderr line interleave between the
  # plan's `[dry-run]` and ` docker rmi` chunks under the parallel suite
  # Isolating stdout makes the assertion cross-stream-independent.
  run --separate-stderr bash "${SANDBOX}/prune.sh" --worktree-orphans --dry-run
  assert_success
  assert_output --partial "[dry-run] docker rmi"
  assert_output --partial "tester/repo-99:devel"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans -y skips confirmation" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  # No stdin piping needed — -y bypasses the prompt and rmi fires.
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "tester/repo-99:devel"
}

@test "prune.sh --worktree-orphans without --workspace + empty .env → exit 2" {
  # No WS_PATH in .env, no --workspace flag → must error out.
  : > "${SANDBOX}/.env.generated"
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans -y
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "cannot resolve workspace"
}

@test "prune.sh --worktree-orphans --workspace <flag> wins over .env WS_PATH" {
  local _env_ws="${TEMP_DIR}/env_ws"
  local _flag_ws="${TEMP_DIR}/flag_ws"
  mkdir -p "${_env_ws}/worktree/repo-99"   # would KEEP if env-ws used
  mkdir -p "${_flag_ws}/worktree"          # MISSING repo-99 → orphan if flag-ws used
  _orphans_setup_stub "${_env_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans --workspace "${_flag_ws}" -y
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "tester/repo-99:devel"
}

@test "prune.sh --worktree-orphans --owner <flag> wins over .env DOCKER_HUB_USER" {
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" bob          # .env says bob
  export DOCKER_IMAGES_OUTPUT="alice/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans --owner alice -y
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "alice/repo-99:devel"
}

# ── --worktree-orphans interactive confirmation gate ────────────────
#
# Every test above passes -y or --dry-run, so the interactive prompt
# branch (prune.sh _run_worktree_orphans_prune) was never exercised:
# the confirm-'y' delete path, the abort-on-non-'y' refuse path, and
# the closed-stdin/EOF behaviour under `set -e`. Mirrors the --volumes
# prompt set (abort-on-'n' + closed-stdin EOF + -y-skip) for the MORE
# destructive image removal. The volumes prompt carries its own EOF
# spec at the top of this file; both bare-read sites are guarded with
# `read -r _reply || _reply=""`.

@test "prune.sh --worktree-orphans without -y confirms 'y' and removes the image (#699)" {
  # Confirm path: a piped 'y' must reach the destructive docker rmi loop.
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash -c "echo y | bash '${SANDBOX}/prune.sh' --worktree-orphans"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "tester/repo-99:devel"
}

@test "prune.sh --worktree-orphans without -y aborts on 'n' and removes nothing (#699)" {
  # Abort path: a non-'y' reply must refuse, emit 'aborted', and skip rmi.
  # _run_worktree_orphans_prune returns 1; main runs it unguarded under
  # set -e, so the whole run exits 1 (intended: a user abort is a failure).
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash -c "echo n | bash '${SANDBOX}/prune.sh' --worktree-orphans"
  assert_failure 1
  assert_output --partial "aborted by user"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --worktree-orphans without -y on closed stdin aborts cleanly, no set-e crash (#699)" {
  # EOF path: with no -y and a closed stdin, `read` returns non-zero on
  # EOF. Pre-fix, `set -e` aborted the script at the `read` line BEFORE
  # the case could map empty->abort, so a piped/CI invocation died with
  # exit 1 and NO 'aborted' diagnostic. Post-fix, EOF maps to an empty
  # reply which the case treats as an explicit abort with a clear message.
  local _ws="${TEMP_DIR}/ws"
  mkdir -p "${_ws}/worktree"
  _orphans_setup_stub "${_ws}" tester
  export DOCKER_IMAGES_OUTPUT="tester/repo-99:devel"
  run bash "${SANDBOX}/prune.sh" --worktree-orphans </dev/null
  assert_failure 1
  assert_output --partial "aborted by user"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "prune.sh --help mentions --worktree-orphans (#388)" {
  run bash "${SANDBOX}/prune.sh" --help
  assert_success
  assert_output --partial "--worktree-orphans"
  assert_output --partial "--workspace"
  assert_output --partial "--owner"
  assert_output --partial "--repo"
}

# ════════════════════════════════════════════════════════════════════
# Pre-prune hook abort
#
# prune.sh guards its prune work with `_run_pre_hook prune "$@" || exit $?`
# (after arg parsing + target selection, before any `docker ... prune`).
# A failing pre-hook must abort with the hook's rc AND must NOT run any
# docker prune. Locked here so a refactor that drops/reorders the
# `|| exit $?` cannot silently delete resources after a pre-hook said
# 'do not proceed'. Real mode + a target selected (the hook no-ops under
# --dry-run, and a no-target invocation exits 2 before the hook).
@test "prune.sh aborts on a failing pre-prune hook and skips docker prune (#690)" {
  mkdir -p "${SANDBOX}/script/hooks/pre"
  cat > "${SANDBOX}/script/hooks/pre/prune.sh" <<'HOOK'
#!/usr/bin/env bash
echo "PRE_PRUNE_HOOK_FIRED"
exit 7
HOOK
  chmod +x "${SANDBOX}/script/hooks/pre/prune.sh"
  run -7 bash "${SANDBOX}/prune.sh" --networks
  assert_output --partial "PRE_PRUNE_HOOK_FIRED"
  refute_output --partial "docker network prune"
}
