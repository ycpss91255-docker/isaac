#!/usr/bin/env bash
# runheadless wrapper that reads per-host config from /etc/host.yaml
# (mounted by caller from <repo>/config/host.yaml). Extracts
# network.public_ip and injects it as --/app/livestream/publicEndpointAddress.
# Falls back to no public-endpoint arg when yaml is absent or empty —
# Isaac Sim then advertises its container IP, which is fine for
# localhost-only WebRTC sessions.
#
# Lives in /usr/local/bin/ (COPY'd by Dockerfile devel stage).
set -euo pipefail

PUBLIC_IP=""
if [ -f /etc/host.yaml ]; then
  PUBLIC_IP=$(awk -F': *' '/^[[:space:]]*public_ip:/{gsub(/"/,""); print $2}' \
    /etc/host.yaml 2>/dev/null || true)
fi

if [ -n "${PUBLIC_IP}" ]; then
  exec /isaac-sim/runheadless.sh -v \
    --/app/livestream/nvcf/quitOnSessionEnded=false \
    --/app/livestream/publicEndpointAddress="${PUBLIC_IP}" \
    "$@"
else
  exec /isaac-sim/runheadless.sh -v \
    --/app/livestream/nvcf/quitOnSessionEnded=false \
    "$@"
fi
