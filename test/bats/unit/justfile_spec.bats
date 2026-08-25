#!/usr/bin/env bats
#
# Static checks for the layered user-facing just entry (ADR-00000010):
# the entry at dist/script/justfile (symlinked into the consumer as
# script/justfile, with <repo>/justfile -> script/justfile) imports the
# docker recipes at dist/script/docker/justfile.docker as top-level
# verbs. ADR-00000005: `just` replaces the GNU make wrapper -- recipes
# forward 1:1 to ./script/<name>.sh with full `{{args}}` passthrough (no
# MAKEOVERRIDES guard / `--` separator / EXEC_ARGS shim).
#
# These are content assertions (grep), not execution: `just` is not
# installed in the test-tools image, so the files are verified statically
# here; downstream installs `just` to run them. Execution parity lives in
# justfile_user_spec.bats.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # Verb recipes live in the docker module; the `default` recipe + the
  # import live in the entry.
  DOCKER_JUSTFILE=/source/dist/script/docker/justfile.docker
  ENTRY=/source/dist/script/justfile
}

@test "layered entry + docker module exist" {
  [ -f "${ENTRY}" ]
  [ -f "${DOCKER_JUSTFILE}" ]
}

@test "docker module declares args-passthrough recipes for every wrapper verb (#545)" {
  local _v
  for _v in build run exec stop prune setup; do
    run grep -E "^${_v} \*args:" "${DOCKER_JUSTFILE}"
    assert_success
  done
  run grep -E '^setup-tui \*args:' "${DOCKER_JUSTFILE}"
  assert_success
}

@test "docker module no longer carries upgrade/upgrade-check (moved to base ns, #652)" {
  # upgrade is a .base-management op, not a docker op -- it lives in the
  # `base` namespace (just base upgrade / just base update), ADR-00000011.
  run grep -E '^upgrade |^upgrade-check:' "${DOCKER_JUSTFILE}"
  assert_failure
}

@test "docker module recipes forward to ./script/<wrapper>.sh with {{args}} (#545)" {
  run grep -F './script/build.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/run.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/exec.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F './script/setup_tui.sh {{args}}' "${DOCKER_JUSTFILE}"
  assert_success
}

@test "base module declares upgrade + update (apt-aligned) forwarding to .base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)" {
  local _base=/source/dist/script/base/justfile.base
  [ -f "${_base}" ]
  run grep -E '^upgrade \*args:' "${_base}"
  assert_success
  # `update` takes *args purely as a --help shim: it still runs the check, so
  # the signature is `update *args:` not the old argless `update:`.
  run grep -E '^update \*args:' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/upgrade.sh {{args}}' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/upgrade.sh --check' "${_base}"
  assert_success
}

@test "base update recipe forwards -h|--help to upgrade.sh usage without the check (#789)" {
  # The --help shim: `just base update --help` must reach upgrade.sh --help
  # (usage) rather than running the network check or erroring on a dashed name.
  local _base=/source/dist/script/base/justfile.base
  run grep -F 'exec ./.base/dist/script/base/upgrade.sh --help' "${_base}"
  assert_success
  run grep -E '\-h\|--help' "${_base}"
  assert_success
}

@test "every shipped namespace module ships a help recipe + h alias (#789)" {
  # Namespace-level help within just's module limits: `just <ns> help` /
  # `just <ns> h` list the namespace (dashed `just <ns> --help` cannot be a
  # recipe; with `help` present just hints "Did you mean 'help'?").
  local _m
  for _m in /source/dist/script/docker/justfile.docker \
            /source/dist/script/base/justfile.base \
            /source/dist/script/template/justfile.template; do
    run grep -E '^help( |:)' "${_m}"
    assert_success
    run grep -F 'alias h := help' "${_m}"
    assert_success
  done
}

@test "base module declares init + completions recipes (#653, ADR-00000011)" {
  local _base=/source/dist/script/base/justfile.base
  run grep -E '^init ' "${_base}"
  assert_success
  run grep -E '^completions ' "${_base}"
  assert_success
  run grep -F './.base/dist/script/base/init.sh {{args}}' "${_base}"
  assert_success
  run grep -F 'script/base/completions.sh {{args}}' "${_base}"
  assert_success
}

@test "entry mods the base namespace (#652, ADR-00000011)" {
  run grep -F "mod? base 'script/base/justfile.base'" "${ENTRY}"
  assert_success
}

@test "docker module owns a default recipe + pins cwd to repo root (#652, ADR-00000011)" {
  # As a mod? module (not a top-level import) it owns its own default
  # (`just docker` lists the verbs); module recipes default cwd to the
  # module dir, so `set working-directory := '../..'` pins them to the
  # repo root for the ./script/<wrapper>.sh calls.
  run grep -E '^default:' "${DOCKER_JUSTFILE}"
  assert_success
  run grep -F "set working-directory := '../..'" "${DOCKER_JUSTFILE}"
  assert_success
}

@test "entry mods the docker namespace + default recipe lists recipes (#652, ADR-00000011)" {
  # docker is a namespace (zero special case): `just docker build`, not a
  # top-level `just build`. bare `just` still lists via the entry default.
  run grep -F "mod? docker 'script/docker/justfile.docker'" "${ENTRY}"
  assert_success
  run grep -E '^default:' "${ENTRY}"
  assert_success
  run grep -F 'just --list' "${ENTRY}"
  assert_success
}

@test "test / release namespaces own a default recipe (bare-namespace help, #655)" {
  # Every namespace must respond to a bare invocation (`just test` /
  # `just release`) with its English-baseline help -- the `default` recipe.
  run grep -E '^default:' /source/script/test/justfile.test
  assert_success
  run grep -E '^default:' /source/script/release/justfile.release
  assert_success
}

@test "test namespace: coverage-path demands its spec, coverage keeps its optional shard (#887)" {
  # `just test coverage-path <spec>` is the one-spec-under-kcov entry. Its
  # argument is REQUIRED: an optional one (`spec=''`, the shape the sibling
  # `coverage` recipe uses for its shard) would turn a mistyped bare
  # invocation into a silent 8-12 minute full-suite kcov run instead of an
  # error naming the missing argument.
  local _test_justfile=/source/script/test/justfile.test
  run grep -E "^coverage-path spec \*args:$" "${_test_justfile}"
  assert_success
  run grep -E "^coverage-path spec=" "${_test_justfile}"
  assert_failure
  run grep -F -- "--coverage-path '{{spec}}'" "${_test_justfile}"
  assert_success
  # The shard argument of `coverage` stays optional (bare = full suite).
  run grep -E "^coverage shard='':$" "${_test_justfile}"
  assert_success
}

@test "test / release namespaces are English-only -- no --lang plumbing (#655)" {
  # ADR-00000011 i18n scope: test / release are machine/CI namespaces, so
  # they ship no --lang flag (only docker / base / template are localised).
  run grep -F -- '--lang' /source/script/test/justfile.test
  assert_failure
  run grep -F -- '--lang' /source/script/release/justfile.release
  assert_failure
}

# `just --list` uses the comment IMMEDIATELY above a `mod?` (no blank gap) as
# the module's description, and only the LAST line of a contiguous block. A
# blank gap yields NO description; a multi-line block yields a mid-sentence
# fragment. Enforce one clean one-liner per mod?: line above is a `#` comment,
# line two-above is NOT (single, adjacent).
_assert_mod_doc_comments() {
  awk '
    BEGIN { bad=0 }
    /^mod\? / {
      if (prev !~ /^#/)      { print "no adjacent doc comment: " $0; bad=1 }
      else if (prev2 ~ /^#/) { print "multi-line comment block (fragment risk): " $0; bad=1 }
    }
    { prev2=prev; prev=$0 }
    END { exit bad }
  ' "$1"
}

@test "consumer entry: every top-level mod? has one adjacent one-line doc comment (#720)" {
  run _assert_mod_doc_comments "${ENTRY}"
  assert_success
}

@test "base root justfile: every top-level mod? has one adjacent one-line doc comment (#720)" {
  run _assert_mod_doc_comments /source/justfile
  assert_success
}
