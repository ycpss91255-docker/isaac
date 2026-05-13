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
