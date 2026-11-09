#!/usr/bin/env bash
# init_isaac_dirs.sh — host-side mkdir for Isaac Sim cache dirs.
#
# Why this exists:
#   Docker auto-mkdirs missing bind-mount source paths as root when the
#   daemon runs as root. The container runs as a non-root user with
#   host-aligned UID; root-owned mount points yield permission denied
#   on first launch (shader cache writes, log files, etc.). Pre-creating
#   the dirs as the host user makes the bind mount inherit that ownership.
#
# It also runs from the pre-run hook (script/hooks/pre/run.sh), so a
# `just docker run` before this script no longer lets the daemon create
# the mount sources as root.
#
# Usage: ./script/init_isaac_dirs.sh [--quiet] [-h|--help]
# Idempotent: subsequent runs are a no-op.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./script/init_isaac_dirs.sh [--quiet] [-h|--help]

Create the 10 host-owned Isaac Sim cache dirs under ${WS_PATH}/isaac-sim/
before a container bind-mounts them (otherwise the docker daemon creates
them as root). Runs ./script/setup.sh apply first when .env.generated is
missing. Idempotent; the pre-run hook also runs it before every
`just docker run`.

Options:
  --quiet     Do not print the success summary.
  -h, --help  Show this help and exit.
USAGE
}

quiet=0
while (( $# > 0 )); do
  case "$1" in
    --quiet) quiet=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "[init_isaac_dirs] ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

script_dir="$(cd "$(dirname "$0")/.." && pwd)"
env_generated="${script_dir}/.env.generated"

# WS_PATH is resolved by base setup into .env.generated (.env is only the
# hand-edited workload overlay). On a fresh clone there is no cache yet:
# generate it through the base setup wrapper.
if [[ ! -f "${env_generated}" ]] && [[ -x "${script_dir}/script/setup.sh" ]]; then
  echo "[init_isaac_dirs] no .env.generated yet; running ./script/setup.sh apply"
  "${script_dir}/script/setup.sh" apply
fi
if [[ ! -f "${env_generated}" ]]; then
  echo "[init_isaac_dirs] ERROR: ${env_generated} not found." >&2
  echo "[init_isaac_dirs] Generate it with: ./script/setup.sh apply" >&2
  exit 1
fi

WS_PATH=""
while IFS= read -r line || [[ -n "${line}" ]]; do
  case "${line}" in
    WS_PATH=*) WS_PATH="${line#WS_PATH=}" ;;
  esac
done < "${env_generated}"

if [[ -z "${WS_PATH}" ]]; then
  echo "[init_isaac_dirs] ERROR: WS_PATH not set in ${env_generated}" >&2
  echo "[init_isaac_dirs] Regenerate it with: ./script/setup.sh apply" >&2
  exit 1
fi

base="${WS_PATH}/isaac-sim"
dirs=(
  "${base}/kit/cache"
  "${base}/kit/data"
  "${base}/kit/logs"
  "${base}/ov/cache"
  "${base}/ov/data"
  "${base}/ov/logs"
  "${base}/pip"
  "${base}/nvidia/glcache"
  "${base}/nvidia/computecache"
  "${base}/documents"
)

# Migration: pre-2026-05-21 layout used flat cache/, logs/, data/ paths
# alongside namespaced kit/cache. Refactor (issue ycpss91255-docker/isaac#21
# fix-A) renamed everything under kit/ / ov/ / pip/ / nvidia/ namespaces.
# Move any pre-existing host data to the new locations on first run so
# users do not lose accumulated shader / pip / compute caches.
declare -A migrations=(
  ["${base}/cache/kit"]="${base}/kit/cache"
  ["${base}/cache/ov"]="${base}/ov/cache"
  ["${base}/cache/pip"]="${base}/pip"
  ["${base}/cache/glcache"]="${base}/nvidia/glcache"
  ["${base}/cache/computecache"]="${base}/nvidia/computecache"
  ["${base}/logs"]="${base}/ov/logs"
  ["${base}/data"]="${base}/ov/data"
)
migrated=()
for old in "${!migrations[@]}"; do
  new="${migrations[$old]}"
  if [[ -d "${old}" ]] && [[ ! -d "${new}" ]]; then
    mkdir -p "$(dirname "${new}")"
    mv "${old}" "${new}"
    migrated+=("${old} -> ${new}")
  fi
done
# Clean up empty parent dirs left over from the old layout.
rmdir "${base}/cache" 2>/dev/null || true

# Detect pre-existing root-owned dirs (the failure mode this script
# prevents) and abort with an actionable message rather than silently
# proceeding to a permission-denied build.
root_owned=()
for d in "${dirs[@]}"; do
  if [[ -d "${d}" ]] && [[ "$(stat -c '%u' "${d}")" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    root_owned+=("${d}")
  fi
done

if (( ${#root_owned[@]} > 0 )); then
  echo "[init_isaac_dirs] ERROR: the following dirs already exist with root ownership:" >&2
  printf '  %s\n' "${root_owned[@]}" >&2
  echo >&2
  echo "[init_isaac_dirs] Container's non-root user cannot write to them. Fix with:" >&2
  echo "  sudo chown -R \"\$(id -u):\$(id -g)\" ${base}" >&2
  echo "or, without sudo:" >&2
  echo "  docker run --rm -v \"${base}:/x\" busybox:1 chown -R \"\$(id -u):\$(id -g)\" /x" >&2
  exit 2
fi

mkdir -p "${dirs[@]}"

# Kit creates documents/Kit/shared/screenshots with mode 000 when it does
# not exist yet, which later breaks anything that walks the tree (a docker
# build context, backups). Pre-create it 0755 and repair a mode-000 one.
screenshots="${base}/documents/Kit/shared/screenshots"
mkdir -p "${screenshots}"
chmod 0755 "${screenshots}"

if (( ${#migrated[@]} > 0 )); then
  echo "[init_isaac_dirs] migrated ${#migrated[@]} dirs to new layout:"
  printf '  %s\n' "${migrated[@]}"
fi
if (( ! quiet )); then
  echo "[init_isaac_dirs] OK — ${#dirs[@]} cache dirs ready under ${base}/"
  echo "[init_isaac_dirs] Next: just docker build && just docker run"
fi
