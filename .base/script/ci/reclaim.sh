#!/usr/bin/env bash
# reclaim.sh - Remove the docker artifacts a CI run created, and nothing else.
#
# Once every name CI creates is keyed to the run that created it, the
# leftovers stop dying with the VM: a self-hosted host keeps them. The
# obvious collector -- `docker system prune -a` -- is ACTIVELY HARMFUL on
# exactly that machine, because a shared host's "unused" resources include
# a concurrent job's in-flight build cache and images. The naive fix for
# the leftover problem breaks the thing the unique naming was protecting.
#
# So this script only ever removes what a run can PROVE it created, by one
# of two ownership predicates:
#
#   label  base.ci.run=<key>   stamped on the artifacts CI builds itself
#                              (the loaded test-tools image is the one
#                              compose does not track, so a name alone
#                              cannot answer "whose is this?")
#   name   ...ci-<key>...      the artifacts downstream tooling names but
#                              does not label -- the scaffolded consumer's
#                              image / container / network. <key> is
#                              globally unique, so the name IS the proof.
#
# Two layers, because each covers the other's failure:
#
#   --run <key>        Layer 1. Exact, precise, and the normal path; runs
#                      as an `if: always()` teardown step so a failed job
#                      still hands its artifacts back.
#   --stale <duration> Layer 2. The backstop for the case layer 1 cannot
#                      cover at all: a runner killed mid-job never reaches
#                      its teardown step. Age-based, and still
#                      ownership-scoped -- age alone is not evidence of
#                      ownership. The classes that carry no ownership
#                      marker (dangling images, unattached networks,
#                      buildx cache) are delegated to the sibling
#                      prune.sh, whose docker prune verbs skip anything
#                      in use by definition.
#
# Layer 2 is a step of the same `if: always()` teardown rather than a
# scheduled job or host-level maintenance. A scheduled workflow lands on
# ONE runner of a pool and leaves the others uncollected; host maintenance
# lives outside the repo, so it cannot be versioned, tested or propagated
# to downstream repos. A teardown step runs on exactly the hosts that
# accumulate garbage -- a host only accrues leftovers if it runs jobs, and
# if it runs jobs it sweeps. The one case it defers is the killed runner,
# whose leftovers are collected at the end of the next job to land there.
#
# Volumes are removed by layer 1 (the key proves ownership) and never by
# layer 2: a volume holds state, and its age says nothing about who owns
# it.
#
# Refs

set -euo pipefail

# The label CI stamps on the images it builds itself.
readonly _OWNER_LABEL='base.ci.run'

# Marker every CI-created NAME embeds: `ci-<run_id>-<run_attempt>`. run_id
# is an 11-digit integer in practice; the 4-digit floor keeps the pattern
# from matching an ordinary `ci-1-2`-shaped tag while staying usable in a
# test fixture.
readonly _NAME_MARKER='(^|[^[:alnum:]])ci-[0-9]{4,}-[0-9]+([^0-9]|$)'

_self="$(readlink -f -- "${BASH_SOURCE[0]:-$0}" 2>/dev/null \
  || printf '%s' "${BASH_SOURCE[0]:-$0}")"
readonly _self
_self_dir="$(dirname -- "${_self}")"
readonly _self_dir

_warn() {
  printf '[reclaim] WARNING: %s\n' "$*" >&2
}

_note() {
  printf '[reclaim] %s\n' "$*"
}

usage() {
  cat >&2 <<'EOF'
Usage: reclaim.sh [--run KEY] [--stale DURATION] [--dry-run] [-h|--help]

Remove the docker artifacts a CI run created -- and only those.

Options:
  --run KEY         Remove everything owned by run KEY (the
                    `<run_id>-<run_attempt>` value the workflow keys every
                    name to). Ownership is the `base.ci.run=KEY` label or
                    a name embedding `ci-KEY`. Covers containers,
                    networks, volumes and images.
  --stale DURATION  Also sweep CI-owned artifacts older than DURATION
                    (e.g. 12h, 30m, 2d) -- the backstop for a runner
                    killed before its teardown ran. Never touches volumes,
                    never touches an artifact with no ownership marker,
                    and never touches the --run KEY of this invocation.
                    Delegates dangling images / unattached networks /
                    buildx cache to the sibling prune.sh with the same
                    window.
  --dry-run         Print what would be removed; remove nothing.
  -h, --help        Show this help.

At least one of --run / --stale is required: a scopeless sweep is the
failure mode this script exists to avoid.
EOF
  exit 0
}

# _die <message> -- usage error, exit 2 (mirrors prune.sh).
_die() {
  printf '[reclaim] ERROR: %s\n' "$*" >&2
  exit 2
}

# _duration_seconds <duration> -- `12h` -> 43200. Exits 2 on garbage.
_duration_seconds() {
  local _d="${1}"
  [[ "${_d}" =~ ^([0-9]+)([smhd])$ ]] \
    || _die "not a duration: ${_d} (expected <N>s / <N>m / <N>h / <N>d)"
  local _n="${BASH_REMATCH[1]}" _u="${BASH_REMATCH[2]}"
  case "${_u}" in
    s) printf '%s' "${_n}" ;;
    m) printf '%s' "$(( _n * 60 ))" ;;
    h) printf '%s' "$(( _n * 3600 ))" ;;
    d) printf '%s' "$(( _n * 86400 ))" ;;
  esac
}

# ── the docker surface, one place ────────────────────────────────────
#
# Kept to four verbs per kind so the whole daemon interaction is auditable
# at a glance: list-by-label, list-id-and-name, created-at, remove. Note
# `docker images --format` has no `.Labels` field, which is why label
# matching goes through `--filter` for every kind rather than being read
# out of one listing.

# _ids_by_label <kind> <label-expr>
_ids_by_label() {
  local _kind="${1}" _expr="${2}"
  case "${_kind}" in
    container) docker ps -aq --filter "label=${_expr}" 2>/dev/null || true ;;
    image)     docker images -q --filter "label=${_expr}" 2>/dev/null || true ;;
    network)   docker network ls -q --filter "label=${_expr}" 2>/dev/null || true ;;
    volume)    docker volume ls -q --filter "label=${_expr}" 2>/dev/null || true ;;
  esac
}

# _ids_and_names <kind> -- `<id>|<name>` per line.
_ids_and_names() {
  local _kind="${1}"
  case "${_kind}" in
    container) docker ps -a --format '{{.ID}}|{{.Names}}' 2>/dev/null || true ;;
    image)     docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}' 2>/dev/null || true ;;
    network)   docker network ls --format '{{.ID}}|{{.Name}}' 2>/dev/null || true ;;
    volume)    docker volume ls --format '{{.Name}}|{{.Name}}' 2>/dev/null || true ;;
  esac
}

# _created_epoch <kind> <id> -- creation time as a unix timestamp, empty
# when the artifact vanished between listing and inspection (a concurrent
# job's teardown racing ours is normal, not an error).
_created_epoch() {
  local _kind="${1}" _id="${2}" _created=""
  _created="$(docker "${_kind}" inspect --format '{{.Created}}' "${_id}" 2>/dev/null)" \
    || return 0
  [[ -n "${_created}" ]] || return 0
  date -d "${_created}" +%s 2>/dev/null || true
}

# _remove <kind> <id>...
_remove() {
  local _kind="${1}"; shift
  (( $# > 0 )) || return 0
  if [[ "${DRY_RUN}" == true ]]; then
    _note "would remove ${_kind}: $*"
    return 0
  fi
  _note "removing ${_kind}: $*"
  case "${_kind}" in
    container) docker rm -f "$@" >/dev/null 2>&1 || _warn "could not remove container(s): $*" ;;
    image)     docker rmi -f "$@" >/dev/null 2>&1 || _warn "could not remove image(s): $*" ;;
    network)   docker network rm "$@" >/dev/null 2>&1 || _warn "could not remove network(s): $*" ;;
    volume)    docker volume rm -f "$@" >/dev/null 2>&1 || _warn "could not remove volume(s): $*" ;;
  esac
}

# ── ownership predicates ─────────────────────────────────────────────

# _name_owned_by <name> <key> -- true when the name embeds `ci-<key>` as a
# whole field. A plain substring test would let attempt 1 claim attempt
# 10's artifacts (`ci-1001-1` is a prefix of `ci-1001-10`) -- i.e. a
# re-running job deleting the attempt still in flight.
_name_owned_by() {
  local _name="${1}" _key="${2}"
  [[ "${_name}" =~ (^|[^[:alnum:]])ci-${_key}([^0-9]|$) ]]
}

# _name_is_ci <name> -- true when the name carries the run-key marker for
# SOME run. Used by the backstop, which does not know which run left it.
_name_is_ci() {
  [[ "${1}" =~ ${_NAME_MARKER} ]]
}

# ── layer 1: exact per-run teardown ──────────────────────────────────

_reclaim_run() {
  local _key="${1}"
  _note "reclaiming artifacts of run ${_key}"
  # Containers first (they hold images and attach networks), volumes and
  # networks next, images last.
  local _kind
  for _kind in container network volume image; do
    local -a _ids=()
    local _id _name _line
    while IFS= read -r _id; do
      [[ -n "${_id}" ]] && _ids+=("${_id}")
    done < <(_ids_by_label "${_kind}" "${_OWNER_LABEL}=${_key}")
    while IFS='|' read -r _id _name; do
      [[ -n "${_id}" ]] || continue
      _name_owned_by "${_name}" "${_key}" || continue
      _ids+=("${_id}")
    done < <(_ids_and_names "${_kind}")
    # De-duplicate: an artifact can match by both label and name.
    local -a _uniq=()
    while IFS= read -r _line; do
      [[ -n "${_line}" ]] && _uniq+=("${_line}")
    done < <(printf '%s\n' "${_ids[@]+"${_ids[@]}"}" | sort -u)
    _remove "${_kind}" "${_uniq[@]+"${_uniq[@]}"}"
  done
}

# ── layer 2: age-based backstop ──────────────────────────────────────

_reclaim_stale() {
  local _window="${1}" _exclude_key="${2}"
  local _seconds _now _cutoff
  _seconds="$(_duration_seconds "${_window}")"
  _now="$(date +%s)"
  _cutoff="$(( _now - _seconds ))"
  _note "sweeping CI-owned artifacts older than ${_window}"

  # Volumes are deliberately absent: age is no evidence of ownership for
  # a resource that holds state.
  local _kind
  for _kind in container network image; do
    local -a _ids=()
    local _id _name _created
    while IFS= read -r _id; do
      [[ -n "${_id}" ]] && _ids+=("${_id}")
    done < <(_ids_by_label "${_kind}" "${_OWNER_LABEL}")
    while IFS='|' read -r _id _name; do
      [[ -n "${_id}" ]] || continue
      _name_is_ci "${_name}" || continue
      _ids+=("${_id}")
    done < <(_ids_and_names "${_kind}")

    local -a _victims=()
    local _cand
    while IFS= read -r _cand; do
      [[ -n "${_cand}" ]] || continue
      # Never sweep the run doing the sweeping: a long re-run chain can
      # legitimately own artifacts older than the window.
      if [[ -n "${_exclude_key}" ]]; then
        local _skip=false _n
        while IFS='|' read -r _id _n; do
          [[ "${_id}" == "${_cand}" ]] || continue
          _name_owned_by "${_n}" "${_exclude_key}" && _skip=true
        done < <(_ids_and_names "${_kind}")
        [[ "${_skip}" == true ]] && continue
      fi
      _created="$(_created_epoch "${_kind}" "${_cand}")"
      [[ -n "${_created}" ]] || continue
      (( _created < _cutoff )) || continue
      _victims+=("${_cand}")
    done < <(printf '%s\n' "${_ids[@]+"${_ids[@]}"}" | sort -u)
    _remove "${_kind}" "${_victims[@]+"${_victims[@]}"}"
  done

  # The classes with no ownership marker at all. docker's own prune verbs
  # skip in-use resources, so this is safe on a shared host in a way a
  # blanket `system prune -a` is not: dangling images are untagged build
  # residue, `network prune` refuses a network with any container
  # attached, and buildx cache older than the window belongs to no
  # in-flight build.
  local _prune="${_self_dir}/../prune.sh"
  if [[ -x "${_prune}" || -f "${_prune}" ]]; then
    local -a _prune_args=(--all --until "${_window}")
    [[ "${DRY_RUN}" == true ]] && _prune_args+=(--dry-run)
    bash "${_prune}" "${_prune_args[@]}" \
      || _warn "prune.sh delegation failed (leftovers stay for the next sweep)"
  else
    _warn "prune.sh not found next to reclaim.sh; skipped the unowned classes"
  fi
}

main() {
  local RUN_KEY="" STALE=""
  DRY_RUN=false

  while (( $# )); do
    case "${1}" in
      -h|--help) usage ;;
      --run)     RUN_KEY="${2:?"--run requires a key"}"; shift 2 ;;
      --stale)   STALE="${2:?"--stale requires a duration"}"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      *)         _die "unknown flag: ${1}" ;;
    esac
  done
  readonly DRY_RUN

  if [[ -z "${RUN_KEY}" && -z "${STALE}" ]]; then
    _die "nothing scoped. Pass --run <key> and/or --stale <duration>."
  fi

  if [[ -n "${RUN_KEY}" ]]; then
    _reclaim_run "${RUN_KEY}"
  fi
  if [[ -n "${STALE}" ]]; then
    _reclaim_stale "${STALE}" "${RUN_KEY}"
  fi
}

main "$@"
