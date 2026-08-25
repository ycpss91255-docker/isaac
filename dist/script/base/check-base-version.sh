#!/usr/bin/env bash
# check-base-version.sh - Per-repo base version monitor.
#
# Shipped inside the subtree so every downstream repo gets it (and its
# updates) for free on each upgrade. Driven by the generated workflow
# .github/workflows/base-version-monitor.yaml on a weekly schedule:
#
#   1. Read the pinned base version from <subtree>/.version.
#   2. Query the upstream base repo's latest STABLE release
#      (releases/latest skips prereleases / RC tags).
#   3. If the repo is behind, open a tracking issue in THIS repo so a
#      human can run `just upgrade`. Pull-based, files into itself with
#      the default GITHUB_TOKEN -- no PAT, no central repo list.
#
# Dedupe: at most one open `base-upgrade`-labelled issue per target
# version. A newer target opens a fresh issue; stale ones are closed by
# whoever performs the upgrade.
#
# Subcommands:
#   compare <local> <remote>   exit 0 iff <remote> is strictly newer
#                              (pure semver, numeric per-field, no network)
#   run                        full check-and-file flow (default)
#
# Env overrides:
#   BASE_REPO          upstream repo to poll (default ycpss91255-docker/base,
#                      the shared constant in upstream.sh). It also names
#                      the release link this script writes into the issue it
#                      files, so a wrong value publishes a wrong link.
#   MONITOR_LABEL      issue label used for dedupe (default base-upgrade)
#   BASE_VERSION_FILE  explicit local .version path (default: walk up to
#                      the subtree root carrying `.version` + `dist/`)
#   GH                 gh binary (default gh)
#   GH_REPO            target repo for `gh issue ...` (set by the workflow
#                      to ${{ github.repository }}; honoured natively by gh)

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

# One definition of the upstream identity, shared with upgrade.sh /
# init.sh. Sourced from this script's own directory: it runs from a
# generated workflow, not from a wrapper that has set the tree up.
_CHECK_BASE_VERSION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=dist/script/base/upstream.sh
source "${_CHECK_BASE_VERSION_DIR}/upstream.sh"

BASE_REPO="${BASE_REPO:-${BASE_UPSTREAM_SLUG}}"
MONITOR_LABEL="${MONITOR_LABEL:-base-upgrade}"
GH="${GH:-gh}"

# _strip_v <ver> -> ver without a leading 'v' and any -prerelease suffix.
_strip_v() {
  local _v="${1#v}"
  printf '%s' "${_v%%-*}"
}

# semver_gt <a> <b> -> exit 0 iff a > b, comparing major.minor.patch
# numerically (so 0.10.0 > 0.9.7, which a lexical compare gets wrong).
semver_gt() {
  local _a _b
  _a="$(_strip_v "${1}")"
  _b="$(_strip_v "${2}")"
  local -a A B
  IFS=. read -r -a A <<< "${_a}"
  IFS=. read -r -a B <<< "${_b}"
  local _i _ai _bi
  for _i in 0 1 2; do
    _ai="${A[_i]:-0}"
    _bi="${B[_i]:-0}"
    # Guard against non-numeric junk so `(( ))` never errors out.
    [[ "${_ai}" =~ ^[0-9]+$ ]] || _ai=0
    [[ "${_bi}" =~ ^[0-9]+$ ]] || _bi=0
    (( _ai > _bi )) && return 0
    (( _ai < _bi )) && return 1
  done
  return 1
}

# _local_version -> the base version this repo is pinned to.
_local_version() {
  if [[ -n "${BASE_VERSION_FILE:-}" ]]; then
    [[ -f "${BASE_VERSION_FILE}" ]] || { echo "check-base-version: ${BASE_VERSION_FILE} not found" >&2; return 1; }
    tr -d '[:space:]' < "${BASE_VERSION_FILE}"
    return 0
  fi
  local _dir
  _dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
  while [[ "${_dir}" != "/" ]]; do
    [[ -f "${_dir}/.version" && -d "${_dir}/dist" ]] && {
      tr -d '[:space:]' < "${_dir}/.version"
      return 0
    }
    _dir="$(cd -- "${_dir}/.." && pwd -P)"
  done
  echo "check-base-version: cannot locate subtree root (.version + dist/)" >&2
  return 1
}

# _latest_release -> upstream base's latest STABLE release tag.
_latest_release() {
  "${GH}" api "repos/${BASE_REPO}/releases/latest" --jq '.tag_name' 2>/dev/null
}

# _issue_open_for <version> -> exit 0 iff an open base-upgrade issue
# already names <version> (dedupe gate).
_issue_open_for() {
  local _target="${1}"
  # Read the whole title list and match in-shell. Piping into `grep -qF`
  # handed the answer to a reader that stops reading: grep leaves on its
  # match, the gh still writing the rest of the list takes SIGPIPE and
  # exits 141, and this script's `pipefail` makes 141 the PIPELINE's
  # status -- so an ALREADY-OPEN tracking issue read as absent and the
  # monitor filed a duplicate. It runs weekly in every downstream repo,
  # so that duplicate came back on every poll until someone upgraded.
  local _title
  local _found=1
  while IFS= read -r _title || [[ -n "${_title}" ]]; do
    if [[ "${_title}" == *"${_target}"* ]]; then
      _found=0
    fi
  done < <("${GH}" issue list --label "${MONITOR_LABEL}" --state open \
    --json title --jq '.[].title' 2>/dev/null)
  return "${_found}"
}

cmd_compare() {
  [[ $# -eq 2 ]] || { echo "usage: check-base-version.sh compare <local> <remote>" >&2; return 2; }
  semver_gt "${2}" "${1}"
}

cmd_run() {
  local _local _latest
  _local="$(_local_version)" || return 1
  _latest="$(_latest_release)"
  if [[ -z "${_latest}" ]]; then
    echo "check-base-version: could not resolve ${BASE_REPO} latest release" >&2
    return 1
  fi

  if ! semver_gt "${_latest}" "${_local}"; then
    echo "check-base-version: up to date (${_local} >= ${_latest})"
    return 0
  fi

  if _issue_open_for "${_latest}"; then
    echo "check-base-version: tracking issue for ${_latest} already open; skipping"
    return 0
  fi

  local _title _body
  _title="chore: .base behind base — upgrade ${_local} -> ${_latest}"
  _body="A newer \`base\` release is available.

- Current (this repo's \`.base/.version\`): \`${_local}\`
- Latest stable release: \`${_latest}\`

Upgrade the subtree with:

\`\`\`bash
just upgrade ${_latest}
\`\`\`

Release notes: https://github.com/${BASE_REPO}/releases/tag/${_latest}

---
Opened automatically by \`.github/workflows/base-version-monitor.yaml\`."

  "${GH}" issue create \
    --label "${MONITOR_LABEL}" \
    --title "${_title}" \
    --body "${_body}"
  echo "check-base-version: opened tracking issue for ${_latest} (was ${_local})"
}

main() {
  local _cmd="${1:-run}"
  case "${_cmd}" in
    compare) shift; cmd_compare "$@" ;;
    run)     shift || true; cmd_run ;;
    -h|--help|help)
      grep -E '^#( |$)' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
      ;;
    *) echo "check-base-version.sh: unknown subcommand '${_cmd}'" >&2; return 2 ;;
  esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
