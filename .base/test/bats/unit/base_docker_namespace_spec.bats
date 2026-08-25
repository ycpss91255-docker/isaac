#!/usr/bin/env bats
#
# Static checks for base's self-use of the `docker` namespace
# (ADR-00000011 sec.2/4): base is the template SOURCE, so it has no `.base/`
# subtree -- it wires the docker namespace into its own root justfile and
# ships the wrapper symlinks pointing directly at dist/ (no `.base/`
# prefix), mirroring what init.sh produces for a consumer. `just` is not
# installed in the test-tools image, so these are content / symlink
# assertions, not execution (execution parity is a consumer/local concern).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  ROOT=/source
}

@test "base root justfile mods the docker namespace (#713)" {
  run grep -E "^mod\?? docker 'script/docker/justfile.docker'" "${ROOT}/justfile"
  assert_success
}

@test "base ships script/docker/justfile.docker as a symlink into dist/ (no .base/)" {
  assert [ -L "${ROOT}/script/docker/justfile.docker" ]
  # Resolves to a real file under dist/script/docker (not via a .base/ hop).
  local _t
  _t="$(readlink -- "${ROOT}/script/docker/justfile.docker")"
  assert [ -f "${ROOT}/script/docker/justfile.docker" ]
  [[ "${_t}" != *".base/"* ]]
  [[ "${_t}" == *"dist/script/docker/justfile.docker" ]]
}

@test "base ships flat wrapper symlinks resolving into dist/script/docker/wrapper" {
  local _w
  for _w in build run exec stop prune setup setup_tui; do
    assert [ -L "${ROOT}/script/${_w}.sh" ]
    assert [ -f "${ROOT}/script/${_w}.sh" ]
    local _t
    _t="$(readlink -- "${ROOT}/script/${_w}.sh")"
    [[ "${_t}" != *".base/"* ]]
    [[ "${_t}" == *"dist/script/docker/wrapper/${_w}.sh" ]]
  done
}

@test "base compose.yaml declares a test-tools service building Dockerfile.test-tools" {
  run grep -nE '^\s{2}test-tools:' "${ROOT}/compose.yaml"
  assert_success
  # The service builds from the standalone tooling Dockerfile.
  run grep -nE 'dockerfile:\s*dockerfile/Dockerfile.test-tools' "${ROOT}/compose.yaml"
  assert_success
}

@test "just test system builds test-tools via the docker namespace, not a raw docker build (#713, ADR-00000011 sec.5)" {
  run grep -nE 'just docker build --target test-tools' "${ROOT}/script/test/justfile.test"
  assert_success
  # The raw `docker build -t test-tools:local -f dockerfile/Dockerfile.test-tools`
  # one-liner is gone -- the test runner invokes the docker namespace instead.
  run grep -nE 'docker build -t test-tools:local -f' "${ROOT}/script/test/justfile.test"
  assert_failure
}

@test "base compose.yaml names every image with TEST_TOOLS_IMAGE and gives it no default (#891, #896)" {
  # A hardcoded `image: test-tools:local` makes every checkout on the host
  # write one tag, so a sibling build silently displaces the image a live
  # run is using. A DEFAULT is worse still: two different ones let the
  # build-only service write one tag while the ci / ci-system / coverage
  # consumers read another, and one shared default would only hide that
  # while still building or pulling something behind the operator's back.
  local _total
  _total="$(grep -cE '^ {4}image: ' "${ROOT}/compose.yaml")"
  run grep -cE '^ {4}image: \$\{TEST_TOOLS_IMAGE(\}|:\?)' "${ROOT}/compose.yaml"
  assert_success
  assert_output "${_total}"
  run grep -nE '^ {4}image: \$\{TEST_TOOLS_IMAGE:-' "${ROOT}/compose.yaml"
  assert_failure
  run grep -nE '^ {4}image: test-tools:local *$' "${ROOT}/compose.yaml"
  assert_failure
}

@test "just test system derives the local test-tools tag instead of hardcoding it (#891)" {
  run grep -nE 'TEST_TOOLS_IMAGE=test-tools:local' "${ROOT}/script/test/justfile.test"
  assert_failure
  run grep -nE 'test\.sh --test-tools-image' "${ROOT}/script/test/justfile.test"
  assert_success
}

@test "base compose.yaml carries no fallback identity for the mounted checkout (#895)" {
  # The behavioural half (what compose RESOLVES) lives in
  # compose_host_identity_spec, which needs the compose plugin in the
  # tooling image. This half needs nothing and cannot rot: a `:-` default
  # on either variable is the silent 'files owned by uid 1000' defect
  # regardless of which value it names.
  run grep -nE '^ +- HOST_(UID|GID)=\$\{HOST_(UID|GID):-' "${ROOT}/compose.yaml"
  assert_failure
  run grep -cE '^ +- HOST_(UID|GID)=\$\{HOST_(UID|GID):\?' "${ROOT}/compose.yaml"
  assert_success
  assert_output "6"
}

@test "base root justfile exports the host identity every compose read needs (#895)" {
  # compose interpolates the WHOLE compose.yaml whatever service is named,
  # so dropping the HOST_UID / HOST_GID defaults made them required of
  # every `just` recipe that reaches compose -- including
  # `just docker build --target test-tools`, base's documented self-use of
  # the docker namespace, which touches no service that reads them. One
  # export at the root entry covers every namespace (`just` propagates a
  # root export into module recipes), so raw `docker compose` stays the
  # only refused path -- which is the point of refusing.
  run grep -nE '^export HOST_UID := `id -u`$' "${ROOT}/justfile"
  assert_success
  run grep -nE '^export HOST_GID := `id -g`$' "${ROOT}/justfile"
  assert_success
}

@test "just test system supplies the host identity its bare compose run needs (#895)" {
  # The bare `docker compose run --rm ci-system` here is the one `just test`
  # path that does not go through test.sh's _run_via_compose, so it is the
  # one that has to export HOST_UID / HOST_GID itself. Without them the
  # containers wrote the mounted checkout as whatever compose defaulted to.
  run grep -nE '^ +export HOST_UID HOST_GID$' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE 'HOST_UID="\$\(id -u\)"' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE 'HOST_GID="\$\(id -g\)"' "${ROOT}/script/test/justfile.test"
  assert_success
}

@test "just test system names the compose project instead of inheriting the basename (#891)" {
  # Its `docker compose run --rm ci-system` is a second call site with the
  # same defect test.sh had: no -p and no COMPOSE_PROJECT_NAME means compose
  # falls back to the checkout directory's basename.
  run grep -nE 'test\.sh --compose-project-name' "${ROOT}/script/test/justfile.test"
  assert_success
  run grep -nE '^ +export COMPOSE_PROJECT_NAME$' "${ROOT}/script/test/justfile.test"
  assert_success
}
