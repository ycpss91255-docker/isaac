#!/usr/bin/env bash
# runheadless-host-config.sh -- build the full Isaac Sim livestream
# invocation from container env + per-host config, then exec the Kit
# launcher.
#
# This is the single place that constructs the livestream Kit args.
# Before base #465/#440 the same args were duplicated in the retired
# host-side run_instance.sh; they now live only here and the per-instance
# values arrive as container env (compose overlay) + /etc/host.yaml.
#
#   ports          ISAAC_SIGNAL_PORT -> --/app/livestream/port
#                  ISAAC_MEDIA_PORT  -> --/app/livestream/fixedHostPort
#                  ISAAC_API_PORT    -> --/exts/omni.services.transport.server.http/port
#                  Each is omitted when unset, so Kit falls back to its
#                  own default (default-instance case).
#   public address network.public_ip from /etc/host.yaml (mounted by the
#                  post-run hook). Absent/empty -> no publicEndpointAddress
#                  arg; Isaac advertises its container IP, which is fine
#                  for localhost-only WebRTC sessions.
#
# Lives in /usr/local/bin/ (COPY'd by the Dockerfile devel stage).
#
# Test seams (production defaults unchanged):
#   HOST_YAML_LIB         shared parser path (default /usr/local/lib/host_yaml.sh)
#   HOST_YAML_FILE        per-host config path (default /etc/host.yaml)
#   RUNHEADLESS_DRYRUN=1  print the resolved command line instead of exec
set -euo pipefail

# Shared, validated parser (strips inline comments, rejects garbage) so
# this container-side wrapper and the host-side hook never drift (#104).
# COPY'd next to runheadless by the Dockerfile devel stage.
# shellcheck source=host_yaml.sh
. "${HOST_YAML_LIB:-/usr/local/lib/host_yaml.sh}"

PUBLIC_IP="$(resolve_public_ip "${HOST_YAML_FILE:-/etc/host.yaml}")" || exit 1

kit_args=(
  -v
  --/app/livestream/nvcf/quitOnSessionEnded=false
)

if [ -n "${ISAAC_SIGNAL_PORT:-}" ]; then
  kit_args+=("--/app/livestream/port=${ISAAC_SIGNAL_PORT}")
fi
if [ -n "${ISAAC_MEDIA_PORT:-}" ]; then
  kit_args+=("--/app/livestream/fixedHostPort=${ISAAC_MEDIA_PORT}")
fi
if [ -n "${ISAAC_API_PORT:-}" ]; then
  kit_args+=("--/exts/omni.services.transport.server.http/port=${ISAAC_API_PORT}")
fi
if [ -n "${PUBLIC_IP}" ]; then
  kit_args+=("--/app/livestream/publicEndpointAddress=${PUBLIC_IP}")
fi

if [ "${RUNHEADLESS_DRYRUN:-0}" = "1" ]; then
  printf '%s\n' "/isaac-sim/runheadless.sh" "${kit_args[@]}" "$@"
  exit 0
fi

exec /isaac-sim/runheadless.sh "${kit_args[@]}" "$@"
