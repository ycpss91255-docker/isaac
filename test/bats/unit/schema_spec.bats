#!/usr/bin/env bats
#
# schema_spec.bats — unit tests for the setup.conf validation registry
# (lib/schema.sh, epic).
#
# `_schema_validate <section> <key> <value>` is the single validation
# gate routed through by BOTH setup.sh (set/add) and the TUI. The
# registry maps a canonical (section,key) to the validator that lives in
# _tui_conf.sh; the dispatcher normalises per-service logging sections
# and numbered list keys before lookup.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/schema.sh
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — list keys (numbered suffix normalised to prefix)
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes network.port_N to _validate_port_mapping (accept)" {
  run _schema_validate network port_1 "8080:80"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes network.port_N to _validate_port_mapping (reject)" {
  run _schema_validate network port_1 "not-a-port"
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — scalar keys (exact match) + empty-value policy
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes deploy.gpu_count to _validate_gpu_count (accept)" {
  run _schema_validate deploy gpu_count "all"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes deploy.gpu_count to _validate_gpu_count (reject)" {
  run _schema_validate deploy gpu_count "-1"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate rejects empty deploy.gpu_count (empty policy = validate)" {
  run _schema_validate deploy gpu_count ""
  [ "${status}" -ne 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — per-service logging section normalisation
# ([logging.<svc>] shares the [logging] key validators) + empty=allow
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate routes logging.driver to _validate_log_driver (accept)" {
  run _schema_validate logging driver "json-file"
  [ "${status}" -eq 0 ]
}

@test "_schema_validate routes logging.driver to _validate_log_driver (reject)" {
  run _schema_validate logging driver "bad driver!"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate allows empty logging.driver (empty policy = allow)" {
  run _schema_validate logging driver ""
  [ "${status}" -eq 0 ]
}

@test "_schema_validate normalises logging.<svc> to the logging key set (reject)" {
  run _schema_validate logging.test driver "bad driver!"
  [ "${status}" -ne 0 ]
}

@test "_schema_validate normalises logging.<svc> to the logging key set (accept)" {
  run _schema_validate logging.devel driver "journald"
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_validate — full registry coverage (parity with the validators
# that setup.sh AND the TUI wire). Table-driven: each row is
# "<section>|<key>|<value>|<expect: ok|fail>". This is the union: keys
# the TUI validated but setup.sh historically accepted (target_arch /
# build_network / gpu_runtime / runtime alias / network.name /
# devices.device_ / security.cap_add_ / cap_drop_) are now rejected by
# BOTH paths — the divergence closes.
# ════════════════════════════════════════════════════════════════════

# Helper: assert _schema_validate verdict for one row.
_assert_schema() {
  local _section="$1" _key="$2" _value="$3" _expect="$4"
  if _schema_validate "${_section}" "${_key}" "${_value}"; then
    [[ "${_expect}" == "ok" ]] \
      || { echo "expected FAIL but ACCEPTED: ${_section}.${_key} = '${_value}'"; return 1; }
  else
    [[ "${_expect}" == "fail" ]] \
      || { echo "expected ACCEPT but REJECTED: ${_section}.${_key} = '${_value}'"; return 1; }
  fi
}

@test "_schema_validate accepts every registered key's valid sample" {
  _assert_schema resources shm_size "2gb" ok
  _assert_schema lifecycle restart "unless-stopped" ok
  _assert_schema lifecycle init "true" ok
  _assert_schema lifecycle init "false" ok
  _assert_schema lifecycle watchdog_check "rosnode ping -a" ok
  _assert_schema lifecycle watchdog_interval "30" ok
  _assert_schema lifecycle watchdog_timeout "10" ok
  _assert_schema lifecycle watchdog_start_period "0" ok
  _assert_schema lifecycle watchdog_failures "3" ok
  _assert_schema lifecycle watchdog_on_fail "restart-container" ok
  _assert_schema lifecycle watchdog_on_fail "restart-service" ok
  _assert_schema lifecycle watchdog_max_restarts "5" ok
  _assert_schema lifecycle watchdog_notify "curl -X POST https://hook" ok
  _assert_schema build target_arch "arm64" ok
  _assert_schema build network "host" ok
  _assert_schema build arg_1 "FOO=bar" ok
  _assert_schema deploy gpu_mode "force" ok
  _assert_schema deploy gpu_capabilities "gpu compute" ok
  _assert_schema deploy gpu_runtime "nvidia" ok
  _assert_schema deploy runtime "auto" ok
  _assert_schema deploy dri_groups "auto" ok
  _assert_schema gui mode "off" ok
  _assert_schema image rule_1 "@basename" ok
  _assert_schema network network_name "my_net" ok
  _assert_schema network mode "host" ok
  _assert_schema network mode "container:db" ok
  _assert_schema network ipc "shareable" ok
  _assert_schema network ipc "container:db" ok
  _assert_schema network pid "host" ok
  _assert_schema network pid "private" ok
  _assert_schema network pid "container:db" ok
  _assert_schema logging max_size "10m" ok
  _assert_schema logging max_file "3" ok
  _assert_schema logging compress "true" ok
  _assert_schema logging local_path "/var/log/app" ok
  _assert_schema logging container_log_keep "20" ok
  _assert_schema logging container_log_days "14" ok
  _assert_schema volumes mount_1 "/data:/data:ro" ok
  _assert_schema devices device_1 "/dev/snd:/dev/snd" ok
  _assert_schema devices cgroup_rule_1 "c 81:* rmw" ok
  _assert_schema environment env_1 "FOO=bar" ok
  _assert_schema additional_contexts context_1 "repo=.." ok
  _assert_schema security cap_add_1 "SYS_ADMIN" ok
  _assert_schema security cap_drop_1 "NET_RAW" ok
  _assert_schema security privileged "false" ok
  _assert_schema security security_opt_1 "seccomp:unconfined" ok
}

@test "_schema_validate rejects every registered key's invalid sample" {
  _assert_schema resources shm_size "huge" fail
  _assert_schema lifecycle restart "sometimes" fail
  _assert_schema lifecycle init "garbage" fail
  _assert_schema lifecycle watchdog_interval "0" fail
  _assert_schema lifecycle watchdog_timeout "-5" fail
  _assert_schema lifecycle watchdog_start_period "-1" fail
  _assert_schema lifecycle watchdog_failures "abc" fail
  _assert_schema lifecycle watchdog_on_fail "restart-host" fail
  _assert_schema lifecycle watchdog_max_restarts "1.5" fail
  _assert_schema lifecycle watchdog_check $'has\nnewline' fail
  _assert_schema build target_arch "sparc" fail
  _assert_schema build network "carrier-pigeon" fail
  _assert_schema build arg_1 "1BAD=x" fail
  _assert_schema deploy gpu_mode "on" fail
  _assert_schema deploy gpu_capabilities "gpu bogus" fail
  _assert_schema deploy gpu_runtime "podman" fail
  _assert_schema deploy runtime "podman" fail
  _assert_schema deploy dri_groups "on" fail
  _assert_schema gui mode "of" fail
  _assert_schema image rule_1 "whatever" fail
  _assert_schema network network_name "-bad" fail
  _assert_schema network mode "foo: bar" fail
  _assert_schema network mode "bogus" fail
  _assert_schema network ipc "bogus" fail
  _assert_schema network ipc "bridge" fail
  _assert_schema network pid "shareable" fail
  _assert_schema network pid "bogus" fail
  _assert_schema logging max_size "10petabytes" fail
  _assert_schema logging max_file "0" fail
  _assert_schema logging compress "maybe" fail
  _assert_schema logging local_path $'has\nnewline' fail
  _assert_schema logging container_log_keep "0" fail
  _assert_schema logging container_log_days "abc" fail
  _assert_schema volumes mount_1 "noslash" fail
  _assert_schema devices device_1 "noslash" fail
  _assert_schema devices cgroup_rule_1 "bogus" fail
  _assert_schema environment env_1 "1BAD=x" fail
  _assert_schema additional_contexts context_1 "noequals" fail
  _assert_schema security cap_add_1 "lowercase" fail
  _assert_schema security cap_drop_1 "has space" fail
  _assert_schema security privileged "yes" fail
  _assert_schema security security_opt_1 "anything goes" fail
}

# Embedded-newline values must be rejected by every value-bearing
# validator, mirroring the [logging] local_path guard above (line ~140).
# A real newline in any of these flows verbatim into compose.yaml's
# environment: / additional_contexts: / volumes: / devices: lists, where
# it injects an extra YAML line (a setup.conf injection vector).
@test "_schema_validate rejects embedded-newline values (YAML injection) (#687)" {
  _assert_schema environment env_1 $'FOO=a\nBAR=x' fail
  _assert_schema additional_contexts context_1 $'name=v\ninject' fail
  _assert_schema additional_contexts context_1 $'repo=.\ninject' fail
  _assert_schema volumes mount_1 $'/d:/d\ninject' fail
  _assert_schema devices device_1 $'/dev/x:/dev/x\ninject' fail
}

# The numeric validators are deliberately shape-only: they constrain the
# *form* (digits, colon, optional protocol) but delegate range/bound
# checking to docker at `compose up` time. This test PINS that contract so
# a future tightening (range check) or loosening (accepting non-numeric)
# is observable rather than silent.
@test "_schema_validate numeric validators are shape-only, not range-bound (#687)" {
  # In-shape-but-out-of-range integers are accepted (delegated to docker):
  _assert_schema network port_1 "0:0" ok
  _assert_schema network port_1 "70000:80" ok
  _assert_schema network port_1 "99999999999:80" ok
  _assert_schema deploy gpu_count "999999999999999999999" ok
  _assert_schema logging max_file "999999" ok
  # Shape violations are still rejected, so the contract is shape, not free-form:
  _assert_schema network port_1 "0:" fail
  _assert_schema deploy gpu_count "1.5" fail
  _assert_schema logging max_file "0" fail
}

@test "_schema_validate allows empty (clear) for every list + clearable scalar key" {
  _assert_schema resources shm_size "" ok
  _assert_schema lifecycle restart "" ok
  _assert_schema lifecycle watchdog_check "" ok
  _assert_schema lifecycle watchdog_notify "" ok
  _assert_schema lifecycle watchdog_interval "" ok
  _assert_schema build target_arch "" ok
  _assert_schema build arg_1 "" ok
  _assert_schema network network_name "" ok
  _assert_schema network mode "" ok
  _assert_schema network ipc "" ok
  _assert_schema network pid "" ok
  _assert_schema volumes mount_1 "" ok
  _assert_schema devices device_1 "" ok
  _assert_schema environment env_1 "" ok
  _assert_schema security cap_add_1 "" ok
}

@test "_schema_validate accepts free-form (unregistered) keys" {
  # security.security_opt_ and image.rule_ used to sit here: both have a
  # closed value set their consumer dispatches on, so both are registered
  # now and the free-form default no longer covers them.
  _assert_schema tmpfs tmpfs_1 "/run:size=64m" ok
  _assert_schema environment not_a_registered_key "anything goes" ok
}

# ════════════════════════════════════════════════════════════════════
# SCHEMA_SECTIONS — ordered section list (epic)
#
# Single source for "which sections exist, in what order". setup.sh's
# _setup_known_section and the TUI dispatch derive from it so adding a
# section here makes it known/dispatchable without hand-editing them.
# ════════════════════════════════════════════════════════════════════

@test "SCHEMA_SECTIONS lists every setup.conf section in file order (#561)" {
  local _expected="project image build deploy lifecycle gui network security resources environment tmpfs devices volumes additional_contexts logging"
  [ "${SCHEMA_SECTIONS[*]}" = "${_expected}" ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_is_section — SCHEMA_SECTIONS membership predicate
# ════════════════════════════════════════════════════════════════════

@test "_schema_is_section accepts a registered section with typed keys (#561)" {
  run _schema_is_section build
  [ "${status}" -eq 0 ]
}

@test "_schema_is_section accepts a free-form-only section (image) (#561)" {
  run _schema_is_section image
  [ "${status}" -eq 0 ]
}

@test "_schema_is_section rejects an unknown section (#561)" {
  run _schema_is_section nonsense
  [ "${status}" -ne 0 ]
}

@test "_schema_is_section rejects a per-service logging variant (#561)" {
  # [logging.<svc>] is not a base section; its known-ness is the
  # _setup_known_section special case, not this membership predicate.
  run _schema_is_section logging.foo
  [ "${status}" -ne 0 ]
}

@test "_schema_is_section tracks SCHEMA_SECTIONS additions (single source) (#561)" {
  SCHEMA_SECTIONS+=(brandnew)
  run _schema_is_section brandnew
  [ "${status}" -eq 0 ]
}

# ════════════════════════════════════════════════════════════════════
# _schema_section_keys <section> <outarray> — registered keys per
# section, derived from SCHEMA_VALIDATOR by canonical-key prefix.
# Order is unspecified (assoc-array iteration), so tests sort.
# ════════════════════════════════════════════════════════════════════

# _sorted_keys <section> -> echoes the section's keys, sorted, space-joined.
_sorted_keys() {
  local -a _k=()
  _schema_section_keys "${1}" _k
  (( ${#_k[@]} == 0 )) && return 0
  printf '%s\n' "${_k[@]}" | sort | tr '\n' ' '
}

@test "_schema_section_keys returns scalar+list keys for build (#561)" {
  [ "$(_sorted_keys build)" = "arg_ network target_arch " ]
}

@test "_schema_section_keys returns all logging keys (#561, #606)" {
  [ "$(_sorted_keys logging)" = "compress container_log_days container_log_keep driver local_path max_file max_size wrapper_transcript wrapper_transcript_days wrapper_transcript_keep " ]
}

@test "_schema_section_keys returns deploy keys incl. legacy alias (#561)" {
  [ "$(_sorted_keys deploy)" = "dri_groups gpu_capabilities gpu_count gpu_mode gpu_runtime runtime " ]
}

@test "_schema_section_keys returns the rule_ list key for image (#561, #876)" {
  # [image] was free-form-only until rule_N got a validator; it now
  # yields exactly the one registered list key.
  [ "$(_sorted_keys image)" = "rule_ " ]
}

# ════════════════════════════════════════════════════════════════════
# Registry completeness: keys whose resolver has a fixed value set
#
# An unregistered key was accepted with ANY value and the resolver then
# discarded it in a catch-all branch, so `setup set gui.mode of` exited
# 0, printed a success line and left the GUI following host detection.
# The same value passed as `--gui of` was rejected. These pin the
# conf/CLI-set path to the resolver's real value set.
# ════════════════════════════════════════════════════════════════════

@test "_schema_validate gates gui.mode the way the --gui flag does (#876)" {
  _assert_schema gui mode "auto" ok
  _assert_schema gui mode "force" ok
  _assert_schema gui mode "off" ok
  _assert_schema gui mode "of" fail
  _assert_schema gui mode "true" fail
}

@test "_schema_validate gates the [deploy] keys the resolver reads (#876)" {
  _assert_schema deploy gpu_mode "auto" ok
  _assert_schema deploy gpu_mode "force" ok
  _assert_schema deploy gpu_mode "off" ok
  _assert_schema deploy gpu_mode "on" fail
  _assert_schema deploy gpu_capabilities "gpu compute utility graphics" ok
  _assert_schema deploy gpu_capabilities "all" ok
  _assert_schema deploy gpu_capabilities "gpu bogus" fail
  _assert_schema deploy dri_groups "auto" ok
  _assert_schema deploy dri_groups "off" ok
  _assert_schema deploy dri_groups "on" fail
}

@test "_schema_validate gates the [security] keys the resolver reads (#876)" {
  _assert_schema security privileged "true" ok
  _assert_schema security privileged "false" ok
  _assert_schema security privileged "yes" fail
  _assert_schema security security_opt_1 "seccomp:unconfined" ok
  _assert_schema security security_opt_1 "apparmor=unconfined" ok
  _assert_schema security security_opt_1 "no-new-privileges:true" ok
  _assert_schema security security_opt_1 "anything goes" fail
  _assert_schema security security_opt_1 "noseparator" fail
}

@test "_schema_validate gates image.rule_N against the dispatch prefixes (#876)" {
  _assert_schema image rule_1 "prefix:docker_" ok
  _assert_schema image rule_1 "suffix:_ws" ok
  _assert_schema image rule_1 "string:my-image" ok
  _assert_schema image rule_1 "@basename" ok
  _assert_schema image rule_1 "@default:fallback" ok
  # detect_image_name has no branch for these: they are skipped in
  # silence and the run ends on the 'unknown' fallback.
  _assert_schema image rule_1 "whatever" fail
  _assert_schema image rule_1 "prefix:" fail
  _assert_schema image rule_1 "@basename-ish" fail
}
