#!/usr/bin/env bash
# pre-prune hook: host-side, runs before prune.sh main logic.
# Receives the same "$@" as prune.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{prune}.sh runs with --dry-run.
exit 0
