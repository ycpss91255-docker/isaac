# TEST.md

**64 tests** total.

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

## test/smoke/bats/post_run_hook_spec.bats (12)

Post-run hook (`script/hooks/post/run.sh`, base #440): on `run.sh -t stream -d`, copies host.yaml into the Isaac container and starts the web-viewer. Exercised via `POST_RUN_DRYRUN=1`.

| Test | Description |
|------|-------------|
| `post-run: non-stream target is a no-op` | A non-`stream` target produces no actions. |
| `post-run: stream without -d is a no-op` | The stream stage without `-d/--detach` produces no actions. |
| `post-run: stream + -d starts the viewer with stream-only UI mode` | Viewer `docker run` carries `VIEWER_UI_MODE=stream-only`; negative guards that `usd-viewer` and the dropped `VIEWER_AUTO_LAUNCH` flag never appear (#123). |
| `post-run: viewer ports come from the instance env via --env-file (#123)` | A named instance hands its overlay env to the viewer via `docker --env-file config/instances/<name>.env` (no literal `-e` port fallback). |
| `post-run: viewer container is named per instance and removed first` | `docker rm -f owv-<name>` precedes `docker run --name owv-<name>` (idempotent). |
| `post-run: default instance falls back to owv-default + literal -e ports` | With no `--instance` (no env-file), the viewer is `owv-default` with literal `-e SIGNALING_PORT=49100` + `-e SERVE_PORT=5173`. |
| `post-run: host.yaml present is copied into the Isaac container` | A present host.yaml is `docker cp`'d to the per-instance Isaac container at `/etc/host.yaml`. |
| `post-run: invalid host.yaml aborts with rc 1` | Garbage in host.yaml fails the hook (validated on the host first). |
| `post-run: identity is read from .env.generated, not .env (base A2 model)` | With `.env` absent, identity comes from `.env.generated`: container name is `alice-isaac-stream-foo` (no leading dash) and the viewer image is `alice/...` (not `local/...`). |
| `post-run: .env overlays .env.generated identity (user override wins)` | `.env` (sourced second) overrides `.env.generated`: a `USER_NAME=bob` overlay yields `bob-isaac-stream-foo`. |
| `post-run: every committed instance env cache dir is ./-prefixed or absolute` | Grep guard that every committed `config/instances/*.env` `INSTANCE_CACHE_DIR` is `./`-prefixed or absolute (never a bare relative compose source). |
| `post-run: viewer image is omniverse_web_viewer:runtime, not stale owv:runtime (#121)` | Viewer `docker run` uses `${DOCKER_HUB_USER:-local}/omniverse_web_viewer:runtime` (owv renamed serve->runtime, #123); regression guard that the old short stale `owv:runtime` is not launched. |

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

Host-runnable unit tests for the `isaac_devkit` framework pure surface (no Isaac Sim, no GPU). They are the M1 stage gate (ADR-0017 section 7): the `python-tests` CI job runs `test/assert_pytest_baseline.sh`, which executes this suite in a plain Python container and enforces all-green + collected >= `HOSTED_UNIT_BASELINE` (committed in `test/pytest-baseline.txt`, ratchet) + framework pure-surface coverage >= 80% (`framework/pyproject.toml` `[tool.coverage]` excludes Isaac-side function-local code via `exclude_also` regexes; live coverage 99%). They are not counted in the bats total in the header (the drift check counts `^@test` lines only). Live collected = **233** (#130 framework extraction 171 + #131 example sim 14 + #134 scaffold structure-check 23 + #135 onboarding gate 13 + #151 driver AppLauncher 8 + #150/#153 ADR-0018 +4; baseline floor ratchets to 233, DoD floor was 115). The #150/#153 (ADR-0018) net +4 is: `test_import_model.py` rewritten to the single-USD CLI contract (20 -> 14, the Asset-Structure-3.0 template/validate helpers are gone), `test_material_setup.py` +10 for the new pure `material_cfg_from_yaml` (color-only -> per-prim spawn cfg-param mapping). The #151 addition was 8 tests for `parse_livestream_applauncher` (the `ISAAC_LIVESTREAM` -> Isaac Lab `AppLauncher`-args mapping); the lifecycle-order spy in `test_isaac_driver.py` is rewritten in place (mocks `isaaclab.app.AppLauncher`, asserts the `app_launcher -> open_stage -> ensure_scene_defaults -> play_timeline -> setup -> main -> shutdown -> close` order), not added.

| File | Collected | Scope |
|------|:---------:|-------|
| `test_import_safety.py` | 8 | Hosted import of each `isaac_devkit.*` module (incl. `__init__`) leaves `sys.modules` free of `omni` / `pxr` / `isaacsim` (ADR-0017 section 8 / PRD A1). |
| `test_no_module_top_isaac_import.py` | 8 | AST static guard: no module-top `import omni\|pxr\|isaacsim` in any package source (catches try/except-disguised module-top imports; mirrors the ruff TID253 config). |
| `test_camera_setup.py` | 27 | Camera surface of `isaac_devkit.sensors` (former `camera_setup.py`): `validate_camera`, unified `load_config`, role -> Camera Helper type, FOV -> aperture math. |
| `test_sensor_setup.py` | 22 | `isaac_devkit.sensors` (former `sensor_setup.py`): YAML load, shared validation, category dispatch, per-category validation (lidar profile, IMU rigid-body rule). |
| `test_material_setup.py` | 29 | `isaac_devkit.materials`: material YAML load / validate, variant enumeration, prim-material mapping, plus `material_cfg_from_yaml` (ADR-0018 decision 7) -- color-only variant -> per-prim spawn cfg-param mapping (`{prim: {shader, diffuse_color (r,g,b), ...}}`), JSON-serializable / GPU-free, the seam #152 attaches to `sim_utils` visual material. |
| `test_scene_builder.py` | 17 | `isaac_devkit.scene`: YAML load / validate, model-path resolution, multi-instance generation, sensor-config reference resolution. |
| `test_import_model.py` | 14 | `isaac_devkit.model_import` (former `import_model.py`): single-USD CLI plumbing (ADR-0018 decision 6) -- path resolution to one `<name>.usd`, the single-USD existing-file check, output-dir creation, `package://` URDF preprocessing, and the `import_urdf` URDF-missing precondition. |
| `test_isaac_driver.py` | 16 | `isaac_devkit.driver`: `parse_livestream_env`, `resolve_repo_relative_usd`, construction without Kit, plus the greenfield `SCENE` shape + hosted lifecycle-order spy (ADR-0017 section 7). |
| `test_prim_summary.py` | 11 | Greenfield `PrimSummary` surface: `parse_urdf_expected` (pure URDF-XML expectation, fixed-joint merge), `_summarize_prim_records` (pure stage-record fold), the L1 diff-zero agreement on matching inputs. |
| `test_ros_io.py` | 23 | Greenfield `isaac_devkit.ros_io` pure surface: `parse_ros2_io_config`, `expected_attr_paths`, `_build_graph_topology`, `RosIo.latest` non-blocking fresh-once bookkeeping against an injected reader. |
| `test_example_driver.py` | 14 | `example/sim/example_driver.py` pure surface (#131): three-file scene merge (`load_three_file_scene`), expected robot/`base_link` prim-path strings, `cmd_vel_to_planar_velocity` controller mapping, `SCENE` attr shape, the `run()` SCENE-driven lifecycle-order spy + injected-SIGINT shutdown, and example import-safety. |
| `test_new_workspace_scaffold.py` | 23 | `script/new-workspace.sh` structure-check (#134): runs the scaffold into a tmp dir (`--no-submodule`, offline) and asserts the A5 consumer layout -- 16 emitted-file existence checks (`.env`, 4-lang README, `src/isaac/sim/{model,config,scene,example_driver}`, `src/isaac/ros2/src/<pkg>`), the `src/docker` mount point, the two-file env model (`.env` overlay emitted / `.env.generated` not), the workload-var overlay (`ROS_DOMAIN_ID`), and that the pre-filled driver imports cleanly on the host with no Isaac modules pulled + resolves its own three-file scene + carries the rewritten consumer submodule framework path. |
| `test_onboarding_gate.py` | 13 | M5 onboarding agent-proxy gate precondition (#135): the 4-lang `example/README.{md,zh-TW,zh-CN,ja}` exists, the English README documents the three onboarding tasks (first-topic / URDF swap / in-scope sensor swap), carries the lidar/imu `NotImplementedError` out-of-scope callout, and the URDF + sensor swap surfaces (`example/sim/model/camera_bot.urdf`, `example/sim/config/sensor/custom.yaml`) are present; plus the `test/onboarding/agent_proxy_gate.sh` harness passes its structure precondition (`STRUCTURE PASS`) and its `--audit` mode fails on a tool-call log that reads `framework/isaac_devkit/*` and passes on a clean log. Hosted, no Isaac/GPU/network. |

## test/integration/pytest/ — GPU integration (pytest, not in the bats count above)

Python integration tests boot Isaac Sim and need the GPU-enabled `test` compose service (`[stage:devel-test] deploy.gpu_mode = force` in setup.conf). Run on the GPU host: `./script/run.sh -t test -- /isaac-sim/python.sh -m pytest test/integration/pytest/<file>`. They are not counted in the bats total in the header (the drift check counts `^@test` lines only). Live collected = **25** = 23 in-container (9 active example-GPU strong-assertion tests + 3 scaffold-smoke tests from #134 + 1 Isaac Lab availability smoke from #149 + the prior 10) + 2 host cross-container tests from #132. The MR (#150/#153, ADR-0018) drops 2 in-container tests: the color USD variant-set GPU coverage (`test_material_setup_integration.py`, 2 tests, plus `_apply_materials_runner.py`) is REMOVED because color is now a spawn-time material cfg param (decision 7), reinstated as spawn-time material GPU coverage at the spawn-adapter milestone (#152/#154); `test_model_import.py` is rewritten from the Asset-Structure-3.0 assertions to the single-USD contract (decision 6), staying 3 tests. This is an intentional -2 baseline exception to the ratchet (recorded in `pytest-baseline.txt` and the PR body). The M2 cross-runner gate is `./test/assert_pytest_baseline.sh --gpu`, wired into the `python-tests` CI job on the self-hosted GPU runner: it runs the in-container suite for real, then runs the host cross-container leg (`test_cross_container_roundtrip.py`, which spawns sibling `ros:humble` containers so it cannot run inside the Isaac container) and SUMS its collected/passed into the GPU-integration totals. It asserts the GPU suite actually RAN (passed > 0 -- a skipped/collected-only GPU job is NOT green), collected >= `GPU_INTEGRATION_BASELINE` (ratchet), and the cross-runner aggregate (`HOSTED_UNIT` 233 + `GPU_INTEGRATION` 25 = 258) >= the PRD `AGGREGATE_TARGET` 126. The #130 extraction repointed every integration runner / test at `isaac_devkit.*` (the camera-headless #127 runner self-resolves `framework/` from the repo root so `import isaac_devkit` works under nested-worktree mounts too, #134).

| Test | Description |
|------|-------------|
| `test_camera_ros2_headless.py::test_camera_custom_yaml_publishes_frame_headless` | M0 gate (#127): headless Isaac boots (CUDA probe + Kit-log Vulkan/CUDA markers), `custom.yaml` camera publish chain builds via `camera_setup.setup_camera`, and >= 1 `sensor_msgs/Image` arrives on `/forklift/camera/color/image_raw` with `frame_id=forklift_camera_color_optical_frame`. Pass criterion = `[BOOT OK]` / `[CAMERA FRAME OK]` / `[EXIT CLEAN]` marker lines (Kit `_exit(0)`s, return code is meaningless). |
| `test_scaffold_smoke.py` (3) | M2 scaffold smoke (#134): scaffold a throwaway consumer workspace via `new-workspace.sh --local-docker <repo>`, then boot the SCAFFOLDED `example_driver.py` headless and assert the DoD scaffold smoke end-to-end. `test_scaffolded_driver_boots_clean` (`[BOOT OK]` + `[EXIT CLEAN]`, nothing raised); `test_scaffolded_camera_graph_built` (`[CAMERA GRAPH OK]`, the camera OmniGraph chain); `test_scaffolded_camera_topic_appears` (a sibling rclpy probe receives >= 1 frame on `/camera_bot/camera/color/image_raw` with `frame_id=camera_bot_camera_color_optical_frame` -- the camera topic appears after scaffold -> boot). Boots the SCAFFOLDED driver (consumer-layout path rewrite) on a live Kit stage, the half the hosted structure-check cannot. Marker-line acceptance; headless; runner `_scaffold_smoke_runner.py` (underscore-prefixed, not collected). |
| `test_example_gpu_integration.py` (9) | M2 gate (#132): boots the #131 `ExampleDriver` headless and makes the strong L1-L4 + `cmd_vel` assertions on the live scene. `test_l4_boot_and_clean_exit_markers` (`[BOOT OK]` + `[EXIT CLEAN]`, nothing raised); `test_cuda_and_vulkan_init` (libcuda device count + Kit-log CUDA/Vulkan markers); `test_l1_base_link_valid_and_rigidbody` (`/World/Robot/base_link` IsValid + `RigidBodyAPI`); `test_l1_link_and_joint_counts` (live committed-USD = 2 links / 2 joints / root `/camera_bot`, the importer's true convention); `test_l1_urdf_to_usd_diff_zero` (fresh `import_urdf` re-import vs committed USD, `PrimSummary` diff == 0, via `_prim_summary_runner.py`) -- SKIPPED pending #154: the committed `camera_bot.usd` is from the legacy importer, so its diff against a fresh Isaac Lab instanceable import is non-zero by construction until #154 regenerates the example asset (still collected, so the GPU ratchet count is unchanged); `test_l3_camera_topic_frame_and_message` (topic + `frame_id` + >= 1 `sensor_msgs/Image`); `test_ros_io_latest_none_before_publish` (non-blocking None); `test_cmd_vel_round_trip` (in-process Twist `vx=0.42 wz=0.21` echoes through `io.latest()`); `test_l4_injected_sigint_runs_shutdown` (live SIGINT -> `shutdown()`). Marker-line acceptance (Kit `_exit(0)`); headless; timeout = boot budget x 1.5 (600 s); retry <= 1, logged. Runners `_example_headless_runner.py` + `_prim_summary_runner.py` (underscore-prefixed, not collected). The previously-skipped `test_cross_container_ament_roundtrip_deferred_to_133` placeholder is REMOVED -- the genuine round-trip now lives in `test_cross_container_roundtrip.py` (below). |
| `test_cross_container_roundtrip.py` (2) | M2 gate (#132, PRD Pre-Publish item 1): the genuine Isaac<->ament cross-container ROS 2 round-trip, host-orchestrated against a sibling `ros:humble` container running the `example/ros2/` ament nodes (the proven #127/#131 `docker run --rm ros:humble` + `ROS_DOMAIN_ID` / `fastdds.xml` pattern on the host network). `test_sim_to_ament_camera_received` (sim -> ament: the ament `example_app_py camera_subscriber` node receives a real sim frame, `[FRAME OK] ... frame_id=camera_bot_camera_color_optical_frame`); `test_ament_to_sim_cmd_vel_received` (ament -> sim: the ament `cmd_vel_publisher` node's Twist `vx=0.37 wz=0.19` crosses the boundary and the Isaac `RosIo.latest('/cmd_vel')` picks it up, `[XC CMD_VEL RX]`). Isaac side = `_cross_container_runner.py` (underscore-prefixed, not collected); it publishes NOTHING on `/cmd_vel` so every command observed crossed the container boundary. Because it spawns sibling containers it runs on the GPU HOST (not inside the Isaac container) -- `assert_pytest_baseline.sh --gpu` runs it as a host leg and sums it into the GPU totals. Skipped (not failed) without docker / the built `isaac:test` image; a skip does not advance the `passed > 0` gate. Marker-line acceptance; headless; retry <= 1, logged. Proven on the RTX 5090. |
| `test_isaaclab_available.py` (1) | MR gate (#149, ADR-0018): the baked Isaac Lab base tool is importable inside the GPU container. `test_isaaclab_importable_in_container` launches `AppLauncher` headless, imports `isaaclab.sim`, and asserts the spawner surface (`UsdFileCfg` / `GroundPlaneCfg`), the `isaaclab.sim.converters.UrdfConverterCfg` surface, and a resolved `isaaclab.__version__` (the `isaaclab` PACKAGE version, e.g. `0.54.x`, which is independent of the Isaac Lab repo tag `v2.3.0` enforced at build time via the Dockerfile clone + `pip show`). Pass criterion = `[ISAACLAB OK] version=... spawn=True urdf_converter=True` + `[EXIT CLEAN]` marker lines, the marker printed before `simulation_app.close()` (Kit `_exit(0)` swallows anything after close). Runner `_isaaclab_available_runner.py` (underscore-prefixed, not collected). Headless, no cameras. The runtime spawn / driver imports are exercised in full by MR-2..MR-6. |

## example/ros2/ — app-side ament package tests (colcon test, not in the counts above)

The app-side ROS 2 templates (#133, `example/ros2/src/`) carry their own tests, run by `colcon test` inside a hosted `ros:humble` container (`docker run --rm`, no Isaac / no GPU per the PRD compatibility matrix ament row). They are NOT counted in the bats header total (the drift check counts `^@test` lines only) and are NOT part of the framework hosted-unit pytest baseline (`test/assert_pytest_baseline.sh` collects only `test/unit/pytest/`). Run: `docker run --rm -v "$PWD/example/ros2":/ws -w /ws ros:humble bash -c 'source /opt/ros/humble/setup.bash && colcon build && colcon test && colcon test-result --all'`.

| Test | Package | Description |
|------|---------|-------------|
| `test_copyright.py` | `example_app_py` | `ament_copyright`: every source file carries an accepted licence header. |
| `test_flake8.py` | `example_app_py` | `ament_flake8`: source is flake8-clean. |
| `test_pep257.py` | `example_app_py` | `ament_pep257`: docstrings follow the ament PEP 257 convention. |
| `test_helpers.py` | `example_app_py` | Pure-helper unit tests (no ROS context): default topics match the example, `describe_image` summary fields, `make_twist` sets only the planar components. |
| `ament_lint_common` suite | `example_app_cpp` | `copyright` / `cpplint` / `uncrustify` / `lint_cmake` / `xmllint` / `cppcheck` (cppcheck skips when the optional tool is absent) over the C++ nodes + `CMakeLists.txt` + `package.xml`. |

## script/new-workspace.sh — consumer-workspace scaffold (#134)

`script/new-workspace.sh <name>` scaffolds the A5 consumer workspace and pre-fills the base `example/` (camera_bot: model + three-file scene + `ExampleDriver` + ament_python pkg) into `src/isaac/`, so right after scaffolding `just run` boots the example and the camera topic appears (M1/M5 literal). The `example/` is the single source; the script copies from it and rewrites the copied driver's path prologue for the consumer layout (framework at `<ws>/src/docker/framework`, sim assets relative to the driver's own dir, `SCENE` -> `src/isaac/sim/scene/scene.yaml`). The scaffold emits the hand-written `.env` workload overlay; `.env.generated` is the consumer's first `just setup` output, not emitted. `src/docker` is a git submodule pinned to a base tag (`--no-submodule` for offline/hosted-test, `--local-docker <path>` for the local GPU smoke).

Coverage of the scaffold:

- **Hosted structure-check**: `test/unit/pytest/test_new_workspace_scaffold.py` (23, in the hosted-unit baseline) — runs the script for real (`--no-submodule`) and asserts the emitted layout + the driver imports cleanly. Hosted, no Isaac/GPU/network.
- **GPU smoke**: `test/integration/pytest/test_scaffold_smoke.py` (3, in the GPU-integration baseline) — scaffold (`--local-docker`) -> boot the scaffolded driver -> the camera topic appears. The DoD smoke end-to-end, proven on the RTX 5090.

## script/demo-bump-propagation.sh — M8 bump-propagation demo (#134)

`script/demo-bump-propagation.sh` is the documented M8 demo (a runnable script + asserted evidence, not prose). Fully offline / host-only, it proves both halves of the mount-not-baked framework model (ADR-0017 section 2) with no image rebuild: **Leg 1** — a live edit to the MOUNTED framework changes what the scaffolded consumer driver imports on the next run; **Leg 2** — bumping the `src/docker` submodule pin (`git -C src/docker checkout <newer>`) swaps the whole mounted framework and delivers the fix. It also asserts structurally that the framework never enters an image layer (no `COPY ... framework` in the `Dockerfile`; PYTHONPATH + bind mount only), so no rebuild can be involved by construction. Run: `./script/demo-bump-propagation.sh` (exits 0 on PASS).

## test/onboarding/agent_proxy_gate.sh — M5 onboarding gate harness (#135)

`test/onboarding/agent_proxy_gate.sh` is the repeatable harness for the M5 onboarding agent-proxy gate (the MVP completion point). Default mode runs the **structure precondition** (mechanical, repeatable, hosted): the 4-lang `example/README.*` exists, documents the three onboarding tasks (first-topic / URDF swap / in-scope sensor swap), carries the lidar/imu `NotImplementedError` out-of-scope callout, and the URDF + sensor swap surfaces are present (`STRUCTURE PASS` on success). `--audit <log>` mode is the **enforcement** half: it scans a proxy tool-call log for any `framework/isaac_devkit/` read and fails the gate if one is found (`AUDIT PASS` on a clean log). The full runbook + the four-step procedure (structure precondition -> spawn the proxy -> audit -> the pre-1.0.0 human dry-run that stays OPEN as the real backstop) is `doc/onboarding/agent-proxy-gate.md`. Enforcement is honest: making `framework/` unreadable mid-run is not mechanically enforceable here, so the prohibition is enforced post-hoc by auditing the proxy's log; the human dry-run blocks the v1.0.0 tag.

Coverage of the gate:

- **Hosted structure-check**: `test/unit/pytest/test_onboarding_gate.py` (13, in the hosted-unit baseline) — mirrors the structure precondition + asserts `--audit` fails on a framework-source leak and passes on a clean log. Hosted, no Isaac/GPU/network.
- **Proxy run + human dry-run**: not hosted tests (they need an agent harness / a human). The first proxy run (2026-06-11) is recorded in the runbook's run log; the pre-1.0.0 human dry-run is tracked there as an OPEN checklist item.
