#!/usr/bin/env bash
# post-stop hook (base #440): host-side, runs after stop.sh main logic.
#
# Stop the web-viewer container that post/run.sh started outside compose.
# `stop.sh [--instance NAME]` tears down the compose (Isaac) containers
# but never sees the viewer, so the symmetric cleanup lives here.
# Replaces Makefile.local stop-stream + stop_instance.sh's viewer stop.
#
# Receives stop.sh's "$@". Skipped when stop.sh runs with --dry-run.
set -euo pipefail

instance=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance) instance="${2:-}"; shift 2 ;;
    --instance=*) instance="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

wv_container="owv-${instance:-default}"

if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
  printf 'docker rm -f %s\n' "${wv_container}"
  exit 0
fi

docker rm -f "${wv_container}" >/dev/null 2>&1 || true
exit 0
