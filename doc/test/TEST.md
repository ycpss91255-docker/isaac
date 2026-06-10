# TEST.md

Template self-tests: **1465 tests** total (1391 unit + 74 integration).

> Counted scope is the `make -f Makefile.ci test` self-test suite —
> what runs in the `Self Test` CI job. The 36 shared smoke tests under
> `test/smoke/` are a separate suite that runs at Dockerfile `test`-stage
> build time (via `./build.sh test`) inside both this repo and every
> downstream repo, and are documented in [Smoke Tests](#smoke-tests)
> below. They are **not** included in the 1080 figure because they are
> build-time assertions, not self-tests.

## Test Files

### test/unit/lib_spec.bats (43)

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
| `_print_config_summary wraps dividers + section headers in ANSI when FORCE_COLOR=1 (#309)` | Color migration via _log_plain |
| `_print_config_summary omits ANSI when NO_COLOR=1 overrides FORCE_COLOR=1 (#309)` | NO_COLOR precedence on summary |

### test/unit/log_spec.bats (52)

OTel-aligned logger (#423, #438). Single-sink tty-detect dispatch,
`LOG_FORMAT=auto|text|json` override, strict body enforcement (unregistered
body = fatal), `display=` attribute for i18n text in text mode, UTC
microsecond timestamps, `_log_plain` removed.

| Category | Tests |
|----------|-------|
| Text output format (`LOG_FORMAT=text`): timestamp + aligned level + tag, multi-token join, attr=val skip, `display=` override | 10 |
| Timestamp: UTC with microsecond precision in both text and JSON | 2 |
| Stream routing: stdout for INFO/DEBUG, stderr for WARN/ERROR/FATAL | 2 |
| Single-sink tty-detect dispatch (#438): non-TTY auto JSON, `LOG_FORMAT=text` force, `LOG_FORMAT=json` force, `LOG_FORMAT=auto` equiv | 5 |
| JSON output: OTel fields, custom attributes, severity numbers, per-line structure | 4 |
| TRACEPARENT in JSON: trace_id/span_id present/absent | 2 |
| Strict body enforcement (#438): unregistered fatal, registered OK, empty OK, error names body + file | 4 |
| Missing service rejected, `_log_fatal` does not auto-exit | 3 |
| Scoped wrappers: `_log_with_trace` save/restore, `_log_with_span` trace_id | 4 |
| `_log_plain` removed (#438) | 1 |
| `_log_color_enabled`: TTY detect, FORCE_COLOR, NO_COLOR precedence | 3 |
| FORCE_COLOR text: red bold ERROR, yellow WARN, NO_COLOR strips | 3 |
| Event registry: registered/unregistered/comment detection | 3 |
| lnav format file | 2 |

### test/unit/setup_spec.bats (358)

Covers core detection (user/hardware/docker/GPU/GUI), the INI parser
(`_parse_ini_section` and its shared core `_ini_tokenize`), setup.conf
section merging (`_load_setup_conf` with replace strategy), image_name
rule engine via `[image] rules`,
resolvers (`_resolve_gpu`, `_resolve_gui`), workspace path detection,
conf hash computation, drift detection, `write_env` (now including
runtime values + SETUP_* metadata), the `main()` CLI, and workspace
writeback (first-time bootstrap / user-edit respect / opt-out).

| Category | Tests |
|----------|-------|
| `detect_user_info` / `detect_hardware` / `detect_docker_hub_user` / `detect_gpu` / `detect_gui` | 11 |
| `_is_ssh_x11` / `_setup_ssh_x11_cookie` (#321: 6 detection cases + cookie rewrite via stubbed xauth + warn on missing xauth + write_env XAUTHORITY override on/off) | 10 |
| `_parse_ini_section` (section isolation, comments, trim, missing, dotted-section non-absorption, dotted section read, dup/reopened order) | 9 |
| `_ini_tokenize` (per-entry owning section + header dedup, dotted keys verbatim) | 2 |
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
| Per-section setup.conf parameter end-to-end coverage (#202: [deploy] gpu_mode/count/capabilities/runtime, [gui] mode, [network] mode/ipc/pid/network_name/port_*, [resources] shm_size, [environment] env_*, [tmpfs] tmpfs_*, [devices] device_*/cgroup_rule_*, [volumes] mount_2..N, [security] privileged) | 28 |
| `_validate_stage_name` (#215: format / baseline / reserved exit codes; #493: accepts devel-test as emittable) | 5 |
| `_parse_dockerfile_stages` (#215: extract, dedup, file-order, missing file, lowercase `as` rejection; #493: devel-test promoted out of baseline) | 7 |
| `_compute_dockerfile_hash` (#215: stable / add / remove / non-FROM-AS edits / missing) | 5 |
| `auto-emit` end-to-end (#215: #108 runtime regression, multi-stage emit, target/image/container_name shape, no-extras, baseline collision, reserved tag latest/v0, invalid format WARN+skip, SETUP_DOCKERFILE_HASH, drift on add, drift on remove) | 11 |
| Per-stage overrides #220 helpers (`_parse_stage_sections`, `_load_stage_overrides`, `_validate_stage_override_key` allowlist, `_resolve_stage_scalar`, `_resolve_stage_list` append/replace + ordering + meta-key skip) | 20 |
| Per-stage overrides #220 compose emit integration (zero-diff regression for stages w/o overrides, `gui.mode=off` strips X11, `network.mode=bridge` per-stage + ports, `volumes.mount_inherit=false` replaces, orphan `[stage:foo]` WARN, disallowed override-key WARN, `[stage:sys]` hard-error; #493: `[stage:devel-test]` GPU control surface on the test service) | 8 |
| #285 `--quiet` / `-q` flag + success confirmation lines on set / add / remove / reset / apply (default-on confirmation with file: + next: hint on the 4 mutating subcommands; reset's existing `reset_done` line gated on `_quiet`; apply's existing 2-line summary gated on `_quiet`; mutation still writes to setup.conf under `--quiet`) | 11 |
| #328 `[logging]` CLI orphan fix (`_setup_known_section` recognises `logging` + `logging.<svc>`; rightmost-dot spec parsing for `logging.<svc>.<key>`; `set/show/remove` round-trip on global + per-service keys; validators surface as `Invalid value` errors; whole-section `show logging` lists all 4 keys; per-service editing reaches devel / test / runtime through CLI subcommands) | 9 |
| #338 apply CLI flags (`--gui auto|force|off` per-invocation override via print-resolved diff vs setup.conf; `--gui=force` short-form; invalid `--gui bogus` rejected; `--print-resolved` dumps key=value without writing `.env` / `compose.yaml`; `--no-x11-cookie` sets `X11_COOKIE_SKIP=1` in the dump; default `X11_COOKIE_SKIP=0`; `SETUP_GUI` env var overrides setup.conf when no CLI flag; CLI `--gui` wins over `SETUP_GUI` env var) | 9 |
| #502 A2 file roles (`apply` writes the `.env.generated` cache, scaffolds the `.env` workload overlay when absent, never overwrites an existing overlay, `_scaffold_env_overlay` idempotent, legacy `.env` cache migrated to `.env.generated` + backed up, devel service emits `env_file: - .env`) | 6 |
| #503 `_generate_runtime_dockerfile` ENV-bake primitive (injects `ENV` after `FROM ... AS runtime`, expands cross-refs, returns 1 with no runtime stage / empty `[environment]`) | 4 |
| #504 `config/app/` dev bind-mount (`apply` binds `./config/app:/opt/app/config` when the dir is present, omits it when absent) | 2 |

### test/unit/tui_spec.bats (124)

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
| Per-stage `[stage:NAME]` round-trip (#220: namespaced load, append new section, multi-section append, round-trip, in-place update of existing section) | 5 |
| `_validate_log_*` (#328: driver name shape, max_size num+unit, max_file positive int, compress boolean; covers happy paths + rejection of empty / whitespace / wrong unit / decimals / case mismatches) | 7 |
| `_edit_section_lifecycle` (#514: restart radiolist writes simple policy + default no; on-failure:N assembly; empty-N -> bare on-failure; invalid-N re-prompt then accept) | 5 |
| `_edit_section_deploy` legacy runtime->gpu_runtime migration (#517: suggest msgbox when legacy [deploy] runtime present; silent when gpu_runtime already used; writes canonical gpu_runtime key) | 3 |
| `_show_runtime_env_info` (#497: info-only msgbox points at the .env overlay; writes no override) | 1 |

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

### test/unit/tui_flow.bats (100)

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
| `_edit_section_network` (host+host+pid no shm prompt, bridge prompts name+ports, ipc=private prompts shm, empty network_name allowed) | 4 |
| `_edit_section_deploy` (off short-circuits — only writes gpu_mode) | 1 |
| Multi-section dispatch from main menu (network → host → save) | 1 |
| Per-stage UI #220 (`_list_dockerfile_stages_available` from-Dockerfile + baseline filter, `_count_stage_overrides` OVR+CURRENT dedup + empty skip, `_edit_stage_gui` mode + __inherit, `_edit_stage_scalar` write + empty-clears, `_edit_stage_list` inherit toggle + add) | 10 |
| Menu restructure #221 (i18n keys for main.runtime/mounts/features × 4 langs; `_render_runtime_menu` / `_render_mounts_menu` / `_render_features_menu` function existence; main-menu dispatch for image/build/runtime/mounts/features + bare network/deploy/gui/volumes/environment no longer dispatch from main; Runtime sub-menu dispatch for network/deploy/gui/environment + __back/Cancel; Mounts sub-menu dispatch for volumes/devices/tmpfs + __back/Cancel; Features sub-menu __back, per_stage enabled enters editor, per_stage hidden shows msgbox without entering editor; Advanced sub-menu image/build/devices/tmpfs entries removed, security still dispatches) | 31 |
| #328 logging menu dispatch (Runtime menu's `logging` entry calls `_edit_section_logging`; `_edit_section_logging`'s top-level menu routes `global` to `_edit_logging_keys logging` and `devel` / `test` / `runtime` to `_edit_logging_keys logging.<svc>`) | 5 |

### test/unit/build_worker_yaml_spec.bats (37)

Structural assertions for `.github/workflows/build-worker.yaml` (#195
+ #243 + #272 + #273 + #378 b1). Reusable workflows are not exec'd by
these tests; instead grep patterns lock the YAML invariants —
`context_path` / `dockerfile_path` inputs declared with the right
defaults, all 4 `docker/build-push-action` steps (devel-test / devel /
runtime-test / runtime after #243) forwarding those inputs, no
leftover `context: .` / `file: ./Dockerfile` literals, the GHA-cache
plumbing (#272: `cache_variant` input, `Compute cache scope` step;
#378 b1: per-target scope suffix so a late-stage COPY change in one
target no longer cascades into siblings' manifests), and the #273
doc-only PR fast-pass (`path-filter` job; Phase 2 classifier is pure
shell via `git diff --name-only base...head` + `case` glob, no
`dorny/paths-filter` dependency; 6-path allowlist; compute-matrix +
build gated on `code_changed`; docker-build aggregator short-circuits
on doc-only PRs).

| Category | Tests |
|----------|-------|
| `inputs.context_path` declared with `default: "."` | 1 |
| `inputs.dockerfile_path` declared with `default: ""` | 1 |
| 4 build steps reference `inputs.context_path` (#243 added runtime-test) | 1 |
| 4 build steps reference `inputs.dockerfile_path` with `format()` fallback | 1 |
| No leftover `context: .` literals | 1 |
| No leftover `file: ./Dockerfile` literals | 1 |
| Default values together preserve repo-root-Dockerfile callers | 1 |
| User build-args use long form matching Dockerfile.example sys stage (#198: USER_NAME / USER_GROUP / USER_UID / USER_GID across 4 build steps + no short-form regression) | 5 |
| `build_contexts` input forwards to docker/build-push-action `build-contexts:` (#207: input declared with empty default, 4 build steps forward, default preserves zero-diff) | 3 |
| #243 stage rename + runtime-test smoke: `target: devel-test` (renamed from `test`), no leftover `target: test`, `target: runtime-test` exists, runtime-test gated on `inputs.build_runtime` (>=2 occurrences shared with runtime gate) | 4 |
| #272 + #378 b1 GHA buildx cache: `cache_variant` input declared with empty default, `Compute cache scope` step emits `id: cache` + base key (no `-cache` suffix; per-target suffix appended at use site), 4 build steps use per-target `<base>-<target>-cache` scopes (cache-from + cache-to per target), no legacy shared-scope leftover (negative regression), 4 build steps preserve `mode=max`, default preserves zero-diff for single-call callers | 6 |
| #273 doc-only PR fast-pass (Phase 1 + Phase 2 shell rewrite): `path-filter` job declared, classifier is pure shell (`git diff --name-only base...head` + `case` glob; no `dorny/paths-filter` dependency), reads EVENT_NAME / BASE_SHA / HEAD_SHA from env: keys so the case body stays portable, non-PR event short-circuits before git diff (BASE_SHA / HEAD_SHA empty on push / tag / workflow_dispatch), 6-path allowlist (`**/*.md`, `doc/**`, `LICENSE`, `.gitignore`, `.github/CODEOWNERS`, `.github/dependabot.yml`) in a single `case` arm, `compute-matrix` + `build` jobs gated on `code_changed == 'true'` (2 occurrences), `docker-build` aggregator handles `code_changed == 'false'` short-circuit + `needs: [path-filter, build]`, non-PR triggers always set `code_changed=true` | 8 |
| #470 opt-in `free_disk_space` for large BASE_IMAGE repos: input declared `type: boolean` default `false`, step gated on `inputs.free_disk_space`, uses `jlumbroso/free-disk-space@...`, positioned before `Set up Docker Buildx` so the overlayfs snapshot dir has room | 4 |

### test/unit/self_test_yaml_spec.bats (52)

Structural assertions for `.github/workflows/self-test.yaml`. Locks
eight cumulative invariants:

1. **#305 actionlint gate** — `actionlint` job declared, runs
   `rhysd/actionlint` via Docker pinned to an explicit version
   (`x.y.z`); downstream jobs (`test`, `integration-e2e`,
   `behavioural`) need it so the workflow-validator class of
   regression that wedged v0.26.0-rc1 (refs #297) is caught early.

2. **#317 P1 classifier + buildx GHA cache** — a `classify` job
   emits `code_changed` + `behavioural_relevant` outputs from PR
   diff against the doc-only allow-list (`doc/**` + `README.md` +
   `LICENSE`) and behavioural block-list (entrypoint.sh + compose
   + Dockerfile.example/.test-tools + wrappers + init/upgrade +
   `test/behavioural/**` + `.github/workflows/**`); the `test` job
   always runs (required check) but short-circuits to SUCCESS on
   doc-only PRs; `integration-e2e` and `behavioural` gate via
   job-level `if:`; all three test-tools image builds use
   `docker/build-push-action` with shared `scope=test-tools` GHA
   cache.

3. **#317 P1 follow-up classifier hardening** — `classify` job is
   fail-open: `set -uo pipefail` (no `-e`) so transient diff/fetch
   errors don't crash the job and wedge every PR via the Q4
   fail-closed chain. Explicit `git fetch origin` of the base ref
   with `--depth=200` before diff so fork PRs (where
   `actions/checkout@v6 fetch-depth: 0` only fetches the head
   branch) don't trip on missing `origin/<base>`.

4. **#317 P2 Obtain step + rolling tag fallback** — each of the 3
   downstream jobs (`test`, `integration-e2e`, `behavioural`)
   precedes its test-tools provisioning with an `Obtain` step
   implementing the 3-layer fallback: PR touched
   `dockerfile/Dockerfile.test-tools` -> rebuild local; else
   `docker pull ghcr.io/ycpss91255-docker/test-tools:main` and
   re-tag; else fall back to a from-source rebuild. For `test` +
   `behavioural` (which `docker compose run` test-tools), the
   buildx Build step gates on `steps.obtain.outputs.build_local
   == 'true'` so the hot path skips it and the cold path reuses
   P1's GHA cache. For `integration-e2e` (which `docker compose
   build`, whose `FROM ${TEST_TOOLS_IMAGE}` resolves against the
   host docker daemon), the buildx `driver: docker` override is
   preserved and the rebuild fallback is inlined as plain
   `docker build` — GHA cache is not available on this driver,
   accepted because the hot path is `docker pull :main` and cold
   path matches pre-P2 cost. `integration-e2e` additionally
   passes `TEST_TOOLS_IMAGE: test-tools:local` to `./build.sh
   test` so the wrapper script skips its own internal test-tools
   build, reusing the image populated by the Obtain step.

5. **#317 P3 behavioural conditional + block-list expansion** —
   `behavioural` job's job-level `if:` tightens from
   `code_changed == 'true'` (P1) to `behavioural_relevant ==
   'true'` (the narrower output P1 already emitted but didn't
   consume). PRs that change pure lint / unit-test paths
   covered by `test` now skip the docker.sock-mounted compose
   run, saving ~3-5 min per such PR. The behavioural block-list
   in `classify` is extended with `script/docker/setup.sh` +
   `script/docker/i18n.sh` + `script/docker/lib/**` +
   `script/docker/prune.sh` (gotcha-5): each affects `.env` /
   `compose.yaml` generation or wrapper behaviour that the
   compose service exercises end-to-end, so they must invalidate
   the behavioural-skip optimization.

6. **#337 `ci-rollup` aggregator** — a single always-running
   (`if: always()`) `ci-rollup` job sits downstream of every PR
   check and collapses their results into one pass/fail signal that
   branch protection can require. The verifier shell step consumes
   every `${{ needs.<job>.result }}` and applies a 2-tier rule:
   `actionlint` / `classify` / `test` must be `success`;
   conditionally-gated jobs (`shellcheck` / `hadolint` /
   `integration-e2e` / `behavioural`) may be `success` or `skipped`
   (their job-level `if:` legitimately skips on doc-only / non-
   behavioural PRs per #317 P1/P3, #376). Adding sub-jobs (#377)
   to the rollup's `needs:` list becomes a workflow-internal
   change with no branch-protection update required.

7. **#376 ShellCheck + Hadolint dedicated jobs** — `shellcheck` runs
   on plain ubuntu-latest with the pre-installed binary (no buildx,
   no test-tools image, ~30s feedback on a regression) via
   `ci.sh --shellcheck-only`. `hadolint` uses
   `hadolint/hadolint-action@v3.1.0` to lint
   `dockerfile/Dockerfile.example` + `dockerfile/Dockerfile.test-tools`
   (both template-owned; downstream Dockerfile.example consumers
   inherit the lint pass). Both gate on
   `needs.classify.outputs.code_changed == 'true'` so doc-only PRs
   SKIP them. Both join `ci-rollup`'s `needs:` list, and `release`
   also gates on them so a tag with a lint regression doesn't publish
   a Release.

8. **#377 Bats unit/integration split + Kcov coverage move** — the
   pre-#377 monolithic `test` job is fully removed and replaced by
   three sibling jobs:
   - `bats-unit` (matrix `shard: ['1/2', '2/2']`, `fail-fast: false`):
     each shard runs a round-robin partition of `test/unit/*_spec.bats`
     via `ci.sh --bats-unit-shard ${{ matrix.shard }}`. Parallel
     execution drops PR wall-time from ~5min to ~2min.
   - `bats-integration`: runs `test/integration/` via
     `ci.sh --bats-integration`. Pulled out of the unit serial path
     so each unit shard sees only its share.
   - `coverage`: `if: github.event_name == 'push' && github.ref ==
     'refs/heads/main'` — gated to main pushes only. Runs
     `ci.sh --coverage` (full kcov pipeline) and uploads to Codecov.
     **NOT in `ci-rollup`'s `needs:`** — coverage failure must not
     block PR merge. PR-side coverage delta still works because
     Codecov compares the PR head against the latest main coverage
     blob.

   `ci-rollup needs:` now `[actionlint, classify, shellcheck,
   hadolint, bats-unit, bats-integration, integration-e2e,
   behavioural]` (8 jobs) — every PR-check job. `release needs:`
   updates from `[shellcheck, hadolint, test, integration-e2e,
   behavioural]` → `[shellcheck, hadolint, bats-unit, bats-integration,
   integration-e2e, behavioural]`. Post-#377 only `actionlint` +
   `classify` are hard-mandatory in `ci-rollup`'s verifier (the
   always-running `test` job no longer exists).

| Category | Tests |
|----------|-------|
| `actionlint` job declared | 1 |
| `actionlint` step uses `rhysd/actionlint:<pinned-version>` Docker image | 1 |
| `classify` job declared with `code_changed` + `behavioural_relevant` outputs | 3 |
| `classify` doc-only allow-list + behavioural block-list + non-PR default | 3 |
| `bats-unit`/`bats-integration`/`integration-e2e`/`behavioural` declare `needs: [actionlint, classify]` | 4 |
| `bats-unit`/`bats-integration` job-level `if: code_changed == 'true'` + no remaining monolithic `test:` job (#377) | 3 |
| `integration-e2e` job-level `if: code_changed == 'true'` + `behavioural` job-level `if: behavioural_relevant == 'true'` (#317 P3 tightens) | 2 |
| `bats-unit`/`bats-integration`/`behavioural` use `docker/build-push-action@v6` with `scope=test-tools` GHA cache | 3 |
| `classify` fail-open (`set -uo pipefail`) + pre-fetch base ref (#317 gotcha-1/2) | 2 |
| `bats-unit` Obtain step pulls `:main` with 3-layer fallback + Build step gated on `build_local` (#317 P2 + #377) | 2 |
| `bats-integration` Obtain step + 3-layer fallback (#317 P2 + #377) | 1 |
| `integration-e2e` Obtain step + `TEST_TOOLS_IMAGE` env passthrough + no `driver: docker` pin (#317 P2) | 2 |
| `behavioural` Obtain step with 3-layer fallback (#317 P2) | 1 |
| Obtain steps pre-fetch base ref (5 occurrences post-#377: classify + 4 jobs, #317 P2 reuses P1 gotcha-2 fix) | 1 |
| `classify` behavioural block-list extends to `setup.sh` + `i18n.sh` + `lib/**` + `prune.sh` (#317 P3 gotcha-5) | 1 |
| `ci-rollup` declared + `needs: [actionlint, classify, shellcheck, hadolint, bats-unit, bats-integration, integration-e2e, behavioural]` + `if: always()` (#337 + #376 + #377) | 3 |
| `ci-rollup` does NOT need `coverage` (#377) | 1 |
| `ci-rollup` verify step consumes every `needs.<job>.result` + SKIPPED treated as pass for conditional jobs + `success` required for hard-mandatory jobs (#337 + #376 + #377) | 3 |
| `shellcheck` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + runs `ci.sh --shellcheck-only` on plain ubuntu-latest with no buildx (#376) | 3 |
| `hadolint` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + lints both template-owned Dockerfiles via `hadolint-action` (#376) | 3 |
| `bats-unit` declared + `strategy.matrix.shard: ['1/2', '2/2']` + `fail-fast: false` + invokes `ci.sh --bats-unit-shard ${{ matrix.shard }}` (#377) | 3 |
| `bats-integration` declared + invokes `ci.sh --bats-integration` (#377) | 2 |
| `coverage` declared + `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` + runs `ci.sh --coverage` + uploads Codecov (#377) | 3 |
| `release` job needs `[shellcheck, hadolint, bats-unit, bats-integration, integration-e2e, behavioural]` before publishing a tag (#376 + #377) | 1 |

### test/unit/release_test_tools_yaml_spec.bats (10)

Structural assertions for `.github/workflows/release-test-tools.yaml`.
Locks the publish surface that downstream Dockerfile.example's `FROM
${TEST_TOOLS_IMAGE} AS test-tools-stage` depends on. The workflow has
three publish modes:

1. **Tag push (`v*`)** — multi-arch `:<version>` + `:latest`. Cuts the
   release downstream consumers pin via `inputs.test_tools_version`.
2. **Main push** (#317 P2) — multi-arch `:main` rolling tag. Used by
   self-test.yaml's Obtain step to skip from-source rebuilds. Paths
   filter (gotcha 3) restricts to commits that touched
   `dockerfile/Dockerfile.test-tools` or this workflow.
3. **workflow_dispatch** — manual `:latest` republish, kept unfiltered
   for bootstrap.

Smoke step uses `steps.tags.outputs.smoke` so it always pulls the tag
the current trigger produced (rather than statically pulling `:latest`,
which would leave a freshly-pushed `:main` unverified).

| Category | Tests |
|----------|-------|
| Triggers on `v*` tag push (existing) | 1 |
| Triggers on main push (#317 P2) | 1 |
| Main push trigger has `paths:` filter limiting to Dockerfile.test-tools + workflow self (#317 P2 gotcha-3) | 1 |
| Triggers on `workflow_dispatch` (existing) | 1 |
| Resolve tags step: 3 publish modes (`v*` + `main` + dispatch) emit correct tag sets and `smoke` output | 3 |
| Smoke step pulls trigger's tag via `steps.tags.outputs.smoke` (#317 P2) | 1 |
| Build step pushes multi-arch (amd64 + arm64) + declares `packages: write` permission | 2 |

### test/unit/multi_distro_build_worker_yaml_spec.bats (16)

Structural assertions for `.github/workflows/multi-distro-build-worker.yaml`
(#325 B-1 dispatcher, extended to N-D matrix-mode via #344 in v0.32.0).
The dispatcher fans a per-event `include`-shape matrix across
`build-worker.yaml` matrix shards so multi-distro / multi-variant
caller `main.yaml`s (`env/ros_distro`, `env/ros2_distro`,
`app/ros1_bridge`) stop copy-pasting a
`${{ github.event_name == 'pull_request' && ... || ... }}`
expression. Three jobs:

1. **`resolve-matrix`** — pure-shell selector emitting a `matrix`
   JSON-array output (`include`-shape, each entry has `name` +
   `build_args` plus arbitrary additional fields). `pull_request` ->
   `pr_matrix` (subset); anything else (tag push, main push,
   `workflow_dispatch`) -> `tag_matrix` (release validation matrix).

2. **`call-build`** — strategy.matrix job invoking the local
   `build-worker.yaml` per matrix cell. Derives per-shard
   `image_name` as `<image_name>-<matrix.name>`, forwards
   `matrix.build_args` verbatim as `build_args`, and shards buildx
   GHA cache by name via `cache_variant: ${{ matrix.name }}`
   (reuses #272's per-variant scope contract). `fail-fast: false`
   so one shard's failure doesn't cancel siblings.

3. **`ci-passed`** — rollup gate for branch protection. Matches the
   existing `ci-passed` rollup naming used by env/ros_distro /
   env/ros2_distro per CLAUDE.md's status-check table, so
   downstream branch-protection contexts don't change on adoption.

**BREAKING since v0.32.0 (#344)**: legacy 1D inputs `pr_distros` /
`tag_distros` / `distro_input_name` / `extra_build_args` were removed;
the 14 v0.29-era tests covering those inputs are replaced by 16 tests
covering the new matrix-mode shape (incl. a negative assertion that
the 1D inputs are gone).

| Category | Tests |
|----------|-------|
| Declares `workflow_call` | 1 |
| Required inputs: `pr_matrix`, `tag_matrix`, `image_name` | 1 |
| Legacy 1D inputs gone (no `pr_distros` / `tag_distros` / `distro_input_name` / `extra_build_args`) | 1 |
| `pr_matrix` description documents required `name` + `build_args` fields | 1 |
| `tag_matrix` description documents required `name` + `build_args` fields | 1 |
| Passthrough inputs mirror build-worker (build_runtime / test_tools_version / platforms / context_path / dockerfile_path / build_contexts) | 1 |
| `resolve-matrix` emits `matrix` output (include-shape) | 1 |
| `resolve-matrix` branches on `github.event_name == 'pull_request'` | 1 |
| `call-build` `uses: ./.github/workflows/build-worker.yaml` | 1 |
| `call-build` matrix `include: fromJSON(needs.resolve-matrix.outputs.matrix)` | 1 |
| `call-build` per-shard `image_name: <image_name>-<matrix.name>` (hyphen) | 1 |
| `call-build` forwards `build_args: ${{ matrix.build_args }}` verbatim | 1 |
| `call-build` `cache_variant: ${{ matrix.name }}` (per-cell cache scope) | 1 |
| `call-build` `fail-fast: false` | 1 |
| `ci-passed` rollup depends on `call-build`, runs with `if: always()` | 1 |
| `ci-passed` declares `name: ci-passed` to satisfy branch protection contract | 1 |

### test/unit/build_sh_spec.bats (51)

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
positional `TARGET`, **`-t` / `--target TARGET` alias** (#280: short +
long form, last-wins resolution against positional `[TARGET]` in both
orderings, `-t` value-required guard, usage help mention), `--lang`
argument validation, fallback `_detect_lang` branches (zh_TW/zh_CN/ja),
real (non-dry-run) docker build invocation, **runtime log-line i18n**
(bootstrap / drift-regen / err_no_env messages translate in all four
languages via the local `_msg()` table; English remains the default),
and **`-C` / `--chdir` flag** (docker_harness#53: pre-pass overrides
FILE_PATH to redirect the wrapper to a different repo, both short and
long form, value-required and directory-existence guards, usage help
mention), and **`-v` / `--verbose` / `-vv` / `--very-verbose` flag**
(#311: exports `BUILDKIT_PROGRESS=plain` so a hung `docker build`'s RUN
step output is visible; `-vv` adds `set -x` on the wrapper itself;
usage help mentions all four spellings).

### test/unit/build_sh_prune_spec.bats (7)

Unit tests for `build.sh`'s #387 post-build prune-predecessor logic.
Separate spec so the docker stub can be tailored to image-inspect /
images-filter / rmi semantics without bloating the default
build_sh_spec stub (which only logs argv). Smart docker stub branches
on `image inspect` (returns `DOCKER_INSPECT_PRE_ID` on the first call,
`DOCKER_INSPECT_POST_ID` on the second — defaults to PRE_ID for the
cache-hit case), `images --filter reference=<id>` (emits the
`<none>:<none>` self-entry plus `DOCKER_IMAGES_OUTPUT` lines so the
multi-tag-still-references case can be simulated), and `rmi` (appends
the id to `DOCKER_RMI_LOG` so tests assert presence/absence).

Covers: first-build path (`docker image inspect` exits 1 → no
`_pre_build_id` → prune skipped, no rmi), cache-hit rebuild
(`pre == post` → cache-hit guard returns early), successful displaced
rebuild (`pre != post`, old id has no other tag → `docker rmi
<old-id>` fires), multi-tag guard (old id still referenced elsewhere
→ "skip prune: predecessor still tagged" log + no rmi), `--no-prune`
opt-out (no inspect calls + no rmi even when ids would have moved),
`--dry-run` (planned-action line `[dry-run] docker rmi <old-id-of ...
if displaced>` visible + zero real rmi), and `--help` mentions the
`--no-prune` flag.

### test/unit/run_sh_spec.bats (65)

Unit tests for `run.sh`. Mirrors the build_sh_spec.bats harness;
`docker ps` reads from a controllable stub file so tests can simulate
"container already running" scenarios.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path,
bootstrap staying non-interactive (setup.sh, not TUI), defensive guard
when setup produces no `.env`, `--detach`, devel vs non-devel TARGET
routing, `--instance`, already-running guard, Wayland xhost path,
`--lang` / `--instance` argument validation, fallback `_detect_lang`
branches, **runtime log-line i18n** (bootstrap + already-running
error translate in all four languages via the local `_msg()` table),
**#216/#429 auto-build gate** (image present → silent + no build,
image absent → auto-delegates to `./build.sh TARGET`, non-devel target
forwarded, build failure aborts run, per-target image inspect, `--build`
invokes `./build.sh test` before compose up, `--build` after
check-drift), and **`-C` / `--chdir`
flag** (docker_harness#53: redirect FILE_PATH, short + long form,
value-required and directory guards, usage help mention), and **`-v`
/ `--verbose` / `-vv` / `--very-verbose` flag** (#311: same export +
trace pattern as build.sh, parity across wrappers), and **#386
foreground exit auto compose-down** (default-on for devel + one-shot
non-devel targets, `--no-rm` opts out, `-d` suppresses the trap; the
trap fires `down --remove-orphans` to mirror stop.sh and close the
worktree-removed-before-stop network leak), and **#448 `--` CMD
separator** (`--` stops flag parsing so CMD flags like `--target`
don't collide; positional CMD also stops parsing; usage documents
`--`).

### test/unit/exec_sh_spec.bats (53)

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
routing when container is running, **`--` flag/CMD separator** (#289:
standalone `--` consumed before CMD flows through to `docker compose
exec`, lets a dash-leading CMD pass through, works after `-t TARGET`
for run.sh parity, no-`--` positional path stays backward-compatible,
`-h` usage mentions `--`), fallback `_detect_lang` branches when
`template/` is absent, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come
from the alt repo, short + long form, value-required and directory
guards, usage help mention), **`-v` / `--verbose` / `-vv` /
`--very-verbose` flag** (#311: symmetry-only for exec since
`docker exec` itself does not build, but flag is accepted and `-vv`
enables wrapper trace), and **`-T` / `--no-tty` + `-i` / `--tty`
TTY-mode flags + auto-detect of `bash|sh|dash|zsh|ash|ksh -c '...'`**
(#382 Option 1+2: 17 assertions covering the no-CMD default (TTY),
interactive binary default (TTY), 4 shell flavours with `-c` auto-add
`-T`, `bash hello.sh` (no `-c`) keeps TTY, explicit `-T`/`--no-tty`
forces no-TTY, explicit `-i`/`--tty` overrides heuristic, last-wins
precedence between `-T` and `-i` in both orders, `-T` + `-t TARGET`
attaches to the right service, `-T` + `--` separator round-trip,
`--help` mentions both flag pairs).

### test/unit/stop_sh_spec.bats (34)

Unit tests for `stop.sh` argument parsing, the `--all` multi-instance
teardown, and i18n. `docker ps -a` output is PATH-shimmed via
`${DOCKER_PS_A_FILE}` so tests can seed the project list for the `--all`
branch.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--instance` value
validation, default teardown via `docker compose down`, named-instance
suffix in project name, `--all` no-instances English message,
Chinese / Simplified Chinese / Japanese translations of the
no-instances message, `--all` multi-project teardown loop, fallback
`_detect_lang` branches, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come
from the alt repo, short + long form, value-required and directory
guards, usage help mention), and **`-v` / `--verbose` / `-vv` /
`--very-verbose` flag** (#311: parity across wrappers; flag is a no-op
for `docker compose down` but `-vv` still enables wrapper trace), and
**`--prune` flag** (#319: opt-in lightweight cleanup after compose
down — `docker network prune --filter until=10m` + `docker image prune
--filter until=24h`; works alongside `--all` even when no instances
found; usage help mentions `--prune` with the two grace windows; the
plain `stop.sh --dry-run` path emits no `docker prune` commands).

### test/unit/prune_sh_spec.bats (36)

Unit tests for the new `script/docker/prune.sh` wrapper (#319) — atomic
docker garbage cleanup with conservative per-target `--filter until=`
defaults (network=10m, image=24h, builder=24h, volume=no filter). Sandbox
+ PATH-shimmed `docker` stub mirrors the build/run/exec/stop spec
strategy; `docker compose` is never invoked here so no `.env` seeding is
required beyond the sandbox layout.

Covers: `--help` (en/zh-TW/zh-CN/ja), no-target exit-2 hint (English +
zh-TW), `--until` / `--lang` value-required guards, unknown-flag
exit-2, individual `--networks` / `--images` / `--builder` /
`--volumes` dry-run output (each with its own default grace; volume
output omits `--filter`), **`--all` aggregator** (network + image +
builder; volumes intentionally excluded), **`--until <dur>` override**
across all selected targets, **volume confirmation prompt** (`n`
aborts with exit-1 + i18n "aborted" message; `-y` skips the prompt;
zh-TW prompt body asserts), `-C` / `--chdir` parity (accepted but
no-op for daemon-wide prune; value-required + directory guards),
usage help mentions every flag family, and **#388 `--worktree-orphans`
mode** (13 cases): per-test smart docker stub keyed on
`DOCKER_IMAGES_OUTPUT` / `DOCKER_RMI_LOG` mocks `docker images` + `rmi`;
fixtures construct real `<workspace>/worktree/<name>/` dirs so the
existence check has something to consult. Cases cover empty-list
no-op, owner-match + missing worktree → rmi, owner-match + worktree
alive → keep, main-checkout pattern (no hyphen) → keep, **two safety
gates**: bare-name image → skip ("Skipping N bare-name image" log),
other-owner image → skip ("Skipping N image(s) owned by another user"
log). Plus `--repo` filter, `--dry-run` plan-only output, `-y` skip
prompt, missing `--workspace` + empty `.env` → exit 2, `--workspace`
flag wins over `.env` `WS_PATH`, `--owner` flag wins over `.env`
`DOCKER_HUB_USER`, and `--help` mentions all four new flags.

Regression guard for **issue #282** — the four user-facing wrappers
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) must resolve `_lib.sh`
through the post-#263 `.base/` subtree prefix on a fresh clone of any
downstream repo. Pre-fix the wrappers hard-coded `template/` and a
freshly cloned downstream repo (where the subtree now lives under
`.base/`) failed at the `_lib.sh` source step with "cannot find _lib.sh".

Covers: `--help` succeeds for each wrapper when `.base/script/docker/_lib.sh`
exists alongside the wrapper symlink; the documented "cannot find _lib.sh"
error path still fires (with the new `.base/...` path in the diagnostic)
when neither `.base/` nor the sibling fallback is present.

### test/unit/justfile_user_spec.bats (7)

Executable tests for the user-facing `script/docker/justfile` (#546 /
ADR-00000005: `just` replaces the retired GNU make wrapper). Parity with
the removed `makefile_user_spec`: sandboxes a repo with the justfile
symlinked at root + stub `script/*.sh` recorders, and RUNS `just <verb>`
to assert 1:1 forwarding with `{{args}}` passthrough. Skips when `just`
is not yet in the test-tools image (pre-release GHCR pull -- see
template_spec for the `apk add ... just` guard + the release smoke check).

| Test | Description |
|------|-------------|
| `just build forwards positional args` | `just build test` -> build.sh test |
| `just build passes flags through verbatim` | no `--` separator needed |
| `just exec passes = -bearing Kit-style args` | no EXEC_ARGS shim (#469) |
| `just run / stop / prune / setup forward` | wrapper dispatch |
| `just setup-tui forwards to setup_tui.sh` | hyphenated recipe |
| `just upgrade forwards to .base/upgrade.sh` | upgrade dispatch |
| `bare just lists recipes` | replaces `make help` |

### test/unit/justfile_spec.bats (4)

Static content checks for the user-facing `script/docker/justfile`
(ADR-00000005, #545): `just` replaces the GNU make wrapper, with recipes
forwarding 1:1 to `./script/<name>.sh` via `{{args}}` passthrough (no
`MAKEOVERRIDES` / `--` / `EXEC_ARGS` workarounds). Asserted by grep, not
execution -- `just` is not in the test-tools image; downstream installs it.

| Test | Description |
|------|-------------|
| `justfile exists` | file present |
| `declares args-passthrough recipes for every wrapper verb` | build/run/exec/stop/prune/setup/setup-tui/upgrade `*args` |
| `recipes forward to ./script/<wrapper>.sh with {{args}}` | forwarding bodies |
| `default recipe lists recipes (replaces make help)` | `default: @just --list` |

### test/unit/compose_gen_spec.bats (85)

Covers `generate_compose_yaml` conditional output: AUTO-GENERATED
header, baseline workspace volume, network/ipc/privileged env-var
references, conditional pid emission (only for `host`; omitted for
`private` since Docker rejects the literal), `test` service presence,
image name threading, and conditional GPU deploy block + GUI
env/volumes + extra volumes from `[volumes]` section.

| Test | Description |
|------|-------------|
| `outputs AUTO-GENERATED header` | Header check |
| `always emits workspace volume` | Baseline |
| `emits network_mode/ipc/privileged via env var` | env-var baked |
| `omits pid when default private` | pid omit |
| `emits pid env-var ref when host` | pid host |
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
| `environment env_N expands ${VAR} cross-reference to earlier sibling (refs #236)` | basic cross-ref |
| `environment env_N forward reference is left literal (refs #236)` | order-sensitive |
| `environment env_N unknown ${VAR} is left literal (refs #236)` | unknown stays literal |
| `environment env_N supports multiple cross-references in one value (refs #236)` | multi-ref |
| `environment env_N transitive cross-reference resolves through chain (refs #236)` | transitive |
| `_resolve_docker_flags: no overrides => inherits all parent values (#505)` | inherit baseline |
| `_resolve_docker_flags: gui.mode=off overrides parent gui=true (#505)` | gui force-off |
| `_resolve_docker_flags: gui.mode=force overrides parent gui=false (#505)` | gui force-on |
| `_resolve_docker_flags: deploy.gpu_mode=off overrides parent gpu=true (#505)` | gpu force-off |
| `_resolve_docker_flags: deploy.gpu_count + gpu_capabilities overrides win (#505)` | gpu scalars |
| `_resolve_docker_flags: deploy.gpu_runtime override wins (#505/#481)` | runtime override |
| `_resolve_docker_flags: legacy deploy.runtime alias used when gpu_runtime absent (#505/#481)` | runtime legacy alias |
| `_resolve_docker_flags: legacy deploy.runtime overrides gpu_runtime at per-stage scope (resolved last, #505/#481)` | runtime per-stage precedence |
| `_resolve_docker_flags: network scalars + privileged override (#505)` | net + privileged |
| `_resolve_docker_flags: list fields append to top by default (#505)` | list append |
| `_resolve_docker_flags: list *_inherit=false switches to replace mode (#505)` | list replace |
| `generate_compose_yaml per-stage emit is byte-identical via _resolve_docker_flags (#505 golden master)` | byte-identical golden |
| `_resolve_docker_flags: security cap_add / cap_drop / security_opt append to top by default (#526)` | per-stage caps append |
| `generate_compose_yaml per-stage security.cap_add_inherit=false clears inherited caps for that stage only (#526)` | per-stage caps clear |
| `generate_compose_yaml per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append emit |

### test/unit/deploy_spec.bats (47)

Covers the S6 (#506) deploy-generator primitive `_emit_docker_run_flags`:
the pure mapping from a resolved docker-flag record to a `docker run`
argv fragment for the self-contained `deploy.sh` field launcher. Asserts
each flag mapping plus the conditional gates that mirror the compose
emit (shm only when ipc != host, ports only under bridge, gpu `all` vs
`count=N,capabilities`, device propagation -> `-v`, runtime off/auto
skipped, ipc `private` skipped) and the deliberate omissions
(`[environment]` baked, gui dev-only).

| Test | Description |
|------|-------------|
| `privileged=true emits --privileged` | privileged |
| `gpu count=0 emits --gpus all` | gpu all |
| `gpu count>0 emits count+capabilities spec` | gpu partition |
| `gpu=false emits no --gpus` | gpu off |
| `runtime=nvidia emits --runtime=nvidia` | runtime on |
| `runtime off/auto/empty emits no --runtime` | runtime skip |
| `net host emits --network=host` | net host |
| `net bridge + name emits --network=<name>` | net named bridge |
| `net bridge without name emits no --network` | default bridge |
| `ipc host emits --ipc=host; private is skipped` | ipc gate |
| `pid host emits --pid=host` | pid host |
| `shm_size emitted only when ipc != host` | shm gate |
| `restart emitted only when set and != no` | restart gate |
| `volumes each emit -v` | volumes |
| `ports emit -p only under bridge` | ports gate |
| `plain device -> --device, propagation device -> -v` | device split |
| `caps + security_opt map to docker run flags` | caps/secopt |
| `dri_groups (space-sep) each map to --group-add` | group-add |
| `cgroup_rules map to --device-cgroup-rule` | cgroup rules |
| `environment and gui are NOT mapped (baked / dev-only)` | omissions |
| `empty record emits nothing` | empty no-op |
| `_resolve_deploy_context: resolves scalars + list strings from setup.conf` | full resolution |
| `_resolve_deploy_context: applies effective defaults for a minimal repo conf` | template-merged defaults |
| `_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode` | legacy alias |
| `_resolve_deploy_context: dri_groups auto detects host GIDs via SETUP_DETECT_DRI_GROUPS` | dri auto |
| `_resolve_deploy_context: dri_groups off yields empty` | dri off |
| `_generate_deploy_sh: writes an executable launcher with the expected skeleton` | launcher skeleton |
| `_generate_deploy_sh: inlines global [security] privileged + caps + devices` | global security/devices |
| `_generate_deploy_sh: gpu force inlines --gpus count + capabilities + runtime` | gpu inline |
| `_generate_deploy_sh: network host inlines --network=host` | network inline |
| `_generate_deploy_sh: omits -e (env baked) and -v (no dev binds)` | env/volume omission |
| `_generate_deploy_sh: [lifecycle] restart inlines --restart` | restart inline |
| `_generate_deploy_sh: per-stage [stage:runtime] override is applied` | per-stage override |
| `_generate_deploy_sh: per-stage security.cap_add_inherit=false clears inherited caps (#526)` | per-stage caps clear |
| `_generate_deploy_sh: per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append |
| `_generate_deploy_sh: generated launcher is ShellCheck-clean` | shellcheck-clean output |
| `_bake_config_copy: splices COPY config/app into the target stage` | config COPY bake |
| `_bake_config_copy: handles src == out in place` | in-place bake |
| `_generate_deploy_bundle: dry-run plans build --target + save + tar.xz` | bundle plan |
| `_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set` | env-bake build |
| `_generate_deploy_bundle: dry-run builds from the plain Dockerfile when no runtime bake applies` | plain build |
| `_setup_deploy: --dry-run previews the launcher + prints the build plan` | deploy dry-run |
| `_setup_deploy: refuses in a non-interactive shell without -y` | non-tty refuse |
| `_setup_deploy: errors when the repo has no Dockerfile` | no-Dockerfile guard |
| `_setup_deploy: rejects an unknown flag` | arg validation |
| `_setup_deploy: --stage selects the target stage` | stage select |
| `main deploy routes to _setup_deploy` | dispatch wiring |

### test/unit/compose_logging_spec.bats (32)

Covers `[logging]` + `[logging.<svc>]` support in
`generate_compose_yaml` (#310). Tests the global emission on every
service (devel / test / auto-emitted stage), back-compat for repos
not yet declaring `[logging]`, per-service override key-level merge
behaviour, and the two new setup.sh helpers `_parse_logging_svc_sections`
+ `_collect_logging`.

| Test | Description |
|------|-------------|
| `omits logging: block when both inputs empty (back-compat)` | Empty inputs no-op |
| `emits logging: block on devel from global [logging]` | Global → devel |
| `test service inherits global logging via extends:devel (#493)` | Global logging emitted once on devel; test inherits via extends |
| `driver-only [logging] omits options: block` | No rotation keys |
| `partial options emits only set keys` | Sparse override |
| `per-svc [logging.<svc>] overrides global key on that svc` | Override semantics |
| `per-svc [logging.<svc>] inherits keys absent in override` | Key-level merge |
| `_parse_logging_svc_sections enumerates services in file order` | Parser order |
| `_parse_logging_svc_sections ignores plain [logging] section` | Section discrimination |
| `_parse_logging_svc_sections returns empty when file does not exist` | Missing-file guard |
| `_collect_logging reads global [logging] from per-repo setup.conf` | Per-repo source |
| `_collect_logging reads per-service [logging.<svc>] sections` | Per-svc source |
| `_collect_logging returns empty when no [logging] sections anywhere` | Total absence |
| `local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)` | Mount + env on devel |
| `local_path empty omits mount + env (back-compat) (#328)` | Empty fallback |
| `local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)` | Per-service emit |
| `local_path absolute path is passed through verbatim (#328)` | Absolute path |
| `local_path is NOT emitted as a logging.options key (driver-only options) (#328)` | local_path NOT a docker option |
| `local_path on test service emits standalone volumes block + env (#328)` | test service |
| `_sync_logging_local_paths_gitignore appends relative local_path to .gitignore (#328)` | gitignore append |
| `_sync_logging_local_paths_gitignore skips absolute paths (#328)` | Absolute skip |
| `_sync_logging_local_paths_gitignore skips ~ paths (#328)` | Tilde skip |
| `_sync_logging_local_paths_gitignore is idempotent (#328)` | Re-run no-op |
| `_sync_logging_local_paths_gitignore collects from both global + per-svc (#328)` | Multi-source |
| `_sync_logging_local_paths_gitignore is no-op when no local_path keys (#328)` | Empty no-op |
| `_sync_logging_local_paths_gitignore prunes stale managed entries on value change (#390)` | Rename prune |
| `_sync_logging_local_paths_gitignore drops marker + entries when candidates become empty (#390)` | Feature-off cleanup |
| `_sync_logging_local_paths_gitignore preserves user entries outside managed block (#390)` | User-owned untouched |
| `setup.conf [logging] comment block references in-image helper path (/usr/local/lib/base/, #368)` | Documented adoption path matches in-image COPY |
| `generate_compose_yaml emits per-stage LOG_FILE_PATH on extends:devel stage when [logging] local_path is set (#367)` | Per-svc LOG_FILE_PATH on auto-emitted extends-only stage |
| `generate_compose_yaml emits per-stage volume mount on extends:devel stage when [logging] local_path is set (#367)` | Per-svc volume mount on auto-emitted extends-only stage |
| `generate_compose_yaml does NOT emit LOG_FILE_PATH on extends:devel stage when [logging] local_path is unset (#367 back-compat)` | Zero-diff back-compat when feature unset |

### test/unit/entrypoint_logging_spec.bats (6)

Behaviour of `script/docker/_entrypoint_logging.sh` — the helper
downstream repos source from their `script/entrypoint.sh` so
container stdout/stderr is tee'd to the host bind-mounted log file
when `[logging] local_path` is set (#328). Tests source the helper
under controlled `LOG_FILE_PATH` env in subshells and assert both
the host file content and the inherited stdout (preserving
`docker logs` parity).

| Test | Description |
|------|-------------|
| `entrypoint_logging is no-op when LOG_FILE_PATH unset (#328)` | Back-compat: do nothing |
| `entrypoint_logging tees stdout to LOG_FILE_PATH when set (#328)` | Happy path |
| `entrypoint_logging truncates LOG_FILE_PATH on each run (#328)` | Fresh container = fresh log |
| `entrypoint_logging creates parent dir if missing (#328)` | mkdir -p safety net |
| `entrypoint_logging warns + continues when target is a directory (#328)` | Failure-mode fallback |
| `entrypoint_logging captures stderr along with stdout (#328)` | 2>&1 redirect |

### test/unit/template_spec.bats (143)

| Test | Description |
|------|-------------|
| `build.sh exists and is executable` | File check |
| `run.sh exists and is executable` | File check |
| `exec.sh exists and is executable` | File check |
| `stop.sh exists and is executable` | File check |
| `setup.sh exists and is executable` | File check |
| `ci.sh exists and is executable` | File check |
| `ci.sh uses set -euo pipefail` | Shell convention |
| `Makefile.ci exists (template CI)` | File check |
| `Makefile.ci has test target` | Makefile target |
| `Makefile.ci has lint target` | Makefile target |
| `Makefile.ci has upgrade target` | Makefile target |
| `Makefile.ci upgrade target forwards optional VERSION variable` | VERSION arg passthrough |
| `Makefile.ci upgrade-check tolerates upgrade.sh exit 1 (update available)` | Regression #175: wrap on Makefile.ci |
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
| `.version file exists in template root` | Version file check |
| `upgrade.sh reads version from template/.version` | .version path |
| `upgrade.sh does not reference legacy VERSION or .template_version` | Legacy refs purged |
| `upgrade.sh runs init.sh after subtree pull` | Sync symlinks |
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
| `Dockerfile.example copies _entrypoint_logging.sh to /usr/local/lib/base/ in devel stage (#368)` | In-image helper COPY + devel-stage placement |
| `Dockerfile.example commented runtime stage shows _entrypoint_logging.sh COPY example (#368)` | Runtime opt-in scaffold |
| `_entrypoint_logging.sh header documents in-image source-line (no $USER, no work/.base) (#368)` | Helper Usage docstring positive + negative regression guards |

### test/unit/bashrc_spec.bats (10)

| Test | Description |
|------|-------------|
| `defines alias_func` | Function definition |
| `defines color_git_branch` | Function definition |
| `defines ebc alias` | Alias definition |
| `defines sbc alias` | Alias definition |
| `alias_func is called` | Function call |
| `color_git_branch is called` | Function call |
| `color_git_branch sets PS1` | PS1 setting |

### test/unit/ci_spec.bats (25)

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
| `main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1` | #523 single-file dispatch |
| `main --bats-path: accepts a directory` | #523 directory path |
| `main --bats-path: non-existent path dies with ci_bats_path_not_found` | #523 missing-path guard |
| `main --bats-path: test/behavioural/ path dies with a clear hint` | #523 behavioural guard |
| `main --bats-path + --coverage is rejected (ci_bats_path_coverage)` | #523 coverage-combo guard |
| `main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE` | #523 filter-only dispatch |
| `_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f` | #523 single-path runner |
| `_run_bats_path: filter-only runs bats across unit + integration` | #523 filter-only runner |

### test/unit/lint_mixed_test_layout_spec.bats (8)

Covers `script/ci/lint_mixed_test_layout.sh` (#495 / ADR-00000004): the
WARNING-only lint that flags a `test/<category>/` directory mixing test
runner families (`.bats` + `test_*.py`) at one level and suggests the
`test/<category>/<tool>/` subdir split. Asserts the warn / silent cases,
that non-test files are ignored, the non-blocking exit 0, the
non-directory exit 2, and the `_runner_family` classifier.

| Test | Description |
|------|-------------|
| `warns when a category mixes bats and python at one level` | mixed -> WARN |
| `silent for a single-tool (bats-only) category` | bats-only silent |
| `silent for a single-tool (python-only) category` | python-only silent |
| `warns only for the mixed category among several` | per-category scoping |
| `non-test files do not trigger a warning` | helper / docs ignored |
| `is non-blocking: exits 0 even when it warns` | advisory exit 0 |
| `exits 2 when given a non-directory root` | usage error |
| `_runner_family classifies bats / python / other` | classifier unit |

### test/unit/init_spec.bats (29)

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
| `_detect_template_version: reads .version file when present (no network)` | .version file priority |
| `_detect_template_version: .version file takes priority over git ls-remote` | Local-first resolution |
| `_create_new_repo: main.yaml uses given ref in workflow @ref` | Ref threading |
| `_create_new_repo: main.yaml falls back to @main when ref arg omitted` | Default ref |
| `_create_new_repo: main.yaml falls back to @main when ref arg is empty` | Empty-string → `@main` |
| `_create_new_repo: does NOT generate .env.example (image name via setup.conf)` | setup.conf rules drive IMAGE_NAME |
| `_create_symlinks: places 7 wrapper symlinks under script/ (#330)` | 7 wrappers under script/ with ../ targets; justfile at root, no Makefile |
| `_create_symlinks: places justfile at root with the direct .base/ target (#545)` | root justfile -> .base/script/docker/justfile |
| `_create_symlinks: does NOT symlink Makefile and cleans a stale root Makefile symlink (#546)` | Makefile retired; stale symlink dropped on upgrade |
| `_create_symlinks: replaces a stale file at the new symlink path under script/ (#330)` | Re-init over stale file at script/build.sh |
| `_create_symlinks: removes stale root *.sh symlinks left by pre-#330 init (#330 migration loop)` | Migration: plant 7 root symlinks, re-run, all gone + script/ created |
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

### test/unit/upgrade_spec.bats (38)

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
for rollback), the R1+ rewrite of `_verify_subtree_intact` (#477)
that replaces the hard-coded marker list with a path-agnostic
structural invariant + target-version match (catches destructive
fast-forward, empty subtree, malformed `.version`, and wrong-tag
pulls), and the SemVer §11-aware `_semver_cmp` + `_check`
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
| `_verify_subtree_intact succeeds when subtree dir + version match target (#477 happy path)` | R1+ happy path |
| `_verify_subtree_intact rolls back when template/.version is missing` | Destructive-FF rollback |
| `_verify_subtree_intact rolls back when template/ dir is missing (#477 destructive-FF detector)` | R1+ dir-missing rollback |
| `_verify_subtree_intact rolls back when template/ dir is empty (#477)` | R1+ empty-dir rollback |
| `_verify_subtree_intact rolls back when .version content is not semver (#477)` | R1+ semver-shape guard |
| `_verify_subtree_intact rolls back when .version does not match target (#477 wrong-tag detector)` | R1+ wrong-tag detector |
| `upgrade.sh calls _require_git_identity before subtree pull` | Pre-flight ordering |
| `upgrade.sh calls _verify_subtree_intact after subtree pull with target version (#477)` | Post-flight ordering + R1+ caller integration |
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

### test/integration/init_new_repo_spec.bats (42)

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
| `new repo: .env.example is NOT generated (image name via setup.conf rules)` | setup.conf rules drive IMAGE_NAME |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)` | default in-image helper source line + comment present; ${USER} / /home/ absent (regression guards) |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: main.yaml grants permissions: contents: write` | #62 release perms |
| `new repo: .gitignore exists` | gitignore |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink lives under script/, not root (#330)` | symlink target moved to script/build.sh |
| `new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)` | symlink set: 7 wrappers + justfile root, no Makefile |
| `new repo: config/ is an empty placeholder (template#254 layered override)` | config placeholder |
| `new repo: init.sh preserves pre-existing config/ directory (no clobber)` | config preservation |
| `new repo: init.sh drops stale config symlink before creating placeholder` | config-symlink drop |
| `Dockerfile.example references CONFIG_SRC="config" (not .base/config)` | CONFIG_SRC default |
| `Dockerfile.example has layered config COPY chain (template#254)` | layered COPY order |
| `Dockerfile.example declares ENV HOME before WORKDIR ${HOME}/work (#334)` | HOME env directive |
| `Dockerfile.example sets up bashrc.d drop-in directory (template#254)` | bashrc.d setup |
| `new repo: Dockerfile contains _entrypoint_logging.sh in-image COPY (#368)` | End-to-end check on init.sh-generated repo |
| `new repo: .base/.version exists (no legacy VERSION / .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)` | setup_tui under script/ |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)` | upgrade cleanup |
| `new repo: init.sh removes stale root *.sh symlinks (#330 migration)` | migrate 7 root symlinks to script/ |
| `new repo: build.sh -h works against the generated symlink` | smoke script/build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke script/run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke script/exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke script/stop.sh |
| `new repo: setup.sh symlink under script/ → ../.base/script/docker/setup.sh` | setup.sh under script/ |
| `new repo: setup.sh -h works against the generated symlink` | smoke script/setup.sh |
| `init.sh --gen-conf copies setup.conf to repo root` | setup.conf gen |
| `init.sh --gen-conf refuses to overwrite existing setup.conf` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: compose.yaml ships devices: /dev:/dev by default` | default device mount |
| `new repo: setup.conf mount_1 is NOT empty after first init` | workspace writeback non-empty |
| `new repo: per-repo setup.conf auto-created on first init (workspace writeback)` | #201 — bootstrap writes WS_PATH back |

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

### test/integration/wrapper_compose_dispatch_spec.bats (6)

Behavioural assertion (#490) that every wrapper routes its `docker compose`
calls through the `-p`-injecting dispatcher. Reuses the
`fresh_clone_portability_spec.bats` fixture pattern (cp `/source` -> `.base/`,
symlink the wrappers from the repo root, materialize `.env` + `compose.yaml`
via `build.sh --dry-run`), then runs each wrapper with `--dry-run` and
inspects the planned `[dry-run] docker compose -p <project> <verb>` line.
Immune to internal renames (replaces the old name-coupled `_compose_project` /
`_app_cleanup` greps in `template_spec.bats`) and catches a raw-`docker
compose` bypass (a missing `-p`). **Level 1** (no Docker invocation).

| Test | Description |
|------|-------------|
| `build.sh --dry-run dispatches compose build with -p project flag` | build dispatch |
| `run.sh --dry-run (default devel) dispatches compose up + exec with -p` | run devel up+exec |
| `exec.sh --dry-run dispatches compose exec with -p` | exec dispatch |
| `stop.sh --dry-run dispatches compose down with -p` | stop dispatch |
| `run.sh foreground --dry-run installs cleanup that downs with --remove-orphans` | EXIT-trap cleanup |
| `no wrapper dispatches compose without -p (bypass regression)` | bypass catcher |

### test/integration/upgrade_spec.bats (16)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags
on a minimal subtree layout) attached to a sandbox downstream repo.
**Level 1** (no Docker). Exercises the happy path, the pre-flight
guards, the destructive-FF rollback path added after the Jetson v0.9.7
incident (stubs `git-subtree pull` via `GIT_EXEC_PATH` to simulate the
bug and asserts the repo is restored), and the post-#284 Dockerfile
lint-stage auto-patch that heals downstream Dockerfiles missing the
`COPY .base/script/docker/lib /lint/lib` line (#348).

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps template/.version, pulls new content, updates main.yaml` | Happy path |
| `upgrade.sh patches Dockerfile lint stage when missing COPY .base/script/docker/lib /lint/lib (#348)` | Auto-heal post-#284 lib drift on first upgrade |
| `upgrade.sh is idempotent on Dockerfile already containing the lib COPY line (#348)` | Already-patched Dockerfile is unchanged on re-run |
| `upgrade.sh warns + skips Dockerfile patch when stock shellcheck anchor is missing (#348)` | Custom Dockerfile shape opts out of auto-heal |
| `upgrade.sh continues cleanly when no Dockerfile at repo root (#348)` | Subtree-only repos (no consumer Dockerfile) skip silently |
| `upgrade.sh patches Dockerfile COPY *.sh /lint/ → script/*.sh /lint/ (#399)` | Auto-patch stale root COPY post-#330 |
| `upgrade.sh is idempotent when Dockerfile already has COPY script/*.sh /lint/ (#399)` | Already-patched COPY skipped |
| `upgrade.sh skips #399 patch when Dockerfile has no COPY *.sh /lint/ line` | No stale line to patch |
| `upgrade.sh patches stale COPY *.sh /lint/ even when COPY script/*.sh /lint/script/ exists (#403)` | Regression: /lint/script/ must not false-positive |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `just upgrade-check (downstream justfile): exit 0 when update available (#175, #546)` | Regression #175: recipe wraps exit 1 (skips w/o just) |
| `just upgrade-check (downstream justfile): exit 0 when up-to-date (#546)` | Up-to-date path stays green (skips w/o just) |
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

## Behavioural Tests (opt-in)

Specs that drive `docker buildx build --target runtime-test` against
synthesized fixtures so the runtime smoke gate in `Dockerfile.example`
is genuinely exercised end-to-end — not just static-grep asserted
in `template_spec.bats`. Issue #249.

Excluded from the `1080` self-test total because they require host
docker access (mounted via the `ci-behavioural` compose service)
which the default `ci` service does NOT provide. Run with `make
-f Makefile.ci test-behavioural` locally, or via the dedicated
`Behavioural Test` job in `self-test.yaml` on CI. Each test
invokes one `docker buildx build` (~5-15s amd64, ~30-60s arm64
QEMU); the dedicated `template-behavioural` buildx builder
(created/pruned per ci.sh run) isolates the cache from the host's
default context.

### test/behavioural/runtime_test_smoke_spec.bats (5)

| Test | Description |
|------|-------------|
| `runtime-test build succeeds with default smoke command` | Baseline `whoami && bash --version` ARG default works |
| `runtime-test build succeeds with && chain override (#243 word-split regression)` | Wrapper preserves shell operators |
| `runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)` | `${var:offset:length}` works (would fail under `sh -c`) |
| `runtime-test build succeeds with bash [[ test operator override (#249)` | `[[` works (sister bash-only regression guard) |
| `runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)` | Negative case: the gate actually gates |

## Smoke Tests

Shared specs that ship with `template/test/smoke/` and run at Dockerfile
`test`-stage build time (i.e. during `./build.sh test`) inside both this
repo and every downstream repo that consumes the template. They assert
the integrity of the generated `compose.yaml` + the wrapper scripts'
`-h` / `--help` paths. **Not** part of the 935-test self-test count
(those run via `make -f Makefile.ci test` and never enter the build
graph).

How they reach downstream repos: each `Dockerfile`'s `test` stage does

```dockerfile
COPY template/test/smoke/ /smoke_test/
COPY test/smoke/ /smoke_test/
RUN bats /smoke_test/
```

so the shared specs and any per-repo `test/smoke/` overlay execute
together. `display_env.bats` self-skips on headless repos by detecting
the absence of GUI lines in the generated `compose.yaml`.

### test/smoke/script_help.bats (27)

Locks the `-h` / `--help` invariants on the four wrapper scripts
(`build.sh` / `run.sh` / `exec.sh` / `stop.sh`) plus the `_LANG`
auto-detection rules in `build.sh` (`LANG=zh_TW.UTF-8` → zh, `ja_JP`
→ ja, `en_US` → en, `SETUP_LANG` overrides `LANG`) plus #222
`--help` / `--lang` order independence (pre-pass scans for `--lang`
before main parse so `<script> --help --lang zh-TW` produces zh-TW
usage, not English).

| Test | Description |
|------|-------------|
| `build.sh -h exits 0` | Wrapper smoke |
| `build.sh --help exits 0` | Long flag |
| `build.sh -h prints usage` | Output sanity |
| `build.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `run.sh -h exits 0` | Wrapper smoke |
| `run.sh --help exits 0` | Long flag |
| `run.sh -h prints usage` | Output sanity |
| `run.sh -h describes auto-apply default (no stale 'warn on drift', #365)` | Help text describes auto-apply, not stale warn-on-drift |
| `exec.sh -h exits 0` | Wrapper smoke |
| `exec.sh --help exits 0` | Long flag |
| `exec.sh -h prints usage` | Output sanity |
| `stop.sh -h exits 0` | Wrapper smoke |
| `stop.sh --help exits 0` | Long flag |
| `stop.sh -h prints usage` | Output sanity |
| `build.sh detects zh from LANG=zh_TW.UTF-8` | i18n detect — zh-TW |
| `build.sh detects ja from LANG=ja_JP.UTF-8` | i18n detect — ja |
| `build.sh defaults to en for LANG=en_US.UTF-8` | i18n detect — en default |
| `build.sh SETUP_LANG overrides LANG` | i18n env override |

### test/smoke/display_env.bats (11)

Asserts the generated `compose.yaml` carries the X11 / Wayland env
+ volume block expected by GUI containers, and that `run.sh` runs the
right `xhost` command per session type. Auto-skipped when the repo's
`compose.yaml` has no GUI block (headless repos like `multi_run`).

| Test | Description |
|------|-------------|
| `compose.yaml contains WAYLAND_DISPLAY env` | Wayland env line |
| `compose.yaml contains XDG_RUNTIME_DIR env` | Wayland session dir env |
| `compose.yaml contains XAUTHORITY env` | X11 auth env |
| `compose.yaml mounts XDG_RUNTIME_DIR as rw` | Wayland socket mount |
| `compose.yaml mounts XAUTHORITY volume` | X11 auth mount |
| `compose.yaml has no consecutive duplicate keys` | YAML hygiene |
| `compose.yaml mounts X11-unix volume` | X11 socket mount |
| `run.sh contains XDG_SESSION_TYPE check` | Session-type branch |
| `run.sh calls xhost +SI:localuser on wayland` | Wayland xhost path |
| `run.sh calls xhost +local: on X11` | X11 xhost path |
| `run.sh defaults to X11 xhost when XDG_SESSION_TYPE unset` | Fallback path |

### test/smoke/test_helper.bash

Not a spec — runtime helper (`assert_compose_has` / `skip_if_headless`
etc.) loaded by every smoke spec via `load "${BATS_TEST_DIRNAME}/test_helper"`.
Asserts in this file are exercised via `test/unit/smoke_helper_spec.bats`
(which IS in the 935 self-test count).
