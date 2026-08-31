#!/usr/bin/env bash
# isaac GPU CI suite, invoked by the org reusable workflow
# (ycpss91255-docker/.github gpu-self-hosted.yml) after checkout on the
# self-hosted GPU runner. The cross-cutting concerns -- the fork-PR safety
# gate, self-hosted runner selection, and pre-checkout root-owned-residue
# cleanup -- live in that reusable workflow. This script owns ONLY isaac's
# bespoke build/test logic. See ADR-0011 / ADR-0017.
#
# Shell flags match the GitHub default run shell (errexit + pipefail). -u is
# intentionally NOT set, to preserve the prior per-step behavior (the steps
# this script replaces did not run under nounset).
set -eo pipefail

# M1 stage gate (ADR-0017 section 7, isaac#130): hosted unit pytest needs no
# Isaac runtime and no GPU, so it runs in a plain Python container and gates
# every PR. assert_pytest_baseline.sh enforces all-green + collected >= the
# committed baseline (ratchet) + framework pure-surface coverage >= 80%. This
# is the M1 acceptance floor.
./test/assert_pytest_baseline.sh

# base detect_ws_path mis-detects the self-CI _work/<repo>/<repo> layout: none
# of its strategies (docker_* sibling, *_ws ancestor) match, so the parent-dir
# fallback returns _work/<repo> -- one level too high, leaving the repo at
# ~/work/<repo>/ inside the container. config/docker/setup.conf ships mount_1
# in portable ${WS_PATH} form, so `apply` re-detects WS_PATH locally and
# ignores a job-env override. Pin it in the derived .env.generated cache AFTER
# apply (the --env-file the wrappers pass to compose) so the devel-test compose
# mounts the repo root at ~/work -- fixing both the relative GPU test path
# (test/integration/pytest/) and the baked PYTHONPATH=~/work/framework.
# base follow-up: base#586.
./script/setup.sh apply
sed -i "s|^WS_PATH=.*|WS_PATH=${GITHUB_WORKSPACE}|" .env.generated

# Build the devel-test image (cached if unchanged).
./script/build.sh -t test

# Pre-create the Isaac Sim cache mount sources writable. The devel-test compose
# bind-mounts ${WS_PATH}/isaac-sim/* (kit / ov / nvidia shader + compute
# caches). With WS_PATH pinned to the checkout root these sources do not
# pre-exist, so the docker daemon (root) auto-creates them root-owned -- and the
# container runs as the non-root image user, so it cannot write them. The
# symptom is silent: the RTX Hydra engine + shader cache fail to initialize, no
# camera frames render, and the L3 / scaffold / cuda camera assertions fail with
# no obvious cause. Creating the leaf dirs here (as the runner user) makes the
# mounts writable. They are gitignored and cleared by checkout, so the cache is
# cold each run.
mkdir -p \
  isaac-sim/kit/cache isaac-sim/kit/data isaac-sim/kit/logs \
  isaac-sim/ov/cache isaac-sim/ov/data isaac-sim/ov/logs \
  isaac-sim/pip isaac-sim/nvidia/glcache \
  isaac-sim/nvidia/computecache isaac-sim/documents

# M2 GPU integration gate (PRD #4-int / isaac#132): boots headless Isaac for
# real on the self-hosted GPU runner and runs the example strong-assertion suite
# (L1-L4 + cmd_vel round-trip) plus the #127 camera smoke.
# assert_pytest_baseline.sh --gpu enforces: the GPU suite actually RAN
# (passed > 0 -- a skipped GPU job is NOT green), collected >=
# GPU_INTEGRATION_BASELINE (ratchet), and the cross-runner aggregate
# (HOSTED_UNIT + GPU_INTEGRATION) >= AGGREGATE_TARGET (the PRD 126 parity
# floor). With WS_PATH pinned to the checkout root, the repo root mounts at
# ~/work, so the in-container test path is test/integration/pytest/ (default).
# GPU_ROS_DOMAIN_ID isolates this run's /cmd_vel round-trip onto a private ROS 2
# domain (derived from the run id, non-zero) so the shared host network's domain
# 0 -- where leaked cross-container ros:humble siblings keep publishing /cmd_vel
# -- cannot bleed into io.latest(). See the env-wrapper note in
# assert_pytest_baseline.sh.
GPU_ROS_DOMAIN_ID="$(( (GITHUB_RUN_ID % 99) + 1 ))" ./test/assert_pytest_baseline.sh --gpu
