#!/usr/bin/env bash
# post-run hook: host-side, runs after run.sh main logic.
# Receives the same "$@" as run.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{run}.sh runs with --dry-run.
exit 0
