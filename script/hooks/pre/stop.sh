#!/usr/bin/env bash
# pre-stop hook: host-side, runs before stop.sh main logic.
# Receives the same "$@" as stop.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{stop}.sh runs with --dry-run.
exit 0
