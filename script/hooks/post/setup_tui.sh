#!/usr/bin/env bash
# post-setup_tui hook: host-side, runs after setup_tui.sh main logic.
# Receives the same "$@" as setup_tui.sh. Non-zero exit fails the wrapper with this rc.
# Replace `exit 0` with your steps (binfmt register, mount dir prep, etc.).
# Skipped when ./{setup_tui}.sh runs with --dry-run.
exit 0
