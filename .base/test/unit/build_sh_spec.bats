#!/usr/bin/env bats
#
# Unit tests for script/docker/build.sh argument handling and control flow.
#
# Strategy:
#   * A sandbox tree mirrors the layout build.sh expects (script alongside a
#     .base/ subtree). We copy the real _lib.sh into the sandbox so
#     _load_env / _compose_project are exercised, while setup.sh is replaced
#     with a mock that records invocations and touches .env + compose.yaml.
#   * docker is stubbed via PATH prepend — the stub logs its argv to
#     ${DOCKER_LOG} and exits 0. Combined with DRY_RUN=true in build.sh's
#     _compose path, the stub only receives docker build / docker rmi calls.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/script/docker/lib" \
           "${SANDBOX}/.base/dockerfile" \
           "${SANDBOX}/config/docker"

  cp /source/script/docker/_lib.sh     "${SANDBOX}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh     "${SANDBOX}/.base/script/docker/i18n.sh"
  # _lib.sh post-#284 is an umbrella that sources lib/*.sh sub-libs.
  cp /source/script/docker/lib/*.sh    "${SANDBOX}/.base/script/docker/lib/"
  # Symlink (not copy) so kcov attributes coverage to /source/script/docker/build.sh.
  ln -s /source/script/docker/build.sh "${SANDBOX}/build.sh"
  touch "${SANDBOX}/.base/dockerfile/Dockerfile.test-tools"

  MOCK_SETUP_LOG="${TEMP_DIR}/setup.log"
  export MOCK_SETUP_LOG

  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
# Mock setup.sh (subprocess-only after #49 Phase B-1):
#   - `check-drift` subcommand → exit 0 (no drift in this baseline)
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
  DOCKER_LOG="${TEMP_DIR}/docker.log"
  export DOCKER_LOG
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
{
  printf 'docker'
  printf ' %q' "$@"
  printf '\n'
} | tee -a "${DOCKER_LOG}"
EOS
  chmod +x "${BIN_DIR}/docker"
  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "build.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "build.sh"
}

@test "build.sh --setup forces setup.sh to run" {
  run bash "${SANDBOX}/build.sh" --setup --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${SANDBOX}"
}

@test "build.sh -s short flag is equivalent to --setup" {
  run bash "${SANDBOX}/build.sh" -s --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "build.sh bootstraps setup.sh when .env is missing" {
  # Sandbox starts without .env → build.sh must auto-bootstrap via setup.sh.
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ -f "${SANDBOX}/.env" ]
}

@test "build.sh auto-regens .env / compose.yaml when drift detected" {
  # Regression (v0.9.5): drift used to be warn-only, leaving the stale
  # .env in place. Users had to remember `./build.sh --setup` after
  # every git pull / setup.conf edit. Now the drift branch regens
  # automatically since .env / compose.yaml are derived artifacts.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  # Patch the mock so check-drift subcommand reports drift (exit 1).
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
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "regenerating"
  assert [ -f "${MOCK_SETUP_LOG}" ]
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${SANDBOX}"
}

@test "build.sh skips setup.sh when .env AND setup.conf AND compose.yaml exist (drift-check path)" {
  # Pre-create all three derived files → build.sh must NOT execute
  # setup.sh, only source it for drift detection.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  refute_output --partial "First run"
  assert [ ! -f "${MOCK_SETUP_LOG}" ]
}

@test "build.sh bootstraps setup.sh when setup.conf is missing (even if .env exists)" {
  # Regression: previously build.sh only checked .env. If the user
  # manually deleted setup.conf to reset to defaults, .env alone is
  # stale and build would skip the bootstrap. Now missing setup.conf
  # also triggers the bootstrap path.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  rm -f "${SANDBOX}/config/docker/setup.conf"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
}

@test "build.sh bootstraps setup.sh when compose.yaml is missing (fresh clone)" {
  # Regression (v0.9.2): v0.9.0 started gitignoring compose.yaml, so
  # a fresh clone has .env.example absent + setup.conf tracked +
  # compose.yaml missing. Prior bootstrap check only looked at .env /
  # setup.conf and skipped to the drift path, which then blew up in
  # _load_env because .env also wasn't there. Missing compose.yaml
  # must now trigger the bootstrap path on its own.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  rm -f "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "First run"
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ -f "${SANDBOX}/compose.yaml" ]
}

@test "build.sh bootstrap calls setup.sh directly, not setup_tui.sh" {
  # Regression (v0.9.2): bootstrap used to dispatch through
  # _run_interactive, which on a TTY launches setup_tui.sh. A user who
  # pressed Esc / Ctrl+C in the TUI ended up with no .env and the next
  # build step blew up. Bootstrap must always go through setup.sh
  # non-interactively; TUI is reserved for explicit --setup.
  cat > "${SANDBOX}/setup_tui.sh" <<'EOS'
#!/usr/bin/env bash
echo "TUI_INVOKED" >> "${MOCK_SETUP_LOG}.tui"
exit 0
EOS
  chmod +x "${SANDBOX}/setup_tui.sh"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  assert [ ! -f "${MOCK_SETUP_LOG}.tui" ]
}

@test "build.sh fails with clear error if setup.sh produced no .env" {
  # Defensive guard: if bootstrap runs but setup.sh exits without
  # writing .env (user cancelled a TUI, setup.sh crashed, etc.), the
  # next step would fail deep in _load_env with a cryptic path error.
  # Surface a helpful message instead.
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
# Mock that exits cleanly but produces nothing.
exit 0
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_failure
  assert_output --partial ".env"
  assert_output --partial "--setup"
}

@test "build.sh --no-cache is forwarded to docker build and compose" {
  run bash "${SANDBOX}/build.sh" --no-cache --dry-run
  assert_success
  assert_output --partial "--no-cache"
}

@test "build.sh --clean-tools schedules docker rmi via trap" {
  run bash "${SANDBOX}/build.sh" --clean-tools --dry-run
  assert_success
}

@test "build.sh accepts positional TARGET argument" {
  run bash "${SANDBOX}/build.sh" --dry-run test
  assert_success
  assert_output --partial "test"
}

@test "build.sh -t TARGET (short form) selects the build target (#280)" {
  run bash "${SANDBOX}/build.sh" --dry-run -t test
  assert_success
  assert_output --partial "test"
}

@test "build.sh --target TARGET (long form) selects the build target (#280)" {
  run bash "${SANDBOX}/build.sh" --dry-run --target test
  assert_success
  assert_output --partial "test"
}

@test "build.sh -t + positional: last positional wins (#280)" {
  # Documented contract: when both forms are passed, the rightmost
  # argument wins regardless of which style it was given in.
  run bash "${SANDBOX}/build.sh" --dry-run -t test runtime
  assert_success
  # `runtime` was the last token, so it should be the active TARGET
  assert_output --partial "runtime"
}

@test "build.sh positional + -t: last -t wins (#280)" {
  run bash "${SANDBOX}/build.sh" --dry-run test -t runtime
  assert_success
  assert_output --partial "runtime"
}

@test "build.sh -t with no value errors clearly (#280)" {
  run bash "${SANDBOX}/build.sh" --dry-run -t
  assert_failure
  assert_output --partial "-t/--target requires a value"
}

@test "build.sh --help mentions -t / --target (#280)" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "-t, --target"
}

@test "build.sh passes --build-arg TARGETARCH=<value> when TARGET_ARCH set in .env" {
  # Seed .env with TARGET_ARCH so the drift-check path loads it into
  # the build.sh environment; then the test-tools build should forward
  # it via --build-arg.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
    echo "TARGET_ARCH=arm64"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "--build-arg TARGETARCH=arm64"
}

@test "build.sh omits --build-arg TARGETARCH when TARGET_ARCH absent from .env" {
  # No TARGET_ARCH line → BuildKit auto-fills, build.sh must not pass
  # any --build-arg for TARGETARCH.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  refute_output --partial "TARGETARCH"
}

@test "build.sh passes --network <value> to docker build when BUILD_NETWORK set in .env" {
  # Seed .env with BUILD_NETWORK. [build] network controls the docker
  # build network mode for the auxiliary test-tools image. Required on
  # hosts where Docker's bridge NAT can't reach the outside (e.g.
  # Jetson L4T without iptable_raw kernel module).
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
    echo "BUILD_NETWORK=host"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "--network host"
}

@test "build.sh omits --network when BUILD_NETWORK absent from .env" {
  # No BUILD_NETWORK line → docker build uses its default network
  # (bridge). build.sh must not pass any --network flag.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  : > "${SANDBOX}/config/docker/setup.conf"
  : > "${SANDBOX}/compose.yaml"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  refute_output --partial "--network"
}

@test "build.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/build.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "build.sh --lang requires a value" {
  run bash "${SANDBOX}/build.sh" --lang
  assert_failure
}

@test "build.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/build.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "build.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/build.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

# ── /lint/-layout _detect_lang (flat dir: build.sh + _lib.sh + i18n.sh) ────
# After #104 the inline fallback is gone; scripts in the Dockerfile test
# stage rely on _lib.sh + i18n.sh copied alongside. These tests exercise
# that layout by symlinking build.sh (for kcov) and copying the helpers.

@test "build.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/build.sh "${_tmp}/build.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/build.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "build.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/build.sh "${_tmp}/build.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/build.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "build.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/script/docker/build.sh "${_tmp}/build.sh"
  cp /source/script/docker/_lib.sh "${_tmp}/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/i18n.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/script/docker/lib/*.sh "${_tmp}/lib/"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/build.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}

@test "build.sh calls real docker build when --dry-run is not set" {
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env"
  echo "# mock compose" > "${SANDBOX}/compose.yaml"

  bash "${SANDBOX}/build.sh"
  run cat "${DOCKER_LOG}"
  assert_output --partial "docker build"
  assert_output --partial "-t test-tools:local"
}

# ── i18n log lines (bootstrap / drift / err_no_env) ────────────────────────
# These exercise _msg() for every language on every log line that build.sh
# emits directly. Usage-text coverage lives above; these assert that the
# *runtime* messages (not just --help) translate end-to-end.

@test "build.sh --lang zh-TW prints Chinese bootstrap log" {
  run bash "${SANDBOX}/build.sh" --lang zh-TW --dry-run
  assert_success
  assert_output --partial "首次執行"
}

@test "build.sh --lang zh-CN prints Simplified Chinese bootstrap log" {
  run bash "${SANDBOX}/build.sh" --lang zh-CN --dry-run
  assert_success
  assert_output --partial "首次运行"
}

@test "build.sh --lang ja prints Japanese bootstrap log" {
  run bash "${SANDBOX}/build.sh" --lang ja --dry-run
  assert_success
  assert_output --partial "初回実行"
}

@test "build.sh default bootstrap log is English" {
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "First run"
}

@test "build.sh --lang zh-TW prints Chinese drift-regen log" {
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
  check-drift) exit 1 ;;
  apply)
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
  run bash "${SANDBOX}/build.sh" --lang zh-TW --dry-run
  assert_success
  assert_output --partial "重新產生"
}

@test "build.sh --lang zh-TW prints Chinese err_no_env on failed bootstrap" {
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"
  run bash "${SANDBOX}/build.sh" --lang zh-TW --dry-run
  assert_failure
  # Level keyword is now English-only (#283); zh-TW body still localised.
  assert_output --partial "[build] ERROR:"
  assert_output --partial "setup 未產生 .env"
}

@test "build.sh --lang ja prints Japanese err_no_env on failed bootstrap" {
  cat > "${SANDBOX}/.base/script/docker/setup.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "${SANDBOX}/.base/script/docker/setup.sh"
  run bash "${SANDBOX}/build.sh" --lang ja --dry-run
  assert_failure
  # Level keyword is now English-only (#283); ja body still localised.
  assert_output --partial "[build] ERROR:"
  assert_output --partial "setup が .env を生成"
}

# ════════════════════════════════════════════════════════════════════
# --reset-conf flag (issue #60 / #124)
# ════════════════════════════════════════════════════════════════════

@test "build.sh --reset-conf --yes --dry-run prints init.sh --gen-conf --force cmd" {
  # -y skips the interactive prompt; --dry-run makes the init.sh call
  # a printf instead of an exec so we can assert it without sandbox
  # side effects.
  echo "old" > "${SANDBOX}/config/docker/setup.conf"
  run bash "${SANDBOX}/build.sh" --reset-conf --yes --dry-run
  assert_success
  assert_output --partial "[dry-run]"
  assert_output --partial ".base/init.sh --gen-conf --force"
}

@test "build.sh --reset-conf is mentioned in usage help" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "--reset-conf"
  assert_output --partial "setup.conf.bak"
}

@test "build.sh --reset-conf with no existing setup.conf / .env skips prompt" {
  # Nothing to overwrite → no confirmation needed, --dry-run just prints
  # the init.sh call and exits cleanly.
  rm -f "${SANDBOX}/config/docker/setup.conf" "${SANDBOX}/.env"
  run bash "${SANDBOX}/build.sh" --reset-conf --dry-run
  assert_success
  refute_output --partial "proceed?"
}

# ════════════════════════════════════════════════════════════════════
# -C / --chdir flag (issue docker_harness#53)
#
# The pre-pass at file scope must override FILE_PATH so _lib.sh + setup.sh
# + .env / compose.yaml all resolve against DIR instead of the wrapper's
# symlink dir. Critical for Claude Code's sandbox excludedCommands match
# (top-level token stays `./build.sh ...` rather than subshell / bash -c).
# ════════════════════════════════════════════════════════════════════

@test "build.sh -C <dir> redirects FILE_PATH to <dir>" {
  # Build a second sandbox tree mirroring the primary one, then invoke
  # the *primary* build.sh with -C pointing at the alt tree. The mock
  # setup.sh stamps MOCK_SETUP_LOG with whatever --base-path it received,
  # so the log proves which tree FILE_PATH resolved to.
  local ALT="${TEMP_DIR}/alt"
  mkdir -p "${ALT}/.base/script/docker/lib" "${ALT}/.base/dockerfile"
  cp /source/script/docker/_lib.sh "${ALT}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${ALT}/.base/script/docker/lib/"
  cp "${SANDBOX}/.base/script/docker/setup.sh" "${ALT}/.base/script/docker/setup.sh"
  chmod +x "${ALT}/.base/script/docker/setup.sh"
  touch "${ALT}/.base/dockerfile/Dockerfile.test-tools"

  run bash "${SANDBOX}/build.sh" -C "${ALT}" --dry-run
  assert_success
  assert [ -f "${MOCK_SETUP_LOG}" ]
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${ALT}"
  refute_output --partial "setup.sh invoked --base-path ${SANDBOX}"
}

@test "build.sh --chdir <dir> long form is equivalent to -C" {
  local ALT="${TEMP_DIR}/alt2"
  mkdir -p "${ALT}/.base/script/docker/lib" "${ALT}/.base/dockerfile"
  cp /source/script/docker/_lib.sh "${ALT}/.base/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${ALT}/.base/script/docker/i18n.sh"
  cp /source/script/docker/lib/*.sh "${ALT}/.base/script/docker/lib/"
  cp "${SANDBOX}/.base/script/docker/setup.sh" "${ALT}/.base/script/docker/setup.sh"
  chmod +x "${ALT}/.base/script/docker/setup.sh"
  touch "${ALT}/.base/dockerfile/Dockerfile.test-tools"

  run bash "${SANDBOX}/build.sh" --chdir "${ALT}" --dry-run
  assert_success
  run cat "${MOCK_SETUP_LOG}"
  assert_output --partial "setup.sh invoked --base-path ${ALT}"
}

@test "build.sh -C without a value exits 2" {
  run bash "${SANDBOX}/build.sh" -C
  assert_failure 2
  assert_output --partial "requires a value"
}

@test "build.sh -C with a non-existent directory exits 2" {
  run bash "${SANDBOX}/build.sh" -C /definitely/does/not/exist
  assert_failure 2
  assert_output --partial "not a directory"
}

@test "build.sh -C is mentioned in usage help" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "-C"
  assert_output --partial "--chdir"
}

# ════════════════════════════════════════════════════════════════════
# -v / --verbose / -vv / --very-verbose (BUILDKIT_PROGRESS=plain, #311)
# ════════════════════════════════════════════════════════════════════

@test "build.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "-v, --verbose"
  assert_output --partial "-vv, --very-verbose"
  assert_output --partial "BUILDKIT_PROGRESS=plain"
}

@test "build.sh -v --dry-run is accepted and exits 0 (#311)" {
  run bash "${SANDBOX}/build.sh" -v --dry-run
  assert_success
}

@test "build.sh --verbose long form is accepted (#311)" {
  run bash "${SANDBOX}/build.sh" --verbose --dry-run
  assert_success
}

@test "build.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)" {
  run --separate-stderr bash "${SANDBOX}/build.sh" -vv --dry-run
  assert_success
  # set -x emits trace lines starting with `+ ` to stderr. After the case
  # branch fires the wrapper continues hitting other lines that all get
  # traced.
  [[ "${stderr}" == *"+ "* ]]
}
