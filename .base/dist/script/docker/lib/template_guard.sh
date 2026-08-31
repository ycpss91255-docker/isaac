#!/usr/bin/env bash
#
# template_guard.sh - refuse to run init / upgrade inside the base template
# source itself.
#
# init.sh / upgrade.sh self-locate the subtree root by walking up to the dir
# carrying `.version` + `dist/` (ADR-00000011 sec.8). That root is then used
# as the subtree, and its PARENT as the repo root to scaffold / subtree-pull
# into. The walk-up cannot, on its own, tell "I am a vendored `.base/`
# subtree inside a consumer" from "I am the base template SOURCE itself":
# both carry `.version` + `dist/`.
#
# The distinguisher is `.git`. A vendored subtree never carries `.git` --
# the consumer's `.git` lives at the consumer repo root, OUTSIDE the subtree.
# The base template source, by contrast, IS a git checkout (or worktree), so
# its subtree root carries `.git` (a dir for a normal checkout, a file for a
# worktree -- `-e` catches both). Running init / upgrade there would resolve
# the repo root to base's PARENT dir and pollute it. This guard refuses that.
# It deliberately does NOT hardcode the subtree basename, so a renamed
# subtree prefix keeps working.
#
# Style: Google Shell Style Guide.

# _assert_not_template_source <subtree_root> [service]
#   Return non-zero (and log an actionable error) when <subtree_root> carries
#   `.git` -- i.e. it is the base template source, not a vendored subtree.
#   `service` (default "base") tags the log line for the calling script.
#   The caller decides whether to exit on the non-zero return.
_assert_not_template_source() {
  local _root="${1}" _service="${2:-base}"
  if [[ -e "${_root}/.git" ]]; then
    _log_err "${_service}" base_self_run_refused \
      "display=refusing to run inside the base template source itself: ${_root} carries .git (a git checkout/worktree, not a vendored .base/ subtree). This script initializes/upgrades a downstream repo that has vendored base as a .base/ subtree -- run it from that repo (see README Prerequisites)."
    return 1
  fi
  return 0
}
