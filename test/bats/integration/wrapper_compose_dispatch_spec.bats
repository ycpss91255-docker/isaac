#!/usr/bin/env bats
#
# Integration test: wrapper -> compose dispatch, asserted by observed behaviour
# via --dry-run output rather than by grepping for the dispatcher's
# identifier name in the wrapper source.
#
# Why behaviour-based: the old template_spec.bats greps asserted that the
# literal string `_compose_project` appeared in each wrapper. Every
# internal rename (`_compose_dispatch` shim, `_app_cleanup`)
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
    ln -s ".base/dist/script/docker/wrapper/${_w}.sh" "${REPO_DIR}/${_w}.sh"
  done

  # Seed a per-repo setup.conf from the template so apply renders .env +
  # compose.yaml deterministically.
  mkdir -p "${REPO_DIR}"
  cp "${REPO_DIR}/.base/dist/.setup.conf" \
     "${REPO_DIR}/.setup.conf"

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

# ── compose dispatch (behaviour-based) ──────────────────────────────────────────

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
  # The EXIT-trap cleanup is visible in dry-run output: it
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

# ── project name: one value, two consumers ─────────────────────────────────

@test "the -p project name and compose.yaml's name: are one value, not two computations" {
  # The defect: the wrapper computed `${DOCKER_HUB_USER}-${IMAGE_NAME}` in
  # bash while the emitter wrote the same expression into compose.yaml, and
  # the explicit -p silently beat the file. Two answerers to one question.
  # The proof that they are now ONE value: whatever variable compose.yaml's
  # `name:` interpolates must be defined in .env.generated (which compose
  # reads via --env-file), and the wrapper's -p must be that variable's
  # value -- so changing the recorded value moves BOTH.
  local _name_line _var _recorded
  _name_line="$(grep -E '^name:' "${REPO_DIR}/compose.yaml" | head -1)"
  [[ "${_name_line}" =~ ^name:[[:space:]]*\$\{([A-Z_][A-Z0-9_]*)\}$ ]] \
    || fail "compose.yaml name: is not a single interpolation: ${_name_line}"
  _var="${BASH_REMATCH[1]}"

  _recorded="$(grep -E "^${_var}=" "${REPO_DIR}/.env.generated" | tail -1)"
  [[ -n "${_recorded}" ]] \
    || fail "compose.yaml interpolates \${${_var}} but .env.generated does not define it"
  _recorded="${_recorded#*=}"

  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  assert_output --partial "docker compose -p ${_recorded}"
}

@test "[project] name in .setup.conf.local moves BOTH the -p and the emitted name:" {
  printf '[project]\nname = %s\n' "myapp-worktree-2" \
    > "${REPO_DIR}/.setup.conf.local"
  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  assert_output --partial "docker compose -p myapp-worktree-2"

  run grep -E '^PROJECT_NAME=myapp-worktree-2$' "${REPO_DIR}/.env.generated"
  assert_success

  # The emitted compose.yaml stays an overlay-overridable interpolation
  # (ADR-00000022), so the value moved without the artifact's shape moving.
  run grep -E '^name: \$\{PROJECT_NAME\}$' "${REPO_DIR}/compose.yaml"
  assert_success
}

@test "two checkouts of one repo dispatch different projects after a local override" {
  # The acceptance criterion: two worktrees run concurrently after setting
  # the project name in one of them, through the wrappers alone -- no
  # hand-edited derived artifact and no environment variable.
  local _second="${TMP_ROOT}/${REPO_NAME}-2"
  cp -a "${REPO_DIR}" "${_second}"
  printf '[project]\nname = %s\n' "myapp-worktree-2" \
    > "${_second}/.setup.conf.local"

  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  local _first_out="${output}"
  run bash "${_second}/build.sh" --dry-run
  assert_success

  assert_output --partial "docker compose -p myapp-worktree-2"
  [[ "${_first_out}" != *"-p myapp-worktree-2"* ]] \
    || fail "the first checkout also resolved the second's project name"
}

@test "an unchanged repo keeps the project name it resolved before [project] existed" {
  # With no [project] name set anywhere, the resolved value must be the
  # historical `${DOCKER_HUB_USER}-${IMAGE_NAME}` string, byte for byte.
  local _hub _img
  _hub="$(grep -E '^DOCKER_HUB_USER=' "${REPO_DIR}/.env.generated" | tail -1)"
  _hub="${_hub#*=}"
  _img="$(grep -E '^IMAGE_NAME=' "${REPO_DIR}/.env.generated" | tail -1)"
  _img="${_img#*=}"
  run grep -Fx "PROJECT_NAME=${_hub}-${_img}" "${REPO_DIR}/.env.generated"
  assert_success
}
