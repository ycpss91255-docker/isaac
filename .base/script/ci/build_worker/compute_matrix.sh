#!/usr/bin/env bash
# compute_matrix.sh -- platform -> build matrix resolver for the reusable
# Docker build worker (build-worker.yaml).
#
# Parses the caller's comma-separated `platforms` input into the
# strategy.matrix `include` list the build job fans out over, mapping each
# supported platform to its native runner label + canonical HARDWARE
# build-arg value. This is the "a matrix condition that produces no jobs"
# semantic break the shared worker can suffer -- an empty or all-invalid
# platform list must FAIL LOUDLY here, not silently fan out to zero build
# jobs (which would leave the aggregator green with nothing built). It also
# rejects an unsupported platform up front with a plain-language message
# instead of failing deep in a build.
#
# Pushed down out of build-worker.yaml's inline `compute-matrix` step so the
# logic is host-testable under `just test` (System-level logic -> Unit
# level, ADR-00000018); the workflow keeps only the thin GITHUB_OUTPUT
# plumbing around this script's stdout.
#
# Input : PLATFORMS env var (comma-separated, e.g. "linux/amd64,linux/arm64").
#         Whitespace around entries and empty segments are tolerated.
# Output: the matrix JSON object `{"include":[...]}` on stdout.
# Exit  : 0 on success; 1 on an unsupported platform or an empty result
#         (with a message on stderr). The logic is CI-host-agnostic: only
#         build-worker.yaml binds the PLATFORMS env + stdout to GitHub.

set -euo pipefail

main() {
  local platforms="${PLATFORMS:-}"
  local items="" p

  local IFS=','
  # shellcheck disable=SC2206  # deliberate word-split on the comma IFS.
  local plats=(${platforms})
  unset IFS

  for p in "${plats[@]}"; do
    p="$(printf '%s' "${p}" | tr -d '[:space:]')"
    case "${p}" in
      linux/amd64)
        items+='{"platform":"linux/amd64","runner":"ubuntu-latest","hardware":"x86_64"},'
        ;;
      linux/arm64)
        items+='{"platform":"linux/arm64","runner":"ubuntu-24.04-arm","hardware":"aarch64"},'
        ;;
      "")
        continue
        ;;
      *)
        printf "compute_matrix: unsupported platform '%s'. Supported: linux/amd64, linux/arm64\n" \
          "${p}" >&2
        return 1
        ;;
    esac
  done

  if [[ -z "${items}" ]]; then
    printf "compute_matrix: No valid platforms found in '%s'\n" "${platforms}" >&2
    return 1
  fi

  printf '{"include":[%s]}\n' "${items%,}"
}

main "$@"
