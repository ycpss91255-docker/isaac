#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

source "${REPO_ROOT}/.env" 2>/dev/null || true

PUBLIC_IP="${PUBLIC_IP:-127.0.0.1}"

echo "[web-viewer] Building with SIGNALING_SERVER=${PUBLIC_IP}"
docker compose -f "${SCRIPT_DIR}/docker-compose.yaml" build \
  --build-arg "SIGNALING_SERVER=${PUBLIC_IP}" "$@"
