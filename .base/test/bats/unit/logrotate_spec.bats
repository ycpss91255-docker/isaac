#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/runtime/logrotate.sh -- the shared
# glog-style rotate/symlink/prune primitives reused by BOTH the wrapper
# transcript (lib/transcript.sh) and the container-log tee
# (runtime/logging.sh). See ADR-00000021.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/runtime/logrotate.sh
  TMP_DIR="$(mktemp -d)"
}

teardown() { rm -rf "${TMP_DIR}"; }

# ── _logrotate_repoint ──────────────────────────────────────────────

@test "_logrotate_repoint: points the stable symlink at the newest real file (#805)" {
  local _real="${TMP_DIR}/svc_20260101T000000Z.log"
  printf 'run-1\n' > "${_real}"
  _logrotate_repoint "${_real}" "svc.log"
  # The symlink exists and resolves to the run's file.
  [ -L "${TMP_DIR}/svc.log" ]
  run cat "${TMP_DIR}/svc.log"
  assert_output "run-1"
  # The link target is RELATIVE (basename only), so it survives a dir move.
  run readlink "${TMP_DIR}/svc.log"
  assert_output "svc_20260101T000000Z.log"
}

@test "_logrotate_repoint: repointing to a newer file does NOT delete the old one (#805)" {
  local _a="${TMP_DIR}/svc_20260101T000000Z.log"
  local _b="${TMP_DIR}/svc_20260102T000000Z.log"
  printf 'run-1\n' > "${_a}"
  _logrotate_repoint "${_a}" "svc.log"
  printf 'run-2\n' > "${_b}"
  _logrotate_repoint "${_b}" "svc.log"
  # Symlink now follows the newer run.
  run cat "${TMP_DIR}/svc.log"
  assert_output "run-2"
  # The previous run's real file is still on disk (history retained).
  [ -f "${_a}" ]
}

# ── _logrotate_prune ────────────────────────────────────────────────

@test "_logrotate_prune: keeps the N most recent real files, drops the rest (#805)" {
  local _i _f
  for _i in $(seq 1 6); do
    _f="${TMP_DIR}/svc_2026010${_i}T000000Z.log"
    : > "${_f}"
    # Stagger mtimes so ls -t ordering is deterministic (newest = _i=6).
    touch -d "2026-01-0${_i} 00:00:00" "${_f}"
  done
  ln -sfn "svc_20260106T000000Z.log" "${TMP_DIR}/svc.log"
  # keep=3, days huge so age never fires: only the 3 newest survive.
  _logrotate_prune "${TMP_DIR}" "svc.log" 3 3650
  local -a _kept=()
  local _g
  for _g in "${TMP_DIR}"/svc_*.log; do _kept+=("$(basename "${_g}")"); done
  [ "${#_kept[@]}" -eq 3 ]
  [ -e "${TMP_DIR}/svc_20260106T000000Z.log" ]
  [ -e "${TMP_DIR}/svc_20260105T000000Z.log" ]
  [ -e "${TMP_DIR}/svc_20260104T000000Z.log" ]
  [ ! -e "${TMP_DIR}/svc_20260101T000000Z.log" ]
}

@test "_logrotate_prune: drops files older than <days> regardless of count (#805)" {
  local _old="${TMP_DIR}/svc_20200101T000000Z.log"
  local _new="${TMP_DIR}/svc_20260101T000000Z.log"
  : > "${_old}"; touch -d "2020-01-01 00:00:00" "${_old}"
  : > "${_new}"
  ln -sfn "svc_20260101T000000Z.log" "${TMP_DIR}/svc.log"
  # keep huge (count never fires); age drops the year-2020 file.
  _logrotate_prune "${TMP_DIR}" "svc.log" 9999 14
  [ ! -e "${_old}" ]
  [ -e "${_new}" ]
}

@test "_logrotate_prune: never removes the stable symlink itself (#805)" {
  # Only the symlink is present (no real files) -> nothing to prune, and
  # the symlink must survive both the age and count passes.
  local _real="${TMP_DIR}/svc_20260101T000000Z.log"
  : > "${_real}"; touch -d "2020-01-01 00:00:00" "${_real}"
  ln -sfn "svc_20260101T000000Z.log" "${TMP_DIR}/svc.log"
  # Age drops the (now-dangling-after) real file; the symlink must remain.
  _logrotate_prune "${TMP_DIR}" "svc.log" 1 14
  [ -L "${TMP_DIR}/svc.log" ]
}

@test "_logrotate_prune: never prunes a SIBLING service's symlink sharing the dir (#805)" {
  # A shared /var/log/<repo>/ holds svc-a's per-start files + stable a.log
  # AND svc-b's stable b.log symlink. Pruning svc-a must skip b.log even
  # though its name != the caller's <symlink_name> -- it is a symlink, not a
  # real per-start file. (Reals dated in the future so ls -t sorts b.log,
  # created now, as the OLDEST -> without the symlink guard the count pass
  # would have deleted it.)
  : > "${TMP_DIR}/a_1.log"; touch -d "2030-01-01 00:00:00" "${TMP_DIR}/a_1.log"
  : > "${TMP_DIR}/a_2.log"; touch -d "2030-01-02 00:00:00" "${TMP_DIR}/a_2.log"
  ln -sfn "a_2.log" "${TMP_DIR}/a.log"
  ln -sfn "a_2.log" "${TMP_DIR}/b.log"
  # keep=1 for svc-a: a_1 drops, a_2 stays; both symlinks must survive.
  _logrotate_prune "${TMP_DIR}" "a.log" 1 3650
  [ -L "${TMP_DIR}/b.log" ]
  [ -L "${TMP_DIR}/a.log" ]
  [ -e "${TMP_DIR}/a_2.log" ]
  [ ! -e "${TMP_DIR}/a_1.log" ]
}

@test "_logrotate_prune: missing dir is a no-op (best-effort) (#805)" {
  run _logrotate_prune "${TMP_DIR}/does-not-exist" "svc.log" 3 14
  assert_success
}
