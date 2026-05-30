#!/usr/bin/env bash
# pre-run hook: host-side, runs before run.sh main logic.
# Receives the same "$@" as run.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{run}.sh runs with --dry-run.
exit 0
