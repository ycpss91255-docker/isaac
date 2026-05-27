#!/usr/bin/env bash
# ci.sh - Run CI pipeline (ShellCheck + Bats [+ Kcov])
#
# Usage:
#   ./ci.sh                   # Run ShellCheck + Bats (fast dev loop)
#   ./ci.sh --ci              # Run inside CI container (called by compose)
#   ./ci.sh --lint-only       # Run ShellCheck only (via docker compose)
#   ./ci.sh --shellcheck-only # Run ShellCheck only, no compose, no bats deps
#                             # (used by self-test.yaml's dedicated shellcheck
#                             # job, #376; plain ubuntu-latest runner with
#                             # pre-installed shellcheck)
#   ./ci.sh --bats-only       # Run Bats only inside compose (skip ShellCheck)
#                             # (used by self-test.yaml's bats jobs, #376/#377)
#   ./ci.sh --bats-unit-shard N/T  # Run unit shard N of T (skip ShellCheck +
#                                  # integration). Used by the bats-unit
#                                  # matrix in self-test.yaml (#377)
#   ./ci.sh --bats-integration     # Run integration tests only (skip
#                                  # ShellCheck + unit). Used by the
#                                  # bats-integration job in self-test.yaml
#                                  # (#377)
#   ./ci.sh --coverage        # Run ShellCheck + Bats + Kcov coverage
#                             # (push-to-main only via self-test.yaml's
#                             # coverage job, #377)
#   ./ci.sh -h, --help        # Show this help
#
# Kcov instrumentation wraps every bats command and slows the suite
# 2-5x, so the default no longer runs it. Run `--coverage` (or
# `make coverage`) when you need the HTML report before releasing.

# Only set strict mode when running directly; when sourced, respect caller's settings
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  set -euo pipefail
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
readonly REPO_ROOT

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../docker/_lib.sh"

# ── Help ─────────────────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: ./ci.sh [OPTIONS]

Run CI pipeline: ShellCheck + Bats [+ Kcov coverage].

Options:
  --ci                    Run directly inside CI container (called by
                          compose); honors $COVERAGE=1 to include kcov,
                          $BATS_ONLY=1 to skip the ShellCheck phase,
                          $BATS_UNIT_SHARD to run only one matrix shard,
                          $BATS_INTEGRATION=1 to run integration only
  --lint-only             ShellCheck only (via docker compose)
  --shellcheck-only       ShellCheck only, directly, no compose; relies on
                          shellcheck already being in PATH (e.g. plain
                          ubuntu-latest GHA runner). Used by
                          self-test.yaml's dedicated shellcheck job (#376)
  --bats-only             Bats only inside compose (skip ShellCheck) (#376)
  --bats-unit-shard N/T   Run unit shard N of T (skip ShellCheck +
                          integration). Used by the bats-unit matrix in
                          self-test.yaml (#377)
  --bats-integration      Run integration tests only (skip ShellCheck +
                          unit). Used by the bats-integration job in
                          self-test.yaml (#377)
  --coverage              Run tests with Kcov coverage (slow; CI / release
                          check). Used by self-test.yaml's coverage job
                          (push-to-main only, #377)
  -h, --help              Show this help

Default (no flag): ShellCheck + bats via docker compose, no kcov.
Kcov wraps every bats command and slows the suite 2-5x, so the
dev-loop default skips it.

Examples:
  ./ci.sh                       # Fast: ShellCheck + Bats (no kcov)
  make test                     # Same as above
  ./ci.sh --coverage            # Full: ShellCheck + Bats + Kcov
  make coverage                 # Same as above
  make lint                     # ShellCheck only
  ./ci.sh --shellcheck-only     # Direct shellcheck, no compose
  ./ci.sh --bats-only           # Compose-bats only, skip ShellCheck
  ./ci.sh --bats-unit-shard 1/2 # Compose-bats unit shard 1 of 2
  ./ci.sh --bats-integration    # Compose-bats integration only
EOF
  exit 0
}

# ── CI container setup ───────────────────────────────────────────────────────

_die() { _log_err ci "$*"; exit 1; }

_install_deps() {
  command -v bats >/dev/null 2>&1 && return 0

  # Rewrite sources.list to use APT_MIRROR_DEBIAN before apt-get update.
  # Default deb.debian.org is unreachable on some networks (regional outage,
  # ISP routing, captive portals) while the configured mirror responds. The
  # env var is plumbed through by compose.yaml; only rewrite when it actually
  # differs from the default so unaffected networks keep using the upstream.
  local _mirror="${APT_MIRROR_DEBIAN:-deb.debian.org}"
  if [[ "${_mirror}" != "deb.debian.org" ]]; then
    [[ -f /etc/apt/sources.list ]] \
      && sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list
    if compgen -G '/etc/apt/sources.list.d/*.list' >/dev/null; then
      sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.list
    fi
    if compgen -G '/etc/apt/sources.list.d/*.sources' >/dev/null; then
      sed -i "s|deb.debian.org|${_mirror}|g" /etc/apt/sources.list.d/*.sources
    fi
  fi

  apt-get update -qq \
    || _die "apt-get update failed. Check network / apt mirror reachability."

  # `make` is needed by integration tests that exercise the downstream
  # Makefile recipes (#175 / #182). The kcov image's apt repo doesn't
  # ship it by default, so without this the upgrade-check integration
  # tests fail with exit 127 only under `make coverage` (the same tests
  # pass under `make test`, where the alpine test-tools image bundles
  # make from #182).
  apt-get install -y --no-install-recommends \
      bats bats-support bats-assert \
      shellcheck git ca-certificates \
      parallel make \
    || _die "apt-get install failed for bats/shellcheck deps."

  # bats-mock is distro-packaged on newer distros but missing on bookworm,
  # so we always pin to upstream v1.2.5 for reproducibility.
  git clone --depth 1 -b v1.2.5 \
      https://github.com/jasonkarns/bats-mock /usr/lib/bats/bats-mock \
    || _die "git clone bats-mock failed. Check network / GitHub access."
}

# ── ShellCheck ───────────────────────────────────────────────────────────────

_run_shellcheck() {
  echo "--- Running ShellCheck ---"
  find "${REPO_ROOT}/script/docker" -maxdepth 1 -name "*.sh" -print0 | xargs -0 shellcheck -x
  # #284: sub-libs under script/docker/lib/ also need linting; gitignore.sh
  # has lived there unlinted since #172, this picks up both that file and
  # the post-#284 sub-libs (log / env / conf / compose / config_summary).
  find "${REPO_ROOT}/script/docker/lib" -name "*.sh" -print0 | xargs -0 shellcheck -x
  shellcheck -x "${REPO_ROOT}/script/ci/ci.sh"
  shellcheck -x "${REPO_ROOT}/init.sh"
  shellcheck -x "${REPO_ROOT}/upgrade.sh"
  shellcheck -x "${REPO_ROOT}/config/shell/terminator/setup.sh"
  shellcheck -x "${REPO_ROOT}/config/shell/tmux/setup.sh"
}

# ── Bats tests ───────────────────────────────────────────────────────────────

_bats_args_with_label() {
  # Shared helper: populate the caller-supplied array name with the
  # `--jobs N` argument when GNU parallel is available, and set the
  # caller-supplied label var. Reused by every _run_*_tests function so
  # parallelism + fallback messaging stay in one place. Inputs:
  #   $1 = name of array var (e.g. _bats_args)
  #   $2 = name of label string var (e.g. _label)
  # All specs use per-test mktemp dirs (BATS_TEST_TMPDIR / TEMP_DIR) so
  # there's no shared filesystem state between tests — safe to run
  # concurrently. When parallel is missing (earlier alpine test-tools
  # images pre-#168), fall back to serial bats — slower but correct.
  local -n _out_args="$1"
  local -n _out_label="$2"
  _out_args=()
  if command -v parallel >/dev/null 2>&1; then
    local _jobs
    _jobs="$(nproc 2>/dev/null || echo 4)"
    _out_args=(--jobs "${_jobs}")
    _out_label="jobs=${_jobs}"
  else
    _out_label="serial; parallel not in PATH"
  fi
}

_run_unit_tests() {
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Unit Tests (${_label}) ---"
  bats "${_bats_args[@]}" "${REPO_ROOT}/test/unit/"
}

_run_integration_tests() {
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Integration Tests (${_label}) ---"
  bats "${_bats_args[@]}" "${REPO_ROOT}/test/integration/"
}

_run_tests() {
  # Wrapper retained for the full sequential dev-loop path (local
  # `make test`). Kept so refactors are localised; the CI matrix shard
  # jobs go through _run_unit_shard / _run_integration_tests directly.
  _run_unit_tests
  _run_integration_tests
}

_run_unit_shard() {
  # Run a deterministic subset of test/unit/*_spec.bats for the GHA
  # bats-unit matrix (#377). Spec accepts `<n>/<total>` where 1<=n<=total.
  # Round-robin partition over `find ... | sort` so the mapping is stable
  # across runs regardless of which files were added since the last
  # matrix tuning. Issue #377 notes weight-by-test-count as a deferred
  # follow-up; round-robin keeps each shard's count balanced enough at
  # the current 30-ish unit spec scale.
  local _spec="${1:?BUG: _run_unit_shard expects <n>/<total>}"
  if [[ "${_spec}" != */* ]]; then
    _die "Invalid shard spec '${_spec}'. Expected <n>/<total> (e.g. 1/2)."
  fi
  local _shard="${_spec%/*}"
  local _total="${_spec#*/}"
  if ! [[ "${_shard}" =~ ^[0-9]+$ && "${_total}" =~ ^[0-9]+$ ]] \
       || (( _shard < 1 || _shard > _total )); then
    _die "Invalid shard spec '${_spec}'. Need 1<=n<=total."
  fi
  local _files
  _files=$(find "${REPO_ROOT}/test/unit" -maxdepth 1 -name '*_spec.bats' -print \
             | sort \
             | awk -v s="${_shard}" -v t="${_total}" 'NR % t == (s - 1) % t')
  if [[ -z "${_files}" ]]; then
    _die "No spec files matched shard ${_spec}. Empty test/unit/ ?"
  fi
  local -a _bats_args
  local _label
  _bats_args_with_label _bats_args _label
  echo "--- Running Bats Unit Shard ${_spec} (${_label}) ---"
  # Word-split intentional: print one line per shard file.
  # shellcheck disable=SC2086
  printf '  shard:%s\n' ${_files}
  # Word-split intentional: bats accepts multiple file args.
  # shellcheck disable=SC2086
  bats "${_bats_args[@]}" ${_files}
}

# ── Kcov coverage ────────────────────────────────────────────────────────────

_run_coverage() {
  local _excludes=(
    "${REPO_ROOT}/test/"
    "${REPO_ROOT}/script/ci/"
    "${REPO_ROOT}/init.sh"
    "${REPO_ROOT}/upgrade.sh"
    "${REPO_ROOT}/config/shell/bashrc"
    "${REPO_ROOT}/config/shell/terminator/config"
    "${REPO_ROOT}/config/shell/tmux/tmux.conf"
    "${REPO_ROOT}/.github/"
  )
  local _exclude_path
  _exclude_path="$(IFS=,; printf '%s' "${_excludes[*]}")"

  echo "--- Running Tests with Kcov Coverage ---"
  kcov \
    --include-path="${REPO_ROOT}" \
    --exclude-path="${_exclude_path}" \
    "${REPO_ROOT}/coverage" \
    bats "${REPO_ROOT}/test/unit/" "${REPO_ROOT}/test/integration/"
}

# ── Fix coverage permissions ─────────────────────────────────────────────────

_fix_permissions() {
  local uid="${HOST_UID:-}"
  local gid="${HOST_GID:-}"
  if [[ -n "${uid}" && -n "${gid}" && -d "${REPO_ROOT}/coverage" ]]; then
    chown -R "${uid}:${gid}" "${REPO_ROOT}/coverage"
  fi
}

# ── Docker compose wrapper ───────────────────────────────────────────────────

_run_via_compose() {
  # Service is the first arg so the caller picks the runner image:
  #   `ci`       — alpine test-tools (bats/shellcheck/hadolint baked in,
  #                no apt-install on each run; fast dev loop)
  #   `coverage` — kcov/kcov (debian; needs apt-install via _install_deps,
  #                opt-in APT_MIRROR_DEBIAN rewrite for unreachable mirrors)
  #
  # BATS_ONLY is forwarded so the inner `--ci` dispatch can skip
  # _run_shellcheck when the dedicated GHA shellcheck job (#376) is
  # covering it in parallel. Default 0 keeps the local `make test`
  # path unchanged (full shellcheck + bats).
  #
  # BATS_UNIT_SHARD / BATS_INTEGRATION (#377) route the matrix
  # bats-unit + bats-integration GHA jobs to the right subset inside
  # the container; empty / 0 keep the local `make test` path
  # unchanged (full unit + integration).
  local _service="${1:-ci}"
  local _coverage="${2:-0}"
  docker compose -f "${REPO_ROOT}/compose.yaml" run --rm \
    -e HOST_UID="$(id -u)" \
    -e HOST_GID="$(id -g)" \
    -e COVERAGE="${_coverage}" \
    -e BATS_ONLY="${BATS_ONLY:-0}" \
    -e BATS_UNIT_SHARD="${BATS_UNIT_SHARD:-}" \
    -e BATS_INTEGRATION="${BATS_INTEGRATION:-0}" \
    "${_service}"
}

# ── Behavioural runtime-test specs (#249) ────────────────────────────────────
#
# Opt-in path. Requires the ci-behavioural compose service (mounts host
# /var/run/docker.sock + sets MOUNT_DOCKER_SOCK=1). Drives
# `docker buildx build --target runtime-test` against synthesized
# fixtures so the runtime smoke gate is actually exercised end-to-end,
# not just static-grep asserted.

readonly _BEHAVIOURAL_BUILDER="template-behavioural"

_behavioural_setup() {
  [[ -S /var/run/docker.sock ]] \
    || _die "behavioural mode requires /var/run/docker.sock; run via 'make test-behavioural' (ci-behavioural service)."
  command -v docker >/dev/null 2>&1 \
    || _die "behavioural mode requires docker CLI in the test-tools image (test-tools < v0.23.2 lacks it)."

  # Dedicated buildx builder isolates the cache from the host's default
  # context, so prune at the end only touches our cache (not the user's
  # other docker work). `--use` switches active builder for this process.
  if ! docker buildx inspect "${_BEHAVIOURAL_BUILDER}" >/dev/null 2>&1; then
    docker buildx create --name "${_BEHAVIOURAL_BUILDER}" --driver docker-container --bootstrap >/dev/null
  fi
  docker buildx use "${_BEHAVIOURAL_BUILDER}"
}

_behavioural_teardown() {
  # Prune only the dedicated builder's cache. Leaves the host's default
  # context untouched so the user's other docker workflows aren't
  # disturbed. `|| true` because builder may already be gone if
  # something earlier aborted partway through.
  docker buildx prune --builder "${_BEHAVIOURAL_BUILDER}" -af >/dev/null 2>&1 || true
}

_run_behavioural() {
  _behavioural_setup
  trap _behavioural_teardown EXIT

  local -a _bats_args=()
  local _jobs
  _jobs="$(nproc 2>/dev/null || echo 1)"
  if command -v parallel >/dev/null 2>&1; then
    _bats_args=(--jobs "${_jobs}")
  fi

  bats "${_bats_args[@]}" "${REPO_ROOT}/test/behavioural/"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  local mode="compose"
  local behavioural=0
  local bats_only=0
  local shellcheck_only=0
  local bats_unit_shard=""
  local bats_integration=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage ;;
      --ci) mode="ci"; shift ;;
      --lint-only) mode="lint"; shift ;;
      --shellcheck-only) shellcheck_only=1; shift ;;
      --bats-only) bats_only=1; shift ;;
      --bats-unit-shard) bats_unit_shard="${2:?--bats-unit-shard expects <n>/<total>}"; shift 2 ;;
      --bats-integration) bats_integration=1; shift ;;
      --coverage) mode="coverage"; shift ;;
      --behavioural) behavioural=1; shift ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  # --shellcheck-only short-circuits before any mode dispatch. It runs
  # the lint phase directly on the host (no compose, no apt-install).
  # Caller is responsible for having the linter binary in PATH — the
  # dedicated self-test.yaml shellcheck job (#376) uses plain
  # ubuntu-latest, which ships it pre-installed.
  if [[ "${shellcheck_only}" == "1" ]]; then
    _run_shellcheck
    return 0
  fi

  case "${mode}" in
    ci)
      # Running inside container. Default path skips kcov for speed
      # (the dev loop is far more frequent than the coverage check).
      # Pass COVERAGE=1 via the outer `--coverage` flag to include it.
      # `--behavioural` swaps the bats invocation to drive
      # `docker buildx build` against runtime-test fixtures (#249).
      # BATS_ONLY=1 (set by `--bats-only` outer flag, plumbed via
      # `_run_via_compose`) skips the ShellCheck phase — the dedicated
      # self-test.yaml shellcheck job covers it in parallel (#376).
      # BATS_UNIT_SHARD / BATS_INTEGRATION (#377) route this dispatch
      # to a matrix-shard / integration-only subset; the dedicated GHA
      # bats-unit / bats-integration jobs set these via the outer
      # `--bats-unit-shard` / `--bats-integration` flags so the
      # in-container path matches the local dev path.
      if [[ "${behavioural}" == "1" ]]; then
        _install_deps
        _run_behavioural
        _fix_permissions
        return 0
      fi
      _install_deps
      if [[ "${BATS_ONLY:-0}" != "1" ]]; then
        _run_shellcheck
      fi
      if [[ "${COVERAGE:-0}" == "1" ]]; then
        _run_coverage
        _fix_permissions
        echo "Coverage report: ${REPO_ROOT}/coverage/index.html"
      elif [[ -n "${BATS_UNIT_SHARD:-}" ]]; then
        _run_unit_shard "${BATS_UNIT_SHARD}"
      elif [[ "${BATS_INTEGRATION:-0}" == "1" ]]; then
        _run_integration_tests
      else
        _run_tests
      fi
      ;;
    lint)
      # ShellCheck only — requires shellcheck installed locally
      _run_shellcheck
      ;;
    coverage)
      # Full CI + kcov via the kcov/kcov-based `coverage` service.
      _run_via_compose coverage 1
      ;;
    compose)
      # Default: fast CI (shellcheck + bats, no kcov) via the alpine
      # test-tools-based `ci` service. Flag-driven plumbing of the
      # relevant env vars selects the inner branch:
      #   --bats-only          -> BATS_ONLY=1 (skip _run_shellcheck)
      #   --bats-unit-shard X  -> BATS_ONLY=1 + BATS_UNIT_SHARD=X
      #   --bats-integration   -> BATS_ONLY=1 + BATS_INTEGRATION=1
      # Local `make test` (no flags) keeps the full pipeline.
      if [[ -n "${bats_unit_shard}" ]]; then
        BATS_ONLY=1 BATS_UNIT_SHARD="${bats_unit_shard}" _run_via_compose ci 0
      elif [[ "${bats_integration}" == "1" ]]; then
        BATS_ONLY=1 BATS_INTEGRATION=1 _run_via_compose ci 0
      elif [[ "${bats_only}" == "1" ]]; then
        BATS_ONLY=1 _run_via_compose ci 0
      else
        _run_via_compose ci 0
      fi
      ;;
  esac
}

# Guard: only run main when executed directly, not when sourced (for testing)
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" ]]; then
  main "$@"
fi
