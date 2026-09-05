#!/usr/bin/env bash
# post-stop hook (base #440): host-side, runs after stop.sh main logic.
#
# Stop the web-viewer container that post/run.sh started outside compose.
# `stop.sh` tears down the compose (Isaac) containers but never sees the
# viewer, so the symmetric cleanup lives here.
#
# The viewer container is ${USER_NAME}-${IMAGE_NAME}-owv<suffix> -- the same
# name post/run creates -- so two isolated stacks on one host do not tear down
# each other's viewer (#237), and a stop reaps only its own project's viewer
# (isaac#238). base v0.42.0 removed INSTANCE_SUFFIX (base#666); the suffix is
# derived from the resolved PROJECT_NAME (sourced from .env.generated below),
# empty for the default project, reproducing today's exact name.
#
# Receives stop.sh's "$@". Skipped when stop.sh runs with --dry-run.
set -euo pipefail

repo_root="${FILE_PATH:-$(pwd -P)}"

# Identity vars for the viewer container name -- the same identity post/run
# uses. Under the base A2 model these live in .env.generated (USER_NAME /
# IMAGE_NAME / DOCKER_HUB_USER, resolved by setup.sh); .env is the user
# overlay layered on top. Source .generated FIRST, then .env so user edits
# win.
USER_NAME=""; IMAGE_NAME="isaac"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env.generated" ] && . "${repo_root}/.env.generated"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env" ] && . "${repo_root}/.env"

# Viewer suffix derived from the resolved compose project the same way
# post/run.sh derives it (replaces base's removed INSTANCE_SUFFIX, base#666):
# empty for the default project ${DOCKER_HUB_USER}-${IMAGE_NAME} or unset,
# "-<remainder>" for any distinct project.
_default_project="${DOCKER_HUB_USER:-local}-${IMAGE_NAME}"
if [ -n "${PROJECT_NAME:-}" ] && [ "${PROJECT_NAME}" != "${_default_project}" ]; then
  _viewer_suffix="-${PROJECT_NAME#"${_default_project}-"}"
else
  _viewer_suffix=""
fi
wv_container="${USER_NAME}-${IMAGE_NAME}-owv${_viewer_suffix}"

if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
  printf 'docker rm -f %s\n' "${wv_container}"
  exit 0
fi

docker rm -f "${wv_container}" >/dev/null 2>&1 || true
exit 0
