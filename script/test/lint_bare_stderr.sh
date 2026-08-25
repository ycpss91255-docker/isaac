#!/usr/bin/env bash
#
# lint_bare_stderr.sh - Flag bare printf/echo >&2 outside _log_* helpers.
#
# Enforce that all stderr output goes through lib/log.sh
# helpers. Scans dist/script/docker/**/*.sh and script/test/**/*.sh
# for lines that write to fd 2 without using _log_err / _log_warn /
# _log_fatal / _log_info / _log_debug / _die.
#
# Exit: 0 = clean, 1 = violations found, 2 = usage error.

set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"

# Files excluded entirely (log.sh itself, i18n, entrypoint, TUI).
_is_excluded_file() {
  case "${1}" in
    dist/script/docker/lib/log.sh) return 0 ;;
    dist/script/docker/lib/i18n.sh) return 0 ;;
    dist/script/docker/runtime/logging.sh) return 0 ;;
    # In-container watchdog helper: runs in the runtime image with no
    # lib/log.sh sourced, so its loud stderr events go straight to fd 2
    # (captured by `docker logs`) -- same rationale as logging.sh.
    dist/script/docker/runtime/watchdog.sh) return 0 ;;
    dist/script/docker/runtime/smoke.sh) return 0 ;;
    dist/script/docker/lib/_tui_backend.sh) return 0 ;;
    dist/script/docker/lib/_tui_conf.sh) return 0 ;;
    dist/script/docker/wrapper/setup_tui.sh) return 0 ;;
    # Deliberately standalone, log.sh-free CI tool: the coverage-floor
    # gate runs as a bare `bash coverage_gate.sh ...` under both GitHub
    # Actions and (after the move) GitLab CI, so it must NOT depend on
    # lib/log.sh being sourced. Its diagnostics go straight to stderr --
    # the same rationale class as the pre-sourcing bootstrap allowlist.
    script/test/drivers/coverage_gate.sh) return 0 ;;
  esac
  return 1
}

_is_allowlisted_line() {
  local line="${1}"

  # Already using _log_* or _die.
  [[ "${line}" == *_log_* ]] && return 0
  [[ "${line}" == *_die* ]] && return 0

  # Comment line.
  [[ "${line}" =~ ^[[:space:]]*# ]] && return 0

  # getopts / OPTARG.
  [[ "${line}" == *OPTARG* ]] && return 0
  [[ "${line}" == *getopts* ]] && return 0

  # GITHUB_OUTPUT / GITHUB_STEP_SUMMARY.
  [[ "${line}" == *GITHUB_OUTPUT* ]] && return 0
  [[ "${line}" == *GITHUB_STEP_SUMMARY* ]] && return 0

  # Interactive prompts and confirmation context.
  [[ "${line}" == *'[y/N]'* ]] && return 0
  [[ "${line}" == *'[y/n]'* ]] && return 0
  [[ "${line}" == *'[Y/n]'* ]] && return 0
  [[ "${line}" == *'will overwrite'* ]] && return 0
  [[ "${line}" == *'backup'* ]] && return 0
  [[ "${line}" == *'aborted'* ]] && return 0
  [[ "${line}" == *'_msg info volume_prompt'* ]] && return 0

  # Pre-sourcing bootstrap errors (cannot find _lib.sh / bootstrap.sh):
  # these fire before lib/log.sh is sourced, so _log_* is not yet available.
  [[ "${line}" == *'cannot find _lib.sh'* ]] && return 0
  [[ "${line}" == *'cannot find lib/bootstrap.sh'* ]] && return 0
  [[ "${line}" == *'.base/dist/script/docker/lib/_lib.sh'* ]] && return 0
  [[ "${line}" == *'/_lib.sh'* ]] && return 0

  # Pre-sourcing -C/--chdir errors (before _lib.sh is loaded).
  [[ "${line}" == *'-C/--chdir'* ]] && return 0
  [[ "${line}" == *'-C target is not'* ]] && return 0

  # Array/list output (printf '  %s\n' "${array[@]}").
  [[ "${line}" =~ printf[[:space:]]+.+\$\{ ]] && [[ "${line}" == *'[@]}'* ]] && return 0
  [[ "${line}" =~ printf[[:space:]]+\'\ \ %s ]] && return 0

  # sed-piped output (structured list formatting).
  [[ "${line}" == *"| sed"* ]] && return 0

  return 1
}

violations=0

while IFS= read -r file; do
  rel="${file#"${repo_root}"/}"
  _is_excluded_file "${rel}" && continue

  in_usage=0
  lineno=0
  while IFS= read -r line; do
    lineno=$((lineno + 1))

    if [[ "${line}" =~ ^[[:space:]]*(usage|_usage)\(\) ]]; then
      in_usage=1
      continue
    fi
    if [[ "${in_usage}" -eq 1 ]] && [[ "${line}" =~ ^[[:space:]]*\} ]]; then
      in_usage=0
      continue
    fi
    [[ "${in_usage}" -eq 1 ]] && continue

    _is_allowlisted_line "${line}" && continue

    if [[ "${line}" =~ (printf|echo)[[:space:]].*\>\&2 ]] || \
       [[ "${line}" =~ \>\&2[[:space:]]*(printf|echo) ]]; then
      printf '%s:%d: %s\n' "${rel}" "${lineno}" "${line}"
      violations=$((violations + 1))
    fi
  done < "${file}"
done < <(find "${repo_root}/dist/script/docker" "${repo_root}/script/test" \
  -name '*.sh' -type f 2>/dev/null | sort)

if [[ "${violations}" -gt 0 ]]; then
  printf '\n%d bare stderr output(s) found. Use _log_err/_log_warn/_log_fatal instead.\n' "${violations}" >&2
  exit 1
fi

exit 0
