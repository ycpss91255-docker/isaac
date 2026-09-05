#!/usr/bin/env bash
#
# stage.sh - multi-stage Dockerfile parsing + per-stage override resolution.
#
# The stage subsystem setup.sh uses to turn a multi-stage Dockerfile + its
# [stage.<name>.*] overrides into per-stage compose services: stage-name
# validation (_validate_stage_name), Dockerfile stage parsing + content hashing
# (_parse_dockerfile_stages / _compute_dockerfile_hash / _generate_runtime_dockerfile),
# the override readers (_parse_stage_sections / _load_stage_overrides /
# _validate_stage_override_key), and the append/replace resolvers
# (_resolve_stage_scalar / _resolve_stage_list / _resolve_docker_flags).
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# the conf accessors (lib/setup_conf.sh, lib/conf.sh), the resolvers + _setup_msg
# + globals that stay in setup.sh; all resolve at call-time via the _lib.sh load
# order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_STAGE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_STAGE_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# Stage helpers
# ════════════════════════════════════════════════════════════════════

# _validate_stage_name <stage>
#
# Returns:
#   0 — valid; auto-emit as compose service
#   1 — invalid format (caller WARNs + skips, continues parsing other stages)
#   2 — collides with template-managed baseline
#       {sys, devel-base, devel, runtime-test}; hard error
#       (caller exits non-zero). `devel-test` is deliberately NOT in
#       that set -- see the note in the body. For backward compatibility
#       during the v0.21.x transition the legacy names {base, test} are
#       also accepted as baseline (downstream Dockerfiles renamed to
#       devel-base / devel-test over a coordinated rollout); they will
#       be removed from the blocklist in a future major release.
#   3 — collides with template-controlled image-tag namespace
#       ({latest} | v[0-9]*); hard error
#
# Exit codes are distinct so the parser/emitter can react differently
# (skip-with-warn vs abort) without re-validating.
_validate_stage_name() {
  local _stage="$1"
  # Order matters: collision / reserved checks fire BEFORE format check
  # so a name that matches both a reserved pattern AND has a format
  # quirk (e.g. `v1.2` — dotted, but still in v[0-9]* reserved
  # namespace) gets the more severe verdict (hard error 3) instead of
  # the milder format-only verdict (skip 1). Same name should not
  # silently drop as "invalid format" if its real problem is namespace
  # collision.

  # 1. baseline collision (template-managed stages)
  #    Forward-looking: sys / devel-base / devel / runtime-test
  #    Legacy (backward-compat during v0.21.x transition): base / test
  #    (A1'-b): `devel-test` is NOT in this set — it is emitted as a
  #    compose service (legacy name `test`) through the per-stage
  #    inherit-with-override loop, so `[stage:devel-test]` gives it a
  #    runtime control surface (e.g. GPU pytest). The service name `test`
  #    stays blocklisted below so a Dockerfile `AS test` can't collide
  #    with devel-test's emitted service.
  case "${_stage}" in
    sys|devel-base|devel|runtime-test) return 2 ;;
    base|test) return 2 ;;
  esac
  # 2. reserved tag namespace (template-controlled tag slots)
  case "${_stage}" in
    latest)   return 3 ;;
    v[0-9]*)  return 3 ;;
  esac
  # 3. format check (lowercase, leading letter, [a-z0-9_-])
  [[ "${_stage}" =~ ^[a-z][a-z0-9_-]*$ ]] || return 1
  return 0
}

# _is_deployable_stage <stage>
#
# ADR-00000023 sec.4's stage-eligibility predicate, `deployable = not
# devel and not *-test`, as one shared function. Returns 0 when <stage>
# is a field-oriented stage, 1 otherwise (including an empty name).
# Two callers share it, and must keep sharing it so the rule has exactly
# one definition: the compose emitter (which `restart:` services get a
# policy) and the deploy subcommand (which stages may be built into a
# field bundle at all).
#
# The exclusions differ in kind:
#   - `devel` IS the interactive shell -- the container lives exactly as
#     long as that shell, so any service-shaped policy applied to it
#     (auto-restart above all) fights the developer instead of helping,
#     and shipping a toolchain image designed to bind host source to the
#     field ships the wrong artifact;
#   - a `*-test` stage exists to run, assert and EXIT, so a policy that
#     reacts to exit turns a green test run into a restart loop;
#   - `sys` / `devel-base` are build intermediates with no runnable
#     service at all -- there is nothing to deploy and nothing to keep
#     alive, so a bundle built from one is simply broken.
# The legacy aliases the v0.21.x transition still accepts (`test` for
# `devel-test`, the bare service name it is emitted under, and `base`
# for `devel-base`) are excluded alongside the names that replaced them.
# The remaining baseline names, `devel-test` and `runtime-test`, are
# already covered by `*-test`.
_is_deployable_stage() {
  local _stage="${1-}"
  [[ -n "${_stage}" ]] || return 1
  case "${_stage}" in
    devel|test|*-test) return 1 ;;
    sys|devel-base|base) return 1 ;;
  esac
  return 0
}

# ── The stage-declaring FROM line ────────────────────────────────────
#
# THE one answer to "does this line declare a build stage, and which".
# Every reader of a Dockerfile's stage list routes through it: the stage
# parser (compose services), the drift hash projection, the
# `[environment]` ENV bake, the `COPY config/app` bake, and the TUI's
# per-stage override menu. They used to carry three different regexes,
# which disagreed on the standard cross-build form
# (`FROM --platform=$BUILDPLATFORM <image> AS runtime`): the strict ones
# skipped it silently while the loose one spliced into it, so a field
# image shipped with the baked config and none of the baked env. Any
# future change to what counts as a stage line belongs here and nowhere
# else.
#
# Accepted grammar (the whole line, anchored both ends):
#
#   FROM [--flag[=value]]... <image-ref> AS <stage>[ \t]*
#
#   - `FROM` starts the line: no leading whitespace, uppercase, one
#     directive per line. Docker's own parser is case-insensitive; the
#     repo convention is uppercase and a lowercase `from` / `as` is read
#     as a hand-edit typo and ignored rather than silently honoured.
#   - Zero or more leading flag tokens, each starting `--`
#     (`--platform=linux/arm64`, `--link`). Values are attached with `=`;
#     docker has no space-separated flag form, so neither has this.
#   - Exactly ONE image-reference token, which may not start with `-`
#     (that slot is an image, `${VAR}` interpolation included -- never a
#     flag). No stray extra bare token: `FROM img junk AS x` is not a
#     directive docker accepts and is not one here either.
#   - Uppercase `AS`, then exactly one stage-name token.
#   - Trailing whitespace tolerated; a `#` anywhere in any token
#     disqualifies the line, so a commented-out `# FROM ... AS x` never
#     registers as a stage.
#
# Whitespace between tokens is one or more spaces / tabs.
_DOCKERFILE_STAGE_FROM_RE='^FROM([[:space:]]+--[^[:space:]#]+)*[[:space:]]+[^-[:space:]#][^[:space:]#]*[[:space:]]+AS[[:space:]]+([^[:space:]#]+)[[:space:]]*$'

# _dockerfile_stage_from_line <line> [<stage_outvar>]
#
# Returns 0 when <line> declares a build stage per the grammar above,
# and sets <stage_outvar> (when given) to the declared stage name.
# Returns 1 otherwise, leaving <stage_outvar> untouched.
_dockerfile_stage_from_line() {
  local _dsfl_line="${1-}"
  [[ "${_dsfl_line}" =~ ${_DOCKERFILE_STAGE_FROM_RE} ]] || return 1
  if [[ -n "${2-}" ]]; then
    local -n _dsfl_out="${2}"
    _dsfl_out="${BASH_REMATCH[2]}"
  fi
  return 0
}

# _parse_dockerfile_stages <dockerfile_path>
#
# Reads the stage-declaring FROM lines from the Dockerfile (grammar:
# _dockerfile_stage_from_line above), dedups, filters out the baseline
# blocklist {sys, devel-base, devel, runtime-test} (plus the legacy
# {base, test} accepted during the v0.21.x transition), and echoes the
# surviving stages one per line preserving file order. `devel-test` is
# deliberately NOT filtered: it survives the parse and is emitted as the
# `test` service, matching _validate_stage_name's blocklist exactly.
#
# Missing Dockerfile → empty output (silent), exit 0. Caller decides
# whether to treat that as "no extra stages" or an error.
_parse_dockerfile_stages() {
  local _dockerfile="$1"
  [[ -f "${_dockerfile}" ]] || return 0
  # Read the Dockerfile directly (no grep|awk pipe) so an empty match
  # set under `set -o pipefail` does not propagate exit 1 back through
  # process substitution.
  local _line _stage _seen=" "
  while IFS= read -r _line; do
    _dockerfile_stage_from_line "${_line}" _stage || continue
    case "${_stage}" in
      sys|devel-base|devel|runtime-test) continue ;;
      base|test) continue ;;
    esac
    case "${_seen}" in
      *" ${_stage} "*) continue ;;  # already emitted (dedup)
    esac
    _seen+="${_stage} "
    printf '%s\n' "${_stage}"
  done < "${_dockerfile}"
  return 0
}

# _compute_dockerfile_hash <base_path> <outvar>
#
# sha256 of the Dockerfile's stage-list projection (just `FROM ... AS
# <stage>` lines), NOT the whole Dockerfile. Drift detection scope:
# adding/removing a stage changes which compose services exist, so the
# hash must change on those edits — but unrelated `RUN apt-get install`
# changes must not, otherwise every Dockerfile edit triggers a full
# compose regen.
#
# Empty output if Dockerfile is missing (caller decides what to do).
_compute_dockerfile_hash() {
  local _base="${1:?}"
  local -n _cdh_out="${2:?}"
  local _dockerfile="${_base}/Dockerfile"
  if [[ ! -f "${_dockerfile}" ]]; then
    _cdh_out=""
    return 0
  fi
  # Build the stage-list projection inline (no grep|sha256sum pipe) so
  # an empty match set under pipefail does not propagate failure. Same
  # matcher as _parse_dockerfile_stages, so a line that becomes a compose
  # service is exactly a line the hash reacts to.
  local _line _stage_lines=""
  while IFS= read -r _line; do
    _dockerfile_stage_from_line "${_line}" || continue
    _stage_lines+="${_line}"$'\n'
  done < "${_dockerfile}"
  _cdh_out="$(printf '%s' "${_stage_lines}" | sha256sum | cut -d' ' -f1)"
  return 0
}

# ════════════════════════════════════════════════════════════════════
# _generate_runtime_dockerfile <dockerfile> <env_str> <out> <stage>
#
# S3 ofbake the `[environment]` defaults as `ENV` into the
# deployed stage so a bare `docker run <image>` carries sane
# defaults with no env file -- delivery channel 1 (the only one that
# reaches the field). Copies <dockerfile> to <out>, inserting an
# `ENV KEY="VALUE"` block immediately after the `FROM ... AS <stage>`
# line. <env_str> is the newline-separated `KEY=VALUE` [environment]
# list; cross-refs (`${KEY}`) are expanded against earlier siblings, the
# same way the compose `environment:` block does.
#
# <stage> is REQUIRED and is the stage actually being built: `runtime` is
# only the template's example name, and a downstream repo names its
# deployable stage whatever it likes. Hardcoding `runtime` here silently
# dropped every [environment] value for such a repo, while the sibling
# `_bake_config_copy` / `docker build --target` already followed the stage.
#
# Exit codes are distinguishable so a caller can tell a no-op from a
# mistake:
#   0 — <out> written with the ENV block spliced in
#   1 — nothing to do, and that is fine: no Dockerfile, or the repo
#       configured no [environment] values. Silent; the caller keeps
#       building from the plain Dockerfile.
#   2 — the Dockerfile does not declare <stage> at all. That is a deploy
#       asking for a stage that does not exist, so it is NAMED (WARN)
#       rather than skipped: the old silent 1 shipped a field bundle with
#       every [environment] default missing and nothing said about it.
# Nothing is written on 1 / 2. The dev `.env` overlay (S2) and
# `deploy.sh -e` (S6) still override these baked defaults at run time,
# because container env_file / environment beats image `ENV`.
# ════════════════════════════════════════════════════════════════════
_generate_runtime_dockerfile() {
  local _dockerfile="${1:?}"
  local _env_str="${2:-}"
  local _out="${3:?}"
  local _stage="${4:?"${FUNCNAME[0]}: missing stage"}"

  [[ -f "${_dockerfile}" ]] || return 1

  # The shared matcher reports the declared stage name; compare it
  # literally rather than splicing <stage> into a pattern -- a stage name
  # reaches here straight from the conf / CLI, and a literal compare
  # cannot be turned into a regex.
  local _line _found="" _has_stage=0
  while IFS= read -r _line; do
    if _dockerfile_stage_from_line "${_line}" _found \
       && [[ "${_found}" == "${_stage}" ]]; then
      _has_stage=1
      break
    fi
  done < "${_dockerfile}"
  if (( ! _has_stage )); then
    _log_warn setup deploy_stage_absent \
      "display=[setup] deploy: '${_stage}' is not declared by any \`FROM ... AS ${_stage}\` line in ${_dockerfile}; the [environment] defaults cannot be baked into an image stage that does not exist." \
      "stage=${_stage}" "dockerfile=${_dockerfile}"
    return 2
  fi

  # An empty [environment] is ordinary configuration, not a mistake, so
  # it stays a silent no-op -- checked after the stage lookup so a
  # genuinely absent stage is still reported.
  [[ -n "${_env_str}" ]] || return 1

  local -a _env_expanded=()
  _expand_env_cross_refs "${_env_str}" _env_expanded

  local _tmp
  _tmp="$(mktemp "${_out}.XXXXXX")"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    printf '%s\n' "${_line}" >> "${_tmp}"
    if _dockerfile_stage_from_line "${_line}" _found \
       && [[ "${_found}" == "${_stage}" ]]; then
      printf '# >>> [environment] baked defaults (generated by setup.sh, #503) <<<\n' >> "${_tmp}"
      local _kv _k _v
      for _kv in "${_env_expanded[@]}"; do
        [[ -z "${_kv}" || "${_kv}" != *=* ]] && continue
        _k="${_kv%%=*}"
        _v="${_kv#*=}"
        # The value is baked into a double-quoted `ENV K="<v>"` line. A
        # raw `"` would unbalance the quotes (`ENV MSG="say "hi""`) and a
        # `$` would trigger Dockerfile ENV expansion / shell command
        # substitution (`$(id)`) at build time instead of landing
        # literally. Escape backslash first, then `"` and `$`, so the
        # configured value is baked verbatim.
        _v="${_v//\\/\\\\}"
        _v="${_v//\"/\\\"}"
        _v="${_v//\$/\\\$}"
        printf 'ENV %s="%s"\n' "${_k}" "${_v}" >> "${_tmp}"
      done
    fi
  done < "${_dockerfile}"
  mv -- "${_tmp}" "${_out}"
  return 0
}


# ════════════════════════════════════════════════════════════════════
# Per-stage overrides
#
# `[stage:<name>]` sections in <repo>/.setup.conf override top-level
# settings on a per-stage basis. Only the v1 allowlist (gui.mode, the
# whole [deploy] / [network] blocks, security.privileged, [volumes]
# mounts, [environment] env_*) is honored — anything else is WARN'd
# and skipped by the validator.
#
# List fields use append-default + opt-out semantics: stage's `mount_*`
# / `port_*` / `env_*` items are appended to the top-level list unless
# the matching `<list>_inherit = false` flag is set, in which case
# only the stage's own entries survive.
# ════════════════════════════════════════════════════════════════════

# _parse_stage_sections <file> <out_array_var>
#
# Scans <file> for `^\[stage:NAME\]$` headers, returns NAME list in
# file order. Stage names matching `[a-z][a-z0-9_-]*` are collected;
# malformed names are silently skipped here (caller surfaces them
# via _validate_stage_name). Empty / missing file → empty output.
_parse_stage_sections() {
  local _file="${1:?"${FUNCNAME[0]}: missing file"}"
  local -n _pss_out="${2:?"${FUNCNAME[0]}: missing out array"}"
  _pss_out=()
  [[ -f "${_file}" ]] || return 0
  local _line
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" =~ ^\[stage:([a-z][a-z0-9_-]*)\][[:space:]]*$ ]]; then
      _pss_out+=("${BASH_REMATCH[1]}")
    fi
  done < "${_file}"
}

# _load_stage_overrides <base_path> <stage> <keys_outvar> <values_outvar>
#
# Reads the `[stage:<stage>]` section through the conf chain into parallel
# arrays, same section-replace rule as every other section: the highest
# layer that defines `[stage:<stage>]` supplies all of it. In practice the
# template carries no stage overrides (it does not know which Dockerfile
# stages exist downstream), so the contest is between the repo's committed
# override and the per-worktree `.setup.conf.local`. The local layer may
# override ANY section -- a per-stage section is not a special case.
_load_stage_overrides() {
  local _base="${1:?"${FUNCNAME[0]}: missing base_path"}"
  local _stage="${2:?"${FUNCNAME[0]}: missing stage"}"
  local -n _lso_keys="${3:?"${FUNCNAME[0]}: missing keys outvar"}"
  local -n _lso_values="${4:?"${FUNCNAME[0]}: missing values outvar"}"
  _load_setup_conf "${_base}" "stage:${_stage}" _lso_keys _lso_values
}

# _validate_stage_override_key <key>
#
# Returns 0 when <key> is in the v1 per-stage override allowlist,
# 1 otherwise. Allowlist scope:
#
#   [deploy]      gpu_mode, gpu_count, gpu_capabilities, runtime
#   [gui]         mode
#   [network]     mode, ipc, pid, network_name, port_<N>, port_inherit
#   [security]    privileged, cap_add_<N>, cap_add_inherit,
#                 cap_drop_<N>, cap_drop_inherit,
#                 security_opt_<N>, security_opt_inherit
#   [volumes]     mount_<N>, mount_inherit
#   [environment] env_<N>, env_inherit
#
# security cap_add / cap_drop / security_opt: added in v2 once a
# real downstream need surfaced (jetson_sdk_manager#69 — per-stage caps so
# a read-only probe stage drops the flash stage's SYS_ADMIN). Same
# append-by-default / *_inherit=false-replaces list convention as
# volumes / env / ports.
#
# Excluded by design:
#   [image_name] / [build] / [devices] / [tmpfs] /
#   [additional_contexts] / [resources] — outside the "Isaac Sim
#   per-stage runtime" use case driving them. Re-evaluate once a real
#   downstream need surfaces.
_validate_stage_override_key() {
  local _key="${1:?"${FUNCNAME[0]}: missing key"}"
  case "${_key}" in
    deploy.gpu_mode|deploy.gpu_count|deploy.gpu_capabilities|deploy.gpu_runtime|deploy.runtime) return 0 ;;
    gui.mode) return 0 ;;
    network.mode|network.ipc|network.pid|network.network_name) return 0 ;;
    security.privileged) return 0 ;;
    network.port_inherit|volumes.mount_inherit|environment.env_inherit) return 0 ;;
    security.cap_add_inherit|security.cap_drop_inherit|security.security_opt_inherit) return 0 ;;
  esac
  if [[ "${_key}" =~ ^(network\.port|volumes\.mount|environment\.env|security\.cap_add|security\.cap_drop|security\.security_opt)_[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

# _resolve_stage_scalar <keys_var> <values_var> <key> <fallback> <out_var>
#
# Look up <key> in the stage's parallel arrays. If found, set <out_var>
# to that value; otherwise set <out_var> to <fallback>. Used for
# per-stage scalar overrides (gui.mode, network.mode, etc.) where there
# is no merge — the stage value either replaces the top-level or
# falls through entirely.
_resolve_stage_scalar() {
  local -n _rss_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rss_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _key="${3:?"${FUNCNAME[0]}: missing key"}"
  local _fallback="${4-}"
  local -n _rss_out="${5:?"${FUNCNAME[0]}: missing out var"}"
  local i
  for (( i = 0; i < ${#_rss_keys[@]}; i++ )); do
    if [[ "${_rss_keys[i]}" == "${_key}" ]]; then
      _rss_out="${_rss_values[i]}"
      return 0
    fi
  done
  _rss_out="${_fallback}"
}

# _resolve_stage_list <keys_var> <values_var> <prefix> <inherit_key> \
#                     <top_level_str> <out_var>
#
# Computes the effective list for a list field (volumes.mount_*,
# network.port_*, environment.env_*) on a per-stage basis.
#
# Args:
#   keys_var / values_var  Stage's parallel override arrays
#   prefix                 Full dotted prefix e.g. "volumes.mount_"
#                          — keys matching `<prefix>[0-9]+` are list items
#   inherit_key            Meta-key e.g. "volumes.mount_inherit"
#                          — value "false" switches to replace mode
#   top_level_str          Newline-separated top-level list (the same
#                          aggregate format setup.sh uses elsewhere)
#   out_var                Newline-separated effective list (no
#                          trailing newline)
#
# Default (inherit unspecified or anything ≠ "false"): top-level entries
# come first, stage entries appended afterward in setup.conf order.
# Replace mode (inherit=false): only stage entries appear; top-level
# is dropped. The opt-out lets a stage opt out of inherited mounts
# entirely (e.g. headless that wants no host-side ssh keys, regardless
# of the top-level mount_2 setting).
_resolve_stage_list() {
  local -n _rsl_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rsl_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local _prefix="${3:?"${FUNCNAME[0]}: missing prefix"}"
  local _inherit_key="${4:?"${FUNCNAME[0]}: missing inherit_key"}"
  local _top="${5-}"
  local -n _rsl_out="${6:?"${FUNCNAME[0]}: missing out var"}"

  # Default to inheriting top-level. Only the literal "false" toggles
  # replace mode — anything else (including "true", empty, malformed)
  # keeps the safe append-default behavior.
  local _inherit="true" i
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    if [[ "${_rsl_keys[i]}" == "${_inherit_key}" ]]; then
      [[ "${_rsl_values[i]}" == "false" ]] && _inherit="false"
      break
    fi
  done

  # Collect stage's own list entries in setup.conf order. Match only
  # `<prefix><digits>` so meta-keys like `mount_inherit` (which share
  # the prefix) are not pulled in.
  local -a _stage_entries=()
  local _suffix
  for (( i = 0; i < ${#_rsl_keys[@]}; i++ )); do
    [[ "${_rsl_keys[i]}" == "${_prefix}"* ]] || continue
    _suffix="${_rsl_keys[i]#"${_prefix}"}"
    [[ "${_suffix}" =~ ^[0-9]+$ ]] || continue
    _stage_entries+=("${_rsl_values[i]}")
  done

  if [[ "${_inherit}" == "true" ]]; then
    if [[ -n "${_top}" ]] && (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="${_top}"$'\n'"$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    elif [[ -n "${_top}" ]]; then
      _rsl_out="${_top}"
    elif (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  else
    if (( ${#_stage_entries[@]} > 0 )); then
      _rsl_out="$(printf '%s\n' "${_stage_entries[@]}")"
      _rsl_out="${_rsl_out%$'\n'}"
    else
      _rsl_out=""
    fi
  fi
}

# _resolve_docker_flags <stage_keys> <stage_values> <parent_assoc> <out_assoc>
#
# THE single per-stage docker-flag resolution layer. Given one
# stage's [stage:<name>] overrides (already filtered to the allowlist)
# layered over the parent (devel / top-level) already-resolved values,
# it computes the stage's effective docker flags into <out_assoc>.
#
# Both renderers call this so per-stage semantics never drift:
#   - the compose renderer (generate_compose_yaml's per-stage loop), and
#   - the deploy renderer (S6), which resolves the runtime stage's
#     flags to emit a field docker-run launcher.
#
# Modes (gui / gpu) inherit the parent's already-resolved boolean unless
# the stage forces off / force — per-stage does NOT re-detect hardware
# (that host-specific detection is the global resolution's job, upstream
# of this layer). Other scalars fall back to the parent's effective
# value; list fields (volumes / environment / ports) delegate to
# _resolve_stage_list (append-by-default, replace on `*_inherit = false`).
#
# Args:
#   $1 stage_keys    (array ref)  filtered [stage:*] override keys
#   $2 stage_values  (array ref)  parallel override values
#   $3 parent        (assoc ref)  parent fallbacks + top-level lists:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name volumes_top env_top ports_top
#        cap_add_top cap_drop_top sec_opt_top
#   $4 out           (assoc ref)  effective record, keys:
#        gui gpu gpu_count gpu_caps runtime net_mode ipc_mode pid_mode
#        net_name privileged volumes environment ports
#        cap_add cap_drop security_opt
_resolve_docker_flags() {
  local -n _rdf_keys="${1:?"${FUNCNAME[0]}: missing keys array"}"
  local -n _rdf_values="${2:?"${FUNCNAME[0]}: missing values array"}"
  local -n _rdf_parent="${3:?"${FUNCNAME[0]}: missing parent assoc"}"
  local -n _rdf_out="${4:?"${FUNCNAME[0]}: missing out assoc"}"
  local _mode _tmp

  # gui / gpu: off|force decide outright; anything else (incl. absent or
  # "auto") inherits the parent's already-resolved boolean. Assoc-array
  # subscripts are quoted as string literals so ShellCheck does not read
  # them as arithmetic variable references (SC2154) -- _rdf_out is a
  # nameref, so ShellCheck cannot infer it is associative.
  _resolve_stage_scalar _rdf_keys _rdf_values "gui.mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gui"]="false" ;;
    force) _rdf_out["gui"]="true" ;;
    *)     _rdf_out["gui"]="${_rdf_parent["gui"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_mode" "" _mode
  case "${_mode}" in
    off)   _rdf_out["gpu"]="false" ;;
    force) _rdf_out["gpu"]="true" ;;
    *)     _rdf_out["gpu"]="${_rdf_parent["gpu"]}" ;;
  esac

  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_count" "${_rdf_parent["gpu_count"]}" _tmp
  _rdf_out["gpu_count"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_capabilities" "${_rdf_parent["gpu_caps"]}" _tmp
  _rdf_out["gpu_caps"]="${_tmp}"

  # gpu_runtime is canonical; the legacy deploy.runtime alias is consulted
  # only when this stage sets no gpu_runtime. Same precedence AND same
  # deprecation warning as _resolve_deploy_context uses for the global
  # [deploy] section -- the two layers must not disagree, or a stage
  # migrated to gpu_runtime keeps emitting the value of the line the
  # migration was supposed to retire.
  local _legacy_runtime=""
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.gpu_runtime" "" _tmp
  _resolve_stage_scalar _rdf_keys _rdf_values "deploy.runtime" "" _legacy_runtime
  if [[ -n "${_legacy_runtime}" ]]; then
    _log_warn setup conf_runtime_key_deprecated \
      "display=$(_setup_msg deploy runtime_deprecated)"
  fi
  if [[ -z "${_tmp}" ]]; then
    _tmp="${_legacy_runtime:-${_rdf_parent["runtime"]}}"
  fi
  _rdf_out["runtime"]="${_tmp}"

  _resolve_stage_scalar _rdf_keys _rdf_values "network.mode" "${_rdf_parent["net_mode"]}" _tmp
  _rdf_out["net_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.ipc" "${_rdf_parent["ipc_mode"]}" _tmp
  _rdf_out["ipc_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.pid" "${_rdf_parent["pid_mode"]}" _tmp
  _rdf_out["pid_mode"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "network.network_name" "${_rdf_parent["net_name"]}" _tmp
  _rdf_out["net_name"]="${_tmp}"
  _resolve_stage_scalar _rdf_keys _rdf_values "security.privileged" "" _tmp
  _rdf_out["privileged"]="${_tmp}"

  _resolve_stage_list _rdf_keys _rdf_values "volumes.mount_" "volumes.mount_inherit" "${_rdf_parent["volumes_top"]}" _tmp
  _rdf_out["volumes"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "environment.env_" "environment.env_inherit" "${_rdf_parent["env_top"]}" _tmp
  _rdf_out["environment"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "network.port_" "network.port_inherit" "${_rdf_parent["ports_top"]}" _tmp
  _rdf_out["ports"]="${_tmp}"

  # per-stage [security] cap_add / cap_drop / security_opt as list
  # fields, same append-by-default / *_inherit=false-replaces convention as
  # volumes / env / ports above. A stage sets `cap_add_inherit = false`
  # (and lists no entries) to drop all inherited caps — e.g. a read-only
  # probe stage that should not inherit the flash stage's SYS_ADMIN.
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_add_" "security.cap_add_inherit" "${_rdf_parent["cap_add_top"]}" _tmp
  _rdf_out["cap_add"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.cap_drop_" "security.cap_drop_inherit" "${_rdf_parent["cap_drop_top"]}" _tmp
  _rdf_out["cap_drop"]="${_tmp}"
  _resolve_stage_list _rdf_keys _rdf_values "security.security_opt_" "security.security_opt_inherit" "${_rdf_parent["sec_opt_top"]}" _tmp
  _rdf_out["security_opt"]="${_tmp}"
}
