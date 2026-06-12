#!/usr/bin/env bash
#
# demo-bump-propagation.sh - M8 bump-propagation demo (isaac#134 DoD).
#
# Demonstrates the two halves of the mount-not-baked framework model
# (ADR-0017 section 2 / PRD A6 / M8 metric), end to end, with no image
# rebuild:
#
#   Leg 1 (mounted-framework edit takes effect immediately): editing the
#     framework that rides the workspace mount changes what the consumer's
#     scaffolded driver imports on the very next run -- no rebuild, no
#     reinstall, because there is no Dockerfile `pip install` / baked copy.
#
#   Leg 2 (submodule-pin bump delivers the fix): the consumer's src/docker
#     is a git submodule pinned to a tag/commit of this base repo. Bumping
#     the pin (`git -C src/docker checkout <newer>`) swaps the whole
#     mounted framework to the newer version -- again with no image
#     rebuild, since the framework is mounted, not in the image.
#
# The demo is fully offline and host-only (no Isaac, no GPU, no network):
# it asserts on the import surface (`isaac_devkit.__version__` + a
# demo-injected sentinel) reached through the SCAFFOLDED driver's
# consumer framework path, which is exactly the path a live `just run`
# resolves. "No rebuild" is structural: the framework never enters an
# image layer (verified by the ADR-0017 section 2 wiring -- PYTHONPATH +
# bind mount, no COPY framework), so a host-side import check is a
# faithful proxy for what the container sees.
#
# Usage: script/demo-bump-propagation.sh
set -euo pipefail

SCRIPT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_SELF}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SCAFFOLD="${SCRIPT_DIR}/new-workspace.sh"

WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

_step() { printf '\n=== %s ===\n' "$*"; }
_ok() { printf '[demo] OK: %s\n' "$*"; }
_die() { printf '[demo] FAIL: %s\n' "$*" >&2; exit 1; }

# Resolve the consumer framework version through the SCAFFOLDED driver's
# path prologue (the same _FRAMEWORK = <ws>/src/docker/framework the live
# driver uses). Prints "<version>|<sentinel-or-MISSING>".
_consumer_surface() {
  local ws="$1"
  WS="${ws}" python3 - <<'PY'
import os
import sys
from pathlib import Path

ws = Path(os.environ["WS"])
fw = ws / "src" / "docker" / "framework"
sys.path.insert(0, str(fw))
import isaac_devkit  # noqa: E402

sentinel = getattr(isaac_devkit, "DEMO_SENTINEL", "MISSING")
print(f"{isaac_devkit.__version__}|{sentinel}")
PY
}

# ---------------------------------------------------------------------------
# Build a local bare "origin" of the base repo with two commits that carry
# different framework versions, so Leg 2 can pin one and bump to the other
# fully offline. (A real consumer pins a published semver tag instead.)
# ---------------------------------------------------------------------------
_step "Setup: local two-commit base origin (offline stand-in for tags)"
SRC="${WORK}/base-src"
git clone -q "${REPO_ROOT}" "${SRC}"
git -C "${SRC}" config user.name demo
git -C "${SRC}" config user.email demo@example.com

# Commit A = the current framework version (call it the "old pin").
OLD_VERSION="$(grep -oE '__version__ = "[^"]+"' \
  "${SRC}/framework/isaac_devkit/__init__.py" | head -1 \
  | sed -E 's/.*"([^"]+)".*/\1/')"
git -C "${SRC}" tag demo-old
_ok "old pin tagged demo-old (framework __version__ = ${OLD_VERSION})"

# Commit B = a bumped framework version + a fix sentinel (the "new pin").
NEW_VERSION="${OLD_VERSION}+bump"
sed -i -E "s/__version__ = \"[^\"]+\"/__version__ = \"${NEW_VERSION}\"/" \
  "${SRC}/framework/isaac_devkit/__init__.py"
printf '\n# isaac#134 M8 demo: a framework fix delivered by a pin bump.\nDEMO_SENTINEL = "fix-from-new-pin"\n' \
  >> "${SRC}/framework/isaac_devkit/__init__.py"
git -C "${SRC}" commit -q -am "demo: bump framework version + add fix sentinel"
git -C "${SRC}" tag demo-new
_ok "new pin tagged demo-new (framework __version__ = ${NEW_VERSION} + DEMO_SENTINEL)"

# ---------------------------------------------------------------------------
# Scaffold a consumer workspace pinned to the OLD framework version.
# ---------------------------------------------------------------------------
_step "Scaffold consumer pinned to the old framework (demo-old)"
CONSUMER_PARENT="${WORK}/consumer"
mkdir -p "${CONSUMER_PARENT}"
# file: clone the local "origin" over the file:// transport (offline);
# the scaffold's nested-submodule fetch is best-effort, so a viewer that
# cannot clone offline does not abort the demo.
export GIT_ALLOW_PROTOCOL="file"
(
  cd "${CONSUMER_PARENT}"
  "${SCAFFOLD}" my-robot-ws --remote "${SRC}" --pin demo-old
) >/dev/null 2>"${WORK}/scaffold.err" \
  || { cat "${WORK}/scaffold.err" >&2; _die "scaffold failed"; }
WS="${CONSUMER_PARENT}/my-robot-ws"
[[ -d "${WS}/src/docker/framework" ]] || _die "submodule framework not present"

surface_initial="$(_consumer_surface "${WS}")"
ver_initial="${surface_initial%%|*}"
sent_initial="${surface_initial##*|}"
printf '[demo] consumer sees: __version__=%s DEMO_SENTINEL=%s\n' \
  "${ver_initial}" "${sent_initial}"
[[ "${ver_initial}" == "${OLD_VERSION}" ]] \
  || _die "expected old version ${OLD_VERSION}, got ${ver_initial}"
[[ "${sent_initial}" == "MISSING" ]] \
  || _die "old pin should not carry the fix sentinel"
_ok "consumer pinned to old framework (no fix yet)"

# ---------------------------------------------------------------------------
# LEG 1: edit the mounted framework -> effect is immediate (no rebuild).
# ---------------------------------------------------------------------------
_step "LEG 1: edit the mounted framework in place (no rebuild)"
MOUNTED_INIT="${WS}/src/docker/framework/isaac_devkit/__init__.py"
printf '\n# LEG 1: a live edit to the MOUNTED framework.\nDEMO_SENTINEL = "edited-in-mount"\n' \
  >> "${MOUNTED_INIT}"

surface_after_edit="$(_consumer_surface "${WS}")"
sent_after_edit="${surface_after_edit##*|}"
printf '[demo] after a live mount edit, consumer sees: DEMO_SENTINEL=%s\n' \
  "${sent_after_edit}"
[[ "${sent_after_edit}" == "edited-in-mount" ]] \
  || _die "mounted-framework edit did NOT take effect immediately"
_ok "LEG 1: mounted-framework edit took effect with no rebuild"

# Revert the live edit so Leg 2 starts from the clean old pin.
git -C "${WS}/src/docker" checkout -q -- framework/isaac_devkit/__init__.py

# ---------------------------------------------------------------------------
# LEG 2: bump the submodule pin -> the fix reaches the consumer (no rebuild).
# ---------------------------------------------------------------------------
_step "LEG 2: bump the src/docker submodule pin old -> new (no rebuild)"
git -C "${WS}/src/docker" fetch -q origin
git -C "${WS}/src/docker" checkout -q demo-new

surface_after_bump="$(_consumer_surface "${WS}")"
ver_after_bump="${surface_after_bump%%|*}"
sent_after_bump="${surface_after_bump##*|}"
printf '[demo] after the pin bump, consumer sees: __version__=%s DEMO_SENTINEL=%s\n' \
  "${ver_after_bump}" "${sent_after_bump}"
[[ "${ver_after_bump}" == "${NEW_VERSION}" ]] \
  || _die "pin bump did not deliver the new framework version"
[[ "${sent_after_bump}" == "fix-from-new-pin" ]] \
  || _die "pin bump did not deliver the fix sentinel"
_ok "LEG 2: submodule pin bump delivered the fix with no rebuild"

# ---------------------------------------------------------------------------
# Structural proof that no rebuild can be involved: the framework never
# enters an image layer. Grep the Dockerfile + setup.conf wiring.
# ---------------------------------------------------------------------------
_step "Structural check: framework is mounted + PYTHONPATH, never COPY'd"
if grep -qE '^\s*COPY\b.*framework' "${REPO_ROOT}/Dockerfile" 2>/dev/null; then
  _die "found a COPY of framework into the image -- it would be baked, not mounted"
fi
grep -q 'PYTHONPATH=.*src/docker/framework' \
  "${REPO_ROOT}/config/docker/setup.conf" \
  || _die "consumer framework PYTHONPATH wiring missing from setup.conf"
_ok "framework rides the mount + PYTHONPATH (no image COPY) -- a pin bump or"
_ok "a live edit reaches the container with no rebuild by construction"

printf '\n[demo] PASS: M8 bump-propagation demo (both legs, no rebuild)\n'
