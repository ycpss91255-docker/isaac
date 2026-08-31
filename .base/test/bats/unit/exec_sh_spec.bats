#!/usr/bin/env bats
#
# Unit tests for dist/script/docker/wrapper/exec.sh argument handling, i18n log lines,
# and the "container not running" guard. Mirrors the sandbox/mock strategy
# from build_sh_spec.bats / run_sh_spec.bats: a sandbox tree with symlinked
# exec.sh, real _lib.sh / i18n.sh, and a PATH-shimmed `docker` stub whose
# `docker ps` output is controlled by ${DOCKER_PS_FILE} so individual tests
# can toggle "container running" state.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/dist/script/docker/lib"

  cp /source/dist/script/docker/lib/_lib.sh  "${SANDBOX}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh  "${SANDBOX}/.base/dist/script/docker/lib/i18n.sh"
  # _lib.sh is an umbrella that sources lib/*.sh sub-libs.
  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  ln -s /source/dist/script/docker/wrapper/exec.sh "${SANDBOX}/exec.sh"

  # Seed .env so _load_env / _compute_project_name succeed without bootstrap.
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=mockimg"
    echo "DOCKER_HUB_USER=mockuser"
  } > "${SANDBOX}/.env.generated"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"

  DOCKER_PS_FILE="${TEMP_DIR}/docker_ps.out"
  export DOCKER_PS_FILE
  : > "${DOCKER_PS_FILE}"

  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
  # Opt-in late write (${DOCKER_PS_LATE_FILE}): names that arrive only
  # after a reader which stops reading has already left, so the write
  # finds no reader. `exec` so the SIGPIPE is this stub's own exit
  # status rather than being swallowed by the `exit 0` below.
  if [[ -n "${DOCKER_PS_LATE_FILE:-}" ]]; then
    sleep 0.2
    exec cat "${DOCKER_PS_LATE_FILE}"
  fi
  exit 0
fi
printf 'docker'
printf ' %q' "$@"
printf '\n'
EOS
  chmod +x "${BIN_DIR}/docker"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

@test "exec.sh --help exits 0 and shows usage" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  assert_output --partial "exec.sh"
}

@test "exec.sh --lang zh-TW prints Chinese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW --help
  assert_success
  assert_output --partial "用法"
}

@test "exec.sh --lang zh-CN prints Simplified Chinese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang zh-CN --help
  assert_success
  assert_output --partial "用法"
}

@test "exec.sh --lang ja prints Japanese usage text" {
  run bash "${SANDBOX}/exec.sh" --lang ja --help
  assert_success
  assert_output --partial "使用法"
}

@test "exec.sh --lang requires a value" {
  run bash "${SANDBOX}/exec.sh" --lang
  assert_failure
}

@test "exec.sh --target requires a value" {
  run bash "${SANDBOX}/exec.sh" --target
  assert_failure
}

@test "exec.sh fails when container not running (default English)" {
  run bash "${SANDBOX}/exec.sh"
  assert_failure
  assert_output --partial "is not running"
}

@test "exec.sh --lang zh-TW prints Chinese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW
  assert_failure
  assert_output --partial "未在執行中"
}

@test "exec.sh --lang zh-CN prints Simplified Chinese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang zh-CN
  assert_failure
  assert_output --partial "未在运行中"
}

@test "exec.sh --lang ja prints Japanese not-running error" {
  run bash "${SANDBOX}/exec.sh" --lang ja
  assert_failure
  assert_output --partial "実行されていません"
}

@test "exec.sh prints start hint when container not running" {
  run bash "${SANDBOX}/exec.sh"
  assert_failure
  assert_output --partial "./run.sh"
}

@test "exec.sh --lang zh-TW start hint translates" {
  run bash "${SANDBOX}/exec.sh" --lang zh-TW
  assert_failure
  assert_output --partial "請先以"
  assert_output --partial "./run.sh"
}

@test "exec.sh --dry-run bypasses container-running check" {
  # No container running, but --dry-run should short-circuit the guard
  # and fall through to _compose_project exec (which the docker stub logs).
  run bash "${SANDBOX}/exec.sh" --dry-run
  assert_success
}

@test "exec.sh runs docker compose exec when container is running" {
  # container_name now includes USER_NAME prefix; setup .env has USER_NAME=tester
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run
  assert_success
  assert_output --partial "exec"
}

# ── -t <non-devel> precheck container name ──────────────────────

@test "exec.sh -t <non-devel>: precheck name suffixes the target stage (#335)" {
  # Previously the precheck always grepped `tester-mockimg` regardless of
  # -t, so any non-devel target aborted with "not running". After the fix:
  # -t devel    -> tester-mockimg
  # -t headless -> tester-mockimg-headless
  run bash "${SANDBOX}/exec.sh" -t headless
  assert_failure
  assert_output --partial "tester-mockimg-headless"
  refute_output --partial "'tester-mockimg' is not running"
}

@test "exec.sh -t devel: precheck name has no stage suffix (parity, #335)" {
  run bash "${SANDBOX}/exec.sh" -t devel
  assert_failure
  assert_output --partial "tester-mockimg"
  refute_output --partial "tester-mockimg-devel"
}

@test "exec.sh -t headless: precheck name carries the stage suffix (#335)" {
  # Order in compose.yaml: ${USER_NAME}-${IMAGE_NAME}-${TARGET}
  run bash "${SANDBOX}/exec.sh" -t headless
  assert_failure
  assert_output --partial "tester-mockimg-headless"
}

@test "exec.sh -t <non-devel>: precheck passes when matching container is running (#335)" {
  echo "tester-mockimg-headless" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" -t headless --dry-run
  assert_success
  assert_output --partial "exec"
}

@test "exec.sh: a docker ps still writing cannot make the precheck miss a running container (#905)" {
  # Same inverted answer as run.sh's guard, taken through a NEGATION:
  # `! docker ps ... | <reader>`. A reader that stops reading strands a
  # `docker ps` still writing, exec.sh's file-scope `pipefail` makes the
  # pipeline 141, the `if` reads that as "no match", and the `!` turns it
  # into "not running" -- so exec.sh refuses a container that is running,
  # exits 1, and tells the user to start it. Loud, and wrong.
  #
  # The matching name is written first so a real early-closing reader
  # genuinely matches and genuinely leaves; the late write then finds
  # nobody. Draining the whole stream is unaffected by either half.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  DOCKER_PS_LATE_FILE="${TEMP_DIR}/docker_ps.late"
  export DOCKER_PS_LATE_FILE
  echo "someone-elses-container" > "${DOCKER_PS_LATE_FILE}"

  run bash "${SANDBOX}/exec.sh" -- true
  assert_success
  refute_output --partial "is not running"
}

# ── -- flag/CMD separator ──────────────────────────────────────

@test "exec.sh -- separator: standalone -- is consumed, CMD flows through (#289)" {
  # container_name now includes USER_NAME prefix; setup .env has USER_NAME=tester
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -- ls /tmp
  assert_success
  assert_output --partial " ls /tmp"
  # The literal -- must not survive into the docker exec command line —
  # confirm there's no ` -- ` standalone token in the captured docker args.
  refute_output --partial " -- "
}

@test "exec.sh -- separator: lets a dash-leading CMD pass through (#289)" {
  # The whole point of -- is to send a CMD starting with a dash to the
  # container without exec.sh's own option parser capturing it.
  # container_name now includes USER_NAME prefix; setup .env has USER_NAME=tester
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -- my-tool --version
  assert_success
  assert_output --partial "my-tool"
  assert_output --partial "--version"
  refute_output --partial " -- "
}

@test "exec.sh -- separator: works after -t TARGET (run.sh parity, #289)" {
  # container_name now includes USER_NAME prefix; setup .env has USER_NAME=tester
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -t devel -- echo hi
  assert_success
  assert_output --partial "echo hi"
  refute_output --partial " -- "
}

@test "exec.sh: no -- still works for positional CMD (backward compat, #289)" {
  # container_name now includes USER_NAME prefix; setup .env has USER_NAME=tester
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run ls -la /tmp
  assert_success
  assert_output --partial "ls"
}

@test "exec.sh --help mentions the -- separator (#289)" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  # Either the synopsis token [--] or the standalone Options entry.
  assert_output --partial "--"
}

# ── /lint/-layout _detect_lang (flat dir with _lib.sh + i18n.sh,) ─────

@test "exec.sh in /lint/ layout maps zh_TW.UTF-8 to zh-TW" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
  LANG=zh_TW.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "exec.sh in /lint/ layout maps zh_CN.UTF-8 to zh-CN" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
  LANG=zh_CN.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "用法"
  rm -rf "${_tmp}"
}

@test "exec.sh in /lint/ layout maps ja_JP.UTF-8 to ja" {
  local _tmp
  _tmp="$(mktemp -d)"
  ln -s /source/dist/script/docker/wrapper/exec.sh "${_tmp}/exec.sh"
  mkdir -p "${_tmp}/lib"
  cp /source/dist/script/docker/lib/* "${_tmp}/lib/"
  LANG=ja_JP.UTF-8 run bash "${_tmp}/exec.sh" -h
  assert_success
  assert_output --partial "使用法"
  rm -rf "${_tmp}"
}

# ════════════════════════════════════════════════════════════════════
# -C / --chdir flag (issue docker_harness#53) — see build_sh_spec.
# ════════════════════════════════════════════════════════════════════

@test "exec.sh -C <dir> redirects FILE_PATH to <dir>" {
  # Seed an alt sandbox with its own .env carrying a distinct IMAGE_NAME.
  # When -C points there, exec.sh's docker exec invocation must reference
  # the alt IMAGE_NAME, proving FILE_PATH was redirected.
  local ALT="${TEMP_DIR}/alt"
  mkdir -p "${ALT}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${ALT}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${ALT}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${ALT}/.base/dist/script/docker/lib/"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg"
    echo "DOCKER_HUB_USER=altuser"
  } > "${ALT}/.env.generated"

  # Make `docker ps` claim the alt container is running so exec proceeds.
  echo "altuser-altimg" > "${DOCKER_PS_FILE}"

  run bash "${SANDBOX}/exec.sh" -C "${ALT}" --dry-run
  assert_success
  # The compose project name is derived from DOCKER_HUB_USER + IMAGE_NAME
  # in .env. If FILE_PATH still pointed at SANDBOX, project would say
  # mockuser-mockimg.
  assert_output --partial "altuser-altimg"
  refute_output --partial "mockuser-mockimg"
}

@test "exec.sh --chdir <dir> long form is equivalent to -C" {
  local ALT="${TEMP_DIR}/alt2"
  mkdir -p "${ALT}/.base/dist/script/docker/lib"
  cp /source/dist/script/docker/lib/_lib.sh "${ALT}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh "${ALT}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${ALT}/.base/dist/script/docker/lib/"
  {
    echo "USER_NAME=tester"
    echo "IMAGE_NAME=altimg2"
    echo "DOCKER_HUB_USER=altuser2"
  } > "${ALT}/.env.generated"
  echo "altuser2-altimg2" > "${DOCKER_PS_FILE}"

  run bash "${SANDBOX}/exec.sh" --chdir "${ALT}" --dry-run
  assert_success
  assert_output --partial "altuser2-altimg2"
}

@test "exec.sh -C without a value exits 2" {
  run bash "${SANDBOX}/exec.sh" -C
  assert_failure 2
  assert_output --partial "requires a value"
}

@test "exec.sh -C with a non-existent directory exits 2" {
  run bash "${SANDBOX}/exec.sh" -C /definitely/does/not/exist
  assert_failure 2
  assert_output --partial "not a directory"
}

@test "exec.sh -C is mentioned in usage help" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  assert_output --partial "-C"
  assert_output --partial "--chdir"
}

# ════════════════════════════════════════════════════════════════════
# -v / --verbose / -vv / --very-verbose (BUILDKIT_PROGRESS=plain,)
# ════════════════════════════════════════════════════════════════════

@test "exec.sh -v / --verbose / -vv / --very-verbose are mentioned in usage help (#311)" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  assert_output --partial "-v, --verbose"
  assert_output --partial "-vv, --very-verbose"
  assert_output --partial "BUILDKIT_PROGRESS=plain"
}

@test "exec.sh -v --dry-run is accepted and exits 0 (#311)" {
  run bash "${SANDBOX}/exec.sh" -v --dry-run
  assert_success
}

@test "exec.sh --verbose long form is accepted (#311)" {
  run bash "${SANDBOX}/exec.sh" --verbose --dry-run
  assert_success
}

@test "exec.sh -vv --dry-run enables bash trace (set -x output on stderr) (#311)" {
  run --separate-stderr bash "${SANDBOX}/exec.sh" -vv --dry-run
  assert_success
  # kcov instruments bash (set -x/PS4), so the wrapper's `-vv` trace
  # prefix `+ ` does not reach stderr under coverage; the real -vv
  # behaviour is covered by the normal (non-kcov) job. Skip the fragile
  # observation under kcov.
  [ "${COVERAGE:-0}" = 1 ] && skip "set -x trace not observable under kcov instrumentation (#613)"
  [[ "${stderr}" == *"+ "* ]]
}

# ── TTY auto-detect + explicit -T / -i (Option 1+2) ──────────────
#
# `docker compose exec` defaults to -it; running a one-shot CMD inherits
# that TTY so container-side bash echoes terminal escape sequences
# (focus-in `^[[I`, bracketed-paste, etc.) into stdout. Fix shape:
#   - auto-detect: positional CMD `bash|sh|dash|zsh|ash|ksh -c ...`
#     implies no-TTY (the 90% case)
#   - explicit `-T / --no-tty` forces no-TTY (escape hatch for the
#     heuristic-misses case, e.g. `whoami`, `env BAR=1 bash -c '...'`)
#   - explicit `-i / --tty` forces TTY (override for the rare case
#     where a `bash -c` actually wants a TTY, e.g. `bash -c 'tput cols'`)
#   - last-wins between -T and -i (standard CLI convention)
#
# Verification is via --dry-run path: _compose prints all argv via
# `printf '%q'` so we can grep for the literal `-T` between `exec` and
# the target name.

@test "exec.sh --dry-run with no CMD: no -T (default interactive bash entry, #382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run
  assert_success
  assert_output --partial "exec devel"
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run with interactive binary (htop): no -T (auto-detect doesn't fire, #382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run htop
  assert_success
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run bash -c '...': auto-detect adds -T (#382 Option 2)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run bash -c 'echo hi'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run sh -c '...': auto-detect adds -T (#382 Option 2)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run sh -c 'echo hi'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run dash -c '...': auto-detect adds -T (#382 Option 2)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run dash -c 'echo hi'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run zsh -c '...': auto-detect adds -T (#382 Option 2)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run zsh -c 'echo hi'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run bash hello.sh: no -T (no -c → not a one-shot, #382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run bash hello.sh
  assert_success
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run -T whoami: explicit -T forces no-TTY (#382 Option 1)" {
  # Heuristic doesn't fire (whoami isn't bash/sh + -c); explicit -T
  # covers this leaked-output case.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -T whoami
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run --no-tty long form forces no-TTY (#382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run --no-tty whoami
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run -T env BAR=1 bash -c '...': covers auto-detect's heuristic gap (#382)" {
  # `env` is the first positional so the bash + -c heuristic misses;
  # explicit -T is the escape hatch for this case.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -T env BAR=1 bash -c 'echo $BAR'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run -i bash -c '...': explicit -i overrides heuristic (#382 Option 1)" {
  # User wants TTY for `bash -c 'tput cols'`-style commands; -i wins
  # over the auto-detect -T.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -i bash -c 'tput cols'
  assert_success
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run --tty long form overrides heuristic (#382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run --tty bash -c 'tput cols'
  assert_success
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run -T -i: last-wins gives TTY (#382)" {
  # Standard CLI last-wins precedence. -T then -i → -i (TTY).
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -T -i bash -c 'echo hi'
  assert_success
  refute_output --partial "exec -T"
}

@test "exec.sh --dry-run -i -T: last-wins gives no-TTY (#382)" {
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -i -T bash -c 'echo hi'
  assert_success
  assert_output --partial "exec -T devel"
}

@test "exec.sh --dry-run -T after -t TARGET still attaches to the right service (#382)" {
  echo "tester-mockimg-headless" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -t headless -T whoami
  assert_success
  assert_output --partial "exec -T headless"
}

@test "exec.sh --dry-run -- separator: -T propagates, CMD flows through (#382 + #289)" {
  # The -- separator stops exec.sh option parsing. -T must be BEFORE --.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  run bash "${SANDBOX}/exec.sh" --dry-run -T -- my-tool --version
  assert_success
  assert_output --partial "exec -T devel"
  assert_output --partial "my-tool"
  assert_output --partial "--version"
}

@test "exec.sh --help mentions -T / --no-tty and -i / --tty flags (#382)" {
  run bash "${SANDBOX}/exec.sh" --help
  assert_success
  assert_output --partial "-T"
  assert_output --partial "--no-tty"
  assert_output --partial "-i"
  assert_output --partial "--tty"
}

# ════════════════════════════════════════════════════════════════════
# Exit-code forwarding + error-path integration
#
# exec.sh forwards the in-container command's exit code so that
# `./exec.sh false` / `./exec.sh my-test` propagate a container-command
# failure for scripting/CI (exec.sh: `_compose_project exec ...;
# _exec_rc=$?; ...; return "${_exec_rc}"`). The default docker stub in
# this file always exits 0 for non-`ps` calls, so a non-zero container
# exit was never exercised. _exec_rc_fixture swaps in a docker stub whose
# `compose exec` exits ${DOCKER_EXEC_RC}, so a test can drive the wrapper
# exit code. Mirrors run_sh_spec's _exit_code_fixture pattern.
_exec_rc_fixture() {
  # Container running so the not-running guard passes and exec proceeds.
  echo "tester-mockimg" > "${DOCKER_PS_FILE}"
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
if [[ "$1" == "ps" ]]; then
  cat "${DOCKER_PS_FILE}"
  exit 0
fi
_has_exec=0
for _a in "$@"; do
  [[ "${_a}" == "exec" ]] && _has_exec=1
done
printf 'docker'
printf ' %q' "$@"
printf '\n'
(( _has_exec )) && exit "${DOCKER_EXEC_RC:-0}"
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"
}

@test "exec.sh forwards a non-zero container command exit code (#690)" {
  _exec_rc_fixture
  export DOCKER_EXEC_RC=42
  # Real mode (not --dry-run) so _compose_project exec actually runs and
  # its rc is captured + forwarded by `return "${_exec_rc}"`.
  run -42 bash "${SANDBOX}/exec.sh" -- false
}

@test "exec.sh forwards exit code 0 on success (#690)" {
  _exec_rc_fixture
  export DOCKER_EXEC_RC=0
  run -0 bash "${SANDBOX}/exec.sh" -- true
}

@test "exec.sh forwards a distinct non-zero exit code unchanged (#690)" {
  # A second non-zero code guards against the wrapper hard-coding 1 (or
  # any fixed value) instead of forwarding the container command's rc.
  _exec_rc_fixture
  export DOCKER_EXEC_RC=7
  run -7 bash "${SANDBOX}/exec.sh" -- some-test
}

@test "exec.sh post-exec hook failure overrides the forwarded rc (#690)" {
  # exec.sh: `_run_post_hook exec "$@" || exit $?` (after capturing
  # _exec_rc). A failing post-hook must override the container rc so the
  # wrapper surfaces the hook failure. Container command succeeds (rc 0);
  # the post-hook exits 9 → wrapper must exit 9, not 0.
  _exec_rc_fixture
  export DOCKER_EXEC_RC=0
  mkdir -p "${SANDBOX}/script/hooks/post"
  cat > "${SANDBOX}/script/hooks/post/exec.sh" <<'HOOK'
#!/usr/bin/env bash
echo "POST_EXEC_HOOK_FIRED"
exit 9
HOOK
  chmod +x "${SANDBOX}/script/hooks/post/exec.sh"
  run -9 bash "${SANDBOX}/exec.sh" -- true
  assert_output --partial "POST_EXEC_HOOK_FIRED"
}

@test "exec.sh aborts on a failing pre-exec hook and skips compose exec (#690)" {
  # exec.sh: `_run_pre_hook exec "$@" || exit $?` fires AFTER the
  # not-running guard, BEFORE `_compose_project exec`. A pre-hook that
  # exits 7 must abort the wrapper (status 7) and the docker `exec`
  # command must NEVER run. Real mode (pre-hook no-ops under --dry-run).
  _exec_rc_fixture
  mkdir -p "${SANDBOX}/script/hooks/pre"
  cat > "${SANDBOX}/script/hooks/pre/exec.sh" <<'HOOK'
#!/usr/bin/env bash
echo "PRE_EXEC_HOOK_FIRED"
exit 7
HOOK
  chmod +x "${SANDBOX}/script/hooks/pre/exec.sh"
  run -7 bash "${SANDBOX}/exec.sh" -- whoami
  assert_output --partial "PRE_EXEC_HOOK_FIRED"
  refute_output --partial "docker compose exec"
}
