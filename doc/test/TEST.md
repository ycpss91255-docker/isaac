# TEST.md

**52 tests** total.

## test/smoke/bats/makefile_local_spec.bats (6)

| Test | Description |
|------|-------------|
| `Makefile.local: no /proc/1/fd/ redirect under pid=host (#75)` | Asserts `Makefile.local` does not redirect to the literal `/proc/1/fd/*`. Under `pid=host` that path points at host systemd, fails with EPERM, leaves `docker logs` empty. |
| `Makefile.local: redirect resolves container PID 1 via State.Pid (#75)` | Asserts `Makefile.local` resolves `CONTAINER_PID1` via `docker inspect --format '{{.State.Pid}}'` so the FD redirect lands in the container's docker logs pipe. |
| `Makefile.local: run-stream launches web-viewer in stream-only auto-launch (#79/#107)` | Asserts `run-stream` passes `VIEWER_UI_MODE=stream-only` + `VIEWER_AUTO_LAUNCH=true` as `-e` flags (not a bare string) and that the opposite values are not wired. |
| `Makefile.local: host.yaml-absent message is functional, not Kit jargon (#108)` | The no-host.yaml message says remote browser access will not work (no `skip publicEndpointAddress` Kit jargon). |
| `Makefile.local: run-stream output includes a firewall hint (#108)` | run-stream output mentions firewall + ports 8011 / 49100. |
| `Makefile.local: HOST_YAML resolves relative to the makefile dir (#109)` | `HOST_YAML` is derived from `$(SELF_DIR)` (via `MAKEFILE_LIST`), not the CWD. |

## test/smoke/bats/host_yaml_spec.bats (8)

Shared host.yaml `public_ip` parser (`script/host_yaml.sh`), used by both `run_instance.sh` and `runheadless-host-config.sh` (#104).

| Test | Description |
|------|-------------|
| `host_yaml: clean quoted value` | A quoted IPv4 is returned verbatim. |
| `host_yaml: strips a trailing inline comment (#104)` | `public_ip: "1.2.3.4"  # note` yields `1.2.3.4`, not the comment. |
| `host_yaml: trims whitespace on an unquoted value` | Leading/trailing whitespace is removed. |
| `host_yaml: accepts a hostname` | A DNS hostname passes validation. |
| `host_yaml: absent file -> empty, rc 0` | A missing file resolves to empty (localhost-only), no error. |
| `host_yaml: key absent -> empty, no warning` | A file without `public_ip` resolves to empty with no warning. |
| `host_yaml: key present but empty -> empty value + warning (#104)` | Distinguishes "not configured" from "configured but unparseable" -- warns on stderr. |
| `host_yaml: invalid value (metacharacters) -> rc 1 + error (#104)` | A value with illegal characters fails fast with an error instead of passing garbage to Kit / the viewer. |

## test/smoke/bats/run_instance_spec.bats (8)

| Test | Description |
|------|-------------|
| `run_instance.sh: kit_args starts with /isaac-sim/runheadless.sh (#81 bug A)` | Asserts the first non-flag token in the `kit_args` array literal is `/isaac-sim/runheadless.sh`. Without the prefix the image entrypoint (`exec "$@"`) eats `-v` as its own flag and the Isaac container dies with `exitCode=2 / execDuration=0`. |
| `run_instance.sh: _start_web_viewer passes SIGNALING_SERVER env (#81 bug B)` | Asserts `_start_web_viewer` passes `-e SIGNALING_SERVER=${public_ip}` to the viewer container. Defense in depth so the viewer JS bundle gets the right host IP even if the locally cached `owv:runtime` image is older than `omniverse_web_viewer#12` (the entrypoint that reads `/etc/host.yaml`). |
| `run_instance.sh: VIEWER_* passed as -e flags inside _start_web_viewer (#79/#107)` | Structural check: both `VIEWER_*` appear as `-e` flags within the `_start_web_viewer` body, and the opposite values do not. |
| `run_instance.sh: _start_web_viewer removes a stale container first (#105)` | Asserts `docker rm -f "${WV_CONTAINER}"` runs before `docker run` so a re-run does not hit a name conflict. |
| `run_instance.sh: web-viewer launch is gated on the stream stage (#105)` | Asserts the launch guard tests `stage == stream`, so `headless` does not spawn a viewer with no stream to show. |
| `run_instance.sh: uses the shared validated host.yaml parser (#104)` | Asserts `resolve_public_ip` is used and the old permissive inline awk parser is gone. |
| `run_instance.sh: success message distinguishes remote vs localhost-only (#108)` | The viewer success line has a remote-ready branch and a localhost-only branch that points at `config/host.yaml`. |
| `run_instance.sh: viewer guard also requires an initialized .base (#109)` | The launch guard also checks `WV_DIR/.base` and the error suggests `--init --recursive`, so a shallow submodule does not reach a failing docker build. |

## test/smoke/bats/docker_env.bats (4)

| Test | Description |
|------|-------------|
| `entrypoint.sh is installed and executable` | Entrypoint check |
| `bash is available on PATH` | Shell sanity |
| `fastdds.xml is baked at /isaac-sim/fastdds.xml and world-readable` | Fast DDS profile (UDPv4-only) shipped by this repo's Dockerfile, content sanity-checked for `useBuiltinTransports=false` |
| `custom streaming kit experience baked at /isaac-sim/apps/ (issue #21 fix-B)` | The repo's custom streaming `.kit` experience file is baked into `/isaac-sim/apps/` so the stream stage launches it |

## test/smoke/bats/isaac_smoke.bats (7)

| Test | Description |
|------|-------------|
| `isaac-sim launchers exist and are executable` | `/isaac-sim/runheadless.sh` and `/isaac-sim/runapp.sh` both `0755` |
| `isaac-sim ships Python 3.11 in /isaac-sim/kit/python/bin/python3` | Isolated Python interpreter exists and reports `3.11` |
| `runtime user is host-aligned (not root, not isaac-sim default)` | Container user is the host-UID-aligned `USER_NAME`, not the image default `isaac-sim` (UID 1234) |
| `runtime user is in isaac-sim group (can read /isaac-sim/* mode 0750)` | Group membership unlocks read/exec on Isaac Sim binaries |
| `HOME is writable` | `${HOME}` is owned by the runtime user — required for cache / logs / Documents writes |
| `bundled ROS 2 humble + jazzy libs are both readable` | `librmw_fastrtps_cpp.so` present under both `humble/lib/` and `jazzy/lib/` — image carries both distros; the headless / stream shim picks one via `ARG ROS_DISTRO` |
| `bundled ROS 2 humble + jazzy rclpy are both readable (Python 3.11)` | `rclpy/` Python bindings present under both distros; kit-side `import rclpy` resolves to whichever the bridge extension activates |

## test/smoke/bats/isaac_ros_env_wrapper.bats (10)

| Test | Description |
|------|-------------|
| `wrapper exists and is executable` | `/usr/local/bin/isaac-ros-env-wrapper.sh` 0755 |
| `/etc/isaac/ros-distro is baked with humble (default ARG)` | Const file written from `ARG ROS_DISTRO` at build time |
| `wrapper exports ROS_DISTRO from /etc/isaac/ros-distro` | Wrapper reads file and exports |
| `wrapper exports LD_LIBRARY_PATH derived from ROS_DISTRO` | Wrapper exports `/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` |
| `wrapper hard-overrides runtime ROS_DISTRO env` | `ROS_DISTRO=jazzy ./wrapper bash -c 'echo ROS_DISTRO'` still prints `humble` — runtime `-e` ineffective on headless / stream |
| `wrapper passes args verbatim to wrapped command` | `./wrapper echo arg1 arg2 arg3` → `arg1 arg2 arg3` |
| `wrapper appends publicEndpointAddress when PUBLIC_IP is set` | With `PUBLIC_IP` exported, the wrapper adds `--/app/livestream/publicEndpointAddress=<ip>` to the Kit args |
| `wrapper does not append publicEndpointAddress when PUBLIC_IP is empty` | With no `PUBLIC_IP`, the wrapper omits the public-endpoint arg (localhost-only WebRTC) |
| `devel stage ENV ROS_DISTRO is baked (soft)` | Devel interactive shell sees `ROS_DISTRO=humble` from Dockerfile `ENV` |
| `devel stage ENV LD_LIBRARY_PATH points to baked humble lib` | Same — `ENV LD_LIBRARY_PATH=/isaac-sim/exts/isaacsim.ros2.bridge/${ROS_DISTRO}/lib` interpolated at build time |

## test/smoke/bats/init_isaac_dirs_spec.bats (6)

| Test | Description |
|------|-------------|
| `script-under-test is baked into the test stage` | `init_isaac_dirs.sh` is present in the devel-test image for the spec to exercise |
| `fresh run creates all 10 namespaced dirs` | A clean run creates the full per-instance namespaced cache directory set |
| `second run is idempotent (no error, no double-mkdir noise)` | Re-running does not error or re-create existing dirs |
| `migration: pre-2026-05-21 layout is auto-moved to new namespaces` | Legacy cache layout is migrated into the namespaced layout |
| `migration skips when destination already exists (no overwrite)` | Migration does not clobber an existing destination |
| `missing .env errors with actionable message` | Absent `.env` produces a clear, actionable error |

## test/smoke/bats/python_testing.bats (3)

| Test | Description |
|------|-------------|
| `pytest installed in devel-test stage` | `/isaac-sim/python.sh -m pytest --version` exits 0 — pytest importable via Isaac Sim's bundled Python |
| `pyyaml installed in devel-test stage` | `import yaml; print(yaml.__version__)` succeeds — YAML available for Python config / fixture loading |
| `pytest-cov installed in devel-test stage` | `pytest --help` mentions `--cov` — coverage plugin registered, enables `pytest --cov=<pkg>` invocations |
