# TEST.md

**61 tests** total.

## test/smoke/bats/host_yaml_spec.bats (8)

Shared host.yaml `public_ip` parser (`script/host_yaml.sh`), used by both the post-run hook and `runheadless-host-config.sh` (#104).

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

## test/smoke/bats/runheadless_host_config_spec.bats (8)

Single builder of the Isaac livestream Kit invocation (`script/runheadless-host-config.sh`); ports from container env, `public_ip` from `/etc/host.yaml`. Exercised via `RUNHEADLESS_DRYRUN=1` (base #465/#440).

| Test | Description |
|------|-------------|
| `runheadless: first token is the Kit launcher` | The emitted command line starts with `/isaac-sim/runheadless.sh`. |
| `runheadless: always emits -v + quitOnSessionEnded=false` | The two unconditional Kit args are always present. |
| `runheadless: port env -> livestream port kit-args` | `ISAAC_SIGNAL_PORT` / `ISAAC_MEDIA_PORT` / `ISAAC_API_PORT` map to `--/app/livestream/port` / `fixedHostPort` / the http port. |
| `runheadless: no port env -> no port kit-args (default instance)` | With no port env, the port args are omitted (Kit defaults). |
| `runheadless: host.yaml public_ip -> publicEndpointAddress` | A valid `public_ip` is appended as `--/app/livestream/publicEndpointAddress`. |
| `runheadless: no host.yaml -> no publicEndpointAddress` | Absent host.yaml omits the public-endpoint arg (localhost-only). |
| `runheadless: invalid public_ip -> rc 1 (shared parser rejects)` | Garbage in host.yaml fails fast via the shared `resolve_public_ip`. |
| `runheadless: forwards extra args after the built kit-args` | Trailing `"$@"` (e.g. a scene USD) is appended after the constructed args. |

## test/smoke/bats/pre_run_hook_spec.bats (4)

Pre-run hook (`script/hooks/pre/run.sh`, base #440): creates the per-instance cache dir tree for `run.sh --instance NAME`.

| Test | Description |
|------|-------------|
| `pre-run: --instance creates the 8 cache subdirs (absolute path)` | The kit/ov/nvidia cache subtree is created under an absolute `INSTANCE_CACHE_DIR`. |
| `pre-run: relative INSTANCE_CACHE_DIR resolves against FILE_PATH` | A relative cache path resolves against the repo root. |
| `pre-run: no --instance is a no-op (creates nothing)` | Without `--instance` the hook does nothing (the default instance is handled elsewhere). |
| `pre-run: --instance with missing env warns but does not fail` | A named instance with no overlay env warns on stderr and exits 0. |

## test/smoke/bats/post_run_hook_spec.bats (9)

Post-run hook (`script/hooks/post/run.sh`, base #440): on `run.sh -t stream -d`, copies host.yaml into the Isaac container and starts the web-viewer. Exercised via `POST_RUN_DRYRUN=1`.

| Test | Description |
|------|-------------|
| `post-run: non-stream target is a no-op` | A non-`stream` target produces no actions. |
| `post-run: stream without -d is a no-op` | The stream stage without `-d/--detach` produces no actions. |
| `post-run: stream + -d starts the viewer with stream-only + auto-launch` | Viewer `docker run` carries `VIEWER_UI_MODE=stream-only` + `VIEWER_AUTO_LAUNCH=true` (negative guard on the opposites). |
| `post-run: viewer SIGNALING_PORT comes from the instance overlay env` | The viewer's `SIGNALING_PORT` is sourced from `config/instances/<name>.env`. |
| `post-run: viewer container is named per instance and removed first` | `docker rm -f owv-<name>` precedes `docker run --name owv-<name>` (idempotent). |
| `post-run: default instance falls back to owv-default + port 49100` | With no `--instance`, the viewer is `owv-default` on the default signaling port. |
| `post-run: host.yaml present is copied into the Isaac container` | A present host.yaml is `docker cp`'d to the per-instance Isaac container at `/etc/host.yaml`. |
| `post-run: invalid host.yaml aborts with rc 1` | Garbage in host.yaml fails the hook (validated on the host first). |
| `post-run: viewer image is omniverse_web_viewer:serve, not stale owv:runtime (#121)` | Viewer `docker run` uses `${DOCKER_HUB_USER:-local}/omniverse_web_viewer:serve`; regression guard that the renamed/stale `owv:runtime` is not launched. |

## test/smoke/bats/post_stop_hook_spec.bats (2)

Post-stop hook (`script/hooks/post/stop.sh`, base #440): stops the out-of-compose web-viewer that `stop.sh` does not see.

| Test | Description |
|------|-------------|
| `post-stop: --instance stops the per-instance viewer` | `stop.sh --instance <name>` removes `owv-<name>`. |
| `post-stop: no --instance stops the default viewer` | `stop.sh` (no instance) removes `owv-default`. |

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

## test/unit/pytest/ — hosted unit (pytest, not in the bats count above)

Host-runnable unit tests for the `isaac_devkit` framework pure surface (no Isaac Sim, no GPU). They are the M1 stage gate (ADR-0017 section 7): the `python-tests` CI job runs `test/assert_pytest_baseline.sh`, which executes this suite in a plain Python container and enforces all-green + collected >= `HOSTED_UNIT_BASELINE` (committed in `test/pytest-baseline.txt`, ratchet) + framework pure-surface coverage >= 80% (`framework/pyproject.toml` `[tool.coverage]` excludes Isaac-side function-local code via `exclude_also` regexes; live coverage 98%). They are not counted in the bats total in the header (the drift check counts `^@test` lines only). Live collected = **185** (#130 framework extraction 171 + #131 example sim 14; baseline floor ratchets to 185, DoD floor was 115).

| File | Collected | Scope |
|------|:---------:|-------|
| `test_import_safety.py` | 8 | Hosted import of each `isaac_devkit.*` module (incl. `__init__`) leaves `sys.modules` free of `omni` / `pxr` / `isaacsim` (ADR-0017 section 8 / PRD A1). |
| `test_no_module_top_isaac_import.py` | 8 | AST static guard: no module-top `import omni\|pxr\|isaacsim` in any package source (catches try/except-disguised module-top imports; mirrors the ruff TID253 config). |
| `test_camera_setup.py` | 27 | Camera surface of `isaac_devkit.sensors` (former `camera_setup.py`): `validate_camera`, unified `load_config`, role -> Camera Helper type, FOV -> aperture math. |
| `test_sensor_setup.py` | 22 | `isaac_devkit.sensors` (former `sensor_setup.py`): YAML load, shared validation, category dispatch, per-category validation (lidar profile, IMU rigid-body rule). |
| `test_material_setup.py` | 19 | `isaac_devkit.materials`: material YAML load / validate, variant enumeration, prim-material mapping. |
| `test_scene_builder.py` | 17 | `isaac_devkit.scene`: YAML load / validate, model-path resolution, multi-instance generation, sensor-config reference resolution. |
| `test_import_model.py` | 20 | `isaac_devkit.model_import` (former `import_model.py`): path resolution, existing-file checks, material/root template generation, output validation. |
| `test_isaac_driver.py` | 16 | `isaac_devkit.driver`: `parse_livestream_env`, `resolve_repo_relative_usd`, construction without Kit, plus the greenfield `SCENE` shape + hosted lifecycle-order spy (ADR-0017 section 7). |
| `test_prim_summary.py` | 11 | Greenfield `PrimSummary` surface: `parse_urdf_expected` (pure URDF-XML expectation, fixed-joint merge), `_summarize_prim_records` (pure stage-record fold), the L1 diff-zero agreement on matching inputs. |
| `test_ros_io.py` | 23 | Greenfield `isaac_devkit.ros_io` pure surface: `parse_ros2_io_config`, `expected_attr_paths`, `_build_graph_topology`, `RosIo.latest` non-blocking fresh-once bookkeeping against an injected reader. |
| `test_example_driver.py` | 14 | `example/sim/example_driver.py` pure surface (#131): three-file scene merge (`load_three_file_scene`), expected robot/`base_link` prim-path strings, `cmd_vel_to_planar_velocity` controller mapping, `SCENE` attr shape, the `run()` SCENE-driven lifecycle-order spy + injected-SIGINT shutdown, and example import-safety. |

## test/integration/pytest/ — GPU integration (pytest, not in the bats count above)

Python integration tests boot Isaac Sim and need the GPU-enabled `test` compose service (`[stage:devel-test] deploy.gpu_mode = force` in setup.conf). Run on the GPU host: `./script/run.sh -t test -- /isaac-sim/python.sh -m pytest test/integration/pytest/<file>`. They are not counted in the bats total in the header (the drift check counts `^@test` lines only); automated CI auto-run is tracked in #85 / PRD #4-int (the hosted-unit M1 gate above runs for real today). Live collected = **12**; the full cross-runner aggregate (185 unit + 12 integration) is asserted at M2 with #132. The #130 extraction repointed every integration runner / test at `isaac_devkit.*` (the camera-headless #127 runners reach the framework through the `src/script` shims).

| Test | Description |
|------|-------------|
| `test_camera_ros2_headless.py::test_camera_custom_yaml_publishes_frame_headless` | M0 gate (#127): headless Isaac boots (CUDA probe + Kit-log Vulkan/CUDA markers), `custom.yaml` camera publish chain builds via `camera_setup.setup_camera`, and >= 1 `sensor_msgs/Image` arrives on `/forklift/camera/color/image_raw` with `frame_id=forklift_camera_color_optical_frame`. Pass criterion = `[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]` marker lines (Kit `_exit(0)`s, return code is meaningless). |

## example/ros2/ — app-side ament package tests (colcon test, not in the counts above)

The app-side ROS 2 templates (#133, `example/ros2/src/`) carry their own tests, run by `colcon test` inside a hosted `ros:humble` container (`docker run --rm`, no Isaac / no GPU per the PRD compatibility matrix ament row). They are NOT counted in the bats header total (the drift check counts `^@test` lines only) and are NOT part of the framework hosted-unit pytest baseline (`test/assert_pytest_baseline.sh` collects only `test/unit/pytest/`). Run: `docker run --rm -v "$PWD/example/ros2":/ws -w /ws ros:humble bash -c 'source /opt/ros/humble/setup.bash && colcon build && colcon test && colcon test-result --all'`.

| Test | Package | Description |
|------|---------|-------------|
| `test_copyright.py` | `example_app_py` | `ament_copyright`: every source file carries an accepted licence header. |
| `test_flake8.py` | `example_app_py` | `ament_flake8`: source is flake8-clean. |
| `test_pep257.py` | `example_app_py` | `ament_pep257`: docstrings follow the ament PEP 257 convention. |
| `test_helpers.py` | `example_app_py` | Pure-helper unit tests (no ROS context): default topics match the example, `describe_image` summary fields, `make_twist` sets only the planar components. |
| `ament_lint_common` suite | `example_app_cpp` | `copyright` / `cpplint` / `uncrustify` / `lint_cmake` / `xmllint` / `cppcheck` (cppcheck skips when the optional tool is absent) over the C++ nodes + `CMakeLists.txt` + `package.xml`. |
