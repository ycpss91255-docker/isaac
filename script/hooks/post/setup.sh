#!/usr/bin/env bash
# post-setup hook: host-side, runs after setup.sh main logic.
# Receives the same "$@" as setup.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{setup}.sh runs with --dry-run.
exit 0
