#!/usr/bin/env bash
#
# new-workspace.sh - scaffold a consumer workspace from the base example.
#
# One command sets up a consumer workspace and pre-fills the base repo's
# `example/` (the camera_bot running example) into `src/isaac/`, so that
# right after scaffolding `just run` produces the camera topic and a
# newcomer has a runnable working reference (PRD A5, ADR-0017 section 1).
#
# Emitted layout (A5 consumer shape):
#
#   <name>/
#     .env                      hand-written workload overlay (this script
#                               emits it; .env.generated is the consumer's
#                               first `just setup` / `just build` output)
#     src/docker                git submodule pinned to a base tag (this
#                               repo) -- the framework rides this mount
#     src/isaac/
#       README.{md,zh-TW,zh-CN,ja}.md   4-lang, pre-filled from example
#       sim/model/<robot>.urdf + usd/   copied from example/sim/
#       sim/config/sensor/custom.yaml
#       sim/scene/{scene,robot,object}.yaml
#       sim/example_driver.py           path prologue rewritten for the
#                                       consumer submodule framework path
#       ros2/src/<pkg>                  ament_python skeleton from example/ros2/
#
# The example/ is the single source: this script copies from it (which is
# why issue #134 is blocked-by #131/#133). Editing the mounted framework
# takes effect immediately; bumping the src/docker submodule pin delivers
# framework fixes to the consumer with no image rebuild (M8, ADR-0017
# section 2).
#
# Usage:
#   script/new-workspace.sh <name> [options]
#
# Options:
#   --pin <ref>        Submodule ref (tag/branch/commit) to pin src/docker
#                      to. Default: the base repo's current HEAD tag, else
#                      "main".
#   --remote <url>     Submodule source URL.
#                      Default: https://github.com/ycpss91255-docker/isaac.git
#   --no-submodule     Do not run `git submodule add`; create src/docker as
#                      an empty mount point. For offline / hosted-test runs.
#   --local-docker <p> Use <p> (a local checkout of this base repo) as
#                      src/docker via a relative symlink, instead of a
#                      submodule. For the local GPU smoke where `just run`
#                      must resolve the framework without network.
#   -h, --help         Show this help.
#
# The script is layout-agnostic about where it is invoked: it resolves the
# base repo root from its own location and writes the new workspace under
# the current working directory (or an absolute <name>).
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate the base repo root (this script lives at <repo>/script/).
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null \
  || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${SCRIPT_SELF}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

EXAMPLE_DIR="${REPO_ROOT}/example"
DEFAULT_REMOTE="https://github.com/ycpss91255-docker/isaac.git"

_die() {
  printf '[new-workspace] ERROR: %s\n' "$*" >&2
  exit 1
}

_info() {
  printf '[new-workspace] %s\n' "$*"
}

_usage() {
  sed -n '2,60p' "${SCRIPT_SELF}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Parse args.
# ---------------------------------------------------------------------------
NAME=""
PIN=""
REMOTE="${DEFAULT_REMOTE}"
NO_SUBMODULE=0
LOCAL_DOCKER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      _usage
      exit 0
      ;;
    --pin)
      [[ $# -ge 2 ]] || _die "--pin needs a value"
      PIN="$2"
      shift 2
      ;;
    --remote)
      [[ $# -ge 2 ]] || _die "--remote needs a value"
      REMOTE="$2"
      shift 2
      ;;
    --no-submodule)
      NO_SUBMODULE=1
      shift
      ;;
    --local-docker)
      [[ $# -ge 2 ]] || _die "--local-docker needs a value"
      LOCAL_DOCKER="$2"
      shift 2
      ;;
    -*)
      _die "unknown option: $1"
      ;;
    *)
      [[ -z "${NAME}" ]] || _die "unexpected extra argument: $1"
      NAME="$1"
      shift
      ;;
  esac
done

[[ -n "${NAME}" ]] || { _usage; _die "missing <name>"; }
[[ -d "${EXAMPLE_DIR}/sim" ]] || _die "base example/sim not found at ${EXAMPLE_DIR}"

# ---------------------------------------------------------------------------
# Resolve the workspace destination.
# ---------------------------------------------------------------------------
if [[ "${NAME}" = /* ]]; then
  WS="${NAME}"
else
  WS="$(pwd)/${NAME}"
fi
WS_BASENAME="$(basename -- "${WS}")"

[[ ! -e "${WS}" ]] || _die "destination already exists: ${WS}"

_info "scaffolding consumer workspace: ${WS}"
mkdir -p "${WS}/src/isaac"

# ---------------------------------------------------------------------------
# 1. Pre-fill src/isaac/sim from example/sim (the single source).
# ---------------------------------------------------------------------------
_info "pre-filling src/isaac/sim from example/sim"
mkdir -p "${WS}/src/isaac/sim"
# Copy the whole sim tree (model + usd + config + scene), then the driver
# is rewritten in place for the consumer layout.
cp -R "${EXAMPLE_DIR}/sim/." "${WS}/src/isaac/sim/"

# ---------------------------------------------------------------------------
# 2. Rewrite the driver path prologue for the consumer layout.
#
# In the base repo the driver lives at example/sim/example_driver.py and
# resolves:
#   _REPO_ROOT  = parents[2]                      (repo root)
#   _FRAMEWORK  = _REPO_ROOT / "framework"
#   asset base  = _REPO_ROOT / "example" / "sim"
#   SCENE       = "example/sim/scene/scene.yaml"
#
# In the consumer the driver lives at src/isaac/sim/example_driver.py and
# must resolve:
#   _WS_ROOT    = parents[3]                      (workspace root)
#   _FRAMEWORK  = _WS_ROOT / "src/docker/framework"   (the submodule mount)
#   asset base  = the driver's own dir            (src/isaac/sim)
#   SCENE       = "src/isaac/sim/scene/scene.yaml"
# ---------------------------------------------------------------------------
DRIVER="${WS}/src/isaac/sim/example_driver.py"
[[ -f "${DRIVER}" ]] || _die "example_driver.py missing after copy"

_info "rewriting driver path prologue for the consumer layout"
# Use python for the in-place rewrite: anchored, exact-string replacement
# (no fragile sed escaping of the literal Path expressions).
SIM_ASSET_OLD='_REPO_ROOT / "example" / "sim"' \
DRIVER_PATH="${DRIVER}" \
python3 - <<'PY'
import os
import sys

path = os.environ["DRIVER_PATH"]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

replacements = [
    # parents[2] (repo root from example/sim/) -> parents[3] (ws root from
    # src/isaac/sim/).
    (
        "_REPO_ROOT = Path(__file__).resolve().parents[2]",
        "# Consumer layout (scaffolded by new-workspace.sh): this driver\n"
        "# lives at <ws>/src/isaac/sim/example_driver.py.\n"
        "_WS_ROOT = Path(__file__).resolve().parents[3]\n"
        "_REPO_ROOT = _WS_ROOT\n"
        "_SIM_DIR = Path(__file__).resolve().parent",
    ),
    # framework path -> the src/docker submodule mount.
    (
        '_FRAMEWORK = _REPO_ROOT / "framework"',
        '_FRAMEWORK = _WS_ROOT / "src" / "docker" / "framework"',
    ),
    # SCENE class attr -> consumer-relative path.
    (
        'SCENE = "example/sim/scene/scene.yaml"',
        'SCENE = "src/isaac/sim/scene/scene.yaml"',
    ),
    # asset base for the USD reference -> the driver's own sim dir.
    (
        'usd_abs = _REPO_ROOT / "example" / "sim" / usd_rel',
        "usd_abs = _SIM_DIR / usd_rel",
    ),
    # asset base for the sensor config -> the driver's own sim dir.
    (
        'cfg_abs = _REPO_ROOT / "example" / "sim" / cfg_rel',
        "cfg_abs = _SIM_DIR / cfg_rel",
    ),
    # The run-from doc line in the module docstring.
    (
        "/isaac-sim/python.sh example/sim/example_driver.py",
        "/isaac-sim/python.sh src/isaac/sim/example_driver.py",
    ),
    # scene_path resolution uses _REPO_ROOT / self.SCENE -- SCENE is now
    # ws-relative, and _REPO_ROOT == _WS_ROOT, so this still resolves.
]

for old, new in replacements:
    if old not in src:
        sys.stderr.write(
            f"[new-workspace] ERROR: anchor not found in driver: {old!r}\n"
        )
        sys.exit(1)
    src = src.replace(old, new)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)
PY

# ---------------------------------------------------------------------------
# 3. Pre-fill src/isaac/ros2 from example/ros2 (ament_python skeleton).
# ---------------------------------------------------------------------------
_info "pre-filling src/isaac/ros2 from example/ros2"
mkdir -p "${WS}/src/isaac/ros2/src"
# A5 says the consumer gets an ament_python skeleton; copy the python
# template (the cpp template stays in the base example for reference).
cp -R "${EXAMPLE_DIR}/ros2/src/example_app_py" "${WS}/src/isaac/ros2/src/"

# ---------------------------------------------------------------------------
# 4. Pre-fill the 4-lang README from example/ros2 (the example's i18n docs).
# ---------------------------------------------------------------------------
_info "pre-filling 4-lang README into src/isaac"
for lang in md zh-TW.md zh-CN.md ja.md; do
  src_readme="${EXAMPLE_DIR}/ros2/README.${lang}"
  if [[ -f "${src_readme}" ]]; then
    cp "${src_readme}" "${WS}/src/isaac/README.${lang}"
  fi
done

# ---------------------------------------------------------------------------
# 5. Emit the hand-written .env workload overlay (NOT .env.generated).
# ---------------------------------------------------------------------------
_info "emitting .env workload overlay"
cat > "${WS}/.env" <<'ENVEOF'
# .env - hand-written workload overlay for this consumer workspace.
#
# Two-file env model (base v0.41.0, PRD A5):
#   .env            this file -- per-task workload vars, env_file-injected
#                   into the container. Hand-written; the scaffold seeds it
#                   and `just setup` never overwrites it.
#   .env.generated  the setup.sh interpolation cache (compose variable
#                   substitution). Produced by your first `just setup` /
#                   `just build`; gitignored; do NOT edit by hand.
#
# Wrappers run with `--env-file .env.generated`; this overlay is injected
# as the container env_file. Put per-task runtime vars here.

# ROS 2 domain (isolate this workspace's DDS traffic from other robots).
ROS_DOMAIN_ID=0

# Bounded tick budget for the unattended example smoke (the camera_bot
# driver self-terminates after this many ticks; raise / unset for an
# interactive session).
EXAMPLE_TICK_BUDGET=1800
ENVEOF

# ---------------------------------------------------------------------------
# 6. src/docker -- the framework submodule (or a test/local stand-in).
# ---------------------------------------------------------------------------
if [[ -n "${LOCAL_DOCKER}" ]]; then
  LOCAL_ABS="$(cd -- "${LOCAL_DOCKER}" && pwd)" \
    || _die "--local-docker path not found: ${LOCAL_DOCKER}"
  _info "wiring src/docker as a symlink to local checkout: ${LOCAL_ABS}"
  ln -s "${LOCAL_ABS}" "${WS}/src/docker"
elif [[ "${NO_SUBMODULE}" -eq 1 ]]; then
  _info "skipping submodule (--no-submodule); creating src/docker mount point"
  mkdir -p "${WS}/src/docker"
else
  # Resolve the pin: explicit --pin wins, else the base repo's current tag,
  # else main.
  if [[ -z "${PIN}" ]]; then
    PIN="$(git -C "${REPO_ROOT}" describe --tags --exact-match 2>/dev/null \
      || echo main)"
  fi
  _info "adding src/docker submodule: ${REMOTE} @ ${PIN}"
  git -C "${WS}" init -q
  git -C "${WS}" submodule add -q "${REMOTE}" src/docker
  git -C "${WS}" -C src/docker checkout -q "${PIN}" \
    || _die "could not check out pin ${PIN} in src/docker"
  git -C "${WS}" submodule update -q --init --recursive
fi

# ---------------------------------------------------------------------------
# Done.
# ---------------------------------------------------------------------------
cat <<DONEEOF
[new-workspace] OK: scaffolded ${WS_BASENAME}

Next steps (inside ${WS_BASENAME}/):
  1. just setup       # generates .env.generated + compose.yaml
  2. just build       # builds the Isaac image
  3. just run         # boots the example -> camera topic appears

The pre-filled example is a runnable reference: edit src/isaac/sim/ to
swap in your own robot URDF / scene / sensors. Bump the framework with
'git -C src/docker checkout <newer-tag>' (no image rebuild).
DONEEOF
