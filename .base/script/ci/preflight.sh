#!/usr/bin/env bash
# preflight.sh - caller-contract validator for the reusable workers.
#
# The reusable build / release workers must self-validate the caller
# contract before doing any real work, and never fail silently. This
# script is that validator: given a declared requirement manifest (the
# explicit, self-describing list of what a caller must provide) it checks
# each entry against an environment variable the worker populates from the
# real inputs / permission probes, and on any missing item exits non-zero
# with a plain-language message telling the caller exactly what to add to
# their main.yaml.
#
# Keeping the logic here (host-testable under `just test`) keeps the GHA
# wiring in build-worker.yaml / release-worker.yaml thin: the workflow only
# exports the env vars the manifest names and calls this script.
#
# Usage:
#   preflight.sh <manifest>          # validate; exit 1 with guidance on gaps
#   preflight.sh --list <manifest>   # print the requirement list, exit 0
#
# Manifest format (one requirement per line; `#` comments + blank lines
# ignored). Adding a future requirement is a single new line:
#   <kind>|<key>|<envvar>|<description>|<hint>
#     kind        input       -> <envvar> must be non-empty
#                 permission  -> <envvar> must equal "granted"
#     key         short requirement name (e.g. image_name, packages)
#     envvar      environment variable the worker exports the real value to
#     description one-line human description of what the requirement is
#     hint        plain-language fix; `\n` is expanded to a newline so a
#                 hint can show a multi-line main.yaml snippet

set -euo pipefail

_check() {
  # Return 0 when the requirement identified by <kind>/<envvar> is
  # satisfied by the current environment, non-zero otherwise. Fail closed
  # on an unrecognised kind so a malformed manifest can never validate
  # green -- _validate rejects unknown kinds up front (with a loud
  # message); this default is the defence-in-depth backstop.
  local kind="$1" envvar="$2"
  case "${kind}" in
    input) [[ -n "${!envvar:-}" ]] ;;
    permission) [[ "${!envvar:-}" == "granted" ]] ;;
    *) return 1 ;;
  esac
}

_cond_applies() {
  # Return 0 when the guard expression `<condvar>=<value>` matches the
  # current environment (env `<condvar>` equals `<value>`), non-zero
  # otherwise. Used to make a requirement conditional -- e.g. only require
  # `packages: write` when the caller selected `cache_backend: registry`.
  local cond="$1" condvar condval
  condvar="${cond%%=*}"
  condval="${cond#*=}"
  [[ "${!condvar:-}" == "${condval}" ]]
}

_reason() {
  # One-line explanation of why <kind>/<envvar> is unsatisfied, so the
  # failure message states the observed problem, not just the fix.
  local kind="$1" envvar="$2"
  case "${kind}" in
    input) printf 'required input is missing or empty (env %s)' "${envvar}" ;;
    permission)
      printf 'permission not granted (probe env %s=%s)' \
        "${envvar}" "${!envvar:-<unset>}" ;;
    *) printf 'unsatisfied' ;;
  esac
}

_read_manifest() {
  # Emit the manifest with comments / blank lines stripped, so both the
  # validate and list paths iterate the same cleaned view.
  local manifest="$1" line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    printf '%s\n' "${line}"
  done < "${manifest}"
}

_list() {
  local manifest="$1" kind key envvar desc hint cond
  printf 'Caller contract -- this worker requires:\n\n'
  while IFS='|' read -r kind key envvar desc hint cond; do
    if [[ -n "${cond}" ]]; then
      # Self-describe that this requirement is only enforced conditionally
      # (e.g. `packages` only when cache_backend: registry), so `--list`
      # doubles as accurate contract documentation.
      printf '  [%s] %s -- %s (when %s)\n' "${kind}" "${key}" "${desc}" "${cond}"
    else
      printf '  [%s] %s -- %s\n' "${kind}" "${key}" "${desc}"
    fi
  done < <(_read_manifest "${manifest}")
}

_validate() {
  local manifest="$1" kind key envvar desc hint cond
  local failures=0 total=0
  while IFS='|' read -r kind key envvar desc hint cond; do
    case "${kind}" in
      input|permission) ;;
      *)
        # A malformed manifest (typo'd kind column) must never validate
        # green -- fail loudly, naming the offending kind and its line, as
        # a config error (exit 2, same class as a missing manifest).
        printf "preflight: malformed manifest '%s': unknown requirement kind '%s' (expected 'input' or 'permission') on line: %s|%s|%s|%s|%s\n" \
          "${manifest}" "${kind}" "${kind}" "${key}" "${envvar}" "${desc}" "${hint}" >&2
        return 2
        ;;
    esac
    total=$((total + 1))
    # Optional 6th field `<condvar>=<value>` gates a requirement on another
    # env var (e.g. only require `packages: write` when the caller selected
    # `cache_backend: registry`). A declared-but-not-applicable requirement
    # is counted in the total (the manifest is non-empty) but skipped, never
    # a failure -- keeping unrelated callers backward compatible.
    if [[ -n "${cond}" ]]; then
      # A guard field lacking `=` is a malformed manifest: it cannot express
      # `<condvar>=<value>`, and silently skipping it would fail OPEN (the
      # requirement never enforced). Fail loud instead -- same class as the
      # unknown-kind guard (config error, exit 2), naming the offending guard.
      if [[ "${cond}" != *=* ]]; then
        printf "preflight: malformed manifest '%s': guard '%s' missing '=' (expected '<condvar>=<value>') on line: %s|%s|%s|%s|%s|%s\n" \
          "${manifest}" "${cond}" "${kind}" "${key}" "${envvar}" "${desc}" "${hint}" "${cond}" >&2
        return 2
      fi
      if ! _cond_applies "${cond}"; then
        continue
      fi
    fi
    if ! _check "${kind}" "${envvar}"; then
      if [[ "${failures}" -eq 0 ]]; then
        printf 'Preflight failed: this worker call is missing part of its caller contract.\n'
        printf 'Fix your .github/workflows/main.yaml as described below, then re-run.\n\n'
      fi
      failures=$((failures + 1))
      printf '  x %s (%s)\n' "${key}" "${desc}"
      printf '    reason: %s\n' "$(_reason "${kind}" "${envvar}")"
      printf '    fix:\n'
      printf '%b\n' "${hint}" | while IFS= read -r hint_line; do
        printf '      %s\n' "${hint_line}"
      done
      printf '\n'
    fi
  done < <(_read_manifest "${manifest}")

  if [[ "${total}" -eq 0 ]]; then
    # A manifest that exists but declares nothing to check must not pass
    # silently -- treat it as a config error (exit 2), same class as a
    # missing manifest file.
    printf "preflight: manifest '%s' declares no requirements (empty or all comments) -- nothing to validate\n" \
      "${manifest}" >&2
    return 2
  fi
  if [[ "${failures}" -gt 0 ]]; then
    printf 'Preflight: %d requirement(s) unmet -- see above.\n' "${failures}" >&2
    return 1
  fi
  printf 'Preflight OK: caller contract satisfied.\n'
}

main() {
  local mode="validate" manifest=""
  case "${1:-}" in
    --list|list) mode="list"; manifest="${2:-}" ;;
    "") printf 'usage: preflight.sh [--list] <manifest>\n' >&2; return 2 ;;
    *) manifest="${1}" ;;
  esac

  if [[ -z "${manifest}" || ! -f "${manifest}" ]]; then
    printf 'preflight: manifest not found: %s\n' "${manifest}" >&2
    return 2
  fi

  case "${mode}" in
    list) _list "${manifest}" ;;
    validate) _validate "${manifest}" ;;
  esac
}

main "$@"
