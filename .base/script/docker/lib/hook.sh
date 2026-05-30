#!/usr/bin/env bash
#
# hook.sh -- per-wrapper pre/post hook helpers (#440).
#
# Each base wrapper (run.sh / build.sh / etc.) calls into this lib at
# two points:
#
#   _run_pre_hook <wrapper> "$@"   -- after env preparation, before main work
#   _run_post_hook <wrapper> "$@"  -- after main work (or in cleanup trap)
#
# The helpers look up downstream-owned scripts under:
#
#   ${FILE_PATH}/script/hooks/pre/<wrapper>.sh
#   ${FILE_PATH}/script/hooks/post/<wrapper>.sh
#
# Behaviour:
#   - File absent              -> silent no-op (return 0)
#   - File present + +x        -> exec with the wrapper's "$@"
#   - File present + NOT +x    -> hard fail (init.sh creates with +x;
#                                 removing it is explicit user action)
#   - Pre-hook non-zero exit   -> abort wrapper via `|| exit $?` at caller
#   - Post-hook non-zero exit  -> rc returned to caller; caller decides
#                                 (run.sh's trap overrides exit code,
#                                  other wrappers let it propagate)
#   - DRY_RUN=true             -> both pre and post silently skipped
#                                 (dry-run contract = no side effects)

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_HOOK_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_HOOK_SOURCED=1

# __hook_run <kind> <wrapper> "$@"
#
# Private dispatcher shared by _run_pre_hook / _run_post_hook. <kind>
# is "pre" or "post". <wrapper> is the wrapper basename without .sh.
# Stdout/stderr from the hook pass through; exit code propagates back
# to the caller.
__hook_run() {
  local _kind="${1:?"${FUNCNAME[0]}: missing kind"}"
  local _wrapper="${2:?"${FUNCNAME[0]}: missing wrapper name"}"
  shift 2

  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    return 0
  fi

  # Wrappers that resolve a repo root (run.sh, build.sh, exec.sh,
  # stop.sh, prune.sh) export FILE_PATH; setup.sh / setup_tui.sh
  # work with a local _base_path that never reaches the global env.
  # Fall back to $PWD so the helper stays safe regardless of which
  # wrapper called it, and gracefully no-ops if no hook file exists
  # at the resolved location.
  local _base="${FILE_PATH:-}"
  [[ -z "${_base}" ]] && _base="$(pwd -P)"
  local _hook="${_base}/script/hooks/${_kind}/${_wrapper}.sh"
  if [[ ! -e "${_hook}" ]]; then
    return 0
  fi
  if [[ ! -x "${_hook}" ]]; then
    printf '[hook] ERROR: %s exists but is not executable; chmod +x to enable\n' "${_hook}" >&2
    return 1
  fi
  "${_hook}" "$@"
}

# _run_pre_hook <wrapper> "$@"
#
# Run the pre-<wrapper> hook if present. Caller must propagate
# non-zero exit explicitly (`_run_pre_hook X "$@" || exit $?`) so the
# bash `set -e` + `&&`-chain quirk does not silently swallow the
# abort signal.
_run_pre_hook() {
  __hook_run "pre" "$@"
}

# _run_post_hook <wrapper> "$@"
#
# Run the post-<wrapper> hook if present. Caller decides what to do
# with a non-zero rc:
#   - run.sh's _app_cleanup trap captures the rc and overrides the
#     wrapper's exit (post-hook failure surfaces, cleanup still runs)
#   - Other wrappers let it propagate via normal shell exit
_run_post_hook() {
  __hook_run "post" "$@"
}
