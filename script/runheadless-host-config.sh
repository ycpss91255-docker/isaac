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

# Shared, validated parser (strips inline comments, rejects garbage) so
# this container-side wrapper and host-side run_instance.sh never drift
# (#104). COPY'd next to this script by the Dockerfile devel stage.
# shellcheck source=host_yaml.sh
. /usr/local/lib/host_yaml.sh

PUBLIC_IP="$(resolve_public_ip /etc/host.yaml)" || exit 1

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
