#!/usr/bin/env bash
# pre-run hook: host-side, runs before run.sh main logic.
# Receives the same "$@" as run.sh. Non-zero exit aborts the wrapper.
# Skipped when ./run.sh runs with --dry-run.
#
# 1. Refuses to run while this checkout still uses the image tag / compose
#    project that every checkout on this host shares (stopgap for
#    base#1550 / base#1551; see script/checkout_identity.sh). Fix once per
#    checkout with ./script/checkout_identity.sh isolate, or opt out
#    explicitly with ISAAC_ALLOW_SHARED_IDENTITY=1.
# 2. Creates the Isaac Sim cache mount sources as the host user before
#    compose mounts them (script/init_isaac_dirs.sh). Otherwise the daemon
#    creates them root-owned and Kit cannot write its caches.
set -euo pipefail

repo_root="${FILE_PATH:-$(pwd -P)}"
lib="${ISAAC_IDENTITY_LIB:-${repo_root}/script/checkout_identity.sh}"
bash "${lib}" guard run "${repo_root}"

init_dirs="${repo_root}/script/init_isaac_dirs.sh"
if [[ -x "${init_dirs}" ]]; then
  "${init_dirs}" --quiet
fi
