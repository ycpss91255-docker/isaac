#!/usr/bin/env bash
#
# resolve.sh - mode+detection -> final-state resolvers + conf hashing.
#
# Turn the [gpu]/[gui]/[network] modes (auto/force/off) plus host detection
# into the final enabled state setup.sh writes to .env: _resolve_gpu /
# _resolve_gui / _resolve_runtime / _resolve_build_network, the detection
# helpers they consume (_detect_jetson / _detect_dri_groups), and
# _compute_conf_hash (the setup.conf content hash that drives drift detection).
#
# Extracted from setup.sh (ADR-00000014, epic decompose-setup-sh). Calls into
# the conf accessors + _setup_msg + globals in setup.sh; all resolve at
# call-time via the _lib.sh load order.

# Guard against double-sourcing.
if [[ -n "${_DOCKER_LIB_RESOLVE_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_RESOLVE_SOURCED=1

# ════════════════════════════════════════════════════════════════════
# Resolvers: mode + detection → final enabled state
# ════════════════════════════════════════════════════════════════════

# _resolve_gpu <mode> <detected> <outvar>
#   mode=auto   → enabled iff detected==true
#   mode=force  → always enabled
#   mode=off    → always disabled
_resolve_gpu() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rg_out="${3:?}"
  case "${_mode}" in
    force) _rg_out="true" ;;
    off)   _rg_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rg_out="true"; else _rg_out="false"; fi
      ;;
  esac
}

# _resolve_gui <mode> <detected> <outvar>
_resolve_gui() {
  local _mode="${1:?}"
  local _detected="${2:?}"
  local -n _rgu_out="${3:?}"
  case "${_mode}" in
    force) _rgu_out="true" ;;
    off)   _rgu_out="false" ;;
    auto|*)
      if [[ "${_detected}" == "true" ]]; then _rgu_out="true"; else _rgu_out="false"; fi
      ;;
  esac
}

# _detect_jetson
#   True if running on Jetson (JetPack / L4T) — NVIDIA ships
#   /etc/nv_tegra_release as the canonical marker on tegra-based boards.
#
#   Operator override (supported, documented in README + setup.sh --help):
#   SETUP_DETECT_JETSON=true|false forces the detection result and skips
#   the /etc/nv_tegra_release probe. Real use: simulate a Jetson on
#   non-Jetson hardware (so runtime / build-net auto-promotion applies),
#   or pin the result on a host where the marker is absent or untrusted.
#   This is a first-class knob over auto-detection, not a test-only hook.
_detect_jetson() {
  if [[ -n "${SETUP_DETECT_JETSON:-}" ]]; then
    [[ "${SETUP_DETECT_JETSON}" == "true" ]]
    return
  fi
  [[ -f "/etc/nv_tegra_release" ]]
}

# _detect_dri_groups
#   Echo space-separated unique numeric GIDs that own the host's
#   /dev/dri/{card*,renderD*} nodes so a container can be granted
#   /dev/dri access via group_add on non-NVIDIA (Intel/AMD iGPU) hosts.
#   Numeric GIDs only -- the render GID varies per host, so names are
#   non-portable. Echoes empty when /dev/dri is absent (graceful).
#
#   Operator override (supported, documented in README + setup.sh --help):
#   SETUP_DETECT_DRI_GROUPS (space-separated GIDs) forces the result and
#   skips the /dev/dri stat. Real use: containerised / CI hosts where the
#   /dev/dri render-group GIDs differ from the build host, or pinning the
#   GIDs the container is granted via group_add. A first-class knob over
#   auto-detection, not a test-only hook.
_detect_dri_groups() {
  if [[ -n "${SETUP_DETECT_DRI_GROUPS:-}" ]]; then
    printf '%s' "${SETUP_DETECT_DRI_GROUPS}"
    return 0
  fi
  local _gids
  # stat over a non-matching glob just yields no output (stderr suppressed);
  # sort -u dedups the common case where card* + renderD* share the video GID.
  _gids="$(stat -c %g /dev/dri/card* /dev/dri/renderD* 2>/dev/null \
             | sort -u | tr '\n' ' ')"
  printf '%s' "${_gids% }"
}

# _resolve_runtime <mode> <outvar>
#   mode=nvidia → "nvidia" (force, e.g. desktop with csv-mode toolkit)
#   mode=auto   → "nvidia" iff _detect_jetson, else ""
#   mode=off|"" → "" (no runtime key emitted; Docker default runc)
#
# When non-empty, setup.sh emits `runtime: <value>` at service level in
# compose.yaml. Required on Jetson because its nvidia-container-toolkit
# runs in csv mode, which refuses the modern `--gpus` flow that
# `deploy.resources.reservations.devices` translates to.
_resolve_runtime() {
  local _mode="${1:-off}"
  local -n _rr_out="${2:?}"
  case "${_mode}" in
    nvidia) _rr_out="nvidia" ;;
    auto)
      if _detect_jetson; then _rr_out="nvidia"; else _rr_out=""; fi
      ;;
    off|""|*) _rr_out="" ;;
  esac
}

# _resolve_build_network <mode> <outvar>
#   mode=host / bridge / none / default → pass through
#   mode=auto → "host" iff _detect_jetson, else ""
#   mode=off | "" → "" (no network key emitted; Docker defaults to bridge)
#
# Jetson L4T kernels commonly lack the iptables modules docker's bridge
# NAT needs, so first-time `docker build` on Jetson dies with DNS
# resolution failures before the apt step. Auto-promoting to host-net
# on Jetson removes the trap door; desktop hosts keep default bridge.
_resolve_build_network() {
  local _mode="${1:-}"
  local -n _rbn_out="${2:?}"
  case "${_mode}" in
    host|bridge|none|default) _rbn_out="${_mode}" ;;
    auto)
      if _detect_jetson; then _rbn_out="host"; else _rbn_out=""; fi
      ;;
    off|""|*) _rbn_out="" ;;
  esac
}

# ════════════════════════════════════════════════════════════════════
# _compute_conf_hash <base_path> <outvar>
#
# sha256 of the effective config: every layer of the conf chain
# (_setup_conf_layers -- template default, per-repo override, per-worktree
# .setup.conf.local), in precedence order. Used to detect conf drift in
# build.sh / run.sh. Drift means "an input to the resolved config changed",
# which is why EVERY layer that can change the resolved value is hashed: a
# layer that steers resolution but sits outside the hash would let the
# wrappers reuse artifacts generated from a different config.
# ════════════════════════════════════════════════════════════════════
_compute_conf_hash() {
  local _base="${1:?}"
  local -n _cch_out="${2:?}"
  local -a _cch_layers=()
  _setup_conf_layers "${_base}" _cch_layers

  # Use command substitution (not pipe-into-block) so the nameref
  # assignment happens in the function's scope, not a subshell.
  # The trailing `true` keeps the block's exit status 0 even when every
  # conditional cat is skipped (under `set -euo pipefail` a non-zero block
  # exit would propagate via command substitution and abort setup.sh).
  _cch_out="$(
    {
      local _cch_f
      for _cch_f in "${_cch_layers[@]}"; do
        [[ -f "${_cch_f}" ]] && cat "${_cch_f}"
      done
      true
    } | sha256sum | cut -d' ' -f1
  )"
}
