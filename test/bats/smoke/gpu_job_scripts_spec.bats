#!/usr/bin/env bats
#
# Behavioral guard for the self-hosted GPU job scripts:
#   script/ci/gpu_integration_job.sh  (main.yaml gpu-integration)
#   script/ci/stream_smoke_job.sh     (stream-smoke.yaml stream-smoke)
#
# Both jobs now run through the org reusable workflow
# ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml, which owns
# the runner, the fork-PR gate, the pre-checkout workspace reclaim and the
# checkout, and then runs ONE repo script. These scripts hold the step logic
# the two workflows used to carry inline, so this spec pins what those steps
# did: the order, the WS_PATH pin, which env reaches which command, the
# writable cache dirs, and that a failing step fails the job.
#
# Hermetic: the real job scripts run from a fake repo root against stub
# setup.sh / build.sh / assert_pytest_baseline.sh / stream_smoke.sh that
# record what they receive. No docker, no GPU.
#
# Baked into /smoke_test/ next to the job scripts by the devel-test stage.

bats_require_minimum_version 1.5.0

setup() {
  FAKE="$(mktemp -d)"
  mkdir -p "${FAKE}/script/ci" "${FAKE}/test"
  for f in gpu_job_lib.sh gpu_integration_job.sh stream_smoke_job.sh; do
    cp "${BATS_TEST_DIRNAME}/${f}" "${FAKE}/script/ci/${f}"
  done
  chmod +x "${FAKE}/script/ci/"*.sh

  export CALLS="${FAKE}/calls.log"
  export GITHUB_WORKSPACE="${FAKE}"
  export GITHUB_RUN_ID=1234
  export GITHUB_RUN_ATTEMPT=2
  unset ISAAC_ALLOW_SHARED_IDENTITY BASELINE_PROJECT GPU_ROS_DOMAIN_ID \
    SMOKE_PROJECT SMOKE_REAP_PROJECT_PREFIX

  # setup.sh apply writes a cache with the mis-detected WS_PATH the job must
  # overwrite (base detect_ws_path returns _work/<repo>, base#586).
  cat > "${FAKE}/script/setup.sh" <<'STUB'
#!/usr/bin/env bash
echo "setup $*" >> "${CALLS}"
printf 'IMAGE_NAME=isaac\nWS_PATH=/wrong/parent\nPROJECT_NAME=alice-isaac\n' \
  > .env.generated
STUB

  cat > "${FAKE}/script/build.sh" <<'STUB'
#!/usr/bin/env bash
echo "build $* shared=${ISAAC_ALLOW_SHARED_IDENTITY:-unset}" >> "${CALLS}"
exit "${BUILD_RC:-0}"
STUB

  cat > "${FAKE}/test/assert_pytest_baseline.sh" <<'STUB'
#!/usr/bin/env bash
{
  echo "baseline $* project=${BASELINE_PROJECT:-unset} domain=${GPU_ROS_DOMAIN_ID:-unset} shared=${ISAAC_ALLOW_SHARED_IDENTITY:-unset}"
  grep '^WS_PATH=' .env.generated
  [ -w isaac-sim/kit/cache ] && [ -w isaac-sim/nvidia/computecache ] \
    && [ -w isaac-sim/documents ] && echo "caches=writable"
} >> "${CALLS}"
STUB

  cat > "${FAKE}/script/ci/stream_smoke.sh" <<'STUB'
#!/usr/bin/env bash
{
  echo "smoke project=${SMOKE_PROJECT:-unset} reap=${SMOKE_REAP_PROJECT_PREFIX:-unset} shared=${ISAAC_ALLOW_SHARED_IDENTITY:-unset}"
  grep '^WS_PATH=' .env.generated
  [ -w isaac-sim/kit/logs ] && echo "caches=writable"
} >> "${CALLS}"
if [ -n "${SMOKE_RC:-}" ]; then
  echo "kit-log-line-from-the-failed-run" > isaac-sim/kit/logs/stream-smoke.log
  exit "${SMOKE_RC}"
fi
STUB
  chmod +x "${FAKE}/script/setup.sh" "${FAKE}/script/build.sh" \
    "${FAKE}/test/assert_pytest_baseline.sh" "${FAKE}/script/ci/stream_smoke.sh"
}

teardown() {
  rm -rf "${FAKE}"
}

@test "gpu integration job: apply, pin WS_PATH, build test, caches, gpu baseline -- in order" {
  run bash "${FAKE}/script/ci/gpu_integration_job.sh"
  [ "${status}" -eq 0 ]
  run cat "${CALLS}"
  [ "${lines[0]}" = "setup apply" ]
  [ "${lines[1]}" = "build -t test shared=1" ]
  [ "${lines[2]}" = "baseline --gpu project=isaac-baseline-1234-2 domain=47 shared=unset" ]
  [ "${lines[3]}" = "WS_PATH=${FAKE}" ]
  [ "${lines[4]}" = "caches=writable" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "gpu integration job: works from any cwd (resolves the repo root itself)" {
  cd /
  run bash "${FAKE}/script/ci/gpu_integration_job.sh"
  [ "${status}" -eq 0 ]
  grep -qx "setup apply" "${CALLS}"
}

@test "gpu integration job: a failed build fails the job before the GPU suite" {
  BUILD_RC=3 run bash "${FAKE}/script/ci/gpu_integration_job.sh"
  [ "${status}" -ne 0 ]
  run grep -c '^baseline' "${CALLS}"
  [ "${output}" = "0" ]
}

@test "stream smoke job: apply, pin WS_PATH, build stream, caches, smoke -- in order" {
  run bash "${FAKE}/script/ci/stream_smoke_job.sh"
  [ "${status}" -eq 0 ]
  run cat "${CALLS}"
  [ "${lines[0]}" = "setup apply" ]
  [ "${lines[1]}" = "build -t stream shared=1" ]
  [ "${lines[2]}" = "smoke project=isaac-smoke-1234-2 reap=isaac-smoke- shared=unset" ]
  [ "${lines[3]}" = "WS_PATH=${FAKE}" ]
  [ "${lines[4]}" = "caches=writable" ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "stream smoke job: a failed smoke fails the job and prints the full kit log" {
  SMOKE_RC=1 run bash "${FAKE}/script/ci/stream_smoke_job.sh"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"kit-log-line-from-the-failed-run"* ]]
}

@test "stream smoke job: a failed smoke with no kit log still fails with the smoke's status" {
  cat > "${FAKE}/script/ci/stream_smoke.sh" <<'STUB'
#!/usr/bin/env bash
exit 4
STUB
  run bash "${FAKE}/script/ci/stream_smoke_job.sh"
  [ "${status}" -eq 4 ]
}
