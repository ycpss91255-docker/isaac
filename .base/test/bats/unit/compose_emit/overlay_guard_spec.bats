#!/usr/bin/env bats
#
# Forward-invariant guard (ADR-00000022): base's emitted compose.yaml must
# never bake a hardcoded per-instance literal over the known per-instance
# field set. Every field that can collide across co-located instances is
# emitted as an overlay-overridable compose interpolation (${VAR:-default}
# or ${VAR}), so a multi_run .env overlay can isolate an instance without a
# retroactive base change. This turns "base-generated stacks are
# multi_run-expandable" from discipline into a machine-enforced guarantee:
# a future change that hardcodes a per-instance field fails here immediately.
#
# The override channels differ by field kind (recorded in ADR-00000022):
#   - structural interpolation (${VAR}): project name, container_name,
#     network_mode, ports  -- checked here.
#   - .env env_file overlay + baked ENV: workload env vars (ROS_DOMAIN_ID
#     and friends).
#   - compose-merge overlay: writable volume topology.
#   - host-bound / shared across co-located instances (NOT per-instance):
#     runtime, hostname, GPU.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/../test_helper"

  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM scratch AS sys
FROM sys AS devel-base
FROM devel-base AS devel
FROM devel AS devel-test
FROM devel AS headless
EOF
  mkdir -p "${TEMP_DIR}"
}

teardown() {
  rm -rf "${TEMP_DIR}"
}

# A per-instance field value is overlay-overridable iff it carries a compose
# ${...} interpolation (an .env overlay can override it), not a fully-baked
# literal. This is the guard's discrimination predicate.
_is_overlay_overridable() {
  [[ "$1" == *'${'*'}'* ]]
}

# Emit a compose that exercises the interpolation-channel per-instance
# fields on both the devel service and a per-stage standalone block:
# bridge network (-> network_mode: line + ports honoured), devel ports,
# and a [stage:headless] with its own ports override.
_emit_exercised_compose() {
  cat > "${TEMP_DIR}/.setup.conf" <<'CONF'
[stage:headless]
network.mode = bridge
network.port_inherit = false
network.port_1 = 5000:5000
network.port_2 = 6000:6000
CONF
  local _extras=('/home/u/repo:/home/u/repo:rw')
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" $'8080:80\n9090:90' \
    "" "bridge" "host"
}

# ── Predicate self-check: proves the guard FAILS on a baked literal ─────

@test "overlay guard predicate rejects a baked literal, accepts an interpolation" {
  # A hardcoded per-instance literal (what a regression would emit).
  run _is_overlay_overridable '8080:80'
  assert_failure
  # The overlay-overridable form the emitter must produce.
  run _is_overlay_overridable '${PORT_1:-8080:80}'
  assert_success
  run _is_overlay_overridable '${NETWORK_MODE}'
  assert_success
}

# ── Forward invariant over the interpolation-channel field set ──────────

@test "overlay guard: project name: is an overlay interpolation" {
  _emit_exercised_compose
  local _val
  _val="$(grep -E '^name:' "${COMPOSE_OUT}" | head -1 | sed -E 's/^name:[[:space:]]*//')"
  _is_overlay_overridable "${_val}"
}

@test "overlay guard: every container_name: carries an interpolation (not a baked literal)" {
  _emit_exercised_compose
  local _line _val
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _val="$(sed -E 's/^[[:space:]]*container_name:[[:space:]]*//' <<< "${_line}")"
    _is_overlay_overridable "${_val}" \
      || { echo "baked container_name literal: ${_val}"; return 1; }
  done < <(grep -E '^[[:space:]]*container_name:' "${COMPOSE_OUT}")
}

@test "overlay guard: network_mode: is an env interpolation, never a baked literal" {
  _emit_exercised_compose
  local _line _val
  while IFS= read -r _line; do
    [[ -z "${_line}" ]] && continue
    _val="$(sed -E 's/^[[:space:]]*network_mode:[[:space:]]*//' <<< "${_line}")"
    _is_overlay_overridable "${_val}" \
      || { echo "baked network_mode literal: ${_val}"; return 1; }
  done < <(grep -E '^[[:space:]]*network_mode:' "${COMPOSE_OUT}")
}

@test "overlay guard: no baked published-port literal anywhere (forward invariant)" {
  _emit_exercised_compose
  # A baked port entry is a quoted list item beginning with a digit under a
  # ports: block (host:container[/proto], optionally IP-prefixed). After the
  # fix every port is emitted as ${PORT_N:-<default>}, so a numeric-leading
  # quoted entry means a per-instance literal leaked back in.
  run grep -nE '^[[:space:]]+- "[0-9][0-9.]*:' "${COMPOSE_OUT}"
  assert_failure
}

@test "overlay guard: published ports are emitted as \${PORT_N:-default} on devel and stages" {
  _emit_exercised_compose
  # devel ports (from the top-level list) and the headless stage's ports
  # (from [stage:headless] override) are all overlay interpolations, with the
  # setup.conf value preserved as the :- default (single-run behaviour). The
  # index is 1-based (PORT_1 = first port) to match base's indexed-key
  # convention (port_1 / mount_1 / arg_1).
  run grep -F -- '- "${PORT_1:-8080:80}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_2:-9090:90}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_1:-5000:5000}"' "${COMPOSE_OUT}"
  assert_success
  run grep -F -- '- "${PORT_2:-6000:6000}"' "${COMPOSE_OUT}"
  assert_success
}
