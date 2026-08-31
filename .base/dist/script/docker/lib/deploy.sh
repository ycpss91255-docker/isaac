#!/usr/bin/env bash
#
# deploy.sh - self-contained field-deploy bundle generator + shared resolver.
#
# Provides:
#   _parse_deploy_manifest    : per-stage tunable-config path declarations
#   _collect_deploy_binds     : aggregate a stage's tunable paths by basename
#   _resolve_deploy_version   : git-describe bundle stamp (image identity)
#   _resolve_deploy_context   : setup.conf -> the conf-derived resolution shared
#                               by `apply` (compose) and the deploy generator
#   _generate_resolved_compose: write the self-contained, fully-resolved compose
#   _generate_deploy_launcher : write the thin up/down/logs deploy.sh
#   _render_deploy_readme     : write the generic bundle README
#   _bake_config_copy         : COPY structured config into the runtime stage
#   _generate_deploy_bundle   : build -> save|xz -> resolved compose folder
#   _expand_env_cross_refs    : expand ${VAR} cross-refs in env values
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). These call
# into setup.sh-resident deps (_setup_conf_handle, _resolve_build_network,
# _detect_dri_groups, _setup_msg, the _SETUP_SCRIPT_DIR global) and conf.sh
# accessors (_conf_get_into / _conf_list_sorted); all resolve at call-time via
# the _lib.sh load order, so this lib does not re-source them.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_DEPLOY_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_DEPLOY_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# _parse_deploy_manifest <manifest_path> <stage> <out_paths_array>
#                        [<out_modes_array>]
#
# Field-deploy tunable manifest parser (the per-component, per-stage
# declaration of operator-tunable config). A manifest is a committed,
# downstream-owned `config/<component>/deploy.manifest` with INI-lite
# per-stage sections, each listing the CONTAINER-INTERNAL absolute paths
# that a field operator may override without a rebuild, optionally
# followed by ONE access flag:
#
#   [runtime]  /camera_config.yaml                # read-only, the default
#   [runtime]  /var/lib/app/calibration.yaml rw   # container may write
#   [stream]   /etc/app/host.yaml ro              # the default, spelled out
#   # unlisted paths (launch/, udev/, ...) = baked-only (fail-safe default)
#
# The manifest's semantics are "a human edits the copy in the bundle, the
# container reads it", so the mount is READ-ONLY unless the component
# declares otherwise: a container write then fails immediately in
# development instead of on a field host whose UIDs happen not to line up.
# `rw` turns that exception into reviewable data -- it shows in a diff, and
# someone had to write down that they meant it.
#
# base DELIVERS files, it does not parse their content: this reads only the
# path declarations for <stage> into <out_paths_array>, and (when given)
# the matching `ro` / `rw` access mode into <out_modes_array> at the same
# index. Semantics:
#   - a MISSING manifest is NOT an error -> empty array, return 0 (nothing
#     tunable = everything baked, the fail-safe default);
#   - a MALFORMED manifest fails LOUD (return 1): a bad `[section]` header,
#     a content line that is not a container-internal absolute path, a path
#     declared before any `[section]` header, or an access flag that is
#     neither `ro` nor `rw` (including a second trailing token). A bad flag
#     is never skipped and never silently downgraded to read-only -- the
#     error names the file and the line, like every other defect here;
#   - only the entries under `[<stage>]` are returned; entries for other
#     stages are ignored (a path unlisted for <stage> stays baked-only).
# Leading/trailing whitespace is trimmed; blank + `#` comment lines skipped.
# The flag grammar splits on whitespace, so a declared path may not itself
# contain whitespace (such a line reads as a bad flag and fails loud).
# ════════════════════════════════════════════════════════════════════
_parse_deploy_manifest() {
  local _mf="${1:?"${FUNCNAME[0]}: missing manifest path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local -n _pdm_out="${3:?"${FUNCNAME[0]}: missing out array"}"
  _pdm_out=()
  # Access modes are an opt-in out-param: callers that only need the paths
  # (and the fail-loud grammar check) pass three arguments as before.
  local _pdm_modes_ref="${4:-}"
  if [[ -n "${_pdm_modes_ref}" ]]; then
    local -n _pdm_modes="${_pdm_modes_ref}"
    _pdm_modes=()
  fi
  # Missing manifest = nothing tunable (fail-safe), not an error.
  [[ -f "${_mf}" ]] || return 0

  local _line _trimmed _cur="" _lineno=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lineno=$(( _lineno + 1 ))
    # Trim surrounding whitespace.
    _trimmed="${_line#"${_line%%[![:space:]]*}"}"
    _trimmed="${_trimmed%"${_trimmed##*[![:space:]]}"}"
    [[ -z "${_trimmed}" ]] && continue
    [[ "${_trimmed}" == '#'* ]] && continue

    # Section header: `[<name>]`. Name must be a stage-shaped token.
    if [[ "${_trimmed}" == '['*']' ]]; then
      local _sec="${_trimmed#\[}"; _sec="${_sec%\]}"
      if [[ ! "${_sec}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        _log_err setup deploy_manifest_malformed \
          "display=[setup] deploy: malformed manifest ${_mf}:${_lineno}: bad section header '${_trimmed}'" \
          "path=${_mf}" "line=${_lineno}"
        return 1
      fi
      _cur="${_sec}"
      continue
    fi

    # Content line: `<absolute container path> [ro|rw]`, the flag optional
    # and defaulting to read-only.
    local _path _flag
    _path="${_trimmed%%[[:space:]]*}"
    _flag="${_trimmed#"${_path}"}"
    _flag="${_flag#"${_flag%%[![:space:]]*}"}"
    if [[ "${_path}" != /* ]]; then
      _log_err setup deploy_manifest_malformed \
        "display=[setup] deploy: malformed manifest ${_mf}:${_lineno}: expected an absolute container path, got '${_trimmed}'" \
        "path=${_mf}" "line=${_lineno}"
      return 1
    fi
    if [[ -z "${_cur}" ]]; then
      _log_err setup deploy_manifest_malformed \
        "display=[setup] deploy: malformed manifest ${_mf}:${_lineno}: path '${_trimmed}' declared before any [stage] section" \
        "path=${_mf}" "line=${_lineno}"
      return 1
    fi
    # An unrecognised flag is a defect, not a hint: refusing here is what
    # keeps a typo from silently mounting read-only (or read-write).
    if [[ -n "${_flag}" && "${_flag}" != "ro" && "${_flag}" != "rw" ]]; then
      _log_err setup deploy_manifest_malformed \
        "display=[setup] deploy: malformed manifest ${_mf}:${_lineno}: bad access flag '${_flag}' after '${_path}' (expected 'rw', 'ro', or nothing -- paths are mounted read-only by default)" \
        "path=${_mf}" "line=${_lineno}"
      return 1
    fi
    if [[ "${_cur}" == "${_stage}" ]]; then
      _pdm_out+=("${_path}")
      if [[ -n "${_pdm_modes_ref}" ]]; then
        _pdm_modes+=("${_flag:-ro}")
      fi
    fi
  done < "${_mf}"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _collect_deploy_binds <base_path> <stage> <out_assoc> [<out_modes_assoc>]
#
# Aggregate every component's tunable declarations for <stage> into a
# single basename -> container-path map. Globs `<base>/config/*/deploy.manifest`,
# parses each via _parse_deploy_manifest (propagating a malformed-manifest
# failure), and keys the result by the path BASENAME -- the name the file
# takes in the deploy bundle's editable `config/` folder and in the compose
# bind `./config/<basename>:<container-path>:<mode>`.
#
# When <out_modes_assoc> is given it is filled with the same keys mapped to
# the declared access mode (`ro` -- the default -- or `rw`), so the compose
# emitter can mount each bind at the access its component asked for.
#
# A DUPLICATE basename across components (two tunable files that would both
# land as `config/<basename>`) is a config error that fails LOUD (return 1):
# the bind target would be ambiguous. No manifests / no declared paths ->
# empty map, return 0 (nothing tunable, all baked).
# ════════════════════════════════════════════════════════════════════
_collect_deploy_binds() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local -n _cdb_out="${3:?"${FUNCNAME[0]}: missing out assoc"}"
  _cdb_out=()
  local _cdb_modes_ref="${4:-}"
  if [[ -n "${_cdb_modes_ref}" ]]; then
    local -n _cdb_modes="${_cdb_modes_ref}"
    _cdb_modes=()
  fi
  local _mf
  for _mf in "${_base}"/config/*/deploy.manifest; do
    # Unmatched glob yields the literal pattern; the -f guard skips it.
    [[ -f "${_mf}" ]] || continue
    local -a _paths=() _pmodes=()
    _parse_deploy_manifest "${_mf}" "${_stage}" _paths _pmodes || return 1
    local _i _p _bn
    for (( _i = 0; _i < ${#_paths[@]}; _i++ )); do
      _p="${_paths[_i]}"
      _bn="${_p##*/}"
      if [[ -n "${_cdb_out["${_bn}"]:-}" ]]; then
        _log_err setup deploy_manifest_dup_basename \
          "display=[setup] deploy: duplicate tunable basename '${_bn}' (${_cdb_out["${_bn}"]} and ${_p}); rename one so the bundle config/ mapping is unambiguous" \
          "basename=${_bn}"
        return 1
      fi
      _cdb_out["${_bn}"]="${_p}"
      if [[ -n "${_cdb_modes_ref}" ]]; then
        _cdb_modes["${_bn}"]="${_pmodes[_i]}"
      fi
    done
  done
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_version <base_path>
#
# Echo the version stamp for a deploy bundle: `git describe --tags
# --always --dirty` run in <base_path> -- the nearest tag (else the short
# commit), with a `-dirty` suffix when the working tree has uncommitted
# changes. This is the version-iteration-safe half of the image identity
# `<repo>:<stage>-<version>`, so loading multiple field versions never
# collides. Outside a git tree (or git absent) it degrades to `unknown`
# rather than aborting -- the deploy tool labels honestly and never blocks;
# a base-provided CD guard is the thing that enforces clean + tagged.
# ════════════════════════════════════════════════════════════════════
_resolve_deploy_version() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _v=""
  _v="$(git -C "${_base}" describe --tags --always --dirty 2>/dev/null || true)"
  [[ -n "${_v}" ]] || _v="unknown"
  printf '%s\n' "${_v}"
}

# ════════════════════════════════════════════════════════════════════
# _resolve_deploy_context <base_path> <out_assoc>
#
# S6b ofthe single conf-derived resolution layer shared by
# `apply` (the compose renderer) and the deploy generator. Loads the
# relevant setup.conf sections from <base_path> and resolves the
# scalar modes + aggregated list strings that both paths consume, into
# <out_assoc>. This is the global counterpart to the per-stage
# _resolve_docker_flags (S5): apply unpacks the record into its existing
# locals, and the deploy generator (S6b-gen) feeds it as the parent for
# the runtime stage. Keeping one resolver means the field deploy can
# never drift from what `apply` would produce for the same setup.conf.
#
# Pure resolution: it does NOT apply the `--gui` CLI / SETUP_GUI env
# override (apply layers that on top of the returned gui_mode), it does
# NOT resolve the detection-dependent enabled booleans (callers run
# _resolve_gpu / _resolve_gui with their own host detection), and it does
# NOT touch the WS_PATH / mount_1 migration or the device/volume
# validation warnings (those stay apply-side -- dev-specific side
# effects). The one intrinsic side effect kept here is the legacy
# `[deploy] runtime` deprecation warning, since it is tied to
# resolving gpu_runtime from the conf.
#
# Populated keys: build_network gpu_mode gpu_count gpu_caps
#   gpu_runtime_mode gui_mode net_mode ipc_mode pid_mode network_name
#   privileged restart_policy init watchdog_env_str dri_groups_str
#   devices_str cgroup_rule_str
#   env_str tmpfs_str ports_str cap_add_str cap_drop_str sec_opt_str
#   shm_size  (assoc subscripts quoted so ShellCheck does not read them
#   as arithmetic refs (SC2154) -- the out-param is a nameref).
# ════════════════════════════════════════════════════════════════════
_resolve_deploy_context() {
  local _rdc_base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local -n _rdc_out="${2:?"${FUNCNAME[0]}: missing out assoc"}"

  # Parse the section-replace-merged conf ONCE into an opaque handle, then read
  # every scalar/list from it -- replacing the former 10x per-section
  # _load_setup_conf re-parse (each call re-tokenized the whole conf). Same
  # merge precedence (ADR-00000008 follow-up).
  _setup_conf_handle "${_rdc_base}" _RDC_CONF

  local _tmp=""

  # build-time network (scalar [build] network; auto -> host on Jetson).
  local _build_network_mode="" _build_network=""
  _conf_get_into _RDC_CONF build network auto _build_network_mode
  _resolve_build_network "${_build_network_mode}" _build_network
  _rdc_out["build_network"]="${_build_network}"

  # [deploy] GPU family.
  _conf_get_into _RDC_CONF deploy gpu_mode         auto _tmp; _rdc_out["gpu_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF deploy gpu_count        all  _tmp; _rdc_out["gpu_count"]="${_tmp}"
  _conf_get_into _RDC_CONF deploy gpu_capabilities gpu  _tmp; _rdc_out["gpu_caps"]="${_tmp}"
  # gpu_runtime is the canonical key; legacy `runtime` is a permanent
  # alias (W3) consumed with a deprecation warning, removed at v1.0.0.
  # The warning fires on the legacy key's PRESENCE, not only when it is
  # consumed: a conf that sets both has a half-finished migration, and
  # that is exactly the state the user needs told about. _resolve_docker_flags
  # applies the identical rule to a [stage:*] section.
  local _gpu_runtime_mode="" _legacy_runtime=""
  _conf_get_into _RDC_CONF deploy gpu_runtime "" _gpu_runtime_mode
  _conf_get_into _RDC_CONF deploy runtime     "" _legacy_runtime
  if [[ -n "${_legacy_runtime}" ]]; then
    _log_warn setup conf_runtime_key_deprecated \
      "display=$(_setup_msg deploy runtime_deprecated)"
  fi
  if [[ -z "${_gpu_runtime_mode}" ]]; then
    _gpu_runtime_mode="${_legacy_runtime:-auto}"
  fi
  _rdc_out["gpu_runtime_mode"]="${_gpu_runtime_mode}"

  # [gui] mode (conf only -- caller layers the --gui / SETUP_GUI override).
  _conf_get_into _RDC_CONF gui mode auto _tmp; _rdc_out["gui_mode"]="${_tmp}"

  # [network] + [security] scalars.
  _conf_get_into _RDC_CONF network mode         host    _tmp; _rdc_out["net_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network ipc          host    _tmp; _rdc_out["ipc_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network pid          private _tmp; _rdc_out["pid_mode"]="${_tmp}"
  _conf_get_into _RDC_CONF network network_name ""      _tmp; _rdc_out["network_name"]="${_tmp}"
  # privileged opt-in -- default false when the key is absent.
  _conf_get_into _RDC_CONF security privileged  false   _tmp; _rdc_out["privileged"]="${_tmp}"

  # [lifecycle] restart policy. DEPLOY-scoped (never devel, never a
  # `*-test` stage -- see _is_deployable_stage), so a single default
  # serves both consumers: the template ships `unless-stopped` literally
  # and this fallback only covers a conf hand-stripped of the key.
  _conf_get_into _RDC_CONF lifecycle restart unless-stopped _tmp; _rdc_out["restart_policy"]="${_tmp}"
  # [lifecycle] init toggle -- compose `init: true` (PID1 reaper). Default
  # ON: key-absent / cleared conf resolves to true (compose-level only; the
  # generated deploy.sh run flags do not carry it).
  _conf_get_into _RDC_CONF lifecycle init true _tmp; _rdc_out["init"]="${_tmp}"

  # [lifecycle] watchdog. Emitted to the service `environment:` as
  # WATCHDOG_* env only when the master switch (watchdog_check) is set --
  # empty check => empty string => feature off (no env, no behavior change).
  # Each remaining knob is emitted only when the conf sets it, so an unset
  # knob falls back to watchdog.sh's own default. Built here as a
  # newline-separated `WATCHDOG_KEY=value` block that compose_emit YAML-quotes.
  local _wd_check=""
  _conf_get_into _RDC_CONF lifecycle watchdog_check "" _wd_check
  local _wd_env_str=""
  if [[ -n "${_wd_check}" ]]; then
    _wd_env_str="WATCHDOG_CHECK=${_wd_check}"
    local _wd_key _wd_val
    for _wd_key in interval timeout start_period failures on_fail max_restarts notify; do
      _wd_val=""
      _conf_get_into _RDC_CONF lifecycle "watchdog_${_wd_key}" "" _wd_val
      [[ -z "${_wd_val}" ]] && continue
      _wd_env_str+=$'\n'"WATCHDOG_${_wd_key^^}=${_wd_val}"
    done
  fi
  _rdc_out["watchdog_env_str"]="${_wd_env_str}"

  # dri_groups (non-NVIDIA iGPU /dev/dri); auto -> detect host GIDs.
  local _dri_groups_mode="" _dri_groups_str=""
  _conf_get_into _RDC_CONF deploy dri_groups auto _dri_groups_mode
  [[ "${_dri_groups_mode}" == "auto" ]] && _dri_groups_str="$(_detect_dri_groups)"
  _rdc_out["dri_groups_str"]="${_dri_groups_str}"

  # [devices] device_* + cgroup_rule_*.
  local -a _devices_arr=() _cgroup_rule_arr=()
  _conf_list_sorted _RDC_CONF devices "device_"      _devices_arr
  _conf_list_sorted _RDC_CONF devices "cgroup_rule_" _cgroup_rule_arr
  local _devices_str="" _cgroup_rule_str=""
  (( ${#_devices_arr[@]}      > 0 )) && _devices_str="$(printf '%s\n' "${_devices_arr[@]}")"
  (( ${#_cgroup_rule_arr[@]}  > 0 )) && _cgroup_rule_str="$(printf '%s\n' "${_cgroup_rule_arr[@]}")"
  _rdc_out["devices_str"]="${_devices_str}"
  _rdc_out["cgroup_rule_str"]="${_cgroup_rule_str}"

  # [environment] env_*, [tmpfs] tmpfs_*, [network] port_*.
  local -a _env_arr=() _tmpfs_arr=() _ports_arr=()
  _conf_list_sorted _RDC_CONF environment "env_"   _env_arr
  _conf_list_sorted _RDC_CONF tmpfs       "tmpfs_" _tmpfs_arr
  _conf_list_sorted _RDC_CONF network     "port_"  _ports_arr
  local _env_str="" _tmpfs_str="" _ports_str=""
  (( ${#_env_arr[@]}   > 0 )) && _env_str="$(printf '%s\n'   "${_env_arr[@]}")"
  (( ${#_tmpfs_arr[@]} > 0 )) && _tmpfs_str="$(printf '%s\n' "${_tmpfs_arr[@]}")"
  (( ${#_ports_arr[@]} > 0 )) && _ports_str="$(printf '%s\n' "${_ports_arr[@]}")"
  _rdc_out["env_str"]="${_env_str}"
  _rdc_out["tmpfs_str"]="${_tmpfs_str}"
  _rdc_out["ports_str"]="${_ports_str}"

  # [security] cap_add_*, cap_drop_*, security_opt_* with template fallback:
  # a per-repo [security] that wipes a list falls back to the template
  # baseline rather than Docker's stripped default (rationale).
  local -a _cap_add_arr=() _cap_drop_arr=() _sec_opt_arr=()
  _conf_list_sorted _RDC_CONF security "cap_add_"      _cap_add_arr
  _conf_list_sorted _RDC_CONF security "cap_drop_"     _cap_drop_arr
  _conf_list_sorted _RDC_CONF security "security_opt_" _sec_opt_arr
  local _tpl_setup_conf
  _tpl_setup_conf="${_SETUP_SCRIPT_DIR}/../../../.setup.conf"
  local -a _tpl_sec_k=() _tpl_sec_v=()
  [[ -f "${_tpl_setup_conf}" ]] \
    && _parse_ini_section "${_tpl_setup_conf}" "security" _tpl_sec_k _tpl_sec_v
  (( ${#_cap_add_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_add_"      _cap_add_arr
  (( ${#_cap_drop_arr[@]} == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "cap_drop_"     _cap_drop_arr
  (( ${#_sec_opt_arr[@]}  == 0 )) \
    && _get_conf_list_sorted _tpl_sec_k _tpl_sec_v "security_opt_" _sec_opt_arr
  local _cap_add_str="" _cap_drop_str="" _sec_opt_str=""
  (( ${#_cap_add_arr[@]}  > 0 )) && _cap_add_str="$(printf '%s\n'  "${_cap_add_arr[@]}")"
  (( ${#_cap_drop_arr[@]} > 0 )) && _cap_drop_str="$(printf '%s\n' "${_cap_drop_arr[@]}")"
  (( ${#_sec_opt_arr[@]}  > 0 )) && _sec_opt_str="$(printf '%s\n'  "${_sec_opt_arr[@]}")"
  _rdc_out["cap_add_str"]="${_cap_add_str}"
  _rdc_out["cap_drop_str"]="${_cap_drop_str}"
  _rdc_out["sec_opt_str"]="${_sec_opt_str}"

  # [resources] shm_size (only meaningful when ipc != host).
  _conf_get_into _RDC_CONF resources shm_size "" _tmp; _rdc_out["shm_size"]="${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_resolved_compose <base> <stage> <image_ref> <container> <out>
#                            [<binds_assoc>] [<ctx_assoc>] [<modes_assoc>]
#
# Write the self-contained, FULLY-RESOLVED field compose.yaml (ADR-00000023
# sec.3, amending ADR-00000003's "compose does not travel"). Unlike the
# dev compose (generate_compose_yaml), this carries literal resolved values
# -- NO `${VAR}` interpolation, NO env_file / setup.conf / .env.generated
# dependency, NO build section (the image is pre-built + docker-loaded), and
# NO dev-host workspace bind -- so it runs on a field host that never had
# base's toolchain. It ties the shared resolvers together exactly as apply
# does (so the field never drifts from dev):
#   _resolve_deploy_context (global conf) -> the stage parent
#   _resolve_docker_flags   (per-stage [stage:*] overrides) -> effective record
# then emits a run-only service reusing compose_emit's leaf emitters.
#
# It FOLLOWS THE STAGE (does not blanket-strip GUI/X11): gui/gpu/network are
# the deployed stage's resolved values (a headless runtime stage resolves
# gui off; a gui stage keeps its X11 host-env passthrough). `restart:`
# carries the [lifecycle] policy (shipped default `unless-stopped`, so the
# container auto-starts on host reboot). The [lifecycle] WATCHDOG_* env is
# emitted into `environment:` exactly as the dev compose does -- restart:
# only recovers a container that EXITS, the watchdog is the only mechanism
# that recovers a service that is alive but wedged. When <binds_assoc>
# (basename -> container-path, from _collect_deploy_binds) is non-empty each
# tunable file is bound `./config/<basename>:<container-path>:<mode>`
# (mount-wins over the baked default, ADR-00000023 sec.2). <mode> comes from
# the optional <modes_assoc> (same keys, from _collect_deploy_binds) and is
# `ro` for anything the manifest did not explicitly declare `rw` -- the
# operator writes on the host, the container reads, so a container write
# fails at once in development instead of on a field host whose UIDs happen
# not to line up. host-user (USER_UID) handling is unchanged (a separate
# field-user follow-up owns it).
# ════════════════════════════════════════════════════════════════════
_generate_resolved_compose() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _image_ref="${3:?"${FUNCNAME[0]}: missing image_ref"}"
  local _container="${4:?"${FUNCNAME[0]}: missing container_name"}"
  local _out="${5:?"${FUNCNAME[0]}: missing out path"}"
  local _binds_src="${6:-}"
  local _ctx_src="${7:-}"
  local _modes_src="${8:-}"

  # Re-arm the ports-inert latch (see compose_emit.sh): one bundle, at most
  # one diagnostic.
  _reset_ports_inert_warning

  # Global conf context (shared with apply). Consume a passed record when
  # given, else resolve standalone (direct callers / tests).
  local -A _grc_ctx=()
  if [[ -n "${_ctx_src}" ]]; then
    local -n _grc_ctx_in="${_ctx_src}"
    local _gk
    for _gk in "${!_grc_ctx_in[@]}"; do _grc_ctx["${_gk}"]="${_grc_ctx_in[${_gk}]}"; done
  else
    _resolve_deploy_context "${_base}" _grc_ctx
  fi

  # Tunable-manifest binds (basename -> container-path), sorted for a
  # deterministic compose.
  local -a _bind_names=()
  if [[ -n "${_binds_src}" ]]; then
    local -n _grc_binds="${_binds_src}"
    local _bk
    while IFS= read -r _bk; do
      [[ -n "${_bk}" ]] && _bind_names+=("${_bk}")
    done < <(printf '%s\n' "${!_grc_binds[@]}" | sort)
  fi
  # Per-bind access mode. Read-only is the default for anything the modes
  # record does not declare `rw` -- an omitted / absent record can only
  # tighten the mount, never loosen it. The local is `_grc_`-prefixed like
  # every other nameref target here: a local sharing the CALLER's variable
  # name would shadow the nameref and silently resolve to itself.
  local -A _grc_bind_mode=()
  if [[ -n "${_modes_src}" ]]; then
    local -n _grc_modes="${_modes_src}"
    local _mk
    for _mk in "${!_grc_modes[@]}"; do
      if [[ "${_grc_modes["${_mk}"]}" == "rw" ]]; then
        _grc_bind_mode["${_mk}"]="rw"
      fi
    done
  fi

  # Detection-dependent enabled state + runtime, resolved like apply does.
  # gui FOLLOWS THE STAGE (not forced off): conf gui_mode + host detection.
  local _gpu_detected="" _gpu_enabled="" _runtime_resolved="" _gui_detected="" _gui_enabled=""
  detect_gpu _gpu_detected
  _resolve_gpu "${_grc_ctx["gpu_mode"]}" "${_gpu_detected}" _gpu_enabled
  _resolve_runtime "${_grc_ctx["gpu_runtime_mode"]}" _runtime_resolved
  detect_gui _gui_detected
  _resolve_gui "${_grc_ctx["gui_mode"]}" "${_gui_detected}" _gui_enabled

  # Per-stage [stage:<stage>] overrides, filtered to the allowlist.
  local -a _so_k=() _so_v=() _sof_k=() _sof_v=()
  _load_stage_overrides "${_base}" "${_stage}" _so_k _so_v
  local _ki
  for (( _ki = 0; _ki < ${#_so_k[@]}; _ki++ )); do
    if _validate_stage_override_key "${_so_k[_ki]}"; then
      _sof_k+=("${_so_k[_ki]}")
      _sof_v+=("${_so_v[_ki]}")
    fi
  done

  # Parent for the per-stage resolver. volumes_top / env_top are empty (the
  # field image bakes ENV and carries no dev binds); gui carries the
  # resolved value so a [stage:*] gui.mode can still force it on / off.
  local -A _parent=(
    [gui]="${_gui_enabled}"
    [gpu]="${_gpu_enabled}"
    [gpu_count]="${_grc_ctx["gpu_count"]}"
    [gpu_caps]="${_grc_ctx["gpu_caps"]}"
    [runtime]="${_runtime_resolved}"
    [net_mode]="${_grc_ctx["net_mode"]}"
    [ipc_mode]="${_grc_ctx["ipc_mode"]}"
    [pid_mode]="${_grc_ctx["pid_mode"]}"
    [net_name]="${_grc_ctx["network_name"]}"
    [volumes_top]=""
    [env_top]=""
    [ports_top]="${_grc_ctx["ports_str"]}"
    [cap_add_top]="${_grc_ctx["cap_add_str"]}"
    [cap_drop_top]="${_grc_ctx["cap_drop_str"]}"
    [sec_opt_top]="${_grc_ctx["sec_opt_str"]}"
  )
  local -A _eff=()
  _resolve_docker_flags _sof_k _sof_v _parent _eff

  local _eff_gui="${_eff["gui"]}"
  local _eff_net_mode="${_eff["net_mode"]}"
  local _eff_net_name="${_eff["net_name"]}"
  local _eff_ipc="${_eff["ipc_mode"]}"
  local _eff_pid="${_eff["pid_mode"]}"
  local _eff_runtime="${_eff["runtime"]}"
  local _priv="${_eff["privileged"]:-${_grc_ctx["privileged"]}}"
  local _devices_str="${_grc_ctx["devices_str"]}"
  local _shm="${_grc_ctx["shm_size"]}"
  local _watchdog_env_str="${_grc_ctx["watchdog_env_str"]:-}"

  # restart: the bundle is a service-shaped container meant to run
  # forever, so `unless-stopped` (auto-start on host reboot) is the
  # shipped default; an explicitly configured [lifecycle] restart wins --
  # an operator who asked for `on-failure:5` / `no` gets it instead of a
  # silent override. apply does no schema revalidation, so a hand-edited
  # value is validated here and a malformed one falls back to the default
  # rather than breaking `docker compose up` (mirrors _emit_restart_line).
  local _restart="${_grc_ctx["restart_policy"]:-}"
  if ! _validate_restart "${_restart}"; then
    _restart="unless-stopped"
  fi

  {
    printf '# AUTO-GENERATED self-contained field deploy compose. DO NOT EDIT.\n'
    printf '# Fully resolved (no variable interpolation, no setup.conf/.env dep);\n'
    printf '# run via ./deploy.sh up|down|logs. Regenerate: just setup deploy --stage %s\n' "${_stage}"
    printf 'name: %s\n' "${_container}"
    printf 'services:\n'
    printf '  %s:\n' "${_stage}"
    printf '    image: %s\n' "${_image_ref}"
    printf '    container_name: %s\n' "${_container}"
    # Always emitted: the resolved compose leaves nothing implicit, so even
    # an explicit `no` is written out rather than dropped.
    # `on-failure:N` is quoted; a bare `:` would read as a YAML mapping.
    case "${_restart}" in
      on-failure:*) printf '    restart: "%s"\n' "${_restart}" ;;
      *)            printf '    restart: %s\n'   "${_restart}" ;;
    esac
    # init (PID1 reaper) unless the conf disabled it.
    [[ "${_grc_ctx["init"]:-true}" != "false" ]] && printf '    init: true\n'
    # privileged (literal; the field has no ${PRIVILEGED} env layer).
    [[ "${_priv}" == "true" ]] && printf '    privileged: true\n'
    # ipc: literal; the private default is omitted.
    [[ -n "${_eff_ipc}" && "${_eff_ipc}" != "private" ]] && printf '    ipc: %s\n' "${_eff_ipc}"
    # pid: only host is a valid literal.
    [[ "${_eff_pid}" == "host" ]] && printf '    pid: host\n'
    # runtime: only when explicitly set / non-auto / non-off.
    if [[ -n "${_eff_runtime}" && "${_eff_runtime}" != "off" && "${_eff_runtime}" != "auto" ]]; then
      printf '    runtime: %s\n' "${_eff_runtime}"
    fi
    # network: literal host, or a named bridge network (declared below).
    if [[ "${_eff_net_mode}" == "bridge" && -n "${_eff_net_name}" ]]; then
      printf '    networks:\n      - %s\n' "${_eff_net_name}"
    elif [[ "${_eff_net_mode}" == "host" ]]; then
      printf '    network_mode: host\n'
    fi
    # caps / security_opt + group_add (dri, gui-gated) -- shared emitters.
    _emit_caps_block "${_eff["cap_add"]}" "${_eff["cap_drop"]}" "${_eff["security_opt"]}"
    _emit_group_add_block "${_eff_gui}" "${_grc_ctx["dri_groups_str"]}"
    # environment: the GUI X11 host-env passthrough (only when the stage
    # resolves gui on) plus the [lifecycle] WATCHDOG_* block (only when the
    # conf armed the watchdog); the baked [environment] is ENV in the image
    # and is not re-emitted. The watchdog is delivered through compose, not
    # baked ENV, so the values stay visible and adjustable in the
    # self-contained bundle -- and it is the ONLY mechanism that recovers a
    # service that is alive but wedged (restart: only catches a container
    # that actually exits). ${DISPLAY:-} etc. read the field host's own
    # shell, not .env.generated. The header is emitted once for whichever
    # of the two is present.
    if [[ "${_eff_gui}" == "true" || -n "${_watchdog_env_str}" ]]; then
      printf '    environment:\n'
      if [[ "${_eff_gui}" == "true" ]]; then
        cat <<'YAML'
      - DISPLAY=${DISPLAY:-}
      - WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}
      - XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000}
      - XAUTHORITY=/tmp/.docker.xauth
YAML
      fi
      _emit_watchdog_env "${_watchdog_env_str}"
    fi
    # ports: literal host:container, only under bridge. Same gate as the dev
    # emitter, so the same diagnostic when the mapping is about to be dropped.
    _warn_ports_inert "${_eff["ports"]}" "${_eff_net_mode}"
    if [[ -n "${_eff["ports"]}" && "${_eff_net_mode}" == "bridge" ]]; then
      printf '    ports:\n'
      local _sp
      while IFS= read -r _sp; do
        [[ -z "${_sp}" ]] && continue
        printf '      - "%s"\n' "${_sp}"
      done <<< "${_eff["ports"]}"
    fi
    # volumes: GUI X11 binds (when gui) + tunable-manifest config binds +
    # propagation devices (long-form). Emitted iff any are present.
    local _any_prop=false _d
    if [[ -n "${_devices_str}" ]]; then
      while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        if _device_has_propagation "${_d}"; then _any_prop=true; break; fi
      done <<< "${_devices_str}"
    fi
    if [[ "${_eff_gui}" == "true" ]] || (( ${#_bind_names[@]} > 0 )) || [[ "${_any_prop}" == "true" ]]; then
      printf '    volumes:\n'
      if [[ "${_eff_gui}" == "true" ]]; then
        cat <<'YAML'
      - /tmp/.X11-unix:/tmp/.X11-unix:ro
      - ${XDG_RUNTIME_DIR:-/run/user/1000}:${XDG_RUNTIME_DIR:-/run/user/1000}:rw
      - ${XAUTHORITY:-/dev/null}:/tmp/.docker.xauth:ro
YAML
      fi
      # tunable-manifest binds: the editable copy in the bundle wins over the
      # baked default (mount-wins, ADR-00000023 sec.2), read-only unless the
      # manifest declared the path `rw`.
      local _bn
      for _bn in "${_bind_names[@]}"; do
        printf '      - ./config/%s:%s:%s\n' \
          "${_bn}" "${_grc_binds["${_bn}"]}" "${_grc_bind_mode["${_bn}"]:-ro}"
      done
      if [[ -n "${_devices_str}" ]]; then
        while IFS= read -r _d; do
          [[ -z "${_d}" ]] && continue
          _device_has_propagation "${_d}" && _emit_device_as_volume "${_d}" "    "
        done <<< "${_devices_str}"
      fi
    fi
    # devices: plain entries only (no propagation).
    if [[ -n "${_devices_str}" ]]; then
      local _has_plain=false
      while IFS= read -r _d; do
        [[ -z "${_d}" ]] && continue
        _device_has_propagation "${_d}" && continue
        if [[ "${_has_plain}" != "true" ]]; then printf '    devices:\n'; _has_plain=true; fi
        printf '      - %s\n' "${_d}"
      done <<< "${_devices_str}"
    fi
    _emit_cgroup_rules_block "${_grc_ctx["cgroup_rule_str"]}"
    _emit_tmpfs_block "${_grc_ctx["tmpfs_str"]}"
    # shm_size only when ipc != host.
    [[ -n "${_shm}" && "${_eff_ipc}" != "host" ]] && printf '    shm_size: %s\n' "${_shm}"
    # GPU reservation block (shared emitter) when gpu resolves on.
    if [[ "${_eff["gpu"]}" == "true" ]]; then
      local -a _caps_arr=(); read -ra _caps_arr <<< "${_eff["gpu_caps"]}"
      local _caps_yaml="[" _cf=1 _c
      for _c in "${_caps_arr[@]}"; do
        if (( _cf )); then _caps_yaml+="${_c}"; _cf=0; else _caps_yaml+=", ${_c}"; fi
      done
      _caps_yaml+="]"
      _emit_gpu_deploy_block "${_eff["gpu"]}" "${_eff["gpu_count"]}" "${_caps_yaml}"
    fi
    # Top-level networks: declare the named bridge so the field host creates
    # it (self-contained; no external prerequisite).
    if [[ "${_eff_net_mode}" == "bridge" && -n "${_eff_net_name}" ]]; then
      printf '\nnetworks:\n  %s:\n    driver: bridge\n' "${_eff_net_name}"
    fi
  } > "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_launcher <out> <stage>
#
# Write the thin, arg-driven field launcher (`deploy.sh`). It carries NO
# inlined docker flags (the resolved compose.yaml carries everything); it
# only loads the bundled image and drives compose. cd's to its own bundle
# dir so it runs from anywhere. chmod +x, ShellCheck-clean.
#   ./deploy.sh up    -> docker load < image (unxz) then docker compose up -d
#   ./deploy.sh down  -> docker compose down
#   ./deploy.sh logs  -> docker compose logs
# ════════════════════════════════════════════════════════════════════
_generate_deploy_launcher() {
  local _out="${1:?"${FUNCNAME[0]}: missing out path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  {
    cat <<EOF
#!/usr/bin/env bash
# AUTO-GENERATED field deploy launcher. DO NOT EDIT.
# Regenerate via: just setup deploy --stage ${_stage}
#
# Self-contained: loads the bundled image, then drives the resolved
# compose.yaml. Runs from anywhere (cd's to its own bundle dir).
#   ./deploy.sh up      docker load the image, then docker compose up -d
#   ./deploy.sh down    docker compose down
#   ./deploy.sh logs    docker compose logs (add -f to follow)
EOF
    cat <<'EOF'
set -euo pipefail

cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]:-$0}")")" || exit 1

IMAGE_ARCHIVE="image.tar.xz"

_cmd="${1:-up}"
if (( $# > 0 )); then shift; fi

case "${_cmd}" in
  up)
    if [[ -f "${IMAGE_ARCHIVE}" ]]; then
      unxz -c "${IMAGE_ARCHIVE}" | docker load
    fi
    docker compose up -d "$@"
    ;;
  down)
    docker compose down "$@"
    ;;
  logs)
    docker compose logs "$@"
    ;;
  *)
    {
      printf 'usage: %s {up|down|logs} [args]\n' "$0"
    } >&2
    exit 2
    ;;
esac
EOF
  } > "${_out}"
  chmod +x "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _render_deploy_readme <out> <repo> <stage> <image_ref> [<local_sections>]
#
# Write the bundle's generic README from the base-shipped template
# (dist/deploy/README, @IMAGE@ / @REPO@ / @STAGE@ substituted). Falls back
# to a minimal inline README when the template is unreachable, so the
# generator stays self-sufficient. base owns the generic template; it
# carries no per-repo knowledge.
# ════════════════════════════════════════════════════════════════════
_render_deploy_readme() {
  local _out="${1:?"${FUNCNAME[0]}: missing out path"}"
  local _name="${2:?"${FUNCNAME[0]}: missing repo name"}"
  local _stage="${3:?"${FUNCNAME[0]}: missing stage"}"
  local _image="${4:?"${FUNCNAME[0]}: missing image_ref"}"
  # Space-separated sections that came from the build host's untracked
  # .setup.conf.local (empty for the normal case). Recorded in the README
  # because an escape hatch that leaves no trace in the artifact is exactly
  # the silent dependency the refusal exists to prevent: the person holding
  # this bundle in the field is not the person who chose to bypass the gate.
  local _local_sections="${5-}"
  local _tpl="${_SETUP_SCRIPT_DIR:-}/../../../deploy/README"
  if [[ -n "${_SETUP_SCRIPT_DIR:-}" && -f "${_tpl}" ]]; then
    sed -e "s|@IMAGE@|${_image}|g" -e "s|@REPO@|${_name}|g" \
        -e "s|@STAGE@|${_stage}|g" "${_tpl}" > "${_out}"
  else
    cat > "${_out}" <<EOF
# ${_name} field deploy bundle (${_stage})

Self-contained deploy of the image ${_image}.

  ./deploy.sh up      load the image + docker compose up -d
  ./deploy.sh down    docker compose down
  ./deploy.sh logs    docker compose logs (add -f to follow)

Contents:
  image.tar.xz   the container image (deploy.sh docker-loads it)
  compose.yaml   fully-resolved, self-contained (do NOT edit)
  config/        operator-tunable config copies (edit, then ./deploy.sh up)
  deploy.sh      this launcher
  README         this file

Caution: compose.yaml is machine-generated and fully resolved. To adjust a
tunable value in the field, edit the matching file under config/ (a mounted
copy wins over the baked default) and re-run ./deploy.sh up -- do not edit
compose.yaml. You edit these files on the host and the container only reads
them: each config bind ends in its access mode and is :ro unless the
component declared that path writable (<path> rw in its manifest). Read-only
is the default because a writable mount would quietly depend on the
container's user id matching whoever unpacked this folder. The compose
restart: policy carries the repo's
[lifecycle] restart setting; at its default (unless-stopped) the container
auto-starts again after a crash and after a host reboot -- use
./deploy.sh down to stop it for good.
EOF
  fi
  _append_local_override_note "${_out}" "${_local_sections}"
}

# ════════════════════════════════════════════════════════════════════
# _append_local_override_note <readme_path> <sections>
#
# Append the "built from an untracked config layer" record to a bundle
# README. No-op when <sections> is empty, which is every normal build.
# ════════════════════════════════════════════════════════════════════
_append_local_override_note() {
  local _out="${1:?"${FUNCNAME[0]}: missing out path"}"
  local _sections="${2-}"
  [[ -n "${_sections}" ]] || return 0
  cat >> "${_out}" <<EOF

## Built with an untracked config override

This bundle was generated with \`--allow-local-override\` while the build
host had a \`.setup.conf.local\`. These setup.conf sections were taken from
that file rather than from the repository:

    ${_sections// /, }

\`.setup.conf.local\` is gitignored. Its contents are not in the repository,
so this bundle CANNOT be reproduced from a clean checkout -- reproducing it
requires that same file. Treat the values above as unversioned.
EOF
}

# ════════════════════════════════════════════════════════════════════
# _bake_config_copy <src_dockerfile> <stage> <out>
#
# S4 deploy half: splice `COPY config/app /opt/app/config`
# into the <stage> stage of <src_dockerfile>, writing the result to <out>.
# The dev side bind-mounts config/app (apply); the field image bakes it in
# as an immutable layer so the deploy bundle is self-contained. Insert is
# right after the `FROM ... AS <stage>` line (handles src == out via a
# temp file). Caller only invokes this when <base>/config/app exists.
#
# Which line counts as `FROM ... AS <stage>` is _dockerfile_stage_from_line's
# call (lib/stage.sh), shared with the [environment] ENV bake so the two
# splices can never land in different stages of the same Dockerfile.
# ════════════════════════════════════════════════════════════════════
_bake_config_copy() {
  local _src="${1:?"${FUNCNAME[0]}: missing src dockerfile"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _out="${3:?"${FUNCNAME[0]}: missing out"}"
  local _tmp _line _found
  _tmp="$(mktemp)"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if _dockerfile_stage_from_line "${_line}" _found \
       && [[ "${_found}" == "${_stage}" ]]; then
      printf '# >>> config/app baked (generated by setup.sh, #504/#506) <<<\n' >> "${_tmp}"
      printf 'COPY config/app /opt/app/config\n' >> "${_tmp}"
    fi
  done < "${_src}"
  mv -- "${_tmp}" "${_out}"
}

# ════════════════════════════════════════════════════════════════════
# _generate_deploy_bundle <base_path> <stage> <out_dir>
#
# Orchestrate the self-contained field-deploy FOLDER (ADR-00000023 sec.3;
# supersedes the raw-run tar.xz{image, docker-run deploy.sh}). Produces, under
# <out_dir> (the caller's `deploy/<repo>-<stage>-<version>/`):
#   image.tar.xz   the image (deploy.sh docker-loads it), tagged
#                  <repo>:<stage>-<version> so field versions never collide
#   compose.yaml   fully-resolved, self-contained (no ${VAR} / setup.conf dep)
#   config/        editable copies of each tunable file (baked default, the
#                  compose binds them mount-wins), from _collect_deploy_binds
#   deploy.sh      thin up/down/logs launcher
#   README         generic base template
#
# Steps: resolve name/version/image -> collect tunable binds (fail loud on a
# malformed / duplicate-basename manifest) -> bake [environment] ENV (S3) +
# COPY config/app (S4) into a temp Dockerfile -> docker build --target ->
# docker save | xz -> extract each tunable's baked default into config/ ->
# generate compose.yaml + deploy.sh + README -> install into <out_dir>.
#
# The compose / deploy.sh / README are written docker-free up front (so the
# plan is inspectable), while the docker / xz / cp / install steps run
# through _dry_run_cmd, so DRY_RUN=true prints the plan without building and
# leaves no side effect (the temp workdir is removed).
# ════════════════════════════════════════════════════════════════════
_generate_deploy_bundle() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local _out_dir="${3:?"${FUNCNAME[0]}: missing out_dir"}"

  local _name=""
  BASE_PATH="${_base}" detect_image_name _name "${_base}"
  local _version; _version="$(_resolve_deploy_version "${_base}")"
  local _image="${_name}:${_stage}-${_version}"
  local _container="${_name}-${_stage}"

  local -A _ctx=()
  _resolve_deploy_context "${_base}" _ctx

  # Tunable-manifest binds + their declared access modes; a malformed /
  # duplicate-basename manifest fails loud BEFORE any build side effect.
  local -A _binds=() _bind_modes=()
  _collect_deploy_binds "${_base}" "${_stage}" _binds _bind_modes || return 1

  local _work
  _work="$(mktemp -d)"
  mkdir -p "${_work}/config"
  local _gen="${_work}/Dockerfile.deploy"
  local _build_dockerfile="${_base}/Dockerfile"

  # Bake [environment] as ENV (S3) into the stage actually being built.
  # A no-op (nothing configured under [environment]) keeps the plain
  # Dockerfile silently; a stage the Dockerfile does not declare returns 2
  # and is already WARN'd by name inside the generator, so the operator
  # hears about it before `docker build --target` fails on the same name.
  if _generate_runtime_dockerfile "${_base}/Dockerfile" "${_ctx["env_str"]}" "${_gen}" "${_stage}"; then
    _build_dockerfile="${_gen}"
  fi
  # Bake config/app into the image (S4 deploy half) when the repo ships it.
  if [[ -d "${_base}/config/app" ]]; then
    _bake_config_copy "${_build_dockerfile}" "${_stage}" "${_gen}"
    _build_dockerfile="${_gen}"
  fi

  # Deterministic, docker-free artifacts up front (inspectable under DRY_RUN).
  _generate_resolved_compose "${_base}" "${_stage}" "${_image}" "${_container}" \
    "${_work}/compose.yaml" _binds _ctx _bind_modes
  _generate_deploy_launcher "${_work}/deploy.sh" "${_stage}"
  # The bundle records the untracked sections it was built from, so the
  # record travels with the artifact rather than living only in the build
  # host's terminal scrollback.
  local -a _gdb_local_sections=()
  _setup_conf_local_sections "${_base}" _gdb_local_sections
  _render_deploy_readme "${_work}/README" "${_name}" "${_stage}" "${_image}" \
    "${_gdb_local_sections[*]-}"

  local _rc=0
  # Build the image tagged <repo>:<stage>-<version> so the field docker load
  # aligns with the compose image ref.
  _dry_run_cmd docker build --target "${_stage}" \
    -f "${_build_dockerfile}" -t "${_image}" "${_base}" || _rc=$?
  # Save + xz-compress into the bundle (deploy.sh unxz | docker loads it).
  if (( _rc == 0 )); then
    _dry_run_cmd docker save -o "${_work}/image.tar" "${_image}" || _rc=$?
  fi
  if (( _rc == 0 )); then
    _dry_run_cmd xz -f "${_work}/image.tar" || _rc=$?
  fi
  # Extract each tunable's baked default into the editable config/ folder via
  # one throwaway container. The image MUST bake a FILE at every declared
  # tunable path: the field bind mounts config/<basename> OVER that baked
  # default (mount-wins), and a bind whose target does not exist as a file
  # fails at `deploy.sh up` with a cryptic runc "mount a directory onto a
  # file" error. Catch it here at generate time with a clear, actionable
  # message instead (never-fail-silently, PRD invariant 2).
  if (( _rc == 0 )) && (( ${#_binds[@]} > 0 )); then
    local _xc="${_container}-cfgextract"
    _dry_run_cmd docker create --name "${_xc}" "${_image}" || _rc=$?
    local _bn _cp_ok
    for _bn in "${!_binds[@]}"; do
      (( _rc == 0 )) || break
      _cp_ok=1
      _dry_run_cmd docker cp "${_xc}:${_binds["${_bn}"]}" "${_work}/config/${_bn}" || _cp_ok=0
      # A real run must land a regular file. DRY_RUN only plans (docker cp is
      # echoed, nothing is written), so skip the existence check there.
      if [[ "${DRY_RUN:-false}" != "true" ]] \
         && { (( ! _cp_ok )) || [[ ! -f "${_work}/config/${_bn}" ]]; }; then
        _log_err setup deploy_manifest_no_baked_default \
          "display=[setup] deploy: config/<component>/deploy.manifest declares ${_binds["${_bn}"]} as tunable, but the ${_stage} image bakes no file there. The Dockerfile must COPY or create a default file at ${_binds["${_bn}"]} (the field bind mounts an editable copy over that baked default; ADR-00000023)." \
          "path=${_binds["${_bn}"]}" "stage=${_stage}"
        _rc=1
        break
      fi
    done
    _dry_run_cmd docker rm -f "${_xc}" || true
  fi

  # Install the assembled bundle into the output folder.
  if (( _rc == 0 )); then
    _dry_run_cmd mkdir -p "${_out_dir}" || _rc=$?
  fi
  if (( _rc == 0 )); then
    _dry_run_cmd cp -a "${_work}/." "${_out_dir}/" || _rc=$?
  fi

  rm -rf "${_work}"
  return "${_rc}"
}

# _parse_logging_svc_sections / _collect_logging moved to
# lib/conf_logging.sh in (PR-A) so both setup.sh and the
# upcoming PR-B gitignore sync (lib/gitignore.sh) can share them
# without circular sourcing. _lib.sh now pulls conf_logging.sh in
# automatically, so callers below still resolve the same names.

# _sync_logging_local_paths_gitignore moved to lib/gitignore.sh in
# (PR-B) and renamed _sync_logging_gitignore (now takes only
# <base_path>, calls _collect_logging itself). Sync runs at
# init.sh / upgrade.sh time instead of every setup.sh apply, so
# the file stays in step across template versions even when no
# wrapper has fired since the last setup.conf edit.

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml <out> <repo_name> <gui_enabled> <gpu_enabled>
#                       <gpu_count> <gpu_caps> <extras_array_ref>
#                       [<network_name>]
#
# Emits full compose.yaml with:
#   - Baseline: workspace + X11 (iff GUI) + GUI env block (iff GUI)
#   - Conditional: GPU deploy block (iff gpu_enabled=true)
#   - Extra volumes from [volumes] section (comes in via extras_array_ref)
#   - When network_name is given (only meaningful for mode=bridge), the
#     service joins that external network and a top-level `networks:`
#     block declares it external. Otherwise falls back to the env-driven
#     `network_mode: ${NETWORK_MODE}`.
# IPC/privileged always read from env var refs; .env provides values.
# ════════════════════════════════════════════════════════════════════

# _expand_env_cross_refs <input-newline-list> <output-array-name>
#
# Reads `KEY=VALUE` entries (one per line, blank lines skipped) and
# substitutes `${KEY}` references in each value with the value of an
# earlier-seen sibling KEY. Order-sensitive: forward references (a value
# referencing a sibling not yet parsed) survive as the literal `${VAR}`,
# as do unknown references with no matching sibling -- compose.yaml's
# own substitution layer (.env / shell env) gets a chance at file-load
# time, surfacing genuinely undefined names visibly rather than silently
# substituting empty.
#
# Resolvespreviously, sibling cross-references in
# `[environment] env_N` were emitted literally and compose's `${VAR}`
# substitution does NOT consult sibling environment entries -- so e.g.
#   env_1 = BUILD_TARGET=production
#   env_2 = LD_LIBRARY_PATH=/foo/${BUILD_TARGET}/lib
# would ship `LD_LIBRARY_PATH=/foo//lib` to the container.
_expand_env_cross_refs() {
  local _input="$1"
  local -n _expand_out_arr="$2"
  _expand_out_arr=()
  declare -A _seen=()
  local _line _k _v _ref_k _ref_v _expanded
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _k="${_line%%=*}"
    _v="${_line#*=}"
    _expanded="${_v}"
    # Substitute every ${ref_k} found in _v against earlier siblings.
    # Multiple-pass not needed because _seen already holds fully-expanded
    # values from prior iterations (transitive references resolve through
    # the chain naturally).
    for _ref_k in "${!_seen[@]}"; do
      _ref_v="${_seen[${_ref_k}]}"
      _expanded="${_expanded//\$\{${_ref_k}\}/${_ref_v}}"
    done
    _seen["${_k}"]="${_expanded}"
    _expand_out_arr+=("${_k}=${_expanded}")
  done <<< "${_input}"
}
