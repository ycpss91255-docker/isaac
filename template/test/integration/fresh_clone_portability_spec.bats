#!/usr/bin/env bats
#
# Integration test: fresh clone of a consumer repo whose committed
# setup.conf was written by a different contributor and still carries
# that contributor's absolute host workspace path in mount_1.
#
# This is the exact scenario that surfaced on the NVIDIA Jetson:
#
#   1. Contributor A runs `./build.sh` locally, setup.sh bootstraps and
#      writes mount_1 = /home/A/repo:/home/${USER_NAME}/work into
#      setup.conf. Committed to git.
#   2. Contributor B clones on a machine where /home/A/... doesn't
#      exist. `.env` and `compose.yaml` are gitignored so a fresh
#      clone has setup.conf (with A's path) + no derived artifacts.
#   3. Running `./build.sh` used to silently resolve WS_PATH to A's
#      path (compose.yaml then failed or bind-mounted an empty dir).
#
# The fixes from v0.9.4 (mount_1 portability / auto-migrate) and
# v0.9.5 (build.sh drift auto-regen) combine to handle this flow
# end-to-end. This test exercises that composition against the real
# build.sh + setup.sh — unit tests cover each layer individually.
#
# Level-1 (file generation only) — docker is not invoked.

setup() {
  load "${BATS_TEST_DIRNAME}/../unit/test_helper"

  REPO_NAME="myapp_test"
  TMP_ROOT="$(mktemp -d)"
  REPO_DIR="${TMP_ROOT}/${REPO_NAME}"
  mkdir -p "${REPO_DIR}/template"
  cp -a /source/. "${REPO_DIR}/template/"

  # Make the repo look like a committed consumer repo: Dockerfile is
  # present (so init.sh's existing-repo path fires), build.sh is
  # symlinked exactly as init.sh would have produced it.
  touch "${REPO_DIR}/Dockerfile"
  ln -s template/script/docker/build.sh "${REPO_DIR}/build.sh"

  cd "${REPO_DIR}"
}

teardown() {
  rm -rf "${TMP_ROOT}"
}

# _seed_stale_setup_conf <host_path>
#
# Drop in a setup.conf that mirrors what another contributor would
# have committed: all the template defaults with mount_1 pointing at
# an absolute host path that does NOT exist on the current machine.
_seed_stale_setup_conf() {
  local _host="$1"
  cp "${REPO_DIR}/template/setup.conf" "${REPO_DIR}/setup.conf"
  # shellcheck disable=SC2016  # ${USER_NAME} is a literal in setup.conf
  sed -i "s|^mount_1 =.*|mount_1 = ${_host}:/home/\${USER_NAME}/work|" \
    "${REPO_DIR}/setup.conf"
}

# ════════════════════════════════════════════════════════════════════
# Scenario: contributor B clones; setup.conf has A's absolute path;
# no .env / compose.yaml exist yet.
# ════════════════════════════════════════════════════════════════════

@test "fresh clone with stale absolute mount_1: setup.conf is regenerated, no path leak (#174)" {
  # Pre-#174 the contributor-A → contributor-B path-leak hinged on
  # setup.conf being tracked: the absolute path travelled through git
  # and apply had to detect-and-rewrite. After #174 setup.conf is
  # gitignored and a derived snapshot, so the leak vector is gone at
  # the source. This test still pre-seeds a stale setup.conf to model
  # a worst-case scenario (e.g. a developer manually checked it in)
  # and asserts that apply still produces a clean .env / compose.yaml
  # regardless — the stale value never reaches WS_PATH.
  _seed_stale_setup_conf "/nonexistent/contributor-a/repo"

  assert [ -f "${REPO_DIR}/setup.conf" ]
  assert [ ! -f "${REPO_DIR}/.env" ]
  assert [ ! -f "${REPO_DIR}/compose.yaml" ]

  # --dry-run so build.sh stops before invoking docker (the docker
  # binary may be absent in the test image), but setup.sh still runs
  # end-to-end and produces .env + compose.yaml.
  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  # The bootstrap banner fires because compose.yaml / .env are missing.
  assert_output --partial "First run"

  # .env carries THIS machine's WS_PATH, never the seeded stale path —
  # apply re-detects ws_path from template's portable mount_1 (no
  # .local override exists) instead of trusting the stale snapshot.
  assert [ -f "${REPO_DIR}/.env" ]
  run grep '^WS_PATH=' "${REPO_DIR}/.env"
  assert_success
  refute_output --partial "WS_PATH=/nonexistent/contributor-a/repo"

  # compose.yaml regenerated.
  assert [ -f "${REPO_DIR}/compose.yaml" ]
}

@test "fresh clone with portable \${WS_PATH} mount_1: no warning, .env gets local path" {
  # Same shape as above but with a repo whose committed setup.conf
  # already uses the portable form (the happy case after v0.9.4+).
  cp "${REPO_DIR}/template/setup.conf" "${REPO_DIR}/setup.conf"
  # shellcheck disable=SC2016  # literal ${WS_PATH} / ${USER_NAME} intentional
  sed -i 's|^mount_1 =.*|mount_1 = ${WS_PATH}:/home/${USER_NAME}/work|' \
    "${REPO_DIR}/setup.conf"

  run bash "${REPO_DIR}/build.sh" --dry-run
  assert_success
  # No stale-path warning.
  refute_output --partial "WARNING"

  # mount_1 stays as the portable form.
  run grep '^mount_1' "${REPO_DIR}/setup.conf"
  assert_output --partial 'mount_1 = ${WS_PATH}:/home/${USER_NAME}/work'

  # .env populated with this machine's WS_PATH (non-empty, absolute).
  run grep '^WS_PATH=' "${REPO_DIR}/.env"
  assert_output --regexp '^WS_PATH=/[^[:space:]]+'
}
