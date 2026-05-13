#!/usr/bin/env bash
#
# _lib.sh - Umbrella loader for the focused sub-libs under lib/.
#
# Sourced (not executed) by build.sh / run.sh / exec.sh / stop.sh / setup.sh
# for the full helper set. Lighter callers (init.sh / upgrade.sh / ci.sh)
# can source only what they need (e.g. lib/log.sh for just `_log_*`) once
# they get migrated; until then _lib.sh stays as the back-compat umbrella.
#
# Sub-libs (sourced in dependency order):
#   lib/log.sh             : _log_err / _log_warn / _log_info / _log_color_enabled
#   lib/env.sh             : _load_env
#   lib/conf.sh            : _dump_conf_section
#   lib/compose.sh         : _compute_project_name / _compose / _compose_project
#   lib/config_summary.sh  : _lib_msg + _print_config_summary
#                            (depends on lib/conf.sh — sourced first above)
#
# Style: Google Shell Style Guide.
# Closes #284.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SOURCED=1

_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# i18n.sh is a sibling of _lib.sh (existing convention pre-#284, kept for
# back-compat with the /lint/ stage layout where the Dockerfile COPYs the
# flat helper set without lib/). Sourced first so every sub-lib sees _LANG.
# shellcheck disable=SC1091
source "${_lib_dir}/i18n.sh"

# Sub-libs in dependency order. config_summary.sh uses _dump_conf_section
# from conf.sh, so conf.sh must be sourced first.
# shellcheck disable=SC1091
source "${_lib_dir}/lib/log.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/lib/env.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/lib/conf.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/lib/compose.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/lib/config_summary.sh"
unset _lib_dir
