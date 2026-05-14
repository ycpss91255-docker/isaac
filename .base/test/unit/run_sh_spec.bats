#!/usr/bin/env bats
#
# Unit tests for script/docker/run.sh argument handling and control flow.
# See build_sh_spec.bats for the sandbox/mock strategy — this file mirrors it
# and focuses on run.sh-specific branches: --detach, --instance, TARGET
# routing (devel vs non-devel), already-running guard, and bootstrap/drift.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/script/docker/lib" \
           "${SANDBOX}/config/docker"

  cp /source/script/docker/_lib.sh  "${SANDBOX}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh  "${SANDBOX}/.base/script/docker/i18n.sh"
  # _lib.sh post-#284 is an umbrella that sources lib/*.sh sub-libs.
  cp /source/script/docker/lib/*.sh "${SANDBOX}/.base/script/docker/lib/"
  # Symlink (not copy) so kcov attributes coverage to /source/script/docker/run.sh.
  ln -s /source/script/docker/run.sh "${SANDBOX}/run.sh"

  MOCK_SETUP_LOG="${TEMP_DIR}/setup.log"
  export MOCK_SETUP_LOG

  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
# Mock setup.sh (subprocess-only after #49 Phase B-1):
#   - `check-drift` subcommand → exit 0 (no drift baseline)
#   - apply (default / explicit / legacy flag-only) → write .env + compose
set -euo pipefail
_subcmd="apply"
case "${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) _base="$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "${_subcmd}" in
  check-drift) exit 0 ;;
  apply)
    printf 'setup.sh invoked --base-path %s\n' "${_base}" >> "${MOCK_SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "${_base}/.env"
    echo "# mock compose" > "${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  # docker stub: `docker ps` reads from DOCKER_PS_FILE so individual tests
  # can simulate a running container; everything else is a no-op.
  DOCKER_PS_FILE="${TEMP_DIR}/docker_ps.out"
  export DOCKER_PS_FILE
  : > "${DOCKER_PS_FILE}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
  exit 0
fi
# image inspect: drives the #216 soft guard. Env var
# DOCKER_IMAGE_PRESENT=true makes the inspect succeed (image present
# locally), anything else makes it fail (image missing → guard fires).
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  if [[ "${DOCKER_IMAGE_PRESENT:-false}" == "true" ]]; then
    echo "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    exit 0
  fi
  printf 'Error: No such image\n' >&2
  exit 1
fi
printf 'docker'
printf ' %q' "$@"
printf '\n'
EOS
  chmod +x "${BIN_DIR}/docker"

  # build.sh stub: drives the #216 --build opt-in path. Logs every
  # invocation to BUILD_SH_LOG so tests can assert the call (or its
  # absence). Exits 0 to mimic a successful build.
  BUILD_SH_LOG="${TEMP_DIR}/build.log"
  export BUILD_SH_LOG
  : > "${BUILD_SH_LOG}"
  cat > "${SANDBOX}/build.sh" <<'EOS'
#!/usr/bin/env bash
printf 'build.sh invoked: %s\n' "$*" >> "${BUILD_SH_LOG}"
exit 0
EOS
  chmod +x "${SANDBOX}/build.sh"

  cat > "${BIN_DIR}/xhost" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${BIN_DIR}/xhost"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "run.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/run.sh" --help
  assert_success
  assert_output --partial "run.sh"
}

@test "run.sh --setup forces setup.sh to run" {
  run bash "${SANDBOX}/run.sh" --setup --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh -s short flag triggers setup.sh" {
  run bash "${SANDBOX}/run.sh" -s --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when .env is missing" {
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${SANDBOX}/.env" ]
}

@test "run.sh auto-regens .env / compose.yaml when drift detected" {
  # Regression (v0.9.5): mirror of the build.sh drift auto-regen test.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
_subcmd="apply"
case "${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) _base="$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "${_subcmd}" in
  check-drift)
    printf '[setup] drift detected: stub\n' >&2
    exit 1
    ;;
  apply)
    printf 'setup.sh invoked --base-path %s\n' "${_base}" >> "${MOCK_SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "${_base}/.env"
    echo "# mock compose" > "${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "regenerating"
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh skips setup.sh when .env AND setup.conf AND compose.yaml exist (drift-check path)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  refute_output --partial "First run"
  assert [ ! -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when setup.conf is missing (even if .env exists)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  rm -f "${SANDBOX}/config/docker/setup.conf"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "run.sh bootstraps setup.sh when compose.yaml is missing (fresh clone)" {
  # Regression (v0.9.2): compose.yaml is gitignored since v0.9.0, so
  # a fresh clone lands here with .env / setup.conf present but no
  # compose.yaml. That case must also bootstrap.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  rm -f "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ -f "${SANDBOX}/compose.yaml" ]
}

@test "run.sh bootstrap calls setup.sh directly, not setup_tui.sh" {
  # Regression (v0.9.2): bootstrap used to launch setup_tui.sh on a
  # TTY; user cancelling left the repo with no .env. Bootstrap must
  # always be non-interactive.
  cat > "${SANDBOX}/setup_tui.sh" <<'EOS'
#!/usr/bin/env bash
echo "TUI_INVOKED" >> "${MOCK_SETUP_LOG}.tui"
exit 0
EOS
  chmod +x "${SANDBOX}/setup_tui.sh"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ ! -f "${MOCK_SETUP_LOG}.tui" ]
}

@test "run.sh fails with clear error if setup.sh produced no .env" {
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_failure
  assert_output --partial ".env"
  assert_output --partial "--setup"
}

@test "run.sh --detach routes to 'compose up -d'" {
  run bash "${SANDBOX}/run.sh" --detach --dry-run
  assert_success
  assert_output --partial "up"
  assert_output --partial "-d"
}

@test "run.sh devel target routes to 'compose up -d' + 'compose exec'" {
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "exec"
}

@test "run.sh non-devel target routes to 'compose run --rm'" {
  # -t is now the explicit target flag; positional would be treated as CMD.
  run bash "${SANDBOX}/run.sh" --dry-run -t test
  assert_success
  assert_output --partial "run"
  assert_output --partial "--rm"
}

@test "run.sh positional args after options become CMD passthrough (devel)" {
  # New semantics: positionals = cmd, default target = devel.
  # Expect exec of `ls /tmp` inside the devel service.
  run bash "${SANDBOX}/run.sh" --dry-run ls /tmp
  assert_success
  assert_output --partial "exec"
  assert_output --partial "ls /tmp"
}

@test "run.sh -t runtime with CMD overrides Dockerfile runtime CMD" {
  run bash "${SANDBOX}/run.sh" --dry-run -t runtime bash
  assert_success
  assert_output --partial "run"
  assert_output --partial "--rm"
  assert_output --partial "runtime"
  assert_output --partial "bash"
}

@test "run.sh -d combined with CMD is rejected with exit 2" {
  run bash "${SANDBOX}/run.sh" --dry-run -d ls /tmp
  assert_failure
  [ "$status" -eq 2 ]
  assert_output --partial "does not accept a CMD"
  assert_output --partial "./exec.sh"
}

@test "run.sh --instance is appended to project/container name" {
  run bash "${SANDBOX}/run.sh" --dry-run --instance foo
  assert_success
  assert_output --partial "mockuser-mockimg-foo"
}

@test "run.sh refuses to start when container already running (devel + no -d)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  # Simulate a running container matching CONTAINER_NAME=${USER_NAME}-mockimg
  # (#322: container_name now includes USER_NAME prefix to disambiguate
  # per-OS-user on shared hosts).
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"

  # Real mode (no --dry-run) triggers the guard; DRY_RUN=true bypasses it.
  run bash "${SANDBOX}/run.sh"
  assert_failure
  assert_output --partial "already running"
}

@test "run.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/run.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "run.sh --lang requires a value" {
  run bash "${SANDBOX}/run.sh" --lang
  assert_failure
}

@test "run.sh --instance requires a value" {
  run bash "${SANDBOX}/run.sh" --instance
  assert_failure
}

@test "run.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/run.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "run.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/run.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

@test "run.sh uses xhost +SI:localuser under Wayland session" {
  run env XDG_SESSION_TYPE=wayland bash "${SANDBOX}/run.sh" --dry-run
  assert_success
}

# ── /lint/-layout _detect_lang (flat dir with _lib.sh + i18n.sh, #104) ─────

@test "run.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "run.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "run.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/run.sh "${_tmp}/run.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/run.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}

# ── i18n log lines (bootstrap / drift / err_no_env / already-running) ──────
# Exercises _msg() across all four languages on the log lines run.sh emits
# itself. Usage-text coverage is above.

@test "run.sh --lang zh-TW prints Chinese bootstrap log" {
  run bash "${SANDBOX}/run.sh" --lang zh-TW --dry-run
  assert_success
  assert_output --partial "首次執行"
}

@test "run.sh --lang zh-CN prints Simplified Chinese bootstrap log" {
  run bash "${SANDBOX}/run.sh" --lang zh-CN --dry-run
  assert_success
  assert_output --partial "首次运行"
}

@test "run.sh --lang ja prints Japanese bootstrap log" {
  run bash "${SANDBOX}/run.sh" --lang ja --dry-run
  assert_success
  assert_output --partial "初回実行"
}

@test "run.sh default bootstrap log is English" {
  run bash "${SANDBOX}/run.sh" --dry-run
  assert_success
  assert_output --partial "First run"
}

@test "run.sh --lang zh-TW prints Chinese already-running error" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  # #322: container_name now includes USER_NAME prefix.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/run.sh" --lang zh-TW
  assert_failure
  assert_output --partial "已在執行中"
}

@test "run.sh --lang ja prints Japanese already-running error" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  # #322: container_name now includes USER_NAME prefix.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/run.sh" --lang ja
  assert_failure
  assert_output --partial "すでに実行中"
}

# ════════════════════════════════════════════════════════════════════
# #216 — soft guard for the auto-build path that bypasses lint+smoke
# ════════════════════════════════════════════════════════════════════

@test "run.sh: image present → no auto-build INFO printed" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=true
  run bash -c "exec 2>&1; bash '${SANDBOX}/run.sh' --detach"
  assert_success
  refute_output --partial "Compose will auto-build"
  refute_output --partial "skips ShellCheck"
}

@test "run.sh: image absent + TTY → INFO message printed before compose up" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=false
  # Force TTY check to true via env var so the test does not need a
  # real PTY (run.sh respects RUN_FORCE_TTY=1 for testing).
  export RUN_FORCE_TTY=1
  run bash -c "exec 2>&1; bash '${SANDBOX}/run.sh' --detach"
  assert_success
  assert_output --partial "not found locally"
  assert_output --partial "auto-build"
  assert_output --partial "ShellCheck"
}

@test "run.sh: image absent + no TTY → silent (no INFO message)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=false
  unset RUN_FORCE_TTY
  # Without RUN_FORCE_TTY and with bats's piped stderr, the TTY check
  # naturally returns false → no INFO.
  run bash -c "exec 2>&1; bash '${SANDBOX}/run.sh' --detach"
  assert_success
  refute_output --partial "Compose will auto-build"
}

@test "run.sh: image-inspect uses per-target tag (-t headless inspects :headless)" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  # docker stub logs every invocation to a temp file so we can assert
  # the inspect arg.
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
{
  printf 'docker'
  printf ' %q' "$@"
  printf '\n'
} >> "${TEMP_DIR}/docker.log"
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
  exit 0
fi
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  exit 1
fi
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"
  export RUN_FORCE_TTY=1
  run bash "${SANDBOX}/run.sh" --detach -t headless
  # Image inspect must target ${IMAGE_NAME}:headless, not :devel.
  run grep -F "image inspect" "${TEMP_DIR}/docker.log"
  assert_output --partial ":headless"
}

@test "run.sh --build: invokes ./build.sh test before compose up" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=true
  run bash "${SANDBOX}/run.sh" --build --detach
  assert_success
  # build.sh was called with `test` so lint + smoke runs.
  run grep -F "build.sh invoked" "${BUILD_SH_LOG}"
  assert_output --partial "test"
}

@test "run.sh --build: skips when image present too (explicit opt-in always builds)" {
  # User who passes --build wants a fresh lint+smoke pass even if the
  # image is cached. Defensive: cached image may be stale wrt source.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=true
  run bash "${SANDBOX}/run.sh" --build --detach
  assert_success
  run wc -l < "${BUILD_SH_LOG}"
  # exactly one build.sh invocation
  [[ "${output}" -eq 1 ]] || { echo "expected 1 build.sh call, got ${output}"; return 1; }
}

@test "run.sh: no --build, image absent → does NOT invoke build.sh (Option 4 rejected)" {
  # Default behavior is INFO-only; build.sh is opt-in only.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"
  export DOCKER_IMAGE_PRESENT=false
  export RUN_FORCE_TTY=1
  run bash "${SANDBOX}/run.sh" --detach
  assert_success
  # build.sh log should be empty.
  run cat "${BUILD_SH_LOG}"
  assert_output ""
}

@test "run.sh --build: runs after check-drift (build sees regenerated state)" {
  # Order matters: check-drift must regenerate .env / compose.yaml
  # BEFORE build.sh invocation, otherwise build runs against stale
  # compose. Mock setup.sh logs check-drift and apply calls; build.sh
  # logs its own. Assert chronological order.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock" > "${SANDBOX}/compose.yaml"
  echo "# stub" > "${SANDBOX}/config/docker/setup.conf"

  # Replace mock setup.sh with one that logs to a shared timeline.
  EVENT_LOG="${TEMP_DIR}/timeline.log"
  export EVENT_LOG
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  check-drift) printf '%s\n' "setup-check-drift" >> "${EVENT_LOG}"; exit 0 ;;
  apply)       printf '%s\n' "setup-apply"       >> "${EVENT_LOG}"; exit 0 ;;
esac
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"

  cat > "${SANDBOX}/build.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "build-sh" >> "${EVENT_LOG}"
exit 0
EOS
  chmod +x "${SANDBOX}/build.sh"

  export DOCKER_IMAGE_PRESENT=true
  run bash "${SANDBOX}/run.sh" --build --detach
  assert_success

  # Read timeline; setup-check-drift must precede build-sh.
  run head -1 "${EVENT_LOG}"
  assert_output "setup-check-drift"
  run grep -n 'build-sh' "${EVENT_LOG}"
  # build-sh appears AFTER setup-check-drift (line ≥ 2)
  [[ "${output%%:*}" -ge 2 ]] || { echo "expected build-sh after check-drift, got: ${output}"; return 1; }
}

# ════════════════════════════════════════════════════════════════════
# -C / --chdir flag (issue docker_harness#53) — see build_sh_spec for the
# rationale; run.sh mirrors the build.sh pre-pass.
# ════════════════════════════════════════════════════════════════════

@test "run.sh -C <dir> redirects FILE_PATH to <dir>" {
  local ALT="${TEMP_DIR}/alt"
  mkdir -p "${ALT}/.base/script/docker/lib"
  cp /source/script/docker/_lib.sh "${ALT}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${ALT}/.base/script/docker/lib/"
  cp "${SANDBOX}/.base/script/docker/setup.sh" "${ALT}/.base/script/docker/setup.sh"
  chmod +x "${ALT}/.base/script/docker/setup.sh"

  run bash "${SANDBOX}/run.sh" -C "${ALT}" --dry-run --detach
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${ALT}"
}

@test "run.sh --chdir <dir> long form is equivalent to -C" {
  local ALT="${TEMP_DIR}/alt2"
  mkdir -p "${ALT}/.base/script/docker/lib"
  cp /source/script/docker/_lib.sh "${ALT}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${ALT}/.base/script/docker/lib/"
  cp "${SANDBOX}/.base/script/docker/setup.sh" "${ALT}/.base/script/docker/setup.sh"
  chmod +x "${ALT}/.base/script/docker/setup.sh"

  run bash "${SANDBOX}/run.sh" --chdir "${ALT}" --dry-run --detach
  assert_success
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${ALT}"
}

@test "run.sh -C without a value exits 2" {
  run bash "${SANDBOX}/run.sh" -C
  assert_failure 2
  assert_output --partial "requires a value"
}

@test "run.sh -C with a non-existent directory exits 2" {
  run bash "${SANDBOX}/run.sh" -C /definitely/does/not/exist
  assert_failure 2
  assert_output --partial "not a directory"
}

@test "run.sh -C is mentioned in usage help" {
  run bash "${SANDBOX}/run.sh" --help
  assert_success
  assert_output --partial "-C"
  assert_output --partial "--chdir"
}

# ════════════════════════════════════════════════════════════════════
# -v / --verbose / -vv / --very-verbose (BUILDKIT_PROGRESS=plain, #311)
# ════════════════════════════════════════════════════════════════════

@test "run.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)" {
  run bash "${SANDBOX}/run.sh" --help
  assert_success
  assert_output --partial "-v, --verbose"
  assert_output --partial "-vv, --very-verbose"
  assert_output --partial "BUILDKIT_PROGRESS=plain"
}

@test "run.sh -v --dry-run is accepted and exits 0 (#311)" {
  run bash "${SANDBOX}/run.sh" -v --dry-run
  assert_success
}

@test "run.sh --verbose long form is accepted (#311)" {
  run bash "${SANDBOX}/run.sh" --verbose --dry-run
  assert_success
}

@test "run.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)" {
  run --separate-stderr bash "${SANDBOX}/run.sh" -vv --dry-run
  assert_success
  [[ "${stderr}" == *"+ "* ]]
}
