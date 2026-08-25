#!/usr/bin/env bats

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"
}

# ════════════════════════════════════════════════════════════════════
# Structure: required files exist
# ════════════════════════════════════════════════════════════════════

@test "build.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/build.sh ]
  assert [ -x /source/dist/script/docker/wrapper/build.sh ]
}

@test "run.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/run.sh ]
  assert [ -x /source/dist/script/docker/wrapper/run.sh ]
}

@test "exec.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/exec.sh ]
  assert [ -x /source/dist/script/docker/wrapper/exec.sh ]
}

@test "stop.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/stop.sh ]
  assert [ -x /source/dist/script/docker/wrapper/stop.sh ]
}

@test "setup.sh exists and is executable" {
  assert [ -f /source/dist/script/docker/wrapper/setup.sh ]
  assert [ -x /source/dist/script/docker/wrapper/setup.sh ]
}

# ════════════════════════════════════════════════════════════════════
# Structure: test.sh and justfile.test exist
# ════════════════════════════════════════════════════════════════════

@test "test.sh exists and is executable" {
  assert [ -f /source/script/test/test.sh ]
  assert [ -x /source/script/test/test.sh ]
}

@test "test.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/script/test/test.sh
  assert_success
}

# The container-ops Makefile was retired for `just`; its existence /
# build-target / upgrade-path checks live in justfile_spec.bats (static)
# + justfile_user_spec.bats (executable). The base-only CI gate
# `Makefile.ci` is likewise retired for `justfile.test`, so the repo
# carries a single runner (just); `just test <recipe>` mirrors
# the former `make -f Makefile.ci <target>`.

@test "justfile.test exists (template CI gate)" {
  assert [ -f /source/script/test/justfile.test ]
}

@test "Makefile.ci no longer exists (retired for justfile.test)" {
  assert [ ! -e /source/Makefile.ci ]
}

@test "justfile.test default recipe runs the suite (bare just test)" {
  # min->max (ADR-00000011 #3): bare `just test` runs the whole self-test,
  # so the namespace default recipe invokes test.sh.
  run grep -E '^default:' /source/script/test/justfile.test
  assert_success
  run grep -F './script/test/test.sh' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test has lint recipe" {
  # lint takes *args so it can forward --shellcheck / --hadolint
  # narrowing flags (`lint *args:`), so match the recipe name, not `lint:`.
  run grep -E '^lint( |:|\b)' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test lint recipe forwards args + runs all linters by default (#650)" {
  # `just test lint` (no flag) runs --lint (all linters: shellcheck +
  # hadolint via the test-tools container); `--shellcheck` / `--hadolint`
  # narrow. The recipe forwards {{args}} so the narrowing flags reach
  # test.sh (ADR-00000011 #3 min->max).
  run grep -E '^lint \*args:' /source/script/test/justfile.test
  assert_success
  run grep -F './script/test/test.sh --lint {{args}}' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test has coverage recipe" {
  # the recipe takes an optional shard arg (`just test coverage 1/4`)
  # for the sharded kcov path; bare `just test coverage` still runs the
  # full suite. Match the recipe header with or without the param.
  run grep -E "^coverage( shard='')?:" /source/script/test/justfile.test
  assert_success
  # bare path still drives the full-suite --coverage flag.
  run grep -F './script/test/test.sh --coverage' /source/script/test/justfile.test
  assert_success
  # shard path drives the new --coverage-shard flag.
  run grep -F './script/test/test.sh --coverage-shard' /source/script/test/justfile.test
  assert_success
}

@test "justfile.test carries no stale init/upgrade recipes at nonexistent root scripts (#779)" {
  # ADR-00000011 §8 relocated init.sh / upgrade.sh from the repo root to
  # dist/script/base/, and the `base` namespace (`just base init` /
  # `just base upgrade` / `just base update`) supersedes the former
  # `test init` / `test upgrade` / `test upgrade-check` recipes. Those
  # recipes still pointed at the vanished root ./init.sh / ./upgrade.sh,
  # so they failed immediately if invoked. Guard: justfile.test must not
  # reference the relocated root scripts (self recipes resolve to real
  # targets).
  run grep -E '\./(init|upgrade)\.sh' /source/script/test/justfile.test
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Structure: test directory layout
# ════════════════════════════════════════════════════════════════════

@test "dist smoke test_helper.bash exists under shared/" {
  assert [ -f /source/dist/test/bats/smoke/shared/test_helper.bash ]
}

@test "dist smoke shared entrypoint spec exists under shared/" {
  assert [ -f /source/dist/test/bats/smoke/shared/entrypoint.bats ]
}

@test "dist smoke script_help.bats exists under devel-test/" {
  assert [ -f /source/dist/test/bats/smoke/devel-test/script_help.bats ]
}

@test "dist smoke display_env.bats exists under devel-test/" {
  assert [ -f /source/dist/test/bats/smoke/devel-test/display_env.bats ]
}

@test "old flat dist/test/smoke/ layout is gone" {
  assert [ ! -d /source/dist/test/smoke ]
}

@test "test/bats/unit/ directory exists" {
  assert [ -d /source/test/bats/unit ]
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
# Path reference: scripts call .base/dist/script/docker/wrapper/setup.sh
# ════════════════════════════════════════════════════════════════════

# the setup.sh reference moved out of build.sh / run.sh into the
# shared setup/drift orchestration in lib/wrapper.sh (_wrapper_setup_sync),
# which build.sh and run.sh both call. Assert the reference lives at its
# new home; the per-wrapper behaviour is proven by the setup-sync unit
# specs (wrapper_lib_spec.bats) and the dispatch integration spec.
@test "lib/wrapper.sh references .base/dist/script/docker/wrapper/setup.sh (#565)" {
  run grep ".base/dist/script/docker/wrapper/setup.sh" /source/dist/script/docker/lib/wrapper.sh
  assert_success
}

@test "build.sh + run.sh route setup/drift through _wrapper_setup_sync (#565)" {
  run grep -E '_wrapper_setup_sync (build|run)' /source/dist/script/docker/wrapper/build.sh
  assert_success
  run grep -E '_wrapper_setup_sync (build|run)' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Shell conventions: set -euo pipefail
# ════════════════════════════════════════════════════════════════════

@test "build.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh supports --no-cache flag" {
  run grep -E '\-\-no-cache' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh passes --no-cache to docker compose build when set" {
  run grep -E 'NO_CACHE.*=.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)" {
  # Default behavior: do NOT auto-remove test-tools:local
  # cleanup must be conditional on CLEAN_TOOLS
  run grep -E 'CLEAN_TOOLS.*==.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh supports --clean-tools flag" {
  run grep -E '\-\-clean-tools' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "build.sh removes test-tools image when --clean-tools is set" {
  run grep -E 'CLEAN_TOOLS.*=.*true' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh uses set -euo pipefail" {
  run grep "set -euo pipefail" /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Docker compose project name (-p)
# ════════════════════════════════════════════════════════════════════

@test "lib/compose.sh is the ONLY producer of a project name (#893)" {
  # One question, one answerer. Every project name in the product comes out
  # of _resolve_project_name in lib/compose.sh: setup's apply calls it to
  # record PROJECT_NAME in .env.generated, and the wrapper calls it only
  # when there is no .env.generated to read at all. A second place that
  # assembles `<hub>-<image>` is the shape this replaces, so no other
  # shipped file may build one.
  run grep -E '^_resolve_project_name\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success

  # The shape being outlawed is the JOIN itself -- `${...HUB...}-${...IMAGE...}`
  # in either order. An image TAG (`${HUB}/${IMAGE}`) is a different figure
  # and stays where it is.
  local _hit
  _hit="$(grep -rlE '(DOCKER_HUB_USER[^}]*\}-\$\{[^}]*IMAGE_NAME)|(IMAGE_NAME[^}]*\}-\$\{[^}]*DOCKER_HUB_USER)' \
            /source/dist --include='*.sh' --include='*.yaml' \
          | grep -v '/lib/compose\.sh$' || true)"
  [[ -z "${_hit}" ]] || {
    echo "a second place assembles a project name: ${_hit}"
    false
  }
}

# Wrapper -> compose dispatch is asserted by observed behaviour in
# test/integration/wrapper_compose_dispatch_spec.bats: each wrapper
# is run with --dry-run and the planned `docker compose -p <project> <verb>`
# is checked (incl. the -p flag, catching a raw-`docker compose` bypass).
# The old name-coupled greps for `_compose_project` here were removed —
# they broke on every internal rename (shim, rename) and could
# not catch a bypass.

@test "exec.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh loads .env via _load_env helper" {
  run grep -E '_load_env .*\.env' /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "lib/env.sh defines _load_env helper" {
  run grep -E '^_load_env\(\)' /source/dist/script/docker/lib/env.sh
  assert_success
}

@test "lib/compose.sh defines _compute_project_name helper" {
  run grep -E '^_compute_project_name\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success
}

@test "lib/compose.sh defines _compose wrapper" {
  run grep -E '^_compose\(\)' /source/dist/script/docker/lib/compose.sh
  assert_success
}

@test "stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)" {
  # v0.6.6: run.sh devel switched to compose up + exec, so no more orphan
  # containers from `compose run --name`. The orphan cleanup line is removed.
  run grep -E 'docker rm.*-f.*IMAGE_NAME' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
}

@test "run.sh devel target uses compose up -d (not compose run --name)" {
  # Regression: foreground devel previously used `compose run --name` which
  # created a one-off container that `./exec.sh` (compose exec) couldn't see,
  # producing "service devel is not running". Switched to up + exec.
  run grep -E 'up -d' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh devel branch uses compose exec to enter shell" {
  run grep -E '_compose_project exec' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# run.sh foreground EXIT-trap cleanup (auto compose-down with
# --remove-orphans -t 0) is asserted by observed behaviour in
# wrapper_compose_dispatch_spec.bats via the dry-run output, instead
# of grepping the `_app_cleanup` identifier (renamed in).

@test "run.sh non-devel TARGET: foreground 'up', CMD-override 'run --rm' (#458/#679)" {
  # non-devel + no CMD uses foreground `compose up` so container_name
  # takes effect (Dockerfile CMD runs).
  run grep -E 'up "?\$\{TARGET\}"?' /source/dist/script/docker/wrapper/run.sh
  assert_success
  # non-devel + CMD uses `compose run --rm` so the ENTRYPOINT runs
  # (env/ROS sourced) and the override REPLACES the default CMD. The
  # `up -d` + `exec` pair bypassed the ENTRYPOINT and
  # double-launched the default CMD.
  run grep -E '_compose_project run --rm "\$\{TARGET\}"' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh devel branch does not use 'compose run --name'" {
  # The old buggy pattern must be gone for devel; only run --rm for one-shots
  run grep -E 'run .*--name' /source/dist/script/docker/wrapper/run.sh
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# single-instance container naming
# ════════════════════════════════════════════════════════════════════

@test "run.sh refuses when the default container is already running" {
  # The script should grep docker ps for an existing container with the
  # default name and exit non-zero with a helpful message.
  run grep -E 'already running|already exists' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "base is single-instance: no --instance flag remains (#600)" {
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/run.sh
  assert_failure
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/exec.sh
  assert_failure
  run grep -E '\-\-instance' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
}

@test "base is single-instance: no INSTANCE_SUFFIX remains (#600)" {
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/run.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/exec.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/stop.sh
  assert_failure
  run grep -E 'INSTANCE_SUFFIX' /source/dist/script/docker/wrapper/setup.sh
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# --dry-run flag (PR B)
# ════════════════════════════════════════════════════════════════════

@test "build.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh supports --dry-run flag" {
  run grep -E '\-\-dry-run' /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "build.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/build.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "run.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/run.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "exec.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/exec.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

@test "stop.sh -h shows --dry-run in help" {
  run bash -c "bash /source/dist/script/docker/wrapper/stop.sh -h 2>&1"
  assert_output --partial "--dry-run"
}

# ════════════════════════════════════════════════════════════════════
# exec.sh container precheck (PR B)
# ════════════════════════════════════════════════════════════════════

@test "exec.sh checks container is running before exec" {
  # The precheck asks the shared probe rather than spelling `docker ps`
  # inline: run.sh asks the identical question, and the two inline copies
  # were identical down to the `| grep -qx` that made both of them answer
  # backwards. Assert the seam from both ends -- exec.sh calls the probe,
  # and the probe is the thing that queries the daemon -- so this stays a
  # check that the precheck EXISTS rather than a pin on where the string
  # `docker ps` happens to sit today.
  run grep -F '_wrapper_container_running' /source/dist/script/docker/wrapper/exec.sh
  assert_success
  run grep -E 'docker (ps|inspect)' /source/dist/script/docker/lib/wrapper.sh
  assert_success
}

@test "exec.sh precheck error mentions run.sh hint" {
  # Friendly error pointing user at ./run.sh
  run grep -E 'run\.sh' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "exec.sh exits non-zero with friendly hint when container not running" {
  # Simulate a tmp repo with .env so exec.sh gets past _load_env, then call
  # without docker on PATH so the precheck fails (no container can be found).
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env.generated" <<EOF
USER_NAME=alice
DOCKER_HUB_USER=alice
IMAGE_NAME=missing-image-$$
EOF
  mkdir -p "${_tmp}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${_tmp}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${_tmp}/.base/dist/script/docker/lib/i18n.sh" 2>/dev/null || true
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${_tmp}/.base/dist/script/docker/lib/"
  cp /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh"
  assert_failure
  assert_output --partial "is not running"
  assert_output --partial "run.sh"
  rm -rf "${_tmp}"
}

@test "exec.sh --dry-run skips precheck and prints compose command" {
  local _tmp
  _tmp="$(mktemp -d)"
  cat > "${_tmp}/.env.generated" <<EOF
USER_NAME=alice
DOCKER_HUB_USER=alice
IMAGE_NAME=ghost-$$
EOF
  mkdir -p "${_tmp}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${_tmp}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${_tmp}/.base/dist/script/docker/lib/i18n.sh" 2>/dev/null || true
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${_tmp}/.base/dist/script/docker/lib/"
  cp /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"

  run bash "${_tmp}/exec.sh" --dry-run
  assert_success
  assert_output --partial "[dry-run] docker compose"
  assert_output --partial "exec"
  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# i18n.sh shared module
# ════════════════════════════════════════════════════════════════════

@test "dist/script/docker/lib/i18n.sh exists" {
  assert [ -f /source/dist/script/docker/lib/i18n.sh ]
}

@test "Dockerfile.test-tools includes bats-mock" {
  run grep 'bats-mock' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools installs just (justfile entry-point execution in CI)" {
  # The test-tools image must carry `just` so justfile_user_spec /
  # upgrade-check can exercise the entry point for real.
  run grep -E 'apk add .*\bjust\b' /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools source-builds kcov in a builder stage (#686)" {
  # kcov is not packaged in any alpine repo, so it is compiled from source
  # in a discardable builder stage and COPY'd into the final image. This
  # lets the coverage matrix run on the same one-pull test-tools image as
  # the rest of the suite (no debian kcov/kcov, no per-shard apt-install).
  run grep -E '^FROM alpine:\$\{ALPINE_VERSION\} AS kcov-builder' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools COPYs the kcov binary into the final image (#686)" {
  run grep -E '^COPY --from=kcov-builder .*kcov' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools installs kcov's runtime shared libs in the final stage (#686)" {
  # The source-built kcov binary links against these runtime libs; without
  # them it fails to load (verified via ldd in the spike). Pin them so
  # a refactor that drops one surfaces as a test failure, not a runtime
  # crash on the first coverage shard.
  run grep -E '^[[:space:]]+libstdc\+\+ libcurl libdw libelf zlib libgcc' \
    /source/dockerfile/Dockerfile.test-tools
  assert_success
}

@test "Dockerfile.test-tools no longer installs make into the final image (single runner: just)" {
  # make was retired with Makefile.ci; the integration tests now exercise
  # the downstream justfile (`just upgrade-check`), so the dead make
  # dependency must not creep back into the FINAL image. The kcov-builder
  # stage legitimately apk-adds make to compile kcov, but that
  # stage is discarded — only its /usr/local/bin/kcov is COPY'd out — so
  # scope this guard to the final-stage apk add line (the one that also
  # installs bash + parallel), not the whole file.
  run grep -E 'apk add .*\bbash\b.*\bmake\b|apk add .*\bmake\b.*\bbash\b' \
    /source/dockerfile/Dockerfile.test-tools
  assert_failure
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

@test "Dockerfile.test-tools curl release downloads retry on transient failure (#550)" {
  # The shellcheck + hadolint binaries are fetched from github.com release
  # CDN at build time; a transient 504 there used to fail the whole build
  # first-hit (no retry). Every curl that pulls a release must use
  # --retry-all-errors so a 504/timeout retries transparently instead of
  # blocking every code PR's CI on a release-CDN hiccup.
  local _n
  _n="$(grep -cE 'curl .*--retry-all-errors' /source/dockerfile/Dockerfile.test-tools)"
  # both the shellcheck tarball and the hadolint binary downloads
  [ "${_n}" -ge 2 ]
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
  run grep -E '^_detect_lang\(\)' /source/dist/script/docker/lib/i18n.sh
  assert_success
}

@test "build.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/dist/script/docker/wrapper/build.sh
  assert_success
}

@test "run.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "exec.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/dist/script/docker/wrapper/exec.sh
  assert_success
}

@test "stop.sh sources _lib.sh" {
  run grep -E 'source.*_lib\.sh' /source/dist/script/docker/wrapper/stop.sh
  assert_success
}

@test "_lib.sh sources i18n.sh (delegates language detection)" {
  run grep -E 'source.*i18n\.sh' /source/dist/script/docker/lib/_lib.sh
  assert_success
}

@test "setup.sh sources i18n.sh" {
  run grep -E 'source.*i18n\.sh' /source/dist/script/docker/wrapper/setup.sh
  assert_success
}

_stage_lint_layout() {
  local _dest="${1:?}" _script="${2:?}"
  mkdir -p "${_dest}/wrapper" "${_dest}/lib"
  cp "/source/dist/script/docker/wrapper/${_script}" "${_dest}/wrapper/${_script}"
  cp /source/dist/script/docker/lib/* "${_dest}/lib/"
}

@test "build.sh -h works in /lint/ layout (flat dir with _lib.sh + i18n.sh, issue #104)" {
  # After we no longer carry inline _detect_lang fallbacks; the
  # /lint/ stage COPY must include _lib.sh and i18n.sh alongside.
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" build.sh
  run bash "${_tmp}/wrapper/build.sh" -h
  assert_success
  assert_output --partial "Usage"
  rm -rf "${_tmp}"
}

@test "run.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" run.sh
  run bash "${_tmp}/wrapper/run.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "exec.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" exec.sh
  run bash "${_tmp}/wrapper/exec.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "stop.sh -h works in /lint/ layout" {
  local _tmp
  _tmp="$(mktemp -d)"
  _stage_lint_layout "${_tmp}" stop.sh
  run bash "${_tmp}/wrapper/stop.sh" -h
  assert_success
  rm -rf "${_tmp}"
}

@test "build.sh errors with a clear diagnostic when bootstrap/_lib.sh missing (issue #104, #408)" {
  # build.sh copied alone (no lib/bootstrap.sh, no _lib.sh) -> explicit
  # non-zero exit + a clear broken-install diagnostic. the
  # shared preamble lives in lib/bootstrap.sh (which in turn sources
  # _lib.sh), so the first missing dependency reported is bootstrap.sh.
  # Better UX than a cryptic `_bootstrap: command not found`.
  local _tmp
  _tmp="$(mktemp -d)"
  cp /source/dist/script/docker/wrapper/build.sh "${_tmp}/build.sh"
  run bash "${_tmp}/build.sh" -h
  assert_failure
  assert_output --partial "cannot find lib/bootstrap.sh"
  rm -rf "${_tmp}"
}

@test "Dockerfile.example copies lib/ and wrapper/ into /lint/ (#406)" {
  run grep -F '.base/dist/script/docker/lib /lint/lib' /source/dist/dockerfile/Dockerfile
  assert_success
  run grep -F '.base/dist/script/docker/wrapper /lint/wrapper' /source/dist/dockerfile/Dockerfile
  assert_success
}

@test "Dockerfile.example copies logging.sh to /usr/local/lib/base/ in devel stage (#368)" {
  # PR documented the source-line example as
  # `. /home/${USER}/work/.base/dist/script/docker/runtime/logging.sh`,
  # which has two failure modes that broke every v0.30.0 adopter:
  # (1) $USER is unset/empty in the Dockerfile test stage, crashing
  # `set -u` entrypoints; (2) on multi-repo workspaces WS_PATH is the
  # workspace parent, not the repo root, so .base/ is never at the
  # documented path. Path A: COPY the helper into a stable in-image
  # location so downstream entrypoints can source it unconditionally
  # without $USER deref or path arithmetic.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}"
  assert_success
  # COPY must sit in devel stage (between `FROM ... AS devel` and the
  # devel-test FROM line); a placement inside the commented runtime
  # block is also documented but devel is the canonical site.
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example commented runtime stage shows logging.sh COPY example (#368)" {
  # The optional runtime stage starts from a fresh BASE_IMAGE, not
  # FROM devel, so the helper is NOT inherited. Repos that ship a
  # runtime image and want host-side log tee must opt in via a
  # second COPY in the runtime stage. The commented-out scaffold
  # documents it so downstream maintainers see the requirement at
  # the moment they uncomment the runtime block.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The example line must be commented (leading '# ') so it doesn't
  # accidentally activate in repos that haven't enabled the runtime
  # stage. Either inside the runtime-base/runtime block or the
  # documentation block above it.
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/logging.sh /usr/local/lib/base/logging.sh' "${_df}"
  assert_success
}

@test "runtime/logging.sh header documents in-image source-line (no \$USER, no work/.base) (#368)" {
  # The helper's own Usage block is the canonical reference downstream
  # entrypoint authors copy from. the example was
  # `. /home/${USER}/work/.base/dist/script/docker/runtime/logging.sh`
  # which only works on a single-repo workspace AND only at runtime
  # AFTER the compose bind mount lands -- failing at build-time smoke
  # and on multi-repo workspace layouts. Header must show the
  # in-image path instead, with no $USER deref and no work/.base
  # prefix.
  local _h="/source/dist/script/docker/runtime/logging.sh"
  # Positive: header documents the stable in-image path.
  run grep -F '#   . /usr/local/lib/base/logging.sh' "${_h}"
  assert_success
  # Negative regression guards: the broken patterns must not
  # reappear anywhere in the helper file (header, comments, or code).
  run grep -F '${USER}/work/.base/dist/script/docker/runtime/logging.sh' "${_h}"
  assert_failure
  run grep -F '/home/${USER}/work/.base' "${_h}"
  assert_failure
}

@test "Dockerfile.example copies logrotate.sh to /usr/local/lib/base/ in devel stage (#805)" {
  # runtime/logging.sh sources its sibling logrotate.sh from the same
  # in-image dir, so the shared rotate/symlink/prune helper must be COPY'd
  # alongside logging.sh (same devel-stage window) or the container tee
  # degrades to no rotation/prune.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}"
  assert_success
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example copies watchdog.sh to /usr/local/lib/base/ in devel stage (#797)" {
  # The generic watchdog ships runtime/watchdog.sh, sourced from the
  # repo entrypoint alongside logging.sh. It must be COPY'd into the same
  # in-image dir (devel stage, before devel-test) so the source line
  # resolves at build + run time.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -F 'COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}"
  assert_success
  local _devel_line _test_line _copy_line
  _devel_line="$(grep -nE '^FROM devel-base AS devel$' "${_df}" | head -1 | cut -d: -f1)"
  _test_line="$(grep -nE '^FROM \$\{TEST_TOOLS_IMAGE\} AS test-tools-stage' "${_df}" | head -1 | cut -d: -f1)"
  _copy_line="$(grep -nF 'COPY --chmod=0755 .base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}" | head -1 | cut -d: -f1)"
  [[ -n "${_devel_line}" && -n "${_test_line}" && -n "${_copy_line}" ]]
  (( _devel_line < _copy_line ))
  (( _copy_line < _test_line ))
}

@test "Dockerfile.example commented runtime stage shows watchdog.sh COPY example (#797)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/watchdog.sh /usr/local/lib/base/watchdog.sh' "${_df}"
  assert_success
}

@test "runtime/entrypoint.sh sources the watchdog helper after logging (#797)" {
  # The template entrypoint sources logging.sh then watchdog.sh; both are
  # no-ops when their feature is off, so the source lines are safe. Order
  # matters: watchdog logs should ride the logging tee.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  run grep -F '. /usr/local/lib/base/watchdog.sh' "${_ep}"
  assert_success
  local _log_line _wd_line
  _log_line="$(grep -nF '. /usr/local/lib/base/logging.sh' "${_ep}" | head -1 | cut -d: -f1)"
  _wd_line="$(grep -nF '. /usr/local/lib/base/watchdog.sh' "${_ep}" | head -1 | cut -d: -f1)"
  [[ -n "${_log_line}" && -n "${_wd_line}" ]]
  (( _log_line < _wd_line ))
}

@test "runtime/entrypoint.sh guards both lib sources with a readability test (#842)" {
  # The runtime stage's logging/watchdog COPYs are opt-in and init.sh seeds
  # this entrypoint verbatim into every repo, so an image that skipped them
  # must not source a missing file on every start. Same `[[ -r ]]` shape the
  # libs already use for their own sibling logrotate.sh source.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  run grep -F 'if [[ -r /usr/local/lib/base/logging.sh ]]; then' "${_ep}"
  assert_success
  run grep -F 'if [[ -r /usr/local/lib/base/watchdog.sh ]]; then' "${_ep}"
  assert_success
}

@test "runtime/entrypoint.sh execs cleanly under set -euo pipefail with the libs absent (#842)" {
  # The observable half of the guard: with neither helper installed the
  # entrypoint must still reach `exec` -- no missing-file stderr, and no
  # abort for a consumer running the documented strict-mode entrypoint.
  local _ep="/source/dist/script/docker/runtime/entrypoint.sh"
  if [[ -e /usr/local/lib/base/logging.sh || -e /usr/local/lib/base/watchdog.sh ]]; then
    skip "runtime libs installed in this image -- absent-lib path not observable"
  fi
  local _err="${BATS_TEST_TMPDIR}/entrypoint.err"
  run bash -c 'bash -euo pipefail "$1" printf ok 2>"$2"' _ "${_ep}" "${_err}"
  assert_success
  assert_output "ok"
  assert_equal "$(cat "${_err}")" ""
}

@test "Dockerfile.example commented runtime stage shows logrotate.sh COPY example (#805)" {
  # The optional runtime stage is a fresh BASE_IMAGE (no devel inherit), so
  # a repo enabling host-side log tee there must COPY BOTH logging.sh and
  # its logrotate.sh sibling; the commented scaffold documents both.
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -E '^# COPY --chmod=0755 \.base/dist/script/docker/runtime/logrotate.sh /usr/local/lib/base/logrotate.sh' "${_df}"
  assert_success
}

@test "no inline _detect_lang fallbacks remain after dedupe (issue #104)" {
  # Lock in: only i18n.sh defines _detect_lang. build.sh / run.sh /
  # exec.sh / stop.sh / _lib.sh previously shipped their own copies,
  # which drifted ('s zh→zh-TW typo) — a single-source
  # definition prevents further drift.
  local _count
  _count="$(grep -cE '^_detect_lang\(\)' \
    /source/dist/script/docker/wrapper/build.sh \
    /source/dist/script/docker/wrapper/run.sh \
    /source/dist/script/docker/wrapper/exec.sh \
    /source/dist/script/docker/wrapper/stop.sh \
    /source/dist/script/docker/lib/_lib.sh \
    /source/dist/script/docker/wrapper/setup.sh \
    | awk -F: '{sum += $2} END {print sum}')"
  [ "${_count}" = "0" ]

  # i18n.sh must still have exactly one definition.
  run grep -cE '^_detect_lang\(\)' /source/dist/script/docker/lib/i18n.sh
  assert_output "1"
}

@test "setup.sh does not redefine _detect_lang" {
  # setup.sh is not COPY'd into consumer /lint stage, so no fallback needed
  run grep -cE '^_detect_lang\(\)' /source/dist/script/docker/wrapper/setup.sh
  assert_output "0"
}

@test "setup.sh defines _setup_msg, not _msg (closes #101)" {
  # Regression forbuild.sh / run.sh source setup.sh to obtain
  # `_check_setup_drift`. setup.sh used to define a top-level `_msg`
  # with a smaller key set than the caller's, silently shadowing it
  # post-source. Subsequent `_msg drift_regen` returned empty and
  # `printf "%s\n" ""` ate the drift-regen status line on every fresh-
  # host / setup.conf-changed run. Defensive namespacing fix: rename
  # to `_setup_msg`. Future helpers in setup.sh should follow the
  # `_setup_*` prefix convention to keep this immune.
  run grep -cE '^_msg\(\) \{' /source/dist/script/docker/wrapper/setup.sh
  assert_output "0"
  run grep -cE '^_setup_msg\(\) \{' /source/dist/script/docker/wrapper/setup.sh
  assert_output "1"
}

@test "build.sh _msg keys survive sourcing setup.sh (#101 behavioral)" {
  # Behavioral guard: source setup.sh in a subshell that already has a
  # top-level _msg with rich keys (mirrors what build.sh / run.sh used
  # to do in the drift-check branch pre-B-1) and assert the rich keys
  # still resolve afterward. Prior to fix, setup.sh's _msg shadowed
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
    source /source/dist/script/docker/wrapper/setup.sh </dev/null >/dev/null 2>&1 || true
    _msg drift_regen
  '
  assert_success
  assert_output "regenerating"
}

@test "build.sh does not source setup.sh (#49 Phase B-1)" {
  # Structural guard for the fix: B-1 replaced build.sh's
  # `source "${_setup}"` + `_check_setup_drift "${FILE_PATH}"` with a
  # subprocess call (`bash setup.sh check-drift --base-path ... --lang ...`).
  # No future change should put `source` back — that would reopen the
  # entire shadow-bug class even if _msg vs _setup_msg stays clean.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/dist/script/docker/wrapper/build.sh
  assert_output "0"
}

@test "run.sh does not source setup.sh (#49 Phase B-1)" {
  # Mirror of build.sh structural guard above.
  run grep -cE '^[[:space:]]*source[[:space:]]+"\$\{_setup\}"' /source/dist/script/docker/wrapper/run.sh
  assert_output "0"
}

# the subprocess check-drift invocation moved into the shared
# _wrapper_setup_sync (lib/wrapper.sh), which build.sh + run.sh both call.
# Positive guard: it must invoke setup.sh via subprocess with the
# check-drift subcommand instead of sourcing it.
@test "lib/wrapper.sh uses subprocess check-drift (#49 Phase B-1, #565)" {
  run grep -cE '"\$\{_setup\}"[[:space:]]+check-drift' /source/dist/script/docker/lib/wrapper.sh
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

@test "upgrade.sh reads version from <subtree-prefix>/.version" {
  # Post-v0.25.0 the subtree prefix is parameterised (TEMPLATE_REL) so
  # the rename `.base/` -> `.base/` works without code change. Assert
  # the parameterised form rather than the literal `.base/` prefix.
  run grep -F '${TEMPLATE_REL}/.version' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh does not reference legacy VERSION or .template_version" {
  # After the .version rename, upgrade.sh must not mention either
  # legacy filename — no backward-compat fallback is carried.
  run grep -cE '.base/VERSION|\.template_version' /source/dist/script/base/upgrade.sh
  assert_failure
  assert_output "0"
}

@test "upgrade.sh runs init.sh after subtree pull" {
  run grep -E 'init\.sh' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh supports --gen-conf flag" {
  run grep -E '\-\-gen-conf' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh --gen-conf delegates to init.sh --gen-conf" {
  run grep -E 'init\.sh.*--gen-conf' /source/dist/script/base/upgrade.sh
  assert_success
}

@test "upgrade.sh --help mentions --gen-conf" {
  run bash -c "bash /source/dist/script/base/upgrade.sh --help 2>&1"
  assert_success
  assert_output --partial "--gen-conf"
}

@test "upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml" {
  # Regression: a greedy sed pattern .*@v[0-9.]* matched both build-worker
  # and release-worker references, replacing both with build-worker.yaml@<ver>
  local _tmp _yaml
  _tmp="$(mktemp -d)"
  _yaml="${_tmp}/main.yaml"
  mkdir -p "${_tmp}/.base" "${_tmp}/.github/workflows"
  cat > "${_yaml}" <<'EOF'
jobs:
  call-docker-build:
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.5.0
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.5.0
EOF
  # Source upgrade.sh and exercise just the sed block by inlining the
  # production sed commands here, mirroring what upgrade.sh does.
  # We do this by extracting and running the sed commands from upgrade.sh.
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
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
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.10.0-rc1
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.10.0-rc1
EOF
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
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
    uses: ycpss91255-docker/base/.github/workflows/build-worker.yaml@v0.10.0-rc2
  call-release:
    uses: ycpss91255-docker/base/.github/workflows/release-worker.yaml@v0.9.9
EOF
  local _seds
  # Narrow the sed extract to main_yaml-targeted lines. upgrade.sh also
  # only mutates main_yaml directly via sed (Step-5 Dockerfile healing now
  # lives in lib/dockerfile_migrate.sh,); the substitution
  # below only knows how to fill in main_yaml + target_ver, so feeding it
  # a Dockerfile sed would `eval sed -i ... ""` with an empty filename.
  _seds="$(grep -E '^[[:space:]]*sed -i.*main_yaml' /source/dist/script/base/upgrade.sh)"
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

@test "build-worker.yaml: devel-test build passes TEST_TOOLS_IMAGE from inputs" {
  local _yaml="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "build-worker.yaml not present in /source"
  # the step was named "Build test stage"; renamed to
  # "Build devel-test stage" for symmetry with the new runtime-test
  # stage. The TEST_TOOLS_IMAGE plumbing didn't move.
  run awk '
    /- name: Build devel-test stage/ { inside = 1 }
    inside && /^[[:space:]]*- name:/ && !/Build devel-test stage/ { inside = 0 }
    inside { print }
  ' "${_yaml}"
  assert_success
  # build-arg must wire inputs.test_tools_version into the ghcr tag
  assert_output --partial 'TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:${{ inputs.test_tools_version }}'
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: TEST_TOOLS_IMAGE ARG + named stage
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example has ARG TEST_TOOLS_IMAGE with no bare test-tools:local default" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # No bare, version-agnostic default: build.sh (local) and CI both pass
  # a version-scoped TEST_TOOLS_IMAGE explicitly, so an unset value fails
  # the build loudly instead of silently reusing a stale test-tools:local.
  run grep -E '^ARG TEST_TOOLS_IMAGE$' "${_df}"
  assert_success
  run grep -E '^ARG TEST_TOOLS_IMAGE=' "${_df}"
  assert_failure
}

@test "Dockerfile.example FROM \${TEST_TOOLS_IMAGE} AS test-tools-stage" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -F 'FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage' "${_df}"
  assert_success
}

@test "Dockerfile.example test stage copies from test-tools-stage, not test-tools:local" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # All ACTIVE COPY --from referring to the test-tools image must use
  # the named stage alias. Count only uncommented lines -- added a
  # commented-out runtime-test Bats COPY example (style (b)) which would
  # otherwise inflate the count.
  run grep -cE '^COPY --from=test-tools-stage' "${_df}"
  # 4 active copies expected (all in devel-test): shellcheck, hadolint,
  # /opt/bats, /usr/lib/bats.
  assert_output "4"
  # Legacy tag reference must be gone:
  run grep -c 'COPY --from=test-tools:local' "${_df}"
  assert_output "0"
}

# ──generalized -test toolchain pattern ────────────────────────

@test "Dockerfile.example runtime-test shows commented Bats COPY from test-tools-stage (#647)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The generalized rule: runtime-test gains an opt-in Bats smoke
  # via the SAME COPY --from=test-tools-stage devel-test uses, staying
  # FROM runtime. The example must be commented (leading '# ') so it
  # doesn't activate in repos that haven't opted in.
  run grep -E '^# COPY --from=test-tools-stage /opt/bats /opt/bats$' "${_df}"
  assert_success
  run grep -E '^# COPY --from=test-tools-stage /usr/lib/bats /usr/lib/bats$' "${_df}"
  assert_success
  # Anti-pattern guard: NO -test stage may be FROM ${TEST_TOOLS_IMAGE};
  # only the test-tools-stage alias itself is (one line).
  run grep -cE '^FROM \$\{TEST_TOOLS_IMAGE\}' "${_df}"
  assert_output "1"
}

@test "Dockerfile.example documents -test stages stay FROM the real stage + heavier-is-fine (#647)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The header must state the generalized rule and the anti-pattern.
  run grep -F 'Do NOT' "${_df}"
  assert_success
  run grep -F 'make any `-test` stage `FROM ${TEST_TOOLS_IMAGE}`' "${_df}"
  assert_success
  # -test stages may be heavier than shipped stages (never reach users).
  run grep -F 'never reach users' "${_df}"
  assert_success
  # Flavour tooling is the consumer's responsibility, not a base image.
  run grep -F "CONSUMER's responsibility" "${_df}"
  assert_success
}

# ── baked artifacts live at /opt, not under $HOME ──────────────

@test "Dockerfile.example states the /opt-not-\$HOME baking convention (#799)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The convention has to be stated where a downstream author meets it --
  # the file they edit to bake a workspace -- not only in base's own docs.
  run grep -F 'bake self-built artifacts at an ABSOLUTE /opt/' "${_df}"
  assert_success
  # Rule 2: the SOURCE line must name the absolute path, never ~ / $HOME.
  run grep -F 'source the ABSOLUTE path' "${_df}"
  assert_success
  # A ~/x -> /opt/x symlink is allowed for discoverability but must not be
  # what anything sources.
  run grep -F 'convenience symlink' "${_df}"
  assert_success
  # Rule 3 plus its enforcement handle, so the reader can run the gate.
  run grep -F 'just test lint --home-literal' "${_df}"
  assert_success
  # The recorded rationale, so the WHY does not have to live in the comment.
  run grep -F 'ADR-00000024' "${_df}"
  assert_success
}

@test "build-worker.yaml: runtime-test build forwards TEST_TOOLS_IMAGE (#647 prerequisite)" {
  # When runtime-test does COPY --from=test-tools-stage, test-tools
  # enters its build graph, so its build must receive the pinned
  # TEST_TOOLS_IMAGE just like devel-test (else FROM ${TEST_TOOLS_IMAGE}
  # falls back to test-tools:local and CI fails with pull-access-denied).
  local _wf="/source/.github/workflows/build-worker.yaml"
  [[ -f "${_wf}" ]] || skip "build-worker.yaml not present in /source"
  # Two forwards expected: devel-test and runtime-test build steps.
  run grep -cE '^            TEST_TOOLS_IMAGE=ghcr\.io/ycpss91255-docker/test-tools:\$\{\{ inputs\.test_tools_version \}\}$' "${_wf}"
  assert_output "2"
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: runtime-test stage syntax (v0.21.1 fix /
# v0.23.1 follow-up)
#
# v0.21.0 shipped the runtime-test block with `RUN ${RUNTIME_SMOKE_CMD}`
# and `USER root`. Both were buggy:
#   1. Bare `RUN ${ARG}` word-splits the substituted value: shell
#      operators (&&, ||) and nested quotes get treated as literal
#      args to the first command. Concrete failure: with default
#      ARG `bash -lc "whoami && bash --version && exit 0"`, bash
#      tokenized as `whoami '&&' bash '--version'` and whoami saw
#      `--version` as an arg, printing its own version info instead
#      of running the chain. Discovered during sick_humble's manual
#      v0.21.0 rollout.
#   2. `USER root` triggered hadolint DL3002 (last USER should not
#      be root). runtime-test is ephemeral, but hadolint can't
#      know that; the lint failure was real.
#
# v0.21.1 fix: drop USER root (inherit non-root from runtime), and
# wrap the ARG in `sh -c "..."` so the value is passed as a single
# string for the shell to parse.
#
# v0.23.1 follow-up: `sh -c` (dash) doesn't support `source` or
# bash parameter expansion, blocking any override that sourced
# bash-syntax files (e.g. `. /opt/ros/$DISTRO/setup.bash`). Switched
# to `bash -c` -- bash is present in every Ubuntu/Debian runtime
# image the template targets, the dependency is safe, and downstream
# overrides can now use natural shell semantics. Discovered during
# the v0.21.1 runtime-test framework's downstream rollout
# (ycpss91255-docker/docker_harness#57); see also
# ycpss91255-docker/template#249.
#
# The grep tests below lock all three invariants (positive: bash -c
# wrapper present; negative: no bare ARG substitution; negative:
# no stale sh -c wrapper) so the bug can't regress.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example runtime-test uses bash -c wrapper (regression: #243 word-split + #57 dash-source bugs)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The runtime-test block is commented out (opt-in for repos with a
  # runtime stage). The RUN line in the comment must use bash -c so
  # downstream RUNTIME_SMOKE_CMD overrides can use bash semantics
  # (source / . of bash-syntax files, parameter expansion, etc.).
  run grep -E '^# RUN bash -c "\$\{RUNTIME_SMOKE_CMD\}"$' "${_df}"
  assert_success
}

@test "Dockerfile.example runtime-test does NOT use bare RUN \${RUNTIME_SMOKE_CMD} (v0.21.0 word-split regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Regression guard: bare form word-splits operators / nested quotes.
  run grep -E '^# RUN \$\{RUNTIME_SMOKE_CMD\}$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "Dockerfile.example runtime-test does NOT use sh -c wrapper (v0.21.1 -> v0.23.1 dash-source regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Regression guard: sh -c (dash) cannot parse bash-syntax files in
  # `source` / `.` overrides. Blocks all ROS-style smoke commands.
  # See ycpss91255-docker/docker_harness#57 + for context.
  run grep -E '^# RUN sh -c "\$\{RUNTIME_SMOKE_CMD\}"$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

@test "Dockerfile.example runtime-test does NOT set USER root (DL3002 regression guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Hadolint DL3002 fires on `USER root` if it ends up the last USER
  # in the Dockerfile. runtime-test inherits non-root from runtime;
  # leave it that way. Downstream override via sudo if privileged
  # smoke is genuinely needed.
  #
  # Match the commented-out form in Dockerfile.example.
  run grep -E '^# USER root$' "${_df}"
  [ "${status}" -ne 0 ] || [ -z "${output}" ]
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: builder + runtime split pattern
#
# Lifts the three lessons proven empirically in
# ycpss91255-docker/ros1_bridge#60 (saved ~1.1 GB/arch on runtime):
#   1. runtime MUST NOT be FROM devel -- forces devel to delete its
#      own source to avoid runtime bloat, breaking the dev workflow.
#   2. Runtime apt: install only the ldd-identified missing libs.
#      Bulk-installing builder deps defeats the runtime/devel split.
#   3. `source FILE` in entrypoints needs trailing `--` (ROS 1 catkin
#      / _setup_util.py argparse pitfall when CMD has --flag args).
#
# Tests below grep for marker text proving each lesson is documented
# inline so the commented-out reference pattern can't silently lose
# them.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example top stage-list documents builder stage (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The top-of-file "Stages:" comment is the first thing a user
  # reading the template sees. builder must appear there or the
  # downstream pattern is invisible.
  run grep -E '^#   builder ' "${_df}"
  assert_success
}

@test "Dockerfile.example documents 3 builder/runtime split lessons (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Three explicit lesson markers (text must persist verbatim in
  # the commented-out reference block so the lift from ros1_bridge#60
  # stays load-bearing).
  run grep -F 'runtime` MUST NOT be `FROM devel`' "${_df}"
  assert_success
  run grep -F 'install only the libs `ldd` proves are missing' "${_df}"
  assert_success
  run grep -F 'source FILE` in entrypoints needs a trailing `--`' "${_df}"
  assert_success
}

@test "Dockerfile.example has commented-out builder + runtime + COPY --from=builder reference (#239)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The concrete commented-out skeleton downstream can uncomment.
  # All three lines must be commented (#-prefixed) so the example
  # doesn't try to build by default; downstream uncomments when
  # opting in via main.yaml build_runtime: true.
  run grep -E '^# FROM devel-base AS builder$' "${_df}"
  assert_success
  run grep -E '^# FROM \$\{BASE_IMAGE\} AS runtime-base$' "${_df}"
  assert_success
  run grep -E '^# COPY --from=builder ' "${_df}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: runtime interactive-shell env source
#
# The minimal runtime stage does NOT inherit devel's ~/.bashrc +
# ~/.bashrc.d/ wiring, so `docker exec -it <runtime> bash`
# (`just exec -t runtime bash`) gets none of the repo env (e.g. ROS
# `ros2`). The runtime block must document, as an OPTIONAL opt-in, the
# lightweight one-line /etc/bash.bashrc source so interactive exec
# shells in runtime pick up the env -- WITHOUT dragging the full config/
# COPY into the minimal runtime, and WITHOUT baking env into Dockerfile
# ENV. The ROS-specific source line belongs downstream (base is
# ROS-agnostic). Tests below grep for the documented marker + example
# line so the pattern can't silently disappear.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example runtime documents 3-process-kinds env rationale (#657)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The rationale must explain why entrypoint (PID 1) and bashrc
  # (interactive) are complementary, both needed -- so a future edit
  # doesn't collapse the runtime gap into a wrong "fix the entrypoint".
  run grep -F 'Interactive-shell env source for `docker exec`' "${_df}"
  assert_success
}

@test "Dockerfile.example runtime shows commented /etc/bash.bashrc source example (#657)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # The example must be commented (leading '# ') so the minimal runtime
  # stays minimal by default -- it is an opt-in snippet, not a mandatory
  # layer. The ROS source line is the consumer's (base is ROS-agnostic).
  run grep -E "^# #   RUN echo 'source /opt/ros/\\\$ROS_DISTRO/setup.bash' >> /etc/bash.bashrc$" "${_df}"
  assert_success
}

@test "Dockerfile.example runtime does NOT bake ROS env into ENV (#657 fragility guard)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Guard the rejected alternative: no ENV LD_LIBRARY_PATH / PYTHONPATH
  # baked for ROS (arch- and python-version-dependent -- fragile).
  run grep -E '^ENV (LD_LIBRARY_PATH|PYTHONPATH)=' "${_df}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# pip scaffolding removed (reverses)
#
# dockerfile/setup/ and all pip-related Dockerfile.example patterns
# have been removed. Downstream repos that need pip handle it
# independently in their own Dockerfiles.
# ════════════════════════════════════════════════════════════════════

@test "template no longer ships dockerfile/setup/ (#407, reverses #261)" {
  [[ ! -e /source/dockerfile/setup ]]
}

@test "template no longer ships config/pip/ (#261 relocation regression guard)" {
  [[ ! -e /source/dist/config/pip ]]
}

@test "Dockerfile.example has no SETUP_DIR or pip references (#407)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  run grep -E 'SETUP_DIR|python3-pip|pip/setup|pip install' "${_df}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# Dockerfile.example: ENV alignment with downstream fleet
#
# All 17 hand-written downstream Dockerfiles declare ENV TZ +
# ENV LANGUAGE alongside ENV LC_ALL / ENV LANG. the seed
# Dockerfile.example only had LC_ALL / LANG; downstream-derived images
# from `/new-repo` therefore silently differed from the fleet on
# runtime $TZ and $LANGUAGE. The gap surfaces only for consumers that
# read the env directly (Python tzlocal, gettext fallback, some JVM
# tz resolution paths), but new repos should match the fleet.
# ════════════════════════════════════════════════════════════════════

@test "Dockerfile.example declares ENV TZ (matches downstream fleet, #210)" {
  local _df="/source/dist/dockerfile/Dockerfile"
  [[ -f "${_df}" ]] || skip "Dockerfile.example not present in /source"
  # Forwards the build-time ARG TZ value into a runtime env. ENV without
  # an explicit value would inherit the ARG, which is what we want — the
  # exact spelling the test locks is `ENV TZ="${TZ}"` to mirror how the
  # 17 downstream Dockerfiles spell it.
  run grep -E '^ENV TZ="\$\{TZ\}"$' "${_df}"
  assert_success
}

@test "Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)" {
  local _df="/source/dist/dockerfile/Dockerfile"
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
  # arches build on their native runners (not one QEMU runner),
  # then a merge job assembles the manifest list. Assert both native
  # runners are present rather than the old single combined
  # `platforms: linux/amd64,linux/arm64` string. Detailed structure is
  # covered by release_test_tools_yaml_spec.bats.
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -F 'ubuntu-latest' "${_yaml}"
  assert_success
  run grep -F 'ubuntu-24.04-arm' "${_yaml}"
  assert_success
}

@test "release-test-tools.yaml uses template-repo-local Dockerfile path" {
  # Regression: this workflow runs in the template repo, so Dockerfile.test-tools
  # path must be `dockerfile/...` (not `.base/dockerfile/...` which is the
  # downstream subtree path used by build-worker.yaml).
  local _yaml="/source/.github/workflows/release-test-tools.yaml"
  [[ -f "${_yaml}" ]] || skip "release-test-tools.yaml not present in /source"
  run grep -E '^\s*file: dockerfile/Dockerfile\.test-tools$' "${_yaml}"
  assert_success
  # And must NOT have the subtree-prefixed path:
  run grep -c 'file: .base/dockerfile/Dockerfile.test-tools' "${_yaml}"
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
  # Positive guard: we don't want to accidentally remove too much. The
  # user-facing wrappers ship via `script/` (symlinks into .base) since
  # not as root-level operands, so assert `script/` rather
  # than the removed root `build.sh`.
  local _yaml="/source/.github/workflows/release-worker.yaml"
  [[ -f "${_yaml}" ]] || skip "release-worker.yaml not present in /source"
  run awk '/cp -r/,/"\$\{ARCHIVE_NAME\}\/"/' "${_yaml}"
  assert_success
  assert_output --partial 'Dockerfile'
  assert_output --partial 'script/'
  assert_output --partial '.base/'
}

# ════════════════════════════════════════════════════════════════════
# run.sh: XDG_SESSION_TYPE branching
# ════════════════════════════════════════════════════════════════════

@test "run.sh contains XDG_SESSION_TYPE check" {
  run grep "XDG_SESSION_TYPE" /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh contains xhost +SI:localuser for wayland" {
  run grep 'xhost "+SI:localuser' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

@test "run.sh contains xhost +local: for X11" {
  run grep 'xhost +local:' /source/dist/script/docker/wrapper/run.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# setup.sh: default _base_path goes up 1 level (not 2)
# ════════════════════════════════════════════════════════════════════

@test "setup.sh default _base_path uses /.." {
  # In template, setup.sh is at .base/dist/script/docker/wrapper/setup.sh
  # So it should go up 1 level (..) to reach repo root
  run grep -E '\.\./\.\.' /source/dist/script/docker/wrapper/setup.sh
  assert_success  # Should have ../../ ../../ (that was old docker_setup_helper/src/ pattern)
}

@test "setup.sh default _base_path uses double parent traversal" {
  # setup.sh resolves the script directory once via readlink -f into
  # _SETUP_SCRIPT_DIR (so invocation through the root-level symlink works),
  # then walks up `../../..` to reach the repo root. The base_path-default
  # resolution moved with the subcommands into lib/setup_cmd.sh during the
  # setup.sh decomposition (ADR-00000014); the traversal still keys off the
  # same _SETUP_SCRIPT_DIR global setup.sh exports. Accept either the
  # original inline BASH_SOURCE form or the _SETUP_SCRIPT_DIR indirection.
  run grep -E "(dirname.*BASH_SOURCE|_SETUP_SCRIPT_DIR).*\.\..*\.\." \
    /source/dist/script/docker/lib/setup_cmd.sh
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# pre/post hook wiring presence across all 7 wrappers
# ════════════════════════════════════════════════════════════════════

@test "all 7 wrappers call _run_pre_hook with their own name (#440)" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    run grep -E "_run_pre_hook ${_w}\b" "/source/dist/script/docker/wrapper/${_w}.sh"
    [[ "${status}" -eq 0 ]] \
      || { echo "missing _run_pre_hook ${_w} in ${_w}.sh"; return 1; }
  done
}

@test "all 7 wrappers call _run_post_hook with their own name (#440)" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    run grep -E "_run_post_hook ${_w}\b" "/source/dist/script/docker/wrapper/${_w}.sh"
    [[ "${status}" -eq 0 ]] \
      || { echo "missing _run_post_hook ${_w} in ${_w}.sh"; return 1; }
  done
}

@test "run.sh _app_cleanup runs post-hook before compose down (#440)" {
  # Order matters: container must still be alive when post-hook runs
  # so the hook can `docker exec` for final reporting.
  run bash -c "
    awk '
      /_app_cleanup\\(\\) \\{/ { in_func = 1; next }
      in_func && /_run_post_hook run/ { print \"POST_LINE=\" NR; post_seen = 1 }
      in_func && /_compose_(project|dispatch) down/ { print \"DOWN_LINE=\" NR; down_seen = 1 }
      in_func && /^\\}/ { exit }
    ' /source/dist/script/docker/wrapper/run.sh
  "
  assert_output --partial "POST_LINE="
  assert_output --partial "DOWN_LINE="
  local _post_line _down_line
  _post_line="$(echo "${output}" | grep POST_LINE | cut -d= -f2 | head -1)"
  _down_line="$(echo "${output}" | grep DOWN_LINE | cut -d= -f2 | head -1)"
  (( _post_line < _down_line )) \
    || { echo "post-hook should run before compose down: post=${_post_line} down=${_down_line}"; return 1; }
}

@test "lib/hook.sh skips both helpers under DRY_RUN (#440, #13)" {
  # Regression guard for Q13: dry-run contract requires no side effects.
  run grep -E 'DRY_RUN.*true' /source/dist/script/docker/lib/hook.sh
  assert_success
}

@test "lib/hook.sh hard-fails on present-but-not-executable hook (#440, #11)" {
  run grep -E 'not executable.*chmod' /source/dist/script/docker/lib/hook.sh
  assert_success
}
