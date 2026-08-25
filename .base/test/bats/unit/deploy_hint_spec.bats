#!/usr/bin/env bats
#
# Regression tests for the "regenerate this artifact" hints the field-deploy
# generator stamps into what it emits (the resolved compose header and the
# deploy.sh launcher) plus the sibling hint in the shipped cd-guard.sh.
#
# Why this file exists: the hints used to print a bare positional stage
# (`just setup deploy runtime`), but `_setup_deploy` parses only
# --stage / -o / --dry-run / -y / -q, so a positional hits its `*)` branch
# and errors "unknown arg" -- copy-pasting the printed hint failed. These
# tests assert the emitted hint is a form the parser actually accepts
# (base#843). Lives apart from deploy_spec.bats so the hint contract has a
# named home instead of hiding inside the generator's behavioural specs.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
}

_write_hint_repo() {
  local _dir="${1}"
  mkdir -p "${_dir}"
  printf '%s\n' "[deploy]" "gpu_mode = off" "dri_groups = off" \
    "[gui]" "mode = off" > "${_dir}/.setup.conf"
  cat > "${_dir}/Dockerfile" <<'DOCK'
FROM scratch AS sys
FROM sys AS devel
FROM devel AS runtime
CMD ["/app"]
DOCK
}

# Pull the `deploy` argument list out of a printed hint line: everything
# after the literal `deploy` token, so the assertion exercises the real
# emitted string rather than a hand-copied duplicate of it.
_hint_args() {
  local _line="${1}"
  _line="${_line#*deploy }"
  printf '%s\n' "${_line}"
}

@test "resolved compose header hint uses --stage, not a bare positional stage (#843)" {
  local _d; _d="$(mktemp -d)"
  _write_hint_repo "${_d}"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  run grep -m1 'Regenerate' "${_d}/compose.yaml"
  assert_success
  assert_output --partial "just setup deploy --stage runtime"
  rm -rf "${_d}"
}

@test "deploy.sh launcher hint uses --stage, not a bare positional stage (#843)" {
  local _d; _d="$(mktemp -d)"
  _generate_deploy_launcher "${_d}/deploy.sh" runtime
  run grep -m1 'Regenerate' "${_d}/deploy.sh"
  assert_success
  assert_output --partial "just setup deploy --stage runtime"
  rm -rf "${_d}"
}

@test "cd-guard.sh documents the --stage form of the deploy command (#843)" {
  run grep -m1 'before .just setup deploy' /source/dist/deploy/cd-guard.sh
  assert_success
  assert_output --partial "just setup deploy --stage <stage>"
}

@test "the compose-header hint's args are accepted by the deploy arg parser (#843)" {
  local _d; _d="$(mktemp -d)"
  _write_hint_repo "${_d}"
  local -A _binds=()
  SETUP_DETECT_DRI_GROUPS="" _generate_resolved_compose \
    "${_d}" runtime "img" "name" "${_d}/compose.yaml" _binds
  local _hint _args
  _hint="$(grep -m1 'Regenerate' "${_d}/compose.yaml")"
  _args="$(_hint_args "${_hint}")"
  # Word-splitting is the point: replay the printed args as real argv.
  # shellcheck disable=SC2086
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" ${_args} --dry-run
  assert_success
  refute_output --partial "unknown arg"
  assert_output --partial "deploy plan: stage=runtime"
  rm -rf "${_d}"
}

@test "the launcher hint's args are accepted by the deploy arg parser (#843)" {
  local _d; _d="$(mktemp -d)"
  _write_hint_repo "${_d}"
  # The stage must be a deployable one: the hint is replayed through the
  # real parser, which enforces stage eligibility (PRD invariant 8).
  _generate_deploy_launcher "${_d}/deploy.sh" runtime
  local _hint _args
  _hint="$(grep -m1 'Regenerate' "${_d}/deploy.sh")"
  _args="$(_hint_args "${_hint}")"
  # shellcheck disable=SC2086
  SETUP_DETECT_DRI_GROUPS="" run _setup_deploy --base-path "${_d}" ${_args} --dry-run
  assert_success
  refute_output --partial "unknown arg"
  assert_output --partial "deploy plan: stage=runtime"
  rm -rf "${_d}"
}
