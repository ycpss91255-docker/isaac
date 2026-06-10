#!/usr/bin/env bash
# Tee container stdout/stderr to a host file when [logging] local_path
# is set in setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by Dockerfile.example's
# devel stage (refs #364 + #368).
# shellcheck disable=SC1091
. /usr/local/lib/base/logging.sh

exec "${@}"
