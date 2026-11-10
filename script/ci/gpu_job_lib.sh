#!/usr/bin/env bash
# gpu_job_lib.sh -- steps shared by the self-hosted GPU job scripts
# (gpu_integration_job.sh, stream_smoke_job.sh). Sourced, not executed.
#
# Those jobs run through the org reusable workflow
# ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml, which
# reclaims the workspace, checks out, and then runs ONE repo script. The
# steps below used to be inline workflow steps; they keep their old names
# as log groups.

# Log group helpers (collapsible sections in the Actions log).
gpu_job_group() { echo "::group::$*"; }
gpu_job_endgroup() { echo "::endgroup::"; }

# base detect_ws_path mis-detects the self-CI _work/<repo>/<repo> layout:
# none of its strategies (docker_* sibling, *_ws ancestor) match, so the
# parent-dir fallback returns _work/<repo> -- one level too high, leaving the
# repo at ~/work/<repo>/ inside the container. .setup.conf ships mount_1 in
# portable ${WS_PATH} form, so apply re-detects WS_PATH locally and ignores a
# job-env override. Pin it in the derived .env.generated cache AFTER apply
# (the --env-file the wrappers pass to compose) so the compose mounts the
# repo root at ~/work. base follow-up: base#586.
gpu_job_apply_and_pin_ws_path() {
  gpu_job_group "Generate .env + compose.yaml (pin WS_PATH)"
  ./script/setup.sh apply
  sed -i "s|^WS_PATH=.*|WS_PATH=${GITHUB_WORKSPACE:?}|" .env.generated
  gpu_job_endgroup
}

# CI keeps the shared image name `isaac` (the GPU tests resolve
# <hub>/isaac:test) and each suite pins its own per-run PROJECT_NAME, so only
# the build opts out of the pre-build shared-identity guard
# (script/checkout_identity.sh, base#1551). The opt-out is scoped to this one
# command, as the old step-level env was.
gpu_job_build() {
  local stage="$1"
  gpu_job_group "Build ${stage} stage (cached if unchanged)"
  ISAAC_ALLOW_SHARED_IDENTITY=1 ./script/build.sh -t "${stage}"
  gpu_job_endgroup
}

# The compose bind-mounts ${WS_PATH}/isaac-sim/* (kit / ov / nvidia shader +
# compute caches). With WS_PATH pinned to the checkout root these sources do
# not pre-exist, so the docker daemon (root) would auto-create them
# root-owned, unwritable by the non-root container user. The symptom is
# silent: the RTX Hydra engine + shader cache fail to initialize, no camera
# frames are rendered, and camera assertions fail with no obvious cause.
# Creating the leaf dirs as the runner user makes the mounts writable. They
# are gitignored and wiped by checkout's clean step, so the cache is cold
# each run.
gpu_job_cache_dirs() {
  gpu_job_group "Pre-create Isaac Sim cache mount dirs (writable)"
  mkdir -p \
    isaac-sim/kit/cache isaac-sim/kit/data isaac-sim/kit/logs \
    isaac-sim/ov/cache isaac-sim/ov/data isaac-sim/ov/logs \
    isaac-sim/pip isaac-sim/nvidia/glcache \
    isaac-sim/nvidia/computecache isaac-sim/documents
  gpu_job_endgroup
}
