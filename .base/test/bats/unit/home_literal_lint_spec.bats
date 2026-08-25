#!/usr/bin/env bats
#
# Unit tests for script/test/drivers/home_literal.sh -- the "no hardcoded
# home path in the shipped image tree" lint.
#
# `ENV HOME="/home/${USER_NAME}"` resolves at BUILD time, so a shipped
# Dockerfile / entrypoint that spells a CONCRETE username into a home path
# breaks the moment the image is rebuilt (or `docker save`+`load`'ed and run)
# under a different USER_NAME: the path points at a different, empty home
# directory. The parameterised `${HOME}` / `${USER_NAME}` forms survive that,
# and an absolute /opt path sidesteps the indirection entirely
# (ADR-00000024).
#
# Detection runs against a controlled temp REPO_ROOT so the spec is
# independent of the live tree's contents; a final case drives the REAL
# shipped tree to prove it passes today. Shape mirrors
# stale_setup_conf_lint_spec.bats.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source the driver in isolation (not test.sh, which makes REPO_ROOT
  # readonly). The driver references the REPO_ROOT global + _die; provide
  # both so the function runs against a controlled scratch tree.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/_lib.sh
  _die() { local _ev="${1}"; shift; _log_err ci "${_ev}" "display=$*"; return 1; }
  # shellcheck disable=SC1091
  source /source/script/test/drivers/home_literal.sh

  SCRATCH="$(mktemp -d)"
  mkdir -p "${SCRATCH}/dist/dockerfile" \
    "${SCRATCH}/dist/script/docker/runtime" \
    "${SCRATCH}/dockerfile"
  REPO_ROOT="${SCRATCH}"

  # The literal the lint hunts for, assembled at runtime so this spec file
  # never carries a concrete home path as a plain token of its own.
  LITERAL="/home/user"
}

teardown() {
  [[ -n "${SCRATCH:-}" ]] && rm -rf "${SCRATCH}"
}

# _write <relative-path> <line>... -- create a shipped-tree fixture file.
_write() {
  local _rel="${1}"; shift
  mkdir -p "$(dirname "${SCRATCH}/${_rel}")"
  printf '%s\n' "$@" > "${SCRATCH}/${_rel}"
}

# ════════════════════════════════════════════════════════════════════
# _run_home_literal: violations
# ════════════════════════════════════════════════════════════════════

@test "_run_home_literal: FAILS on a hardcoded home path in the shipped Dockerfile, naming file and line (#799)" {
  _write "dist/dockerfile/Dockerfile" \
    'FROM ubuntu:24.04' \
    "WORKDIR ${LITERAL}/work"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/dockerfile/Dockerfile:2"* ]]
}

@test "_run_home_literal: FAILS on a hardcoded home path in a runtime entrypoint (#799)" {
  _write "dist/script/docker/runtime/entrypoint.sh" \
    '#!/usr/bin/env bash' \
    ". ${LITERAL}/some_ws/install/setup.bash"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"entrypoint.sh:2"* ]]
}

@test "_run_home_literal: FAILS on a hardcoded home path in a non-.sh in-image config file (#799)" {
  # The image-baked surface is not all shell scripts: config/shell/bashrc
  # has no extension and is COPY'd into every devel image.
  _write "dist/config/shell/bashrc" \
    "source ${LITERAL}/some_ws/install/setup.bash"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist/config/shell/bashrc:1"* ]]
}

@test "_run_home_literal: FAILS on a hardcoded home path inside a comment too (#799)" {
  # A comment is documentation a downstream author copies; a concrete
  # username there teaches the exact anti-pattern the lint exists to stop.
  _write "dist/script/docker/runtime/entrypoint.sh" \
    "# sources ${LITERAL}/some_ws at start"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"entrypoint.sh:1"* ]]
}

@test "_run_home_literal: names the offending literal in the failure message (#799)" {
  _write "dist/dockerfile/Dockerfile" "WORKDIR ${LITERAL}/work"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"${LITERAL}"* ]]
}

@test "_run_home_literal: points at the /opt convention in the failure message (#799)" {
  # The message has to carry the fix, not just the finding: parameterise the
  # home path, or better, bake the artifact at an absolute /opt path.
  _write "dist/dockerfile/Dockerfile" "WORKDIR ${LITERAL}/work"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"/opt"* ]]
  [[ "${output}" == *"USER_NAME"* ]]
}

@test "_run_home_literal: scans the repo-root dockerfile/ tree too (#799)" {
  _write "dockerfile/Dockerfile.test-tools" \
    'FROM alpine:3.20' \
    "WORKDIR ${LITERAL}/build"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dockerfile/Dockerfile.test-tools:2"* ]]
}

@test "_run_home_literal: FAILS on a literal AFTER an allow-end (region does not leak) (#799)" {
  _write "dist/script/docker/runtime/entrypoint.sh" \
    "# ${_HOME_LITERAL_ALLOW_BEGIN} narrative" \
    "# the default user's home is ${LITERAL}" \
    "# ${_HOME_LITERAL_ALLOW_END}" \
    "WORKDIR ${LITERAL}/work"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"entrypoint.sh:4"* ]]
  [[ "${output}" != *"entrypoint.sh:2"* ]]
}

@test "_run_home_literal: FAILS on an unterminated allow-begin region (#799)" {
  _write "dist/script/docker/runtime/entrypoint.sh" \
    "# ${_HOME_LITERAL_ALLOW_BEGIN} narrative" \
    "# the default user's home is ${LITERAL}"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unterminated"* ]]
}

@test "_run_home_literal: FAILS on an allow-end with no matching allow-begin (#799)" {
  _write "dist/script/docker/runtime/entrypoint.sh" \
    '#!/usr/bin/env bash' \
    "# ${_HOME_LITERAL_ALLOW_END}"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"unmatched"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_home_literal: accepted forms
# ════════════════════════════════════════════════════════════════════

@test "_run_home_literal: PASSES the \${USER_NAME} build-arg form (#799)" {
  _write "dist/dockerfile/Dockerfile" \
    'ENV HOME="/home/${USER_NAME}"' \
    'WORKDIR "${HOME}/work"'
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_home_literal: PASSES the backslash-escaped \\\${USER_NAME} form (#799)" {
  # Shell code that must EMIT the literal '${USER_NAME}' (setup.conf mount
  # rewriting) escapes the dollar; that is still parameterised.
  _write "dist/script/docker/lib/setup_detect.sh" \
    '_form="\${WS_PATH}:/home/\${USER_NAME}/work"'
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_home_literal: PASSES the angle-bracket placeholder form (#799)" {
  # Prose that talks ABOUT the shape uses a placeholder, not a name; only a
  # concrete username is a defect.
  _write "dist/script/docker/runtime/entrypoint.sh" \
    '# a different USER_NAME points at an empty /home/<other>/ tree'
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_home_literal: PASSES an absolute /opt artifact path (#799)" {
  _write "dist/script/docker/runtime/entrypoint.sh" \
    '. /opt/some_ws/install/setup.bash --'
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_home_literal: EXEMPTS a literal inside an allow-begin/allow-end region (#799)" {
  _write "dist/script/docker/lib/dockerfile_migrate.sh" \
    "# ${_HOME_LITERAL_ALLOW_BEGIN} names the useradd default home" \
    "# the default user's home is ${LITERAL}" \
    "# ${_HOME_LITERAL_ALLOW_END}"
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

@test "_run_home_literal: ignores files OUTSIDE the shipped tree (#799)" {
  # doc/ and test/ legitimately spell concrete home paths (fixtures,
  # failure-mode narratives); only what ships into an image is scanned.
  mkdir -p "${SCRATCH}/doc"
  printf '%s\n' "the workspace used to live at ${LITERAL}/work" \
    > "${SCRATCH}/doc/notes.md"
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_home_literal: scan-root guard
# ════════════════════════════════════════════════════════════════════

@test "_run_home_literal: FAILS when a scan root is missing (no vacuous pass) (#799)" {
  # An empty find root passes vacuously, silently disabling the lint if the
  # shipped tree is ever relocated. Fail loudly on a missing scan root.
  rm -rf "${SCRATCH}/dist"
  run _run_home_literal
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"dist"* ]]
}

# ════════════════════════════════════════════════════════════════════
# _run_home_literal: real tree guard
# ════════════════════════════════════════════════════════════════════

@test "_run_home_literal: the REAL shipped tree passes today (#799)" {
  REPO_ROOT="/source"
  run _run_home_literal
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"clean"* ]]
}
