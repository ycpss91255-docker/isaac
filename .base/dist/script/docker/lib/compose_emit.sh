#!/usr/bin/env bash
#
# compose_emit.sh - compose.yaml emission (the renderer).
#
# Generates the project compose.yaml from the resolved setup.conf: the
# per-field `_emit_*_block` / `_emit_*_line` helpers, the volume/device
# classifiers (_classify_volume_lhs, _collect_named_volumes, _yaml_dq, ...),
# the per-stage service block (_emit_stage_service), and the top-level
# generate_compose_yaml orchestrator.
#
# Distinct from lib/compose.sh, which is the `docker compose` INVOCATION
# wrapper + project naming (_compose / _compose_project / _compute_project_name).
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# setup.sh-resident deps (resolvers, _setup_msg, _SETUP_SCRIPT_DIR), deploy.sh
# (_resolve_deploy_context), and conf.sh accessors; all resolve at call-time
# via the _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_COMPOSE_EMIT_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_COMPOSE_EMIT_SOURCED=1

# _yaml_dq <value> <outvar>
#
# Wraps <value> as a YAML double-quoted scalar in <outvar>, escaping the
# two characters that a YAML double-quoted scalar treats specially: the
# backslash (\) and the double-quote ("). This keeps a validator-accepted
# environment value that carries YAML-structural characters -- a colon-
# space ("a: b" -> mapping), a leading flow indicator (* & [ { !), or an
# inline " #" comment -- from being mis-parsed when emitted as a
# compose.yaml `environment:` list item. The compose env sink was the
# asymmetric, unprotected one: the Dockerfile baked-ENV sink and deploy.sh
# already harden the same accepted-value class.
_yaml_dq() {
  local _in="$1"
  local -n _yaml_dq_out="$2"
  # Order matters: escape backslashes first, then double-quotes.
  _in="${_in//\\/\\\\}"
  _in="${_in//\"/\\\"}"
  _yaml_dq_out="\"${_in}\""
}

# _write_runtime_env was retired in S7: runtime.env is
# superseded by the S3 baked ENV (in-container) + .env.generated/.env
# (host-side helpers source these instead).

# ── ports-inert diagnostic ────────────────────────────────────────────
#
# Compose honours a `ports:` block only under network_mode=bridge, and the
# template ships `[network] mode = host` (ADR-00000019) -- so under the stock
# configuration a port mapping the user configured, the TUI editor accepted and
# `_validate_port_mapping` vetted is dropped. The host default is deliberate,
# so the fix is a diagnostic rather than a default change: say it where the
# user can act on it.
#
# One helper, three call sites (the devel block, the per-stage block, and
# deploy.sh's field emitter) plus setup_cmd.sh's `set` / `add`, so store-time
# and emit-time can never disagree about when a port is inert.
_PORTS_INERT_WARNED=0

# _warn_ports_inert <ports_str> <net_mode>
#
# Warn once per emit that <ports_str> will not be published under <net_mode>.
# No-op when no port is configured or when the mode does publish them. The
# once-per-emit latch keeps a repo with N stages from printing N copies of the
# same sentence; generate_compose_yaml / _generate_resolved_compose reset it at
# entry so a second emit in the same process still reports.
_warn_ports_inert() {
  local _ports="${1-}" _mode="${2-}"
  [[ -z "${_ports}" ]] && return 0
  [[ "${_mode}" == "bridge" ]] && return 0
  (( _PORTS_INERT_WARNED )) && return 0
  _PORTS_INERT_WARNED=1
  _log_warn setup network_ports_inert \
    "display=$(_setup_msg network ports_inert) (mode=${_mode})" "mode=${_mode}"
}

# _reset_ports_inert_warning
#
# Re-arm the latch. Called at the top of each top-level emitter.
_reset_ports_inert_warning() {
  _PORTS_INERT_WARNED=0
}

_device_has_propagation() {
  local _entry="${1}"
  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_entry}"
  (( ${#_parts[@]} == 3 )) || return 1
  [[ "${_parts[2]}" =~ (rslave|rshared|rprivate|slave|shared|private) ]]
}

_emit_device_as_volume() {
  local _entry="${1}" _indent="${2:-    }"
  local -a _parts=()
  IFS=':' read -ra _parts <<< "${_entry}"
  local _src="${_parts[0]}" _tgt="${_parts[1]}" _opts="${_parts[2]}"
  local _propagation="" _read_only=""
  local _o
  IFS=',' read -ra _oarr <<< "${_opts}"
  for _o in "${_oarr[@]}"; do
    case "${_o}" in
      ro) _read_only="true" ;;
      rw) _read_only="false" ;;
      rslave|rshared|rprivate|slave|shared|private) _propagation="${_o}" ;;
    esac
  done
  echo "${_indent}  - type: bind"
  echo "${_indent}    source: ${_src}"
  echo "${_indent}    target: ${_tgt}"
  [[ -n "${_read_only}" ]] && echo "${_indent}    read_only: ${_read_only}"
  echo "${_indent}    bind:"
  echo "${_indent}      propagation: ${_propagation}"
}

# _classify_volume_lhs <mount_string>
#
# Classify a `host:container[:mode]` mount by its left-hand side
# Option A / D-Strict). A LHS that looks like a path -- starts with `/`,
# `./`, `~/`, or a `${...}` variable reference -- is a bind mount; anything
# else is a Docker named-volume reference. Echoes `bind` or `named`.
_classify_volume_lhs() {
  # The `~/` and `${` globs are single-quoted so they stay literal: an
  # unquoted `~/*` case pattern undergoes tilde expansion (to $HOME/*) and
  # would never match a literal `~/...` LHS; an unquoted `${`-glob is fine
  # but quoting keeps both path-prefix markers consistent and silences
  # SC2016 (the literal `${` is intentional -- a `${VAR}` LHS is a bind path).
  # shellcheck disable=SC2016,SC2088
  case "${1%%:*}" in
    /*|./*|'~/'*|'${'*) printf 'bind\n' ;;
    *)                 printf 'named\n' ;;
  esac
}

# _collect_named_volumes <assoc_array_name> <newline_separated_mounts>
#
# Add the named-volume names from <mounts> into the associative array used
# as a set (key = volume name, the LHS before the first `:`, which already
# excludes any `:mode` suffix). Bind mounts are skipped.
_collect_named_volumes() {
  local -n _cnv_set="$1"
  local _line
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    [[ "$(_classify_volume_lhs "${_line}")" == named ]] || continue
    _cnv_set["${_line%%:*}"]=1
  done <<< "$2"
}

# _emit_volumes_block <assoc_array_name>
#
# Emit a top-level `volumes:` declaration with one bare stub per collected
# named volume (no driver / labels / options -> Docker's default `local`
# driver). Emits nothing when the set is empty (zero-diff for bind-only
# repos). Names are sorted for deterministic output.
_emit_volumes_block() {
  local -n _evb_set="$1"
  (( ${#_evb_set[@]} == 0 )) && return 0
  printf '\nvolumes:\n'
  local _k
  while IFS= read -r _k; do
    printf '  %s:\n' "${_k}"
  done < <(printf '%s\n' "${!_evb_set[@]}" | sort)
}

# ════════════════════════════════════════════════════════════════════
# Shared compose leaf emitters
#
# Hoisted out of generate_compose_yaml so the per-service emitter
# (_emit_stage_service) and the devel baseline block can share them as
# independently-testable sub-seams. Each takes its context explicitly
# instead of closing over generate_compose_yaml's 30 positional args.
# ════════════════════════════════════════════════════════════════════

# additional_contexts emitter: forwards `[additional_contexts]
# context_N = NAME=PATH` entries to compose.yaml's
# `build.additional_contexts:` block under every service that has its
# own `build:` (devel / runtime / test). Empty = omit the block so
# repos that don't need named build contexts see no diff.
_emit_additional_contexts_block() {
  local _additional_contexts_str="${1-}"
  [[ -z "${_additional_contexts_str}" ]] && return 0
  echo "      additional_contexts:"
  local _ac _name _path
  while IFS= read -r _ac; do
    [[ -z "${_ac}" ]] && continue
    _name="${_ac%%=*}"
    _path="${_ac#*=}"
    printf '        %s: %s\n' "${_name}" "${_path}"
  done <<< "${_additional_contexts_str}"
}

# TARGETARCH line emitter: only when target_arch is set. Empty =
# omit the line entirely so BuildKit auto-fills TARGETARCH from the
# host. Shared between devel + test service blocks below.
_emit_target_arch_line() {
  local _target_arch="${1-}"
  [[ -z "${_target_arch}" ]] && return 0
  # shellcheck disable=SC2016  # literal ${} consumed by compose, not bash
  printf '        TARGETARCH: ${TARGET_ARCH}\n'
}

# build.network emitter: only when build_network is set. Empty =
# omit the line so Docker uses its default (bridge). Non-empty =
# force the build to use that network (typically "host" for
# environments where bridge NAT doesn't work).
_emit_build_network_line() {
  local _build_network="${1-}"
  [[ -z "${_build_network}" ]] && return 0
  printf '      network: %s\n' "${_build_network}"
}

# runtime emitter: Jetson / csv-mode nvidia-container-toolkit hosts
# need `runtime: nvidia` at service level to bypass the modern
# --gpus flow (which `deploy.resources.reservations.devices`
# translates to). Empty = omit so Docker uses the default runc.
# Only emitted for the devel service; devel-test doesn't run.
_emit_runtime_line() {
  local _runtime="${1-}"
  [[ -z "${_runtime}" ]] && return 0
  printf '    runtime: %s\n' "${_runtime}"
}

# restart emitter: [lifecycle] restart policy, DEPLOY-scoped.
#
# Emitted only for a deployable stage service (_is_deployable_stage:
# not devel, not `*-test`) and for the field bundle's resolved compose.
# devel deliberately never carries it -- a devel container is the
# interactive shell, so `always` / `unless-stopped` on it relaunches the
# container the moment the developer types `exit`, forever. That is also
# why devel must not carry it for `extends: devel` stages to inherit:
# the qualifying stage services emit it themselves.
#
# `no` emits nothing -- that IS Docker's no-restart default, so the
# operator's choice is honoured by omission. `on-failure:N` is quoted
# because the `:` would otherwise read as a YAML mapping.
_emit_restart_line() {
  local _restart="${1-}"
  [[ "${_restart}" == "no" ]] && return 0
  # apply does no schema revalidation, so a hand-edited setup.conf can feed
  # a malformed policy here. Drop anything _validate_restart rejects rather
  # than emit an invalid `restart:` that breaks `docker compose up` with a
  # cryptic error (apply-time trust-boundary guard).
  _validate_restart "${_restart}" || return 0
  case "${_restart}" in
    on-failure:*) printf '    restart: "%s"\n' "${_restart}" ;;
    *)            printf '    restart: %s\n'   "${_restart}" ;;
  esac
}

# init emitter: [lifecycle] init toggle. Docker's `init: true` runs the
# daemon init (docker-init = tini) as PID 1 -- a zombie reaper + signal
# forwarder. Default ON (emits `init: true`); an explicit `false` omits
# the field. Stages that `extends: devel` inherit it; the per-stage
# standalone block re-emits it (no extends to inherit from).
_emit_init_line() {
  local _init="${1-true}"
  # apply does no schema revalidation, so a hand-edited setup.conf can feed
  # a non-boolean here. Drop anything _validate_init rejects rather than
  # emit a malformed init: field (apply-time trust-boundary guard, mirrors
  # _emit_restart_line).
  _validate_init "${_init}" || return 0
  [[ "${_init}" == "false" ]] && return 0
  printf '    init: true\n'
}

# watchdog env emitter: [lifecycle] watchdog. Emits each resolved
# `WATCHDOG_*=value` line (built in deploy.sh, gated on a non-empty
# watchdog_check) as a YAML double-quoted environment list item, so a
# command value carrying YAML-structural characters survives the parse.
# No-op when the block is empty (watchdog disabled -> zero compose diff,
# the default-off golden is unaffected). The env is uniform across
# services (a lifecycle
# property, not per-service like LOG_FILE_PATH), so devel emits it and
# extends:devel stages inherit it; standalone override stages re-emit it.
_emit_watchdog_env() {
  local _watchdog_env_str="${1-}"
  [[ -z "${_watchdog_env_str}" ]] && return 0
  local _we _we_dq
  while IFS= read -r _we; do
    [[ -z "${_we}" ]] && continue
    _yaml_dq "${_we}" _we_dq
    echo "      - ${_we_dq}"
  done <<< "${_watchdog_env_str}"
}

# env_file emitter: inject the hand-authored .env workload
# overlay into the service so per-task env vars take effect with
# `just run` alone (no regenerate, no SETUP_CONF_HASH drift). Path is
# relative to compose.yaml (repo root). The devel block emits it and
# `extends: devel` stages inherit it; the per-stage standalone block
# (override mode, no extends) re-emits it. Plain (not required:false):
# setup.sh scaffolds .env on apply, so it always exists before compose
# runs. .env.generated (the resolved cache) is NOT listed here -- it
# feeds compose interpolation via the CLI --env-file flag, not the
# container environment (two-role split).
_emit_env_file_block() {
  cat <<'YAML'
    env_file:
      - .env
YAML
}

# User-added [build] args: emit each as `KEY: ${KEY}` — Dockerfile's
# `ARG KEY="default"` fallback handles empty values. No hard-coded
# defaults here since template doesn't know them.
_emit_user_build_args() {
  local _user_build_args_str="${1-}"
  [[ -z "${_user_build_args_str}" ]] && return 0
  local _ub _k
  while IFS= read -r _ub; do
    [[ -z "${_ub}" ]] && continue
    _k="${_ub%%=*}"
    # Emit literal compose substitution `${KEY}` into compose.yaml;
    # the ${} is consumed by docker compose at runtime, not bash.
    # shellcheck disable=SC2016
    printf '        %s: ${%s}\n' "${_k}" "${_k}"
  done <<< "${_user_build_args_str}"
}

# cap_add / cap_drop / security_opt. The devel block passes the
# top-level [security] strings; the per-stage standalone block
# passes its effective resolved lists so a stage can override / clear
# inherited caps via [stage:*] security.*.
_emit_caps_block() {
  local _cap_add="${1-}"
  local _cap_drop="${2-}"
  local _sec_opt="${3-}"
  local _c
  if [[ -n "${_cap_add}" ]]; then
    echo "    cap_add:"
    while IFS= read -r _c; do
      [[ -z "${_c}" ]] && continue
      echo "      - ${_c}"
    done <<< "${_cap_add}"
  fi
  if [[ -n "${_cap_drop}" ]]; then
    echo "    cap_drop:"
    while IFS= read -r _c; do
      [[ -z "${_c}" ]] && continue
      echo "      - ${_c}"
    done <<< "${_cap_drop}"
  fi
  if [[ -n "${_sec_opt}" ]]; then
    echo "    security_opt:"
    while IFS= read -r _c; do
      [[ -z "${_c}" ]] && continue
      echo "      - ${_c}"
    done <<< "${_sec_opt}"
  fi
}

# group_add for /dev/dri: GUI-gated; caller passes the effective
# gui flag (devel's _gui or a stage's _eff_gui) and the resolved
# dri_groups string. Numeric GIDs quoted.
_emit_group_add_block() {
  local _g="$1"
  local _dri_groups_str="${2-}"
  [[ "${_g}" == "true" && -n "${_dri_groups_str}" ]] || return 0
  echo "    group_add:"
  local _gid
  for _gid in ${_dri_groups_str}; do
    echo "      - \"${_gid}\""
  done
}

# hostname: GUI+bridge-gated (ADR-00000019). Under bridge networking the container
# gets a Docker-assigned random hostname, which breaks the LOCAL X11
# MIT-MAGIC-COOKIE -- that cookie is keyed to the host's hostname, so the
# container's random name fails the auth match. Pinning the container's
# hostname to the host's name restores the match. It is only meaningful when
# BOTH the GUI is enabled AND network.mode = bridge: under host networking
# the container already shares the host's UTS namespace (its hostname IS the
# host's), and with the GUI off there is no X cookie to satisfy. Caller
# passes the effective gui flag + net mode + the resolved host name.
_emit_hostname_line() {
  local _g="$1" _nm="$2" _host="${3-}"
  [[ "${_g}" == "true" && "${_nm}" == "bridge" && -n "${_host}" ]] || return 0
  echo "    hostname: ${_host}"
}

# device_cgroup_rules from [devices] cgroup_rule_* (enclosing scope).
_emit_cgroup_rules_block() {
  local _cgroup_rule_str="${1-}"
  [[ -n "${_cgroup_rule_str}" ]] || return 0
  echo "    device_cgroup_rules:"
  local _cr
  while IFS= read -r _cr; do
    [[ -z "${_cr}" ]] && continue
    echo "      - \"${_cr}\""
  done <<< "${_cgroup_rule_str}"
}

# tmpfs from [tmpfs] (enclosing scope).
_emit_tmpfs_block() {
  local _tmpfs_str="${1-}"
  [[ -n "${_tmpfs_str}" ]] || return 0
  echo "    tmpfs:"
  local _tf
  while IFS= read -r _tf; do
    [[ -z "${_tf}" ]] && continue
    echo "      - ${_tf}"
  done <<< "${_tmpfs_str}"
}

# deploy GPU reservation: caller passes the effective gpu flag, count,
# and pre-built capabilities YAML array (devel's globals or a stage's
# resolved values).
_emit_gpu_deploy_block() {
  local _g="$1" _count="$2" _caps="$3"
  [[ "${_g}" == "true" ]] || return 0
  cat <<YAML
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: ${_count}
              capabilities: ${_caps}
YAML
}

# _logging_svc_kv <svc> <out_assoc_name> <global_str> <per_svc_str>
#
# Resolve effective logging KV map for compose service <svc>:
#   1. seed with global [logging] entries (`<global_str>`)
#   2. overlay per-service [logging.<svc>] entries — key-level merge
#
# If both inputs are empty the map stays empty and the emitter
# downstream skips the `logging:` block entirely (back-compat with
# downstream repos that haven't adopted [logging] yet).
_logging_svc_kv() {
  local _svc="$1"
  local -n _lkv="$2"
  local _logging_global_str="${3-}"
  local _logging_per_svc_str="${4-}"
  _lkv=()
  local _line _k _v
  if [[ -n "${_logging_global_str}" ]]; then
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      _k="${_line%%=*}"
      _v="${_line#*=}"
      _lkv["${_k}"]="${_v}"
    done <<< "${_logging_global_str}"
  fi
  if [[ -n "${_logging_per_svc_str}" ]]; then
    while IFS= read -r _line; do
      [[ -z "${_line}" ]] && continue
      [[ "${_line%%:*}" == "${_svc}" ]] || continue
      _line="${_line#*:}"
      _k="${_line%%=*}"
      _v="${_line#*=}"
      _lkv["${_k}"]="${_v}"
    done <<< "${_logging_per_svc_str}"
  fi
}

# _emit_logging_block <svc> <global_str> <per_svc_str>
#
# Emit compose `logging:` mapping for service <svc>. Maps four
# setup.conf keys (driver / max_size / max_file / compress) to the
# corresponding Docker compose option names (driver as scalar;
# max-size / max-file / compress as `options:` sub-keys, dash-named
# per Docker docs). The 5th key, `local_path`, is **not** a Docker
# logging option -- it triggers a per-service volume bind via
# `_logging_svc_local_path_mount` (emitted from each service's
# `volumes:` block), so this function deliberately ignores it.
# No-op when no docker-option key is set on this service.
_emit_logging_block() {
  local _svc="$1"
  local _logging_global_str="${2-}"
  local _logging_per_svc_str="${3-}"
  local -A _kv=()
  _logging_svc_kv "${_svc}" _kv "${_logging_global_str}" "${_logging_per_svc_str}"
  local _have_opts=0 _k
  for _k in driver max_size max_file compress; do
    [[ -n "${_kv[${_k}]:-}" ]] && _have_opts=1 && break
  done
  (( _have_opts == 0 )) && return 0
  echo "    logging:"
  [[ -n "${_kv[driver]:-}" ]] && echo "      driver: ${_kv[driver]}"
  local _opts=0
  for _k in max_size max_file compress; do
    [[ -n "${_kv[${_k}]:-}" ]] && _opts=1 && break
  done
  if (( _opts )); then
    echo "      options:"
    [[ -n "${_kv[max_size]:-}" ]] && echo "        max-size: \"${_kv[max_size]}\""
    [[ -n "${_kv[max_file]:-}" ]] && echo "        max-file: \"${_kv[max_file]}\""
    [[ -n "${_kv[compress]:-}" ]] && echo "        compress: \"${_kv[compress]}\""
  fi
  return 0
}

# _logging_svc_local_path_mount <svc> <out_var> <name> <base> <global> <per_svc>
#
# Resolves the effective `local_path` for service <svc> against the
# repo base directory <base> and emits a compose volume mount string
# `<host>:/var/log/<name>` (no leading indentation; caller decides
# placement). Empty out when local_path is unset or empty.
#
# Path semantics (from):
#   ./logs/     relative to repo root (<base>)
#   /abs/path/  used verbatim
#   ~/dir/      ~ expanded against $HOME
#   (empty)     feature disabled, no mount
#
# The function also creates the host directory eagerly with
# `mkdir -p` so the bind mount works on first `./run.sh` without
# Docker silently creating a root-owned dir.
_logging_svc_local_path_mount() {
  local _svc="$1"
  local -n _llp_out="$2"
  local _name="${3-}"
  local _setup_base="${4-}"
  local _logging_global_str="${5-}"
  local _logging_per_svc_str="${6-}"
  _llp_out=""
  local -A _kv=()
  _logging_svc_kv "${_svc}" _kv "${_logging_global_str}" "${_logging_per_svc_str}"
  local _raw="${_kv[local_path]:-}"
  [[ -z "${_raw}" ]] && return 0
  # ~ expansion at front only (not embedded — same restriction as
  # POSIX sh). The pattern uses single-char literal match (\~) and
  # case so shellcheck SC2088 doesn't flag it; we're matching the
  # user's *literal* `~/foo` setup.conf value and rewriting it to
  # ${HOME}/foo.
  case "${_raw}" in
    \~/*)
      _raw="${HOME}/${_raw#\~/}" ;;
    \~)
      _raw="${HOME}" ;;
  esac
  # Strip trailing slashes for predictable mount string.
  while [[ "${_raw}" == */ && "${_raw}" != "/" ]]; do
    _raw="${_raw%/}"
  done
  # Relative -> resolve against repo root (the compose.yaml's directory).
  if [[ "${_raw}" != /* ]]; then
    _raw="${_setup_base%/}/${_raw}"
  fi
  # Create the dir eagerly so `docker run` doesn't auto-create it
  # root-owned. Failure is non-fatal -- if the user's running setup
  # without write perms to that dir, the eventual docker run will
  # raise a clear error.
  mkdir -p "${_raw}" 2>/dev/null || true
  _llp_out="${_raw}:/var/log/${_name}"
}

# _logging_svc_retention <svc> <keep_out> <days_out> <global> <per_svc>
#
# Resolve the container-log retention knobs for service <svc> from the
# effective [logging] / [logging.<svc>] keys (container_log_keep /
# container_log_days), falling back to 20 / 14 and clamping a
# non-positive hand-edit back to the default (mirrors transcript.sh +
# runtime/logging.sh). Emitted as CONTAINER_LOG_KEEP / CONTAINER_LOG_DAYS
# env alongside LOG_FILE_PATH so the in-image tee's shared logrotate
# prune honors setup.conf across the container boundary.
_logging_svc_retention() {
  local _svc="$1"
  local -n _keep_out="$2"
  local -n _days_out="$3"
  local _logging_global_str="${4-}"
  local _logging_per_svc_str="${5-}"
  local -A _kv=()
  _logging_svc_kv "${_svc}" _kv "${_logging_global_str}" "${_logging_per_svc_str}"
  _keep_out="${_kv[container_log_keep]:-20}"
  _days_out="${_kv[container_log_days]:-14}"
  [[ "${_keep_out}" =~ ^[1-9][0-9]*$ ]] || _keep_out=20
  [[ "${_days_out}" =~ ^[1-9][0-9]*$ ]] || _days_out=14
}

# _emit_stage_service <ctx_assoc> <resolved_assoc> <svc> <emit_stage> <has_overrides>
#
# Per-service compose emitter. Consumes one resolved-stage value
# (the _dflags_eff record produced by _resolve_docker_flags) plus the
# shared static context, and emits a single service YAML fragment:
#
#   has_overrides=0 -> the minimal `extends: devel` shape,
#                      byte-for-byte identical to for the 17
#                      downstream repos that carry no [stage:*] sections;
#   has_overrides=1 -> a standalone block (no extends) whose every list
#                      field carries exactly the stage's resolved set
#                      (v0.18.1: compose `extends` MERGES lists, so
#                      a stage that clears an inherited entry cannot use
#                      extends).
#
# generate_compose_yaml owns resolution (override load/filter +
# _resolve_docker_flags) and the top-level assembly; this function owns
# only the per-service emission. The leaf emitters (_emit_caps_block,
# _emit_gpu_deploy_block, _emit_logging_block, ...) are its sub-seams.
_emit_stage_service() {
  local -n _ess_ctx="$1"
  local -n _ess_res="$2"
  local _svc="$3"
  local _emit_stage="$4"
  local _has_overrides="$5"

  # Rehydrate the shared static context under the names the emit bodies
  # use (kept identical to generate_compose_yaml's scope so the emitted
  # bytes never drift).
  local _name="${_ess_ctx[name]-}"
  local _setup_base="${_ess_ctx[setup_base]-}"
  local _additional_contexts_str="${_ess_ctx[additional_contexts]-}"
  local _build_network="${_ess_ctx[build_network]-}"
  local _target_arch="${_ess_ctx[target_arch]-}"
  local _user_build_args_str="${_ess_ctx[user_build_args]-}"
  local _devices_str="${_ess_ctx[devices]-}"
  local _cgroup_rule_str="${_ess_ctx[cgroup_rule]-}"
  local _tmpfs_str="${_ess_ctx[tmpfs]-}"
  local _shm_size="${_ess_ctx[shm_size]-}"
  local _dri_groups_str="${_ess_ctx[dri_groups]-}"
  local _init="${_ess_ctx[init]-true}"
  local _restart="${_ess_ctx[restart]-}"
  local _watchdog_env_str="${_ess_ctx[watchdog_env]-}"

  # [lifecycle] restart is DEPLOY-scoped: emitted here, on the qualifying
  # stage services, and never on devel for `extends: devel` to inherit
  # (see _emit_restart_line / _is_deployable_stage). A non-deployable
  # stage resolves to the empty policy, which every emit path drops.
  _is_deployable_stage "${_emit_stage}" || _restart=""
  local _logging_global_str="${_ess_ctx[logging_global]-}"
  local _logging_per_svc_str="${_ess_ctx[logging_per_svc]-}"
  local _net_mode="${_ess_ctx[net_mode]-host}"
  local _ipc_mode="${_ess_ctx[ipc_mode]-host}"
  local _pid_mode="${_ess_ctx[pid_mode]-private}"
  local _host_name="${_ess_ctx[host_name]-}"
  local _any_prop_device="${_ess_ctx[any_prop_device]-false}"

  # ── Zero-diff path: stage with NO overrides keeps the minimal
  # extends:devel shape. Critical for the 17 existing downstream repos
  # (no [stage:*] sections -> byte-for-byte identical to).
  if (( ! _has_overrides )); then
    cat <<YAML

  ${_svc}:
    extends:
      service: devel
    build:
      context: .
      dockerfile: Dockerfile
      target: ${_emit_stage}
YAML
    _emit_additional_contexts_block "${_additional_contexts_str}"
    cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_svc}
    container_name: \${USER_NAME}-${_name}-${_svc}
    stdin_open: false
    tty: false
    profiles:
      - ${_svc}
YAML
    # restart: the `extends: devel` merge has nothing to inherit (devel
    # carries no policy), so a deployable stage emits its own.
    _emit_restart_line "${_restart}"
    # per-stage LOG_FILE_PATH + volume mount when [logging] /
    # [logging.<stage>] local_path is set. compose's `extends` merge
    # inherits devel's environment / volumes lists, then concatenates the
    # child's entries on top -- last-wins at runtime means the per-stage
    # override here takes effect. Volume mount duplicates devel's inherited
    # mount but compose dedups identical bind strings (Option A).
    local _stage_llp=""
    _logging_svc_local_path_mount "${_svc}" _stage_llp "${_name}" "${_setup_base}" "${_logging_global_str}" "${_logging_per_svc_str}"
    if [[ -n "${_stage_llp}" ]]; then
      echo "    environment:"
      echo "      - LOG_FILE_PATH=/var/log/${_name}/${_svc}.log"
      local _clog_keep _clog_days
      _logging_svc_retention "${_svc}" _clog_keep _clog_days "${_logging_global_str}" "${_logging_per_svc_str}"
      echo "      - CONTAINER_LOG_KEEP=${_clog_keep}"
      echo "      - CONTAINER_LOG_DAYS=${_clog_days}"
      echo "    volumes:"
      echo "      - ${_stage_llp}"
    fi
    # Per-stage [logging.<stage>] driver / rotation override (if any).
    # Without an override compose `extends: devel` already covers
    # logging: -- emit only when the stage actually diverges from devel.
    if [[ -n "${_logging_per_svc_str}" ]] && \
       grep -qE "^${_svc}:" <<< "${_logging_per_svc_str}"; then
      _emit_logging_block "${_svc}" "${_logging_global_str}" "${_logging_per_svc_str}"
    fi
    return 0
  fi

  # Rehydrate the resolved-stage record (_dflags_eff shape).
  local _eff_gui="${_ess_res[gui]-}"
  local _eff_gpu="${_ess_res[gpu]-}"
  local _eff_gpu_count="${_ess_res[gpu_count]-}"
  local _eff_gpu_caps="${_ess_res[gpu_caps]-}"
  local _eff_runtime="${_ess_res[runtime]-}"
  local _eff_net_mode="${_ess_res[net_mode]-}"
  local _eff_ipc_mode="${_ess_res[ipc_mode]-}"
  local _eff_pid_mode="${_ess_res[pid_mode]-}"
  local _eff_net_name="${_ess_res[net_name]-}"
  local _eff_privileged="${_ess_res[privileged]-}"
  local _eff_volumes="${_ess_res[volumes]-}"
  local _eff_environment="${_ess_res[environment]-}"
  local _eff_ports="${_ess_res[ports]-}"
  local _eff_cap_add="${_ess_res[cap_add]-}"
  local _eff_cap_drop="${_ess_res[cap_drop]-}"
  local _eff_sec_opt="${_ess_res[security_opt]-}"

  # ── Standalone emit (v0.18.1 fix) ──────────────────────────────
  #
  # Stages with overrides drop `extends: devel` and emit a full service
  # block, because compose `extends` MERGES list fields (volumes /
  # environment / ports / cap_add / deploy.devices) by appending child
  # entries to the parent's, not replacing them. Standalone emit sidesteps
  # the merge entirely: every list the stage touches contains exactly the
  # resolved set. Top-level fields not yet in the per-stage allowlist
  # (devices / cgroup_rules / tmpfs) are re-emitted from the enclosing
  # scope's top-level values so the stage still inherits those by default.
  cat <<YAML

  ${_svc}:
    build:
      context: .
      dockerfile: Dockerfile
      target: ${_emit_stage}
YAML
  _emit_additional_contexts_block "${_additional_contexts_str}"
  _emit_build_network_line "${_build_network}"
  cat <<YAML
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: \${TZ:-Asia/Taipei}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
YAML
  _emit_target_arch_line "${_target_arch}"
  _emit_user_build_args "${_user_build_args_str}"
  cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:${_svc}
    container_name: \${USER_NAME}-${_name}-${_svc}
    stdin_open: false
    tty: false
    profiles:
      - ${_svc}
YAML
  # Workload overlay: standalone block has no `extends: devel`
  # to inherit from, so re-emit env_file explicitly.
  _emit_env_file_block
  # privileged: literal when stage overrides; else env-var ref
  # (same shape devel emits — .env's PRIVILEGED applies).
  if [[ -n "${_eff_privileged}" ]]; then
    echo "    privileged: ${_eff_privileged}"
  else
    echo "    privileged: \${PRIVILEGED}"
  fi
  # ipc: literal when stage overrides; else env-var ref. apply does no
  # schema revalidation, so a hand-edited [stage:*] override can feed a
  # bogus mode here -- drop anything _validate_ipc_mode rejects back to the
  # env-var ref rather than emit a malformed literal (apply-time guard,
  # mirrors _emit_restart_line).
  if [[ "${_eff_ipc_mode}" != "${_ipc_mode}" ]] \
     && _validate_ipc_mode "${_eff_ipc_mode}"; then
    echo "    ipc: ${_eff_ipc_mode}"
  else
    echo "    ipc: \${IPC_MODE}"
  fi
  # pid: only emitted for "host" — Docker rejects "private" as literal.
  # Same apply-time guard: a bogus stage override drops to the env-var ref.
  if [[ "${_eff_pid_mode}" == "host" ]]; then
    if [[ "${_eff_pid_mode}" != "${_pid_mode}" ]] \
       && _validate_pid_mode "${_eff_pid_mode}"; then
      echo "    pid: ${_eff_pid_mode}"
    else
      echo "    pid: \${PID_MODE}"
    fi
  fi
  # runtime: only when explicitly set non-empty / non-auto / non-off.
  if [[ -n "${_eff_runtime}" ]] && \
     [[ "${_eff_runtime}" != "off" ]] && \
     [[ "${_eff_runtime}" != "auto" ]]; then
    echo "    runtime: ${_eff_runtime}"
  fi
  # restart / init: the standalone block has no `extends: devel` to
  # inherit from, so re-emit the [lifecycle] toggles. restart is dropped
  # for a non-deployable stage (resolved to the empty policy above).
  _emit_restart_line "${_restart}"
  _emit_init_line "${_init}"
  # cap_add / cap_drop / security_opt: effective per-stage lists —
  # a stage can override / clear inherited caps via [stage:*]
  # security.cap_add_* / cap_drop_* / security_opt_* (+ *_inherit), else
  # inherits the top-level [security] block. group_add is gated on the
  # stage's effective gui. Shared emitter with devel.
  _emit_caps_block "${_eff_cap_add}" "${_eff_cap_drop}" "${_eff_sec_opt}"
  _emit_group_add_block "${_eff_gui}" "${_dri_groups_str}"
  # network: literal mode + optional named network. When stage didn't
  # override mode, fall back to env-var ref (matches devel).
  if [[ "${_eff_net_mode}" == "bridge" ]] && [[ -n "${_eff_net_name}" ]]; then
    cat <<YAML
    networks:
      - ${_eff_net_name}
YAML
  elif [[ "${_eff_net_mode}" != "${_net_mode}" ]] \
       && _validate_network_mode "${_eff_net_mode}"; then
    # apply-time guard: a bogus hand-edited [stage:*] network.mode drops
    # to the env-var ref rather than emit a malformed literal.
    echo "    network_mode: ${_eff_net_mode}"
  else
    echo "    network_mode: \${NETWORK_MODE}"
  fi
  # hostname: pin to host name under GUI+bridge so local X11 auth works
  # (see _emit_hostname_line). Uses the stage's EFFECTIVE gui/net.
  _emit_hostname_line "${_eff_gui}" "${_eff_net_mode}" "${_host_name}"
  # environment: GUI baseline (effective gui) + effective env list
  # + LOG_FILE_PATH for the per-stage tee target.
  local _stage_llp=""
  _logging_svc_local_path_mount "${_svc}" _stage_llp "${_name}" "${_setup_base}" "${_logging_global_str}" "${_logging_per_svc_str}"
  local _stage_log_file=""
  [[ -n "${_stage_llp}" ]] && _stage_log_file="/var/log/${_name}/${_svc}.log"
  if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_environment}" ]] || [[ -n "${_stage_log_file}" ]] || [[ -n "${_watchdog_env_str}" ]]; then
    echo "    environment:"
    if [[ "${_eff_gui}" == "true" ]]; then
      cat <<'YAML'
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=/tmp/.docker.xauth
YAML
    fi
    if [[ -n "${_eff_environment}" ]]; then
      local _ev _ev_dq
      while IFS= read -r _ev; do
        [[ -z "${_ev}" ]] && continue
        # Quote each entry as a YAML double-quoted scalar (see the devel
        # env block) so structural chars in the value can't be re-parsed.
        _yaml_dq "${_ev}" _ev_dq
        echo "      - ${_ev_dq}"
      done <<< "${_eff_environment}"
    fi
    if [[ -n "${_stage_log_file}" ]]; then
      echo "      - LOG_FILE_PATH=${_stage_log_file}"
      local _clog_keep _clog_days
      _logging_svc_retention "${_svc}" _clog_keep _clog_days "${_logging_global_str}" "${_logging_per_svc_str}"
      echo "      - CONTAINER_LOG_KEEP=${_clog_keep}"
      echo "      - CONTAINER_LOG_DAYS=${_clog_days}"
    fi
    # [lifecycle] watchdog: re-emit here because a standalone stage has no
    # `extends: devel` to inherit devel's WATCHDOG_* env from.
    _emit_watchdog_env "${_watchdog_env_str}"
  fi
  # ports: only under bridge mode (compose ignores it under host).
  # Each published port is emitted as an overlay-overridable
  # ${PORT_<n>:-<default>} interpolation, not a baked literal, so a
  # multi_run .env overlay can remap the host port per instance without a
  # regenerate (ADR-00000022 forward invariant). Unset -> compose
  # substitutes the setup.conf default (identical single-run behaviour).
  # The index is 1-based (PORT_1 = first port) to match base's 1-based
  # indexed-key convention (port_1 / mount_1 / arg_1).
  _warn_ports_inert "${_eff_ports}" "${_eff_net_mode}"
  if [[ -n "${_eff_ports}" ]] && [[ "${_eff_net_mode}" == "bridge" ]]; then
    echo "    ports:"
    local _sp _spi=1
    while IFS= read -r _sp; do
      [[ -z "${_sp}" ]] && continue
      # shellcheck disable=SC2016  # literal ${} consumed by compose, not bash
      printf '      - "${PORT_%d:-%s}"\n' "${_spi}" "${_sp}"
      _spi=$(( _spi + 1 ))
    done <<< "${_eff_ports}"
  fi
  # volumes: GUI baseline (effective gui) + effective volume list
  # + [logging] local_path per-stage bind mount. _stage_llp was
  # resolved above the env block; reuse it here.
  if [[ "${_eff_gui}" == "true" ]] || [[ -n "${_eff_volumes}" ]] || [[ -n "${_stage_llp}" ]] || [[ "${_any_prop_device}" == true ]]; then
    echo "    volumes:"
    if [[ "${_eff_gui}" == "true" ]]; then
      cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:/tmp/.docker.xauth:ro
YAML
    fi
    if [[ -n "${_eff_volumes}" ]]; then
      local _m
      while IFS= read -r _m; do
        [[ -z "${_m}" ]] && continue
        echo "      - ${_m}"
      done <<< "${_eff_volumes}"
    fi
    [[ -n "${_stage_llp}" ]] && echo "      - ${_stage_llp}"
    # device entries with propagation redirect to volumes: long-form
    if [[ -n "${_devices_str}" ]]; then
      local _sd
      while IFS= read -r _sd; do
        [[ -z "${_sd}" ]] && continue
        _device_has_propagation "${_sd}" && _emit_device_as_volume "${_sd}" "    "
      done <<< "${_devices_str}"
    fi
  fi
  # devices: from top-level (plain entries only, no propagation).
  if [[ -n "${_devices_str}" ]]; then
    local _has_plain_sd=false _sd
    while IFS= read -r _sd; do
      [[ -z "${_sd}" ]] && continue
      _device_has_propagation "${_sd}" && continue
      if [[ "${_has_plain_sd}" != true ]]; then
        echo "    devices:"
        _has_plain_sd=true
      fi
      echo "      - ${_sd}"
    done <<< "${_devices_str}"
  fi
  # device_cgroup_rules + tmpfs from top-level (shared emitters).
  _emit_cgroup_rules_block "${_cgroup_rule_str}"
  _emit_tmpfs_block "${_tmpfs_str}"
  # shm_size: depends on effective ipc (only emitted under non-host ipc,
  # mirroring devel).
  if [[ -n "${_shm_size}" ]] && [[ "${_eff_ipc_mode}" != "host" ]]; then
    echo "    shm_size: ${_shm_size}"
  fi
  # deploy / GPU block (shared emitter): build the effective caps
  # YAML (per-stage resolution differs from devel), then emit.
  if [[ "${_eff_gpu}" == "true" ]]; then
    local -a _eff_caps_arr=()
    read -ra _eff_caps_arr <<< "${_eff_gpu_caps}"
    local _eff_caps_yaml="["
    local _ef=1 _ec
    for _ec in "${_eff_caps_arr[@]}"; do
      if (( _ef )); then _eff_caps_yaml+="${_ec}"; _ef=0
      else _eff_caps_yaml+=", ${_ec}"; fi
    done
    _eff_caps_yaml+="]"
    _emit_gpu_deploy_block "${_eff_gpu}" "${_eff_gpu_count}" "${_eff_caps_yaml}"
  fi
  # Stage emits a standalone block (no `extends: devel`), so it carries no
  # inherited logging — always emit the effective logging block when
  # [logging] or [logging.<stage>] is set. Keyed by the service name
  # (`_svc`) so devel-test's logging stays under [logging.test].
  _emit_logging_block "${_svc}" "${_logging_global_str}" "${_logging_per_svc_str}"
}

generate_compose_yaml() {
  local _out="${1:?}"
  local _name="${2:?}"
  local _gui="${3:?}"
  local _gpu="${4:?}"
  local _gpu_count="${5:?}"
  local _gpu_caps="${6:?}"
  local -n _gcy_extras="${7:?}"
  local _net_name="${8:-}"
  local _devices_str="${9:-}"
  local _env_str="${10:-}"
  local _tmpfs_str="${11:-}"
  local _ports_str="${12:-}"
  local _shm_size="${13:-}"
  local _net_mode="${14:-host}"
  local _ipc_mode="${15:-host}"
  local _pid_mode="${16:-private}"
  local _cap_add_str="${17:-}"
  local _cap_drop_str="${18:-}"
  local _sec_opt_str="${19:-}"
  local _cgroup_rule_str="${20:-}"
  local _user_build_args_str="${21:-}"
  local _target_arch="${22:-}"
  local _build_network="${23:-}"
  local _runtime="${24:-}"
  local _additional_contexts_str="${25:-}"
  local _logging_global_str="${26:-}"
  local _logging_per_svc_str="${27:-}"
  # Matches the template .setup.conf default (like _init below), so an
  # arg-less caller renders what a stock conf renders.
  local _restart="${28:-unless-stopped}"
  local _dri_groups_str="${29:-}"
  local _init="${30:-true}"
  local _watchdog_env_str="${31:-}"

  # Re-arm the ports-inert latch: one emit, at most one diagnostic, but a
  # second emit in the same process still reports.
  _reset_ports_inert_warning

  # Host name for the GUI+bridge hostname pin (ADR-00000019). Resolved once here so
  # both the devel service and every per-stage block emit an identical value.
  # HOSTNAME is set by every interactive/non-interactive bash the wrapper
  # runs under; fall back to `uname -n` when a caller unsets it (and tolerate
  # an empty result -- _emit_hostname_line no-ops on empty).
  local _host_name="${HOSTNAME:-$(uname -n 2>/dev/null || true)}"

  # Auto-emit any `FROM <base> AS <stage>` outside the baseline
  # blocklist {sys, devel-base, devel, runtime-test} (legacy
  # {base, test}) as a compose service that
  # `extends: devel` and only overrides target / image / container_name /
  # stdin_open / tty / profiles. generalized the v0.10.0
  # `runtime`-only detection so any user-added stage gets a
  # corresponding service automatically — e.g. NVIDIA Isaac Sim's
  # `headless` + `gui` stages share devel's baseline (GPU / network /
  # volumes) and differ only in ENTRYPOINT.
  #
  # Validation: each parsed stage runs through _validate_stage_name.
  # Returns 1 (invalid format) → WARN + skip but keep parsing.
  # Returns 2 (baseline collision) / 3 (reserved tag namespace) →
  # caller exits non-zero so user fixes the Dockerfile before retry.
  # Per-stage diff (different volumes / GPU / network than devel) is
  # out of scope v1; declare via Dockerfile ARG + conditional RUN.
  local _dockerfile _setup_base
  _setup_base="$(dirname -- "${_out}")"
  _dockerfile="${_setup_base}/Dockerfile"
  local -a _emit_stages=()
  local _stage _vrc
  while IFS= read -r _stage; do
    [[ -z "${_stage}" ]] && continue
    _vrc=0
    _validate_stage_name "${_stage}" || _vrc=$?
    case "${_vrc}" in
      0) _emit_stages+=("${_stage}") ;;
      1) _log_warn setup stage_invalid_format "display=$(_setup_msg stage invalid_format): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")" ;;
      2) _log_err setup stage_baseline_collision "display=$(_setup_msg stage baseline_collision): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")"; return 1 ;;
      3) _log_err setup stage_reserved_tag "display=$(_setup_msg stage reserved_tag): $(printf '%q' "${_stage}")" "stage=$(printf '%q' "${_stage}")"; return 1 ;;
    esac
  done < <(_parse_dockerfile_stages "${_dockerfile}")

  # Per-stage overrides — validate setup.conf [stage:*] sections.
  #
  #   sys / base / test       → hard error (baseline collision)
  #   latest / v[0-9]*        → hard error (reserved tag namespace)
  #   devel                   → reserved (v1 no-op WARN)
  #   foo (not in Dockerfile) → orphan WARN, ignored
  #
  # Stages with malformed names that don't match `[a-z][a-z0-9_-]*`
  # never reach _conf_stages because _parse_stage_sections's regex
  # already filters them; that's an acceptable v1 silent-drop since
  # the TUI is the primary write path and validates names upfront.
  local -a _conf_stages=()
  _parse_stage_sections "${_setup_base}/.setup.conf" _conf_stages
  local _cs
  for _cs in "${_conf_stages[@]}"; do
    case "${_cs}" in
      sys|base|test)
        _log_err setup stage_baseline_collision "display=$(_setup_msg stage baseline_collision): [stage:${_cs}]" "stage=${_cs}"
        return 1
        ;;
      latest|v[0-9]*)
        _log_err setup stage_reserved_tag "display=$(_setup_msg stage reserved_tag): [stage:${_cs}]" "stage=${_cs}"
        return 1
        ;;
      devel)
        _log_warn setup stage_devel_reserved "display=[stage:devel] is reserved; not applied in v1 (#220). Edit top-level sections to tune devel."
        continue
        ;;
    esac
    # Orphan check: stage is referenced but Dockerfile doesn't have it.
    local _is_emitted=0 _es
    for _es in "${_emit_stages[@]}"; do
      [[ "${_es}" == "${_cs}" ]] && _is_emitted=1 && break
    done
    if (( ! _is_emitted )); then
      _log_warn setup stage_unknown_referenced "display=$(_setup_msg stage unknown_referenced): [stage:${_cs}]" "stage=${_cs}"
    fi
  done

  # Convert space-separated caps to YAML array form [a, b, c]
  local -a _caps_arr=()
  read -ra _caps_arr <<< "${_gpu_caps}"
  local _caps_yaml="["
  local _first=1 _cap
  for _cap in "${_caps_arr[@]}"; do
    if (( _first )); then
      _caps_yaml+="${_cap}"
      _first=0
    else
      _caps_yaml+=", ${_cap}"
    fi
  done
  _caps_yaml+="]"

  {
    cat <<'HEADER'
# AUTO-GENERATED BY setup.sh — DO NOT EDIT.
# Edit setup.conf instead. Regenerate via ./build.sh --setup or ./run.sh --setup.
HEADER
    # top-level name: so non-wrapper tools (lazydocker / docker compose
    # ps / IDE panels) resolve the same project name the wrapper pins via
    # -p. It is the SAME value, not a second computation of it: setup
    # resolves [project] name once into .env.generated as PROJECT_NAME, the
    # wrapper passes that to -p, and compose interpolates it here from the
    # same --env-file. Re-assembling the hub / image pair here is what
    # made this a second answerer to one question.
    #
    # An interpolation rather than the resolved literal, per ADR-00000022:
    # the project name is a per-instance field, so it stays
    # overlay-overridable.
    cat <<'YAML'
name: ${PROJECT_NAME}
YAML
    cat <<YAML
services:
  devel:
    build:
      context: .
      dockerfile: Dockerfile
      target: devel
YAML
    _emit_additional_contexts_block "${_additional_contexts_str}"
    _emit_build_network_line "${_build_network}"
    cat <<YAML
      args:
        APT_MIRROR_UBUNTU: \${APT_MIRROR_UBUNTU:-archive.ubuntu.com}
        APT_MIRROR_DEBIAN: \${APT_MIRROR_DEBIAN:-deb.debian.org}
        TZ: \${TZ:-Asia/Taipei}
        USER_NAME: \${USER_NAME}
        USER_GROUP: \${USER_GROUP}
        USER_UID: \${USER_UID}
        USER_GID: \${USER_GID}
YAML
    _emit_target_arch_line "${_target_arch}"
    _emit_user_build_args "${_user_build_args_str}"
    cat <<YAML
    image: \${DOCKER_HUB_USER:-local}/${_name}:devel
    container_name: \${USER_NAME}-${_name}
    privileged: \${PRIVILEGED}
    ipc: \${IPC_MODE}
YAML
    # pid: only emitted for "host" — Docker rejects "private" as a
    # literal; omitting the key gives the same private-namespace default.
    if [[ "${_pid_mode}" == "host" ]]; then
      echo "    pid: \${PID_MODE}"
    fi
    cat <<YAML
    stdin_open: true
    tty: true
YAML
    # Workload overlay: devel emits it; extends:devel stages inherit.
    _emit_env_file_block
    _emit_runtime_line "${_runtime}"
    # No restart: on devel -- see _emit_restart_line. The deployable
    # stage services below emit it themselves instead of inheriting.
    _emit_init_line "${_init}"
    # cap_add / cap_drop / security_opt + group_add (shared emitters).
    _emit_caps_block "${_cap_add_str}" "${_cap_drop_str}" "${_sec_opt_str}"
    _emit_group_add_block "${_gui}" "${_dri_groups_str}"
    if [[ -n "${_net_name}" ]]; then
      cat <<YAML
    networks:
      - ${_net_name}
YAML
    else
      echo "    network_mode: \${NETWORK_MODE}"
    fi
    # hostname: pin to host name under GUI+bridge so local X11 auth works
    # (see _emit_hostname_line). No-op under host / GUI-off.
    _emit_hostname_line "${_gui}" "${_net_mode}" "${_host_name}"
    # environment: merges GUI baseline (DISPLAY etc.) + user env_N entries
    # + LOG_FILE_PATH when [logging] local_path is set for this svc
    # (consumed by .base/dist/script/docker/_entrypoint_logging.sh helper to
    # tee container stdout/stderr to the bind-mounted host file).
    # _devel_llp resolved here -- the volumes block emit below reuses
    # this variable, but the env block needs to know about the mount
    # too, so we compute once and share.
    local _devel_llp=""
    _logging_svc_local_path_mount devel _devel_llp "${_name}" "${_setup_base}" "${_logging_global_str}" "${_logging_per_svc_str}"
    local _devel_log_file=""
    [[ -n "${_devel_llp}" ]] && _devel_log_file="/var/log/${_name}/devel.log"
    if [[ "${_gui}" == "true" ]] || [[ -n "${_env_str}" ]] || [[ -n "${_devel_log_file}" ]] || [[ -n "${_watchdog_env_str}" ]]; then
      echo "    environment:"
      if [[ "${_gui}" == "true" ]]; then
        cat <<'YAML'
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=/tmp/.docker.xauth
YAML
      fi
      if [[ -n "${_env_str}" ]]; then
        # Expand `${KEY}` cross-references against earlier siblings so
        # the emitted compose.yaml carries the user's intent verbatim
        # (compose's own substitution layer does NOT see sibling env
        # entries --).
        local -a _env_expanded=()
        _expand_env_cross_refs "${_env_str}" _env_expanded
        local _ev _ev_dq
        for _ev in "${_env_expanded[@]}"; do
          [[ -z "${_ev}" ]] && continue
          # Quote each entry as a YAML double-quoted scalar so a
          # structural ": ", a leading flow indicator, or an inline " #"
          # in the value survives the parse as one string (mirrors the
          # ports/cgroup quoting; the asymmetric env sink).
          _yaml_dq "${_ev}" _ev_dq
          echo "      - ${_ev_dq}"
        done
      fi
      if [[ -n "${_devel_log_file}" ]]; then
        echo "      - LOG_FILE_PATH=${_devel_log_file}"
        local _clog_keep _clog_days
        _logging_svc_retention devel _clog_keep _clog_days "${_logging_global_str}" "${_logging_per_svc_str}"
        echo "      - CONTAINER_LOG_KEEP=${_clog_keep}"
        echo "      - CONTAINER_LOG_DAYS=${_clog_days}"
      fi
      # [lifecycle] watchdog: WATCHDOG_* env on devel; extends:devel stages
      # inherit it (it is a uniform lifecycle property, not per-svc).
      _emit_watchdog_env "${_watchdog_env_str}"
    fi
    # ports: only emitted when network_mode=bridge (ignored under host).
    # Each published port is emitted as an overlay-overridable
    # ${PORT_<n>:-<default>} interpolation, not a baked literal, so a
    # multi_run .env overlay can remap the host port per instance without a
    # regenerate (ADR-00000022 forward invariant). Unset -> compose
    # substitutes the setup.conf default (identical single-run behaviour).
    # The index is 1-based (PORT_1 = first port) to match base's 1-based
    # indexed-key convention (port_1 / mount_1 / arg_1).
    _warn_ports_inert "${_ports_str}" "${_net_mode}"
    if [[ -n "${_ports_str}" ]] && [[ "${_net_mode}" == "bridge" ]]; then
      echo "    ports:"
      local _p _pi=1
      while IFS= read -r _p; do
        [[ -z "${_p}" ]] && continue
        # shellcheck disable=SC2016  # literal ${} consumed by compose, not bash
        printf '      - "${PORT_%d:-%s}"\n' "${_pi}" "${_p}"
        _pi=$(( _pi + 1 ))
      done <<< "${_ports_str}"
    fi
    # volumes block (GUI baseline conditional; workspace + extras from
    # [volumes] mount_* — mount_1 is the workspace, auto-populated by
    # setup.sh on first run and user-editable thereafter). adds
    # the [logging] local_path bind mount when the per-service
    # resolution yields a non-empty host path -- _devel_llp was resolved
    # earlier (above the env block) so it could share with LOG_FILE_PATH.
    local _any_prop_device=false
    if [[ -n "${_devices_str}" ]]; then
      local _chk
      while IFS= read -r _chk; do
        [[ -z "${_chk}" ]] && continue
        if _device_has_propagation "${_chk}"; then _any_prop_device=true; break; fi
      done <<< "${_devices_str}"
    fi
    if [[ "${_gui}" == "true" ]] || (( ${#_gcy_extras[@]} > 0 )) || [[ -n "${_devel_llp}" ]] || [[ "${_any_prop_device}" == true ]]; then
      echo "    volumes:"
      if [[ "${_gui}" == "true" ]]; then
        cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:/tmp/.docker.xauth:ro
YAML
      fi
      local _m
      for _m in "${_gcy_extras[@]}"; do
        echo "      - ${_m}"
      done
      [[ -n "${_devel_llp}" ]] && echo "      - ${_devel_llp}"
      # device entries with propagation redirect to volumes: long-form
      if [[ -n "${_devices_str}" ]]; then
        local _d
        while IFS= read -r _d; do
          [[ -z "${_d}" ]] && continue
          _device_has_propagation "${_d}" && _emit_device_as_volume "${_d}" "    "
        done <<< "${_devices_str}"
      fi
    fi
    # devices: from [devices] section (plain entries only, no propagation)
    if [[ -n "${_devices_str}" ]]; then
      local _has_plain=false _d
      while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        _device_has_propagation "${_d}" && continue
        if [[ "${_has_plain}" != true ]]; then
          echo "    devices:"
          _has_plain=true
        fi
        echo "      - ${_d}"
      done <<< "${_devices_str}"
    fi
    # device_cgroup_rules + tmpfs (shared emitters).
    _emit_cgroup_rules_block "${_cgroup_rule_str}"
    _emit_tmpfs_block "${_tmpfs_str}"
    # shm_size: only emitted when ipc != host (otherwise Docker ignores it)
    if [[ -n "${_shm_size}" ]] && [[ "${_ipc_mode}" != "host" ]]; then
      echo "    shm_size: ${_shm_size}"
    fi
    _emit_gpu_deploy_block "${_gpu}" "${_gpu_count}" "${_caps_yaml}"
    _emit_logging_block devel "${_logging_global_str}" "${_logging_per_svc_str}"

    # Auto-emit a service per non-baseline stage parsed from the
    # Dockerfile. Each service:
    #   - extends `devel` (compose merges network / ipc / privileged /
    #     cap_add / volumes / environment / deploy.resources / runtime)
    #   - overrides build.target so docker builds the right stage
    #   - tags `image:` and `container_name:` per stage so multiple
    #     stages coexist locally without clobbering devel's `:devel`
    #   - disables stdin_open / tty: stages are typically headless
    #     entrypoints (e.g. `headless` runs runheadless.sh, `runtime`
    #     runs CMD-driven daemons). Interactive debug uses
    #     `./exec.sh -t <stage>` after `./run.sh -t <stage>`.
    #   - profiles: [<stage>] keeps plain `docker compose up` scoped to
    #     devel; explicit `compose up <stage>` or `./run.sh -t <stage>`
    #     bypasses the profile gate.
    #
    # `runtime` is no longer special-cased — it falls through
    # this loop like any other non-baseline stage, preserving its
    # behavior since `runtime` is not in the baseline blocklist.
    # Build a snapshot of the top-level volumes list (newline-separated
    # — same shape `_resolve_stage_list` consumes/produces). The list is
    # what feeds into compose.yaml's volumes block before per-stage
    # append/replace logic kicks in. _gcy_extras already excludes the
    # GUI baseline (X11) — those are emitted separately based on
    # effective gui resolution.
    local _top_volumes_str=""
    if (( ${#_gcy_extras[@]} > 0 )); then
      _top_volumes_str="$(printf '%s\n' "${_gcy_extras[@]}")"
      _top_volumes_str="${_top_volumes_str%$'\n'}"
    fi

    # accumulate named-volume references across devel + every stage so
    # the top-level `volumes:` declaration can be emitted once at the end
    # (compose requires every named volume a service references to be
    # declared). Bind mounts never enter this set. Per-stage volumes are
    # added inside the emit loop below as each stage's effective list resolves.
    local -A _named_vols=()
    _collect_named_volumes _named_vols "${_top_volumes_str}"

    # Build the shared static context once; every stage's emit reads it.
    local -A _stage_ctx=(
      [name]="${_name}"
      [setup_base]="${_setup_base}"
      [additional_contexts]="${_additional_contexts_str}"
      [build_network]="${_build_network}"
      [target_arch]="${_target_arch}"
      [user_build_args]="${_user_build_args_str}"
      [devices]="${_devices_str}"
      [cgroup_rule]="${_cgroup_rule_str}"
      [tmpfs]="${_tmpfs_str}"
      [shm_size]="${_shm_size}"
      [dri_groups]="${_dri_groups_str}"
      [init]="${_init}"
      [restart]="${_restart}"
      [watchdog_env]="${_watchdog_env_str}"
      [logging_global]="${_logging_global_str}"
      [logging_per_svc]="${_logging_per_svc_str}"
      [net_mode]="${_net_mode}"
      [ipc_mode]="${_ipc_mode}"
      [pid_mode]="${_pid_mode}"
      [host_name]="${_host_name}"
      [any_prop_device]="${_any_prop_device}"
    )

    # Auto-emit a service per non-baseline stage parsed from the
    # Dockerfile. For each: compute the legacy/real service name,
    # load + filter [stage:<name>] overrides, resolve them into a
    # per-stage docker-flags record when present, then hand that
    # resolved-stage value to the per-service emitter. devel-test
    # flows through here under the legacy service name `test`.
    local _emit_stage
    for _emit_stage in "${_emit_stages[@]}"; do
      local _svc="${_emit_stage}"
      [[ "${_emit_stage}" == "devel-test" ]] && _svc="test"
      # Load + filter [stage:<name>] overrides for this stage.
      local -a _so_keys=() _so_values=()
      _load_stage_overrides "${_setup_base}" "${_emit_stage}" _so_keys _so_values
      local -a _so_filtered_keys=() _so_filtered_values=()
      local _ki
      for (( _ki = 0; _ki < ${#_so_keys[@]}; _ki++ )); do
        if _validate_stage_override_key "${_so_keys[_ki]}"; then
          _so_filtered_keys+=("${_so_keys[_ki]}")
          _so_filtered_values+=("${_so_values[_ki]}")
        else
          _log_warn setup stage_override_key_not_allowed "display=$(_setup_msg stage override_key_not_allowed): $(printf '%q' "${_so_keys[_ki]}") (stage=${_emit_stage})" "key=$(printf '%q' "${_so_keys[_ki]}")" "stage=${_emit_stage}"
        fi
      done
      local _has_overrides=0
      (( ${#_so_filtered_keys[@]} > 0 )) && _has_overrides=1

      # Resolve the per-stage docker flags through the single shared
      # resolution layer when the stage carries overrides. The
      # resolved record is the emitter's input contract; the
      # zero-diff stage needs none (it `extends: devel`).
      local -A _dflags_eff=()
      if (( _has_overrides )); then
        local -A _dflags_parent=(
          [gui]="${_gui}"
          [gpu]="${_gpu}"
          [gpu_count]="${_gpu_count}"
          [gpu_caps]="${_gpu_caps}"
          [runtime]="${_runtime}"
          [net_mode]="${_net_mode}"
          [ipc_mode]="${_ipc_mode}"
          [pid_mode]="${_pid_mode}"
          [net_name]="${_net_name}"
          [volumes_top]="${_top_volumes_str}"
          [env_top]="${_env_str}"
          [ports_top]="${_ports_str}"
          [cap_add_top]="${_cap_add_str}"
          [cap_drop_top]="${_cap_drop_str}"
          [sec_opt_top]="${_sec_opt_str}"
        )
        _resolve_docker_flags _so_filtered_keys _so_filtered_values _dflags_parent _dflags_eff
        # pick up any named volumes this stage introduces (a
        # per-stage mount_* override may add one the top-level list lacks).
        _collect_named_volumes _named_vols "${_dflags_eff[volumes]}"
      fi

      _emit_stage_service _stage_ctx _dflags_eff "${_svc}" "${_emit_stage}" "${_has_overrides}"
    done

    # (A1'-b): the `test` service is no longer a hardcoded bare
    # block here — devel-test flows through the per-stage loop above
    # (emitted under the legacy service name `test` via `_svc`), so it
    # inherits devel by default and honours [stage:devel-test] overrides
    # like any other non-baseline stage.

    # top-level volumes: declaration for any named volumes referenced
    # by devel or a stage. Emitted before networks: (top-level section order).
    # No-op (zero-diff) when only bind mounts are used.
    _emit_volumes_block _named_vols
    if [[ -n "${_net_name}" ]]; then
      cat <<YAML

networks:
  ${_net_name}:
    driver: bridge
YAML
    fi
  } > "${_out}"
}
