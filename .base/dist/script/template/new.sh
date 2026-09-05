#!/usr/bin/env bash
# new.sh -- scaffold a repo-local just command group (ADR-00000010).
#
# `just template new <name>` runs this (via the `template` namespace's
# `[no-cd]` recipe, so cwd is the repo root). It creates
# script/local/<name>/justfile.<name> + <name>.sh from the skeleton, and
# registers the group by appending one `mod?` line to
# script/local/justfile.local -- after which `just <name> <recipe>` works.
#
# Refuses to clobber an existing group; the registry append is idempotent.
# The skel/ templates are located relative to this script, so it works
# through the consumer's symlink into .base/dist/script/template/.
set -euo pipefail

# i18n.sh provides _resolve_lang / _sanitize_lang. new.sh is a
# human-facing template-namespace script, so it accepts --lang and honors
# SETUP_LANG/$LANG like the docker wrappers, even though its (few) strings
# are still English-only pending the localized-message pass. Located
# relative to this script's real path so it resolves through the consumer
# symlink into .base/dist/script/template/new.sh.
_new_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=dist/script/docker/lib/i18n.sh
source "$(dirname -- "${_new_self}")/../docker/lib/i18n.sh"
unset _new_self

_usage() {
  cat >&2 <<'EOF'
Usage: just template new <name> [--lang <en|zh-TW|zh-CN|ja>]

Scaffold a repo-local just command group: create script/local/<name>/ from
the skeleton and register it in script/local/justfile.local. After it runs,
`just <name> <recipe>` works.

Arguments:
  <name>         group name (must match ^[a-z][a-z0-9_-]*$)

Options:
  --lang LANG    Message language (en|zh-TW|zh-CN|ja; default: auto-detect
                 from SETUP_LANG / $LANG)
  -h, --help     Show this help
EOF
  exit 0
}

main() {
  local _LANG
  _resolve_lang _LANG

  local name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _usage ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "template new"
        shift 2
        ;;
      *)
        name="$1"
        shift
        ;;
    esac
  done

  if [[ -z "${name}" ]]; then
    printf 'usage: just template new <name>\n' >&2
    return 2
  fi
  if [[ ! "${name}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    printf 'invalid group name %q (must match ^[a-z][a-z0-9_-]*$)\n' "${name}" >&2
    return 2
  fi

  local self_dir skel dest reg line
  self_dir="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd -P)"
  skel="${self_dir}/skel"
  dest="script/local/${name}"
  reg="script/local/justfile.local"

  if [[ -e "${dest}" ]]; then
    printf 'group %q already exists at %s -- refusing to clobber\n' "${name}" "${dest}" >&2
    return 1
  fi

  mkdir -p "${dest}" script/local
  sed "s/__NAME__/${name}/g" "${skel}/justfile.skel" > "${dest}/justfile.${name}"
  sed "s/__NAME__/${name}/g" "${skel}/skel.sh" > "${dest}/${name}.sh"
  chmod +x "${dest}/${name}.sh"

  line="mod? ${name} '${name}/justfile.${name}'"
  # Match a whole real registration line only (grep -x), NOT a commented
  # example: init.sh seeds the registry with `#   mod? deploy '...'`, and a
  # substring match (grep -F) there made `new.sh deploy` a silent no-op
  # (reported "already registered", appended nothing -> `just deploy`
  # undispatchable).
  if [[ -f "${reg}" ]] && grep -qxF "${line}" "${reg}"; then
    printf 'group %q already registered in %s\n' "${name}" "${reg}"
  else
    printf '%s\n' "${line}" >> "${reg}"
  fi
  printf 'created group %q -- run: just %s <recipe>\n' "${name}" "${name}"
}

main "$@"
