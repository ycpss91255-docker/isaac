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
# Usage: ./script/init_isaac_dirs.sh
# Idempotent: subsequent runs are a no-op.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${script_dir}/.env" ]]; then
  echo "[init_isaac_dirs] ERROR: ${script_dir}/.env not found." >&2
  echo "[init_isaac_dirs] Run ./build.sh once first to trigger setup.sh and generate .env." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${script_dir}/.env"

if [[ -z "${WS_PATH:-}" ]]; then
  echo "[init_isaac_dirs] ERROR: WS_PATH not set in .env" >&2
  exit 1
fi

base="${WS_PATH}/isaac-sim"
dirs=(
  "${base}/cache/kit"
  "${base}/cache/ov"
  "${base}/cache/pip"
  "${base}/cache/glcache"
  "${base}/cache/computecache"
  "${base}/logs"
  "${base}/data"
  "${base}/documents"
)

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
  exit 2
fi

mkdir -p "${dirs[@]}"

echo "[init_isaac_dirs] OK — ${#dirs[@]} cache dirs ready under ${base}/"
echo "[init_isaac_dirs] Next: ./build.sh && ./run.sh"
