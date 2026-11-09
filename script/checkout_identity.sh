#!/usr/bin/env bash
#
# checkout_identity.sh - give this checkout its own image tag and compose
# project, and refuse build/run/stop while it still uses the shared ones.
#
# Why this exists (stopgap until base#1550 / base#1551 land):
#   The committed .setup.conf pins `[image] rule_1 = string:isaac`, so every
#   checkout of this repo on one host resolves the same image tag
#   (<DOCKER_HUB_USER>/isaac:<stage>) and, because base derives the compose
#   project as <DOCKER_HUB_USER>-<IMAGE_NAME>, the same project
#   (<DOCKER_HUB_USER>-isaac). base's build then prunes the image the shared
#   tag pointed at -- often another checkout's -- and `stop` / `run` tear
#   down the whole project, including another checkout's containers.
#
#   base already supports a per-checkout, gitignored `.setup.conf.local`
#   layer (base ADR-00000025). `isolate` writes a per-checkout `[image]`
#   rule there; the image name then moves the tag, the derived project name
#   and the container names together. The pre build/run/stop hooks call
#   `guard` so a checkout that was never isolated fails loudly instead of
#   touching another checkout's images or containers.
#
# Usage:
#   checkout_identity.sh slug    [REPO_ROOT]   print this checkout's name
#   checkout_identity.sh isolate [REPO_ROOT]   write it to .setup.conf.local
#   checkout_identity.sh guard <build|run|stop> [REPO_ROOT]
#   checkout_identity.sh show    [REPO_ROOT]   print the resolved identity
#
# REPO_ROOT defaults to $FILE_PATH (set by the base wrappers), then to the
# repo this script lives in.
#
# Opt-out: ISAAC_ALLOW_SHARED_IDENTITY=1 lets build/run/stop proceed on the
# shared identity (CI's build steps use it; see .github/workflows/).

set -euo pipefail

# The image name every checkout resolved before isolation: the committed
# `.setup.conf` `[image] rule_1 = string:isaac`.
_ISAAC_SHARED_IMAGE="isaac"

# _identity_repo_root [path] -> prints the absolute repo root.
_identity_repo_root() {
  local _root="${1:-${FILE_PATH:-}}"
  if [[ -z "${_root}" ]]; then
    _root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
  fi
  (cd -- "${_root}" && pwd -P)
}

# isaac_checkout_slug <repo_root>
#
# Prints `isaac-<basename>-<hash>`: a readable part from the directory name
# and a hash of the full real path, so two checkouts that share a basename
# (~/a/isaac, ~/b/isaac) still differ. Lowercase [a-z0-9-] only, valid as a
# docker image path component and as a compose project name.
isaac_checkout_slug() {
  local _root
  _root="$(_identity_repo_root "${1:-}")"
  local _hash
  _hash="$(printf '%s' "${_root}" | sha256sum | cut -c1-8)"
  local _base
  _base="$(basename -- "${_root}" | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' | tr -s '-')"
  _base="${_base#-}"
  _base="${_base%-}"
  # Drop a leading "isaac" so ~/x/isaac gives isaac-<hash>, not isaac-isaac.
  _base="${_base#isaac}"
  _base="${_base#-}"
  _base="${_base:0:24}"
  _base="${_base%-}"
  if [[ -n "${_base}" ]]; then
    printf 'isaac-%s-%s\n' "${_base}" "${_hash}"
  else
    printf 'isaac-%s\n' "${_hash}"
  fi
}

# isaac_isolate_checkout <repo_root>
#
# Appends `[image] rule_1 = string:<slug>` to <repo_root>/.setup.conf.local
# unless that file already defines an [image] section (an operator's own
# choice wins). Idempotent. The next base wrapper call (or
# `./script/setup.sh apply`) regenerates .env.generated and compose.yaml.
isaac_isolate_checkout() {
  local _root
  _root="$(_identity_repo_root "${1:-}")"
  local _local="${_root}/.setup.conf.local"
  local _slug
  _slug="$(isaac_checkout_slug "${_root}")"

  if [[ -f "${_local}" ]] && grep -q '^[[:space:]]*\[image\][[:space:]]*$' "${_local}"; then
    printf '[checkout_identity] %s already defines [image]; leaving it as is.\n' \
      "${_local}"
    return 0
  fi
  {
    if [[ -s "${_local}" ]]; then
      printf '\n'
    fi
    printf '# Per-checkout image name (isaac script/checkout_identity.sh):\n'
    printf '# keeps this checkout'"'"'s image tag, compose project and containers\n'
    printf '# apart from every other checkout on this host (base#1550, base#1551).\n'
    printf '[image]\n'
    printf 'rule_1 = string:%s\n' "${_slug}"
  } >> "${_local}"
  printf '[checkout_identity] this checkout now builds and runs as "%s"\n' "${_slug}"
  printf '[checkout_identity] (written to %s)\n' "${_local}"
}

# _identity_load <repo_root>
#
# Reads IMAGE_NAME / PROJECT_NAME / DOCKER_HUB_USER from .env.generated into
# the _id_* globals. Returns 1 when there is no .env.generated yet.
_identity_load() {
  local _env="${1}/.env.generated"
  _id_image=""
  _id_project=""
  _id_hub=""
  [[ -f "${_env}" ]] || return 1
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    case "${_line}" in
      IMAGE_NAME=*) _id_image="${_line#IMAGE_NAME=}" ;;
      PROJECT_NAME=*) _id_project="${_line#PROJECT_NAME=}" ;;
      DOCKER_HUB_USER=*) _id_hub="${_line#DOCKER_HUB_USER=}" ;;
    esac
  done < "${_env}"
  _id_hub="${_id_hub:-local}"
  return 0
}

# isaac_identity_guard <build|run|stop> <repo_root>
#
# build: refuses the shared image name (the tag base would prune).
# run / stop: refuse the shared default project (the project base tears
#   down). A distinct PROJECT_NAME pinned in .env.generated -- what CI does
#   per run -- is already isolated and passes.
isaac_identity_guard() {
  local _verb="${1:?guard: missing verb (build|run|stop)}"
  local _root
  _root="$(_identity_repo_root "${2:-}")"
  _identity_load "${_root}" || return 0

  local _shared_project="${_id_hub}-${_ISAAC_SHARED_IMAGE}"
  local _what=""
  case "${_verb}" in
    build)
      if [[ "${_id_image}" == "${_ISAAC_SHARED_IMAGE}" ]]; then
        _what="image tag ${_id_hub}/${_ISAAC_SHARED_IMAGE}:<stage>"
      fi
      ;;
    run|stop)
      if [[ "${_id_project:-${_id_hub}-${_id_image}}" == "${_shared_project}" ]]; then
        _what="compose project ${_shared_project}"
      fi
      ;;
    *)
      printf '[checkout_identity] ERROR: unknown verb "%s" (build|run|stop)\n' \
        "${_verb}" >&2
      return 2
      ;;
  esac
  [[ -z "${_what}" ]] && return 0

  if [[ "${ISAAC_ALLOW_SHARED_IDENTITY:-0}" == "1" ]]; then
    printf '[checkout_identity] WARN: %s on the shared %s (ISAAC_ALLOW_SHARED_IDENTITY=1). Other checkouts on this host share it.\n' \
      "${_verb}" "${_what}" >&2
    return 0
  fi
  {
    printf '[checkout_identity] ERROR: refusing to %s: this checkout uses the shared %s.\n' \
      "${_verb}" "${_what}"
    printf '  Every checkout of this repo on this host resolves the same name, so\n'
    printf '  this %s could delete another checkout'"'"'s image or remove its containers\n' \
      "${_verb}"
    printf '  (base#1550, base#1551).\n'
    printf '  Fix, once per checkout:\n'
    printf '    ./script/checkout_identity.sh isolate\n'
    printf '  To proceed on the shared name anyway:\n'
    printf '    ISAAC_ALLOW_SHARED_IDENTITY=1 just docker %s ...\n' "${_verb}"
  } >&2
  return 3
}

# isaac_identity_show <repo_root>
isaac_identity_show() {
  local _root
  _root="$(_identity_repo_root "${1:-}")"
  if ! _identity_load "${_root}"; then
    printf 'no .env.generated yet; run ./script/setup.sh apply\n'
    return 0
  fi
  printf 'image:   %s/%s:<stage>\n' "${_id_hub}" "${_id_image}"
  printf 'project: %s\n' "${_id_project}"
}

_identity_main() {
  local _cmd="${1:-}"
  shift || true
  case "${_cmd}" in
    slug) isaac_checkout_slug "${1:-}" ;;
    isolate) isaac_isolate_checkout "${1:-}" ;;
    guard) isaac_identity_guard "${1:-}" "${2:-}" ;;
    show) isaac_identity_show "${1:-}" ;;
    -h|--help|"")
      sed -n '/^# Usage:/,/^# Opt-out/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      [[ -n "${_cmd}" ]]
      ;;
    *)
      printf 'checkout_identity.sh: unknown command "%s" (see --help)\n' "${_cmd}" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _identity_main "$@"
fi
