#!/usr/bin/env bash
# run_bats.sh -- run bats, skipping the spec groups CI did not select
# (isaac#434).
#
# Usage: BATS_SKIP_GROUPS=stream,gui run_bats.sh [bats args...] <dir>
#
# BATS_SKIP_GROUPS is a comma list of groups (core, gui, stream, headless,
# docs) whose specs must not run. Specs are grouped with `# bats
# file_tags=<group>`; specs with no group (the base-owned ones baked into the
# same directory) are never skipped, so the shared layer is always checked.
# Empty or unset runs everything. An unknown group exits 2 rather than
# silently skipping nothing.
set -euo pipefail

readonly VALID_GROUPS=" core gui stream headless docs "

filter=""
IFS=',' read -r -a skip <<<"${BATS_SKIP_GROUPS:-}"
for group in "${skip[@]}"; do
  group="${group//[[:space:]]/}"
  [[ -z "${group}" ]] && continue
  if [[ "${VALID_GROUPS}" != *" ${group} "* ]]; then
    echo "error: unknown group '${group}' in BATS_SKIP_GROUPS" \
      "(valid:${VALID_GROUPS})" >&2
    exit 2
  fi
  filter+="${filter:+,}!${group}"
done

if [[ -n "${filter}" ]]; then
  echo "run_bats: skipping groups ${BATS_SKIP_GROUPS} (--filter-tags '${filter}')" >&2
  exec bats --filter-tags "${filter}" "$@"
fi
exec bats "$@"
