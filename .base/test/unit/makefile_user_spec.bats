#!/usr/bin/env bats
#
# Unit tests for the user-facing Makefile at .base/script/docker/Makefile
# (symlinked from downstream repo root). Each named wrapper target is a thin
# 1:1 forward to ./script/<name>.sh, with positional sub-cmd args carried
# via $(filter-out $@,$(MAKECMDGOALS)) and flags requiring the `--`
# separator. A `%:` catch-all no-ops the forwarded tokens so Make does not
# error on `make build test`. RFC #330.
#
# Strategy: each test sandboxes a sample repo with the Makefile symlinked
# at root, the underlying wrapper scripts stubbed under script/, and the
# upgrade script stubbed under .base/. Each stub appends its invocation
# (target name + received args) to ${TMP_REPO}/.invocation_log so tests
# can assert exactly what the underlying wrapper would have been called
# with.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TMP_REPO="$(mktemp -d)"
  export TMP_REPO

  mkdir -p "${TMP_REPO}/.base/script/docker"
  mkdir -p "${TMP_REPO}/script"

  # Source under test: the user-facing Makefile, copied into the
  # sandbox in the same relative location that init.sh would symlink.
  cp /source/script/docker/Makefile "${TMP_REPO}/.base/script/docker/Makefile"
  ln -s ".base/script/docker/Makefile" "${TMP_REPO}/Makefile"

  # Stub recorders: each wrapper logs `<name> <args...>` so tests can
  # check both the target script and the forwarded argv.
  for _name in build run exec stop prune setup setup_tui; do
    cat > "${TMP_REPO}/script/${_name}.sh" <<EOS
#!/usr/bin/env bash
printf '${_name}'
for _arg in "\$@"; do printf ' %s' "\${_arg}"; done
printf '\n'
EOS
    chmod +x "${TMP_REPO}/script/${_name}.sh"
  done

  cat > "${TMP_REPO}/.base/upgrade.sh" <<'EOS'
#!/usr/bin/env bash
printf 'upgrade'
for _arg in "$@"; do printf ' %s' "${_arg}"; done
printf '\n'
EOS
  chmod +x "${TMP_REPO}/.base/upgrade.sh"

  cd "${TMP_REPO}"
}

teardown() {
  rm -rf "${TMP_REPO}"
}

# ════════════════════════════════════════════════════════════════════
# .DEFAULT_GOAL + help
# ════════════════════════════════════════════════════════════════════

@test "bare \`make\` prints help (.DEFAULT_GOAL := help)" {
  run make
  assert_success
  # help target greps for `:.*##` lines and pretty-prints them; the
  # exact ANSI escapes are fragile so we just check a known target
  # name appears, which proves the help recipe ran rather than build.
  assert_line --partial "build"
  assert_line --partial "help"
  # Must NOT have invoked any wrapper.
  refute_line --regexp '^build( |$)'
}

@test "\`make help\` lists the 10 user-facing targets" {
  run make help
  assert_success
  for _target in build run exec stop prune setup setup-tui upgrade upgrade-check help; do
    assert_line --partial "${_target}"
  done
}

@test "\`make help\` does NOT list removed sub-cmd targets (test / runtime / run-detach)" {
  run make help
  assert_success
  refute_line --regexp '^[[:space:]]+test[[:space:]]'
  refute_line --regexp '^[[:space:]]+runtime[[:space:]]'
  refute_line --regexp '^[[:space:]]+run-detach[[:space:]]'
}

# ════════════════════════════════════════════════════════════════════
# 1:1 wrapper invocations (bare target → ./script/<name>.sh)
# ════════════════════════════════════════════════════════════════════

@test "\`make build\` invokes ./script/build.sh with no args" {
  run make build
  assert_success
  assert_line "build"
}

@test "\`make run\` invokes ./script/run.sh with no args" {
  run make run
  assert_success
  assert_line "run"
}

@test "\`make exec\` invokes ./script/exec.sh with no args" {
  run make exec
  assert_success
  assert_line "exec"
}

@test "\`make stop\` invokes ./script/stop.sh with no args" {
  run make stop
  assert_success
  assert_line "stop"
}

@test "\`make prune\` invokes ./script/prune.sh with no args" {
  run make prune
  assert_success
  assert_line "prune"
}

@test "\`make setup\` invokes ./script/setup.sh with no args" {
  run make setup
  assert_success
  assert_line "setup"
}

@test "\`make setup-tui\` invokes ./script/setup_tui.sh with no args" {
  run make setup-tui
  assert_success
  assert_line "setup_tui"
}

@test "\`make upgrade\` invokes ./.base/upgrade.sh with no args" {
  run make upgrade
  assert_success
  assert_line "upgrade"
}

@test "\`make upgrade-check\` invokes ./.base/upgrade.sh --check" {
  run make upgrade-check
  # upgrade.sh --check returns 1 when an update is available; the
  # Makefile recipe swallows that as success via `|| [ $? -eq 1 ]`.
  assert_success
  assert_line "upgrade --check"
}

# ════════════════════════════════════════════════════════════════════
# Positional sub-cmd forwarding (no `--` required)
# ════════════════════════════════════════════════════════════════════

@test "\`make build test\` forwards 'test' to ./script/build.sh" {
  run make build test
  assert_success
  assert_line "build test"
}

@test "\`make build runtime\` forwards 'runtime' to ./script/build.sh" {
  run make build runtime
  assert_success
  assert_line "build runtime"
}

@test "\`make upgrade v0.30.0\` forwards the version arg to ./.base/upgrade.sh" {
  run make upgrade v0.30.0
  assert_success
  assert_line "upgrade v0.30.0"
}

@test "\`make setup foo\` forwards 'foo' to ./script/setup.sh" {
  run make setup foo
  assert_success
  assert_line "setup foo"
}

# ════════════════════════════════════════════════════════════════════
# `--` separator + flag forwarding
# ════════════════════════════════════════════════════════════════════

@test "\`make build -- --no-cache\` forwards the flag to ./script/build.sh" {
  run make build -- --no-cache
  assert_success
  assert_line "build --no-cache"
}

@test "\`make build -- --no-cache test\` forwards flag + sub-cmd" {
  run make build -- --no-cache test
  assert_success
  assert_line "build --no-cache test"
}

@test "\`make run -- -d\` forwards -d to ./script/run.sh (replaces removed run-detach)" {
  run make run -- -d
  assert_success
  assert_line "run -d"
}

@test "\`make exec -- -t bats-src bash\` forwards -t / positional bash" {
  run make exec -- -t bats-src bash
  assert_success
  assert_line "exec -t bats-src bash"
}

# ════════════════════════════════════════════════════════════════════
# Catch-all `%:` rule (silent no-op for unknown positional tokens)
# ════════════════════════════════════════════════════════════════════

@test "\`make foo\` is a silent no-op (catch-all, does not error)" {
  # No target named foo → catch-all matches → @: runs → exit 0 with
  # zero output. Trade-off for sub-cmd forwarding UX.
  run make foo
  assert_success
  assert_output ""
}

@test "\`make build foo bar\` forwards 'foo bar' to ./script/build.sh (foo+bar also no-op via catch-all)" {
  run make build foo bar
  assert_success
  assert_line "build foo bar"
}

@test "\`make\` without targets does NOT invoke wrappers" {
  # Companion to the .DEFAULT_GOAL test — make sure nothing recorded.
  run make
  assert_success
  refute_line --regexp '^build( |$)'
  refute_line --regexp '^run( |$)'
  refute_line --regexp '^upgrade( |$)'
}
