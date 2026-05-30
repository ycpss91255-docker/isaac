#!/usr/bin/env bash
# pre-build hook: host-side, runs before build.sh main logic.
# Receives the same "$@" as build.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{build}.sh runs with --dry-run.
exit 0
