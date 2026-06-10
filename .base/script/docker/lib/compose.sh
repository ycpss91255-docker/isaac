#!/usr/bin/env bash
#
# compose.sh - docker compose wrappers + project naming.
#
# Provides:
#   _compute_project_name <instance>  : derive INSTANCE_SUFFIX + PROJECT_NAME
#   _compose                          : `docker compose` wrapper honoring DRY_RUN
#   _compose_project                  : _compose with -p / -f / --env-file pre-filled
#
# Split out from _lib.sh in #284.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_COMPOSE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_COMPOSE_SOURCED=1

# _compose delegates its DRY_RUN echo/exec split to log.sh's
# _dry_run_cmd (#408-B), so pull log.sh in directly (idempotent via its
# own double-source guard) -- mirrors config_summary.sh. Keeps compose.sh
# self-sufficient when a caller sources it without the full _lib.sh.
_compose_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=script/docker/lib/log.sh
source "${_compose_dir}/log.sh"

# _compute_project_name derives INSTANCE_SUFFIX and PROJECT_NAME for the
# current invocation, and exports INSTANCE_SUFFIX so compose.yaml can resolve
# ${INSTANCE_SUFFIX:-} when computing container_name.
#
# Args:
#   $1: instance name (may be empty for the default instance)
#
# Requires:
#   DOCKER_HUB_USER, IMAGE_NAME already in the environment (from .env).
#
# Sets (and exports INSTANCE_SUFFIX):
#   INSTANCE_SUFFIX  e.g. "-foo" or ""
#   PROJECT_NAME     e.g. "alice-myrepo-foo"
_compute_project_name() {
  local instance="${1:-}"
  if [[ -n "${instance}" ]]; then
    INSTANCE_SUFFIX="-${instance}"
  else
    INSTANCE_SUFFIX=""
  fi
  export INSTANCE_SUFFIX
  # shellcheck disable=SC2034  # PROJECT_NAME is consumed by callers, not _lib.sh
  PROJECT_NAME="${DOCKER_HUB_USER}-${IMAGE_NAME}${INSTANCE_SUFFIX}"
}

# _compose runs `docker compose` with the given args, or prints what it would
# run if DRY_RUN=true. Use this instead of calling docker compose directly so
# every script honors --dry-run uniformly. Delegates the DRY_RUN echo/exec
# split to log.sh's _dry_run_cmd (#408-B) so the dry-run format lives in one
# place; output is byte-identical (`[dry-run] docker compose <%q args>`).
_compose() {
  _dry_run_cmd docker compose "$@"
}

# _compose_project runs `_compose` with -p / -f / --env-file pre-filled, so
# callers only need to pass the verb and its args.
#
# Requires:
#   PROJECT_NAME : set by _compute_project_name
#   FILE_PATH    : the repo root (where compose.yaml + .env.generated live)
#
# --env-file points at .env.generated (the derived interpolation cache,
# #502). The hand-authored .env workload overlay reaches containers via
# each service's `env_file: - .env` directive, not this CLI flag.
_compose_project() {
  _compose -p "${PROJECT_NAME}" \
    -f "${FILE_PATH}/compose.yaml" \
    --env-file "${FILE_PATH}/.env.generated" \
    "$@"
}

# _validate_instance_name <name>
#
# Strict validator for `run.sh --instance NAME` and the overlay path
# convention `config/instances/<name>.{yaml,env}` it derives. Rule
# `^[a-z0-9][a-z0-9_-]*$` matches the char class the project uses
# elsewhere (stage names, [logging.<svc>] sections, etc.).
#
# Stdout: silent on success. Stderr-style message printed to stderr
# AND stdout on failure so bats `assert_output --partial "instance
# name"` can pick it up either way; callers should redirect 2>&1 if
# they only consume stdout.
#
# Exit: 0 on accept, 1 on reject.
_validate_instance_name() {
  local _name="${1:-}"
  if [[ ! "${_name}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    printf 'instance name %q is invalid (must match ^[a-z0-9][a-z0-9_-]*$)\n' "${_name}" >&2
    return 1
  fi
  return 0
}

# _compose_project_with_overlay <yaml-or-empty> <env-or-empty> -- <verb> <args>
#
# Same as _compose_project, but prepends extra -f / --env-file flags
# for per-instance overlays (#465). Either or both overlay slots may
# be empty; missing files are silently skipped so a caller can pass
# both candidate paths without pre-checking file existence.
#
# Compose merge rules:
#   -f         later -f files deep-merge over earlier ones
#   --env-file later --env-file values win on conflicting keys
# Both follow "base then overlay" -- compose.yaml / .env first, then
# the instance-specific files.
_compose_project_with_overlay() {
  local _yaml="${1:-}"
  local _env="${2:-}"
  shift 2
  [[ "${1:-}" == "--" ]] && shift

  local -a _extra=()
  if [[ -n "${_yaml}" && -f "${_yaml}" ]]; then
    _extra+=(-f "${_yaml}")
  fi
  if [[ -n "${_env}" && -f "${_env}" ]]; then
    _extra+=(--env-file "${_env}")
  fi
  _compose_project "${_extra[@]}" "$@"
}
