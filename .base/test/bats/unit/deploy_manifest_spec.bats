#!/usr/bin/env bats
#
# Tests for the field-deploy tunable-config manifest primitives in
# dist/script/docker/lib/deploy.sh: _parse_deploy_manifest (per-stage path
# declarations) and _collect_deploy_binds (per-component aggregation +
# basename-collision guard). base delivers the files a manifest names; it
# does not parse their content. A missing manifest = nothing tunable (all
# baked, the fail-safe default); a malformed manifest fails loud.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh
}

_write_manifest() {
  local _path="${1}"; shift
  mkdir -p "$(dirname -- "${_path}")"
  printf '%s\n' "$@" > "${_path}"
}

# ════════════════════════════════════════════════════════════════════
# _parse_deploy_manifest
# ════════════════════════════════════════════════════════════════════

@test "_parse_deploy_manifest: returns only the requested stage's paths (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" \
    "[runtime]" "/camera_config.yaml" "/etc/app/host.yaml" \
    "[stream]" "/etc/stream.yaml"
  local -a _paths=()
  _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths
  assert_equal "${#_paths[@]}" "2"
  assert_equal "${_paths[0]}" "/camera_config.yaml"
  assert_equal "${_paths[1]}" "/etc/app/host.yaml"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a path unlisted for the stage stays baked-only (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" \
    "[runtime]" "/camera_config.yaml" \
    "[stream]" "/etc/stream.yaml"
  local -a _paths=()
  _parse_deploy_manifest "${_d}/deploy.manifest" stream _paths
  assert_equal "${#_paths[@]}" "1"
  assert_equal "${_paths[0]}" "/etc/stream.yaml"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: skips blank + comment lines and trims whitespace (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" \
    "# tunable config for the field" \
    "" \
    "  [runtime]  " \
    "   /camera_config.yaml   " \
    "# udev rules are baked-only"
  local -a _paths=()
  _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths
  assert_equal "${#_paths[@]}" "1"
  assert_equal "${_paths[0]}" "/camera_config.yaml"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: an unflagged path is read-only, an explicit rw opts in (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" \
    "[runtime]" "/camera_config.yaml" "  /var/lib/app/calib.yaml   rw  "
  local -a _paths=() _modes=("stale")
  _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths _modes
  assert_equal "${#_paths[@]}" "2"
  assert_equal "${_paths[0]}" "/camera_config.yaml"
  assert_equal "${_paths[1]}" "/var/lib/app/calib.yaml"
  assert_equal "${#_modes[@]}" "2"
  assert_equal "${_modes[0]}" "ro"
  assert_equal "${_modes[1]}" "rw"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: an explicit ro flag is accepted (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" "[runtime]" "/etc/app/host.yaml ro"
  local -a _paths=() _modes=()
  _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths _modes
  assert_equal "${_paths[0]}" "/etc/app/host.yaml"
  assert_equal "${_modes[0]}" "ro"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: an unknown access flag fails loud naming file and line (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" \
    "[runtime]" "/camera_config.yaml" "/etc/app/host.yaml write"
  local -a _paths=() _modes=()
  run _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths _modes
  assert_failure
  assert_output --partial "malformed manifest"
  assert_output --partial "${_d}/deploy.manifest:3"
  assert_output --partial "write"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a trailing token after a valid flag fails loud (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" "[runtime]" "/etc/app/host.yaml rw ro"
  local -a _paths=() _modes=()
  run _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths _modes
  assert_failure
  assert_output --partial "malformed manifest"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a missing manifest is not an error -> empty (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  local -a _paths=("stale")
  run _parse_deploy_manifest "${_d}/nope.manifest" runtime _paths
  assert_success
  _parse_deploy_manifest "${_d}/nope.manifest" runtime _paths
  assert_equal "${#_paths[@]}" "0"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a malformed section header fails loud (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" "[Runtime]" "/camera_config.yaml"
  local -a _paths=()
  run _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths
  assert_failure
  assert_output --partial "malformed manifest"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a non-absolute content line fails loud (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" "[runtime]" "camera_config.yaml"
  local -a _paths=()
  run _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths
  assert_failure
  assert_output --partial "absolute container path"
  rm -rf "${_d}"
}

@test "_parse_deploy_manifest: a path before any section fails loud (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/deploy.manifest" "/camera_config.yaml" "[runtime]"
  local -a _paths=()
  run _parse_deploy_manifest "${_d}/deploy.manifest" runtime _paths
  assert_failure
  assert_output --partial "before any"
  rm -rf "${_d}"
}

# ════════════════════════════════════════════════════════════════════
# _collect_deploy_binds
# ════════════════════════════════════════════════════════════════════

@test "_collect_deploy_binds: aggregates every component's stage paths keyed by basename (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/config/camera/deploy.manifest" "[runtime]" "/camera_config.yaml"
  _write_manifest "${_d}/config/stream/deploy.manifest" "[runtime]" "/etc/app/host.yaml"
  local -A _binds=()
  _collect_deploy_binds "${_d}" runtime _binds
  assert_equal "${_binds[camera_config.yaml]}" "/camera_config.yaml"
  assert_equal "${_binds[host.yaml]}" "/etc/app/host.yaml"
  rm -rf "${_d}"
}

@test "_collect_deploy_binds: carries each path's access mode keyed by basename (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/config/camera/deploy.manifest" "[runtime]" "/camera_config.yaml"
  _write_manifest "${_d}/config/calib/deploy.manifest" "[runtime]" "/var/lib/app/calib.yaml rw"
  local -A _binds=() _modes=([stale]=x)
  _collect_deploy_binds "${_d}" runtime _binds _modes
  assert_equal "${#_modes[@]}" "2"
  assert_equal "${_modes[camera_config.yaml]}" "ro"
  assert_equal "${_modes[calib.yaml]}" "rw"
  rm -rf "${_d}"
}

@test "_collect_deploy_binds: no manifests -> empty map (nothing tunable) (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  mkdir -p "${_d}/config/camera"
  local -A _binds=([stale]=x)
  _collect_deploy_binds "${_d}" runtime _binds
  assert_equal "${#_binds[@]}" "0"
  rm -rf "${_d}"
}

@test "_collect_deploy_binds: duplicate basename across components fails loud (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/config/a/deploy.manifest" "[runtime]" "/etc/a/host.yaml"
  _write_manifest "${_d}/config/b/deploy.manifest" "[runtime]" "/etc/b/host.yaml"
  local -A _binds=()
  run _collect_deploy_binds "${_d}" runtime _binds
  assert_failure
  assert_output --partial "duplicate tunable basename"
  rm -rf "${_d}"
}

@test "_collect_deploy_binds: propagates a malformed manifest failure (tunable-manifest)" {
  local _d; _d="$(mktemp -d)"
  _write_manifest "${_d}/config/a/deploy.manifest" "[runtime]" "not-absolute"
  local -A _binds=()
  run _collect_deploy_binds "${_d}" runtime _binds
  assert_failure
  assert_output --partial "malformed manifest"
  rm -rf "${_d}"
}
