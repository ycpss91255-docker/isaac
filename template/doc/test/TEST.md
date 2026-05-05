# TEST.md

Template self-tests: **935 tests** total (881 unit + 54 integration).

## Test Files

### test/unit/lib_spec.bats (41)

| Test | Description |
|------|-------------|
| `_lib.sh sets _LANG to 'en' when LANG is unset` | Default language |
| `_lib.sh sets _LANG to 'zh-TW' for zh_TW.UTF-8` | Traditional Chinese |
| `_lib.sh sets _LANG to 'zh-CN' for zh_CN.UTF-8` | Simplified Chinese |
| `_lib.sh sets _LANG to 'zh-CN' for zh_SG (Singapore)` | Singapore variant |
| `_lib.sh sets _LANG to 'ja' for ja_JP.UTF-8` | Japanese |
| `_lib.sh honors SETUP_LANG override` | Env override |
| `_lib.sh is idempotent when sourced twice` | Double-source guard |
| `_load_env exports variables from a .env file` | Env loader works |
| `_load_env errors when no path is given` | Required arg check |
| `_compute_project_name with empty instance produces clean PROJECT_NAME` | Default instance |
| `_compute_project_name with named instance suffixes both` | Named instance |
| `_compute_project_name exports INSTANCE_SUFFIX so child processes see it` | Export propagation |
| `_compose with DRY_RUN=true prints command instead of running` | DRY_RUN path |
| `_compose without DRY_RUN tries to invoke docker compose (sanity)` | Real-call branch |
| `_compose_project pre-fills -p / -f / --env-file from PROJECT_NAME and FILE_PATH` | Project wrapper |
| `_sanitize_lang accepts en / zh-TW / zh-CN / ja unchanged` | Lang validator pass-through |
| `_sanitize_lang warns and falls back to 'en' for unsupported values` | Unknown lang fallback |
| `_sanitize_lang warns for the old bare 'zh' code (post zh→zh-TW rename)` | Legacy lang rejection |
| `_dump_conf_section extracts keys from the named section` | INI section dump |
| `_dump_conf_section stops at the next section header` | Section boundary |
| `_dump_conf_section returns silent empty for missing file` | Missing file |
| `_dump_conf_section returns silent empty for unknown section` | Missing section |
| `_print_config_summary prints files, identity, all populated sections, resolved` | Full config dump |
| `_print_config_summary prints Variables block mapping setup.conf placeholders to detected values` | Variables block populated |
| `_print_config_summary Variables block falls back to '-' for unset values` | Variables fallback |
| `_print_config_summary hides sections that are empty in setup.conf` | Empty-section skip |
| `_print_config_summary warns when setup.conf is missing` | Missing-conf hint |
| `_print_config_summary warns when setup.conf exists but has no [section] headers` | #157 empty-conf hint on build/run summary |

### test/unit/setup_spec.bats (206)

Covers core detection (user/hardware/docker/GPU/GUI), the INI parser
(`_parse_ini_section`), setup.conf section merging (`_load_setup_conf`
with replace strategy), image_name rule engine via `[image] rules`,
resolvers (`_resolve_gpu`, `_resolve_gui`), workspace path detection,
conf hash computation, drift detection, `write_env` (now including
runtime values + SETUP_* metadata), the `main()` CLI, and workspace
writeback (first-time bootstrap / user-edit respect / opt-out).

| Category | Tests |
|----------|-------|
| `detect_user_info` / `detect_hardware` / `detect_docker_hub_user` / `detect_gpu` / `detect_gui` | 11 |
| `_parse_ini_section` (section isolation, comments, trim, missing) | 6 |
| `_load_setup_conf` (SETUP_CONF env, per-repo, template, replace) | 4 |
| `_get_conf_value` / `_get_conf_list_sorted` (incl. empty-value skip) | 5 |
| `_resolve_gpu` / `_resolve_gui` | 7 |
| `detect_image_name` (template default, per-repo rules, @default, order) | 7 |
| `detect_ws_path` (strategies 1/2/3 + missing base_path) | 5 |
| `_compute_conf_hash` | 2 |
| `write_env` (all fields + SETUP_* metadata) | 1 |
| `_check_setup_drift` (no-op, silent, conf drift, GPU drift) | 4 |
| `main` (unknown arg, --base-path / --lang missing value) | 3 |
| Subcommand dispatch (#49 Phase B-1: apply default / explicit, unknown subcmd, check-drift no-op / clean / drift / bad flag, end-to-end subprocess) | 9 |
| Subcommand `set` / `show` / `list` (#49 Phase B-2: round-trip, validators reject gpu_count / mount / cgroup / env_kv / port, no .env regen, missing key/section, unknown section, list dump, end-to-end subprocess) | 22 |
| Subcommand `add` / `remove` (#49 Phase B-3: empty-slot reuse, max+1 after gap, bootstrap on missing setup.conf, validator rejection, remove by key, remove by value, missing key, comment preservation, round-trip) | 17 |
| Subcommand `reset` + BREAKING no-arg → help (#49 Phase B-4: --yes write, .bak archives, no .env regen, non-tty refusal, unknown flag, first-time bootstrap, no-arg prints help, legacy flag-only errors) | 8 |
| `_msg` / `_detect_lang` i18n | 6 |
| `[build]` apt_mirror (empty fallback, override) | 2 |
| Workspace writeback (first-time, respect user edit, opt-out) | 3 |
| Per-repo setup.conf missing / empty WARN (#150 / #186: missing → WARN, empty → WARN, partial → silent, zh-TW lang) | 4 |
| Per-repo setup.conf WARN on check-drift path (#157 / #186: missing → WARN, empty → WARN, partial → silent, zh-TW lang) | 4 |
| `[additional_contexts]` parsing + compose emission (#199: omitted by default, devel/test block, runtime block, numeric sort, empty-slot skip, _setup_known_section) | 6 |
| Per-section setup.conf parameter end-to-end coverage (#202: [deploy] gpu_mode/count/capabilities/runtime, [gui] mode, [network] mode/ipc/network_name/port_*, [resources] shm_size, [environment] env_*, [tmpfs] tmpfs_*, [devices] device_*/cgroup_rule_*, [volumes] mount_2..N, [security] privileged) | 25 |

### test/unit/tui_spec.bats (92)

Pure-logic unit tests for the TUI support libraries (`_tui_conf.sh`).
No dialog/whiptail invocations here — strictly validators, mount-string
parsers, and setup.conf round-trip.

| Category | Tests |
|----------|-------|
| `_validate_mount` (valid forms, env-var expansion, reject missing/extra colons, invalid mode) | 8 |
| `_validate_gpu_count` ('all', positive int, reject 0/negative/non-numeric/empty) | 6 |
| `_validate_enum` (match, non-match, empty) | 3 |
| `_mount_host_path` (plain, with mode, with env-var host) | 3 |
| `_load_setup_conf_full` + `_write_setup_conf` (section order, kv, comment preservation, untouched keys, round-trip, dst==tpl regression #187) | 6 |
| `_upsert_conf_value` (updates existing, leaves other sections untouched) | 2 |
| `_edit_image_rule __remove` index compaction (#177) — first / middle / last / sole rule | 4 |
| `_validate_additional_context` (#199: relative paths, BuildKit schemes, name punctuation, reject empty / missing pieces, reject invalid name shapes) | 5 |

### test/unit/tui_backend_spec.bats (28)

Backend detection and wrapper-level arg forwarding. Uses a stub
`dialog` / `whiptail` binary installed on PATH that logs argv and echoes
a canned response; exercised with `TUI_STUB_RESPONSE` / `TUI_STUB_EXIT`.

| Category | Tests |
|----------|-------|
| `_backend_detect` (prefers dialog, falls back to whiptail, prints install hint when neither) | 3 |
| `_tui_guard` (rejects empty backend) | 1 |
| `_tui_inputbox` (forwards title/prompt/initial, returns canned response, propagates non-zero on cancel) | 2 |
| `_tui_menu` (computes item count, forwards tag/label pairs; `TUI_EXTRA_LABEL` no-op after #178; `--no-tags`, `--ok-label`) | 1 |
| `_tui_radiolist` (forwards tag/label/state triples) | 1 |
| `_tui_checklist` (passes `--separate-output`) | 1 |
| `_tui_msgbox` / `_tui_yesno` (correct flags, propagates exit code) | 2 |
| whiptail flag-spelling translation (#136: `--ok-button` / `--cancel-button` instead of `--*-label`, no `--extra-button`) + Save-button unification (#178: dialog also drops `--extra-button`) | 6 |

### test/unit/tui_flow.bats (53)

Interactive-flow tests for `setup_tui.sh` (#189). Sources `setup_tui.sh`
directly and overrides `_tui_menu` / `_tui_select` / `_tui_inputbox` /
`_tui_yesno` / `_tui_msgbox` / `_tui_radiolist` / `_tui_checklist` with
file-backed stubs (queue lines popped via `head -n 1` + `sed -i 1d` so
state survives the `$(...)` subshell calls). Each case scripts the
user's click path, calls one section editor, and asserts on the
resulting `_TUI_OVR_*` / `_TUI_REMOVED` / `_TUI_CURRENT` arrays — no
real `dialog` / `whiptail` ever launches. Lifts `setup_tui.sh`
per-file coverage from 18% to 83% by exercising the 5 high-value
target areas the issue body called out.

| Category | Tests |
|----------|-------|
| `_load_current` (repo-conf wins; falls back to template; both missing → silent return 0) | 3 |
| `_render_main_menu` / `_render_advanced_menu` (#178 Save & Exit unification, Cancel/Esc returns 1, navigation into section editor) | 5 |
| `_edit_image_rule` (#177 site: add string/prefix/suffix/basename/default, Cancel from radiolist or inputbox, `__remove`/`__move_up`/`__move_down`, dedupe drops duplicate slot) | 11 |
| `_compact_image_rules_after_remove` (mid-list shift down, last drop, empty no-op, sparse-slot collapse) | 4 |
| `_swap_image_rule` (both occupied / target empty / source empty / both empty / m<1) | 5 |
| `_edit_list_section` via `_edit_section_environment` (env_ add/edit/remove, invalid → msgbox+retry, max+1 indexing, Cancel/Esc) | 7 |
| `_edit_section_image` top-level dispatch (add max+1, click rule_N, Back) | 3 |
| `_edit_section_network` (host+host no shm prompt, bridge prompts name+ports, ipc=private prompts shm, empty network_name allowed) | 4 |
| `_edit_section_deploy` (off short-circuits — only writes gpu_mode) | 1 |
| Multi-section dispatch from main menu (network → host → save) | 1 |

### test/unit/build_worker_yaml_spec.bats (15)

Structural assertions for `.github/workflows/build-worker.yaml` (#195).
Reusable workflows are not exec'd by these tests; instead grep
patterns lock the YAML invariants — `context_path` / `dockerfile_path`
inputs declared with the right defaults, all 3 `docker/build-push-action`
steps forwarding those inputs, and no leftover `context: .` /
`file: ./Dockerfile` literals.

| Category | Tests |
|----------|-------|
| `inputs.context_path` declared with `default: "."` | 1 |
| `inputs.dockerfile_path` declared with `default: ""` | 1 |
| 3 build steps reference `inputs.context_path` | 1 |
| 3 build steps reference `inputs.dockerfile_path` with `format()` fallback | 1 |
| No leftover `context: .` literals | 1 |
| No leftover `file: ./Dockerfile` literals | 1 |
| Default values together preserve repo-root-Dockerfile callers | 1 |
| User build-args use long form matching Dockerfile.example sys stage (#198: USER_NAME / USER_GROUP / USER_UID / USER_GID across 3 build steps + no short-form regression) | 5 |
| `build_contexts` input forwards to docker/build-push-action `build-contexts:` (#207: input declared with empty default, 3 build steps forward, default preserves zero-diff) | 3 |

### test/unit/build_sh_spec.bats (35)

Unit tests for `build.sh` argument handling and control flow. Uses a
sandbox tree mirroring the expected layout (build.sh + `template/` subtree
with real `_lib.sh` / `i18n.sh`, mock `setup.sh`). `docker` is PATH-shimmed
so the stub captures argv; `build.sh` is symlinked (not copied) so kcov
attributes coverage to the real source file.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, auto-bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path when
all three are present, bootstrap staying non-interactive (setup.sh
direct, not `setup_tui.sh`), defensive guard when setup produces no
`.env`, TARGETARCH build-arg forwarding, `--no-cache`, `--clean-tools`,
positional `TARGET`, `--lang` argument validation, fallback
`_detect_lang` branches (zh_TW/zh_CN/ja), real (non-dry-run) docker
build invocation, and **runtime log-line i18n** (bootstrap /
drift-regen / err_no_env messages translate in all four languages via
the local `_msg()` table; English remains the default).

### test/unit/run_sh_spec.bats (33)

Unit tests for `run.sh`. Mirrors the build_sh_spec.bats harness;
`docker ps` reads from a controllable stub file so tests can simulate
"container already running" scenarios.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path,
bootstrap staying non-interactive (setup.sh, not TUI), defensive guard
when setup produces no `.env`, `--detach`, devel vs non-devel TARGET
routing, `--instance`, already-running guard, Wayland xhost path,
`--lang` / `--instance` argument validation, fallback `_detect_lang`
branches, and **runtime log-line i18n** (bootstrap + already-running
error translate in all four languages via the local `_msg()` table).

### test/unit/exec_sh_spec.bats (18)

Unit tests for `exec.sh` argument parsing, the container-running
precheck, and i18n. Sandbox tree mirrors build_sh_spec.bats;
`docker ps` reads from a controllable stub file so tests can toggle
"container running" state without a real docker daemon. `.env` is
pre-seeded so `_load_env` / `_compute_project_name` succeed without a
bootstrap step.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--target` / `--instance`
value validation, English-default not-running error, Chinese /
Simplified Chinese / Japanese not-running error text, instance-specific
vs default start hints, `--dry-run` bypassing the guard, compose exec
routing when container is running, and fallback `_detect_lang`
branches when `template/` is absent.

### test/unit/stop_sh_spec.bats (16)

Unit tests for `stop.sh` argument parsing, the `--all` multi-instance
teardown, and i18n. `docker ps -a` output is PATH-shimmed via
`${DOCKER_PS_A_FILE}` so tests can seed the project list for the `--all`
branch.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--instance` value
validation, default teardown via `docker compose down`, named-instance
suffix in project name, `--all` no-instances English message,
Chinese / Simplified Chinese / Japanese translations of the
no-instances message, `--all` multi-project teardown loop, and
fallback `_detect_lang` branches.

### test/unit/compose_gen_spec.bats (45)

Covers `generate_compose_yaml` conditional output: AUTO-GENERATED
header, baseline workspace volume, network/ipc/privileged env-var
references, `test` service presence, image name threading, and
conditional GPU deploy block + GUI env/volumes + extra volumes from
`[volumes]` section.

| Test | Description |
|------|-------------|
| `outputs AUTO-GENERATED header` | Header check |
| `always emits workspace volume` | Baseline |
| `emits network_mode/ipc/privileged via env var` | env-var baked |
| `emits test service with profiles: [test]` | test service |
| `image field contains repo name` | Image name |
| `does NOT emit /dev:/dev by default (not in baseline)` | Baseline scope |
| `GPU enabled => deploy block present` | GPU on |
| `GPU disabled => no deploy block` | GPU off |
| `GPU with specific count and capabilities` | GPU args |
| `GUI enabled => DISPLAY env + X11 volumes present` | GUI on |
| `GUI disabled => no DISPLAY env + no X11 volumes` | GUI off |
| `extra volumes appended after baseline` | volumes list |
| `empty extras => no extra mount lines` | empty list |
| `with GUI+GPU+extras => all sections present` | fully loaded |
| `emits runtime service when Dockerfile has AS runtime` | #108 auto-emit |
| `skips runtime service when Dockerfile lacks AS runtime` | opt-out by absence |
| `skips runtime service when Dockerfile is absent` | no-Dockerfile guard |
| `runtime service extends devel and overrides target/image/tty/profile` | compose extends shape |
| `runtime service appears between devel and test blocks` | ordering |
| `runtime detection is robust against weird whitespace` | regex tolerance |
| `runtime detection ignores non-runtime stage names` | strict match |

### test/unit/template_spec.bats (134)

| Test | Description |
|------|-------------|
| `build.sh exists and is executable` | File check |
| `run.sh exists and is executable` | File check |
| `exec.sh exists and is executable` | File check |
| `stop.sh exists and is executable` | File check |
| `setup.sh exists and is executable` | File check |
| `ci.sh exists and is executable` | File check |
| `ci.sh uses set -euo pipefail` | Shell convention |
| `Makefile exists (repo entry)` | File check |
| `Makefile has build target` | Makefile target |
| `Makefile.ci exists (template CI)` | File check |
| `Makefile.ci has test target` | Makefile target |
| `Makefile.ci has lint target` | Makefile target |
| `Makefile.ci has upgrade target` | Makefile target |
| `Makefile.ci upgrade target forwards optional VERSION variable` | VERSION arg passthrough |
| `Makefile upgrade target uses ./template/upgrade.sh (not ./template/script/upgrade.sh)` | Regression: bad path in script/docker/Makefile |
| `Makefile upgrade-check tolerates upgrade.sh exit 1 (update available)` | Regression #175: wrap exit 1 = success |
| `Makefile.ci upgrade-check tolerates upgrade.sh exit 1 (update available)` | Regression #175: same wrap on Makefile.ci |
| `test/smoke/test_helper.bash exists` | Directory structure |
| `test/smoke/script_help.bats exists` | Directory structure |
| `test/smoke/display_env.bats exists` | Directory structure |
| `test/unit/ directory exists` | Directory structure |
| `doc/readme/ directory exists` | Directory structure |
| `doc/test/ directory exists` | Directory structure |
| `doc/changelog/ directory exists` | Directory structure |
| `build.sh references template/script/docker/setup.sh` | Path reference |
| `run.sh references template/script/docker/setup.sh` | Path reference |
| `build.sh uses set -euo pipefail` | Shell convention |
| `build.sh supports --no-cache flag` | Force rebuild flag |
| `build.sh passes --no-cache to docker compose build when set` | NO_CACHE forwarded |
| `build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)` | Default keep tools |
| `build.sh supports --clean-tools flag` | Clean tools flag |
| `build.sh removes test-tools image when --clean-tools is set` | CLEAN_TOOLS forwarded |
| `run.sh uses set -euo pipefail` | Shell convention |
| `exec.sh uses set -euo pipefail` | Shell convention |
| `stop.sh uses set -euo pipefail` | Shell convention |
| `_lib.sh derives PROJECT_NAME from DOCKER_HUB_USER and IMAGE_NAME` | Shared derivation |
| `_lib.sh _compose_project wraps -p with PROJECT_NAME` | Shared compose wrapper |
| `_lib.sh defines _load_env helper` | Shared env loader |
| `_lib.sh defines _compute_project_name helper` | Shared helper |
| `_lib.sh defines _compose wrapper` | Shared compose wrapper |
| `build.sh routes compose call through _compose_project` | Uses shared lib |
| `run.sh routes compose calls through _compose_project` | Uses shared lib |
| `exec.sh routes compose call through _compose_project` | Uses shared lib |
| `stop.sh routes compose call through _compose_project` | Uses shared lib |
| `exec.sh loads .env via _load_env helper` | Uses shared lib |
| `stop.sh loads .env via _load_env helper` | Uses shared lib |
| `stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)` | No more orphan |
| `run.sh devel target uses compose up -d (not compose run --name)` | up + exec model |
| `run.sh devel branch uses compose exec to enter shell` | up + exec model |
| `run.sh devel branch installs trap to auto-down on exit` | Auto cleanup |
| `run.sh _devel_cleanup uses short timeout to avoid 10s grace period` | Fast exit |
| `run.sh non-devel TARGET still uses compose run --rm` | One-shot stages |
| `run.sh devel branch does not use 'compose run --name'` | Old pattern gone |
| `run.sh supports --instance flag` | --instance |
| `exec.sh supports --instance flag` | --instance |
| `stop.sh supports --instance flag` | --instance |
| `stop.sh supports --all flag` | --all |
| `run.sh exports INSTANCE_SUFFIX env var to compose` | env passing |
| `exec.sh exports INSTANCE_SUFFIX env var to compose` | env passing |
| `stop.sh exports INSTANCE_SUFFIX env var to compose` | env passing |
| `run.sh refuses when default container already running and no --instance` | collision |
| `init.sh-generated compose.yaml uses parameterized container_name` | template gen |
| `run.sh -h shows --instance in help` | help text |
| `exec.sh -h shows --instance in help` | help text |
| `stop.sh -h shows --instance in help` | help text |
| `build.sh supports --dry-run flag` | --dry-run |
| `run.sh supports --dry-run flag` | --dry-run |
| `exec.sh supports --dry-run flag` | --dry-run |
| `stop.sh supports --dry-run flag` | --dry-run |
| `build.sh -h shows --dry-run in help` | --dry-run help |
| `run.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh -h shows --dry-run in help` | --dry-run help |
| `stop.sh -h shows --dry-run in help` | --dry-run help |
| `exec.sh checks container is running before exec` | precheck |
| `exec.sh precheck error mentions run.sh hint` | friendly hint |
| `exec.sh exits non-zero with friendly hint when container not running` | precheck e2e |
| `exec.sh --dry-run skips precheck and prints compose command` | dry-run e2e |
| `script/docker/i18n.sh exists` | i18n module exists |
| `Dockerfile.test-tools includes bats-mock` | bats-mock available in test image |
| `Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)` | multi-arch build regression |
| `i18n.sh defines _detect_lang function` | _detect_lang in i18n.sh |
| `build.sh sources _lib.sh` | build.sh uses shared lib |
| `run.sh sources _lib.sh` | run.sh uses shared lib |
| `exec.sh sources _lib.sh` | exec.sh uses shared lib |
| `stop.sh sources _lib.sh` | stop.sh uses shared lib |
| `_lib.sh sources i18n.sh (delegates language detection)` | _lib delegates i18n |
| `setup.sh sources i18n.sh` | setup.sh uses shared i18n |
| `build.sh -h works when i18n.sh is missing (consumer Dockerfile /lint scenario)` | i18n fallback |
| `run.sh -h works when i18n.sh is missing` | i18n fallback |
| `exec.sh -h works when i18n.sh is missing` | i18n fallback |
| `stop.sh -h works when i18n.sh is missing` | i18n fallback |
| `setup.sh does not redefine _detect_lang` | No duplication |
| `VERSION file exists in template root` | Version file check |
| `upgrade.sh reads version from template/VERSION` | VERSION path |
| `upgrade.sh does not write .template_version` | No legacy write |
| `upgrade.sh runs init.sh after subtree pull` | Sync symlinks |
| `upgrade.sh cleans up legacy .template_version` | Legacy cleanup |
| `upgrade.sh supports --gen-conf flag` | Flag exists |
| `upgrade.sh --gen-conf delegates to init.sh --gen-conf` | Delegation |
| `upgrade.sh --help mentions --gen-conf` | Help text |
| `upgrade.sh updates main.yaml @tag without clobbering release-worker.yaml` | sed regression |
| `upgrade.sh main.yaml sed handles semver pre-release tags (RC → RC)` | `-rcN-rcN` regression |
| `upgrade.sh main.yaml sed handles stable → stable + RC → stable transitions` | RC → stable cleanup |
| `build-worker.yaml: no legacy in-job test-tools build step` | v0.9.13 GHCR migration |
| `build-worker.yaml: declares test_tools_version input` | v0.10.1 input replaces GITHUB_WORKFLOW_REF parse |
| `build-worker.yaml: does not resurrect the GITHUB_WORKFLOW_REF parse step` | regression guard |
| `build-worker.yaml: test build passes TEST_TOOLS_IMAGE from inputs` | build-arg wiring |
| `Dockerfile.example has ARG TEST_TOOLS_IMAGE with test-tools:local default` | ARG default |
| `Dockerfile.example FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` | named stage alias |
| `Dockerfile.example test stage copies from test-tools-stage, not test-tools:local` | stage rename migration |
| `Dockerfile.example declares ENV TZ (matches downstream fleet, #210)` | runtime $TZ alignment |
| `Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)` | runtime $LANGUAGE alignment |
| `release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools` | GHCR publisher |
| `release-test-tools.yaml declares packages:write permission` | ghcr auth scope |
| `release-test-tools.yaml builds multi-arch (amd64 + arm64)` | arch coverage |
| `release-test-tools.yaml uses template-repo-local Dockerfile path` | no subtree path confusion |
| `release-worker.yaml does not cp compose.yaml into the release archive` | v0.10.1 cp-list regression |
| `release-worker.yaml cp-list still includes Dockerfile + scripts` | positive cp-list guard |
| `build.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `run.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `build.sh uses subprocess check-drift (#49 Phase B-1)` | drift via subcommand |
| `run.sh uses subprocess check-drift (#49 Phase B-1)` | drift via subcommand |
| `run.sh contains XDG_SESSION_TYPE check` | X11/Wayland branch |
| `run.sh contains xhost +SI:localuser for wayland` | Wayland xhost |
| `run.sh contains xhost +local: for X11` | X11 xhost |
| `setup.sh default _base_path uses /..` | Path resolution |
| `setup.sh default _base_path uses double parent traversal` | Repo root traversal |

### test/unit/bashrc_spec.bats (18)

| Test | Description |
|------|-------------|
| `defines alias_func` | Function definition |
| `defines swc` | Function definition |
| `defines color_git_branch` | Function definition |
| `defines ros_complete` | Function definition |
| `defines ros_source` | Function definition |
| `defines ebc alias` | Alias definition |
| `defines sbc alias` | Alias definition |
| `alias_func is called` | Function call |
| `color_git_branch is called` | Function call |
| `ros_complete is called` | Function call |
| `ros_source is called` | Function call |
| `swc searches for catkin devel/setup.bash` | Catkin search |
| `ros_source references ROS_DISTRO` | ROS env var |
| `color_git_branch sets PS1` | PS1 setting |

### test/unit/pip_setup_spec.bats (3)

| Test | Description |
|------|-------------|
| `pip setup.sh runs pip install with requirements.txt` | pip install |
| `pip setup.sh sets PIP_BREAK_SYSTEM_PACKAGES=1` | Break system packages |
| `pip setup.sh fails when pip is not available` | Missing pip error |

### test/unit/ci_spec.bats (17)

| Test | Description |
|------|-------------|
| `_install_deps: skips apt-get and git when bats is already installed` | No-op fast path |
| `_install_deps: dies with clear error when apt-get update fails` | Explicit `apt-get update` error |
| `_install_deps: dies with clear error when apt-get install fails` | Explicit `apt-get install` error |
| `_install_deps: dies with clear error when git clone bats-mock fails` | Explicit `git clone` error |
| `_install_deps: happy path succeeds when bats absent and all deps install cleanly` | Full install path |
| `_install_deps: rewrites sources.list when APT_MIRROR_DEBIAN differs from default` | TW-mirror sed substitution path |
| `_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN equals default` | Default value short-circuit |
| `_install_deps: skips sources.list rewrite when APT_MIRROR_DEBIAN unset` | Unset env var short-circuit |
| `_run_shellcheck: invokes shellcheck against every expected script` | Wired-file regression guard |
| `_run_shellcheck: picks up every .sh file in script/docker/` | `find` covers new scripts |
| `_run_shellcheck: exits non-zero when shellcheck fails on any script` | Strict-mode propagation |
| `_run_via_compose: routes default mode to the ci service with COVERAGE=0` | Service routing — fast path |
| `_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1` | Service routing — coverage path |
| `_run_tests: passes --jobs N when parallel is on PATH` | Parallel-present branch |
| `_run_tests: omits --jobs when parallel is absent (graceful fallback)` | Parallel-missing branch |
| `main: dispatches no-flag default to the ci service` | End-to-end default dispatch |
| `main: dispatches --coverage to the coverage service` | End-to-end --coverage dispatch |

### test/unit/init_spec.bats (18)

Unit coverage for `init.sh` helpers that previous rounds exercised only
through the Level-1 integration test. Complements
`test/integration/init_new_repo_spec.bats` by locking edge cases that
are hard to trigger from a real `bash template/init.sh` invocation
(network-down version detection, main.yaml `@ref` fallback,
`_create_version_file` with no argument).

| Test | Description |
|------|-------------|
| `_detect_template_version: parses newest vX.Y.Z tag from git ls-remote` | Happy path + head -1 |
| `_detect_template_version: returns empty when git ls-remote fails` | Network-down fallback |
| `_detect_template_version: returns empty when no v*.*.* tags exist` | Nothing to match |
| `_detect_template_version: ignores non-semver tags (e.g. rc suffixes)` | Regex filters rc / pre-release |
| `_detect_template_version: reads VERSION file when present (no network)` | VERSION file priority |
| `_detect_template_version: VERSION file takes priority over git ls-remote` | Local-first resolution |
| `init.sh removes legacy .template_version when present` | Legacy cleanup |
| `init.sh succeeds when no legacy .template_version exists` | Clean state |
| `_create_new_repo: main.yaml uses given ref in workflow @ref` | Ref threading |
| `_create_new_repo: main.yaml falls back to @main when ref arg omitted` | Default ref |
| `_create_new_repo: main.yaml falls back to @main when ref arg is empty` | Empty-string → `@main` |
| `_create_new_repo: generates .env.example with IMAGE_NAME=<repo>` | Fallback image name |
| `_create_symlinks: produces all five docker-script symlinks` | Symlink set |
| `_create_symlinks: replaces a stale file at the symlink path` | Re-init over existing files |
| `_create_symlinks: keeps custom .hadolint.yaml when it differs` | Custom-hadolint preservation |

### test/unit/smoke_helper_spec.bats (19)

Exercises the runtime assertion helpers shipped in
`test/smoke/test_helper.bash` (used by downstream-repo smoke specs via
`load "${BATS_TEST_DIRNAME}/test_helper"`).

| Test | Description |
|------|-------------|
| `assert_cmd_installed passes when cmd is on PATH` | Happy path |
| `assert_cmd_installed fails with descriptive message when cmd missing` | Missing cmd |
| `assert_cmd_installed errors when cmd arg missing` | Required arg check |
| `assert_cmd_runs passes when cmd exits 0` | Happy path |
| `assert_cmd_runs uses custom version flag when given` | Custom flag |
| `assert_cmd_runs fails when cmd exits non-zero` | Broken binary |
| `assert_cmd_runs fails when cmd is not installed` | Missing cmd |
| `assert_file_exists passes when file is a regular file` | Happy path |
| `assert_file_exists fails when path is missing` | Missing path |
| `assert_file_exists fails when path is a directory` | Type check |
| `assert_dir_exists passes when path is a directory` | Happy path |
| `assert_dir_exists fails when path is missing` | Missing path |
| `assert_dir_exists fails when path is a file` | Type check |
| `assert_file_owned_by passes when owner matches` | Happy path |
| `assert_file_owned_by fails with owner diff when user mismatches` | Owner mismatch |
| `assert_file_owned_by fails when path missing` | Missing path |
| `assert_pip_pkg passes when pip show returns 0` | Package installed |
| `assert_pip_pkg fails when pip show returns non-zero` | Package missing |
| `assert_pip_pkg fails when pip is not installed` | pip itself missing |

### test/unit/terminator_config_spec.bats (10)

| Test | Description |
|------|-------------|
| `has [global_config] section` | Config section |
| `has [keybindings] section` | Config section |
| `has [profiles] section` | Config section |
| `has [layouts] section` | Config section |
| `has [plugins] section` | Config section |
| `profiles has [[default]]` | Default profile |
| `default profile disables system font` | Font setting |
| `default profile has infinite scrollback` | Scrollback setting |
| `layouts has Window type` | Window layout |
| `layouts has Terminal type` | Terminal layout |

### test/unit/terminator_setup_spec.bats (8)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when terminator is installed` | Dependency check |
| `check_deps fails when terminator is not installed` | Missing dep |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main creates terminator config directory` | Config dir |
| `main copies terminator config file` | Config copy |
| `main calls chown with correct user and group` | Permissions |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/unit/tmux_conf_spec.bats (12)

| Test | Description |
|------|-------------|
| `defines prefix key` | tmux prefix |
| `sets default shell to bash` | Shell setting |
| `sets default terminal` | Terminal setting |
| `enables mouse support` | Mouse |
| `enables vi status-keys` | vi mode |
| `enables vi mode-keys` | vi mode |
| `defines split-window bindings` | Split bindings |
| `defines reload config binding` | Reload binding |
| `enables status bar` | Status bar |
| `sets status bar position` | Status bar position |
| `declares tpm plugin` | tpm plugin |
| `initializes tpm at end of file` | tpm init |

### test/unit/tmux_setup_spec.bats (9)

| Test | Description |
|------|-------------|
| `check_deps returns 0 when tmux and git are installed` | Dependency check |
| `check_deps fails when tmux is not installed` | Missing tmux |
| `check_deps fails when git is not installed` | Missing git |
| `_entry_point calls main when deps pass` | Entry point |
| `_entry_point fails when deps missing` | Entry point fail |
| `main clones tpm repository` | tpm clone |
| `main creates tmux config directory` | Config dir |
| `main copies tmux.conf to config directory` | Config copy |
| `script runs entry_point when executed directly` | Direct-run guard |

### test/unit/upgrade_spec.bats (35)

Unit tests for `upgrade.sh` helpers. Uses the sed-range pattern to extract
one function at a time into a minimal harness (with `_log` / `_error`
stubs), so each helper runs in a sandboxed git repo without needing to
source the full `upgrade.sh` (which would trigger its top-level
`cd REPO_ROOT`).

Covers: `_warn_config_drift` (silent / fires on drift / diff hint),
the three safety guards added after the v0.9.7 Jetson incident
(`_require_git_identity`, `_require_clean_merge_state`,
`_verify_subtree_intact` with rollback), structural invariants that
pin call-ordering in `_upgrade` (identity check runs before subtree
pull, integrity verification runs after, pre-pull HEAD is snapshotted
for rollback), and the SemVer §11-aware `_semver_cmp` + `_check`
behavior added for issue #156 (prerelease ahead of latest stable
must not be reported as "needing downgrade").

| Test | Description |
|------|-------------|
| `_warn_config_drift silent when no template/config in HEAD` | Initial setup |
| `_warn_config_drift silent when pre and post hashes match` | No drift |
| `_warn_config_drift prints WARNING + diff hint when hashes differ` | Drift reported |
| `upgrade.sh defines _warn_config_drift` | Helper present |
| `upgrade.sh invokes _warn_config_drift after subtree pull` | Call site present |
| `upgrade.sh captures pre-pull template/config tree hash` | Snapshot taken |
| `_require_git_identity succeeds when name + email are set` | Happy path |
| `_require_git_identity fails when user.email is unset` | Email guard |
| `_require_git_identity fails when user.name is unset` | Name guard |
| `_require_clean_merge_state succeeds in clean repo` | Happy path |
| `_require_clean_merge_state fails when MERGE_HEAD exists` | Mid-merge guard |
| `_require_clean_merge_state fails when rebase-merge dir exists` | Mid-rebase guard |
| `_verify_subtree_intact succeeds when all markers present` | Happy path |
| `_verify_subtree_intact rolls back when template/.version is missing` | Destructive-FF rollback |
| `_verify_subtree_intact rolls back when template/script/docker/setup.sh is missing` | Marker rollback |
| `upgrade.sh calls _require_git_identity before subtree pull` | Pre-flight ordering |
| `upgrade.sh calls _verify_subtree_intact after subtree pull` | Post-flight ordering |
| `upgrade.sh snapshots pre-pull HEAD for rollback` | Rollback anchor |
| `_semver_cmp: equal versions return 0` | Equality |
| `_semver_cmp: lower core returns 1` | Behind core |
| `_semver_cmp: higher core returns 2` | Ahead core |
| `_semver_cmp: pre-release < final at same core (rc1 < 0.12.0)` | SemVer §11 a |
| `_semver_cmp: final > pre-release at same core (0.12.0 > rc1)` | SemVer §11 b |
| `_semver_cmp: rc1 < rc2 (lex pre-release ordering)` | Pre-release order |
| `_semver_cmp: rc2 > rc1` | Pre-release order |
| `_semver_cmp: pre-release of newer beats older final (0.12.0-rc1 > 0.11.0)` | Cross-core |
| `_semver_cmp: older final < pre-release of newer (0.11.0 < 0.12.0-rc1)` | Cross-core |
| `_check: equal versions report up-to-date and exit 0` | Happy equal |
| `_check: behind latest reports update available and exits 1` | Behind |
| `_check: prerelease ahead of latest stable exits 0 (issue #156 case)` | Regression #156 |
| `_check: stable later than latest stable exits 0 (defensive)` | Local-only tag |
| `_check: prerelease behind latest stable proposes upgrade (rc1 → 0.12.0)` | Leave prerelease |
| `_get_latest_version: returns 0 even when internal pipe fails (bash 5.3 set-e safety)` | Alpine bash 5.3 errexit-from-cmdsub workaround (lock the `\|\| true` guard) |
| `_get_latest_version: empty result feeds _check's 'Could not fetch' guard` | Empty result still surfaces real fetch failures |
| `_upgrade refuses to downgrade from a newer local version` | Implicit-downgrade guard |

### test/unit/gitignore_spec.bats (16)

Unit tests for `template/script/docker/lib/gitignore.sh` — the canonical
`.gitignore` set + sync/untrack helpers introduced for issue #172.

| Test | Description |
|------|-------------|
| `_canonical_gitignore_entries: emits exactly the 7 canonical lines` | Single source of truth |
| `_canonical_gitignore_entries: list is stable order` | Deterministic output |
| `_sync_gitignore: creates the file when missing, with marker block + all entries` | Greenfield |
| `_sync_gitignore: empty file gets marker block + all entries appended` | Empty file |
| `_sync_gitignore: file with all entries already present is a no-op` | Already-synced |
| `_sync_gitignore: appends only missing entries when subset already present` | Drift fill-in |
| `_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)` | User-line preservation |
| `_sync_gitignore: idempotent — second invocation produces no further changes` | Idempotency |
| `_sync_gitignore: no duplicate canonical lines after re-run` | No-dup invariant |
| `_sync_gitignore: ends with newline so future appends start on their own line` | Trailing-newline guarantee |
| `_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml` | 15-repo drift fix |
| `_untrack_canonical_in_repo: leaves untracked files alone` | Scope guard |
| `_untrack_canonical_in_repo: no-op when no canonical files tracked` | Healthy-repo no-op |
| `_untrack_canonical_in_repo: handles tracked coverage/ directory` | Directory entry |
| `_untrack_canonical_in_repo: idempotent — second run succeeds without error` | Re-run safety |
| `_untrack_canonical_in_repo: untracks all canonical entries that match` | Multi-entry sweep |

### test/integration/init_new_repo_spec.bats (36)

End-to-end verification that `init.sh` produces a complete repo skeleton in
an empty directory. **Level 1** (file generation only, no Docker). The
**Level 2** equivalent (real `build.sh` / `run.sh` / `exec.sh` / `stop.sh`)
runs as the `integration-e2e` job in `.github/workflows/self-test.yaml`,
which has access to a Docker daemon on the host runner.

| Test | Description |
|------|-------------|
| `init.sh detects empty dir and creates new repo skeleton` | Smoke |
| `new repo: Dockerfile is copied from template` | Dockerfile gen |
| `new repo: compose.yaml exists and references the repo name` | compose gen |
| `new repo: .env.example contains IMAGE_NAME=<reponame>` | env fallback |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: .gitignore exists` | gitignore |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink → template/script/docker/build.sh` | symlink target |
| `new repo: run.sh / exec.sh / stop.sh / Makefile symlinks correct` | symlink set |
| `new repo: template/VERSION exists (no legacy .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink (not legacy tui.sh)` | post-rename symlink |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions` | upgrade cleanup |
| `new repo: build.sh -h works against the generated symlink` | smoke build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke stop.sh |
| `init.sh --gen-conf copies setup.conf to repo root` | setup.conf gen |
| `init.sh --gen-conf refuses to overwrite existing setup.conf` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: per-repo setup.conf not created by default` | template default usage |

### test/integration/fresh_clone_portability_spec.bats (2)

End-to-end verification for the fresh-clone-on-a-different-machine scenario:
the consumer repo's `setup.conf` has already been committed by another
contributor and carries either a stale absolute `mount_1` path (the Jetson
bug) or the portable `${WS_PATH}` form. Runs the real `build.sh` +
`setup.sh` (no mocks) and asserts the auto-migration / per-machine detection
pipeline lands a valid `.env` + `compose.yaml`. **Level 1** (no Docker
invocation — `build.sh --dry-run`).

| Test | Description |
|------|-------------|
| `fresh clone with stale absolute mount_1: build.sh auto-migrates + generates local .env` | Stale-path auto-migrate |
| `fresh clone with portable ${WS_PATH} mount_1: no warning, .env gets local path` | Happy path round-trip |

### test/integration/upgrade_spec.bats (8)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags
on a minimal subtree layout) attached to a sandbox downstream repo.
**Level 1** (no Docker). Exercises the happy path, the pre-flight
guards, and — most importantly — the destructive-FF rollback path added
after the Jetson v0.9.7 incident (stubs `git-subtree pull` via
`GIT_EXEC_PATH` to simulate the bug and asserts the repo is restored).

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps template/.version, pulls new content, updates main.yaml` | Happy path |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `make upgrade-check (downstream Makefile): exit 0 when update available (#175)` | Regression #175: make wraps exit 1 |
| `make upgrade-check (downstream Makefile): exit 0 when up-to-date` | Up-to-date path stays green |
| `upgrade.sh fails fast when git identity is missing` | Pre-flight identity guard |
| `upgrade.sh fails fast when MERGE_HEAD is present` | Pre-flight merge-state guard |
| `upgrade.sh rolls back when git-subtree does a destructive fast-forward` | Destructive-FF rollback |

### test/integration/gitignore_sync_spec.bats (8)

End-to-end coverage that wires `lib/gitignore.sh` through `init.sh`'s
new-repo + existing-repo paths and `upgrade.sh`'s commit step. Standalone
fixture (independent of `upgrade_spec.bats`'s stub-init fixture) because
gitignore sync requires the **real** `init.sh` to run during Step 3 of
`upgrade.sh`. Issue #172.

| Test | Description |
|------|-------------|
| `init.sh new-repo: .gitignore contains all 7 canonical entries` | New-repo path uses lib |
| `init.sh new-repo: .gitignore has the 'managed by template' marker` | Marker comment present |
| `init.sh existing-repo: appends missing canonical entries to user .gitignore` | Drift fill-in |
| `init.sh existing-repo: untracks compose.yaml that was committed` | 15-repo drift heal |
| `init.sh existing-repo: setup.conf stays committed across init runs (#201)` | 2-file model: setup.conf is user override |
| `init.sh existing-repo: idempotent — second run produces no .gitignore changes` | Re-run no-op |
| `upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit` | One-shot upgrade |
| `upgrade.sh end-to-end: idempotent on a second run — no extra commits` | Re-upgrade clean |
