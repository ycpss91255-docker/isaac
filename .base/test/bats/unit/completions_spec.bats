#!/usr/bin/env bats
#
# Unit tests for the opt-in shell tab-completion installer
# dist/script/base/completions.sh (ADR-00000011).
#
# Reached as `just base completions install|uninstall [--shell ...]`, it writes
# the DYNAMIC `just` completion loader into each shell's standard auto-load
# directory and never edits a shell rc. The tests sandbox HOME + the XDG dirs
# to a temp tree and stub `just` on PATH so `JUST_COMPLETE=<shell> just` emits
# a recognisable per-shell marker; they assert the written file contents,
# idempotency, the zsh fpath hint, default-shell detection, and uninstall.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  COMPLETIONS="/source/dist/script/base/completions.sh"

  SANDBOX="$(mktemp -d)"
  export SANDBOX
  export HOME="${SANDBOX}/home"
  export XDG_DATA_HOME="${SANDBOX}/data"
  export XDG_CONFIG_HOME="${SANDBOX}/config"
  mkdir -p "${HOME}" "${XDG_DATA_HOME}" "${XDG_CONFIG_HOME}"

  # Stub `just` on PATH: emit a per-shell dynamic-completer marker so the spec
  # can prove the installer captured `JUST_COMPLETE=<shell> just` output (fish
  # / zsh) rather than freezing a snapshot.
  create_mock_dir
  mock_cmd "just" 'printf "# dynamic-completer for %s\n" "${JUST_COMPLETE:-none}"'

  BASH_TARGET="${XDG_DATA_HOME}/bash-completion/completions/just"
  FISH_TARGET="${XDG_CONFIG_HOME}/fish/completions/just.fish"
  ZSH_TARGET="${XDG_DATA_HOME}/zsh/site-functions/_just"
}

teardown() {
  cleanup_mock_dir
  [[ -n "${SANDBOX:-}" ]] && rm -rf "${SANDBOX}"
}

@test "install bash writes the dynamic eval-loader file" {
  run "${COMPLETIONS}" install --shell bash
  assert_success
  assert [ -f "${BASH_TARGET}" ]
  run cat "${BASH_TARGET}"
  assert_output 'eval "$(JUST_COMPLETE=bash just)"'
}

@test "install fish writes the file with the dynamic completer output" {
  run "${COMPLETIONS}" install --shell fish
  assert_success
  assert [ -f "${FISH_TARGET}" ]
  run cat "${FISH_TARGET}"
  assert_output --partial "dynamic-completer for fish"
}

@test "install zsh writes _just + prints the fpath hint when dir not on fpath" {
  run "${COMPLETIONS}" install --shell zsh
  assert_success
  assert [ -f "${ZSH_TARGET}" ]
  run cat "${ZSH_TARGET}"
  assert_output --partial "dynamic-completer for zsh"
  # The hint goes to stdout; the dir is not on the live $fpath (or zsh absent).
  run "${COMPLETIONS}" install --shell zsh
  assert_output --partial "fpath+=("
  assert_output --partial "autoload -U compinit"
}

@test "install zsh: a zsh still printing fpath cannot re-hint a dir already on it (#905)" {
  # `zsh -c 'print -l $fpath' | <reader>` where the reader stops reading:
  # it leaves on the matching directory, the zsh still printing the rest
  # of $fpath takes SIGPIPE and exits 141, completions.sh's file-scope
  # `pipefail` makes 141 the pipeline's status, and the `if` reads a
  # directory that IS on $fpath as absent. The hint is printed anyway --
  # advice to add something already there.
  #
  # This is the mildest of the five, and it is here for exactly that
  # reason: the same inverted answer costs a stray line here and a
  # container collision in run.sh. The mechanism is what is under test.
  local _dir="${XDG_DATA_HOME}/zsh/site-functions"
  shim_late_writer "${MOCK_DIR}" "zsh" "${_dir}" "/usr/share/zsh/site-functions"

  run "${COMPLETIONS}" install --shell zsh
  assert_success
  refute_output --partial "fpath+=("
}

@test "uninstall removes the installed file" {
  "${COMPLETIONS}" install --shell bash
  assert [ -f "${BASH_TARGET}" ]
  run "${COMPLETIONS}" uninstall --shell bash
  assert_success
  assert [ ! -f "${BASH_TARGET}" ]
}

@test "uninstall is idempotent when the file is absent (no error)" {
  run "${COMPLETIONS}" uninstall --shell bash
  assert_success
  assert [ ! -f "${BASH_TARGET}" ]
}

@test "install --shell all installs all three shells" {
  run "${COMPLETIONS}" install --shell all
  assert_success
  assert [ -f "${BASH_TARGET}" ]
  assert [ -f "${FISH_TARGET}" ]
  assert [ -f "${ZSH_TARGET}" ]
}

@test "uninstall --shell all removes all three shells" {
  "${COMPLETIONS}" install --shell all
  run "${COMPLETIONS}" uninstall --shell all
  assert_success
  assert [ ! -f "${BASH_TARGET}" ]
  assert [ ! -f "${FISH_TARGET}" ]
  assert [ ! -f "${ZSH_TARGET}" ]
}

@test "default --shell detects bash from \$SHELL basename" {
  SHELL="/usr/bin/bash" run "${COMPLETIONS}" install
  assert_success
  assert [ -f "${BASH_TARGET}" ]
}

@test "default --shell detection errors on an unknown shell" {
  SHELL="/usr/bin/tcsh" run "${COMPLETIONS}" install
  assert_failure
  assert_output --partial "--shell"
}

@test "unknown argument is a usage error (exit 2), distinct from detection error (#692)" {
  # A bogus flag is a usage error: exit 2, not the exit 1 used for an
  # unsupported-shell detection error. The distinction must not collapse.
  run "${COMPLETIONS}" --bogus-flag
  assert_equal "${status}" 2
  assert_output --partial "unknown argument"
}

@test "missing action is a usage error (exit 2) (#692)" {
  # A valid --shell but no install|uninstall action: usage error, exit 2.
  run "${COMPLETIONS}" --shell bash
  assert_equal "${status}" 2
  assert_output --partial "missing action"
}

@test "-h / --help exits 0 with usage" {
  run "${COMPLETIONS}" --help
  assert_success
  assert_output --partial "Usage:"
  run "${COMPLETIONS}" -h
  assert_success
  assert_output --partial "install"
}

@test "install is idempotent: a re-run overwrites cleanly" {
  "${COMPLETIONS}" install --shell bash
  run "${COMPLETIONS}" install --shell bash
  assert_success
  run cat "${BASH_TARGET}"
  assert_output 'eval "$(JUST_COMPLETE=bash just)"'
}
