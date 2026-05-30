#!/usr/bin/env bash
# pre-setup hook: host-side, runs before setup.sh main logic.
# Receives the same "$@" as setup.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{setup}.sh runs with --dry-run.
exit 0
