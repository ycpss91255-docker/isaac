#!/usr/bin/env bash
# Tee container stdout/stderr to a host file when [logging] local_path
# is set in .setup.conf. No-op when local_path is unset (default), so
# default-sourcing has zero side effect on stock repos. Helper is
# COPY'd into the image at /usr/local/lib/base/ by Dockerfile.example's
# devel stage (+).
#
# Both sources are guarded on readability: the devel stage always ships
# the helpers, but the runtime stage's COPYs are opt-in (commented out),
# and this file is seeded verbatim into every repo. A runtime image that
# skipped them must still start clean -- no missing-file stderr, and no
# abort for a consumer running the documented `set -euo pipefail`
# entrypoint. Same shape the helpers themselves use for logrotate.sh.
if [[ -r /usr/local/lib/base/logging.sh ]]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/base/logging.sh
fi
# Generic single-service watchdog. No-op when [lifecycle]
# watchdog_check is unset (WATCHDOG_CHECK empty), so this source line is
# safe unconditionally. When ON_FAIL=restart-service the watchdog
# supervises the service itself and this script does not reach `exec`.
if [[ -r /usr/local/lib/base/watchdog.sh ]]; then
  # shellcheck disable=SC1091
  . /usr/local/lib/base/watchdog.sh
fi

exec "${@}"
