#!/usr/bin/env bats
#
# Integration test: wrapper -> compose dispatch, asserted behaviourally
# via --dry-run output rather than by grepping for the dispatcher's
# identifier name in the wrapper source (#490).
#
# Why behavioural: the old template_spec.bats greps asserted that the
# literal string `_compose_project` appeared in each wrapper. Every
# internal rename (#480 `_compose_dispatch` shim, #484 `_app_cleanup`)
# forced those greps to be updated in lockstep or CI failed -- and a
# grep cannot catch a *bypass* (a raw `docker compose ...` added without
# `-p`, which would silently use the directory basename as the project
# name). These tests instead run each wrapper with --dry-run and assert
# the planned command is `docker compose -p <project> <verb>`, including
# the `-p` flag. They are immune to internal renames and DO catch a
# bypass (a missing `-p`).
#
# Level-1 (file generation + dry-run only) -- docker is never invoked;
# --dry-run makes every wrapper print its compose command and stop.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  REPO_NAME="myapp_test"
  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/${REPO_NAME}"
  mkdir -p "${REPO_DIR}/.base"
  cp -a /source/. "${REPO_DIR}/.base/"

  # Look like a committed downstream consumer: Dockerfile present and the
  # wrappers symlinked from the repo root exactly as init.sh produces.
  touch "${REPO_DIR}/Dockerfile"
  local _w
  for _w in build run exec stop; do
    ln -s ".base/script/docker/wrapper/${_w}.sh" "${REPO_DIR}/${_w}.sh"
  done

  # Seed a per-repo setup.conf from the template so apply renders .env +
  # compose.yaml deterministically.
  mkdir -p "${REPO_DIR}/config/docker"
  cp "${REPO_DIR}/.base/config/docker/setup.conf" \
     "${REPO_DIR}/config/docker/setup.conf"

  cd "${REPO_DIR}"

  # Materialize .env + compose.yaml once. build.sh / run.sh self-regen on
  # drift, but stop.sh / exec.sh expect the derived artifacts to already
  # exist (as in a real repo after its first build). --dry-run keeps docker
  # uninvoked while setup.sh runs end-to-end.
  bash "${REPO_DIR}/build.sh" --dry-run >/dev/null 2>&1 || true
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# ── compose dispatch (behavioural) ──────────────────────────────────────────

@test "build.sh --dry-run dispatches compose build with -p project flag" {
  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  # -p must be present (catches a raw `docker compose` bypass) and the
  # project name is the wrapper's PROJECT_NAME rule, not the dir basename.
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+'
  assert_output --partial ' build'
}

@test "run.sh --dry-run (default devel) dispatches compose up + exec with -p" {
  run bash "${REPO_DIR}/run.sh" --dry-run
  assert_success
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* up '
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* exec '
}

@test "exec.sh --dry-run dispatches compose exec with -p" {
  run bash "${REPO_DIR}/exec.sh" --dry-run
  assert_success
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* exec '
}

@test "stop.sh --dry-run dispatches compose down with -p" {
  run bash "${REPO_DIR}/stop.sh" --dry-run
  assert_success
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* down'
}

@test "run.sh foreground --dry-run installs cleanup that downs with --remove-orphans" {
  run bash "${REPO_DIR}/run.sh" --dry-run
  assert_success
  # The EXIT-trap cleanup is visible in dry-run output (#386/#440): it
  # tears the project down through the same -p dispatcher.
  assert_output --regexp '\[dry-run\] docker compose -p [a-zA-Z0-9._-]+ .* down --remove-orphans -t'
}

@test "no wrapper dispatches compose without -p (bypass regression)" {
  # Every `docker compose` invocation must go through the -p-injecting
  # dispatcher. A raw `docker compose ...` (wrong project name) is the
  # exact failure this guards against -- grep-based tests could not.
  local _w _line
  for _w in build run exec stop; do
    run bash "${REPO_DIR}/${_w}.sh" --dry-run
    assert_success
    while IFS= read -r _line; do
      [[ "${_line}" == *"docker compose"* ]] || continue
      [[ "${_line}" == *"docker compose -p "* ]] \
        || fail "${_w}.sh dispatched compose without -p: ${_line}"
    done <<< "${output}"
  done
}
