#!/usr/bin/env bash
# stop_instance.sh — stop a named Isaac Sim instance.
#
# Usage: ./script/stop_instance.sh <instance_id>

set -euo pipefail

id="${1:-}"
if [[ -z "${id}" ]]; then
  echo "Usage: ./script/stop_instance.sh <instance_id>" >&2
  exit 1
fi

container_name="isaac-${id}"

if docker ps -q --filter "name=^${container_name}$" | grep -q .; then
  docker stop "${container_name}"
  echo "[stop_instance] Container '${container_name}' stopped."
else
  echo "[stop_instance] Container '${container_name}' not running."
fi
