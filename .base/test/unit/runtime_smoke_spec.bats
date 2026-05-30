#!/usr/bin/env bats
#
# Unit tests for script/docker/runtime/smoke.sh -- the runtime-test
# smoke check that catches missing shared library dependencies (#430).

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  SMOKE_SH="/source/script/docker/runtime/smoke.sh"
  SCAN_ROOT="$(mktemp -d)"
  export SCAN_ROOT
}

teardown() {
  rm -rf "${SCAN_ROOT}"
}

# ── #430: ldd-based missing-dep detection ──────────────────────────

@test "smoke.sh exits non-zero when a .so has 'not found' dep (#430)" {
  # Create a fake .so file and a stub `ldd` that reports a missing dep.
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libbroken.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
# Simulate a missing shared lib for any input.
echo "    libmissing.so.1 => not found"
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_failure
  assert_output --partial "MISSING"
}

@test "smoke.sh exits 0 when scan root has no .so files (#430)" {
  # Empty directory — nothing to check, no failure.
  run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  assert_success
}

@test "smoke.sh exits 0 when scan root does not exist (#430)" {
  # Missing dir — non-fatal, just skipped (default has multiple roots).
  run bash "${SMOKE_SH}" "${SCAN_ROOT}/nonexistent"
  assert_success
}

@test "Dockerfile.example runtime-test default RUNTIME_SMOKE_CMD calls smoke.sh (#430)" {
  # Default should invoke the helper script, not just the old
  # 'whoami && bash --version' that missed libboost_regex (ros1_bridge#123).
  run grep -E '^# ARG RUNTIME_SMOKE_CMD=.*smoke\.sh' /source/dockerfile/Dockerfile.example
  assert_success
}

@test "Dockerfile.example commented runtime-test COPY brings smoke.sh into image (#430)" {
  run grep -F 'COPY' /source/dockerfile/Dockerfile.example
  # Find the runtime/smoke.sh COPY (commented in template; downstream uncomments)
  run grep -F '.base/script/docker/runtime/smoke.sh' /source/dockerfile/Dockerfile.example
  assert_success
}

@test "smoke.sh exits 0 when all .so files link cleanly (#430)" {
  mkdir -p "${SCAN_ROOT}/lib"
  : > "${SCAN_ROOT}/lib/libgood.so"
  local _stub_dir
  _stub_dir="$(mktemp -d)"
  cat > "${_stub_dir}/ldd" <<'EOS'
#!/usr/bin/env bash
echo "    libfoo.so => /usr/lib/libfoo.so (0x00007fff)"
EOS
  chmod +x "${_stub_dir}/ldd"
  PATH="${_stub_dir}:${PATH}" run bash "${SMOKE_SH}" "${SCAN_ROOT}"
  rm -rf "${_stub_dir}"
  assert_success
}
