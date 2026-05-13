#!/usr/bin/env bash
#
# env.sh - .env file loader.
#
# Provides _load_env which sources a .env file under allexport so every
# assignment becomes an exported variable visible to `docker compose`.
#
# Split out from _lib.sh in #284.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_ENV_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_ENV_SOURCED=1

# _load_env sources the given .env file with allexport so every assignment
# becomes an exported variable visible to docker compose.
#
# Args:
#   $1: absolute path to .env file
_load_env() {
  local env_file="${1:?_load_env requires an env file path}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${env_file}"
  set +o allexport
}
