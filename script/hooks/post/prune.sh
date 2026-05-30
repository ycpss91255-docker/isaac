#!/usr/bin/env bash
# post-prune hook: host-side, runs after prune.sh main logic.
# Receives the same "$@" as prune.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{prune}.sh runs with --dry-run.
exit 0
