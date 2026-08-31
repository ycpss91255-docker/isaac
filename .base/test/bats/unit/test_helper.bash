#!/usr/bin/env bash

# Standard bats libraries (installed via apt in CI container)
bats_load_library "bats-support"
bats_load_library "bats-assert"

# bats-mock: for stubbing system commands (id, uname, docker, dpkg-query)
# Installed via git in compose.yaml
load "${BATS_LIB_PATH}/bats-mock/stub"

# bash_test_helper (via git subtree):
#   git subtree add --prefix test/bash_test_helper \
#       https://github.com/ycpss91255/bash_test_helper main --squash
_BTH="${BATS_TEST_DIRNAME}/bash_test_helper/src"
if [[ -f "${_BTH}/test_helper.bash" ]]; then
    # shellcheck disable=SC1090
    source "${_BTH}/test_helper.bash"
fi
unset _BTH

# ── Test utilities ────────────────────────────────────────────────────────────

# Create a temporary mock directory prepended to PATH
# Usage: mock_cmd <cmd_name> <script_body>
# Example: mock_cmd "uname" 'echo "aarch64"'
create_mock_dir() {
    MOCK_DIR="$(mktemp -d)"
    export PATH="${MOCK_DIR}:${PATH}"
}

mock_cmd() {
    local _cmd="${1}"; shift
    local _body="${1}"
    printf '#!/bin/bash\n%s\n' "${_body}" > "${MOCK_DIR}/${_cmd}"
    chmod +x "${MOCK_DIR}/${_cmd}"
}

cleanup_mock_dir() {
    [[ -n "${MOCK_DIR:-}" ]] && rm -rf "${MOCK_DIR}"
}

# ── early-closing-reader shims ────────────────────────────────────────────────
#
# A pipeline into a reader that stops reading is a race. `grep -q` leaves on
# its first match, `head -n1` after one line; a writer still writing then takes
# SIGPIPE and exits 141, `pipefail` makes 141 the PIPELINE's status, and an
# `if` reads that as false -- so a SUCCESSFUL match is reported as "not found".
# The status is not lost, it is inverted.
#
# Whether the race is lost depends on the libc and the scheduler: the same
# pipeline lost it 0 times in 20000 iterations on the host (glibc, bash 5.1)
# and 6.4% of the time inside the alpine test-tools image (musl, coreutils 9.5,
# bash 5.2). Repetition is therefore worthless as evidence -- it is a coin the
# platform weights.
#
# These two helpers pin the losing interleaving instead, so a reintroduced
# pipeline fails on EVERY run. Code that reads the whole stream never execs an
# early-closing reader and never leaves a writer without one, so both shims are
# inert against it. Same technique as the ADR-numbering min/max regression in
# adr_numbering_spec.bats.
#
# Note for callers: bats' own `run` clears errexit, and a sourced function
# inherits the harness's options rather than its production script's. Where the
# defect needs `set -euo pipefail` to show, drive the code from a strict shell
# that is a script FILE, never `bash -c '...'` -- under kcov the xtrace PS4
# expands ${BASH_SOURCE}, which is EMPTY at the top level of a `bash -c`
# string, so `set -u` aborts the harness before the code under test runs.

# shim_early_closing_reader <dir> <name>...
#   Install each <name> into <dir> as a reader that exits 0 -- "I have my
#   match" -- WITHOUT reading a byte, so the write end of the pipe has no
#   reader left from the instant the pipeline starts. Models `head -n1` /
#   `grep -q` at their most impatient.
shim_early_closing_reader() {
    local _dir="${1}"; shift
    mkdir -p "${_dir}"
    local _name
    for _name in "$@"; do
        cat > "${_dir}/${_name}" << 'EOF'
#!/bin/sh
# A reader that already has what it needs: leave at once.
exit 0
EOF
        chmod +x "${_dir}/${_name}"
    done
}

# shim_late_writer <dir> <name> <early> <late>
#   Install <name> into <dir> as a writer that prints <early> immediately and
#   <late> only after a delay -- the losing side of the race every time.
#
#   <early> carries whatever the real reader is looking for, so a real
#   `grep -q` genuinely matches and genuinely leaves; the <late> write then
#   finds no reader. The late half runs under `exec` so the SIGPIPE becomes the
#   shim's OWN exit status instead of being swallowed by a trailing `exit 0`.
shim_late_writer() {
    local _dir="${1}" _name="${2}" _early="${3}" _late="${4}"
    mkdir -p "${_dir}"
    printf '%s\n' "${_early}" > "${_dir}/${_name}.early"
    printf '%s\n' "${_late}" > "${_dir}/${_name}.late"
    cat > "${_dir}/${_name}" << EOF
#!/bin/sh
cat "${_dir}/${_name}.early"
sleep 0.2
exec cat "${_dir}/${_name}.late"
EOF
    chmod +x "${_dir}/${_name}"
}
