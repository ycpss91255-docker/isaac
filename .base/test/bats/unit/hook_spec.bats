#!/usr/bin/env bats
#
# Unit tests for lib/hook.sh — wrapper pre/post hook helpers.
#
# The helper looks for executable scripts under
# ${FILE_PATH}/script/hooks/{pre,post}/<wrapper>.sh and runs them with
# the wrapper's "$@". Folder split + strict executable check + dry-run
# skip + pre-abort / post-strict semantics are all part of the
# observable behaviour these tests pin.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # hook.sh emits its not-executable error via _log_err (lib/log.sh),
  # which at runtime is always sourced before hook.sh through _lib.sh.
  # Source it here so the helper is present in isolation too.
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/log.sh
  # shellcheck disable=SC1091
  source /source/dist/script/docker/lib/hook.sh

  TMP_DIR="$(mktemp -d)"
  FILE_PATH="${TMP_DIR}"
  export FILE_PATH
  mkdir -p "${FILE_PATH}/script/hooks/pre" "${FILE_PATH}/script/hooks/post"
  unset DRY_RUN
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# Cycle 1: tracer — no hook file present means silent no-op
# ════════════════════════════════════════════════════════════════════

@test "_run_pre_hook: returns success when no hook file present (#440)" {
  run _run_pre_hook run
  assert_success
  refute_output --partial "hook"
}

# ════════════════════════════════════════════════════════════════════
# Cycle 2: hook present + executable + exits 0 -> runs, args forwarded
# ════════════════════════════════════════════════════════════════════

@test "_run_pre_hook: present + +x + exit 0 -> runs and forwards args (#440)" {
  cat > "${FILE_PATH}/script/hooks/pre/run.sh" <<'HOOK'
#!/usr/bin/env bash
printf 'pre-run got:'
for a in "$@"; do printf ' %s' "${a}"; done
printf '\n'
HOOK
  chmod +x "${FILE_PATH}/script/hooks/pre/run.sh"
  run _run_pre_hook run -t devel bash
  assert_success
  assert_output "pre-run got: -t devel bash"
}

# ════════════════════════════════════════════════════════════════════
# Cycle 3: pre-hook non-zero -> propagates to caller (caller does `|| exit $?`)
# ════════════════════════════════════════════════════════════════════

@test "_run_pre_hook: hook exit 7 -> helper returns 7 for caller to abort (#440)" {
  cat > "${FILE_PATH}/script/hooks/pre/run.sh" <<'HOOK'
#!/usr/bin/env bash
exit 7
HOOK
  chmod +x "${FILE_PATH}/script/hooks/pre/run.sh"
  run _run_pre_hook run
  [[ "${status}" -eq 7 ]] || { echo "expected 7, got ${status}"; return 1; }
}

# ════════════════════════════════════════════════════════════════════
# Cycle 4: post-hook non-zero -> helper returns rc; caller decides
# ════════════════════════════════════════════════════════════════════

@test "_run_post_hook: hook exit 11 -> helper returns 11 (#440)" {
  cat > "${FILE_PATH}/script/hooks/post/run.sh" <<'HOOK'
#!/usr/bin/env bash
exit 11
HOOK
  chmod +x "${FILE_PATH}/script/hooks/post/run.sh"
  run _run_post_hook run
  [[ "${status}" -eq 11 ]] || { echo "expected 11, got ${status}"; return 1; }
}

# ════════════════════════════════════════════════════════════════════
# Cycle 5: hook file present but NOT executable -> hard fail
# ════════════════════════════════════════════════════════════════════

@test "_run_pre_hook: present but not executable -> hard fail with clear msg (#440)" {
  cat > "${FILE_PATH}/script/hooks/pre/run.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
  # explicitly NOT chmod +x
  run _run_pre_hook run
  assert_failure
  assert_output --partial "not executable"
  assert_output --partial "chmod +x"
}

@test "_run_post_hook: present but not executable -> hard fail with clear msg (#440)" {
  cat > "${FILE_PATH}/script/hooks/post/run.sh" <<'HOOK'
#!/usr/bin/env bash
exit 0
HOOK
  run _run_post_hook run
  assert_failure
  assert_output --partial "not executable"
}

# ════════════════════════════════════════════════════════════════════
# Cycle 6: DRY_RUN=true -> both helpers silently skip even when hook present + +x
# ════════════════════════════════════════════════════════════════════

@test "_run_pre_hook: DRY_RUN=true -> hook skipped silently (#440)" {
  cat > "${FILE_PATH}/script/hooks/pre/run.sh" <<'HOOK'
#!/usr/bin/env bash
echo "SHOULD-NOT-RUN"
exit 1
HOOK
  chmod +x "${FILE_PATH}/script/hooks/pre/run.sh"
  DRY_RUN=true run _run_pre_hook run
  assert_success
  refute_output --partial "SHOULD-NOT-RUN"
}

@test "_run_post_hook: DRY_RUN=true -> hook skipped silently (#440)" {
  cat > "${FILE_PATH}/script/hooks/post/run.sh" <<'HOOK'
#!/usr/bin/env bash
echo "SHOULD-NOT-RUN"
exit 1
HOOK
  chmod +x "${FILE_PATH}/script/hooks/post/run.sh"
  DRY_RUN=true run _run_post_hook run
  assert_success
  refute_output --partial "SHOULD-NOT-RUN"
}
