#!/usr/bin/env bash
#
# Opt-in shell tab-completion installer for `just` (ADR-00000011).
#
# Reached as `just base completions install|uninstall [--shell ...]` via the
# consumer symlink script/base/completions.sh. It writes the DYNAMIC clap
# completion loader for the requested shell(s) into that shell's standard
# auto-load directory -- it never edits a shell rc. Because the loader is
# dynamic (`eval "$(JUST_COMPLETE=<shell> just)"` for bash, the generated
# completer for fish/zsh) the completions always reflect the live justfile,
# including the layered `docker::` / `base::` namespaces.
#
#   bash: ${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/just
#   fish: ${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/just.fish
#   zsh:  ${XDG_DATA_HOME:-$HOME/.local/share}/zsh/site-functions/_just
#
# For zsh the site-functions dir is only consulted if it is on $fpath; when it
# is not, a one-line hint is printed (stdout) -- but ~/.zshrc is never touched.

set -euo pipefail

# i18n.sh provides _resolve_lang / _sanitize_lang. completions.sh is
# a human-facing `base` namespace recipe, so it accepts --lang and honors
# SETUP_LANG/$LANG like the docker wrappers, even though its diagnostics are
# English-only pending the localized pass. Located relative to this
# script's real path so it resolves through the consumer symlink into
# .base/dist/script/base/completions.sh.
_completions_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"
# shellcheck source=dist/script/docker/lib/i18n.sh
source "$(dirname -- "${_completions_self}")/../docker/lib/i18n.sh"
unset _completions_self

# ── messaging ───────────────────────────────────────────────────────────────
# Diagnostics go to stderr; the zsh fpath hint (something the user may want to
# capture/eval) goes to stdout.

_msg() {
  printf '%s\n' "$*" >&2
}

_err() {
  printf 'completions.sh: %s\n' "$*" >&2
}

_usage() {
  cat <<'EOF'
Usage: completions.sh <install|uninstall> [--shell bash|zsh|fish|all]

Opt-in shell tab-completion for `just`. Writes the dynamic completion loader
into the shell's standard auto-load directory; never edits a shell rc.

  install     write the completion loader for the selected shell(s)
  uninstall   remove the completion loader for the selected shell(s)

  --shell     bash | zsh | fish | all  (default: detect from $SHELL)
  --lang      en | zh-TW | zh-CN | ja  (default: auto-detect from
              SETUP_LANG / $LANG)
  -h, --help  show this help
EOF
}

# ── target paths ────────────────────────────────────────────────────────────

_bash_target() {
  printf '%s/bash-completion/completions/just' \
    "${XDG_DATA_HOME:-${HOME}/.local/share}"
}

_fish_target() {
  printf '%s/fish/completions/just.fish' \
    "${XDG_CONFIG_HOME:-${HOME}/.config}"
}

_zsh_dir() {
  printf '%s/zsh/site-functions' "${XDG_DATA_HOME:-${HOME}/.local/share}"
}

_zsh_target() {
  printf '%s/_just' "$(_zsh_dir)"
}

# ── shell detection ─────────────────────────────────────────────────────────

_detect_shell() {
  local shell_name
  shell_name="$(basename "${SHELL:-}")"
  case "${shell_name}" in
    bash | zsh | fish)
      printf '%s' "${shell_name}"
      ;;
    *)
      _err "could not detect a supported shell from \$SHELL (${SHELL:-unset}); pass --shell bash|zsh|fish|all"
      return 1
      ;;
  esac
}

# ── install ─────────────────────────────────────────────────────────────────

_install_bash() {
  local target
  target="$(_bash_target)"
  mkdir -p "$(dirname "${target}")"
  # The bash loader is written verbatim -- the $(...) must reach the file so it
  # evaluates the dynamic completer at shell startup, not here.
  # shellcheck disable=SC2016
  printf 'eval "$(JUST_COMPLETE=bash just)"\n' > "${target}"
  _msg "installed bash completions -> ${target}"
}

_install_fish() {
  local target
  target="$(_fish_target)"
  mkdir -p "$(dirname "${target}")"
  JUST_COMPLETE=fish just > "${target}"
  _msg "installed fish completions -> ${target}"
}

_install_zsh() {
  local dir target
  dir="$(_zsh_dir)"
  target="$(_zsh_target)"
  mkdir -p "${dir}"
  JUST_COMPLETE=zsh just > "${target}"
  _msg "installed zsh completions -> ${target}"
  _zsh_fpath_hint "${dir}"
}

# Print a one-line hint (stdout) telling the user how to put the zsh
# site-functions dir on $fpath -- only when it is not already there. Never
# edits ~/.zshrc. If zsh is not installed we cannot inspect the live $fpath, so
# we always print the hint.
_zsh_fpath_hint() {
  local dir="$1"
  if command -v zsh > /dev/null 2>&1; then
    # Read the whole $fpath listing and compare in-shell. Piping into
    # `grep -qxF` handed the answer to a reader that stops reading: grep
    # leaves on its match, the zsh still printing the rest of $fpath takes
    # SIGPIPE and exits 141, and this file's `pipefail` makes 141 the
    # PIPELINE's status -- so a directory that IS on $fpath read as absent
    # and the hint was printed anyway.
    local _entry
    local _on_fpath=1
    while IFS= read -r _entry || [[ -n "${_entry}" ]]; do
      if [[ "${_entry}" == "${dir}" ]]; then
        _on_fpath=0
      fi
    done < <(zsh -c 'print -l $fpath' 2> /dev/null)
    if (( _on_fpath == 0 )); then
      return 0
    fi
  fi
  printf 'fpath+=(%s); autoload -U compinit; compinit\n' "${dir}"
}

# ── uninstall ───────────────────────────────────────────────────────────────

_uninstall_one() {
  local target="$1"
  if [[ -e "${target}" || -L "${target}" ]]; then
    rm -f "${target}"
    _msg "removed ${target}"
  else
    _msg "nothing to remove at ${target}"
  fi
}

# ── dispatch ────────────────────────────────────────────────────────────────

_do() {
  local action="$1" shell="$2"
  case "${action}" in
    install)
      case "${shell}" in
        bash) _install_bash ;;
        zsh) _install_zsh ;;
        fish) _install_fish ;;
      esac
      ;;
    uninstall)
      case "${shell}" in
        bash) _uninstall_one "$(_bash_target)" ;;
        zsh) _uninstall_one "$(_zsh_target)" ;;
        fish) _uninstall_one "$(_fish_target)" ;;
      esac
      ;;
  esac
}

main() {
  local action="" shell=""
  local _LANG
  _resolve_lang _LANG

  while [[ $# -gt 0 ]]; do
    case "$1" in
      install | uninstall)
        action="$1"
        shift
        ;;
      --shell)
        shell="${2:-}"
        shift 2 || true
        ;;
      --lang)
        _LANG="${2:?"--lang requires a value (en|zh-TW|zh-CN|ja)"}"
        _sanitize_lang _LANG "completions"
        shift 2
        ;;
      -h | --help)
        _usage
        return 0
        ;;
      *)
        _err "unknown argument: $1"
        _usage >&2
        return 2
        ;;
    esac
  done

  if [[ -z "${action}" ]]; then
    _err "missing action (install|uninstall)"
    _usage >&2
    return 2
  fi

  if [[ -z "${shell}" ]]; then
    shell="$(_detect_shell)" || return 1
  fi

  case "${shell}" in
    bash | zsh | fish)
      _do "${action}" "${shell}"
      ;;
    all)
      _do "${action}" bash
      _do "${action}" zsh
      _do "${action}" fish
      ;;
    *)
      _err "unknown --shell '${shell}' (want bash|zsh|fish|all)"
      return 2
      ;;
  esac
}

main "$@"
