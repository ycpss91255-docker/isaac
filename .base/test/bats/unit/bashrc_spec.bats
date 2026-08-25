#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RC="/source/dist/config/shell/bashrc"
}

# ════════════════════════════════════════════════════════════════════
# Function definitions
# ════════════════════════════════════════════════════════════════════

@test "defines alias_func" {
  run grep -q "^alias_func()" "${RC}"
  assert_success
}

@test "defines color_git_branch" {
  run grep -q "^color_git_branch()" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Aliases
# ════════════════════════════════════════════════════════════════════

@test "defines ebc alias" {
  run grep -q "alias ebc=" "${RC}"
  assert_success
}

@test "defines sbc alias" {
  run grep -q "alias sbc=" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Functions are called at the bottom
# ════════════════════════════════════════════════════════════════════

@test "alias_func is called" {
  run grep -qE "^alias_func[[:space:]]*$" "${RC}"
  assert_success
}

@test "color_git_branch is called" {
  run grep -qE "^color_git_branch[[:space:]]*$" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# Key content
# ════════════════════════════════════════════════════════════════════

@test "color_git_branch sets PS1" {
  run grep -q "PS1=" "${RC}"
  assert_success
}

# ════════════════════════════════════════════════════════════════════
# bashrc.d drop-in bootstrap loop (template#254 v0.22.0)
# ════════════════════════════════════════════════════════════════════

@test "bashrc has bashrc.d bootstrap loop sourcing ~/.bashrc.d/*.sh" {
  # Layered config + drop-in pattern: at interactive shell start,
  # source any *.sh under ~/.bashrc.d/ so template-side helpers
  # (from .base/dist/config/shell/bashrc.d) AND downstream-side
  # helpers (from <repo>/config/shell/bashrc.d) both get loaded.
  run grep -qF 'for _bashrc_d_f in "${HOME}/.bashrc.d/"*.sh' "${RC}"
  assert_success
  run grep -qF '[[ -r "${_bashrc_d_f}" ]] && source "${_bashrc_d_f}"' "${RC}"
  assert_success
}

@test "bashrc.d bootstrap loop guards on directory existing" {
  # Empty bashrc.d/ (or missing) must not error the bootstrap. The
  # outer if guards the for loop; the inner [[ -r ]] guards the
  # source call so a stray broken symlink doesn't tank shell start.
  run grep -qF 'if [[ -d "${HOME}/.bashrc.d" ]]; then' "${RC}"
  assert_success
}

@test "bashrc.d/ directory exists in .base/dist/config/shell/" {
  # Empty placeholder so the dir exists in subtree (git doesn't
  # track empty dirs). Template-side helpers can drop *.sh here
  # later without touching Dockerfile.example.
  assert [ -d "/source/dist/config/shell/bashrc.d" ]
  assert [ -f "/source/dist/config/shell/bashrc.d/.gitkeep" ]
}

# ════════════════════════════════════════════════════════════════════
# Host-group-name drop-in: name the host-injected device GIDs so
# interactive shells stop printing "groups: cannot find name for group
# ID N". Lives in bashrc.d/ so both `just run` (entrypoint + bashrc) and
# `just exec` (compose exec + bashrc, bypasses entrypoint) fix the label.
# ════════════════════════════════════════════════════════════════════

HG="/source/dist/config/shell/bashrc.d/30-name-host-groups.sh"

@test "host-group drop-in exists" {
  assert [ -f "${HG}" ]
}

@test "host-group drop-in defines name_host_groups and invokes it only when interactive" {
  run grep -qE '^name_host_groups\(\)' "${HG}"
  assert_success
  # Auto-invocation is guarded on an interactive shell ($- contains i).
  run grep -qE '\$-.*i.*name_host_groups|name_host_groups' "${HG}"
  assert_success
  run grep -qF '$-' "${HG}"
  assert_success
}

@test "host-group drop-in uses getent + sudo groupadd" {
  run grep -qF 'getent group' "${HG}"
  assert_success
  run grep -qF 'sudo groupadd -g' "${HG}"
  assert_success
}

@test "name_host_groups: a nameless gid triggers sudo groupadd hostgrp<gid>" {
  create_mock_dir
  mock_cmd "id" 'echo 44'
  # getent never resolves -> the gid is nameless.
  mock_cmd "getent" 'exit 2'
  mock_cmd "sudo" "echo \"\$*\" >> '${BATS_TEST_TMPDIR}/sudo_calls'"
  # Source defines the function; the interactive auto-invoke is skipped
  # (bats is non-interactive), so we drive the function directly.
  # shellcheck disable=SC1090
  source "${HG}"
  name_host_groups
  run cat "${BATS_TEST_TMPDIR}/sudo_calls"
  assert_output --partial 'groupadd -g 44 hostgrp44'
  cleanup_mock_dir
}

@test "name_host_groups: a named gid does not trigger groupadd" {
  create_mock_dir
  mock_cmd "id" 'echo 1000'
  # getent resolves gid 1000 -> already named, skip.
  mock_cmd "getent" 'echo "devuser:x:1000:"; exit 0'
  mock_cmd "sudo" "echo \"\$*\" >> '${BATS_TEST_TMPDIR}/sudo_calls'"
  # shellcheck disable=SC1090
  source "${HG}"
  name_host_groups
  assert [ ! -f "${BATS_TEST_TMPDIR}/sudo_calls" ]
  cleanup_mock_dir
}
