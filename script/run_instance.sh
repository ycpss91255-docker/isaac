#!/usr/bin/env bash
# run_instance.sh — start a named Isaac Sim instance with isolated
# cache dirs and unique ports.
#
# Usage: ./script/run_instance.sh <instance_id> [stage] [extra kit args...]
#
#   instance_id   Must match an existing config/instances/<id>.env
#   stage         headless (default) or headless-stream
#   extra args    Forwarded to Isaac Sim Kit (e.g. scene USD path)
#
# Reads per-instance ports + cache dir from config/instances/<id>.env,
# shared settings from .env (PUBLIC_IP, USER_NAME, WS_PATH, etc.).
#
# Requires: docker compose (for image name), pid=host (setup.conf).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd)"

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/run_instance.sh <instance_id> [stage] [extra kit args...]

  instance_id   Existing instance (created by init_instance.sh)
  stage         headless | headless-stream (default: headless-stream)

Example:
  ./script/run_instance.sh warehouse headless-stream
  ./script/run_instance.sh factory headless
EOF
  exit 1
}

id="${1:-}"
[[ -z "${id}" ]] && _usage
shift

stage="${1:-headless-stream}"
if [[ "${stage}" == "headless" || "${stage}" == "headless-stream" ]]; then
  shift
fi

instance_env="${script_dir}/config/instances/${id}.env"
if [[ ! -f "${instance_env}" ]]; then
  echo "[run_instance] ERROR: ${instance_env} not found." >&2
  echo "[run_instance] Run ./script/init_instance.sh ${id} first." >&2
  exit 1
fi

if [[ ! -f "${script_dir}/.env" ]]; then
  echo "[run_instance] ERROR: ${script_dir}/.env not found." >&2
  echo "[run_instance] Run ./script/setup.sh apply first." >&2
  exit 1
fi

# shellcheck source=/dev/null
source "${script_dir}/.env"
# shellcheck source=/dev/null
source "${instance_env}"

USER_NAME="${USER_NAME:?USER_NAME not set in .env}"
WS_PATH="${WS_PATH:?WS_PATH not set in .env}"
PUBLIC_IP="${PUBLIC_IP:-}"
INSTANCE_CACHE_DIR="${INSTANCE_CACHE_DIR:?INSTANCE_CACHE_DIR not set in instance env}"
ISAAC_SIGNAL_PORT="${ISAAC_SIGNAL_PORT:?ISAAC_SIGNAL_PORT not set in instance env}"
ISAAC_MEDIA_PORT="${ISAAC_MEDIA_PORT:?ISAAC_MEDIA_PORT not set in instance env}"
ISAAC_API_PORT="${ISAAC_API_PORT:?ISAAC_API_PORT not set in instance env}"

IMAGE_NAME="${DOCKER_HUB_USER:-local}/${IMAGE_NAME}:${stage}"

container_name="isaac-${id}"

kit_args=(
  -v
  "--/app/livestream/nvcf/quitOnSessionEnded=false"
  "--/app/livestream/port=${ISAAC_SIGNAL_PORT}"
  "--/app/livestream/fixedHostPort=${ISAAC_MEDIA_PORT}"
  "--/exts/omni.services.transport.server.http/port=${ISAAC_API_PORT}"
)

if [[ -n "${PUBLIC_IP}" ]]; then
  kit_args+=("--/app/livestream/publicEndpointAddress=${PUBLIC_IP}")
fi

kit_args+=("$@")

cache="${INSTANCE_CACHE_DIR}"

echo "[run_instance] Starting instance '${id}' (${stage})"
echo "  container: ${container_name}"
echo "  ports:     signal=${ISAAC_SIGNAL_PORT} media=${ISAAC_MEDIA_PORT} api=${ISAAC_API_PORT}"
echo "  cache:     ${cache}"
echo "  image:     ${IMAGE_NAME}"

docker run --rm -d \
  --name "${container_name}" \
  --network=host --ipc=host --pid=host --privileged \
  --gpus all \
  -e ACCEPT_EULA=Y \
  -e PRIVACY_CONSENT=Y \
  -e PUBLIC_IP="${PUBLIC_IP}" \
  -e ISAAC_LIVESTREAM="${stage##*-}" \
  -v "${WS_PATH}:/home/${USER_NAME}/work" \
  -v "${cache}/kit/cache:/isaac-sim/kit/cache" \
  -v "${cache}/kit/data:/isaac-sim/kit/data" \
  -v "${cache}/kit/logs:/isaac-sim/kit/logs" \
  -v "${cache}/ov/cache:/home/${USER_NAME}/.cache/ov" \
  -v "${cache}/ov/data:/home/${USER_NAME}/.local/share/ov/data" \
  -v "${cache}/ov/logs:/home/${USER_NAME}/.nvidia-omniverse/logs" \
  -v "${cache}/nvidia/glcache:/home/${USER_NAME}/.cache/nvidia/GLCache" \
  -v "${cache}/nvidia/computecache:/home/${USER_NAME}/.nv/ComputeCache" \
  "${IMAGE_NAME}" \
  "${kit_args[@]}"

echo "[run_instance] Container '${container_name}' started."

VIEWER_PORT="${VIEWER_PORT:-5173}"
WV_DIR="${script_dir}/web_viewer"
WV_IMAGE="owv:runtime"
WV_CONTAINER="owv-${id}"

_start_web_viewer() {
  if ! docker image inspect "${WV_IMAGE}" >/dev/null 2>&1; then
    echo "[run_instance] Building web-viewer image (one-time)..."
    docker build -t "${WV_IMAGE}" "${WV_DIR}"
  fi

  docker run --rm -d \
    --name "${WV_CONTAINER}" \
    --network=host \
    -e "SIGNALING_SERVER=${PUBLIC_IP:-127.0.0.1}" \
    -e "SIGNALING_PORT=${ISAAC_SIGNAL_PORT}" \
    -e "SERVE_PORT=${VIEWER_PORT}" \
    "${WV_IMAGE}" >/dev/null

  echo "[run_instance] Web-viewer '${WV_CONTAINER}' started at http://${PUBLIC_IP:-localhost}:${VIEWER_PORT}"
}

if [[ -d "${WV_DIR}" ]] && [[ -f "${WV_DIR}/Dockerfile" ]]; then
  _start_web_viewer &
else
  echo "[run_instance] web_viewer/ submodule not found — skipping web-viewer."
  echo "  Run: git submodule update --init web_viewer"
fi

echo "[run_instance] Wait for 'is loaded' then open browser at :${VIEWER_PORT}"
