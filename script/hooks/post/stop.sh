#!/usr/bin/env bash
# post-stop hook (base #440): host-side, runs after stop.sh main logic.
#
# Stop the web-viewer container that post/run.sh started outside compose.
# `stop.sh` tears down the compose (Isaac) containers but never sees the
# viewer, so the symmetric cleanup lives here.
#
# The viewer container is ${USER_NAME}-${IMAGE_NAME}-owv${INSTANCE_SUFFIX}
# -- the same name post/run creates -- so two isolated stacks on one host do
# not tear down each other's viewer (#237), and an instanced stop reaps only
# its own instance's viewer (isaac#238). stop.sh exports INSTANCE_SUFFIX via
# _compute_project_name (in _down_one) before firing this hook; the suffix is
# empty for the default stop, reproducing today's exact name.
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

wv_container="${USER_NAME}-${IMAGE_NAME}-owv${INSTANCE_SUFFIX:-}"

if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
  printf 'docker rm -f %s\n' "${wv_container}"
  exit 0
fi

docker rm -f "${wv_container}" >/dev/null 2>&1 || true
exit 0
