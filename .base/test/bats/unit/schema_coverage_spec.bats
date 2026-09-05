#!/usr/bin/env bats
#
# schema_coverage_spec.bats — registry drift guards for lib/schema.sh
# (schema epic phase 3).
#
# Phase 1 added the validator registry; phase 2 added the
# ordered SCHEMA_SECTIONS + accessors. These tests assert the registry
# stays internally consistent and in sync with the setup.conf template,
# so schema drift fails CI instead of surfacing as a runtime surprise:
#   - every validator name resolves to a defined function,
#   - SCHEMA_SECTIONS matches the template section headers in file order,
#   - every SCHEMA_EMPTY key is a registered validator key,
#   - every registered key is reachable via SCHEMA_SECTIONS.
#
# Phase 3 follow-up adds the i18n-index column SCHEMA_I18N and the
# locale-coverage assertion the original scope deferred: every
# registered key maps to an i18n key (or an explicit "" opt-out for keys
# with no TUI editor), and every mapped i18n key is present in all four
# locale tables (en / zh-TW / zh-CN / ja). A missing translation in any
# locale, or a new validator key without an index entry, fails CI here.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/schema.sh
}

# Source setup_tui.sh to populate the per-locale _TUI_MSG_* tables. The
# BASH_SOURCE guard at the bottom of setup_tui.sh keeps main from
# running, so this only loads the i18n tables + helpers (mirrors tui_spec).
_load_locale_tables() {
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup_tui.sh
}

@test "every SCHEMA_VALIDATOR validator name resolves to a defined function (#562)" {
  local _canon _fn _missing=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    _fn="${SCHEMA_VALIDATOR[${_canon}]}"
    declare -F "${_fn}" >/dev/null 2>&1 || _missing+=" ${_canon}=>${_fn}"
  done
  [ -z "${_missing}" ] || { echo "validators not defined:${_missing}"; false; }
}

@test "SCHEMA_SECTIONS matches the setup.conf template headers in file order (#562)" {
  # Registry / template drift guard: the ordered SCHEMA_SECTIONS list must
  # equal the [section] headers in the shipped template, in file order. A
  # section added to the template but not the registry (or vice versa)
  # fails here.
  local _tpl="/source/dist/.setup.conf"
  local -a _hdrs=()
  local _line
  while IFS= read -r _line; do
    _hdrs+=("${_line}")
  done < <(grep -oE '^\[[a-z_]+\]' "${_tpl}" | tr -d '[]')
  [ "${SCHEMA_SECTIONS[*]}" = "${_hdrs[*]}" ]
}

@test "every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key (#562)" {
  # The empty-value policy table may only reference keys that actually
  # have a validator -- an orphan SCHEMA_EMPTY entry is dead config.
  local _k _missing=""
  for _k in "${!SCHEMA_EMPTY[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] || _missing+=" ${_k}"
  done
  [ -z "${_missing}" ] || { echo "orphan SCHEMA_EMPTY keys:${_missing}"; false; }
}

@test "every registered key is reachable via SCHEMA_SECTIONS (#562)" {
  # No validator key may be stranded under a section missing from
  # SCHEMA_SECTIONS: the count of keys reachable by walking
  # SCHEMA_SECTIONS + _schema_section_keys must equal the registry size.
  local _seen=0 _sec
  for _sec in "${SCHEMA_SECTIONS[@]}"; do
    local -a _k=()
    _schema_section_keys "${_sec}" _k
    _seen=$(( _seen + ${#_k[@]} ))
  done
  [ "${_seen}" -eq "${#SCHEMA_VALIDATOR[@]}" ]
}

@test "every SCHEMA_VALIDATOR key has a SCHEMA_I18N index entry (#591)" {
  # The i18n-index must be complete: every registered validator key needs
  # an SCHEMA_I18N row (a message key, or an explicit "" opt-out for keys
  # with no TUI editor). A new validator key added without an index entry
  # fails here, forcing the author to decide its i18n mapping.
  local _canon _missing=""
  for _canon in "${!SCHEMA_VALIDATOR[@]}"; do
    [[ -v "SCHEMA_I18N[${_canon}]" ]] || _missing+=" ${_canon}"
  done
  [ -z "${_missing}" ] || { echo "validator keys missing SCHEMA_I18N entry:${_missing}"; false; }
}

@test "every SCHEMA_I18N key is a registered SCHEMA_VALIDATOR key (#591)" {
  # No orphan index rows: an SCHEMA_I18N entry pointing at a key with no
  # validator is dead config (mirrors the SCHEMA_EMPTY orphan guard).
  local _k _missing=""
  for _k in "${!SCHEMA_I18N[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] || _missing+=" ${_k}"
  done
  [ -z "${_missing}" ] || { echo "orphan SCHEMA_I18N keys:${_missing}"; false; }
}

@test "every SCHEMA_I18N message key exists in all four locale tables (#591)" {
  # The coverage assertion deferred: resolve each registered key's
  # i18n key through SCHEMA_I18N and assert it is present in EN / ZH_TW /
  # ZH_CN / JA. A missing translation in any locale fails CI. Keys mapped
  # to "" (no TUI editor) are skipped — they carry no label to translate.
  _load_locale_tables

  local -n _t_en=_TUI_MSG_EN
  local -n _t_tw=_TUI_MSG_ZH_TW
  local -n _t_cn=_TUI_MSG_ZH_CN
  local -n _t_ja=_TUI_MSG_JA

  local _canon _msg _missing=""
  for _canon in "${!SCHEMA_I18N[@]}"; do
    _msg="${SCHEMA_I18N[${_canon}]}"
    [[ -z "${_msg}" ]] && continue   # explicit no-editor opt-out
    [[ -v "_t_en[${_msg}]" ]] || _missing+=" en:${_canon}->${_msg}"
    [[ -v "_t_tw[${_msg}]" ]] || _missing+=" zh-TW:${_canon}->${_msg}"
    [[ -v "_t_cn[${_msg}]" ]] || _missing+=" zh-CN:${_canon}->${_msg}"
    [[ -v "_t_ja[${_msg}]" ]] || _missing+=" ja:${_canon}->${_msg}"
  done
  [ -z "${_missing}" ] || { echo "i18n keys missing from a locale:${_missing}"; false; }
}

@test "_schema_i18n_key resolves scalar + list keys, falls back when free-form (#591)" {
  # The accessor the TUI routes through. Scalar + numbered-list keys resolve
  # to their indexed message key; a free-form key (no registry row) returns
  # the supplied fallback so callers keep their literal default.
  run _schema_i18n_key resources shm_size
  assert_success
  assert_output "resources.shm_size.prompt"

  # Numbered list suffix normalises to the registered prefix.
  run _schema_i18n_key network port_3
  assert_success
  assert_output "ports.entry.prompt"

  # Per-service logging section folds onto the [logging] key set.
  run _schema_i18n_key logging.devel driver
  assert_success
  assert_output "logging.driver.prompt"

  # Free-form (unregistered) key -> fallback echoed verbatim.
  run _schema_i18n_key tmpfs tmpfs_1 tmpfs.entry.prompt
  assert_success
  assert_output "tmpfs.entry.prompt"

  # No-editor opt-out ("" index value) -> fallback, not the empty string.
  run _schema_i18n_key logging wrapper_transcript fallback.key
  assert_success
  assert_output "fallback.key"
}

# ════════════════════════════════════════════════════════════════════
# Template / registry completeness
#
# Registering the five missing validators one by one is a fix for
# today's gap and nothing more -- the next key added to the template
# reopens it, which is exactly how gui.mode / deploy.gpu_mode /
# gpu_capabilities / dri_groups / security_opt_ got in. This guard makes
# an unregistered template key structurally impossible: every key the
# shipped setup.conf ships (live or as a commented example) must resolve
# to a SCHEMA_VALIDATOR entry, or be listed in SCHEMA_FREEFORM with a
# written reason.
# ════════════════════════════════════════════════════════════════════

# Emit "<section> <key>" for every key the shipped template declares:
# live `key = value` lines plus commented `# key = value` examples, which
# are documented knobs users uncomment.
_template_keys() {
  local _tpl="/source/dist/.setup.conf"
  local _section="" _line _key
  while IFS= read -r _line; do
    if [[ "${_line}" =~ ^\[([a-z_]+)\]$ ]]; then
      _section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ -n "${_section}" ]] || continue
    # Strict shape only: `key = value` / `key =`, optionally behind a
    # single leading `# `. Prose comments never match.
    [[ "${_line}" =~ ^#?[[:space:]]*([a-z][a-z0-9_]*)[[:space:]]*= ]] || continue
    _key="${BASH_REMATCH[1]}"
    printf '%s %s\n' "${_section}" "${_key}"
  done < "${_tpl}"
}

# Opt-out lookup that tolerates the map not existing at all, so a
# missing SCHEMA_FREEFORM surfaces as "this key has no opt-out" rather
# than a bash arithmetic-subscript error.
_is_freeform() {
  declare -p SCHEMA_FREEFORM >/dev/null 2>&1 || return 1
  [[ -v "SCHEMA_FREEFORM[${1}]" ]]
}

@test "every shipped setup.conf key is registered or an explicit free-form opt-out (#876)" {
  local _section _key _canon _pfx _missing=""
  while read -r _section _key; do
    _schema_canonical_key "${_section}" "${_key}" _canon
    [[ -n "${_canon}" ]] && continue
    _is_freeform "${_section}.${_key}" && continue
    if [[ "${_key}" =~ ^(.+_)[0-9]+$ ]]; then
      _pfx="${BASH_REMATCH[1]}"
      _is_freeform "${_section}.${_pfx}" && continue
    fi
    _missing+=" ${_section}.${_key}"
  done < <(_template_keys)
  [ -z "${_missing}" ] || {
    echo "template keys with no validator and no SCHEMA_FREEFORM opt-out:${_missing}"
    false
  }
}

@test "every SCHEMA_FREEFORM entry carries a written reason (#876)" {
  local _k _blank=""
  for _k in "${!SCHEMA_FREEFORM[@]}"; do
    [[ -n "${SCHEMA_FREEFORM[${_k}]}" ]] || _blank+=" ${_k}"
  done
  [ -z "${_blank}" ] || { echo "opt-outs with an empty reason:${_blank}"; false; }
}

@test "no key is both SCHEMA_VALIDATOR-registered and SCHEMA_FREEFORM-opted-out (#876)" {
  local _k _both=""
  for _k in "${!SCHEMA_FREEFORM[@]}"; do
    [[ -v "SCHEMA_VALIDATOR[${_k}]" ]] && _both+=" ${_k}"
  done
  [ -z "${_both}" ] || { echo "registered AND opted out:${_both}"; false; }
}
