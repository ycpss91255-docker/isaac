#!/usr/bin/env bats

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  RC="/source/config/shell/bashrc"
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
  # (from .base/config/shell/bashrc.d/) AND downstream-side
  # helpers (from <repo>/config/shell/bashrc.d/) both get loaded.
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

@test "bashrc.d/ directory exists in .base/config/shell/" {
  # Empty placeholder so the dir exists in subtree (git doesn't
  # track empty dirs). Template-side helpers can drop *.sh here
  # later without touching Dockerfile.example.
  assert [ -d "/source/config/shell/bashrc.d" ]
  assert [ -f "/source/config/shell/bashrc.d/.gitkeep" ]
}
