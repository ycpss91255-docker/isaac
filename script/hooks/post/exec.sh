#!/usr/bin/env bash
# post-exec hook: host-side, runs after exec.sh main logic.
# Receives the same "$@" as exec.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{exec}.sh runs with --dry-run.
exit 0
