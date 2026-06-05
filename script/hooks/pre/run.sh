#!/usr/bin/env bash
# pre-run hook (base #440): host-side, runs before run.sh main logic.
#
# For `run.sh ... --instance NAME`, create that instance's per-instance
# cache directory tree on the host so the compose bind mounts inherit the
# caller's ownership (Isaac's Vulkan / Kit / OV caches use file locks that
# crash on root-owned or shared dirs). Salvages the mkdir + ownership
# logic from the retired init_instance.sh.
#
# No --instance -> no-op (the default instance's cache dirs are handled by
# init_isaac_dirs.sh). Receives run.sh's "$@"; non-zero exit aborts run.sh.
# Skipped when run.sh runs with --dry-run.
set -euo pipefail

# Parse --instance NAME out of run.sh's argv (ignore everything else).
instance=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --instance) instance="${2:-}"; shift 2 ;;
    --instance=*) instance="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

[ -z "${instance}" ] && exit 0   # default instance: nothing to do here

repo_root="${FILE_PATH:-$(pwd -P)}"
env_file="${repo_root}/config/instances/${instance}.env"
if [ ! -f "${env_file}" ]; then
  echo "[pre-run] WARNING: ${env_file} not found for instance '${instance}'; skipping cache dir setup." >&2
  exit 0
fi

# shellcheck source=/dev/null
. "${env_file}"

cache="${INSTANCE_CACHE_DIR:-}"
if [ -z "${cache}" ]; then
  echo "[pre-run] WARNING: INSTANCE_CACHE_DIR unset in ${env_file} (instance '${instance}'); skipping." >&2
  exit 0
fi
# Relative paths resolve against the repo root; absolute used as-is.
case "${cache}" in
  /*) ;;
  *) cache="${repo_root}/${cache}" ;;
esac

subdirs="kit/cache kit/data kit/logs ov/cache ov/data ov/logs nvidia/glcache nvidia/computecache"
for sub in ${subdirs}; do
  mkdir -p "${cache}/${sub}"
done

# Warn (do not fail) on root-owned cache dirs -- they trigger the
# cache-lock crashes init_instance.sh documented.
root_owned=""
for sub in ${subdirs}; do
  d="${cache}/${sub}"
  if [ -d "${d}" ] && [ "$(stat -c '%u' "${d}")" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    root_owned="${root_owned} ${d}"
  fi
done
if [ -n "${root_owned}" ]; then
  echo "[pre-run] WARNING: root-owned cache dirs for instance '${instance}':" >&2
  for d in ${root_owned}; do echo "  ${d}" >&2; done
  echo "[pre-run] Fix: sudo chown -R \"\$(id -u):\$(id -g)\" ${cache}" >&2
fi

exit 0
