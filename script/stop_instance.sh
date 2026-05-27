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
wv_container="owv-${id}"

for name in "${wv_container}" "${container_name}"; do
  if docker ps -q --filter "name=^${name}$" | grep -q .; then
    docker stop "${name}"
    echo "[stop_instance] Container '${name}' stopped."
  else
    echo "[stop_instance] Container '${name}' not running."
  fi
done
