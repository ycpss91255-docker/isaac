#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# ════════════════════════════════════════════════════════════════════
# Structure: required files exist
# ════════════════════════════════════════════════════════════════════

@test "build.sh exists and is executable" {
  assert [ -f /source/script/docker/build.sh ]
  assert [ -x /source/script/docker/build.sh ]
}

@test "run.sh exists and is executable" {
  assert [ -f /source/script/docker/run.sh ]
  assert [ -x /source/script/docker/run.sh ]
}

@test "exec.sh exists and is executable" {
  assert [ -f /source/script/docker/exec.sh ]
  assert [ -x /source/script/docker/exec.sh ]
}

@test "stop.sh exists and is executable" {
  assert [ -f /source/script/docker/stop.sh ]
  assert [ -x /source/script/docker/stop.sh ]
}

@test "setup.sh exists and is executable" {
  assert [ -f /source/script/docker/setup.sh ]
  assert [ -x /source/script/docker/setup.sh ]
}

# ════════════════════════════════════════════════════════════════════
# Structure: ci.sh and Makefile exist
# ════════════════════════════════════════════════════════════════════

@test "ci.sh exists and is executable" {
  assert [ -f /source/script/ci/ci.sh ]
  assert [ -x /source/script/ci/ci.sh ]
}

@test "ci.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/ci/ci.sh
  assert_success
}

@test "Makefile exists (repo entry)" {
  assert [ -f /source/script/docker/Makefile ]
}

@test "Makefile has build target" {
  run grep -E '^build:' /source/script/docker/Makefile
  assert_success
}

@test "Makefile upgrade target uses ./template/upgrade.sh (not ./template/script/upgrade.sh)" {
  # Regression: the Makefile symlinked into every downstream repo has
  # called `./template/script/upgrade.sh` since v0.10.x, but upgrade.sh
  # actually lives at template root (`./template/upgrade.sh`). The
  # broken target produced "No such file or directory" on `make upgrade`
  # / `make upgrade-check` for fresh consumer repos.
  run grep -E '^[[:space:]]+\./template/upgrade\.sh' /source/script/docker/Makefile
  assert_success
  refute_output --partial "./template/script/upgrade.sh"
}

@test "Makefile.ci exists (template CI)" {
  assert [ -f /source/Makefile.ci ]
}

@test "Makefile.ci has test target" {
  run grep -E '^test:' /source/Makefile.ci
  assert_success
}

@test "Makefile.ci has lint target" {
  run grep -E '^lint:' /source/Makefile.ci
  assert_success
}

@test "Makefile.ci has upgrade target" {
  run grep -E '^upgrade:' /source/Makefile.ci
  assert_success
}

@test "Makefile.ci upgrade target forwards optional VERSION variable" {
  # `make -f Makefile.ci upgrade [VERSION=vX.Y.Z]` is the documented entry
  # point. The recipe must pass $(VERSION) to ./upgrade.sh so an empty
  # VERSION resolves to "latest" and a set VERSION pins a specific tag.
  run grep -E '^[[:space:]]+\./upgrade\.sh \$\(VERSION\)' /source/Makefile.ci
  assert_success
}

@test "Makefile upgrade-check tolerates upgrade.sh exit 1 (update available)" {
  # Regression #175: `upgrade.sh --check` exits 1 when an update is
  # available (documented shell convention so `if ./upgrade.sh --check;
  # then ...` works). The Makefile recipe must wrap the call so make
  # treats exit 1 as success — the check itself succeeded, the user-
  # facing message already conveys the result. Exit codes ≥2 (genuine
  # failures) still propagate.
  run grep -E '\./template/upgrade\.sh --check \|\| \[ \$\$\? -eq 1 \]' \
      /source/script/docker/Makefile
  assert_success
}

@test "Makefile.ci upgrade-check tolerates upgrade.sh exit 1 (update available)" {
  # Same wrap as the downstream Makefile (regression #175). Template's
  # own `make -f Makefile.ci upgrade-check` was failing on every release
  # cycle when upstream/downstream diverged.
  run grep -E '\./upgrade\.sh --check \|\| \[ \$\$\? -eq 1 \]' \
      /source/Makefile.ci
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Structure: test directory layout
# ════════════════════════════════════════════════════════════════════

@test "test/smoke/test_helper.bash exists" {
  assert [ -f /source/test/smoke/test_helper.bash ]
}

@test "test/smoke/script_help.bats exists" {
  assert [ -f /source/test/smoke/script_help.bats ]
}

@test "test/smoke/display_env.bats exists" {
  assert [ -f /source/test/smoke/display_env.bats ]
}

@test "test/unit/ directory exists" {
  assert [ -d /source/test/unit ]
}

# ════════════════════════════════════════════════════════════════════
# Structure: doc directory layout
# ════════════════════════════════════════════════════════════════════

@test "doc/readme/ directory exists" {
  assert [ -d /source/doc/readme ]
}

@test "doc/test/ directory exists" {
  assert [ -d /source/doc/test ]
}

@test "doc/changelog/ directory exists" {
  assert [ -d /source/doc/changelog ]
}

# ════════════════════════════════════════════════════════════════════
# Path reference: scripts call template/script/docker/setup.sh
# ════════════════════════════════════════════════════════════════════

@test "build.sh references template/script/docker/setup.sh" {
  run grep "template/script/docker/setup.sh" /source/script/docker/build.sh
  assert_success
}

@test "run.sh references template/script/docker/setup.sh" {
  run grep "template/script/docker/setup.sh" /source/script/docker/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Shell conventions: set -euo pipefail
# ════════════════════════════════════════════════════════════════════

@test "build.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/docker/build.sh
  assert_success
}

@test "build.sh supports --no-cache flag" {
  run grep -E '\-\-no-cache' /source/script/docker/build.sh
  assert_success
}

@test "build.sh passes --no-cache to docker compose build when set" {
  run grep -E 'NO_CACHE.*=.*true' /source/script/docker/build.sh
  assert_success
}

@test "build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)" {
  # Default behavior: do NOT auto-remove test-tools:local
  # cleanup must be conditional on CLEAN_TOOLS
  run grep -E 'CLEAN_TOOLS.*==.*true' /source/script/docker/build.sh
  assert_success
}

@test "build.sh supports --clean-tools flag" {
  run grep -E '\-\-clean-tools' /source/script/docker/build.sh
  assert_success
}

@test "build.sh removes test-tools image when --clean-tools is set" {
  run grep -E 'CLEAN_TOOLS.*=.*true' /source/script/docker/build.sh
  assert_success
}

@test "run.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/docker/run.sh
  assert_success
}

@test "exec.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/docker/stop.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Docker compose project name (-p)
# ════════════════════════════════════════════════════════════════════

@test "_lib.sh derives PROJECT_NAME from DOCKER_HUB_USER and IMAGE_NAME" {
  # Project name derivation lives in _lib.sh and is shared by all callers.
  run grep -E 'PROJECT_NAME=.*DOCKER_HUB_USER.*IMAGE_NAME' /source/script/docker/_lib.sh
  assert_success
}

@test "_lib.sh _compose_project wraps -p with PROJECT_NAME" {
  run grep -E '\-p .*PROJECT_NAME' /source/script/docker/_lib.sh
  assert_success
}

@test "build.sh routes compose call through _compose_project" {
  run grep -E '_compose_project ' /source/script/docker/build.sh
  assert_success
}

@test "run.sh routes compose calls through _compose_project" {
  run grep -E '_compose_project ' /source/script/docker/run.sh
  assert_success
}

@test "exec.sh routes compose call through _compose_project" {
  run grep -E '_compose_project ' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh routes compose call through _compose_project" {
  run grep -E '_compose_project ' /source/script/docker/stop.sh
  assert_success
}

@test "exec.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/script/docker/stop.sh
  assert_success
}

@test "_lib.sh defines _load_env helper" {
  run grep -E '^_load_env\(\)' /source/script/docker/_lib.sh
  assert_success
}

@test "_lib.sh defines _compute_project_name helper" {
  run grep -E '^_compute_project_name\(\)' /source/script/docker/_lib.sh
  assert_success
}

@test "_lib.sh defines _compose wrapper" {
  run grep -E '^_compose\(\)' /source/script/docker/_lib.sh
  assert_success
}

@test "stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)" {
  # v0.6.6: run.sh devel switched to compose up + exec, so no more orphan
  # containers from `compose run --name`. The orphan cleanup line is removed.
  run grep -E 'docker rm.*-f.*IMAGE_NAME' /source/script/docker/stop.sh
  assert_failure
}

@test "run.sh devel target uses compose up -d (not compose run --name)" {
  # Regression: foreground devel previously used `compose run --name` which
  # created a one-off container that `./exec.sh` (compose exec) couldn't see,
  # producing "service devel is not running". Switched to up + exec.
  run grep -E 'up -d' /source/script/docker/run.sh
  assert_success
}

@test "run.sh devel branch uses compose exec to enter shell" {
  # Refactored: now goes through `_compose_project exec` wrapper.
  run grep -E '_compose_project exec' /source/script/docker/run.sh
  assert_success
}

@test "run.sh devel branch installs trap to auto-down on exit" {
  # Refactored: trap calls _devel_cleanup which runs compose down.
  run grep -E 'trap _devel_cleanup EXIT' /source/script/docker/run.sh
  assert_success
  run grep -E '_devel_cleanup\(\)' /source/script/docker/run.sh
  assert_success
}

@test "run.sh _devel_cleanup uses short timeout to avoid 10s grace period" {
  # Regression: compose down's default 10s SIGTERM grace makes ./run.sh
  # appear to hang for ~10s after the user exits the bash shell. Interactive
  # devel doesn't need graceful shutdown — the user already exited.
  run grep -E '_devel_cleanup\(\)' /source/script/docker/run.sh
  assert_success
  run grep -E 'down -t 0|down --timeout 0' /source/script/docker/run.sh
  assert_success
}

@test "run.sh non-devel TARGET still uses compose run --rm" {
  # test/runtime/etc one-shots stay on compose run --rm (no exec needed)
  run grep -E 'run --rm' /source/script/docker/run.sh
  assert_success
}

@test "run.sh devel branch does not use 'compose run --name'" {
  # The old buggy pattern must be gone for devel; only run --rm for one-shots
  run grep -E 'run .*--name' /source/script/docker/run.sh
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# --instance flag (v0.6.8)
# ════════════════════════════════════════════════════════════════════

@test "run.sh supports --instance flag" {
  run grep -E '\-\-instance' /source/script/docker/run.sh
  assert_success
}

@test "exec.sh supports --instance flag" {
  run grep -E '\-\-instance' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh supports --instance flag" {
  run grep -E '\-\-instance' /source/script/docker/stop.sh
  assert_success
}

@test "stop.sh supports --all flag" {
  run grep -E '\-\-all' /source/script/docker/stop.sh
  assert_success
}

@test "run.sh exports INSTANCE_SUFFIX env var to compose" {
  # Compose YAML resolves ${INSTANCE_SUFFIX:-} from this env var
  run grep -E 'INSTANCE_SUFFIX' /source/script/docker/run.sh
  assert_success
}

@test "exec.sh exports INSTANCE_SUFFIX env var to compose" {
  run grep -E 'INSTANCE_SUFFIX' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh exports INSTANCE_SUFFIX env var to compose" {
  run grep -E 'INSTANCE_SUFFIX' /source/script/docker/stop.sh
  assert_success
}

@test "run.sh refuses when default container already running and no --instance" {
  # The script should grep docker ps for existing container with the
  # default name and exit non-zero with a helpful message
  run grep -E 'already running|already exists' /source/script/docker/run.sh
  assert_success
}

@test "setup.sh-generated compose.yaml uses parameterized container_name" {
  # compose.yaml is now generated by setup.sh's generate_compose_yaml()
  # rather than init.sh's heredoc. INSTANCE_SUFFIX lets run.sh --instance
  # suffix the container name for parallel runs.
  run grep 'INSTANCE_SUFFIX' /source/script/docker/setup.sh
  assert_success
}

@test "run.sh -h shows --instance in help" {
  run bash -c "bash /source/script/docker/run.sh -h 2>&1"
  assert_output --partial "--instance"
}

@test "exec.sh -h shows --instance in help" {
  run bash -c "bash /source/script/docker/exec.sh -h 2>&1"
  assert_output --partial "--instance"
}

@test "stop.sh -h shows --instance in help" {
  run bash -c "bash /source/script/docker/stop.sh -h 2>&1"
  assert_output --partial "--instance"
}

# ════════════════════════════════════════════════════════════════════
# --dry-run flag (PR B)
# ════════════════════════════════════════════════════════════════════

@test "build.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/script/docker/build.sh
  assert_success
}

@test "run.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/script/docker/run.sh
  assert_success
}

@test "exec.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/script/docker/stop.sh
  assert_success
}

@test "build.sh -h shows --dry-run in help" {
  run bash -c "bash /source/script/docker/build.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "run.sh -h shows --dry-run in help" {
  run bash -c "bash /source/script/docker/run.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "exec.sh -h shows --dry-run in help" {
  run bash -c "bash /source/script/docker/exec.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "stop.sh -h shows --dry-run in help" {
  run bash -c "bash /source/script/docker/stop.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

# ════════════════════════════════════════════════════════════════════
# exec.sh container precheck (PR B)
# ════════════════════════════════════════════════════════════════════

@test "exec.sh checks container is running before exec" {
  # Should reference docker ps / docker inspect or similar precheck
  run grep -E 'docker (ps|inspect)' /source/script/docker/exec.sh
  assert_success
}

@test "exec.sh precheck error mentions run.sh hint" {
  # Friendly error pointing user at ./run.sh or --instance
  run grep -E 'run\.sh|--instance' /source/script/docker/exec.sh
  assert_success
}

@test "exec.sh exits non-zero with friendly hint when container not running" {
  # Simulate a tmp repo with .env so exec.sh gets past _load_env, then call
  # without docker on PATH so the precheck fails (no container can be found).
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env" <<EOF
DOCKER_HUB_USER=alice
IMAGE_NAME=missing-image-$$
EOF
  mkdir -p "${_tmp}/template/script/docker"
  cp /source/script/docker/_lib.sh "${_tmp}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/template/script/docker/i18n.sh" 2>/dev/null || true
  cp /source/script/docker/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh"
  assert_failure
  assert_output --partial "is not running"
  assert_output --partial "run.sh"
  rm -rf "${_tmp}"
}

@test "exec.sh --dry-run skips precheck and prints compose command" {
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env" <<EOF
DOCKER_HUB_USER=alice
IMAGE_NAME=ghost-$$
EOF
  mkdir -p "${_tmp}/template/script/docker"
  cp /source/script/docker/_lib.sh "${_tmp}/template/script/docker/_lib.sh"
  cp /source/script/docker/i18n.sh "${_tmp}/template/script/docker/i18n.sh" 2>/dev/null || true
  cp /source/script/docker/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh" --dry-run
  assert_success
  assert_output --partial "[dry-run] docker compose"
  assert_output --partial "exec"
  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# i18n.sh shared module
# ════════════════════════════════════════════════════════════════════

@test "script/docker/i18n.sh exists" {
  assert [ -f /source/script/docker/i18n.sh ]
}

@test "Dockerfile.test-tools includes bats-mock" {
  run grep 'bats-mock' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools declares ARG TARGETARCH" {
  run grep -E '^ARG TARGETARCH' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)" {
  # Regression guard: `ARG TARGETARCH=amd64` with a default shadows
  # BuildKit's per-platform auto-inject (moby/buildkit#3403), which
  # caused every multi-arch build to fall back to amd64 — arm64 image
  # variants shipped x86_64 shellcheck / hadolint binaries. Symptom
  # downstream: `shellcheck: Exec format error` on arm64 CI.
  run grep -E '^ARG TARGETARCH=' /source/dockerfile/Dockerfile.test-tools
  assert_failure
  # But the bare declaration must still be there so the stage can
  # consume the BuildKit-injected value.
  run grep -E '^ARG TARGETARCH$' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools branches case for amd64 and arm64" {
  # Must handle both common arches; amd64 → x86_64 binaries,
  # arm64 → aarch64 (shellcheck) + arm64 (hadolint) binaries.
  run grep -E 'amd64\)' /source/dockerfile/Dockerfile.test-tools
  assert_success
  run grep -E 'arm64\)' /source/dockerfile/Dockerfile.test-tools
  assert_success
  run grep -E 'aarch64' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools fails loud on unsupported TARGETARCH" {
  run grep -E 'Unsupported TARGETARCH' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "i18n.sh defines _detect_lang function" {
  run grep -E '^_detect_lang\(\)' /source/script/docker/i18n.sh
  assert_success
}

@test "build.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/script/docker/build.sh
  assert_success
}

@test "run.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/script/docker/run.sh
  assert_success
}

@test "exec.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/script/docker/exec.sh
  assert_success
}

@test "stop.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/script/docker/stop.sh
  assert_success
}

@test "_lib.sh sources i18n.sh (delegates language detection)" {
  run grep -E 'source.*i18n\.sh' /source/script/docker/_lib.sh
  assert_success
}

@test "setup.sh sources i18n.sh" {
  run grep -E 'source.*i18n\.sh' /source/script/docker/setup.sh
  assert_success
}

_stage_lint_layout() {
  # Simulate Dockerfile.example's /lint/ stage: script + helpers in one
  # flat directory. Callers pass the script file under test.
  local _dest="${1:?}" _script="${2:?}"
  cp "/source/script/docker/${_script}" "${_dest}/${_script}"
  cp /source/script/docker/_lib.sh   "${_dest}/_lib.sh"
  cp /source/script/docker/i18n.sh   "${_dest}/i18n.sh"
}

@test "build.sh -h works in /lint/ layout (flat dir with _lib.sh + i18n.sh, issue #104)" {
  # After #104 we no longer carry inline _detect_lang fallbacks; the
  # /lint/ stage COPY must include _lib.sh and i18n.sh alongside.
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" build.sh
  run bash "${_tmp}/build.sh" -h
  assert_success
  assert_output --partial "Usage"
  rm -rf "${_tmp}"
}

@test "run.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" run.sh
  run bash "${_tmp}/run.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "exec.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" exec.sh
  run bash "${_tmp}/exec.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "stop.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" stop.sh
  run bash "${_tmp}/stop.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "build.sh errors with a clear diagnostic when _lib.sh missing from both paths (issue #104)" {
  # No template/script/docker/_lib.sh nor sibling _lib.sh → explicit
  # non-zero exit + error message pointing the user at the two
  # expected paths. Better UX than the old silent inline fallback
  # that hid the absence.
  local _tmp
  _tmp="$(mktemp -d)"
  cp /source/script/docker/build.sh "${_tmp}/build.sh"
  run bash "${_tmp}/build.sh" -h
  assert_failure
  assert_output --partial "cannot find _lib.sh"
  rm -rf "${_tmp}"
}

@test "Dockerfile.example copies _lib.sh + i18n.sh + _tui_conf.sh into /lint/ (issue #104)" {
  # Structural guard: if the Dockerfile COPY is dropped, the /lint/
  # smoke test (script_help.bats) would break silently for new
  # downstream repos. Pin it here.
  run grep -F 'template/script/docker/_lib.sh' /source/dockerfile/Dockerfile.example
  assert_success
  run grep -F 'template/script/docker/i18n.sh' /source/dockerfile/Dockerfile.example
  assert_success
  run grep -F 'template/script/docker/_tui_conf.sh' /source/dockerfile/Dockerfile.example
  assert_success
}

@test "no inline _detect_lang fallbacks remain after dedupe (issue #104)" {
  # Lock in: only i18n.sh defines _detect_lang. build.sh / run.sh /
  # exec.sh / stop.sh / _lib.sh previously shipped their own copies,
  # which drifted (see #103's zh→zh-TW typo) — a single-source
  # definition prevents further drift.
  local _count
  _count="$(grep -cE '^_detect_lang\(\)' \
    /source/script/docker/build.sh \
    /source/script/docker/run.sh \
    /source/script/docker/exec.sh \
    /source/script/docker/stop.sh \
    /source/script/docker/_lib.sh \
    /source/script/docker/setup.sh \
    | awk -F: '{sum += $2} END {print sum}')"
  [ "${_count}" = "0" ]

  # i18n.sh must still have exactly one definition.
  run grep -cE '^_detect_lang\(\)' /source/script/docker/i18n.sh
  assert_output "1"
}

@test "setup.sh does not redefine _detect_lang" {
  # setup.sh is not COPY'd into consumer /lint stage, so no fallback needed
  run grep -cE '^_detect_lang\(\)' /source/script/docker/setup.sh
  assert_output "0"
}

@test "setup.sh defines _setup_msg, not _msg (closes #101)" {
  # Regression for #101: build.sh / run.sh source setup.sh to obtain
  # `_check_setup_drift`. setup.sh used to define a top-level `_msg()`
  # with a smaller key set than the caller's, silently shadowing it
  # post-source. Subsequent `_msg drift_regen` returned empty and
  # `printf "%s\n" ""` ate the drift-regen status line on every fresh-
  # host / setup.conf-changed run. Defensive namespacing fix: rename
  # to `_setup_msg`. Future helpers in setup.sh should follow the
  # `_setup_*` prefix convention to keep this immune.
  run grep -cE '^_msg\(\) \{' /source/script/docker/setup.sh
  assert_output "0"
  run grep -cE '^_setup_msg\(\) \{' /source/script/docker/setup.sh
  assert_output "1"
}

@test "build.sh _msg keys survive sourcing setup.sh (#101 behavioral)" {
  # Behavioral guard: source setup.sh in a subshell that already has a
  # top-level _msg() with rich keys (mirrors what build.sh / run.sh used
  # to do in the drift-check branch pre-B-1) and assert the rich keys
  # still resolve afterward. Prior to #101 fix, setup.sh's _msg shadowed
  # the caller's _msg and `_msg drift_regen` returned empty. Even though
  # B-1 dropped the `source` callsite, this guard stays so future helpers
  # added to setup.sh can't reintroduce the bug class.
  run bash -c '
    _msg() {
      case "$1" in
        drift_regen) echo "regenerating" ;;
        env_done)    echo "REAL CALLER env_done — should NOT be returned" ;;
      esac
    }
    # shellcheck source=/dev/null
    source /source/script/docker/setup.sh </dev/null >/dev/null 2>&1 || true
    _msg drift_regen
  '
  assert_success
  assert_output "regenerating"
}

@test "build.sh does not source setup.sh (#49 Phase B-1)" {
  # Structural guard for the #101 fix: B-1 replaced build.sh's
  # `source "${_setup}"` + `_check_setup_drift "${FILE_PATH}"` with a
  # subprocess call (`bash setup.sh check-drift --base-path ... --lang ...`).
  # No future change should put `source` back — that would reopen the
  # entire shadow-bug class even if _msg vs _setup_msg stays clean.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/script/docker/build.sh
  assert_output "0"
}

@test "run.sh does not source setup.sh (#49 Phase B-1)" {
  # Mirror of build.sh structural guard above.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/script/docker/run.sh
  assert_output "0"
}

@test "build.sh uses subprocess check-drift (#49 Phase B-1)" {
  # Positive guard: build.sh must invoke setup.sh via subprocess with
  # the new check-drift subcommand instead of sourcing it.
  run grep -cE '"\$\{_setup\}"[[:space:]]+check-drift' /source/script/docker/build.sh
  assert_success
  refute_output "0"
}

@test "run.sh uses subprocess check-drift (#49 Phase B-1)" {
  run grep -cE '"\$\{_setup\}"[[:space:]]+check-drift' /source/script/docker/run.sh
  assert_success
  refute_output "0"
}

# ════════════════════════════════════════════════════════════════════
# upgrade.sh
# ════════════════════════════════════════════════════════════════════

@test ".version file exists in template root" {
  # Semver with optional pre-release (e.g. v0.10.0-rc1). Accepts plain
  # `vX.Y.Z` and `vX.Y.Z-<identifiers>` per semver §9 so the RC release
  # workflow doesn't fail on the CHANGELOG self-check.
  assert [ -f /source/.version ]
  run cat /source/.version
  assert_output --regexp '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
}

@test "upgrade.sh reads version from template/.version" {
  run grep -E 'template/\.version' /source/upgrade.sh
  assert_success
}

@test "upgrade.sh does not reference legacy VERSION or .template_version" {
  # After the .version rename, upgrade.sh must not mention either
  # legacy filename — no backward-compat fallback is carried.
  run grep -cE 'template/VERSION|\.template_version' /source/upgrade.sh
  assert_failure
  assert_output "0"
}

@test "upgrade.sh runs init.sh after subtree pull" {
  run grep -E 'init\.sh' /source/upgrade.sh
  assert_success
}

@test "upgrade.sh supports --gen-conf flag" {
  run grep -E '\-\-gen-conf' /source/upgrade.sh
  assert_success
}

@test "upgrade.sh --gen-conf delegates to init.sh --gen-conf" {
  run grep -E 'init\.sh.*--gen-conf' /source/upgrade.sh
  assert_success
}

@test "upgrade.sh --help mentions --gen-conf" {
  run bash -c "bash /source/upgrade.sh --help 2>&1"
  assert_success
  assert_output --partial "--gen-conf"
}

@test "upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml" {
  # Regression: a greedy sed pattern .*@v[0-9.]* matched both build-worker
  # and release-worker references, replacing both with build-worker.yaml@<ver>
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  mkdir -p "${_tmp}/template" "${_tmp}/.github/workflows"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v0.5.0
  call-release:
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v0.5.0
EOF
  # Source upgrade.sh and exercise just the sed block by inlining the
  # production sed commands here, mirroring what upgrade.sh does.
  # We do this by extracting and running the sed commands from upgrade.sh.
  local _seds
  _seds="$(grep -E "^[[:space:]]*sed -i" /source/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.6.4|g")"
    eval "${_line}"
  done <<< "${_seds}"

  run grep "build-worker.yaml@v0.6.4" "${_yaml}"
  assert_success
  run grep "release-worker.yaml@v0.6.4" "${_yaml}"
  assert_success
  # Critical: release-worker must NOT be replaced by build-worker
  run grep -c "build-worker.yaml" "${_yaml}"
  assert_output "1"

  rm -rf "${_tmp}"
}

@test "upgrade.sh main.yaml sed handles semver pre-release tags (RC → RC)" {
  # Regression: the previous `[0-9.]*` character class stopped at the
  # first `-`, so upgrading from an existing RC tag left the old
  # `-rcN` suffix in place and the new version got appended after it
  # (e.g. @v0.10.0-rc1 → -rc2 produced `@v0.10.0-rc2-rc1`).
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v0.10.0-rc1
  call-release:
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v0.10.0-rc1
EOF
  local _seds
  _seds="$(grep -E "^[[:space:]]*sed -i" /source/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.10.0-rc2|g")"
    eval "${_line}"
  done <<< "${_seds}"

  # Must produce the clean new tag — no leftover `-rc1` suffix.
  run grep -c 'build-worker.yaml@v0.10.0-rc2$' "${_yaml}"
  assert_output "1"
  run grep -c 'release-worker.yaml@v0.10.0-rc2$' "${_yaml}"
  assert_output "1"
  # And no double suffix anywhere.
  run grep -c '@v0.10.0-rc2-rc' "${_yaml}"
  assert_output "0"

  rm -rf "${_tmp}"
}

@test "upgrade.sh main.yaml sed handles stable → stable + RC → stable transitions" {
  # Edge cases around the pre-release group: from plain semver to plain,
  # and from RC back to plain stable (e.g. v0.10.0-rc2 → v0.10.0).
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v0.10.0-rc2
  call-release:
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v0.9.9
EOF
  local _seds
  _seds="$(grep -E "^[[:space:]]*sed -i" /source/upgrade.sh)"
  while IFS= read -r _line; do
    # shellcheck disable=SC2001
    _line="$(echo "${_line}" | sed "s|\${main_yaml}|${_yaml}|g; s|\${target_ver}|v0.10.0|g")"
    eval "${_line}"
  done <<< "${_seds}"

  run grep -c 'build-worker.yaml@v0.10.0$' "${_yaml}"
  assert_output "1"
  run grep -c 'release-worker.yaml@v0.10.0$' "${_yaml}"
  assert_output "1"
  # Must not leave stale -rc2 anywhere in the file.
  run grep -c 'rc2' "${_yaml}"
  assert_output "0"

  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# build-worker.yaml: GHCR test-tools migration (D plan)
# ════════════════════════════════════════════════════════════════════

@test "build-worker.yaml: no legacy in-job test-tools build step" {
  # The old `Build test-tools image` step is replaced by GHCR pull
  # via the TEST_TOOLS_IMAGE build-arg. If it reappears, CI will hit
  # the cross-step buildx image-store isolation again (v0.9.12 regression).
  local _yaml="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "build-worker.yaml not present in /source"
  run grep -c 'Build test-tools image' "${_yaml}"
  assert_output "0"
}

@test "build-worker.yaml: declares test_tools_version input" {
  # Replaces the v0.10.0 GITHUB_WORKFLOW_REF auto-parse, which read the
  # caller's own tag ref (e.g. a downstream repo's v1.5.0) rather than
  # template's pinned @tag, so downstream tag pushes tried to pull
  # `ghcr.io/.../test-tools:<downstream-tag>` and failed 404.
  local _yaml="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "build-worker.yaml not present in /source"
  run grep -F 'test_tools_version:' "${_yaml}"
  assert_success
  # Default must be `latest` so unpinned callers still work.
  run awk '
    /test_tools_version:/ { inside = 1 }
    inside && /^[[:space:]]+default:/ { print; exit }
  ' "${_yaml}"
  assert_success
  assert_output --partial '"latest"'
}

@test "build-worker.yaml: does not resurrect the GITHUB_WORKFLOW_REF parse step" {
  # Regression guard: the legacy auto-parse step must not come back.
  # Comments referencing it are fine (they explain the deprecation).
  local _yaml="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "build-worker.yaml not present in /source"
  run grep -Fc 'Resolve template version for test-tools image' "${_yaml}"
  assert_output "0"
}

@test "build-worker.yaml: test build passes TEST_TOOLS_IMAGE from inputs" {
  local _yaml="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "build-worker.yaml not present in /source"
  run awk '
    /- name: Build test stage/ { inside = 1 }
    inside && /^[[:space:]]*- name:/ && !/Build test stage/ { inside = 0 }
    inside { print }
  ' "${_yaml}"
  assert_success
  # build-arg must wire inputs.test_tools_version into the ghcr tag
  assert_output --partial 'TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}'
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: TEST_TOOLS_IMAGE ARG + named stage
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example has ARG TEST_TOOLS_IMAGE with test-tools:local default" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -E '^ARG TEST_TOOLS_IMAGE="test-tools:local"' "${_df}"
  assert_success
}

@test "Dockerfile.example FROM \${TEST_TOOLS_IMAGE} AS test-tools-stage" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -F 'FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage' "${_df}"
  assert_success
}

@test "Dockerfile.example test stage copies from test-tools-stage, not test-tools:local" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # All COPY --from referring to the test-tools image must now use the
  # named stage alias.
  run grep -c 'COPY --from=test-tools-stage' "${_df}"
  # 4 copies expected: shellcheck, hadolint, /opt/bats, /usr/lib/bats
  assert_output "4"
  # Legacy tag reference must be gone:
  run grep -c 'COPY --from=test-tools:local' "${_df}"
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: ENV alignment with downstream fleet (#210)
#
# All 17 hand-written downstream Dockerfiles declare ENV TZ +
# ENV LANGUAGE alongside ENV LC_ALL / ENV LANG. Pre-#210 the seed
# Dockerfile.example only had LC_ALL / LANG; downstream-derived images
# from `/new-repo` therefore silently differed from the fleet on
# runtime $TZ and $LANGUAGE. The gap surfaces only for consumers that
# read the env directly (Python tzlocal, gettext fallback, some JVM
# tz resolution paths), but new repos should match the fleet.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example declares ENV TZ (matches downstream fleet, #210)" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Forwards the build-time ARG TZ value into a runtime env. ENV without
  # an explicit value would inherit the ARG, which is what we want — the
  # exact spelling the test locks is `ENV TZ="${TZ}"` to mirror how the
  # 17 downstream Dockerfiles spell it.
  run grep -E '^ENV TZ="\$\{TZ\}"$' "${_df}"
  assert_success
}

@test "Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)" {
  local _df="/source/dockerfile/Dockerfile.example"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Same value the 17 downstream Dockerfiles use; gettext fallback uses
  # $LANGUAGE in addition to $LANG so unset means the fallback chain
  # collapses to en_US only.
  run grep -E '^ENV LANGUAGE="en_US:en"$' "${_df}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# release-test-tools.yaml: GHCR publisher workflow
# ════════════════════════════════════════════════════════════════════

@test "release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools" {
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -F 'ghcr.io/ycpss91255-docker/test-tools' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml declares packages:write permission" {
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -F 'packages: write' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml builds multi-arch (amd64 + arm64)" {
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -F 'platforms: linux/amd64,linux/arm64' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml uses template-repo-local Dockerfile path" {
  # Regression: this workflow runs in the template repo, so Dockerfile.test-tools
  # path must be `dockerfile/...` (not `template/dockerfile/...` which is the
  # downstream subtree path used by build-worker.yaml).
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -E '^\s*file: dockerfile/Dockerfile\.test-tools$' "${_yaml}"
  assert_success
  # And must NOT have the subtree-prefixed path:
  run grep -c 'file: template/dockerfile/Dockerfile.test-tools' "${_yaml}"
  assert_output "0"
}

# ════════════════════════════════════════════════════════════════════
# release-worker.yaml: archive composition
# ════════════════════════════════════════════════════════════════════

@test "release-worker.yaml does not cp compose.yaml into the release archive" {
  # compose.yaml has been gitignored since v0.9.0 (setup.sh-generated
  # derived artifact). Earlier release-worker.yaml wrongly included it
  # in the `cp -r` list, so every tag push hit
  # `cp: cannot stat 'compose.yaml': No such file or directory` and
  # action-gh-release never ran — ros1_bridge v1.5.0 release surfaced
  # this.
  local _yaml="/source/.github/workflows/release-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "release-worker.yaml not present in /source"
  run grep -Fc 'compose.yaml' "${_yaml}"
  # Comments explaining the omission are allowed but the cp line should
  # not reference the file; we assert the cp-list row does not mention it.
  run awk '/cp -r/,/"\$\{ARCHIVE_NAME\}\/"/{ if ($0 ~ /compose\.yaml/) found=1 } END { exit !found }' "${_yaml}"
  assert_failure
}

@test "release-worker.yaml cp-list still includes Dockerfile + scripts" {
  # Positive guard: we don't want to accidentally remove too much.
  local _yaml="/source/.github/workflows/release-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "release-worker.yaml not present in /source"
  run awk '/cp -r/,/"\$\{ARCHIVE_NAME\}\/"/' "${_yaml}"
  assert_success
  assert_output --partial 'Dockerfile'
  assert_output --partial 'build.sh'
  assert_output --partial 'template/'
}

# ════════════════════════════════════════════════════════════════════
# run.sh: XDG_SESSION_TYPE branching
# ════════════════════════════════════════════════════════════════════

@test "run.sh contains XDG_SESSION_TYPE check" {
  run grep "XDG_SESSION_TYPE" /source/script/docker/run.sh
  assert_success
}

@test "run.sh contains xhost +SI:localuser for wayland" {
  run grep 'xhost "+SI:localuser' /source/script/docker/run.sh
  assert_success
}

@test "run.sh contains xhost +local: for X11" {
  run grep 'xhost +local:' /source/script/docker/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# setup.sh: default _base_path goes up 1 level (not 2)
# ════════════════════════════════════════════════════════════════════

@test "setup.sh default _base_path uses /.." {
  # In template, setup.sh is at template/script/docker/setup.sh
  # So it should go up 1 level (/..) to reach repo root
  run grep -E '\.\./\.\.' /source/script/docker/setup.sh
  assert_success  # Should have ../../ ../../ (that was old docker_setup_helper/src/ pattern)
}

@test "setup.sh default _base_path uses double parent traversal" {
  # setup.sh resolves the script directory once via readlink -f into
  # _SETUP_SCRIPT_DIR (so invocation through the root-level symlink works),
  # then walks up `../../..` to reach the repo root. Accept either the
  # original inline BASH_SOURCE form or the _SETUP_SCRIPT_DIR indirection.
  run grep -E "(dirname.*BASH_SOURCE|_SETUP_SCRIPT_DIR).*\.\..*\.\." \
    /source/script/docker/setup.sh
  assert_success
}
