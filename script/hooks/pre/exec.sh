#!/usr/bin/env bash
# pre-exec hook: host-side, runs before exec.sh main logic.
# Receives the same "$@" as exec.sh. Non-zero exit aborts the wrapper.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{exec}.sh runs with --dry-run.
exit 0
