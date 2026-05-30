#!/usr/bin/env bash
#
# _lib.sh - Umbrella loader for the sub-libs in script/docker/lib/.
#
# Sourced (not executed) by wrapper scripts (build.sh / run.sh / etc.)
# for the full helper set. Lighter callers (init.sh / upgrade.sh / ci.sh)
# can source only what they need (e.g. log.sh for just `_log_*`).
#
# Style: Google Shell Style Guide.
# Closes #284, reorganized by #406.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SOURCED=1

_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck disable=SC1091
source "${_lib_dir}/i18n.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/log.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/env.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/conf.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/conf_logging.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/compose.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/config_summary.sh"
# shellcheck disable=SC1091
source "${_lib_dir}/hook.sh"
unset _lib_dir
