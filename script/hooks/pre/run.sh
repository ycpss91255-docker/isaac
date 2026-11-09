#!/usr/bin/env bash
# pre-run hook: host-side, runs before run.sh main logic.
# Receives the same "$@" as run.sh. Non-zero exit aborts the wrapper.
# Skipped when ./run.sh runs with --dry-run.
#
# Refuses to run while this checkout still uses the image tag / compose
# project that every checkout on this host shares (stopgap for base#1550 /
# base#1551; see script/checkout_identity.sh). Fix once per checkout with
# ./script/checkout_identity.sh isolate, or opt out explicitly with
# ISAAC_ALLOW_SHARED_IDENTITY=1.
set -euo pipefail

repo_root="${FILE_PATH:-$(pwd -P)}"
lib="${ISAAC_IDENTITY_LIB:-${repo_root}/script/checkout_identity.sh}"
exec bash "${lib}" guard run "${repo_root}"
