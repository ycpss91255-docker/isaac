#!/usr/bin/env bats
#
# Process-level supervision tests for dist/script/docker/runtime/watchdog.sh
# (issue 797): the restart-container monitor loop, the restart-service
# supervisor, and the real signal / process-group teardown paths (bounded
# SIGTERM -> grace -> SIGKILL, whole-subtree kill via setsid, and the
# docker-stop SIGTERM forward). These drive real background processes,
# sleeps, and signals, so they are KCOV-FRAGILE (the kcov wrapper perturbs
# child processes / signal timing, per ADR-00000008): every test below
# carries the line-anchored `[ "${COVERAGE:-0}" = 1 ] && skip` guard so
# the coverage matrix skips this file and it runs PLAIN under bats-fragile.
# The kcov-safe pure-logic units live in watchdog_spec.bats.

bats_require_minimum_version 1.5.0

WD="/source/dist/script/docker/runtime/watchdog.sh"

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  TMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "${TMP_DIR}"
}

# ── restart-container monitor loop ───────────────────────────────────

@test "restart-container monitor DEFERS checks during the start period (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  # A failing check + a start period longer than the observation window
  # must NOT trigger a container exit yet (still initializing).
  run timeout 6 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=30 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1
    _watchdog_exit_container() { echo ACTED; exit 0; }
    ( _watchdog_monitor ) &
    _pid=\$!
    sleep 2
    kill \${_pid} 2>/dev/null || true
    echo DONE
  "
  refute_output --partial "ACTED"
  assert_output --partial "DONE"
}

@test "restart-container monitor EXITS the container after consecutive failures (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  run timeout 8 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=2
    _watchdog_exit_container() { echo ACTED-\$1; exit 0; }
    _watchdog_monitor
  " 2>&1
  assert_success
  assert_output --partial "restart-container"
  assert_output --partial "ACTED-1"
}

# ── restart-service supervisor: restart-in-place + give-up (stubbed
#    child seams so the loop logic is exercised without real processes) ─

@test "restart-service supervisor restarts in place then GIVES UP loudly at MAX_RESTARTS (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  run timeout 10 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1 _WATCHDOG_MAX_RESTARTS=2
    # Stub the child-management seams so no real processes are spawned.
    _watchdog_start_service()   { :; }
    _watchdog_child_alive()     { return 0; }
    _watchdog_restart_service() { echo RESTARTED; }
    _watchdog_stop_service()    { :; }
    _watchdog_exit_container()  { echo EXITED; exit 0; }
    _watchdog_supervise sleep 100
  " 2>&1
  assert_success
  assert_output --partial "restart 1/2"
  assert_output --partial "restart 2/2"
  assert_output --partial "GIVING UP"
  assert_output --partial "EXITED"
}

# ── bounded stop: a SIGTERM-ignoring service is SIGKILL'd, no hang ────

@test "_watchdog_stop_service SIGKILLs a SIGTERM-ignoring service within the bounded grace (no hang) (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  command -v setsid >/dev/null 2>&1 || skip "setsid unavailable"
  cat > "${TMP_DIR}/ignore_term.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
echo $$ > "$1"
sleep 60
EOF
  # timeout 10: an unbounded wait (the pre-fix bug) hangs here -> status 124.
  run timeout 10 bash -c "
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/ignore_term.sh' '${TMP_DIR}/svc.pid'
    sleep 0.5
    _pid=\"\$(cat '${TMP_DIR}/svc.pid')\"
    _watchdog_stop_service
    sleep 0.3
    if kill -0 \"\${_pid}\" 2>/dev/null; then echo STILL_ALIVE; else echo KILLED; fi
  "
  assert_success
  assert_output --partial "KILLED"
  refute_output --partial "STILL_ALIVE"
}

# ── whole-subtree kill: no orphaned grandchild survives a stop ───────

@test "_watchdog_stop_service kills the whole service subtree (no orphaned grandchild) (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  command -v setsid >/dev/null 2>&1 || skip "setsid unavailable"
  cat > "${TMP_DIR}/spawner.sh" <<'EOF'
#!/usr/bin/env bash
# A grandchild that ignores SIGTERM and records its own pid, then the
# service itself sleeps. Both share the setsid process group.
( trap '' TERM; echo $$ > "$1"; sleep 60 ) &
sleep 60
EOF
  run timeout 10 bash -c "
    . '${WD}'
    export _WATCHDOG_TIMEOUT=1
    _watchdog_start_service bash '${TMP_DIR}/spawner.sh' '${TMP_DIR}/grand.pid'
    sleep 0.7
    _gpid=\"\$(cat '${TMP_DIR}/grand.pid')\"
    _watchdog_stop_service
    sleep 0.3
    if kill -0 \"\${_gpid}\" 2>/dev/null; then echo ORPHAN_ALIVE; else echo SUBTREE_DEAD; fi
  "
  assert_success
  assert_output --partial "SUBTREE_DEAD"
  refute_output --partial "ORPHAN_ALIVE"
}

# ── give-up against a wedged service still reaches container exit ────

@test "restart-service give-up against a wedged (SIGTERM-ignoring) service still exits the container (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  command -v setsid >/dev/null 2>&1 || skip "setsid unavailable"
  cat > "${TMP_DIR}/wedged.sh" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 300
EOF
  # Real (bounded) stop_service against a wedged child; only exit_container
  # is overridden to observe that give-up REACHES it (the pre-fix unbounded
  # wait would hang stop_service so give-up never exits -> timeout 15).
  run timeout 15 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='false'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=1 _WATCHDOG_TIMEOUT=1 _WATCHDOG_FAILURES=1 _WATCHDOG_MAX_RESTARTS=1
    _watchdog_exit_container() { echo EXITED; exit 0; }
    _watchdog_supervise bash '${TMP_DIR}/wedged.sh'
  " 2>&1
  assert_success
  assert_output --partial "GIVING UP"
  assert_output --partial "EXITED"
}

# ── docker stop: supervisor forwards SIGTERM PROMPTLY (not deferred until
#    the interval) to the service group ───────────────────────────────

@test "restart-service supervisor forwards SIGTERM PROMPTLY on docker stop, not deferred until the interval (#797)" {
  [ "${COVERAGE:-0}" = 1 ] && skip "signal/process-timing spec runs plain under bats-fragile (#613)"
  command -v setsid >/dev/null 2>&1 || skip "setsid unavailable"
  cat > "${TMP_DIR}/graceful.sh" <<'EOF'
#!/usr/bin/env bash
trap 'touch "$1"; exit 0' TERM
sleep 300
EOF
  # INTERVAL=30 but the whole harness is timeout 12: a bare foreground
  # `sleep 30` would DEFER the trapped SIGTERM past the 12s timeout, so the
  # graceful forward (marker) would never run and the harness would be
  # SIGKILL'd at 12s (status 124). The interruptible sleep handles SIGTERM
  # at ~1s -> marker created, supervisor exits, well under the interval.
  run timeout 12 bash -c "
    . '${WD}'
    export WATCHDOG_CHECK='true'
    _WATCHDOG_START_PERIOD=0 _WATCHDOG_INTERVAL=30 _WATCHDOG_TIMEOUT=2 _WATCHDOG_FAILURES=3 _WATCHDOG_MAX_RESTARTS=5
    _watchdog_supervise bash '${TMP_DIR}/graceful.sh' '${TMP_DIR}/graceful.marker' &
    _sup=\$!
    sleep 1
    kill -TERM \${_sup}
    wait \${_sup} 2>/dev/null || true
    if [ -f '${TMP_DIR}/graceful.marker' ]; then echo GRACEFUL; else echo NO_SIGNAL; fi
  "
  assert_success
  assert_output --partial "GRACEFUL"
  refute_output --partial "NO_SIGNAL"
}
