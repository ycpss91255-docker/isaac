#!/usr/bin/env bash
# post-build hook: host-side, runs after build.sh main logic.
# Receives the same "$@" as build.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{build}.sh runs with --dry-run.
exit 0
