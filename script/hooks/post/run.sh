#!/usr/bin/env bash
# post-run hook (base #440): host-side, runs after run.sh main logic
# (in run.sh's EXIT trap, while the container is still alive).
#
# After `run.sh -t stream -d [--instance NAME]` brings up the idle stream
# container, this:
#   1. validates config/host.yaml on the host and copies it into the
#      Isaac container at /etc/host.yaml (so the user's subsequent
#      `exec` -- driver script or runheadless-host-config.sh -- reads the
#      right public_ip);
#   2. starts the web-viewer :runtime container (stream-only); per-instance
#      ports come from the overlay env via `docker --env-file` (#123).
#
# It does NOT launch Isaac Sim: that stays an explicit `exec` step
# (driver or runheadless), matching the documented stream flow and
# avoiding a double-Kit conflict. Replaces Makefile.local run-stream +
# run_instance.sh _start_web_viewer.
#
# Gate: only the detached stream bring-up. headless / foreground / a
# driver CMD are no-ops. Receives run.sh's "$@".
set -euo pipefail

# --- parse run.sh argv: target, detach, instance ---
target="devel"; detach=0; instance=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t|--target) target="${2:-}"; shift 2 ;;
    --target=*) target="${1#*=}"; shift ;;
    -d|--detach) detach=1; shift ;;
    --instance) instance="${2:-}"; shift 2 ;;
    --instance=*) instance="${1#*=}"; shift ;;
    --) shift; break ;;
    *) shift ;;
  esac
done

[ "${target}" = "stream" ] || exit 0
[ "${detach}" -eq 1 ] || exit 0

repo_root="${FILE_PATH:-$(pwd -P)}"

# .env for container naming (defaults mirror the base template).
USER_NAME=""; IMAGE_NAME="isaac"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env" ] && . "${repo_root}/.env"

# Per-instance viewer ports: when a named instance has an overlay env,
# hand it to the viewer verbatim via `docker --env-file` (literal, no
# ${VAR} interpolation -- the file carries the viewer key NAMES). With no
# instance / no file, fall back to the literal default-instance ports.
inst_env="${repo_root}/config/instances/${instance}.env"
wv_port_args=(-e "SIGNALING_PORT=49100" -e "SERVE_PORT=5173")
if [ -n "${instance}" ] && [ -f "${inst_env}" ]; then
  wv_port_args=(--env-file "${inst_env}")
fi

suffix=""; [ -n "${instance}" ] && suffix="-${instance}"
isaac_container="${USER_NAME}-${IMAGE_NAME}-stream${suffix}"
wv_container="owv-${instance:-default}"
wv_image="${DOCKER_HUB_USER:-local}/omniverse_web_viewer:runtime"
host_yaml="${repo_root}/config/host.yaml"

_docker() {
  if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
    printf 'docker'; printf ' %s' "$@"; printf '\n'
  else
    docker "$@"
  fi
}

# 1. host.yaml -> Isaac container (validate on the host first; abort on garbage).
hy_mount=()
if [ -f "${host_yaml}" ]; then
  # shellcheck source=/dev/null
  . "${HOST_YAML_LIB:-${repo_root}/script/host_yaml.sh}"
  resolve_public_ip "${host_yaml}" >/dev/null || exit 1
  _docker cp "${host_yaml}" "${isaac_container}:/etc/host.yaml"
  hy_mount=(-v "${host_yaml}:/etc/host.yaml:ro")
fi

# 2. web-viewer (idempotent: drop a stale container first).
if [ "${POST_RUN_DRYRUN:-0}" = "1" ]; then
  printf 'docker rm -f %s\n' "${wv_container}"
else
  docker rm -f "${wv_container}" >/dev/null 2>&1 || true
fi

_docker run --rm -d --name "${wv_container}" --network=host \
  ${hy_mount[@]+"${hy_mount[@]}"} \
  "${wv_port_args[@]}" \
  -e "VIEWER_UI_MODE=stream-only" \
  "${wv_image}"

exit 0
