#!/usr/bin/env bats
#
# Behavioural coverage for Dockerfile.example's runtime-test smoke gate
# (template#249). Drives `docker buildx build --target runtime-test`
# against a synthesized minimal fixture Dockerfile so the smoke RUN
# line is genuinely exercised. Sister of the static-grep tests in
# test/unit/template_spec.bats (which only check the comment shape);
# this file proves the gate actually fires (positive cases pass; the
# `exit 1` case fails the build, not just prints a warning).
#
# Requires the ci-behavioural compose service (mounts host
# /var/run/docker.sock + sets MOUNT_DOCKER_SOCK=1). Auto-skips when
# the socket is absent so accidental invocation via the default `ci`
# service is harmless.
#
# Each @test invokes one `docker buildx build` call (~5-15s amd64,
# ~30-60s arm64 QEMU). The dedicated buildx builder
# (template-behavioural, set up by ci.sh _behavioural_setup) isolates
# the cache from the user's other docker work.

setup_file() {
  if [[ ! -S /var/run/docker.sock ]]; then
    skip "behavioural test: /var/run/docker.sock not mounted (run via 'make test-behavioural')"
  fi
  if ! command -v docker >/dev/null 2>&1; then
    skip "behavioural test: docker CLI not present (test-tools < v0.23.2)"
  fi

  # Fixture: minimal multi-stage Dockerfile mirroring the
  # runtime-base -> runtime -> runtime-test chain from
  # template/dockerfile/Dockerfile.example. Carries no application
  # code -- only the smoke gate under test.
  FIXTURE_DIR="$(mktemp -d -t template-249-behavioural-XXXXXX)"
  export FIXTURE_DIR
  cat > "${FIXTURE_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS runtime-base
FROM runtime-base AS runtime
FROM runtime AS runtime-test
ARG RUNTIME_SMOKE_CMD='whoami && bash --version'
RUN bash -c "${RUNTIME_SMOKE_CMD}"
EOF
}

teardown_file() {
  [[ -n "${FIXTURE_DIR:-}" && -d "${FIXTURE_DIR}" ]] && rm -rf "${FIXTURE_DIR}"
}

# Helper: build the runtime-test target with the given RUNTIME_SMOKE_CMD.
# Echoes docker's stderr+stdout so failures are self-explaining in bats
# output. Exits with docker's exit code so the @test assertion sees
# success/failure directly.
_build_runtime_test() {
  local _cmd="$1"
  docker buildx build \
    --builder template-behavioural \
    --target runtime-test \
    --build-arg "RUNTIME_SMOKE_CMD=${_cmd}" \
    --progress=plain \
    -f "${FIXTURE_DIR}/Dockerfile" \
    "${FIXTURE_DIR}" 2>&1
}

# ────────────────────────────────────────────────────────────────────
# Positive cases: runtime-test should succeed (build returns 0).
# ────────────────────────────────────────────────────────────────────

@test "runtime-test build succeeds with default smoke command" {
  # Default ARG value -- the baseline install-check every repo gets
  # before any override. Proves the gate's happy path works.
  run _build_runtime_test 'whoami && bash --version'
  [ "${status}" -eq 0 ]
}

@test "runtime-test build succeeds with && chain override (#243 word-split regression)" {
  # v0.21.0 shipped `RUN ${RUNTIME_SMOKE_CMD}` (no wrapper) which
  # word-split this exact shape -- bash tokenized `&&` as a literal
  # arg to whoami. v0.21.1's wrapper fix locked the behaviour;
  # this assertion catches future regressions of that wrapper.
  run _build_runtime_test 'echo first && echo second'
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -q 'first'
  echo "${output}" | grep -q 'second'
}

@test "runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)" {
  # v0.21.1's `sh -c` wrapper (kept through v0.23.0) routed the
  # command through dash, which CANNOT parse bash parameter
  # expansion -- `${var:offset:length}` triggered `Bad substitution`.
  # v0.23.1 switched to `bash -c`. This shape (substring extraction)
  # is the minimal reproducer for the dash-vs-bash gap. If a future
  # edit reverts the wrapper to `sh -c`, this test fails build with
  # `Bad substitution` instead of returning 0.
  run _build_runtime_test 'x=hello && [[ "${x:0:3}" = "hel" ]]'
  [ "${status}" -eq 0 ]
}

@test "runtime-test build succeeds with bash [[ test operator override (#249)" {
  # `[[` is bash-only; dash only has `[`. Complements the parameter
  # expansion case -- different bash feature, same dash-incompat
  # class. Two distinct regression guards because someone might
  # restore one bash feature but not the other in a partial revert.
  run _build_runtime_test '[[ 1 == 1 ]] && echo ok'
  [ "${status}" -eq 0 ]
  echo "${output}" | grep -q 'ok'
}

# ────────────────────────────────────────────────────────────────────
# Negative case: runtime-test MUST fail when the smoke command
# returns non-zero. Without this, a future change that swallows the
# smoke exit code (e.g. someone adds `|| true` "to be safe") would
# silently degrade every downstream's smoke and nobody would notice.
# ────────────────────────────────────────────────────────────────────

@test "runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)" {
  run _build_runtime_test 'echo failing-on-purpose && exit 1'
  [ "${status}" -ne 0 ]
  # The fixture's failing command output must appear in the build
  # log so a real failure is debuggable. (Docker's `--progress=plain`
  # surfaces RUN stdout; if a future buildx version suppresses it,
  # this grep catches the regression.)
  echo "${output}" | grep -q 'failing-on-purpose'
}
