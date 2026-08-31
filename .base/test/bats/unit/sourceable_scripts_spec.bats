#!/usr/bin/env bats
#
# Unit tests for the "a spec can source this file" contract.
#
# Two families of shell file here declare themselves sourceable: every
# module under dist/script/docker/lib/, and every script that carries the
# sourced-vs-executed guard at its bottom
# (`if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then main "$@"; fi`, with
# the comment "for testing" beside it). A test that drives a REAL function
# instead of re-implementing it depends on that contract holding, and the
# way it breaks is environment-specific -- it shows up only under the
# kcov-instrumented bash of the coverage shard, i.e. in CI, one round trip
# at a time.
#
# Two distinct hazards, one per section below.
#
# (1) LEAKED STRICT MODE. kcov drives its line counter from xtrace with
#     PS4 set to a string that expands ${BASH_SOURCE}. At the top level of
#     a `bash -c '...'` string that array is EMPTY, so if the sourced file
#     turned nounset on for its caller, the very next traced command at
#     that top level dies on an unbound variable -- inside kcov's own PS4,
#     not in any line of the test. The established shape is to gate the
#     `set -euo pipefail` on being executed directly ("Only set strict mode
#     when running directly; when sourced, respect caller's settings"),
#     which every sibling sourceable script already does.
#
# (2) AN UNGUARDED SELF-LOCATING READ. `${BASH_SOURCE[0]}` with no default
#     aborts under nounset wherever the array is not populated for the
#     file. Defaulting it to `$0` is inert under direct execution (both
#     expand to the same path) and degrades instead of aborting elsewhere.
#     Simulated here by eval'ing the file's text with $0 pointing at it --
#     an exact stand-in for "the file runs, but BASH_SOURCE does not
#     describe it" that needs no instrumented shell to reproduce.
#
# The mechanical half of (2) is also a lint (drivers/bash_source_guard.sh);
# this spec is the behavioural half -- it proves the files actually LOAD,
# which no grep can.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SRC=/source
}

# _sourceable_guarded -- newline-separated shipped/tooling scripts that
# carry the sourced-vs-executed guard. Discovered, not pinned, so a new
# one is covered the day it is written.
_sourceable_guarded() {
  grep -rl --include='*.sh' \
    'BASH_SOURCE\[0\]:-.*==.*\${0' "${SRC}/dist" "${SRC}/script" | sort
}

# _sourceable_libs -- the docker lib modules, every one of which exists to
# be sourced.
#
# help.sh is excluded on purpose and is NOT an exception to the contract:
# it takes a mandatory namespace argument at file scope (`${1:?}`), so it
# is sourced WITH an argument by the help dispatcher and has no standalone
# form to assert. Its BASH_SOURCE read is still covered by the lint.
_sourceable_libs() {
  find "${SRC}/dist/script/docker/lib" -maxdepth 1 -name '*.sh' -type f \
    ! -name 'help.sh' | sort
}

# ════════════════════════════════════════════════════════════════════
# (1) Sourcing must not leak strict mode into the caller
# ════════════════════════════════════════════════════════════════════

@test "sourceable scripts: the discovered set is non-empty and covers the known entry points (#869)" {
  # Non-vacuity floor for every loop below: a broken discovery expression
  # would make them iterate zero files and assert nothing, which is the
  # exact failure this whole spec exists to prevent.
  local -a _guarded=() _libs=()
  mapfile -t _guarded < <(_sourceable_guarded)
  mapfile -t _libs < <(_sourceable_libs)
  [ "${#_guarded[@]}" -ge 12 ] \
    || fail "only ${#_guarded[@]} guard-carrying scripts discovered"
  [ "${#_libs[@]}" -ge 25 ] \
    || fail "only ${#_libs[@]} lib modules discovered"

  local _f
  for _f in dist/script/docker/wrapper/setup_tui.sh \
    dist/script/docker/wrapper/setup.sh \
    script/test/test.sh; do
    printf '%s\n' "${_guarded[@]}" | grep -qxF "${SRC}/${_f}" \
      || fail "${_f} is not in the discovered sourceable set"
  done
}

@test "sourceable scripts: none leaves nounset or errexit on in its caller (#869)" {
  # The kcov-visible half. A file that turns strict mode on for its caller
  # makes the caller's next top-level command die inside kcov's PS4, so a
  # spec that sources it fails in the coverage shard and nowhere else. The
  # `bash -c` here is deliberately NOT strict: the property is that the
  # file does not make it strict.
  local -a _files=()
  mapfile -t _files < <(_sourceable_guarded; _sourceable_libs)
  local _f _leaks
  for _f in "${_files[@]}"; do
    run bash -c "source ${_f}
case \$- in *u*) printf 'nounset '  ;; esac
case \$- in *e*) printf 'errexit ' ;; esac
printf 'END\n'"
    assert_success
    _leaks="${output%END}"
    [ -z "${_leaks}" ] \
      || fail "${_f#"${SRC}/"} leaked strict mode into its caller: ${_leaks}"
  done
}

@test "sourceable scripts: each loads and returns control to the caller (#869)" {
  # The end-to-end statement of the contract: source the file, then run one
  # more command at the caller's top level. Under kcov that trailing
  # command is what dies when the file leaked nounset, so asserting a
  # marker AFTER the source -- not merely that the source itself exited 0
  # -- is what makes this test able to see the failure at all.
  local -a _files=()
  mapfile -t _files < <(_sourceable_guarded; _sourceable_libs)
  local _f
  for _f in "${_files[@]}"; do
    run --separate-stderr bash -c "source ${_f}
printf 'LOADED\n'"
    assert_success
    [ "${output}" = "LOADED" ] \
      || fail "${_f#"${SRC}/"} did not return control to the caller: ${output}"
    [[ "${stderr}" != *"unbound variable"* ]] \
      || fail "${_f#"${SRC}/"} loaded with an unbound-variable error: ${stderr}"
  done
}

# ════════════════════════════════════════════════════════════════════
# (2) Self-location must survive an unpopulated BASH_SOURCE
# ════════════════════════════════════════════════════════════════════

# _load_without_bash_source <file> -- run <file>'s text in a fresh bash
# where BASH_SOURCE does NOT describe it, with $0 pointing at the real
# path. `eval` pushes no source frame, so this reproduces "the code runs,
# BASH_SOURCE is empty" with no instrumented shell required.
#
# errexit but deliberately NOT nounset: kcov drives its counter from
# xtrace with a PS4 that expands ${BASH_SOURCE}, so nounset at the top
# level of ANY `bash -c` string aborts inside the instrumentation before
# reaching the subject -- the harness cannot host that combination, and a
# test that demanded it would be untestable under coverage rather than
# informative. Nounset is not needed to see the defect: with the read
# undefaulted the self-location resolves to the CWD instead, every sibling
# `source` below it misses, and errexit turns that into the failure this
# asserts.
_load_without_bash_source() {
  bash -c 'set -eo pipefail
_text="$(cat -- "$0")"
eval "${_text}"
printf "LOADED\n"' "${1}"
}

@test "self-location: the lib umbrella loads with BASH_SOURCE unpopulated (#869)" {
  # _lib.sh is the whole chain: its own read resolves the dir that every
  # sibling source below it is spelled against, so an abort here takes out
  # i18n / log / transcript / env / conf / schema / compose / deploy / ...
  run --separate-stderr _load_without_bash_source \
    "${SRC}/dist/script/docker/lib/_lib.sh"
  assert_success
  [ "${output}" = "LOADED" ]
  [[ "${stderr}" != *"unbound variable"* ]] || fail "stderr: ${stderr}"
  [[ "${stderr}" != *"No such file"* ]] || fail "stderr: ${stderr}"
}

@test "self-location: the TUI wrapper loads with BASH_SOURCE unpopulated (#869)" {
  run --separate-stderr _load_without_bash_source \
    "${SRC}/dist/script/docker/wrapper/setup_tui.sh"
  assert_success
  [ "${output}" = "LOADED" ]
  [[ "${stderr}" != *"unbound variable"* ]] || fail "stderr: ${stderr}"
  [[ "${stderr}" != *"No such file"* ]] || fail "stderr: ${stderr}"
}

@test "self-location: the setup wrapper loads with BASH_SOURCE unpopulated (#869)" {
  run --separate-stderr _load_without_bash_source \
    "${SRC}/dist/script/docker/wrapper/setup.sh"
  assert_success
  [ "${output}" = "LOADED" ]
  [[ "${stderr}" != *"unbound variable"* ]] || fail "stderr: ${stderr}"
  [[ "${stderr}" != *"No such file"* ]] || fail "stderr: ${stderr}"
}

@test "self-location: the self-test dispatcher loads with BASH_SOURCE unpopulated (#869)" {
  run --separate-stderr _load_without_bash_source "${SRC}/script/test/test.sh"
  assert_success
  [ "${output}" = "LOADED" ]
  [[ "${stderr}" != *"unbound variable"* ]] || fail "stderr: ${stderr}"
  [[ "${stderr}" != *"No such file"* ]] || fail "stderr: ${stderr}"
}

@test "self-location: every docker lib module loads with BASH_SOURCE unpopulated (#869)" {
  # The sweep. A partial fix is what made the earlier attempts fail: a
  # wrapper that guards its own read still aborts on the first lib below
  # it that does not.
  local -a _libs=()
  mapfile -t _libs < <(_sourceable_libs)
  [ "${#_libs[@]}" -ge 25 ] || fail "only ${#_libs[@]} lib modules discovered"
  local _f
  for _f in "${_libs[@]}"; do
    run --separate-stderr _load_without_bash_source "${_f}"
    assert_success
    [ "${output}" = "LOADED" ] \
      || fail "${_f#"${SRC}/"}: ${output} ${stderr}"
    [[ "${stderr}" != *"unbound variable"* ]] \
      || fail "${_f#"${SRC}/"}: ${stderr}"
    [[ "${stderr}" != *"No such file"* ]] \
      || fail "${_f#"${SRC}/"} resolved its siblings against the wrong dir: ${stderr}"
  done
}
