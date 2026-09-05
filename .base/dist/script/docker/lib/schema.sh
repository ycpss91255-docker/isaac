#!/usr/bin/env bash
#
# schema.sh — setup.conf validation registry + dispatcher (epic).
#
# Single source of truth for "is this <section>.<key> = <value> valid?".
# Both setup.sh (the `set` / `add` subcommands, via _setup_validate_kv)
# and the TUI route their accept/reject decision through
# `_schema_validate`, so the two can no longer drift — the TUI can no
# longer accept input that setup.sh rejects, and vice versa.
#
# The registry only maps a canonical (section,key) to the NAME of the
# validator function; the validator bodies stay in _tui_conf.sh. This
# file sources _tui_conf.sh (idempotent via its own guard) so any
# consumer of schema.sh gets the validators without depending on
# _lib.sh's umbrella load order — mirrors how compose.sh /
# config_summary.sh pull in their lib deps.
#
# Style: Google Shell Style Guide.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_SCHEMA_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_SCHEMA_SOURCED=1

_schema_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/docker/lib/_tui_conf.sh
source "${_schema_dir}/_tui_conf.sh"
unset _schema_dir

# ════════════════════════════════════════════════════════════════════
# Registry
#
# Canonical key form:
#   scalar key -> "<section>.<key>"          (e.g. deploy.gpu_count)
#   list key   -> "<section>.<prefix>_"      (trailing underscore kept;
#                 the numbered suffix N is stripped before lookup, so
#                 network.port_1 / port_2 / ... all resolve to
#                 "network.port_")
#
# SCHEMA_VALIDATOR maps the canonical key to the validator function name.
# An unregistered key is free-form: _schema_validate accepts any value
# (matches setup.sh's historical default-accept behaviour).
# ════════════════════════════════════════════════════════════════════
declare -gA SCHEMA_VALIDATOR=(
  # ── scalar keys ──────────────────────────────────────────────────
  [project.name]=_validate_project_name
  [deploy.gpu_mode]=_validate_detect_mode
  [deploy.gpu_count]=_validate_gpu_count
  [deploy.gpu_capabilities]=_validate_gpu_capabilities
  [deploy.gpu_runtime]=_validate_runtime
  [deploy.runtime]=_validate_runtime          # legacy alias
  [deploy.dri_groups]=_validate_dri_groups
  [gui.mode]=_validate_detect_mode
  [security.privileged]=_validate_privileged
  [resources.shm_size]=_validate_shm_size
  [lifecycle.restart]=_validate_restart
  [lifecycle.init]=_validate_init
  [lifecycle.watchdog_check]=_validate_watchdog_cmd
  [lifecycle.watchdog_interval]=_validate_watchdog_posint
  [lifecycle.watchdog_timeout]=_validate_watchdog_posint
  [lifecycle.watchdog_start_period]=_validate_watchdog_nonneg
  [lifecycle.watchdog_failures]=_validate_watchdog_posint
  [lifecycle.watchdog_on_fail]=_validate_watchdog_on_fail
  [lifecycle.watchdog_max_restarts]=_validate_watchdog_posint
  [lifecycle.watchdog_notify]=_validate_watchdog_cmd
  [build.target_arch]=_validate_target_arch
  [build.network]=_validate_build_network
  [network.network_name]=_validate_network_name
  [network.mode]=_validate_network_mode
  [network.ipc]=_validate_ipc_mode
  [network.pid]=_validate_pid_mode
  [logging.driver]=_validate_log_driver
  [logging.max_size]=_validate_log_max_size
  [logging.max_file]=_validate_log_max_file
  [logging.compress]=_validate_log_compress
  [logging.local_path]=_validate_log_local_path
  [logging.container_log_keep]=_validate_container_log_keep
  [logging.container_log_days]=_validate_container_log_days
  [logging.wrapper_transcript]=_validate_wrapper_transcript
  [logging.wrapper_transcript_keep]=_validate_wrapper_transcript_keep
  [logging.wrapper_transcript_days]=_validate_wrapper_transcript_days
  # ── list keys (numbered suffix normalised to the trailing-_ prefix) ─
  [image.rule_]=_validate_image_rule
  [security.security_opt_]=_validate_security_opt
  [build.arg_]=_validate_env_kv
  [volumes.mount_]=_validate_mount
  [devices.device_]=_validate_mount
  [devices.cgroup_rule_]=_validate_cgroup_rule
  [environment.env_]=_validate_env_kv
  [network.port_]=_validate_port_mapping
  [additional_contexts.context_]=_validate_additional_context
  [security.cap_add_]=_validate_capability
  [security.cap_drop_]=_validate_capability
)

# ════════════════════════════════════════════════════════════════════
# SCHEMA_SECTIONS — the ordered list of setup.conf sections.
#
# Single source for "which sections exist, in what order" (the order
# matches the setup.conf template headers). Consumers derive from this
# instead of hand-maintaining parallel section lists:
#   - setup.sh's _setup_known_section (via _schema_is_section)
#   - the TUI menu dispatch + CLI subcommand recognition
# so adding a section here makes it known/dispatchable without editing
# those call sites. Note some sections (image / gui / tmpfs) carry only
# free-form keys and so have no SCHEMA_VALIDATOR rows; the list is kept
# explicit rather than derived from the validator map so those sections
# are not dropped.
declare -ga SCHEMA_SECTIONS=(
  project image build deploy lifecycle gui network security resources
  environment tmpfs devices volumes additional_contexts logging
)

# ════════════════════════════════════════════════════════════════════
# SCHEMA_I18N — the i18n-index (deferred fromepic).
#
# Maps each canonical SCHEMA_VALIDATOR key to the i18n message key its
# TUI editor shows as the key's label/help (the `_tui_msg` key resolved
# in setup_tui.sh's per-locale _TUI_MSG_* tables). This is the missing
# link lacked: it makes "every key has a translation in all four
# locales (en / zh-TW / zh-CN / ja)" mechanically assertable from the
# registry (see test/bats/unit/schema_coverage_spec.bats).
#
# Keying mirrors SCHEMA_VALIDATOR exactly (scalar "<section>.<key>", list
# "<section>.<prefix>_"). For scalar keys the value is the editor's
# `.prompt` message key; for list keys it is the per-entry prompt key
# passed to _edit_list_section. The mapped message key must exist in ALL
# FOUR locale tables — the coverage spec fails on a gap.
#
# Empty string ("") is the explicit "no TUI editor" opt-out: a key that
# is schema-validated (so setup.sh's `set`/`add` gate it) but has no
# interactive editor, hence no label/help to translate. The transcript
# knobs (logging.wrapper_transcript*) are config-file / env only,
# never surfaced in the menu, so they map to "". Every registered
# validator key MUST appear here (the coverage spec asserts the index is
# complete) — opting a key out is a deliberate "" entry, not an omission.
# ════════════════════════════════════════════════════════════════════
declare -gA SCHEMA_I18N=(
  # ── scalar keys ──────────────────────────────────────────────────
  # project.name: config-file / CLI only. The TUI edits the COMMITTED
  # .setup.conf, while the per-worktree name belongs in the gitignored
  # .setup.conf.local that `setup.sh set --local project.name <x>` writes
  # -- a layer the menu has no concept of. Surfacing a project-name row
  # there would edit the wrong file by default, so this is a deliberate
  # no-editor opt-out, not a missing translation.
  [project.name]=""
  [deploy.gpu_mode]=deploy.mode.prompt
  [deploy.gpu_count]=deploy.count.prompt
  [deploy.gpu_capabilities]=deploy.caps.prompt
  [deploy.gpu_runtime]=deploy.runtime.prompt
  [deploy.runtime]=deploy.runtime.prompt        # legacy alias
  # dri_groups: config-file / CLI only (the deploy page edits the NVIDIA
  # knobs; the /dev/dri GID grant has no menu row) -- no-editor opt-out.
  [deploy.dri_groups]=""
  [gui.mode]=gui.mode.prompt
  [security.privileged]=security.privileged.prompt
  [resources.shm_size]=resources.shm_size.prompt
  [lifecycle.restart]=lifecycle.restart.prompt
  # init: config-file / CLI (`setup.sh set lifecycle.init`) only, never
  # surfaced in the TUI menu -- explicit no-editor opt-out.
  [lifecycle.init]=""
  # watchdog: config-file / CLI only, never surfaced in the TUI
  # menu -- explicit no-editor opt-out (same posture as init / transcript).
  [lifecycle.watchdog_check]=""
  [lifecycle.watchdog_interval]=""
  [lifecycle.watchdog_timeout]=""
  [lifecycle.watchdog_start_period]=""
  [lifecycle.watchdog_failures]=""
  [lifecycle.watchdog_on_fail]=""
  [lifecycle.watchdog_max_restarts]=""
  [lifecycle.watchdog_notify]=""
  [build.target_arch]=build.target_arch.prompt
  [build.network]=build.network.prompt
  [network.network_name]=network.name.prompt
  [network.mode]=network.mode.prompt
  [network.ipc]=network.ipc.prompt
  [network.pid]=network.pid.prompt
  [logging.driver]=logging.driver.prompt
  [logging.max_size]=logging.max_size.prompt
  [logging.max_file]=logging.max_file.prompt
  [logging.compress]=logging.compress.prompt
  [logging.local_path]=logging.local_path.prompt
  # Config-file / env only, no TUI editor -> no label to translate.
  [logging.container_log_keep]=""
  [logging.container_log_days]=""
  [logging.wrapper_transcript]=""
  [logging.wrapper_transcript_keep]=""
  [logging.wrapper_transcript_days]=""
  # ── list keys (per-entry prompt shown by _edit_list_section) ───────
  # rule_N is edited as a two-step (type, then value); the type prompt is
  # the per-entry label.
  [image.rule_]=image.type.prompt
  [security.security_opt_]=security.security_opt.prompt
  [build.arg_]=build.arg.prompt
  [volumes.mount_]=volumes.edit.prompt
  [devices.device_]=devices.device.prompt
  [devices.cgroup_rule_]=devices.cgroup.prompt
  [environment.env_]=environment.entry.prompt
  [network.port_]=ports.entry.prompt
  [additional_contexts.context_]=additional_contexts.entry.prompt
  [security.cap_add_]=security.cap_add.prompt
  [security.cap_drop_]=security.cap_drop.prompt
)

# SCHEMA_EMPTY records the per-key empty-value policy. Default (a key
# absent from this map) is "allow": an empty value clears the key and is
# always accepted. The exception is keys whose validator rejects empty by
# design — they are marked "validate" so the empty string is passed
# through to the validator (which rejects it).
declare -gA SCHEMA_EMPTY=(
  [deploy.gpu_count]=validate
)

# ════════════════════════════════════════════════════════════════════
# SCHEMA_FREEFORM — the explicit "this key really has no value set"
# opt-out.
#
# Registering the missing validators one by one fixes today's gap and
# nothing else: the next key added to the template reopens it, which is
# exactly how gui.mode / deploy.gpu_mode / gpu_capabilities / dri_groups
# / security_opt_ / image.rule_ / security.privileged slipped through.
# schema_coverage_spec asserts that EVERY key the shipped setup.conf
# declares -- live line or commented example -- resolves to a
# SCHEMA_VALIDATOR entry or appears here, so "unregistered key with a
# fixed value set" is a CI failure rather than a runtime surprise.
#
# Keying mirrors SCHEMA_VALIDATOR (scalar "<section>.<key>", list
# "<section>.<prefix>_"). The value is the REASON the key genuinely
# accepts arbitrary input; an empty reason fails the coverage spec.
# Opting out is a deliberate, reviewable statement -- not a default.
#
# Currently empty: every shipped key has a value set worth enforcing.
#
# Declarative data, read by schema_coverage_spec's completeness gate
# rather than by any function in this lib -- so the unused-variable
# warning is expected here and nowhere else in the file.
# shellcheck disable=SC2034
declare -gA SCHEMA_FREEFORM=()

# ════════════════════════════════════════════════════════════════════
# _schema_is_section <section>
#
# Returns 0 when <section> is one of the SCHEMA_SECTIONS, 1 otherwise.
# The single membership predicate consumers (setup.sh's
# _setup_known_section, the TUI dispatch) route through so the section
# list is not duplicated. Per-service [logging.<svc>] variants are NOT
# sections here -- that special case lives in _setup_known_section.
# ════════════════════════════════════════════════════════════════════
_schema_is_section() {
  local _s="${1-}"
  local _sec
  for _sec in "${SCHEMA_SECTIONS[@]}"; do
    [[ "${_sec}" == "${_s}" ]] && return 0
  done
  return 1
}

# ════════════════════════════════════════════════════════════════════
# _schema_section_keys <section> <outarray>
#
# Fills <outarray> with the registered key parts for <section>, derived
# from SCHEMA_VALIDATOR by canonical-key prefix. A scalar canonical key
# "<section>.<key>" yields "<key>"; a list key "<section>.<prefix>_"
# yields "<prefix>_" (trailing underscore kept). Free-form-only sections
# (image / gui / tmpfs) yield an empty array. Order is unspecified
# (associative-array iteration) -- callers that need a stable order sort.
# ════════════════════════════════════════════════════════════════════
_schema_section_keys() {
  local _section="${1-}"
  local -n _ssk_out="${2:?_schema_section_keys: missing out var}"
  _ssk_out=()
  local _canon
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    [[ "${_canon}" == "${_section}."* ]] && _ssk_out+=("${_canon#"${_section}".}")
  done
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _schema_canonical_key <section> <key> <out_canon>
#
# Resolves (section,key) to its registry canonical key in <out_canon>,
# or the empty string when the key is free-form (not in the registry).
# Normalises per-service logging sections ([logging.<svc>] -> logging)
# and numbered list keys (port_3 -> port_).
# ════════════════════════════════════════════════════════════════════
_schema_canonical_key() {
  local _section="${1-}"
  local _key="${2-}"
  local -n _sck_out="${3:?_schema_canonical_key: missing out var}"

  # [logging.<svc>] per-service overrides share the [logging] key set.
  [[ "${_section}" == logging.* ]] && _section="logging"

  # Exact (scalar) match first.
  if [[ -v "SCHEMA_VALIDATOR[${_section}.${_key}]" ]]; then
    _sck_out="${_section}.${_key}"
    return 0
  fi

  # List match: strip a trailing _<digits> to the registered prefix.
  if [[ "${_key}" =~ ^(.+_)[0-9]+$ ]]; then
    local _pfx="${BASH_REMATCH[1]}"
    if [[ -v "SCHEMA_VALIDATOR[${_section}.${_pfx}]" ]]; then
      _sck_out="${_section}.${_pfx}"
      return 0
    fi
  fi

  _sck_out=""
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _schema_i18n_key <section> <key> [<fallback>]
#
# Resolves (section,key) to its SCHEMA_I18N message key (the TUI
# label/help key). Normalises the same way _schema_canonical_key does
# (per-service logging sections, numbered list suffix), so port_3 and
# port_ both resolve to the network.port_ entry. Returns the mapped
# message key on stdout. When the key is free-form (no registry entry),
# its index value is "" (opted out of a TUI label), or the section/key is
# unknown, echoes <fallback> (default empty) so callers can keep a literal
# default. The setup TUI routes its per-key prompt lookups through this so
# the i18n-index is the single source the coverage spec asserts and
# the menu strings can't silently drift from it.
# ════════════════════════════════════════════════════════════════════
_schema_i18n_key() {
  local _section="${1-}"
  local _key="${2-}"
  local _fallback="${3-}"

  local _canon
  _schema_canonical_key "${_section}" "${_key}" _canon

  if [[ -n "${_canon}" && -n "${SCHEMA_I18N[${_canon}]:-}" ]]; then
    printf '%s' "${SCHEMA_I18N[${_canon}]}"
    return 0
  fi
  printf '%s' "${_fallback}"
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate <section> <key> <value>
#
# The single validation gate. Returns 0 when <value> is acceptable for
# <section>.<key>, non-zero otherwise. Free-form keys accept any value.
# ════════════════════════════════════════════════════════════════════
_schema_validate() {
  local _section="${1-}"
  local _key="${2-}"
  local _value="${3-}"

  local _canon
  _schema_canonical_key "${_section}" "${_key}" _canon

  # Free-form key: accept any value.
  [[ -z "${_canon}" ]] && return 0

  # Empty-value policy. Default "allow" (empty clears the key); only keys
  # marked "validate" delegate the empty string to their validator.
  local _policy="${SCHEMA_EMPTY[${_canon}]:-allow}"
  if [[ -z "${_value}" && "${_policy}" == "allow" ]]; then
    return 0
  fi

  "${SCHEMA_VALIDATOR[${_canon}]}" "${_value}"
}
