#!/usr/bin/env bash
#
# wrapper.sh - cohesive runtime for the 5 docker wrappers.
#
# The five container-op wrappers (build / run / exec / stop / prune) used
# to repeat ~250 lines of preamble: the bootstrap-locator guard, the
# `--lang` pre-pass, the `_msg` dispatcher, and (for build / run) the
# setup/drift orchestration. This module hoists those cross-cutting
# surfaces so each wrapper shrinks to its verb-specific behaviour.
#
# Sourced (not executed). bootstrap.sh sources this file from the same
# lib/ directory after _lib.sh is loaded, so every wrapper that calls
# `_bootstrap "$@"` gets the runtime for free. The wrapper still owns its
# own file (preserving the `just <verb>` -> `./script/<verb>.sh` symlink
# contract that init.sh maintains) and declares which phases it needs.
#
# lib defensive-unset convention: this module is sourced from 5 distinct
# callers, each with a different subset of caller-locals in scope. Every
# reference to a caller-owned variable uses `${VAR:-}` / a guard so an
# unset name never trips `set -u`.
#
# ADR-00000011: this runtime is the intended home for the shared CLI lib
# (--help / --lang) the test / release / base / template scripts will
# adopt later. For it is scoped to the 5 docker
# wrappers only; the helpers are written to be reusable but nothing
# outside the docker wrappers is pulled in here yet.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_WRAPPER_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_WRAPPER_SOURCED=1

# ── _msg dispatcher ───────────────────────────────────────────────────
#
# Every wrapper that emits i18n strings declares its own per-category
# tables `_msg_<category>` (e.g. `_msg_bootstrap`, `_msg_errors`).
# This dispatcher keeps a single `_msg <category> <key>` call-site shape
# across all wrappers; it was byte-identical in all 5 before
#
# Resolves to `_msg_<category> <key>`; the table function reads the
# global _LANG. A wrapper that defines no message tables (e.g. a future
# table-less verb) simply never calls _msg.
_msg() {
  local _category="${1:?_msg requires category}"
  local _key="${2:?_msg requires key}"
  "_msg_${_category}" "${_key}"
}

# ── --lang pre-pass ───────────────────────────────────────────────────
#
# _wrapper_lang_prepass <verb> "$@"
#
# Scans the wrapper's argv for `--lang <value>` and seeds the global
# _LANG before the main parse loop runs, so usage (which exits via
# -h/--help) renders in the requested locale even when --help precedes
# --lang on the command line. The canonical main parse loop still
# handles --lang itself (validation, error-on-missing-value) on the
# normal path; this pre-pass only front-loads the locale for the early
# usage exit.
#
# bootstrap.sh already ran `_resolve_lang _LANG` (SETUP_LANG / $LANG
# detection) so _LANG holds a valid default before this is called; a
# --lang here overrides it and is re-validated via _sanitize_lang.
#
# _LANG is mutated as a global (no `local` declared for it here). The
# leading <verb> is the script name forwarded to _sanitize_lang for its
# `[<verb>] WARNING:` prefix on an unsupported value.
_wrapper_lang_prepass() {
  local _verb="${1:?_wrapper_lang_prepass requires verb}"
  shift
  local _i
  for (( _i=1; _i<=$#; _i++ )); do
    if [[ "${!_i}" == "--lang" ]]; then
      local _next=$((_i+1))
      _LANG="${!_next:-}"
      _sanitize_lang _LANG "${_verb}"
      break
    fi
  done
}

# ── container-running probe (run + exec) ──────────────────────────────
#
# _wrapper_container_running <name>
#
# Exit 0 iff a container named EXACTLY <name> is currently running.
#
# run.sh asks this to refuse starting on top of a live container; exec.sh
# asks the negation to refuse exec'ing into a dead one. Both spelled it
# `docker ps --format '{{.Names}}' | grep -qx "${name}"`, and that spelling
# hands the answer to a reader that stops reading: `grep -q` leaves the
# instant it matches, a `docker ps` still writing then takes SIGPIPE and
# exits 141, and the file-scope `pipefail` of both wrappers makes 141 the
# PIPELINE's status. An `if` reads 141 as false, so a SUCCESSFUL match is
# reported as "no such container". The status is not lost -- it is
# INVERTED, and neither caller fails loudly: run.sh silently starts a
# second container over the live one, exec.sh silently refuses a running
# one. `docker ps` on a busy host is exactly the writer that has not
# finished, and this ships to every downstream repo, on whatever host they
# have.
#
# There is no reader to leave early here. The loop drains the whole stream
# and compares in-shell, so no exit status depends on how two processes
# were scheduled. Process substitution rather than a pipe, so the loop body
# runs in THIS shell; `docker`'s own stderr is left alone so a genuinely
# broken daemon still says so on the terminal (an empty stream then reads
# as "not running", which is what the pipeline reported too).
_wrapper_container_running() {
  local _name="${1:?_wrapper_container_running requires a container name}"
  local _line
  local _found=1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "${_line}" == "${_name}" ]]; then
      _found=0
    fi
  done < <(docker ps --format '{{.Names}}')
  return "${_found}"
}

# ── setup / drift orchestration (build + run) ─────────────────────────
#
# _wrapper_setup_sync <verb>
#
# The shared bootstrap / drift lifecycle that build.sh and run.sh both
# need before they touch docker: decide whether to (re)run setup.sh,
# regenerate .env.generated + compose.yaml on drift, and fail loudly if
# setup left no .env behind. exec / stop / prune do NOT call this -- they
# expect the derived artifacts to already exist (a real repo has them
# after its first build), so the orchestration stays opt-in per verb.
#
# Reads (all caller-owned, guarded for `set -u`):
#   FILE_PATH            repo root (readonly, set by _bootstrap)
#   _LANG                resolved locale
#   RUN_SETUP            "true" forces an interactive (TUI/setup.sh) run
#   SETUP_FORWARD_ARGS   array; per-invocation overrides forwarded
#                        into setup.sh apply (short-circuits the TUI)
#
# Phase decision (unchanged from the build/run inline blocks):
#   - RUN_SETUP=true                          -> interactive run
#   - missing .env / setup.conf / compose.yaml -> non-interactive bootstrap
#   - otherwise                                -> drift-check, regen on drift
#
# Bootstrap MUST stay non-interactive: compose.yaml is gitignored since
# v0.9.0, so every fresh clone hits the bootstrap path. Dispatching it
# through the TUI would leave a cancelled (Esc / Ctrl-C) session with no
# .env, and the next step would die inside _load_env on a missing file.
#
# Drift regen runs setup.sh as a SUBPROCESS (not `source`) so setup.sh's
# internal helpers never leak into the wrapper's namespace -- this closes
# the class where sourcing setup.sh shadowed the wrapper's _msg
# and silently blanked out the drift_regen / no_env status lines.
#
# On a missing .env after setup, emits the no_env / rerun_setup error
# pair and exits 1.
_wrapper_setup_sync() {
  local _verb="${1:?_wrapper_setup_sync requires verb}"
  local _file_path="${FILE_PATH:?_wrapper_setup_sync requires FILE_PATH}"
  local _lang="${_LANG:-en}"

  # Self-managed compose (base self-use): base is the template SOURCE
  # -- it has no `.base/` subtree and ships a hand-authored compose.yaml, so
  # there is no setup.conf to generate from and regenerating would clobber
  # it. Skip the whole setup-sync lifecycle. This is the general
  # "no .base/ subtree + no setup.conf -> the repo manages its own compose"
  # rule (ADR-00000011 sec.4), not a base special-case; consumers always
  # carry a `.base/` subtree so this never fires for them.
  if [[ ! -d "${_file_path}/.base" \
        && ! -f "${_file_path}/.setup.conf" ]]; then
    return 0
  fi

  local _setup="${_file_path}/.base/dist/script/docker/wrapper/setup.sh"
  local _tui="${_file_path}/setup_tui.sh"

  # per-invocation overrides. Defensive copy so an unset
  # SETUP_FORWARD_ARGS (a future caller that skips the override surface)
  # degrades to an empty array under `set -u` instead of aborting.
  local -a _forward_args=()
  if [[ -n "${SETUP_FORWARD_ARGS+x}" ]]; then
    _forward_args=("${SETUP_FORWARD_ARGS[@]}")
  fi

  # _run_interactive: prefer setup_tui.sh on an interactive TTY when the
  # symlink is executable; otherwise non-interactive setup.sh.
  # per-invocation overrides (--gui / --no-x11-cookie) accumulate in
  # SETUP_FORWARD_ARGS and short-circuit through setup.sh apply -- the
  # TUI Save would persist them to setup.conf, the wrong semantics for a
  # debug knob.
  _run_interactive() {
    if (( "${#_forward_args[@]}" > 0 )); then
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}" \
        "${_forward_args[@]}"
    elif [[ -t 0 && -t 1 && -x "${_tui}" ]]; then
      "${_tui}" --lang "${_lang}"
    else
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
    fi
  }

  if [[ "${RUN_SETUP:-false}" == true ]]; then
    _run_interactive
  elif [[ ! -f "${_file_path}/.env.generated" ]] \
      || [[ ! -f "${_file_path}/.setup.conf" ]] \
      || [[ ! -f "${_file_path}/compose.yaml" ]]; then
    _log_info "${_verb}" "${_verb}_bootstrap" "display=$(_msg bootstrap info)"
    "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
  else
    # Drift-check path. Derived artifacts (.env.generated + compose.yaml)
    # carry no user-owned data, so regenerating on drift is always safe and
    # saves the user from remembering `--setup`. Subprocess invocation
    # avoids the _msg shadow class.
    if ! "${_setup}" check-drift --base-path "${_file_path}" --lang "${_lang}"; then
      _log_info "${_verb}" "${_verb}_drift_regen" "display=$(_msg drift regen)"
      "${_setup}" apply --base-path "${_file_path}" --lang "${_lang}"
    fi
  fi

  # Defensive: setup above must leave .env in place. If it did not (user
  # cancelled an interactive TUI, setup.sh crashed, ...), surface a
  # useful error instead of letting _load_env fail on a missing file.
  if [[ ! -f "${_file_path}/.env.generated" ]]; then
    _log_err  "${_verb}" "${_verb}_no_env" "display=$(_msg errors no_env)"
    _log_info "${_verb}" "${_verb}_rerun_setup" "display=$(_msg errors rerun_setup)"
    exit 1
  fi
}
