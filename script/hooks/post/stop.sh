#!/usr/bin/env bash
# post-stop hook: host-side, runs after stop.sh main logic.
# Receives the same "$@" as stop.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{stop}.sh runs with --dry-run.
exit 0
