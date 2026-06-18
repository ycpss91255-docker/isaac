#!/usr/bin/env bash
# post-stop hook (base #440): host-side, runs after stop.sh main logic.
#
# Stop the web-viewer container that post/run.sh started outside compose.
# `stop.sh` tears down the compose (Isaac) containers but never sees the
# viewer, so the symmetric cleanup lives here.
#
# Single-sim only: same-repo multi-instance was removed (ADR-0019). The
# viewer container is the default `owv` (the same name post/run uses).
#
# Receives stop.sh's "$@". Skipped when stop.sh runs with --dry-run.
set -euo pipefail

wv_container="owv"

if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
  printf 'docker rm -f %s\n' "${wv_container}"
  exit 0
fi

docker rm -f "${wv_container}" >/dev/null 2>&1 || true
exit 0
