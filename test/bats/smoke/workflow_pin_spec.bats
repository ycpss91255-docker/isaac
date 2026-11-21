#!/usr/bin/env bats
# bats file_tags=core
#
# Guard: every reusable-workflow reference to the org's gpu-self-hosted.yml
# must be pinned to a release tag, never @main.
#
# Motivation: when .github's main branch is broken even briefly, every isaac
# push/PR that reaches core-gpu or stream-smoke fails with "workflow
# file issue" and 0 jobs (run 42776185240, 2026-11-10).  Pinning to a release
# tag insulates callers from upstream breakage.  Dependabot (github-actions
# ecosystem, weekly) creates bump PRs when a new tag is cut, so we still
# advance -- just deliberately.
#
# The base build-worker.yaml and release-worker.yaml references are already
# pinned (e.g. @v0.42.0); this spec covers gpu-self-hosted.yml.

bats_require_minimum_version 1.5.0

setup() {
  # Repo checkout: test/bats/smoke/ -> repo root.  devel-test image: the
  # Dockerfile bakes .github/workflows/ next to the specs (isaac#402).
  if [ -d "${BATS_TEST_DIRNAME}/../../../.github/workflows" ]; then
    WORKFLOW_DIR="${BATS_TEST_DIRNAME}/../../../.github/workflows"
  else
    WORKFLOW_DIR="${BATS_TEST_DIRNAME}/workflows"
  fi
  # A missing directory must fail, never pass vacuously.
  [ -d "${WORKFLOW_DIR}" ]
}

@test "no workflow references gpu-self-hosted.yml@main" {
  # Collect every 'uses:' line that references gpu-self-hosted.yml@main.
  local hits
  hits=$(grep -rn 'gpu-self-hosted\.yml@main' "${WORKFLOW_DIR}/" || true)
  if [ -n "${hits}" ]; then
    echo "Found unpinned gpu-self-hosted.yml@main references:"
    echo "${hits}"
    echo ""
    echo "Pin to a release tag (e.g. @v0.4.0) instead."
    return 1
  fi
}

@test "every gpu-self-hosted.yml caller is pinned to @v0.4.0" {
  local f
  for f in main.yaml ci-stream-smoke.yaml publish-stream-source.yaml; do
    [ -f "${WORKFLOW_DIR}/${f}" ] || { echo "missing caller: ${f}"; return 1; }
    grep -q 'gpu-self-hosted\.yml@v0\.4\.0' "${WORKFLOW_DIR}/${f}" \
      || { echo "${f} is not pinned to gpu-self-hosted.yml@v0.4.0"; return 1; }
  done
  # No gpu-self-hosted.yml ref anywhere may be a tag other than v0.4.0.
  local other
  other=$(grep -rn 'gpu-self-hosted\.yml@' "${WORKFLOW_DIR}/" \
    | grep -v 'gpu-self-hosted\.yml@v0\.4\.0' || true)
  if [ -n "${other}" ]; then
    echo "gpu-self-hosted.yml refs not at @v0.4.0:"
    echo "${other}"
    return 1
  fi
}

# --- isaac#344: run-scoped reap-container-filter on core-gpu ---------
# The reusable's cancel-safe "Remove run containers" step only runs when the
# caller passes reap-container-filter; unset, a cancelled run leaks its
# containers.  The workflow is parsed with a real YAML loader (never grepped),
# so a value under env:, in a comment or in another job cannot satisfy it.

_yaml_python() {
  local py
  for py in /isaac-sim/python.sh python3; do
    if "${py}" -c 'import yaml' >/dev/null 2>&1; then
      echo "${py}"
      return 0
    fi
  done
  return 1
}

# Print one field of the core-gpu job in main.yaml.
_gpu_integration_field() {
  local py
  py="$(_yaml_python)" || { echo "no python with PyYAML"; return 1; }
  "${py}" -c '
import sys, yaml
job = yaml.safe_load(open(sys.argv[1]))["jobs"]["core-gpu"]
field = sys.argv[2]
print(job["uses"] if field == "uses" else job["with"][field])
' "${WORKFLOW_DIR}/main.yaml" "$1"
}

@test "core-gpu passes the run-scoped reap-container-filter" {
  run _gpu_integration_field uses
  [ "${status}" -eq 0 ]
  [ "${output}" = "ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml@v0.4.0" ]

  run _gpu_integration_field reap-container-filter
  [ "${status}" -eq 0 ]
  [ "${output}" = 'label=com.docker.compose.project=isaac-baseline-${{ github.run_id }}-${{ github.run_attempt }}' ]
}

@test "reap-container-filter names the BASELINE_PROJECT gpu_integration_job.sh runs" {
  local src fake
  if [ -f "${BATS_TEST_DIRNAME}/gpu_integration_job.sh" ]; then
    src="${BATS_TEST_DIRNAME}"
  else
    src="${BATS_TEST_DIRNAME}/../../../script/ci"
  fi
  fake="$(mktemp -d)"
  mkdir -p "${fake}/script/ci" "${fake}/test"
  cp "${src}/gpu_job_lib.sh" "${src}/gpu_integration_job.sh" "${fake}/script/ci/"
  printf '#!/usr/bin/env bash\nprintf "WS_PATH=/x\\n" > .env.generated\n' > "${fake}/script/setup.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake}/script/build.sh"
  printf '#!/usr/bin/env bash\necho "${BASELINE_PROJECT}" > "${OBSERVED}"\n' \
    > "${fake}/test/assert_pytest_baseline.sh"
  chmod +x "${fake}"/script/*.sh "${fake}"/script/ci/*.sh "${fake}"/test/*.sh

  GITHUB_WORKSPACE="${fake}" GITHUB_RUN_ID=111 GITHUB_RUN_ATTEMPT=2 \
    OBSERVED="${fake}/observed.txt" \
    bash "${fake}/script/ci/gpu_integration_job.sh" >/dev/null
  local project
  project="$(cat "${fake}/observed.txt")"
  [ -n "${project}" ]

  run _gpu_integration_field reap-container-filter
  [ "${status}" -eq 0 ]
  local rendered="${output}"
  rendered="${rendered//'${{ github.run_id }}'/111}"
  rendered="${rendered//'${{ github.run_attempt }}'/2}"
  [ "${rendered}" = "label=com.docker.compose.project=${project}" ]
  rm -rf "${fake}"
}
