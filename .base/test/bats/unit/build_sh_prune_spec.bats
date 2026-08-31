#!/usr/bin/env bats
#
# Unit tests for build.sh's post-build prune-predecessor logic.
# Separate spec so the docker stub can be tailored to image-inspect /
# images-filter / rmi semantics without bloating build_sh_spec.bats's
# default stub (which only logs args).
#
# Stub control env vars (read per-invocation by the smart docker stub):
#   DOCKER_INSPECT_PRE_ID    image ID returned by `docker image inspect`
#                            BEFORE the build (empty → exit 1, simulating
#                            "no prior image")
#   DOCKER_INSPECT_POST_ID   image ID returned AFTER `_compose_project
#                            build` finishes. Defaults to DOCKER_INSPECT_PRE_ID
#                            if unset (cache-hit no-op).
#   DOCKER_IMAGES_OUTPUT     newline-delimited tag list returned by
#                            `docker images --filter reference=<id>`.
#                            `<none>:<none>` is the self-entry the stub
#                            always emits; populate with extra lines to
#                            simulate "other tag still references old ID".
#   DOCKER_RMI_LOG           file that captures every `docker rmi <id>`
#                            call so tests can assert the rmi did (or
#                            did not) fire.

bats_require_minimum_version 1.5.0

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC2154
  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/.base/dist/script/docker/lib" \
           "${SANDBOX}/.base/dist/script/docker/wrapper" \
           "${SANDBOX}/config/docker"

  cp /source/dist/script/docker/lib/_lib.sh  "${SANDBOX}/.base/dist/script/docker/lib/_lib.sh"
  cp /source/dist/script/docker/lib/i18n.sh  "${SANDBOX}/.base/dist/script/docker/lib/i18n.sh"
  cp /source/dist/script/docker/lib/* "${SANDBOX}/.base/dist/script/docker/lib/"
  ln -s /source/dist/script/docker/wrapper/build.sh "${SANDBOX}/build.sh"

  MOCK_SETUP_LOG="${TEMP_DIR}/setup.log"
  export MOCK_SETUP_LOG

  # Mock setup.sh — seeds .env so _load_env succeeds and DOCKER_HUB_USER
  # / IMAGE_NAME are present for the _full_tag computation in build.sh.
  cat > "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
_subcmd="apply"
case "${1:-}" in
  check-drift) _subcmd="check-drift"; shift ;;
  apply)       shift ;;
esac
_base=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-path) _base="$2"; shift 2 ;;
    --lang)      shift 2 ;;
    *)           shift ;;
  esac
done
case "${_subcmd}" in
  check-drift) exit 0 ;;
  apply)
    printf 'setup.sh invoked --base-path %s\n' "${_base}" >> "${MOCK_SETUP_LOG}"
    {
      echo "USER_NAME=tester"
      echo "IMAGE_NAME=mockimg"
      echo "DOCKER_HUB_USER=mockuser"
    } > "${_base}/.env.generated"
    echo "# mock compose" > "${_base}/compose.yaml"
    ;;
esac
EOS
  chmod +x "${SANDBOX}/.base/dist/script/docker/wrapper/setup.sh"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  DOCKER_RMI_LOG="${TEMP_DIR}/rmi.log"
  export DOCKER_RMI_LOG
  : > "${DOCKER_RMI_LOG}"
  INSPECT_CALL_COUNTER="${TEMP_DIR}/inspect_calls"
  export INSPECT_CALL_COUNTER
  : > "${INSPECT_CALL_COUNTER}"

  # Smart docker stub. Branches:
  #   image inspect → first call returns DOCKER_INSPECT_PRE_ID, second
  #     returns DOCKER_INSPECT_POST_ID (defaults to PRE_ID for
  #     cache-hit). Empty PRE_ID → exit 1 (tag absent).
  #   images --filter reference=<id> → emit DOCKER_IMAGES_OUTPUT (one
  #     tag per line) prefixed with the self-entry `<none>:<none>` line
  #     that the build.sh grep filter strips out.
  #   rmi → append the id to DOCKER_RMI_LOG.
  #   any other verb (compose build / build / ...) → no-op exit 0.
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  # Count which inspect call this is (pre vs post build).
  _n="$(($(wc -l < "${INSPECT_CALL_COUNTER}") + 1))"
  printf '%s\n' "${_n}" >> "${INSPECT_CALL_COUNTER}"
  if [[ "${_n}" == "1" ]]; then
    _id="${DOCKER_INSPECT_PRE_ID:-}"
  else
    _id="${DOCKER_INSPECT_POST_ID:-${DOCKER_INSPECT_PRE_ID:-}}"
  fi
  [[ -z "${_id}" ]] && exit 1
  printf '%s\n' "${_id}"
  exit 0
fi
if [[ "${1:-}" == "images" ]]; then
  printf '<none>:<none>\n'
  if [[ -n "${DOCKER_IMAGES_OUTPUT:-}" ]]; then
    printf '%s\n' "${DOCKER_IMAGES_OUTPUT}"
  fi
  exit 0
fi
if [[ "${1:-}" == "rmi" ]]; then
  shift
  printf '%s\n' "$*" >> "${DOCKER_RMI_LOG}"
  exit 0
fi
# compose / build / anything else: silent success.
exit 0
EOS
  chmod +x "${BIN_DIR}/docker"

  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# ── prune-predecessor cases ──────────────────────────────────────────

@test "build.sh first build (no prior image) skips prune" {
  # Pre-build inspect returns exit 1 (tag absent) → _pre_build_id empty
  # → prune branch never enters _prune_predecessor.
  unset DOCKER_INSPECT_PRE_ID DOCKER_INSPECT_POST_ID DOCKER_IMAGES_OUTPUT
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh cache-hit rebuild (same id) skips prune" {
  # Pre and post inspect return the SAME id → _prune_predecessor early
  # returns at the cache-hit guard.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  # POST defaults to PRE when unset
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh successful rebuild with displaced id rmi's old id" {
  # Pre = old id, post = new id, no other tag points at old → rmi fires.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_IMAGES_OUTPUT=""  # only the <none>:<none> self-entry
  run bash "${SANDBOX}/build.sh"
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output --partial "sha256:aaaa"
}

@test "build.sh skips prune when old id still tagged by another reference" {
  # Pre = old id, post = new id, BUT docker images shows another tag
  # also pointing at old id (multi-tag scenario) → no rmi.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_IMAGES_OUTPUT="mockuser/mockimg:legacy"
  run bash "${SANDBOX}/build.sh"
  assert_success
  assert_output --partial "skip prune: predecessor still tagged"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --no-prune skips prune even when id displaced" {
  # Same scenario as the rmi-fires case, but --no-prune short-circuits
  # before either inspect call runs.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  run bash "${SANDBOX}/build.sh" --no-prune
  assert_success
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --dry-run prints planned prune step + does not rmi" {
  # Dry-run surfaces the planned prune line for visibility but does
  # not invoke docker rmi.
  export DOCKER_INSPECT_PRE_ID="sha256:aaaa000000000000000000000000000000000000000000000000000000000000"
  export DOCKER_INSPECT_POST_ID="sha256:bbbb000000000000000000000000000000000000000000000000000000000000"
  run bash "${SANDBOX}/build.sh" --dry-run
  assert_success
  assert_output --partial "[dry-run] docker rmi <old-id-of"
  run cat "${DOCKER_RMI_LOG}"
  assert_output ""
}

@test "build.sh --help mentions --no-prune (#387)" {
  run bash "${SANDBOX}/build.sh" --help
  assert_success
  assert_output --partial "--no-prune"
}
