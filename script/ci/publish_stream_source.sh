#!/usr/bin/env bash
#
# publish_stream_source.sh -- build the stream-source producer image, prove it
# streams, and only then push it (isaac#223 / isaac#252).
#
# Run by publish-stream-source.yaml through the org reusable workflow
# ycpss91255-docker/.github/.github/workflows/gpu-self-hosted.yml, which owns
# the self-hosted GPU runner, the fork-PR gate, the workspace reclaim, the
# checkout, Buildx, the GHCR login and the failure upload of .producer-smoke/.
# These steps used to be inline workflow steps; they keep their old names as
# log groups.
#
# Env:
#   IMAGE_TAG   the immutable tag to publish (required). The workflow
#               validates the workflow_dispatch input before passing it here;
#               it is checked again below so the script never builds or pushes
#               a ref it did not accept itself.
#   GITHUB_SHA  recorded in the image as the GIT_SHA build arg.
#
# Order, and why it matters: BUILD (no push) -> PROVE IT STREAMS -> PUSH.
# Nothing leaves this runner until producer_smoke.sh has passed. There is no
# override and no `|| true` on the proof: an image that cannot be proven to
# stream is precisely the image that must not be published (isaac#252).
# Guard: test/unit/pytest/test_stream_source_producer.py.
set -euo pipefail

readonly IMAGE_REPO="ghcr.io/ycpss91255-docker/isaac-stream-source"
# A docker tag: [A-Za-z0-9_] then up to 127 of [A-Za-z0-9_.-]. The same
# pattern the workflow's validate job applies to the dispatch input.
readonly TAG_PATTERN='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
# The smoke's own bound, previously the step's `timeout-minutes: 30`. The
# reusable workflow runs this whole script as one step, so the bound moves
# here; the job's 90-minute timeout still covers the build and the push.
readonly SMOKE_TIMEOUT="${PUBLISH_SMOKE_TIMEOUT:-30m}"

group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }

tag="${IMAGE_TAG:-}"
if ! [[ "${tag}" =~ ${TAG_PATTERN} ]]; then
  echo "::error::IMAGE_TAG must be a docker tag matching ${TAG_PATTERN} (got '${tag}')" >&2
  exit 2
fi
readonly IMAGE="${IMAGE_REPO}:${tag}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

# BUILD, do not push. --load puts the image in the local daemon so the smoke
# below runs exactly what would be pushed. GIT_SHA is recorded in the image
# so the version table (and anyone holding the image) can answer "which Isaac
# Sim / which commit" without pulling.
group "Build the producer image locally"
docker buildx build \
  --file Dockerfile \
  --target producer \
  --build-arg "GIT_SHA=${GITHUB_SHA:?}" \
  --tag "${IMAGE}" \
  --load \
  .
endgroup

# THE GATE. Boots the image the way a consumer does and asserts it binds its
# signalling port and serves a client. timeout sends TERM, which the smoke
# traps (exit 143) so its EXIT cleanup still saves the log and removes the
# container; set -e then stops this script before the push.
group "Prove the built image actually streams"
timeout "${SMOKE_TIMEOUT}" bash script/ci/producer_smoke.sh "${IMAGE}"
endgroup

# Only now.
group "Push the proven image"
docker push "${IMAGE}"
endgroup
