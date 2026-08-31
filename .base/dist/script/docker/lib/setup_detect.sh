#!/usr/bin/env bash
#
# setup_detect.sh - host detection + image-name / workspace-path resolution.
#
# The detect_* host probes (user, hardware, docker hub user, GPU, GUI, SSH-X11)
# and the name/path resolution (detect_image_name + its rule helpers' callers,
# detect_ws_path, _reconcile_workspace_path) that setup.sh uses to seed the
# generated config from the running host.
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# the conf accessors (lib/setup_conf.sh) + _setup_msg / globals in setup.sh;
# all resolve at call-time via the _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_SETUP_DETECT_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_SETUP_DETECT_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# detect_user_info
#
# Usage: detect_user_info <user_outvar> <group_outvar> <uid_outvar> <gid_outvar>
# ════════════════════════════════════════════════════════════════════
detect_user_info() {
  local -n __dui_user="${1:?"${FUNCNAME[0]}: missing user outvar"}"; shift
  local -n __dui_group="${1:?"${FUNCNAME[0]}: missing group outvar"}"; shift
  local -n __dui_uid="${1:?"${FUNCNAME[0]}: missing uid outvar"}"; shift
  local -n __dui_gid="${1:?"${FUNCNAME[0]}: missing gid outvar"}"

  __dui_user="${USER:-$(id -un)}"
  __dui_group="$(id -gn)"
  __dui_uid="$(id -u)"
  __dui_gid="$(id -g)"
}

# ════════════════════════════════════════════════════════════════════
# detect_hardware
#
# Usage: detect_hardware <outvar>
# ════════════════════════════════════════════════════════════════════
detect_hardware() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  _outvar="$(uname -m)"
}

# ════════════════════════════════════════════════════════════════════
# detect_docker_hub_user
#
# Tries docker info first, falls back to USER, then id -un
#
# Usage: detect_docker_hub_user <outvar>
# ════════════════════════════════════════════════════════════════════
detect_docker_hub_user() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  local _name=""
  _name="$(docker info 2>/dev/null | awk '/^[[:space:]]*Username:/{print $2}')" || true
  _outvar="${_name:-${USER:-$(id -un)}}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu
#
# Checks nvidia-container-toolkit via dpkg-query
#
# Usage: detect_gpu <outvar>
# outvar: "true" or "false"
# ════════════════════════════════════════════════════════════════════
detect_gpu() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  # Read the whole dpkg-query stream and match in-shell. Piping into
  # `grep -q '^ii'` handed the answer to a reader that stops reading:
  # grep leaves the instant it matches, the dpkg-query still writing takes
  # SIGPIPE and exits 141, and setup.sh's `pipefail` makes 141 the
  # PIPELINE's status -- which the `if` reads as "not installed". An
  # INSTALLED toolkit was reported missing, and nothing failed: setup just
  # wrote a GPU-less .env on a GPU host.
  #
  # `__dg_`-prefixed local for the same reason detect_gpu_count uses
  # `__dgc_`: a bash nameref rebinds to the nearest local of the same
  # name, so a caller whose outvar is named `_line` would silently lose
  # the write.
  local __dg_line
  _outvar=false
  while IFS= read -r __dg_line || [[ -n "${__dg_line}" ]]; do
    if [[ "${__dg_line}" == ii* ]]; then
      _outvar=true
    fi
  done < <(dpkg-query -W -f='${db:Status-Abbrev}\n' -- "nvidia-container-toolkit" 2>/dev/null)
}

# ════════════════════════════════════════════════════════════════════
# detect_gpu_count
#
# Queries `nvidia-smi -L` for the number of installed NVIDIA GPUs. Emits
# "0" when nvidia-smi is missing or returns non-zero (host has no GPU,
# or the driver stack is broken). TUI uses this to show "Detected N"
# alongside the `[deploy] gpu_count` prompt.
#
# Usage: detect_gpu_count <outvar>
# ════════════════════════════════════════════════════════════════════
detect_gpu_count() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  # Use `__dgc_`-prefixed locals to avoid nameref shadowing when callers
  # name their outvar `_n` or `_line` — bash namerefs rebind to the nearest
  # local of the same name, which silently drops writes to the caller.
  local __dgc_n=0 __dgc_line
  if command -v nvidia-smi >/dev/null 2>&1; then
    while IFS= read -r __dgc_line; do
      if [[ "${__dgc_line}" == "GPU "* ]]; then
        __dgc_n=$(( __dgc_n + 1 ))
      fi
    done < <(nvidia-smi -L 2>/dev/null || true)
  fi
  _outvar="${__dgc_n}"
}

# ════════════════════════════════════════════════════════════════════
# detect_gui
#
# Returns "true" if host has X11 or Wayland display set, "false" otherwise.
#
# Usage: detect_gui <outvar>
# ════════════════════════════════════════════════════════════════════
detect_gui() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    _outvar=true
  else
    _outvar=false
  fi
}

# ════════════════════════════════════════════════════════════════════
# _is_ssh_x11
#
# Detect if the current session is using SSH X11 forwarding.
# Returns 0 (success) when SSH_CONNECTION is set AND DISPLAY matches
# the "localhost:N[.M]" pattern that SSH writes for X11 tunnels.
# Returns non-zero otherwise (local X session, no display, etc.).
#
# Used by the SSH X11 cookie-rewrite + non-host-network warn path
# in apply flow (refs base#321).
# ════════════════════════════════════════════════════════════════════
_is_ssh_x11() {
  [[ -n "${SSH_CONNECTION:-}" ]] || return 1
  [[ "${DISPLAY:-}" =~ ^localhost:[0-9]+(\.[0-9]+)?$ ]] || return 1
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _setup_ssh_x11_cookie <file_path>
#
# Rewrite the X11 authentication cookie for the current DISPLAY so it
# is accepted regardless of hostname (the container's hostname differs
# from the host's). Standard `ssh + Docker + X11` recipe:
#
#   xauth nlist $DISPLAY | sed 's/^..../ffff/' | xauth -f <out> nmerge -
#
# The `ffff` family code in the cookie's first 4 bytes tells libX11
# "ignore the hostname when matching", so the container can find the
# cookie under its own hostname. The rewritten cookie is written to
# `<file_path>/.docker.xauth`, which gets mounted into the container by
# generate_compose_yaml's existing XAUTHORITY mount line (XAUTHORITY
# in .env points at this path; see write_env's _ssh_x11_xauth arg).
#
# Echoes the absolute path on success. Returns non-zero (and logs a
# warning) if `xauth` is not installed; caller should fall through to
# leaving XAUTHORITY untouched in .env. Refs base#321.
#
# Usage:
#   local _xauth_path
#   _xauth_path="$(_setup_ssh_x11_cookie "${_file_path}")" || _xauth_path=""
# ════════════════════════════════════════════════════════════════════
_setup_ssh_x11_cookie() {
  local _file_path="${1:?_setup_ssh_x11_cookie requires <file_path>}"
  if ! command -v xauth >/dev/null 2>&1; then
    _log_warn setup ssh_x11_no_xauth "display=SSH X11 forwarding detected but 'xauth' is not in PATH; skipping cookie rewrite. Install xauth (apt: x11-xauth-utils) and re-run setup."
    return 1
  fi
  local _out="${_file_path}/.docker.xauth"
  : > "${_out}"
  # `-i` (ignore locks) bypasses ~/.Xauthority lockfile contention from
  # parallel xauth invocations (e.g. another tmux session, ssh-agent,
  # or DE startup hook holding flock). Without -i, `xauth nlist`
  # silently returns empty output (the lock error goes to stderr,
  # exit 0) on a contended file, the sed pipeline gets nothing, and
  # nmerge writes a 0-byte cookie file — defeating the rewrite. Read
  # is a non-mutating op so ignoring the lock is safe.
  # Family-byte rewrite: 'ffff' means "any host" so libX11 inside the
  # container does not fail the hostname check.
  xauth -i nlist "${DISPLAY}" 2>/dev/null \
    | sed -e 's/^..../ffff/' \
    | xauth -i -f "${_out}" nmerge - >/dev/null 2>&1 || {
        _log_warn setup xauth_rewrite_failed "display=xauth cookie rewrite failed; XAUTHORITY left at host value."
        return 1
      }
  # Defensive: verify the rewrite actually produced content. The pipe
  # above can succeed (all three commands exit 0) yet write 0 bytes if
  # nlist hit a soft failure (e.g. wrong DISPLAY key under SSH X11
  # forwarding). Treat empty output as failure so the caller falls back
  # to leaving XAUTHORITY untouched rather than emitting an empty
  # cookie path into .env (which then makes the container mount a
  # 0-byte cookie and fail X11 auth silently).
  if [[ ! -s "${_out}" ]]; then
    _log_warn setup xauth_empty_cookie "display=xauth cookie rewrite produced an empty cookie file; XAUTHORITY left at host value."
    return 1
  fi
  printf '%s\n' "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# detect_image_name
#
# Reads [image] rules from setup.conf (per-repo or template default).
# rules is a comma-separated ordered list; first match wins.
#
# Usage: detect_image_name <outvar> <path>
# ════════════════════════════════════════════════════════════════════
detect_image_name() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _path="${1:?"${FUNCNAME[0]}: missing path"}"

  local _base="${BASE_PATH:-${_path}}"

  # Collect [image] rule_N entries in numeric order via the opaque conf
  # handle (the effective template+repo merge).
  _setup_conf_handle "${_base}" _DIN_CONF
  local -a _rule_arr=()
  _conf_list_sorted _DIN_CONF image "rule_" _rule_arr

  local _found=""
  if (( ${#_rule_arr[@]} > 0 )); then
    local _rule _value
    for _rule in "${_rule_arr[@]}"; do
      _rule="${_rule#"${_rule%%[![:space:]]*}"}"
      _rule="${_rule%"${_rule##*[![:space:]]}"}"
      [[ -z "${_rule}" ]] && continue

      if [[ "${_rule}" == prefix:* ]]; then
        _value="${_rule#prefix:}"
        _found="$(_rule_prefix "${_path}" "${_value}")"
      elif [[ "${_rule}" == suffix:* ]]; then
        _value="${_rule#suffix:}"
        _found="$(_rule_suffix "${_path}" "${_value}")"
      elif [[ "${_rule}" == string:* ]]; then
        # Short-circuit: user provided the exact image name as a string,
        # bypass any path-derived inference.
        _found="${_rule#string:}"
      elif [[ "${_rule}" == "@basename" ]]; then
        _found="$(_rule_basename "${_path}")"
      elif [[ "${_rule}" == @default:* ]]; then
        _found="${_rule#@default:}"
        _log_info setup conf_image_name_default "display=IMAGE_NAME using @default:${_found}" "default=${_found}"
      fi

      [[ -n "${_found}" ]] && break
    done
  fi

  if [[ -z "${_found}" ]]; then
    _log_warn setup conf_image_name_unknown "display=IMAGE_NAME could not be detected. Using 'unknown'."
    _found="unknown"
  fi
  # Lowercase + sanitize: docker compose project names (and image tags)
  # forbid `.`, uppercase, and anything outside [a-z0-9_-]. `@basename`
  # on a dir like "tmp.abcdef" would otherwise produce
  # "yunchien-tmp.abcdef" which docker compose rejects. Map invalids to
  # `-`, collapse runs, and strip any leading non-alphanumeric.
  local _lower="${_found,,}"
  local _sanitized="${_lower//[^a-z0-9_-]/-}"
  # collapse multiple '-' in a row
  while [[ "${_sanitized}" == *--* ]]; do
    _sanitized="${_sanitized//--/-}"
  done
  # strip leading '-' / '_'
  _sanitized="${_sanitized#[-_]}"
  # strip trailing '-' / '_'
  _sanitized="${_sanitized%[-_]}"
  [[ -z "${_sanitized}" ]] && _sanitized="unknown"
  _outvar="${_sanitized}"
}

# ════════════════════════════════════════════════════════════════════
# detect_ws_path
#
# Workspace detection strategy (in order):
#   1. If current directory is docker_*, use sibling *_ws (strip prefix)
#   2. Traverse path upward looking for a *_ws component
#   3. Fall back to base_path itself (base-based repos keep the docker
#      scaffolding at the repo root, so the repo root *is* the ws root;
#      a self-CI checkout at _work/<repo>/<repo> mounts itself,)
#
# Usage: detect_ws_path <outvar> <base_path>
# ════════════════════════════════════════════════════════════════════
detect_ws_path() {
  local -n _outvar="${1:?"${FUNCNAME[0]}: missing outvar"}"; shift
  local _base_path="${1:?"${FUNCNAME[0]}: missing base_path"}"

  if [[ ! -d "${_base_path}" ]]; then
    printf "[setup] ERROR: detect_ws_path: base_path does not exist: %s\n" \
      "${_base_path}" >&2
    return 1
  fi
  _base_path="$(cd "${_base_path}" && pwd -P)"

  local _dirname=""
  _dirname="$(basename "${_base_path}")"

  if [[ "${_dirname}" == docker_* ]]; then
    local _name="${_dirname#docker_}"
    local _parent=""
    _parent="$(dirname "${_base_path}")"
    local _sibling="${_parent}/${_name}_ws"
    if [[ -d "${_sibling}" ]]; then
      _outvar="$(cd "${_sibling}" && pwd -P)"
      return 0
    fi
  fi

  local _check="${_base_path}"
  while [[ "${_check}" != "/" && "${_check}" != "." ]]; do
    if [[ "$(basename "${_check}")" == *_ws && -d "${_check}" ]]; then
      _outvar="$(cd "${_check}" && pwd -P)"
      return 0
    fi
    _check="$(dirname "${_check}")"
  done

  _outvar="${_base_path}"
}

# ════════════════════════════════════════════════════════════════════
# _reconcile_workspace_path <base_path> <repo_conf> <vol_keys> <vol_values> <ws_path>
#
# Reconcile the workspace bind (`[volumes] mount_1`) + WS_PATH for one
# apply. Deep module: the state machine that was inlined in
# _setup_apply. mount_1 can be:
#   - absent repo conf  -> first-time bootstrap: copy the template, write
#     mount_1 in the portable `${WS_PATH}:...` form, reload [volumes]
#   - portable form     -> detect WS_PATH locally; mount_1 untouched
#   - absolute, exists  -> honor the pinned host path as WS_PATH
#   - absolute, stale   -> warn, rewrite mount_1 to portable, re-detect
#   - empty mount_1     -> best-effort WS_PATH detection only; conf untouched
#
# Mutates <vol_keys>/<vol_values> in place (reloaded after any mount_1
# rewrite so the caller's extra_volumes pickup sees the new value) and
# writes the resolved absolute path into <ws_path> (seeded by the caller
# from ${WS_PATH:-}). setup.conf is written only on bootstrap / stale
# rewrite. The detection-dependent steps reuse detect_ws_path, same as
# apply, so behaviour is identical to the prior inline block.
# ════════════════════════════════════════════════════════════════════
_reconcile_workspace_path() {
  local _rwp_base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _rwp_repo_conf="${2:?"${FUNCNAME[0]}: missing repo_conf"}"
  local -n _rwp_vk="${3:?"${FUNCNAME[0]}: missing vol_keys"}"
  local -n _rwp_vv="${4:?"${FUNCNAME[0]}: missing vol_values"}"
  local -n _rwp_ws="${5:?"${FUNCNAME[0]}: missing ws_path out"}"

  local _mount_1=""
  _get_conf_value _rwp_vk _rwp_vv "mount_1" "" _mount_1

  # SC2016: literal ${WS_PATH} / ${USER_NAME} are intentional — this
  # string is written into setup.conf and expanded by docker-compose
  # (via .env) at container start time, not by shell here.
  # shellcheck disable=SC2016
  local _ws_portable_form='${WS_PATH}:/home/${USER_NAME}/work'

  if [[ ! -f "${_rwp_repo_conf}" ]]; then
    # First-time bootstrap: create per-repo setup.conf from template.
    # Write mount_1 as the portable ${WS_PATH} form so the committed
    # file stays machine-agnostic; .env carries the detected absolute
    # path for docker-compose to expand.
    if [[ -z "${_rwp_ws}" ]] || [[ ! -d "${_rwp_ws}" ]]; then
      detect_ws_path _rwp_ws "${_rwp_base}"
    fi
    [[ -d "${_rwp_ws}" ]] && _rwp_ws="$(cd "${_rwp_ws}" && pwd -P)"
    local _tpl_conf
    _tpl_conf="${_SETUP_SCRIPT_DIR}/../../../.setup.conf"
    if [[ -f "${_tpl_conf}" ]]; then
      cp "${_tpl_conf}" "${_rwp_repo_conf}"
      _upsert_conf_value "${_rwp_repo_conf}" "volumes" "mount_1" \
        "${_ws_portable_form}"
      # Reload [volumes] so extra_volumes picks up the new mount_1. This is a
      # single-section reload of the parallel arrays this function mutates in
      # place (the caller's out-param), NOT the multi-section re-parse the
      # parse-once handle replaces: the handle tokenizes both template+repo
      # and would go stale the moment _upsert_conf_value rewrote the conf, so
      # a fresh single-section read is both cheaper and correct here.
      _rwp_vk=(); _rwp_vv=()
      _load_setup_conf "${_rwp_base}" "volumes" _rwp_vk _rwp_vv
      _get_conf_value _rwp_vk _rwp_vv "mount_1" "" _mount_1
    fi
  elif [[ -n "${_mount_1}" ]]; then
    local _mount_1_host=""
    _mount_host_path "${_mount_1}" _mount_1_host
    # SC2016: literal ${WS_PATH} / $WS_PATH substrings are intentional
    # — we are matching the variable reference stored in setup.conf,
    # not expanding it.
    # shellcheck disable=SC2016
    if [[ "${_mount_1_host}" == *'${WS_PATH}'* ]] \
        || [[ "${_mount_1_host}" == *'$WS_PATH'* ]]; then
      # Portable form — detect ws_path locally; mount_1 stays untouched.
      _rwp_ws=""
      detect_ws_path _rwp_ws "${_rwp_base}"
      [[ -d "${_rwp_ws}" ]] && _rwp_ws="$(cd "${_rwp_ws}" && pwd -P)"
    elif [[ -d "${_mount_1_host}" ]]; then
      # User pinned an absolute path that exists locally — honor it.
      _rwp_ws="${_mount_1_host}"
    else
      # Absolute path that doesn't exist on this machine — almost always
      # a stale bake from another contributor's clone. Warn loudly so
      # the user understands the rewrite, then migrate mount_1 back to
      # the portable form.
      _log_warn setup conf_mount_stale_path "display=[volumes] mount_1 host path '${_mount_1_host}' does not exist on this machine. This is usually a stale absolute path committed from a different machine. Rewriting mount_1 to the portable '\${WS_PATH}:/home/\${USER_NAME}/work' form and re-detecting WS_PATH locally. Commit the updated setup.conf to share." "path=${_mount_1_host}"
      _rwp_ws=""
      detect_ws_path _rwp_ws "${_rwp_base}"
      [[ -d "${_rwp_ws}" ]] && _rwp_ws="$(cd "${_rwp_ws}" && pwd -P)"
      _upsert_conf_value "${_rwp_repo_conf}" "volumes" "mount_1" \
        "${_ws_portable_form}"
      # Single-section reload after the stale-path rewrite (see the bootstrap
      # branch above for why this stays a per-section load, not the handle).
      _rwp_vk=(); _rwp_vv=()
      _load_setup_conf "${_rwp_base}" "volumes" _rwp_vk _rwp_vv
      _get_conf_value _rwp_vk _rwp_vv "mount_1" "" _mount_1
    fi
  else
    # setup.conf exists but user cleared mount_1: best-effort detection
    # for WS_PATH only; do not touch setup.conf.
    if [[ -z "${_rwp_ws}" ]] || [[ ! -d "${_rwp_ws}" ]]; then
      detect_ws_path _rwp_ws "${_rwp_base}"
    fi
    [[ -d "${_rwp_ws}" ]] && _rwp_ws="$(cd "${_rwp_ws}" && pwd -P)"
  fi
}
