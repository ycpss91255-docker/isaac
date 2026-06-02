#!/usr/bin/env bash
# run_instance.sh — start a named Isaac Sim instance with isolated
# cache dirs and unique ports.
#
# Usage: ./script/run_instance.sh <instance_id> [stage] [extra kit args...]
#
#   instance_id   Must match an existing config/instances/<id>.env
#   stage         headless (default) or stream
#   extra args    Forwarded to Isaac Sim Kit (e.g. scene USD path)
#
# Reads per-instance ports + cache dir from config/instances/<id>.env,
# shared settings from .env (USER_NAME, WS_PATH, etc.). Per-host config
# (PUBLIC_IP for WebRTC ICE) comes from config/host.yaml when present —
# mounted into both containers, read by entrypoint / wrapper (#65).
#
# Requires: docker compose (for image name), pid=host (setup.conf).

set -euo pipefail

script_dir="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=host_yaml.sh
source "${script_dir}/script/host_yaml.sh"

_usage() {
  cat >&2 <<'EOF'
Usage: ./script/run_instance.sh <instance_id> [stage] [extra kit args...]

  instance_id   Existing instance (created by init_instance.sh)
  stage         headless | stream (default: stream)

Example:
  ./script/run_instance.sh warehouse stream
  ./script/run_instance.sh factory headless
EOF
  exit 1
}

id="${1:-}"
[[ -z "${id}" ]] && _usage
shift

stage="${1:-stream}"
if [[ "${stage}" == "headless" || "${stage}" == "stream" ]]; then
  shift
fi

instance_env="${script_dir}/config/docker/instances/${id}.env"
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
INSTANCE_CACHE_DIR="${INSTANCE_CACHE_DIR:?INSTANCE_CACHE_DIR not set in instance env}"
# Resolve relative paths against the docker repo root; absolute paths used as-is.
case "${INSTANCE_CACHE_DIR}" in
  /*) ;;
  *) INSTANCE_CACHE_DIR="${script_dir}/${INSTANCE_CACHE_DIR}" ;;
esac
ISAAC_SIGNAL_PORT="${ISAAC_SIGNAL_PORT:?ISAAC_SIGNAL_PORT not set in instance env}"
ISAAC_MEDIA_PORT="${ISAAC_MEDIA_PORT:?ISAAC_MEDIA_PORT not set in instance env}"
ISAAC_API_PORT="${ISAAC_API_PORT:?ISAAC_API_PORT not set in instance env}"

IMAGE_NAME="${DOCKER_HUB_USER:-local}/${IMAGE_NAME}:${stage}"

container_name="isaac-${id}"

host_yaml="${script_dir}/config/host.yaml"
public_ip=""
if [[ -f "${host_yaml}" ]]; then
  # Shared, validated parser (strips inline comments, rejects garbage)
  # so host side and the container-side wrapper never drift (#104).
  public_ip="$(resolve_public_ip "${host_yaml}")" || exit 1
fi

kit_args=(
  /isaac-sim/runheadless.sh
  -v
  "--/app/livestream/nvcf/quitOnSessionEnded=false"
  "--/app/livestream/port=${ISAAC_SIGNAL_PORT}"
  "--/app/livestream/fixedHostPort=${ISAAC_MEDIA_PORT}"
  "--/exts/omni.services.transport.server.http/port=${ISAAC_API_PORT}"
)

if [[ -n "${public_ip}" ]]; then
  kit_args+=("--/app/livestream/publicEndpointAddress=${public_ip}")
fi

kit_args+=("$@")

host_yaml_mount=()
if [[ -f "${host_yaml}" ]]; then
  host_yaml_mount=(-v "${host_yaml}:/etc/host.yaml:ro")
fi

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
  -e ISAAC_LIVESTREAM="${stage##*-}" \
  "${host_yaml_mount[@]}" \
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

  # Defense in depth (#81 bug B): pass SIGNALING_SERVER explicitly
  # so the viewer JS bundle gets the right host IP even when the
  # owv:runtime image was built before omniverse_web_viewer#12 (the
  # entrypoint that reads /etc/host.yaml). When both are present the
  # entrypoint prefers /etc/host.yaml -- env stays a no-op fallback.
  local signaling_server_env=()
  if [[ -n "${public_ip}" ]]; then
    signaling_server_env=(-e "SIGNALING_SERVER=${public_ip}")
  fi

  # Idempotent re-run: a prior web-viewer with this name may still be up
  # (--rm only cleans up on stop). Mirror Makefile.local's run-stream.
  docker rm -f "${WV_CONTAINER}" >/dev/null 2>&1 || true

  docker run --rm -d \
    --name "${WV_CONTAINER}" \
    --network=host \
    "${host_yaml_mount[@]}" \
    "${signaling_server_env[@]}" \
    -e "SIGNALING_PORT=${ISAAC_SIGNAL_PORT}" \
    -e "SERVE_PORT=${VIEWER_PORT}" \
    -e "VIEWER_UI_MODE=stream-only" \
    -e "VIEWER_AUTO_LAUNCH=true" \
    "${WV_IMAGE}" >/dev/null

  if [[ -n "${public_ip}" ]]; then
    echo "[run_instance] Web-viewer '${WV_CONTAINER}' started (remote-ready) at http://${public_ip}:${VIEWER_PORT}"
  else
    echo "[run_instance] Web-viewer '${WV_CONTAINER}' started (localhost only) at http://localhost:${VIEWER_PORT}"
    echo "[run_instance]   For remote access, set network.public_ip in config/host.yaml."
  fi
}

# Web-viewer connects to the WebRTC stream, so it only makes sense on the
# stream stage; headless has no stream to show (#105).
if [[ "${stage}" != "stream" ]]; then
  echo "[run_instance] stage '${stage}' is not 'stream' — skipping web-viewer."
elif [[ -d "${WV_DIR}" ]] && [[ -f "${WV_DIR}/Dockerfile" ]] && [[ -d "${WV_DIR}/.base" ]]; then
  _start_web_viewer &
else
  # Dir + Dockerfile alone can pass for a shallow / non-recursive checkout
  # whose nested .base/ is missing -- the viewer Dockerfile COPYs from
  # .base/, so docker build would fail later. Require .base/ too (#109).
  echo "[run_instance] web_viewer/ submodule missing or not fully initialized — skipping web-viewer."
  echo "  Run: git submodule update --init --recursive web_viewer"
fi

echo "[run_instance] Wait for 'is loaded' then open browser at :${VIEWER_PORT}"
