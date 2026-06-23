#!/usr/bin/env bash
# stream_smoke.sh -- producer-side GPU smoke for the stream stage.
#
# Verifies the GPU-only path that hosted CI runners cannot: the Isaac Sim
# stream container boots and its WebRTC livestream signaling port comes up.
# No browser -- that is Tier B (#173). Runs on a GPU host or a self-hosted
# GPU runner.
#
# Flow: `just run -t stream -d` (idle container + viewer via post-run hook)
# -> `docker exec -d runheadless-host-config.sh` (launch Isaac) -> poll for
# the signaling port to listen -> PASS/FAIL -> tear down (always).
#
# Env knobs:
#   ISAAC_SIGNAL_PORT  signaling port to wait for (default 49100, Kit default)
#   SMOKE_TIMEOUT      seconds to wait for the port (default 600)
#
# Exit 0 = livestream up; 1 = container died / timeout (kit log tail printed).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
signal_port="${ISAAC_SIGNAL_PORT:-49100}"
timeout_s="${SMOKE_TIMEOUT:-600}"
smoke_log="${repo_root}/isaac-sim/kit/logs/stream-smoke.log"

# Container name = <USER_NAME>-<IMAGE_NAME>-stream. Identity lives in
# .env.generated (base A2 model), .env is the overlay -- same order as the hooks.
USER_NAME=""
IMAGE_NAME="isaac"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env.generated" ] && . "${repo_root}/.env.generated"
# shellcheck source=/dev/null
[ -f "${repo_root}/.env" ] && . "${repo_root}/.env"
container="${USER_NAME}-${IMAGE_NAME}-stream"

cleanup() {
  echo "[smoke] teardown: removing ${container} + owv"
  docker rm -f "${container}" owv >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "[smoke] bring up stream stage (idle container + viewer)"
# Direct wrapper call (matches the repo's own CI convention; no `just`
# dependency on the runner). The justfile `run` recipe is a 1:1 forward to this.
( cd "${repo_root}" && ./script/run.sh -t stream -d )

echo "[smoke] launch Isaac (detached) in ${container}"
docker exec -d "${container}" \
  sh -c '/usr/local/bin/runheadless-host-config.sh > /isaac-sim/kit/logs/stream-smoke.log 2>&1'

echo "[smoke] wait up to ${timeout_s}s for signaling port ${signal_port}"
deadline=$(( SECONDS + timeout_s ))
while [ "${SECONDS}" -lt "${deadline}" ]; do
  if ! docker ps --format '{{.Names}}' | grep -qx "${container}"; then
    echo "[smoke] FAIL: container ${container} is no longer running"
    tail -n 60 "${smoke_log}" 2>/dev/null || true
    exit 1
  fi
  if [ -n "$(ss -tlnH "sport = :${signal_port}" 2>/dev/null)" ]; then
    echo "[smoke] PASS: livestream signaling port ${signal_port} is listening"
    exit 0
  fi
  sleep 5
done

echo "[smoke] FAIL: signaling port ${signal_port} did not come up within ${timeout_s}s"
tail -n 60 "${smoke_log}" 2>/dev/null || true
exit 1
