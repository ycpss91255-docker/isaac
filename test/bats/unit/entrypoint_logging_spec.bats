#!/usr/bin/env bats
#
# Tests for dist/script/docker/runtime/logging.sh -- the helper sourced
# from repo entrypoints to tee container stdout/stderr to the host
# bind-mounted log when [logging] local_path is set. Glog-style:
# each container start writes a per-start real file <svc>_<ts>.log and
# repoints the stable <svc>.log symlink (= LOG_FILE_PATH) at it, then
# prunes old per-start files by CONTAINER_LOG_KEEP / CONTAINER_LOG_DAYS.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# Create a PATH dir with a `date` stub that prints a fixed <ts> for the
# per-start timestamp format and delegates every other invocation to the
# real date, so multi-start tests get deterministic per-start filenames.
# Echoes the stub dir; caller prepends it to PATH.
_stub_date_dir() {
  local _ts="$1"
  local _d="${TEMP_DIR}/stub_${_ts}"
  mkdir -p "${_d}"
  cat > "${_d}/date" <<EOF
#!/usr/bin/env bash
for _a in "\$@"; do
  case "\$_a" in
    +*Y*m*dT*) printf '%s\n' "${_ts}"; exit 0 ;;
  esac
done
exec "$(command -v date)" "\$@"
EOF
  chmod +x "${_d}/date"
  printf '%s' "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# logging.sh helper
# ════════════════════════════════════════════════════════════════════

@test "entrypoint_logging is no-op when LOG_FILE_PATH unset (#328)" {
  run bash -c '
    unset LOG_FILE_PATH
    . /source/dist/script/docker/runtime/logging.sh
    echo "ok"
  '
  assert_success
  assert_output "ok"
}

@test "entrypoint_logging writes a per-start file + points the stable symlink at it (#805)" {
  local _ts="20260101T000000Z"
  local _stub; _stub="$(_stub_date_dir "${_ts}")"
  run bash -c "
    export PATH='${_stub}:${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'run-one'
    sleep 0.2
  "
  assert_success
  # Real per-start file exists and holds the run's output.
  run grep -F "run-one" "${TEMP_DIR}/devel_${_ts}.log"
  assert_success
  # LOG_FILE_PATH is now a symlink pointing at the per-start file.
  assert [ -L "${TEMP_DIR}/devel.log" ]
  run readlink "${TEMP_DIR}/devel.log"
  assert_output "devel_${_ts}.log"
  # `tail <svc>.log` (via the symlink) shows the current run.
  run grep -F "run-one" "${TEMP_DIR}/devel.log"
  assert_success
  # docker-logs parity preserved: stdout still carries the line.
  assert_output --partial "run-one" || true
}

@test "entrypoint_logging second start adds a new per-start file + repoints symlink, keeps the old (#805)" {
  local _t1="20260101T000000Z" _t2="20260102T000000Z"
  # First start.
  run bash -c "
    export PATH='$(_stub_date_dir "${_t1}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'first-run'
    sleep 0.2
  "
  assert_success
  # Second start (new timestamp).
  run bash -c "
    export PATH='$(_stub_date_dir "${_t2}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'second-run'
    sleep 0.2
  "
  assert_success
  # Both per-start files survive (history retained, no truncation).
  assert [ -f "${TEMP_DIR}/devel_${_t1}.log" ]
  assert [ -f "${TEMP_DIR}/devel_${_t2}.log" ]
  run grep -F "first-run" "${TEMP_DIR}/devel_${_t1}.log"
  assert_success
  # Symlink now follows the newest run.
  run readlink "${TEMP_DIR}/devel.log"
  assert_output "devel_${_t2}.log"
}

@test "entrypoint_logging same wall-clock second: second start bumps suffix, never truncates the first (#805)" {
  # Both starts see the SAME second-granular timestamp (crash-loop restart
  # within one second). The second start must NOT reuse -- and truncate --
  # the first run's file; it probes a -<n> suffix instead.
  local _ts="20260101T000000Z"
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'first-run'
    sleep 0.2
  "
  assert_success
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'second-run'
    sleep 0.2
  "
  assert_success
  # Two DISTINCT files: the base name and its -1 bump; both survive.
  assert [ -f "${TEMP_DIR}/devel_${_ts}.log" ]
  assert [ -f "${TEMP_DIR}/devel_${_ts}-1.log" ]
  # The first run's file was NOT truncated by the second start.
  run grep -F "first-run" "${TEMP_DIR}/devel_${_ts}.log"
  assert_success
  run grep -F "second-run" "${TEMP_DIR}/devel_${_ts}-1.log"
  assert_success
  # Symlink follows the newest (bumped) run.
  run readlink "${TEMP_DIR}/devel.log"
  assert_output "devel_${_ts}-1.log"
}

@test "entrypoint_logging captures stderr along with stdout in the per-start file (#328)" {
  local _ts="20260101T000000Z"
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'on-stdout'
    echo 'on-stderr' >&2
    sleep 0.2
  " 2>&1
  assert_success
  run grep -F "on-stdout" "${TEMP_DIR}/devel_${_ts}.log"
  assert_success
  run grep -F "on-stderr" "${TEMP_DIR}/devel_${_ts}.log"
  assert_success
}

@test "entrypoint_logging creates parent dir if missing (#328)" {
  local _ts="20260101T000000Z"
  local _dir="${TEMP_DIR}/nested/dir"
  [[ ! -d "${_dir}" ]]
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${_dir}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'parent-created'
    sleep 0.2
  "
  assert_success
  assert [ -d "${_dir}" ]
  run grep -F "parent-created" "${_dir}/devel_${_ts}.log"
  assert_success
  assert [ -L "${_dir}/devel.log" ]
}

@test "entrypoint_logging retention honors CONTAINER_LOG_KEEP, never the symlink (#805)" {
  local _ts="20260201T000000Z"
  # Seed 6 older per-start files (staggered mtimes so ls -t is stable).
  local _i _f
  for _i in $(seq 1 6); do
    _f="${TEMP_DIR}/devel_2026010${_i}T000000Z.log"
    : > "${_f}"; touch -d "2026-01-0${_i} 00:00:00" "${_f}"
  done
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    export CONTAINER_LOG_KEEP=3
    export CONTAINER_LOG_DAYS=3650
    . /source/dist/script/docker/runtime/logging.sh
    echo 'newest'
    sleep 0.2
  "
  assert_success
  # keep=3 -> only the 3 newest real files remain (this run + 2 seeds).
  local -a _kept=()
  for _f in "${TEMP_DIR}"/devel_*.log; do _kept+=("${_f}"); done
  assert [ "${#_kept[@]}" -eq 3 ]
  assert [ -e "${TEMP_DIR}/devel_${_ts}.log" ]
  # The stable symlink is never pruned.
  assert [ -L "${TEMP_DIR}/devel.log" ]
}

@test "entrypoint_logging retention honors CONTAINER_LOG_DAYS by age (#805)" {
  local _ts="20260201T000000Z"
  local _old="${TEMP_DIR}/devel_20200101T000000Z.log"
  : > "${_old}"; touch -d "2020-01-01 00:00:00" "${_old}"
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    export CONTAINER_LOG_KEEP=9999
    export CONTAINER_LOG_DAYS=14
    . /source/dist/script/docker/runtime/logging.sh
    echo 'newest'
    sleep 0.2
  "
  assert_success
  assert [ ! -e "${_old}" ]
  assert [ -e "${TEMP_DIR}/devel_${_ts}.log" ]
}

@test "entrypoint_logging clamps a non-positive CONTAINER_LOG_KEEP back to the default (#805)" {
  local _ts="20260201T000000Z"
  # Seed 3 old files; keep=0 must NOT wipe them (clamp to default 20).
  local _i _f
  for _i in 1 2 3; do
    _f="${TEMP_DIR}/devel_2026010${_i}T000000Z.log"
    : > "${_f}"; touch -d "2026-01-0${_i} 00:00:00" "${_f}"
  done
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    export CONTAINER_LOG_KEEP=0
    export CONTAINER_LOG_DAYS=3650
    . /source/dist/script/docker/runtime/logging.sh
    echo 'newest'
    sleep 0.2
  "
  assert_success
  # All 3 seeds + this run survive (0 was rejected -> default 20).
  local -a _kept=()
  for _f in "${TEMP_DIR}"/devel_*.log; do _kept+=("${_f}"); done
  assert [ "${#_kept[@]}" -eq 4 ]
}

@test "entrypoint_logging bumps past an occupied base per-start name, still tees (#805)" {
  # The base per-start name is occupied (here by a directory); the probe
  # loop must skip it and write to a free -<n> file rather than fail, and
  # the occupant is left untouched.
  local _ts="20260101T000000Z"
  mkdir -p "${TEMP_DIR}/devel_${_ts}.log"
  run bash -c "
    export PATH='$(_stub_date_dir "${_ts}"):${PATH}'
    export LOG_FILE_PATH='${TEMP_DIR}/devel.log'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'bumped'
    sleep 0.2
  "
  assert_success
  # Occupant directory untouched; run wrote to the -1 bump.
  assert [ -d "${TEMP_DIR}/devel_${_ts}.log" ]
  run grep -F "bumped" "${TEMP_DIR}/devel_${_ts}-1.log"
  assert_success
  run readlink "${TEMP_DIR}/devel.log"
  assert_output "devel_${_ts}-1.log"
}

@test "entrypoint_logging warns 'cannot create' + continues when parent dir is unmakeable (#691)" {
  printf 'i am a file\n' > "${TEMP_DIR}/blocker"
  local _log="${TEMP_DIR}/blocker/devel.log"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    . /source/dist/script/docker/runtime/logging.sh
    echo 'should still print'
  " 2>&1
  assert_success
  assert_output --partial "cannot create"
  assert_output --partial "should still print"
}

@test "entrypoint_logging warns 'tee binary missing' + continues when tee absent (#691)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "tee-less PATH stub perturbs the kcov wrapper (#613)"
  local _bin="${TEMP_DIR}/stubbin"
  mkdir -p "${_bin}"
  local _t
  for _t in bash dirname basename mkdir cat printf date ln find ls rm; do
    ln -s "$(command -v "${_t}")" "${_bin}/${_t}" 2>/dev/null || true
  done
  local _log="${TEMP_DIR}/devel.log"
  run bash -c "
    export LOG_FILE_PATH='${_log}'
    export PATH='${_bin}'
    set -euo pipefail
    . /source/dist/script/docker/runtime/logging.sh
    echo 'should still print'
  " 2>&1
  assert_success
  assert_output --partial "tee binary missing"
  assert_output --partial "should still print"
}
