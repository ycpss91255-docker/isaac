#!/usr/bin/env bash
# drivers/home_literal.sh - "no hardcoded home path in the shipped image
# tree" per-tool driver for the self-test dispatcher.
#
# Sourced library (no main): test.sh sources this near the top, after
# _lib.sh, so the _log_* / _die helpers are available. Provides
# _run_home_literal, the mechanical half of the "bake self-built artifacts
# at /opt, not under $HOME" convention (ADR-00000024).
#
# Contract: runs INSIDE the ci (test-tools) container where test.sh
# invokes it. References ${REPO_ROOT} (a global exported by test.sh).
# Follows drivers/stale_setup_conf.sh / drivers/readme_sync.sh conventions
# (sourced lib, uses ${REPO_ROOT}, _log_* / _die, no main).
#
# Why: the container user is baked at BUILD time. The sys stage takes the
# USER_NAME / USER_UID / USER_GID build args, creates the user, and sets
# ENV HOME to that user's home directory, so everything an image bakes
# under $HOME is coupled to the build-time username -- `just build` injects
# the local host's user, while CI/release bakes `user` (UID 1000). A
# prebuilt / GHCR / `docker save`+`load` image run or rebuilt under a
# different USER_NAME then points at a different, EMPTY home tree: the baked
# workspace disappears and the entrypoint's `source` breaks. The
# parameterised ${HOME} / ${USER_NAME} forms track the build arg and
# survive that; an absolute /opt path removes the indirection entirely.
#
# What this lint can and cannot check: whether a given artifact BELONGS
# under /opt is a judgement call, not a mechanical property, and this driver
# does not pretend to decide it -- that half of the convention is carried by
# the shipped Dockerfile's commentary, the README and the ADR. What IS
# mechanical is the concrete-username literal, which is always wrong in a
# shipped file, and that is exactly what this scans for.
#
# Scope: the trees that reach an image -- dist/ (the shipped runtime tree:
# the template Dockerfile, the runtime helpers, the COPY'd config/ tree and
# the wrapper/lib code) plus the repo-root dockerfile/ tree (the test-tools
# image). Docs, specs and the CHANGELOG legitimately spell concrete home
# paths (fixtures, failure-mode narratives) and are deliberately NOT
# scanned.
#
# Accepted forms (no violation), all of which track the build arg or name no
# user at all:
#   ${USER_NAME} / $HOME / ${HOME}       parameterised
#   \${USER_NAME}                        escaped, i.e. code that EMITS the
#                                        parameterised form into setup.conf
#   <name>                               an angle-bracket placeholder in prose
#   /opt/<anything>                      not a home path at all
#
# Allowlist: an explicit, region-delimited opt-out rather than a per-file
# exclusion, so a NEW literal elsewhere in an allowlisted file is still
# caught. Bracket the legitimate lines with
#   # home-literal-lint: allow-begin -- <why>
#   ...
#   # home-literal-lint: allow-end
# The one live region is the migration note in lib/dockerfile_migrate.sh,
# which must name the default `useradd` home directory in order to explain
# the mismatch that migration heals. Unbalanced markers (an unterminated
# begin, an unmatched end) fail the lint -- a silently swallowed region
# would re-open exactly the hole this guard closes.

# ── Hardcoded home path lint ─────────────────────────────────────────────────

# The scanned trees, repo-root-relative. Each must exist: a missing root
# would make the scan pass vacuously.
readonly _HOME_LITERAL_SCAN_ROOTS=('dist' 'dockerfile')

# A home path whose first segment starts with a real path character, i.e. a
# CONCRETE username. The parameterised forms start with '$' (or '\$' when
# escaped) and the prose placeholder with '<', so none of them match. The
# leading directory is assembled from a variable for the same reason
# stale_setup_conf.sh splits its literal: this driver's own source then
# carries no concrete home path as a plain token.
readonly _HOME_LITERAL_DIR='/home'
readonly _HOME_LITERAL_RE="${_HOME_LITERAL_DIR}/[A-Za-z0-9_.-]+"

# Region markers for the explicit opt-out (see the header note).
readonly _HOME_LITERAL_ALLOW_BEGIN='home-literal-lint: allow-begin'
readonly _HOME_LITERAL_ALLOW_END='home-literal-lint: allow-end'

_run_home_literal() {
  echo "--- Running hardcoded home path lint ---"
  local _violations=0
  local _root _abs_root _file _rel _line _lineno _in_allow _begin_line _hit

  local -a _files=()
  for _root in "${_HOME_LITERAL_SCAN_ROOTS[@]}"; do
    _abs_root="${REPO_ROOT}/${_root}"
    if [[ ! -d "${_abs_root}" ]]; then
      _die ci_home_literal \
        "scan root '${_root}/' not found under ${REPO_ROOT} -- the lint would pass vacuously. Point it at the trees that reach an image."
      return 1
    fi
    while IFS= read -r -d '' _file; do
      _files+=("${_file}")
    done < <(find "${_abs_root}" -type f -print0 2>/dev/null | sort -z)
  done

  for _file in "${_files[@]}"; do
    _rel="${_file#"${REPO_ROOT}"/}"
    _in_allow=0
    _begin_line=0
    _lineno=0
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      _lineno=$(( _lineno + 1 ))

      if [[ "${_line}" == *"${_HOME_LITERAL_ALLOW_BEGIN}"* ]]; then
        _in_allow=1
        _begin_line="${_lineno}"
        continue
      fi
      if [[ "${_line}" == *"${_HOME_LITERAL_ALLOW_END}"* ]]; then
        if [[ "${_in_allow}" -eq 0 ]]; then
          printf '%s:%d: unmatched allow-end (no open allow-begin)\n' \
            "${_rel}" "${_lineno}"
          _violations=$(( _violations + 1 ))
        fi
        _in_allow=0
        continue
      fi

      [[ "${_in_allow}" -eq 1 ]] && continue

      if [[ "${_line}" =~ ${_HOME_LITERAL_RE} ]]; then
        _hit="${BASH_REMATCH[0]}"
        printf '%s:%d: %s -- %s\n' \
          "${_rel}" "${_lineno}" "${_hit}" "${_line}"
        _violations=$(( _violations + 1 ))
      fi
    done < "${_file}"

    if [[ "${_in_allow}" -eq 1 ]]; then
      printf '%s:%d: unterminated allow-begin (no closing allow-end)\n' \
        "${_rel}" "${_begin_line}"
      _violations=$(( _violations + 1 ))
    fi
  done

  if [[ "${_violations}" -gt 0 ]]; then
    # _die exits in the dispatcher; the explicit return keeps the
    # not-reached "clean" echo unreachable even where a caller stubs _die
    # to return instead of exit (e.g. the unit harness).
    _die ci_home_literal \
      "${_violations} hardcoded home path(s) / unbalanced allow marker(s) in the shipped image tree (${_HOME_LITERAL_SCAN_ROOTS[*]}). The container user is a BUILD arg, so a concrete username breaks under a different USER_NAME (rebuild, GHCR pull, docker save+load). Bake self-built artifacts at an absolute /opt/<name> and source THAT path; use \${HOME} / \${USER_NAME} where a home path is genuinely needed (ADR-00000024). A narrative mention opts out by bracketing it with '# ${_HOME_LITERAL_ALLOW_BEGIN} -- <why>' / '# ${_HOME_LITERAL_ALLOW_END}'."
    return 1
  fi
  echo "hardcoded home path lint: clean"
}
