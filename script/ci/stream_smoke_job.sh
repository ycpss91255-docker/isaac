#!/usr/bin/env bash
# stream_smoke_job.sh -- the Tier A producer-side stream smoke (isaac#172),
# run by stream-smoke.yaml through the org reusable workflow
# gpu-self-hosted.yml (which owns the runner, the fork-PR gate, the workspace
# reclaim and the checkout).
#
# Builds the stream stage, then runs script/ci/stream_smoke.sh (Isaac boots +
# a client streams + survives the dwell; tears down on every exit via its own
# trap).
#
# On failure the full kit log is printed in a collapsed log group. The job
# used to upload it as the `stream-smoke-kit-log` artifact, but the reusable
# workflow runs a single script step and has no upload step after it, so the
# log goes to the job log instead.
# Guard: test/bats/smoke/gpu_job_scripts_spec.bats.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"
# shellcheck source=gpu_job_lib.sh
. "${repo_root}/script/ci/gpu_job_lib.sh"

gpu_job_apply_and_pin_ws_path
gpu_job_build stream
gpu_job_cache_dirs

# SMOKE_PROJECT: per-run-unique compose project (owv#55), so the smoke's
# project-scoped teardown cannot reap a co-hosted manual stream stack.
# SMOKE_REAP_PROJECT_PREFIX: every SMOKE_PROJECT shares it and the workflow's
# concurrency group keeps a single smoke live, so any OTHER project under it
# is a previous run whose teardown never ran; the smoke removes those before
# bring-up (isaac#291). Developer projects never carry this prefix.
gpu_job_group "Stream smoke (Isaac boots + a client streams + survives dwell)"
rc=0
SMOKE_PROJECT="isaac-smoke-${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}" \
  SMOKE_REAP_PROJECT_PREFIX="isaac-smoke-" \
  bash script/ci/stream_smoke.sh || rc=$?
gpu_job_endgroup

if [ "${rc}" -ne 0 ]; then
  kit_log="isaac-sim/kit/logs/stream-smoke.log"
  if [ -f "${kit_log}" ]; then
    gpu_job_group "Full kit log (${kit_log})"
    cat "${kit_log}"
    gpu_job_endgroup
  fi
  exit "${rc}"
fi
