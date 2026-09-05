#!/usr/bin/env bats
#
# Unit tests for dist/script/base/upstream.sh -- the one definition of
# where `base` itself comes from.
#
# Three scripts ask that question: upgrade.sh (the subtree pull AND the
# version query), init.sh (the version query on a subtree with no
# .version yet) and check-base-version.sh (the release poll, plus the
# release link it writes into a real GitHub issue). Each used to carry
# its own literal, so "point this repo at a fork" meant finding all of
# them and a stale one pointed at the wrong supply.
#
# What is fetched from that URL is then EXECUTED -- every wrapper, lib,
# Dockerfile and entrypoint under .base/dist/ -- so the value is the
# highest-trust input the repo has, and worth one auditable definition.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  UPSTREAM_SH="/source/dist/script/base/upstream.sh"
  UPGRADE_SH="/source/dist/script/base/upgrade.sh"
  INIT_SH="/source/dist/script/base/init.sh"
  MONITOR_SH="/source/dist/script/base/check-base-version.sh"
}

# ════════════════════════════════════════════════════════════════════
# The constants themselves
# ════════════════════════════════════════════════════════════════════

@test "upstream.sh: defines the slug and derives the clone URL from it (#895)" {
  run bash -c "
    source '${UPSTREAM_SH}'
    printf '%s\n%s\n' \"\${BASE_UPSTREAM_SLUG}\" \"\${BASE_UPSTREAM_REMOTE}\"
  "
  assert_success
  assert_line --index 0 "ycpss91255-docker/base"
  assert_line --index 1 "https://github.com/ycpss91255-docker/base.git"
}

@test "upstream.sh: sourcing it twice is inert (#895)" {
  # upgrade.sh sources it and then sources _lib.sh, which pulls in more of
  # the tree; a second arrival must not abort a `set -e` caller.
  #
  # The strict shell is a script FILE, never `bash -c '...'`. The coverage
  # shard runs bash under kcov, which counts lines from xtrace with a PS4
  # that expands ${BASH_SOURCE}; at the top level of a `bash -c` string
  # that array is EMPTY, so the first command traced after `set -u` dies
  # "BASH_SOURCE: unbound variable" before the source under test runs at
  # all. That aborts the harness, not the code, which is why this case
  # passed plain and failed under coverage. A script file populates
  # BASH_SOURCE[0]. The sibling cases here do not set -u, so they are
  # unaffected. Same interaction as adr_numbering_spec and
  # sourceable_scripts_spec.
  local _runner="${BATS_TEST_TMPDIR}/source_twice_strict.sh"
  cat > "${_runner}" << EOF
set -euo pipefail
source '${UPSTREAM_SH}'
source '${UPSTREAM_SH}'
printf '%s\n' "\${BASE_UPSTREAM_REMOTE}"
EOF
  run bash "${_runner}"
  assert_success
  assert_output "https://github.com/ycpss91255-docker/base.git"
}

@test "upstream.sh: reads nothing from the environment (#895)" {
  # The overrides are TEMPLATE_REMOTE / BASE_REPO, applied by the scripts
  # that consume these constants. A shared file that ALSO honoured an
  # override would be a second, undocumented spelling of the same knob.
  run bash -c "
    BASE_UPSTREAM_SLUG=attacker/evil BASE_UPSTREAM_REMOTE=https://evil.example/x.git \
      bash -c 'source \"${UPSTREAM_SH}\"; printf \"%s|%s\n\" \"\${BASE_UPSTREAM_SLUG}\" \"\${BASE_UPSTREAM_REMOTE}\"'
  "
  assert_success
  assert_output "ycpss91255-docker/base|https://github.com/ycpss91255-docker/base.git"
}

# ════════════════════════════════════════════════════════════════════
# One definition, three consumers
# ════════════════════════════════════════════════════════════════════

@test "exactly one shipped file names the upstream in code (#895)" {
  # Scanned over dist/ (what a consumer repo receives), comment lines
  # excluded: init.sh's header spells the URL inside the `git subtree add`
  # line a human copy-pastes before any of this code exists, and that one
  # is prose, not a default something resolves. A second live literal is a
  # value that can go stale on its own -- which is what "one definition"
  # has to mean to be worth anything.
  run bash -c "
    grep -rnF 'ycpss91255-docker/base' /source/dist --include='*.sh' \
      | grep -vE ':[0-9]+:[[:space:]]*#' \
      | cut -d: -f1 | sort -u
  "
  assert_success
  assert_output "${UPSTREAM_SH}"
}

@test "upgrade.sh defaults TEMPLATE_REMOTE to the shared constant (#895)" {
  run grep -nF 'TEMPLATE_REMOTE:-${BASE_UPSTREAM_REMOTE}' "${UPGRADE_SH}"
  assert_success
}

@test "init.sh defaults its version query to the shared constant (#895)" {
  run grep -nF 'TEMPLATE_REMOTE:-${BASE_UPSTREAM_REMOTE}' "${INIT_SH}"
  assert_success
}

@test "check-base-version.sh defaults BASE_REPO to the shared constant (#895)" {
  run grep -nF 'BASE_REPO:-${BASE_UPSTREAM_SLUG}' "${MONITOR_SH}"
  assert_success
}

@test "check-base-version.sh still resolves its default with no override set (#895)" {
  # The constant arrives by sourcing a sibling file, which is a new way for
  # this script to fail: it runs from a generated workflow, not from a
  # wrapper that has already set the tree up.
  run bash -c "
    source '${MONITOR_SH}'
    printf '%s\n' \"\${BASE_REPO}\"
  "
  assert_success
  assert_output "ycpss91255-docker/base"
}

@test "a caller's TEMPLATE_REMOTE still wins over the shared default (#895)" {
  # The seam that makes SSH / a private fork possible is the point of the
  # variable; hoisting the default must not close it.
  run bash -c "
    TEMPLATE_REMOTE='git@github.com:someone/base.git' bash -c '
      source \"${UPSTREAM_SH}\"
      printf \"%s\n\" \"\${TEMPLATE_REMOTE:-\${BASE_UPSTREAM_REMOTE}}\"'
  "
  assert_success
  assert_output "git@github.com:someone/base.git"
}
