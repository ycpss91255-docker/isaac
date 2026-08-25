# Minimal fixture for the build-worker System self-test (self-test.yaml's
# worker-selftest job).
#
# self-test.yaml's `worker-selftest` job invokes the shared reusable worker
# (`uses: ./.github/workflows/build-worker.yaml`) against THIS Dockerfile to
# exercise the build-gate ORCHESTRATION end-to-end -- preflight, matrix,
# and the four-stage build/push pipeline actually run -- so a semantic break
# in the worker (an input that became required, a broken cache change, a
# matrix that produces no jobs, a removed build step) turns the self-test
# RED. The point is to test the worker, NOT to build a real image, so every
# stage is a trivial alpine no-op that builds in seconds.
#
# The stage names mirror the four targets the worker builds
# (devel / devel-test / runtime / runtime-test); the `sys` base declares the
# USER_* / HARDWARE build-args the worker always passes, and the two -test
# stages declare TEST_TOOLS_IMAGE (passed to them), so no build-arg the
# worker forwards is left unconsumed.
FROM alpine:3 AS sys
ARG USER_NAME=ci
ARG USER_GROUP=ci
ARG USER_UID=1000
ARG USER_GID=1000
ARG HARDWARE=x86_64
RUN true

FROM sys AS devel
RUN true

FROM devel AS devel-test
ARG TEST_TOOLS_IMAGE
RUN true

FROM sys AS runtime
RUN true

FROM runtime AS runtime-test
ARG TEST_TOOLS_IMAGE
RUN true
