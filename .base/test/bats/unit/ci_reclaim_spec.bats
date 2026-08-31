#!/usr/bin/env bats
#
# Unit tests for script/ci/reclaim.sh -- the CI-host garbage collector.
#
# These assertions are made against the SCRIPT, not against a CI
# environment. `runs-on: ubuntu-latest` hands every job a fresh
# single-tenant VM, so no run on the current CI can exhibit either failure
# this script exists to prevent: one run deleting a CONCURRENT run's
# artifacts, and a killed runner leaving artifacts nobody collects. A fake
# docker daemon (a PATH shim reading a state file) is what lets a test put
# two runs' artifacts on ONE host and assert the boundary between them.
#
# State-file rows are `kind|id|name|run-label|age-seconds`; the shim
# records every argv it is handed, so a test can assert not only what was
# removed but what command was never issued at all.
#
# Refs

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  TEMP_DIR="$(mktemp -d)"
  export TEMP_DIR

  SANDBOX="${TEMP_DIR}/repo"
  mkdir -p "${SANDBOX}/script/ci"

  # A COPY, not a symlink: the script resolves its own directory through
  # readlink, which on a symlink would jump back to the real tree and
  # reach the real prune.sh instead of the recording stub below.
  cp /source/script/ci/reclaim.sh "${SANDBOX}/script/ci/reclaim.sh"
  chmod +x "${SANDBOX}/script/ci/reclaim.sh"
  RECLAIM="${SANDBOX}/script/ci/reclaim.sh"

  PRUNE_CALLS="${TEMP_DIR}/prune-calls"
  export PRUNE_CALLS
  : > "${PRUNE_CALLS}"
  cat > "${SANDBOX}/script/prune.sh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PRUNE_CALLS}"
EOS
  chmod +x "${SANDBOX}/script/prune.sh"

  DOCKER_STATE="${TEMP_DIR}/docker-state"
  DOCKER_CALLS="${TEMP_DIR}/docker-calls"
  DOCKER_REMOVED="${TEMP_DIR}/docker-removed"
  export DOCKER_STATE DOCKER_CALLS DOCKER_REMOVED
  : > "${DOCKER_STATE}"
  : > "${DOCKER_CALLS}"
  : > "${DOCKER_REMOVED}"

  BIN_DIR="${TEMP_DIR}/bin"
  mkdir -p "${BIN_DIR}"
  cat > "${BIN_DIR}/docker" <<'EOS'
#!/usr/bin/env bash
# Fake docker daemon. Understands exactly the surface reclaim.sh uses:
# the four `ls` verbs (quiet + label-filtered or id|name), the three
# `inspect --format {{.Created}}` verbs, and the four remove verbs.
set -u
printf '%s\n' "$*" >> "${DOCKER_CALLS}"

_kind=""; _sub=""
case "${1-}" in
  ps)        _kind=container; shift ;;
  images)    _kind=image; shift ;;
  network)   _kind=network; shift; _sub="${1-}"; shift ;;
  volume)    _kind=volume; shift; _sub="${1-}"; shift ;;
  container) _kind=container; shift; _sub="${1-}"; shift ;;
  image)     _kind=image; shift; _sub="${1-}"; shift ;;
  rm)        _kind=container; _sub=rm; shift ;;
  rmi)       _kind=image; _sub=rm; shift ;;
  *)         exit 0 ;;
esac

_quiet=false; _filter=""
_args=()
while (( $# )); do
  case "${1}" in
    -q|-aq) _quiet=true; shift ;;
    --filter) _filter="${2}"; shift 2 ;;
    --format) shift 2 ;;
    -*) shift ;;
    *) _args+=("${1}"); shift ;;
  esac
done

if [[ "${_sub}" == "inspect" ]]; then
  _now="$(date +%s)"
  for _id in "${_args[@]-}"; do
    [[ -z "${_id}" ]] && continue
    _row="$(grep -- "^${_kind}|${_id}|" "${DOCKER_STATE}")" || exit 1
    _age="$(printf '%s' "${_row}" | cut -d'|' -f5)"
    date -u -d "@$(( _now - _age ))" +%Y-%m-%dT%H:%M:%SZ
  done
  exit 0
fi

if [[ "${_sub}" == "rm" ]]; then
  for _id in "${_args[@]-}"; do
    [[ -z "${_id}" ]] && continue
    printf '%s %s\n' "${_kind}" "${_id}" >> "${DOCKER_REMOVED}"
  done
  exit 0
fi

# Any remaining verb is a listing.
while IFS='|' read -r _k _id _name _label _age; do
  [[ "${_k}" == "${_kind}" ]] || continue
  if [[ -n "${_filter}" ]]; then
    _lf="${_filter#label=}"
    if [[ "${_lf}" == *=* ]]; then
      [[ "${_label}" == "${_lf#*=}" ]] || continue
    else
      [[ -n "${_label}" ]] || continue
    fi
  fi
  if [[ "${_quiet}" == true ]]; then
    printf '%s\n' "${_id}"
  else
    printf '%s|%s\n' "${_id}" "${_name}"
  fi
done < "${DOCKER_STATE}"
EOS
  chmod +x "${BIN_DIR}/docker"
  export PATH="${BIN_DIR}:${PATH}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# _state <kind> <id> <name> <run-label> <age-seconds>
_state() {
  printf '%s|%s|%s|%s|%s\n' "${1}" "${2}" "${3}" "${4}" "${5}" >> "${DOCKER_STATE}"
}

_removed() {
  cat "${DOCKER_REMOVED}"
}

# ── scope is mandatory ─────────────────────────────────────────────

@test "reclaim.sh --help exits 0 and shows usage" {
  run bash "${RECLAIM}" --help
  assert_success
  assert_output --partial "reclaim.sh"
}

@test "reclaim.sh with no scope refuses (a scopeless sweep is the trap)" {
  run bash "${RECLAIM}"
  assert_failure 2
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

@test "reclaim.sh rejects a --stale window that is not a duration" {
  run bash "${RECLAIM}" --stale forever
  assert_failure 2
}

# ── layer 1: exact, per-run teardown ───────────────────────────────

@test "reclaim.sh --run removes this run's artifacts across all four kinds" {
  _state image     img1 "test-tools:ci-1001-1"          1001-1 60
  _state container ctr1 "base-ci-1001-1-ci-1"           ""     60
  _state network   net1 "ci-e2e_test-ci-1001-1_default" ""     60
  _state volume    vol1 "base-ci-1001-1_cache"          ""     60

  run bash "${RECLAIM}" --run 1001-1
  assert_success
  run _removed
  assert_line "image img1"
  assert_line "container ctr1"
  assert_line "network net1"
  assert_line "volume vol1"
}

@test "reclaim.sh --run leaves a CONCURRENT run's artifacts alone (the trap)" {
  # The failure the current CI cannot exhibit: two runs on ONE host. A
  # blanket prune would take both rows; ownership scoping takes one.
  _state image     mine   "test-tools:ci-1001-1" 1001-1 60
  _state image     theirs "test-tools:ci-1002-1" 1002-1 60
  _state container minec  "base-ci-1001-1-ci-1"  ""     60
  _state container theirc "base-ci-1002-1-ci-1"  ""     60

  run bash "${RECLAIM}" --run 1001-1
  assert_success
  run _removed
  assert_line "image mine"
  assert_line "container minec"
  refute_line "image theirs"
  refute_line "container theirc"
}

@test "reclaim.sh --run does not mistake attempt 10 for attempt 1" {
  # `ci-1001-1` is a string prefix of `ci-1001-10`; a substring match
  # would let a re-running job delete the attempt that is still live.
  _state image a1  "test-tools:ci-1001-1"  "" 60
  _state image a10 "test-tools:ci-1001-10" "" 60

  run bash "${RECLAIM}" --run 1001-1
  assert_success
  run _removed
  assert_line "image a1"
  refute_line "image a10"
}

@test "reclaim.sh --run finds an artifact by its ownership label alone" {
  # The loaded test-tools image is the artifact compose does not track:
  # cleanup has to be able to ask whose it is, not only what it is called.
  _state image labelled "some/unrelated-name:latest" 1001-1 60

  run bash "${RECLAIM}" --run 1001-1
  assert_success
  run _removed
  assert_line "image labelled"
}

@test "reclaim.sh --run never issues a blanket prune" {
  _state image img1 "test-tools:ci-1001-1" 1001-1 60

  run bash "${RECLAIM}" --run 1001-1
  assert_success
  run cat "${DOCKER_CALLS}"
  refute_output --partial "system prune"
  refute_output --partial "image prune"
  refute_output --partial "volume prune"
  refute_output --partial "builder prune"
  run cat "${PRUNE_CALLS}"
  assert_output ""
}

@test "reclaim.sh --dry-run reports without removing anything" {
  _state image img1 "test-tools:ci-1001-1" 1001-1 60

  run bash "${RECLAIM}" --run 1001-1 --dry-run
  assert_success
  assert_output --partial "img1"
  run cat "${DOCKER_REMOVED}"
  assert_output ""
}

# ── layer 2: age-based backstop ────────────────────────────────────

@test "reclaim.sh --stale collects a killed runner's leftovers" {
  # Nothing removes these on the normal path: the job that made them died
  # before its own teardown step could run.
  _state image     old "test-tools:ci-1001-1" 1001-1 90000
  _state container oldc "base-ci-1001-1-ci-1" ""     90000

  run bash "${RECLAIM}" --stale 12h
  assert_success
  run _removed
  assert_line "image old"
  assert_line "container oldc"
}

@test "reclaim.sh --stale spares an in-flight run inside the window" {
  # A concurrent job's artifacts are young. Sweeping them is exactly the
  # damage the unique naming was protecting against.
  _state image young "test-tools:ci-1002-1" 1002-1 600
  _state image old   "test-tools:ci-1001-1" 1001-1 90000

  run bash "${RECLAIM}" --stale 12h
  assert_success
  run _removed
  assert_line "image old"
  refute_line "image young"
}

@test "reclaim.sh --stale spares the current run even when its clock says old" {
  _state image mine "test-tools:ci-1001-1" 1001-1 90000

  run bash "${RECLAIM}" --run 1001-1 --stale 30h
  assert_success
  # The --run pass already took it; the stale pass must not be what
  # decides, so a run whose own artifacts predate the window (a long
  # re-run chain) is never swept out from under itself.
  run cat "${DOCKER_CALLS}"
  refute_output --partial "system prune"
}

@test "reclaim.sh --stale ignores artifacts that are not CI-owned" {
  # A developer's or another tenant's image on the same host carries
  # neither the label nor the run-keyed name.
  _state image other "ollama/ollama:latest" "" 900000

  run bash "${RECLAIM}" --stale 12h
  assert_success
  run _removed
  refute_output --partial "image other"
}

@test "reclaim.sh --stale delegates the unowned classes to prune.sh with the same window" {
  # Dangling images / unattached networks / builder cache carry no
  # ownership marker, but docker's own prune verbs skip anything in use,
  # so the sibling wrapper is the right primitive for them.
  run bash "${RECLAIM}" --stale 12h
  assert_success
  run cat "${PRUNE_CALLS}"
  assert_output --partial "--all"
  assert_output --partial "--until 12h"
}

@test "reclaim.sh --stale never touches volumes" {
  # A volume holds state, an image does not. The age of a volume is no
  # evidence about who owns it, so the backstop refuses the class.
  _state volume oldvol "base-ci-1001-1_cache" 1001-1 900000

  run bash "${RECLAIM}" --stale 12h
  assert_success
  run _removed
  refute_output --partial "volume oldvol"
}
