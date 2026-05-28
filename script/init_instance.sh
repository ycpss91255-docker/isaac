#!/usr/bin/env bash
# init_instance.sh — create per-instance cache dirs + env file.
#
# Usage: ./script/init_instance.sh <instance_id> [--base-signal-port N]
#
# Creates config/docker/instances/<id>.env with per-instance port
# assignments and instance/<id>/ cache directory tree (both relative
# to the docker repo root, gitignored).
#
# Instance IDs must match [a-z0-9_-] (Docker compose project name rules).
# Port assignment: auto-increments from base ports by instance index
# (alphabetical order of existing instances). Override in the generated
# .env file after creation.

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${script_dir}/.env" ]]; then
  echo "[init_instance] ERROR: ${script_dir}/.env not found." >&2
  echo "[init_instance] Run ./script/setup.sh apply first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${script_dir}/.env"

if [[ -z "${WS_PATH:-}" ]]; then
  echo "[init_instance] ERROR: WS_PATH not set in .env" >&2
  exit 1
fi

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/init_instance.sh <instance_id>

  instance_id   [a-z0-9_-]+ identifier (e.g. warehouse, test-01)

Creates:
  config/docker/instances/<id>.env  per-instance port + cache config
  instance/<id>/                    cache directory tree (gitignored)

Port auto-assignment: counts existing instances and offsets from base.
Edit the generated .env to override.
EOF
  exit 1
}

id="${1:-}"
[[ -z "${id}" ]] && _usage

if [[ ! "${id}" =~ ^[a-z0-9_-]+$ ]]; then
  echo "[init_instance] ERROR: instance ID must match [a-z0-9_-]+" >&2
  exit 1
fi

instances_dir="${script_dir}/config/docker/instances"
env_file="${instances_dir}/${id}.env"

if [[ -f "${env_file}" ]]; then
  echo "[init_instance] ERROR: ${env_file} already exists." >&2
  echo "[init_instance] Delete it first to regenerate, or edit it directly." >&2
  exit 1
fi

existing_count=0
if [[ -d "${instances_dir}" ]]; then
  existing_count=$(find "${instances_dir}" -maxdepth 1 -name '*.env' | wc -l)
fi

offset=$(( existing_count ))
signal_port=$(( 49100 + offset * 100 ))
media_port=$(( 47998 + offset * 100 ))
api_port=$(( 8011 + offset ))
viewer_port=$(( 5173 + offset ))

cache_dir_rel="instance/${id}"
cache_dir_abs="${script_dir}/${cache_dir_rel}"

mkdir -p "${instances_dir}"
cat > "${env_file}" <<EOF
# Per-instance configuration for: ${id}
#
# IMPORTANT: cache directories MUST NOT be shared between instances.
# Isaac Sim's Vulkan shader cache, Kit data, and OV texture cache use
# file locks that do not support concurrent write access from multiple
# processes. Sharing causes crashes (std::system_error, TfWeakPtr null,
# pthread_mutex ESRCH). Each instance needs its own INSTANCE_CACHE_DIR.
#
# Ports must also be unique per instance (TCP/UDP bind conflict).
# Edit the values below if the auto-assigned ports conflict with
# other services on this host.

# ── Ports ──────────────────────────────────────────────────────
ISAAC_SIGNAL_PORT=${signal_port}
ISAAC_MEDIA_PORT=${media_port}
ISAAC_API_PORT=${api_port}
VIEWER_PORT=${viewer_port}

# ── Cache ──────────────────────────────────────────────────────
# Root directory for this instance's caches. Subdirectories
# (kit/cache, kit/data, kit/logs, ov/cache, ov/data, ov/logs,
# nvidia/glcache, nvidia/computecache) are created automatically
# by init_instance.sh. DO NOT point two instances at the same dir.
#
# Accepts both relative (resolved against the docker repo root) and
# absolute paths. Edit to relocate (e.g. SSD-mounted cache):
#   INSTANCE_CACHE_DIR=/mnt/ssd/isaac-cache/${id}
INSTANCE_CACHE_DIR=${cache_dir_rel}
EOF

cache_subdirs=(
  "${cache_dir_abs}/kit/cache"
  "${cache_dir_abs}/kit/data"
  "${cache_dir_abs}/kit/logs"
  "${cache_dir_abs}/ov/cache"
  "${cache_dir_abs}/ov/data"
  "${cache_dir_abs}/ov/logs"
  "${cache_dir_abs}/nvidia/glcache"
  "${cache_dir_abs}/nvidia/computecache"
)

mkdir -p "${cache_subdirs[@]}"

root_owned=()
for d in "${cache_subdirs[@]}"; do
  if [[ -d "${d}" ]] && [[ "$(stat -c '%u' "${d}")" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    root_owned+=("${d}")
  fi
done

if (( ${#root_owned[@]} > 0 )); then
  echo "[init_instance] WARNING: root-owned dirs detected:" >&2
  printf '  %s\n' "${root_owned[@]}" >&2
  echo "[init_instance] Fix with: sudo chown -R \"\$(id -u):\$(id -g)\" ${cache_dir_abs}" >&2
fi

echo "[init_instance] Instance '${id}' created:"
echo "  env:   ${env_file}"
echo "  cache: ${cache_dir_abs}/  (relative: ${cache_dir_rel})"
echo "  ports: signal=${signal_port} media=${media_port} api=${api_port} viewer=${viewer_port}"
echo ""
echo "Next steps:"
echo "  1. Review/edit ${env_file}"
echo "  2. Start: ./script/run_instance.sh ${id} headless-stream"
