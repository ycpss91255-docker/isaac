# Unit Tests

Unit specs under `test/bats/unit/`: **2765 tests**.

> Part of the `just test` self-test suite — what runs in the `Self Test`
> CI job. See [TEST.md](TEST.md) for the index across all test types and
> the self-test grand total.

## How this catalogue is maintained

**The catalogue is exhaustive, and it is generated.** Every spec file has a
`### <path> (N)` section, and every section that carries a
`| Test | Description |` table carries **one row per `@test`** — never a
selection. Both are produced by `script/test/sync-doc-counts.sh`
(`just test sync-docs`) and validated by its read-only twin
`script/test/check_test_md_drift.sh` (`just test sync-docs-check`), so an
incomplete catalogue is drift and fails the gate. Before the rows were
generated they were hand-written next to a generated count, and they rotted
silently: `deploy_spec.bats` carried 36 rows for 43 tests with both gates
reporting "in sync".

What that means when you edit:

- **Descriptions are yours.** A row is keyed on the test name exactly as bats
  reports it, so prose you write survives regeneration. A test with no
  description shows `-`; filling one in is welcome and never required.
- **Do not hand-add or hand-delete rows or sections.** Add the `@test`, run
  `just test sync-docs`, then write the description. Deleting a test removes
  its row on the next run.
- **Renaming a test loses its description** (a rename is indistinguishable
  from delete-plus-add). To carry the prose across, rename the row here in the
  same commit, then regenerate.
- **Rows follow spec file order**, so the table reads the way the spec reads.
- A section may summarise instead, with a `| Category | Tests |` table or plain
  prose, for specs where a per-test row each is noise. That is an explicit
  editorial choice for that section, not a licence for a per-test table to be
  partial.
- A generated section lands at the end of the file; move it into its thematic
  group freely — every pass keys on the heading, not the position.

## Test Files

### test/bats/unit/lib_spec.bats (54)

| Test | Description |
|------|-------------|
| `_resolve_lang sets 'en' when LANG is unset (#568)` | Default language |
| `_resolve_lang sets 'zh-TW' for zh_TW.UTF-8 (#568)` | Traditional Chinese |
| `_resolve_lang sets 'zh-CN' for zh_CN.UTF-8 (#568)` | Simplified Chinese |
| `_resolve_lang sets 'zh-CN' for zh_SG (Singapore) (#568)` | Singapore variant |
| `_resolve_lang sets 'ja' for ja_JP.UTF-8 (#568)` | Japanese |
| `_resolve_lang honors SETUP_LANG override (#568)` | Env override |
| `_lib.sh does NOT set _LANG at source time (#568 Part B)` | Load-time side-effect removed |
| `conf_logging.sh self-sources its conf.sh dependency in isolation (#568)` | Self-sourcing (load order not load-bearing) |
| `_lib.sh is idempotent when sourced twice` | Double-source guard |
| `_load_env exports variables from a .env file` | Env loader works |
| `_load_env errors when no path is given` | Required arg check |
| `_load_env round-trips shell-hostile values verbatim (no exec, no split) (#689)` | %q-quoted hostile value loads literally (no command-sub / word-split) |
| `_load_env aborts under set -euo pipefail when the file does not exist (#689)` | Missing-file error path (no `[[ -f ]]` guard) |
| `_compute_project_name produces clean PROJECT_NAME (single-instance #600)` | Project name (single-instance) |
| `_compute_project_name honours the PROJECT_NAME resolved into .env.generated (#893)` | - |
| `_compose_project passes the resolved PROJECT_NAME to -p (#893)` | - |
| `_resolve_project_name: a configured name is used verbatim (#893)` | - |
| `_resolve_project_name: empty configured name derives the historical default (#893)` | - |
| `_resolve_project_name: falls back to local + directory basename with nothing to go on (#893)` | - |
| `_compute_project_name warns when .env.generated carries no PROJECT_NAME (#893)` | - |
| `_compose with DRY_RUN=true prints command instead of running` | DRY_RUN path |
| `_compose without DRY_RUN tries to invoke docker compose (sanity)` | Real-call branch |
| `_compose_project pre-fills -p / -f / --env-file from PROJECT_NAME and FILE_PATH` | Project wrapper |
| `_compose_project omits --env-file when .env.generated is absent (self-managed repo)` | - |
| `_sanitize_lang accepts en / zh-TW / zh-CN / ja unchanged` | Lang validator pass-through |
| `_sanitize_lang warns and falls back to 'en' for unsupported values (English default)` | Unknown lang fallback |
| `_sanitize_lang warns for the old bare 'zh' code (post zh→zh-TW rename)` | Legacy lang rejection |
| `_sanitize_lang warning is localized to system LANG (zh-TW)` | - |
| `_sanitize_lang warning is localized to system LANG (zh-CN)` | - |
| `_sanitize_lang warning is localized to system LANG (ja)` | - |
| `_dump_conf_section extracts keys from the named section` | INI section dump |
| `_dump_conf_section stops at the next section header` | Section boundary |
| `_dump_conf_section returns silent empty for missing file` | Missing file |
| `_dump_conf_section returns silent empty for unknown section` | Missing section |
| `_dump_conf_section hides keys with empty values (using default)` | - |
| `_print_config_summary prints files, identity, all populated sections, resolved` | Full config dump |
| `_print_config_summary names an active .setup.conf.local and its sections (#893)` | - |
| `_print_config_summary says nothing about a .setup.conf.local that is absent (#893)` | - |
| `_print_config_summary prints Variables block mapping setup.conf placeholders to detected values` | Variables block populated |
| `_print_config_summary Variables block falls back to '-' for unset values` | Variables fallback |
| `_print_config_summary hides sections that are empty in setup.conf` | Empty-section skip |
| `_print_config_summary warns when setup.conf is missing` | Missing-conf hint |
| `_print_config_summary wraps dividers + section headers in ANSI when FORCE_COLOR=1 (#309)` | Color migration via _log_plain |
| `_print_config_summary omits ANSI when NO_COLOR=1 overrides FORCE_COLOR=1 (#309)` | NO_COLOR precedence on summary |
| `_print_config_summary warns when setup.conf exists but has no [section] headers` | #157 empty-conf hint on build/run summary |
| `_lib_msg returns English by default` | - |
| `_lib_msg returns zh-TW translations` | - |
| `_lib_msg returns zh-CN translations` | - |
| `_lib_msg returns ja translations` | - |
| `_lib_msg returns count / caps across all languages` | - |
| `_lib_msg falls back to English for unknown _LANG value` | - |
| `_print_config_summary uses zh-TW labels when _LANG=zh-TW` | - |
| `_print_config_summary uses ja labels when _LANG=ja` | - |
| `_print_config_summary conf_missing hint is translated (zh-TW)` | - |

### test/bats/unit/log_spec.bats (69)

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
| Startup TTY cache `_LOG_IS_TTY` (#605): helper defined + cached-0/cached-nonzero/unset-fallback; auto-format honours cache + unset-identity; explicit `LOG_FORMAT` bypasses cache; `_log_color_enabled` cache read + NO_COLOR/FORCE_COLOR precedence over cache | 12 |
| JSON escaping (`_log_json_escape`, #691): quote / lone-backslash double / newline+tab+CR / substitution order; live `_log_info` attr value with quote+backslash+tab stays well-formed | 5 |
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

### test/bats/unit/transcript_spec.bats (33)

Wrapper transcript capture (#606) + interactive orchestration capture
(#608): tees a verb's combined output to `log/<verb>/<ts>-<traceid8>.log`
(ANSI stripped) with a per-verb `latest.log` symlink, an
exit-code+duration closing line, retention, and an `_atexit` registry
that owns the single EXIT trap. Interactive verbs (run / exec / setup_tui)
capture the orchestration phase then `_transcript_detach` before the
session. Pure helpers are unit-tested; the tee + EXIT-finalize + detach
are exercised end-to-end by running a tiny harness in a subshell.
Activation is execution-only (`_transcript_begin` in each verb's
`main()`), never at source time.

| Category | Tests |
|----------|-------|
| `_transcript_is_full_verb`: 5 captured verbs / interactive + unknown not | 2 |
| `_transcript_is_interactive_verb` + `_transcript_is_capture_verb` classification (#608) | 2 |
| `_transcript_filename` path shape; `_transcript_meta_line` lnav-parseable format | 2 |
| `_transcript_resolve_traceid`: inherits TRACEPARENT trace_id / generates 32-hex | 2 |
| `_transcript_enabled`: default true / `wrapper_transcript=false` kill switch; `WRAPPER_TRANSCRIPT` env override wins over conf both ways (#622) | 4 |
| `_atexit`: registered callbacks run LIFO on exit | 1 |
| `_transcript_prune`: keep-N-most-recent + drop-older-than-D-days | 2 |
| `_transcript_prune` keep=0 wipes all + read-side guard rejects hand-edited `wrapper_transcript_keep=0` (falls back to 20) (#691) | 2 |
| Degrade-to-no-op failure branches (#691): mkdir-fail / raw-file-unwritable / tee-missing each WARN + return 0, wrapper continues | 3 |
| Non-zero wrapper exit recorded (`transcript_complete exit_code=7`) AND propagated to caller (#691) | 1 |
| End-to-end: file produced with combined content; ANSI stripped in file (colour on terminal); exit-code+duration line; `latest.log` symlink; `wrapper_transcript=false` no-op | 5 |
| `_transcript_detach` (#608): no-detach full-captures (run -d path); detach captures orchestration only (`transcript_detached`, not the session); no-op when never begun | 3 |
| Wiring guards: 5 full verbs call `_transcript_begin`; run/exec/setup_tui call begin + detach | 2 |

### test/bats/unit/transcript_lnav_spec.bats (8)

Regex-type lnav format for the plain-text wrapper transcript
(`transcript.lnav-format.json`, #609): parses `<ISO ts> [service] LEVEL:
msg` lines, coexisting with the JSON `log.lnav-format.json` (`*.jsonl`).
The CI image has no jq/lnav, so it is checked structurally (grep) +
functionally (the embedded regex, extracted and JSON-unescaped, must
match real transcript lines and the 5 levels via `grep -P`).

| Category | Tests |
|----------|-------|
| Declares the lnav schema + format key; is a regex format (not json) | 2 |
| Maps all 5 levels; timestamp/level/body fields + `log/` file-pattern wired | 2 |
| Regex matches real transcript lines incl. all 5 levels; raw docker line does NOT match | 2 |
| Every declared sample matches the pattern | 1 |
| `log.lnav-format.json` (JSON) still coexists unchanged | 1 |

### test/bats/unit/schema_spec.bats (30)

Covers the setup.conf validation registry (`lib/schema.sh`, #560): the
single `_schema_validate <section> <key> <value>` gate that both
setup.sh (`set` / `add`) and the TUI route through. Verifies registry
dispatch (scalar exact-match + numbered-list prefix normalisation),
per-service `[logging.<svc>]` section normalisation, the empty-value
policy (default allow / clear; `deploy.gpu_count` rejects empty), and
the full union of validated keys -- including the keys that were
historically free-form in setup.sh (`build.network` / `build.arg_` /
`deploy.gpu_runtime` + `runtime` alias / `network.network_name` /
`devices.device_` / `security.cap_add_` / `cap_drop_`). Phase 2 (#561)
adds the section-list single source: `SCHEMA_SECTIONS` (ordered list),
`_schema_is_section` (membership), `_schema_section_keys` (a section's
registered keys derived from `SCHEMA_VALIDATOR`).

| Test | Description |
|------|-------------|
| `_schema_validate routes network.port_N to _validate_port_mapping (accept)` | - |
| `_schema_validate routes network.port_N to _validate_port_mapping (reject)` | - |
| `_schema_validate routes deploy.gpu_count to _validate_gpu_count (accept)` | - |
| `_schema_validate routes deploy.gpu_count to _validate_gpu_count (reject)` | - |
| `_schema_validate rejects empty deploy.gpu_count (empty policy = validate)` | empty exception |
| `_schema_validate routes logging.driver to _validate_log_driver (accept)` | - |
| `_schema_validate routes logging.driver to _validate_log_driver (reject)` | - |
| `_schema_validate allows empty logging.driver (empty policy = allow)` | empty default |
| `_schema_validate normalises logging.<svc> to the logging key set (reject)` | - |
| `_schema_validate normalises logging.<svc> to the logging key set (accept)` | - |
| `_schema_validate accepts every registered key's valid sample` | union coverage (accept) |
| `_schema_validate rejects every registered key's invalid sample` | union coverage (reject) |
| `_schema_validate rejects embedded-newline values (YAML injection) (#687)` | - |
| `_schema_validate numeric validators are shape-only, not range-bound (#687)` | - |
| `_schema_validate allows empty (clear) for every list + clearable scalar key` | clear-key semantics |
| `_schema_validate accepts free-form (unregistered) keys` | default-accept |
| `SCHEMA_SECTIONS lists every setup.conf section in file order (#561)` | ordered section list (#561) |
| `_schema_is_section accepts a registered section with typed keys (#561)` | membership accept (#561) |
| `_schema_is_section accepts a free-form-only section (image) (#561)` | membership accept, no keys (#561) |
| `_schema_is_section rejects an unknown section (#561)` | membership reject (#561) |
| `_schema_is_section rejects a per-service logging variant (#561)` | logging.<svc> not a base section (#561) |
| `_schema_is_section tracks SCHEMA_SECTIONS additions (single source) (#561)` | single source (#561) |
| `_schema_section_keys returns scalar+list keys for build (#561)` | keys by prefix (#561) |
| `_schema_section_keys returns all logging keys (#561, #606)` | keys by prefix (#561) |
| `_schema_section_keys returns deploy keys incl. legacy alias (#561)` | keys incl. runtime alias (#561) |
| `_schema_section_keys returns the rule_ list key for image (#561, #876)` | - |
| `_schema_validate gates gui.mode the way the --gui flag does (#876)` | - |
| `_schema_validate gates the [deploy] keys the resolver reads (#876)` | - |
| `_schema_validate gates the [security] keys the resolver reads (#876)` | - |
| `_schema_validate gates image.rule_N against the dispatch prefixes (#876)` | - |

### test/bats/unit/schema_coverage_spec.bats (11)

Registry drift guards (#562, schema epic #559 phase 3): the registry
must stay internally consistent and in sync with the `setup.conf`
template, so drift fails CI. The deferred i18n coverage now lands via the
`SCHEMA_I18N` index column (#591): every registered key maps to a TUI
message key (or an explicit `""` opt-out for keys with no editor), and
every mapped key is present in all four locale tables (en / zh-TW /
zh-CN / ja) -- a missing translation in any locale fails CI.

| Test | Description |
|------|-------------|
| `every SCHEMA_VALIDATOR validator name resolves to a defined function (#562)` | no ghost validators (#562) |
| `SCHEMA_SECTIONS matches the setup.conf template headers in file order (#562)` | registry/template drift (#562) |
| `every SCHEMA_EMPTY key is a registered SCHEMA_VALIDATOR key (#562)` | no dead empty-policy entries (#562) |
| `every registered key is reachable via SCHEMA_SECTIONS (#562)` | no key stranded under an unlisted section (#562) |
| `every SCHEMA_VALIDATOR key has a SCHEMA_I18N index entry (#591)` | i18n-index is complete (#591) |
| `every SCHEMA_I18N key is a registered SCHEMA_VALIDATOR key (#591)` | no orphan index rows (#591) |
| `every SCHEMA_I18N message key exists in all four locale tables (#591)` | no missing translation in any locale (#591) |
| `_schema_i18n_key resolves scalar + list keys, falls back when free-form (#591)` | accessor the TUI routes through (#591) |
| `every shipped setup.conf key is registered or an explicit free-form opt-out (#876)` | - |
| `every SCHEMA_FREEFORM entry carries a written reason (#876)` | - |
| `no key is both SCHEMA_VALIDATOR-registered and SCHEMA_FREEFORM-opted-out (#876)` | - |

### setup.sh-derived unit specs (386, mirroring source libs)

The setup.sh decomposition (ADR-00000014) split one god-source into
subsystem libs; these specs mirror those libs per ADR-00000015 (test
files mirror source — one lib maps to one `<name>_spec.bats`, a lib with
multiple sub-unit specs gets a `<name>/` folder, source is never split
for tests). They share one `setup_spec_helper.bash` (common `setup()` /
`teardown()`); behaviour and total test count are unchanged across the
re-split. P1a (refs #758) relocated the compose / stage / setup_cmd
specs; P1b (closes #758) split the remaining `setup_spec.bats` /
`setup_emit_spec.bats` god-files into one spec per leaf lib (`resolve` /
`drift` / `setup_detect` / `setup_conf` / `env_emit`), slimming
`setup_spec.bats` to the orchestrator (`main` dispatch, `usage`,
`_setup_msg`, the `apply` pipeline integration tests) and retiring
`setup_emit_spec.bats`. P1b also returned the remaining isolated unit
tests to their owning lib's spec: the `_parse_ini_section` /
`_ini_tokenize` INI-parser tests to `conf_accessor_spec.bats`
(`lib/conf.sh`), `_setup_known_section` to `setup_cmd_spec.bats`
(`lib/setup_cmd.sh`), and the `_setup_ssh_x11_cookie` helper tests to
`setup_detect_spec.bats` (`lib/setup_detect.sh`).

#### test/bats/unit/setup_spec.bats (114)

The `setup.sh` orchestrator spec. `main` subcommand dispatch (`set` /
`show` / `remove` for `[logging]` #328 and `[lifecycle]` #478, `reset`,
`--lang` / error paths), `usage`, `_setup_msg` / `_msg` i18n, and the
`apply` pipeline integration tests that drive detect → resolve →
write_env → compose emit end-to-end: template-shipped defaults and
emitted blocks for
`[lifecycle]` restart (#478), `[deploy]` `dri_groups` (#496) and
`gpu_runtime` alias (#481), `[additional_contexts]` (#199), `[build]`
`arg_N` / `target_arch` / `network`, `[security]` opt-in (#466),
`config/app/` bind (#504), `.env.generated` cache + `.env` overlay
(#502), workspace writeback (#174/#201), `--gui` / `--no-x11-cookie` /
`--print-resolved` flags (#338), `--quiet` confirmation lines (#285),
#450 propagation + duplicate-target guards, and S7 `runtime.env`
retirement (#507).

#### test/bats/unit/resolve_spec.bats (25)

Mirrors `lib/resolve.sh`. The host-detection resolvers in isolation:
`_resolve_gpu` / `_resolve_gui` (auto / force / off), `_resolve_runtime`
and `_resolve_build_network` over `_detect_jetson`, the documented
`SETUP_DETECT_JETSON` / `SETUP_DETECT_DRI_GROUPS` operator-override
contract (#760) for `_detect_jetson` / `_detect_dri_groups`, and
`_compute_conf_hash`.

#### test/bats/unit/drift_spec.bats (4)

Mirrors `lib/drift.sh`. `_check_setup_drift` no-op / silent / non-zero
paths when the conf hash or GPU detection changes against a cached
`.env`.

#### test/bats/unit/setup_detect_spec.bats (50)

Mirrors `lib/setup_detect.sh`. Isolated host-detection units:
`detect_user_info`, `detect_hardware`, `detect_docker_hub_user`,
`detect_gpu` / `detect_gpu_count` (incl. the nameref regression),
`detect_gui`, `_is_ssh_x11` (#321), the SSH X11 cookie rewrite
(`_setup_ssh_x11_cookie`, #321/#688), the `detect_image_name` rule engine
+ sanitization, `detect_ws_path`, and `_reconcile_workspace_path`
(#569).

#### test/bats/unit/setup_conf_spec.bats (30)

Mirrors `lib/setup_conf.sh`. setup.conf merging (`_load_setup_conf`
replace strategy) resolving the per-repo override from the repo-root
`.setup.conf` dotfile (a legacy `config/docker/setup.conf` is no longer
read), `_get_conf_value` / `_get_conf_list_sorted` (incl. empty-skip),
and the `_rule_basename` image-rule helper. Also guards the shipped
`dist/` prose against pre-relocation path names: the four `setup_tui.sh`
usage heredocs must advertise `.setup.conf`, and no shipped text may
still say `<repo>/setup.conf` or `.base/setup.conf` (#842).

#### test/bats/unit/env_emit_spec.bats (4)

Mirrors `lib/env_emit.sh`. `write_env` (.env contents + SETUP_*
metadata, SSH X11 `XAUTHORITY` override #321) and `_scaffold_env_overlay`
idempotency.

#### test/bats/unit/setup_cmd_spec.bats (120)

Mirrors `lib/setup_cmd.sh`. The git-style subcommand dispatcher and its
mutating verbs (#49): dispatch (Phase B-1), `set` / `show` / `list`
(Phase B-2), `add` / `remove` (Phase B-3), and `reset` + BREAKING no-arg
→ help (Phase B-4) — round-trips, validators, no-`.env`-regen, comment
preservation, and end-to-end subprocess cases. Also the per-section
setup.conf parameter end-to-end coverage (#202, merged from the former
`setup_section_validate_spec.bats`) exercising `_setup_validate_kv` /
`_setup_known_section`: one key per test asserted through to
`compose.yaml` / `.env`, across `[deploy]`, `[gui]`, `[network]`,
`[resources]`, `[environment]`, `[tmpfs]`, `[devices]`, `[volumes]
mount_2..N`, and `[security]` privileged, with companion negatives for
cleared keys, plus the isolated `_setup_known_section` /
`SCHEMA_SECTIONS` (#561) unit checks.

#### test/bats/unit/stage_spec.bats (103)

Mirrors `lib/stage.sh`. The per-stage engine: `_validate_stage_name`
(#215), `_parse_dockerfile_stages`, `_compute_dockerfile_hash`, `main
apply` auto-emit of non-baseline stages (#215), per-stage overrides #220
(`_parse_stage_sections` / `_load_stage_overrides` /
`_validate_stage_override_key` / `_resolve_stage_scalar` /
`_resolve_stage_list` + compose-emit integration, incl. #493
`devel-test` override surface), the `_resolve_docker_flags` single
per-stage flag-resolution layer (#505/#526, relocated from the compose
spec in P1a), `_generate_runtime_dockerfile` ENV-bake (#503/#688,
relocated from setup_emit in P1a), and `_is_deployable_stage`, the
ADR-00000023 sec.4 stage-eligibility predicate
(`deployable = not devel and not *-test`, widened in #841 to the whole
template-managed baseline incl. the `sys` / `devel-base` build
intermediates) that both the deploy-scoped `[lifecycle] restart`
emission and the `setup deploy` stage guard gate on. Also carries the
#875 AGREEMENT spec for `_dockerfile_stage_from_line`, the one shared
"which line declares stage `<S>`" matcher: instead of testing each
reader against its own regex — the shape that let three regexes drift
apart until a `FROM --platform=... AS <stage>` line was a stage to one
call site and invisible to the others — it drives every call site off a
single FROM line and asserts one verdict per site.

### test/bats/unit/tui_spec.bats (135)

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

### test/bats/unit/tui_backend_spec.bats (31)

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

### test/bats/unit/tui_mount_assembler_spec.bats (9)

Unit tests for the TUI mount-string assembler (`_assemble_mount_value` /
`_prompt_mount_with_picker`, #461): host:container[:mode] composition,
combined access/propagation modes, `_validate_mount` round-trip, and
space-bearing path rejection (#687).

| Test | Description |
|------|-------------|
| `_assemble_mount_value returns host:container when no mode (#461)` | Bare two-field mount |
| `_assemble_mount_value returns host:container:mode for single mode (#461)` | Single-mode suffix |
| `_assemble_mount_value accepts combined access,propagation (#461)` | Combined mode |
| `_assemble_mount_value output validates via _validate_mount (#461)` | Round-trip validation |
| `_assemble_mount_value empty mode means no suffix (#461)` | Empty-mode no suffix |
| `_assemble_mount_value space-bearing path is rejected by _validate_mount (#687)` | Space-path rejection |
| `_prompt_mount_with_picker assembles full mount string from picker steps (#461)` | Full picker assembly |
| `_prompt_mount_with_picker no propagation gives just host:container:access (#461)` | Access-only picker |
| `_prompt_mount_with_picker no access + no propagation gives just host:container (#461)` | Bare picker |

### test/bats/unit/tui_flow_spec.bats (106)

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
| #561 `_tui_known_subcommand` derives CLI direct-jump subcommands from `SCHEMA_SECTIONS` (accepts every section + `ports` pseudo-section, rejects unknown args, tracks `SCHEMA_SECTIONS` additions) | 4 |

### test/bats/unit/build_worker_yaml_spec.bats (50)

Structural assertions for `.github/workflows/build-worker.yaml` (#195
+ #243 + #272 + #273 + #378 b1). Reusable workflows are not exec'd by
these tests; instead grep patterns lock the YAML invariants —
`context_path` / `dockerfile_path` inputs declared with the right
defaults, all 4 `docker/build-push-action` steps (devel-test / devel /
runtime-test / runtime after #243) forwarding those inputs, no
leftover `context: .` / `file: ./Dockerfile` literals, the GHA-cache
plumbing (#272: `cache_variant` input, `Compute cache scope` step;
#378 b1: per-target scope suffix so a late-stage COPY change in one
target no longer cascades into siblings' manifests; #801:
`cache_backend` input selecting the gha default or a GHCR registry
backend via a per-step ternary, a guarded `docker/login-action` step),
and the #273
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
| #272 + #378 b1 GHA buildx cache: `cache_variant` input declared with empty default, `Compute cache scope` step emits `id: cache` + base key (no `-cache` suffix; per-target suffix appended at use site), 4 build steps use per-target `<base>-<target>-cache` gha scopes in the default ternary branch, no legacy shared-scope leftover (negative regression), 4 build steps preserve `mode=max` on both branches, default preserves zero-diff for single-call callers | 6 |
| #801 registry cache backend: `cache_backend` input declared `type: string` default `"gha"` (default preserves the gha backend for existing callers), all 4 build steps emit a `type=registry,ref=ghcr.io/<repo>/buildcache:<scope>` ref in the registry branch, cache-from/cache-to select the backend on `inputs.cache_backend` (8 lines), the `extra_stages` buildx loop honors `cache_backend` too (shell-side selection, no hardwired gha ref), GHCR `docker/login-action` step gated on `cache_backend == 'registry'` | 6 |
| #273 doc-only PR fast-pass (Phase 1 + Phase 2 shell rewrite): `path-filter` job declared, classifier is pure shell (`git diff --name-only base...head` + `case` glob; no `dorny/paths-filter` dependency), reads EVENT_NAME / BASE_SHA / HEAD_SHA from env: keys so the case body stays portable, non-PR event short-circuits before git diff (BASE_SHA / HEAD_SHA empty on push / tag / workflow_dispatch), 6-path allowlist (`**/*.md`, `doc/**`, `LICENSE`, `.gitignore`, `.github/CODEOWNERS`, `.github/dependabot.yml`) in a single `case` arm, `compute-matrix` + `build` jobs gated on `code_changed == 'true'` (2 occurrences), `docker-build` aggregator handles `code_changed == 'false'` short-circuit + `needs: [path-filter, build]`, non-PR triggers always set `code_changed=true` | 8 |
| #470 opt-in `free_disk_space` for large BASE_IMAGE repos: input declared `type: boolean` default `false`, step gated on `inputs.free_disk_space`, uses `jlumbroso/free-disk-space@...`, positioned before `Set up Docker Buildx` so the overlayfs snapshot dir has room | 4 |
| #802 push worker logic down: `compute-matrix` delegates to `compute_matrix.sh` (no inline platform fan-out) and version-matches it via `job_workflow_sha` into `.worker-base`, `Compute cache scope` delegates to `cache_scope.sh` (feeds IMAGE_NAME / CACHE_VARIANT / HARDWARE, no inline derivation), build job checks out base worker source into `.worker-base` | 4 |

### test/bats/unit/build_worker_compute_matrix_spec.bats (8)

Unit tests for `script/ci/build_worker/compute_matrix.sh`, the platform ->
build matrix resolver extracted out of build-worker.yaml's inline
`compute-matrix` step (#802). Pushes the "a matrix condition that produces
no jobs" semantic break down the pyramid (System-level worker logic -> Unit
level, ADR-00000018): each supported platform maps to the right native
runner + HARDWARE (`linux/amd64` -> ubuntu-latest / x86_64, `linux/arm64` ->
ubuntu-24.04-arm / aarch64), whitespace + empty comma segments are
tolerated, an unsupported platform fails with a naming plain-language error,
and an empty / all-empty list fails the no-jobs guard instead of fanning out
to zero build jobs.

### test/bats/unit/build_worker_cache_scope_spec.bats (4)

Unit tests for `script/ci/build_worker/cache_scope.sh`, the buildx
cache-scope base-key resolver extracted out of build-worker.yaml's inline
`Compute cache scope` step (#802). Locks the
`${image_name}[-${cache_variant}]-${hardware}` shape (with its #272 / #378
bug history): the optional `cache_variant` segment single-call callers omit,
the per-arch hardware suffix, and the distro-in-image_name case that needs no
variant.

### test/bats/unit/ci_preflight_spec.bats (18)

Unit tests for `script/ci/preflight.sh`, the caller-contract validator
the reusable build / release workers run before any real work. Drives
the pure-shell engine over synthetic requirement manifests: a present
required input passes; an empty required input, or an ungranted / unset
permission probe, fails non-zero with a plain-language message naming
the gap and the `main.yaml` fix; every unmet requirement is reported in
one pass (not fail-on-first); `--list` self-describes the manifest;
comment / blank manifest lines are ignored. Malformed-manifest guards
keep the never-silent thesis honest: an unknown requirement kind (a
typo'd `kind` column) fails loudly naming the offending kind, and a
missing / empty / all-comment (zero-requirement) manifest is a config
error (exit 2) rather than a silent green. Conditional requirements
(#801): an optional 6th manifest field `<condvar>=<value>` gates a
requirement on another env var (e.g. `packages: write` only when
`cache_backend: registry`) -- a guard that does not match is
declared-but-skipped (never a failure), a matching guard enforces the
requirement without leaking the guard into the hint, and `--list`
annotates it as `(when <condvar>=<value>)`. A malformed guard field
lacking `=` fails loud as a config error (exit 2), never failing open.

### test/bats/unit/worker_preflight_yaml_spec.bats (12)

Structural assertions that `build-worker.yaml` and `release-worker.yaml`
wire in the caller-contract preflight: a `preflight` job that the real
build / release job gates on (its `needs:` list includes it), fetching
the validator + manifest from base at the worker's own ref
(`github.job_workflow_sha`, so the validator can never drift from the
worker it guards), then calling `preflight.sh` with the per-worker
manifest and the real inputs exported into the env vars the manifest
names (plus a GHCR-login probe feeding the packages-permission check on
the build side). #801 adds the build side's `cache_backend` export into
the manifest guard env and a REAL packages: write probe (a GHCR
blob-upload scope check, not a bare login) for the registry backend.

### test/bats/unit/self_test_yaml_spec.bats (101)

Structural assertions for `.github/workflows/self-test.yaml`. Locks
thirteen cumulative invariants:

1. **#305 actionlint gate** — `actionlint` job declared, runs
   `rhysd/actionlint` via Docker pinned to an explicit version
   (`x.y.z`); downstream jobs (`test`, `integration-e2e`,
   `system`) need it so the workflow-validator class of
   regression that wedged v0.26.0-rc1 (refs #297) is caught early.

2. **#317 P1 classifier + buildx GHA cache** — a `classify` job
   emits `code_changed` + `system_relevant` outputs from PR
   diff against the doc-only allow-list (`doc/**` + `README.md` +
   `LICENSE`) and system block-list (entrypoint.sh + compose
   + Dockerfile.example/.test-tools + wrappers + init/upgrade +
   `test/bats/system/**` + `.github/workflows/**`); the `test` job
   always runs (required check) but short-circuits to SUCCESS on
   doc-only PRs; `integration-e2e` and `system` gate via
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
   downstream jobs (`test`, `integration-e2e`, `system`)
   precedes its test-tools provisioning with an `Obtain` step
   implementing the 3-layer fallback: PR touched
   `dockerfile/Dockerfile.test-tools` -> rebuild local; else
   `docker pull ghcr.io/ycpss91255-docker/test-tools:main` and
   re-tag; else fall back to a from-source rebuild. For `test` +
   `system` (which `docker compose run` test-tools), the
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

5. **#317 P3 system conditional + block-list expansion** —
   `system` job's job-level `if:` tightens from
   `code_changed == 'true'` (P1) to `system_relevant ==
   'true'` (the narrower output P1 already emitted but didn't
   consume). PRs that change pure lint / unit-test paths
   covered by `test` now skip the docker.sock-mounted compose
   run, saving ~3-5 min per such PR. The system block-list
   in `classify` is extended with `script/docker/setup.sh` +
   `script/docker/i18n.sh` + `script/docker/lib/**` +
   `script/docker/prune.sh` (gotcha-5): each affects `.env` /
   `compose.yaml` generation or wrapper behaviour that the
   compose service exercises end-to-end, so they must invalidate
   the system-skip optimization.

6. **#337 `ci-rollup` aggregator** — a single always-running
   (`if: always()`) `ci-rollup` job sits downstream of every PR
   check and collapses their results into one pass/fail signal that
   branch protection can require. The verifier shell step consumes
   every `${{ needs.<job>.result }}` and applies a 2-tier rule:
   `actionlint` / `classify` must be `success`;
   conditionally-gated jobs (`shellcheck` / `hadolint` / `bats-unit` /
   `bats-integration` / `coverage` / `integration-e2e` / `system`)
   may be `success` or `skipped` (their job-level `if:` legitimately
   skips on doc-only / non-system PRs per #317 P1/P3, #376, #377,
   #615). Adding sub-jobs (#377)
   to the rollup's `needs:` list becomes a workflow-internal
   change with no branch-protection update required.

7. **#376 ShellCheck + Hadolint dedicated jobs** — `shellcheck` runs
   on plain ubuntu-latest with the pre-installed binary (no buildx,
   no test-tools image, ~30s feedback on a regression) via
   `test.sh --shellcheck-only`. `hadolint` uses
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
     each shard runs a round-robin partition of `test/bats/unit/*_spec.bats`
     via `test.sh --bats-unit-shard ${{ matrix.shard }}`. Parallel
     execution drops PR wall-time from ~5min to ~2min.
   - `bats-integration`: runs `test/bats/integration/` via
     `test.sh --bats-integration`. Pulled out of the unit serial path
     so each unit shard sees only its share.
   - `coverage`: #377 gated it to main pushes only and kept it out of
     `ci-rollup`'s `needs:` (a non-gating metric). **Superseded by #615
     (invariant 11): coverage is now a sharded kcov PR gate in the
     rollup.** The #377-era posture (main-only `if:`, "NOT in ci-rollup
     needs") is no longer asserted here.

9. **#579 integration-e2e runnability gate** — the e2e job drives
   build / run / exec / stop through the documented `just` entry points
   (not raw `script/*.sh`, so a broken container-ops justfile is
   caught) and ASSERTS the runnability contract instead of only running
   the steps: the in-container user equals the configured `USER_NAME`
   (catches the v0.41.0 user-args `initial` bug), the detached container
   is still running (catches the entrypoint `set -u` insta-exit class),
   the wired ENTRYPOINT is `/entrypoint.sh`, the `~/work` mount is
   present and writable, and `just stop` removes both the container and
   the compose project network. `just` is installed via the
   `extractions/setup-just` action.

   `ci-rollup needs:` is `[actionlint, classify, shellcheck,
   hadolint, bats-unit, bats-integration, coverage, integration-e2e,
   system]` (9 jobs post-#615) — every PR-check job. `release needs:`
   updates from `[shellcheck, hadolint, test, integration-e2e,
   system]` → `[shellcheck, hadolint, bats-unit, bats-integration,
   integration-e2e, system]`. Post-#377 only `actionlint` +
   `classify` are hard-mandatory in `ci-rollup`'s verifier (the
   always-running `test` job no longer exists).

10. **#603 native arm64 e2e matrix** — `integration-e2e` runs as a
    static 2-entry `strategy.matrix` (`linux/amd64` -> `ubuntu-latest`,
    `linux/arm64` -> `ubuntu-24.04-arm`) with `fail-fast: false`, so the
    #579 runnability contract is verified on both arches via native
    runners (no QEMU), mirroring the platform->runner convention of
    build-worker / publish-worker / release-test-tools (#587). The job
    `runs-on: ${{ matrix.runner }}` and the Obtain step pulls
    `test-tools:main` for `${{ matrix.platform }}` (multi-arch post-#587)
    so the arm64 shard gets the arm64 variant. `ci-rollup` aggregates
    through `needs.integration-e2e.result` unchanged.

11. **#615 sharded kcov + coverage as an enforced PR gate (amends #377,
    ADR-00000008)** — `coverage` is no longer the #377 main-only metric.
    It now (a) runs as a kcov `strategy.matrix` (`shard: ['1/4', '2/4',
    '3/4', '4/4']`, `fail-fast: false`) MIRRORING the `bats-unit` matrix
    via `test.sh --coverage-shard ${{ matrix.shard }}` — each shard kcov's
    the same round-robin unit slice the unit-test matrix runs (integration
    on the last shard); (b) gates on `needs.classify.outputs.code_changed ==
    'true'` so it runs on PRs (not just main push); and (c) joins
    `ci-rollup`'s `needs:` + the verifier consumes
    `needs.coverage.result` (SKIPPED-as-pass for doc-only PRs), so a kcov
    failure blocks PR merge. The old `if: push && ref
    == refs/heads/main` and the "NOT in ci-rollup needs" posture are gone.

    > #710 self-hosted amendment: the per-shard external-SaaS upload + the
    > SaaS `project` branch-protection status are REMOVED (the repo moves to
    > a GitLab where that SaaS is unavailable and uploading coverage leaks
    > data). Each shard instead uploads its kcov report as a CI ARTIFACT
    > (`actions/upload-artifact`, keyed by `strategy.job-index`); a new
    > `coverage-gate` job downloads every shard artifact and runs
    > `script/test/drivers/coverage_gate.sh`, which MERGES the per-shard
    > cobertura reports into one line-weighted project rate and fails below
    > `COVERAGE_MIN`. `coverage-gate` joins `ci-rollup`'s `needs:`, so the
    > floor gates merge with no external SaaS. The gate script is asserted
    > in `coverage_gate_spec.bats`.

12. **#697 probe-and-rebuild against a stale / racing `:main`** — the
    `release-test-tools` workflow republishes `:main` on a
    `dockerfile/Dockerfile.test-tools` change CONCURRENTLY with this
    workflow, so an Obtain step that `docker pull`s `:main` can fetch a
    pre-new-tool image (e.g. pre-kcov) while the republish is mid-flight,
    fast-failing the coverage shards with `kcov: command not found`. After
    the pull + `docker tag`, every `:main`-pulling Obtain step now PROBES
    the image for the tools this run needs via a single, easy-to-extend
    `REQUIRED_TOOLS="kcov bats shellcheck hadolint"` list (`docker run
    --rm test-tools:local sh -c 'command -v <tool>'`); on any miss it
    emits `build_local=true` so the existing buildx Build step rebuilds
    from `dockerfile/Dockerfile.test-tools`. This makes the Obtain path
    self-correcting against a stale / old / racing `:main` regardless of
    cause, keeping layer-1 (PR touched Dockerfile -> build) and layer-3
    (pull failed -> build) intact. Applied to all five `build_local`-pattern
    obtain steps (`hadolint`, `bats-fragile`, `bats-integration`,
    `coverage`, `system`) since they pull the same tag and race
    identically; `bats-fragile` + `coverage` (the kcov-racing shards) are
    asserted per-job, plus a count assertion that all five carry the guard.

13. **#677 CI double-run restructure (coverage = primary unit gate,
    weight-balanced shards, single `bats-fragile` job)** — after #686
    unified the coverage job onto the same Alpine test-tools image, the
    4-shard `bats-unit` matrix and the 4-shard `coverage` matrix ran the
    SAME ~1991 unit specs twice per PR (8 parallel jobs), differing only by
    `COVERAGE=1`. The restructure: (a) the `coverage` matrix stays the
    PRIMARY unit gate (kcov over every non-fragile test; codecov upload +
    the #615/ADR-00000008 project gate untouched); (b) the `bats-unit`
    matrix is replaced by a SINGLE `bats-fragile` job that runs ONLY the
    kcov-fragile specs the coverage matrix skips via
    `[ "${COVERAGE:-0}" = 1 ] && skip` — in PLAIN mode, so the delta is
    preserved with zero double-run. The fragile set is computed at RUNTIME
    (`test.sh --bats-fragile` -> `_fragile_unit_files` greps a
    line-anchored skip guard), so a new fragile-skip in a 10th file is
    picked up automatically; (c) `_shard_unit_files` replaces round-robin
    with greedy bin-packing by per-spec `@test` count (heaviest-first into
    the lightest shard) so the slowest coverage shard approaches `total/N`.
    `ci-rollup needs:` and `release needs:` swap `bats-unit` ->
    `bats-fragile`; `coverage` joins the `release` chain (it is now the
    primary unit gate). Every unit test still runs SOMEWHERE: non-fragile
    under coverage/kcov, the fragile files under `bats-fragile` (plain).

| Category | Tests |
|----------|-------|
| `actionlint` job declared | 1 |
| `actionlint` step uses `rhysd/actionlint:<pinned-version>` Docker image | 1 |
| `classify` job declared with `code_changed` + `system_relevant` outputs | 3 |
| `classify` doc-only allow-list + system block-list + non-PR default | 3 |
| `bats-fragile`/`bats-integration`/`integration-e2e`/`system` declare `needs: [actionlint, classify]` | 4 |
| `bats-fragile`/`bats-integration` job-level `if: code_changed == 'true'` + no remaining monolithic `test:` job (#377, #677) | 3 |
| `integration-e2e` job-level `if: code_changed == 'true'` + `system` job-level `if: system_relevant == 'true'` (#317 P3 tightens) | 2 |
| `bats-fragile`/`bats-integration`/`system` use `docker/build-push-action@v6` with `scope=test-tools` GHA cache | 3 |
| `classify` fail-open (`set -uo pipefail`) + pre-fetch base ref (#317 gotcha-1/2) | 2 |
| `bats-fragile` Obtain step pulls `:main` with 3-layer fallback + Build step gated on `build_local` (#317 P2 + #677) | 2 |
| `bats-integration` Obtain step + 3-layer fallback (#317 P2 + #377) | 1 |
| `integration-e2e` Obtain step + `TEST_TOOLS_IMAGE` env passthrough + no `driver: docker` pin (#317 P2) | 2 |
| `integration-e2e` native arm64 matrix (#603): amd64+arm64 native-runner matrix with `fail-fast: false`; shards `runs-on: ${{ matrix.runner }}`; Obtain pulls the matrix platform | 3 |
| `system` Obtain step with 3-layer fallback (#317 P2) | 1 |
| Obtain steps pre-fetch base ref (5 occurrences post-#377: classify + 4 jobs, #317 P2 reuses P1 gotcha-2 fix) | 1 |
| `classify` system block-list extends to `setup.sh` + `i18n.sh` + `lib/**` + `prune.sh` (#317 P3 gotcha-5) | 1 |
| `ci-rollup` declared + `needs: [actionlint, classify, shellcheck, hadolint, bats-fragile, bats-integration, coverage, coverage-gate, integration-e2e, system]` + `if: always()` (#337 + #376 + #377 + #615 + #677 + #710) | 3 |
| `ci-rollup` DOES need `coverage` now (#615 amends #377) | 1 |
| `ci-rollup` verify step consumes every `needs.<job>.result` incl `coverage` + `coverage-gate` + SKIPPED treated as pass for conditional jobs + `success` required for hard-mandatory jobs (#337 + #376 + #377 + #615 + #677 + #710) | 3 |
| `shellcheck` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + runs `test.sh --shellcheck-only` on plain ubuntu-latest with no buildx (#376) | 3 |
| `doc-counts` job declared + `needs: [actionlint, classify]` + runs `test.sh --doc-counts-only` on plain ubuntu-latest with no buildx + carries NO `code_changed` gate + is hard-mandatory in `ci-rollup` (#864) | 4 |
| `hadolint` job declared + `needs: [actionlint, classify]` + `if: code_changed == 'true'` + lints both template-owned Dockerfiles via `hadolint-action` (#376) | 3 |
| `bats-fragile` declared + is a single job (no shard matrix) + invokes `test.sh --bats-fragile` + no `bats-unit` matrix remains (#677) | 4 |
| `bats-integration` declared + invokes `test.sh --bats-integration` (#377) | 2 |
| `coverage` declared (#377) + runs on PRs via `if: code_changed == 'true'` (not main-only) + primary kcov unit gate over `matrix.shard: ['1/4'..'4/4']` (greedy weight-balanced) + invokes `test.sh --coverage-shard ${{ matrix.shard }}` + uploads each shard report as a CI artifact (#615 + #677 + #710) | 4 |
| Self-hosted coverage (#710): NO codecov reference anywhere in the workflow + a `coverage-gate` job downloads the shard artifacts and runs `coverage_gate.sh` | 2 |
| `release` job needs `[shellcheck, hadolint, bats-fragile, bats-integration, coverage, integration-e2e, system]` before publishing a tag (#376 + #377 + #677) | 1 |
| Probe-and-rebuild against a stale/racing `:main`: `bats-fragile` + `coverage` Obtain probe for kcov and rebuild on a miss + `REQUIRED_TOOLS` list is extensible + all five `build_local` obtain steps carry the guard (#697) | 4 |

### test/bats/unit/release_test_tools_yaml_spec.bats (14)

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
| Native-runner matrix (#587): drops `setup-qemu-action`; `compute-matrix` maps platforms to native runners; build shards run on `matrix.runner`; build per-platform + push by digest; `merge` job creates the manifest via `imagetools` | 5 |
| Declares `packages: write` permission | 1 |

### test/bats/unit/release_worker_yaml_spec.bats (2)

Structural assertions for `.github/workflows/release-worker.yaml`'s
archive step. The user-facing wrappers moved out of the repo root into
`script/` (symlinks into `.base/`); the archive `cp -r` still listed the
root names (`build.sh` / `run.sh` / `exec.sh` / `stop.sh` /
`setup_tui.sh`) as operands, and `cp -r` aborts non-zero on a missing
operand -- failing the first `v*` tag push of every standard-layout
downstream. These tests lock the removal (wrappers ship via `script/`).

| Category | Tests |
|----------|-------|
| Archive cp list names no removed root wrapper operand (#558) | 1 |
| Archive cp list keeps the paths that still ship (no over-prune) | 1 |

### test/bats/unit/publish_worker_yaml_spec.bats (11)

Structural assertions for the `.github/workflows/publish-worker.yaml`
reusable `call-publish` workflow (foundational image repos push their
Dockerfile target stage to a registry on tag push; downstream app repos
consume via `FROM ${registry}/${owner}/<image>`). #602: the original
`publish` job had every matrix shard push the SAME computed tag(s) via
`push: true` + `tags:`, leaving a last-shard-wins single-arch tag on a
multi-platform call (no manifest merge). The fix mirrors the #587
release-test-tools pattern — each shard pushes by digest, uploads its
digest, and a `merge` job assembles the tagged manifest list via
`docker buildx imagetools create`. These guards lock that contract.

| Category | Tests |
|----------|-------|
| Stays a reusable `workflow_call` workflow; preserves the registry-parameterised inputs | 2 |
| Native-runner matrix: `compute-matrix` maps platforms to native runners; build shards run on `matrix.runner` | 2 |
| Push-by-digest per shard (#602): build pushes by digest; no shared same-tag-per-shard push (regression guard); digest exported + uploaded as artifact | 3 |
| Merge job (#602): downloads digests + creates the manifest via `imagetools`; resolves tags from inputs once; login uses the parameterised registry | 3 |
| Declares `packages: write` on both push jobs | 1 |

### test/bats/unit/multi_distro_build_worker_yaml_spec.bats (16)

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

### test/bats/unit/wrapper_lib_spec.bats (18)

Unit tests for the wrapper-runtime module `lib/wrapper.sh` (#565), which
hoists the cross-cutting surfaces the 5 docker wrappers (build / run /
exec / stop / prune) used to duplicate: the `_msg` dispatcher, the
`--lang` pre-pass, and the build/run setup/drift orchestration. Each
helper is sourced directly (not through a wrapper) so the branches run in
isolation; a minimal sandbox with a mock `setup.sh` drives the
orchestration end-to-end without docker.

Covers (with the "called from each of the 5 wrappers" parameterisation):

| Group | Cases |
| --- | --- |
| `_msg` dispatcher: routes `<category> <key>` to `_msg_<category>`, reads global `_LANG`, errors on missing category / key | 4 |
| `_wrapper_lang_prepass`: sets `_LANG` from `--lang` (anywhere in argv), leaves it untouched without `--lang`, unsupported-value fallback to `en`, requires a verb, threads each of the 5 verbs into the `_sanitize_lang` warning tag | 6 |
| `_wrapper_setup_sync`: bootstrap on missing `.env`, `RUN_SETUP=true` forced run, clean drift-check skips re-apply, regen on drift, exit-1 `no_env` error path, per-verb `[<verb>]` log tag (build + run), requires a verb, degrades to empty forward-args when `SETUP_FORWARD_ARGS` is unset (lib defensive-unset convention) | 8 |

### test/bats/unit/wrapper_lib_lookup_spec.bats (5)

Locks how the wrappers locate `_lib.sh` (#282): `--help` paths source it
from `.base/` when present, and the lookup errors clearly when neither
`.base/` nor a sibling `_lib.sh` exists.

| Test | Description |
|------|-------------|
| `build.sh --help: sources _lib.sh from .base/ (#282)` | build resolves lib from subtree |
| `run.sh --help: sources _lib.sh from .base/ (#282)` | run resolves lib from subtree |
| `exec.sh --help: sources _lib.sh from .base/ (#282)` | exec resolves lib from subtree |
| `stop.sh --help: sources _lib.sh from .base/ (#282)` | stop resolves lib from subtree |
| `build.sh: errors clearly when neither .base/ nor sibling _lib.sh exists (#282)` | Missing-lib hard fail |

### test/bats/unit/hook_spec.bats (8)

Unit tests for the pre/post user-hook runners (`_run_pre_hook` /
`_run_post_hook`, #440): presence + executable-bit gating, exit-code
forwarding for caller abort, and DRY_RUN skip.

| Test | Description |
|------|-------------|
| `_run_pre_hook: returns success when no hook file present (#440)` | Absent hook is a no-op |
| `_run_pre_hook: present + +x + exit 0 -> runs and forwards args (#440)` | Runs and forwards argv |
| `_run_pre_hook: hook exit 7 -> helper returns 7 for caller to abort (#440)` | Exit-code propagation (pre) |
| `_run_post_hook: hook exit 11 -> helper returns 11 (#440)` | Exit-code propagation (post) |
| `_run_pre_hook: present but not executable -> hard fail with clear msg (#440)` | Non-exec hard fail (pre) |
| `_run_post_hook: present but not executable -> hard fail with clear msg (#440)` | Non-exec hard fail (post) |
| `_run_pre_hook: DRY_RUN=true -> hook skipped silently (#440)` | DRY_RUN skip (pre) |
| `_run_post_hook: DRY_RUN=true -> hook skipped silently (#440)` | DRY_RUN skip (post) |

### test/bats/unit/dockerfile_migrate_spec.bats (44)

Unit tests for the declarative Dockerfile-migration list
`lib/dockerfile_migrate.sh` (#567, folds #579 facet B). The lib exposes a
small interface — `apply_migrations <dockerfile>` — over an ordered,
data-driven `_MIGRATIONS` table of `{detect, transform}` units, each
healing one v0.41.0-fanout Dockerfile/entrypoint breakage. upgrade.sh
Step 5 sources the lib and calls the dispatcher (replacing the old one-off
seds). Each migration is driven in isolation via before/after fixtures
plus the dispatcher's apply / skip / idempotency contract: a detected
shape auto-applies idempotently, a missing/ambiguous shape is skipped
(warn, never force-rewrite).

| Test | Description |
|------|-------------|
| `apply_migrations is the public dispatcher entry (#567)` | Small interface exists |
| `apply_migrations skips cleanly when path does not exist (#567)` | No-Dockerfile skip |
| `_MIGRATIONS is a non-empty ordered list (#567)` | Data-driven table is seeded |
| `migration 0 (downstream-to-dist): rewrites lib/wrapper COPY sources to .base/dist/ (#714)` | - |
| `migration 0 (downstream-to-dist): detect false when no .base/downstream/ reference (#714)` | - |
| `migration 0 (downstream-to-dist): idempotent — second run is a no-op (#714)` | - |
| `migration 1 (wrapper-copy): rewrites shape A 'COPY *.sh /lint/' (#567)` | - |
| `migration 1 (wrapper-copy): rewrites shape B 'COPY .base/script/docker/*.sh /lint/' (#567)` | - |
| `migration 1 (wrapper-copy): idempotent — second run is a no-op (#567)` | - |
| `migration 1 (wrapper-copy): detect is false when no legacy wrapper COPY present (#567)` | - |
| `migration 2 (pip-helper): drops the retired CONFIG_DIR pip install line (#567)` | - |
| `migration 2 (pip-helper): idempotent — no pip line means detect false (#567)` | - |
| `migration 3 (explicit-copy): drops single-line explicit top-level .sh COPY (#567)` | - |
| `migration 3 (explicit-copy): drops multi-line backslash-continued COPY block (#567)` | - |
| `migration 3 (explicit-copy): detect false when lint stage uses lib/wrapper dir COPYs only (#567)` | - |
| `migration 4 (logging-rename): rewrites the Dockerfile COPY to runtime/logging.sh (#567)` | - |
| `migration 4 (logging-rename): rewrites a sibling entrypoint source line (#567)` | - |
| `migration 4 (logging-rename): detect false when already on new name (#567)` | - |
| `migration 4 (logging-rename): heals a stale entrypoint when the Dockerfile is already migrated (#692)` | - |
| `migration (logrotate-copy): inserts logrotate.sh COPY after the logging.sh COPY (#805)` | - |
| `migration (logrotate-copy): detect false when logrotate COPY already present (idempotent) (#805)` | - |
| `migration (logrotate-copy): detect false when no logging.sh COPY present (#805)` | - |
| `migration (logrotate-copy): dispatcher run twice inserts the COPY exactly once (#805)` | - |
| `migration (watchdog-copy): inserts watchdog.sh COPY after the logging.sh COPY (#797)` | - |
| `migration (watchdog-copy): detect false when watchdog COPY already present (idempotent) (#797)` | - |
| `migration (watchdog-copy): detect false when no logging.sh COPY present (#797)` | - |
| `migration (watchdog-copy): dispatcher run twice inserts the COPY exactly once (#797)` | - |
| `migration 5 (hadolint): DL3007 pins bats/alpine :latest tags (#567)` | - |
| `migration 5 (hadolint): DL3046 adds useradd -l (#567)` | - |
| `migration 5 (hadolint): DL3003 cd /lint -> WORKDIR /lint + RUN (#567)` | - |
| `migration 5 (hadolint): DL3042 adds pip --no-cache-dir (#567)` | - |
| `migration 5 (hadolint): DL4006 adds SHELL pipefail to alpine lint-tools (#567)` | - |
| `migration 5 (hadolint): DL3006 inline ignore before parameterized FROM (#567)` | - |
| `migration 5 (hadolint): DL3006 idempotent — does not double-insert (#567)` | - |
| `migration 5 (hadolint): detect false on a clean Dockerfile (#567)` | - |
| `migration 6 (sc1090): broadens the entrypoint directive to SC1090,SC1091 (#567)` | - |
| `migration 6 (sc1090): idempotent when already SC1090,SC1091 (#567)` | - |
| `migration 6 (sc1090): detect false when no sibling entrypoint (#567)` | - |
| `migration 7 (arg-user): rewrites bare 'ARG USER' to default from USER_NAME (#579)` | - |
| `migration 7 (arg-user): idempotent — already defaulted is not detected (#579)` | - |
| `migration 7 (arg-user): does not touch an unrelated ARG (#579)` | - |
| `migration 8 (nounset-source): brackets the ROS source with set +u/-u (#579)` | - |
| `migration 8 (nounset-source): idempotent — already-guarded source untouched (#579)` | - |
| `migration 8 (nounset-source): detect false when no set -u in entrypoint (#579)` | - |

### test/bats/unit/build_sh_spec.bats (58)

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
real (non-dry-run) docker build invocation, **version-scoped local
test-tools tag** (#828: the internal build derives `test-tools:<version>`
from `.base/.version` and forwards it as the `TEST_TOOLS_IMAGE` build-arg;
fails loud on a missing version, no bare-tag fallback), **the self-managed-repo
tooling tag** (#896: a repo with no `.base/` subtree has no pinned version to
scope a local tag by, so build.sh asks that repo's own
`script/test/test.sh --test-tools-image` rather than deriving a second tag, and
forwards the result on BOTH channels -- the `--build-arg` a consumer Dockerfile
reads and the exported environment a self-managed `compose.yaml` interpolates;
repos that do carry `.base/` keep the version-scoped derivation),
**runtime log-line i18n**
(bootstrap / drift-regen / err_no_env messages translate in all four
languages via the local `_msg()` table; English remains the default),
and **`-C` / `--chdir` flag** (docker_harness#53: pre-pass overrides
FILE_PATH to redirect the wrapper to a different repo, both short and
long form, value-required and directory-existence guards, usage help
mention), and **`-v` / `--verbose` / `-vv` / `--very-verbose` flag**
(#311: exports `BUILDKIT_PROGRESS=plain` so a hung `docker build`'s RUN
step output is visible; `-vv` adds `set -x` on the wrapper itself;
usage help mentions all four spellings), and **#690 pre-build hook
abort** (a failing `script/hooks/pre/build.sh` makes the wrapper exit
the hook's rc via `_run_pre_hook build "$@" || exit $?` AND `docker
compose build` never runs).

### test/bats/unit/build_sh_prune_spec.bats (7)

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

### test/bats/unit/run_sh_spec.bats (67)

Unit tests for `run.sh`. Mirrors the build_sh_spec.bats harness;
`docker ps` reads from a controllable stub file so tests can simulate
"container already running" scenarios.

Covers: `--help` (en/zh/zh-CN/ja), `--setup`/`-s`, bootstrap on
missing `.env` / `setup.conf` / `compose.yaml`, drift-check path,
bootstrap staying non-interactive (setup.sh, not TUI), defensive guard
when setup produces no `.env`, `--detach`, devel vs non-devel TARGET
routing, already-running guard, Wayland xhost path,
`--lang` argument validation, fallback `_detect_lang`
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
`--`), and **#580 interactive exit-code normalization**
(`_normalize_interactive_rc` maps clean-exit codes 0 and 130 to 0 on
the no-CMD foreground paths -- devel attached shell and one-shot stage
`compose up` -- so a Ctrl-C-cleared line carried out on exit isn't a
recipe failure, while a genuine non-clean code like 127 still
propagates and command mode `just run <cmd>` keeps the real exit code),
and **#679 non-`devel` CMD-override dispatch** (a non-`devel` one-shot
target WITH a CMD dispatches `compose run --rm <SERVICE> <CMD…>` so the
ENTRYPOINT runs and the override replaces the default CMD — NOT the
pre-#679 `up -d` + `exec` pair that bypassed the ENTRYPOINT and
double-launched the default CMD; the #679 repro shape `-t runtime ros2
launch …` is asserted; `devel` + CMD still uses `up -d` + `exec`; the
no-CMD paths are unchanged; #580 exit-code propagation rides the `run`
path for non-`devel` command mode), and **#690 pre-run hook abort +
foreground post-run hook exit override** (a failing
`script/hooks/pre/run.sh` aborts the wrapper with the hook's rc before
the build delegate / `compose up`; in the foreground path a failing
`script/hooks/post/run.sh` makes `_app_cleanup` override the wrapper
exit with the hook's rc while `compose down --remove-orphans` still
runs).

### test/bats/unit/exec_sh_spec.bats (58)

Unit tests for `exec.sh` argument parsing, the container-running
precheck, and i18n. Sandbox tree mirrors build_sh_spec.bats;
`docker ps` reads from a controllable stub file so tests can toggle
"container running" state without a real docker daemon. `.env` is
pre-seeded so `_load_env` / `_compute_project_name` succeed without a
bootstrap step.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` / `--target`
value validation, English-default not-running error, Chinese /
Simplified Chinese / Japanese not-running error text, the `./run.sh`
start hint (en + zh-TW), `--dry-run` bypassing the guard, compose exec
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
`--help` mentions both flag pairs), and **#690 exit-code forwarding +
pre/post hook error paths** (the container command's exit code is
forwarded unchanged via `return "${_exec_rc}"` — 42 / 0 / 7 cases; a
failing post-exec hook overrides the forwarded rc via `|| exit $?`; a
failing pre-exec hook aborts before `compose exec` runs).

### test/bats/unit/stop_sh_spec.bats (28)

Unit tests for `stop.sh` argument parsing, the single-project teardown,
and i18n. `docker ps -a` output is PATH-shimmed via `${DOCKER_PS_A_FILE}`
so tests can seed the project container list for the verbose listing.

Covers: `--help` (en/zh/zh-CN/ja), `--lang` value validation, teardown
via `docker compose down` (base is single-instance, #600), fallback
`_detect_lang` branches, **`-C` / `--chdir` flag**
(docker_harness#53: redirect FILE_PATH so .env / project name come
from the alt repo, short + long form, value-required and directory
guards, usage help mention), and **`-v` / `--verbose` / `-vv` /
`--very-verbose` flag** (#311: parity across wrappers; flag is a no-op
for `docker compose down` but `-vv` still enables wrapper trace; the
verbose path lists the project containers before tearing them down),
and **`--prune` flag** (#319: opt-in lightweight cleanup after compose
down — `docker network prune --filter until=10m` + `docker image prune
--filter until=24h`; usage help mentions `--prune` with the two grace
windows; the plain `stop.sh --dry-run` path emits no `docker prune`
commands), and **#690 pre-stop hook abort** (a failing
`script/hooks/pre/stop.sh` aborts with the hook's rc before
`compose down` runs).

### test/bats/unit/prune_sh_spec.bats (41)

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
aborts with exit-1 + i18n "aborted" message; closed-stdin EOF aborts
cleanly with no set-e crash (#702); `-y` skips the prompt;
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

Plus the **`--worktree-orphans` interactive confirmation gate (#699)**
— the destructive `docker rmi` loop only reaches its prompt when
neither `-y` nor `--dry-run` is given, a branch the cases above never
exercised. Three cases mirror the `--volumes` prompt pair for the more
destructive image removal: piped `y` confirms and the candidate lands
in `DOCKER_RMI_LOG`; piped `n` aborts with exit-1 + "aborted by user"
and an empty `DOCKER_RMI_LOG`; closed stdin (`</dev/null`, no `-y`)
aborts cleanly with the same diagnostic instead of dying on a `set -e`
`read` EOF — prune.sh maps `read` EOF to an empty reply
(`read -r _reply || _reply=""`) so the default case treats it as an
explicit abort.

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

### test/bats/unit/justfile_user_spec.bats (33)

Executable tests for the user-facing layered entry + namespaces (#546 /
ADR-00000005; ADR-00000011: docker is a namespace, `just docker build`).
Parity with the removed `makefile_user_spec`: sandboxes a repo with the
entry + module symlink chain at root + stub `script/*.sh` recorders, and
RUNS `just <ns> <verb>` to assert 1:1 forwarding with `{{args}}`
passthrough. Skips when `just` is not yet in the test-tools image
(pre-release GHCR pull -- see template_spec for the `apk add ... just`
guard + the release smoke check).

| Test | Description |
|------|-------------|
| `just docker build forwards positional args to ./script/build.sh` | `just docker build test` -> build.sh test |
| `just docker build passes flags through verbatim (no -- separator needed)` | no `--` separator needed |
| `just docker exec passes = -bearing Kit-style args through (no EXEC_ARGS shim, #469)` | no EXEC_ARGS shim (#469) |
| `just docker run / stop / prune / setup forward to their wrappers` | wrapper dispatch |
| `just docker setup-tui forwards to ./script/setup_tui.sh` | - |
| `just docker start --help prints composite usage and does NOT build or run (#779)` | - |
| `just docker start -h short-circuits like --help (#779)` | - |
| `just base upgrade forwards to ./.base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)` | - |
| `just base update runs upgrade.sh --check (apt-aligned, #652)` | #652 -- apt-aligned check |
| `just base init forwards to ./.base/dist/script/base/init.sh (#653, #654, ADR-00000011)` | - |
| `just base completions forwards to script/base/completions.sh (#653, ADR-00000011)` | #653 -- opt-in completions installer dispatch |
| `bare just lists namespaces (replaces make help)` | replaces `make help`; lists `docker`/`base`/... |
| `bare just docker lists the docker verbs (namespace help, #655)` | #655 -- namespace help via module default (source_file() --list) |
| `bare just base lists the base verbs (namespace help, #655)` | #655 -- namespace help via module default |
| `just docker build --help forwards --help to the backing script (#655)` | #655 -- recipe `--help` reaches the script as an arg |
| `just docker build --lang ja forwards --lang to the backing script (#655)` | #655 -- recipe `--lang` forwarded |
| `just base completions --lang forwards --lang to completions.sh (#655)` | #655 -- base ns recipe `--lang` forwarded |
| `just base update --help reaches upgrade.sh usage, not the check (#789)` | - |
| `just base update -h reaches upgrade.sh usage (#789)` | - |
| `just docker help + h alias list the docker verbs (#789)` | - |
| `just base help + h alias list the base verbs (#789)` | - |
| `just template help + h alias print the template usage (#789)` | - |
| `just docker help renders zh-TW recipe summaries under LANG=zh-TW (i18n)` | - |
| `just docker help renders Japanese recipe summaries under LANG=ja (i18n)` | - |
| `just docker help --lang overrides LANG for the listing (i18n)` | - |
| `just docker help English default still renders the translated listing (i18n)` | - |
| `just base help renders zh-TW recipe summaries under LANG=zh-TW (i18n)` | - |
| `just template help renders zh-TW recipe summary under LANG=zh-TW (i18n)` | - |
| `dashed just <ns> --help errors but hints 'help' (documented just limit, #789)` | - |
| `just template new --help shows the recipe usage (recipe-level help, #789)` | - |
| `repo-local group via script/local/justfile.local resolves as a top-level namespace (#632)` | #632 `import?` registry + `mod?` group |
| `just template new <name> scaffolds a working repo-local group (#633, closes #594)` | #633 / closes #594 -- scaffold + immediately usable |
| `bare just template prints help (#633)` | #633 -- module default recipe |

### test/bats/unit/template_new_spec.bats (9)

Unit tests for the repo-local command-group scaffolder
`dist/script/template/new.sh` (#633, closes #594). Runs `new.sh`
directly (no `just` needed): it creates `script/local/<name>/justfile.<name>`
+ `<name>.sh` from `skel/` and registers the group in
`script/local/justfile.local`.

| Test | Description |
|------|-------------|
| `new.sh scaffolds script/local/<name>/{justfile.<name>,<name>.sh} from skel` | files created + executable |
| `new.sh substitutes __NAME__ in the scaffolded files` | placeholder replaced |
| `new.sh registers the group in script/local/justfile.local (mod? line)` | registry append |
| `new.sh refuses to clobber an existing group` | safe no-overwrite |
| `new.sh does not duplicate the registry line on a second distinct group` | one mod? per group |
| `new.sh rejects an invalid group name` | name validation |
| `new.sh errors with usage when no name given` | arg guard |
| `new.sh registers a real mod? line even when the seed registry only COMMENTS that name (#785)` | - |
| `new.sh source ships with the executable bit set (recipe invokes it directly) (#785)` | - |

### test/bats/unit/justfile_spec.bats (16)

Static content checks for the layered just entry (ADR-00000005 / #545,
ADR-00000010; ADR-00000011: docker + base are `mod?` namespaces, not a
top-level import). The entry `dist/script/justfile` mods the docker
+ base modules; docker verbs forward 1:1 to `./script/<name>.sh` via
`{{args}}`, base verbs to `./.base/upgrade.sh`. Asserted by grep, not
execution -- `just` is not in the test-tools image; downstream installs it.

| Test | Description |
|------|-------------|
| `layered entry + docker module exist` | both files present |
| `docker module declares args-passthrough recipes for every wrapper verb (#545)` | build/run/exec/stop/prune/setup/setup-tui `*args` |
| `docker module no longer carries upgrade/upgrade-check (moved to base ns, #652)` | #652 -- upgrade is a .base op |
| `docker module recipes forward to ./script/<wrapper>.sh with {{args}} (#545)` | forwarding bodies |
| `base module declares upgrade + update (apt-aligned) forwarding to .base/dist/script/base/upgrade.sh (#652, #654, ADR-00000011)` | - |
| `base update recipe forwards -h\|--help to upgrade.sh usage without the check (#789)` | - |
| `every shipped namespace module ships a help recipe + h alias (#789)` | - |
| `base module declares init + completions recipes (#653, ADR-00000011)` | #653 -- init -> .base/init.sh, completions -> script/base/completions.sh |
| `entry mods the base namespace (#652, ADR-00000011)` | #652 -- `mod? base` |
| `docker module owns a default recipe + pins cwd to repo root (#652, ADR-00000011)` | #652 -- mod default + `set working-directory := '../..'` |
| `entry mods the docker namespace + default recipe lists recipes (#652, ADR-00000011)` | #652 -- `mod? docker` + `default: @just --list` |
| `test / release namespaces own a default recipe (bare-namespace help, #655)` | #655 -- bare `just test` / `just release` |
| `test namespace: coverage-path demands its spec, coverage keeps its optional shard (#887)` | Required spec argument (a defaulted one would kcov the whole suite on a typo) |
| `test / release namespaces are English-only -- no --lang plumbing (#655)` | #655 -- ADR-00000011 i18n scope (machine/CI namespaces) |
| `consumer entry: every top-level mod? has one adjacent one-line doc comment (#720)` | #720 -- guards `just --list` descriptions (no blank-gap empty, no multi-line fragment) |
| `base root justfile: every top-level mod? has one adjacent one-line doc comment (#720)` | #720 -- same invariant for base's self-dev entry |

### test/bats/unit/help_lang_spec.bats (19)

--help / --lang coverage across the recipe-backing scripts (#655,
ADR-00000011 §6). Runs each script directly (no `just`): asserts the
English-baseline usage on `-h`/`--help` (exit 0); the human-facing base /
template scripts (init / upgrade / completions / new) accept `--lang <code>`
and honor `SETUP_LANG`/`$LANG` via i18n.sh (validated, non-fatal fallback on a
bad value); and the machine/CI `test` namespace stays English-only (rejects
`--lang`). Namespace-level bare help + the `just`-driven forwarding live in
justfile_user_spec.bats.

| Test | Description |
|------|-------------|
| `test.sh --help exits 0 and prints usage` | English baseline usage |
| `test.sh -h exits 0 and prints usage` | short flag |
| `init.sh --help exits 0 and prints usage` | base ns usage |
| `upgrade.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh --help exits 0 and prints usage` | base ns usage |
| `completions.sh -h exits 0 and prints usage` | short flag |
| `new.sh --help exits 0 and prints usage (#655: gained -h/--help)` | #655 -- new.sh gained -h/--help |
| `new.sh -h exits 0 and prints usage` | short flag |
| `init.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `upgrade.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `completions.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `new.sh --help advertises --lang (#655 i18n namespace)` | i18n namespace |
| `init.sh accepts a valid --lang without error (flag is stripped)` | flag stripped before dispatch |
| `upgrade.sh accepts a valid --lang without error` | flag stripped before dispatch |
| `completions.sh accepts a valid --lang without error` | flag accepted |
| `new.sh accepts a valid --lang and still scaffolds` | flag + positional name |
| `init.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `completions.sh --lang bogus warns and falls back to en (non-fatal)` | _sanitize_lang fallback |
| `test.sh rejects --lang (test namespace is English-only, #655)` | machine/CI namespace, no i18n |

### test/bats/unit/completions_spec.bats (14)

Unit tests for the opt-in shell tab-completion installer
`dist/script/base/completions.sh` (#653, ADR-00000011), reached as
`just base completions install|uninstall [--shell ...]`. Sandboxes HOME + the
XDG dirs to a temp tree and stubs `just` on PATH so `JUST_COMPLETE=<shell> just`
emits a per-shell marker; asserts the DYNAMIC loader is written to each shell's
standard auto-load dir (no rc edits), idempotency, the zsh fpath hint, default
`$SHELL` detection, and uninstall.

| Test | Description |
|------|-------------|
| `install bash writes the dynamic eval-loader file` | exact `eval "$(JUST_COMPLETE=bash just)"` content |
| `install fish writes the file with the dynamic completer output` | captures `JUST_COMPLETE=fish just` |
| `install zsh writes _just + prints the fpath hint when dir not on fpath` | `_just` + stdout fpath hint |
| `install zsh: a zsh still printing fpath cannot re-hint a dir already on it (#905)` | - |
| `uninstall removes the installed file` | removes the loader |
| `uninstall is idempotent when the file is absent (no error)` | safe no-op |
| `install --shell all installs all three shells` | bash + fish + zsh |
| `uninstall --shell all removes all three shells` | bash + fish + zsh removed |
| `default --shell detects bash from $SHELL basename` | `$SHELL`-driven detection |
| `default --shell detection errors on an unknown shell` | unknown -> error asking for --shell |
| `unknown argument is a usage error (exit 2), distinct from detection error (#692)` | exit 2 vs exit 1 |
| `missing action is a usage error (exit 2) (#692)` | missing install/uninstall -> exit 2 |
| `-h / --help exits 0 with usage` | help text |
| `install is idempotent: a re-run overwrites cleanly` | overwrite-on-reinstall |

### test/bats/unit/compose_emit/blocks_spec.bats (29)

Covers the per-service compose emitter (`_emit_stage_service`) and its
shared leaf-emitter sub-seams, hoisted out of `generate_compose_yaml`
(#566). Each emitter is exercised in isolation -- build the inputs, call
the emitter, assert on the small fragment it returns -- instead of
running the whole ~900-line generator and grepping its YAML output.

| Test | Description |
|------|-------------|
| `_emit_gpu_deploy_block: gui=false emits nothing` | GPU off |
| `_emit_gpu_deploy_block: gui=true emits deploy reservation with count + caps` | GPU on |
| `_emit_caps_block: all empty emits nothing` | caps off |
| `_emit_caps_block: cap_add list emits cap_add block` | cap_add |
| `_emit_caps_block: cap_drop + security_opt emit their blocks` | cap_drop/sec_opt |
| `_emit_env_file_block: emits the .env workload overlay block` | #502 env_file |
| `_emit_target_arch_line: empty omits the line; set emits literal TARGET_ARCH ref` | - |
| `_emit_build_network_line: empty omits; set emits network line` | build.network |
| `_emit_runtime_line: empty omits; set emits runtime line` | runtime |
| `_emit_restart_line: 'no' omits; plain value plain; on-failure:N quoted` | #478 restart |
| `_emit_init_line: default/true emits init: true; false omits; garbage dropped (#792)` | - |
| `_emit_additional_contexts_block: empty omits; entries emit block` | additional_contexts |
| `_emit_cgroup_rules_block: empty omits; entries emit quoted rules` | cgroup rules |
| `_emit_tmpfs_block: empty omits; entries emit tmpfs list` | tmpfs |
| `_emit_group_add_block: gated on gui AND non-empty groups; emits quoted gids` | #496 group_add |
| `_emit_user_build_args: empty omits; entries emit KEY: ${KEY} pairs` | build args |
| `_logging_svc_kv: seeds from global then overlays per-service (key-level merge)` | logging merge |
| `_logging_svc_kv: a different service does not pick up another svc overlay` | svc keying |
| `_emit_logging_block: empty global + per-svc emits nothing` | logging off |
| `_emit_logging_block: driver + rotation maps to compose options block` | logging opts |
| `_emit_logging_block: keys off the service name for per-svc overrides` | per-svc |
| `_logging_svc_local_path_mount: empty local_path yields empty mount` | #328 off |
| `_logging_svc_local_path_mount: relative path resolves against base, mounts /var/log/<name>` | rel path |
| `_logging_svc_local_path_mount: absolute path passed verbatim (trailing slash stripped)` | abs path |
| `_emit_stage_service: zero-diff stage emits the extends:devel shape` | #215 zero-diff |
| `_emit_stage_service: zero-diff stage with per-svc logging override emits logging block` | zero-diff logging |
| `_emit_stage_service: stage with overrides emits a standalone block (no extends)` | #220 standalone |
| `_emit_stage_service: override stage GPU resolution emits deploy reservation` | standalone GPU |
| `_yaml_dq wraps a value as a double-quoted scalar, escaping \ then " (#698)` | YAML scalar quoting |

### test/bats/unit/compose_emit/gen_spec.bats (87)

Covers `generate_compose_yaml` conditional output: AUTO-GENERATED
header, baseline workspace volume, network/ipc/privileged env-var
references, conditional pid emission (only for `host`; omitted for
`private` since Docker rejects the literal), `test` service presence,
image name threading, conditional GPU deploy block + GUI
env/volumes + extra volumes from `[volumes]` section, and the
deploy-scoped `[lifecycle] restart` emission (never on devel, on a
deployable stage in both the `extends: devel` and the standalone
shapes, absent on any `*-test` stage).

| Test | Description |
|------|-------------|
| `generate_compose_yaml outputs AUTO-GENERATED header` | Header check |
| `generate_compose_yaml emits top-level name: as the resolved PROJECT_NAME (#472)` | - |
| `generate_compose_yaml top-level name: precedes services: (#472)` | - |
| `generate_compose_yaml emits exactly one top-level name: (#472)` | - |
| `generate_compose_yaml named volume mount emits top-level volumes: stub (#482)` | - |
| `generate_compose_yaml bind mounts never enter top-level volumes: (#482)` | - |
| `generate_compose_yaml bind-only repo is zero-diff (no top-level volumes:) (#482)` | - |
| `generate_compose_yaml named volume with :mode strips mode from top-level name (#482)` | - |
| `generate_compose_yaml dedups a named volume referenced twice (#482)` | - |
| `generate_compose_yaml top-level volumes: stub has no driver/labels (#482)` | - |
| `generate_compose_yaml emits volumes: before networks: (#482)` | - |
| `generate_compose_yaml emits workspace mount when present in extras` | - |
| `generate_compose_yaml omits workspace when extras is empty (opt-out)` | - |
| `generate_compose_yaml default (no network_name) keeps network_mode env var` | - |
| `generate_compose_yaml with network_name emits networks list + bridge driver block (compose self-managed)` | - |
| `generate_compose_yaml omits devices block when both inputs empty` | - |
| `generate_compose_yaml emits devices: block from device list` | - |
| `generate_compose_yaml accepts /dev:/dev (full /dev tree bind)` | - |
| `generate_compose_yaml: device with propagation emits to volumes long-form (#450 P1)` | - |
| `generate_compose_yaml: device without propagation stays in devices: (#450 P1)` | - |
| `generate_compose_yaml: mixed devices split correctly (#450 P1)` | - |
| `generate_compose_yaml: device rw,rslave emits combined propagation (#450 P1)` | - |
| `generate_compose_yaml: device ro,rshared emits read_only + propagation (#450 P1)` | - |
| `generate_compose_yaml: propagation-only device creates volumes: header even without extras (#450)` | - |
| `generate_compose_yaml: all devices have propagation → no devices: section (#450)` | - |
| `generate_compose_yaml emits environment block from env_ list` | - |
| `environment env_N expands ${VAR} cross-reference to earlier sibling (refs #236)` | basic cross-ref |
| `environment env_N forward reference is left literal (refs #236)` | order-sensitive |
| `environment env_N unknown ${VAR} is left literal (refs #236)` | unknown stays literal |
| `environment env_N supports multiple cross-references in one value (refs #236)` | multi-ref |
| `environment env_N transitive cross-reference resolves through chain (refs #236)` | transitive |
| `generate_compose_yaml emits tmpfs block from tmpfs_ list` | - |
| `generate_compose_yaml emits ports block only under network_mode=bridge` | - |
| `generate_compose_yaml emits shm_size only when ipc_mode != host` | - |
| `generate_compose_yaml emits cap_add from security list` | - |
| `generate_compose_yaml emits cap_drop from security list` | - |
| `generate_compose_yaml emits security_opt from security list` | - |
| `generate_compose_yaml omits cap_add / cap_drop / security_opt blocks when empty` | - |
| `generate_compose_yaml per-stage security.cap_add_inherit=false clears inherited caps for that stage only (#526)` | per-stage caps clear |
| `generate_compose_yaml per-stage security.cap_add_N appends to inherited caps (#526)` | per-stage caps append emit |
| `generate_compose_yaml emits network_mode/ipc/privileged via env var` | env-var baked |
| `generate_compose_yaml omits pid when default private` | pid omit |
| `generate_compose_yaml emits pid env-var ref when host` | pid host |
| `generate_compose_yaml emits test service with profiles: [test]` | test service |
| `generate_compose_yaml image field contains repo name` | Image name |
| `generate_compose_yaml emits TZ build arg with Asia/Taipei default` | - |
| `generate_compose_yaml emits TARGETARCH build arg on devel (test inherits via extends, #493)` | - |
| `generate_compose_yaml omits TARGETARCH line when target_arch empty (BuildKit auto-fill)` | - |
| `generate_compose_yaml emits build.network on devel (test inherits via extends, #493)` | - |
| `generate_compose_yaml omits build.network line when build_network empty` | - |
| `generate_compose_yaml does NOT emit /dev:/dev by default (not in baseline)` | Baseline scope |
| `generate_compose_yaml GPU enabled => deploy block present` | GPU on |
| `generate_compose_yaml GPU disabled => no deploy block` | GPU off |
| `generate_compose_yaml GPU with specific count and capabilities` | GPU args |
| `generate_compose_yaml GUI enabled => DISPLAY env + X11 volumes present` | GUI on |
| `generate_compose_yaml GUI: xauth mounts at fixed neutral target, not host abs path (#582)` | #582 mount target |
| `generate_compose_yaml GUI: container XAUTHORITY points at the fixed mount target (#582)` | #582 env sync |
| `generate_compose_yaml GUI disabled => no DISPLAY env + no X11 volumes` | GUI off |
| `generate_compose_yaml GUI enabled => XDG_RUNTIME_DIR env (Wayland socket dir)` | - |
| `generate_compose_yaml GUI enabled => XDG_RUNTIME_DIR mounted rw at the same path` | - |
| `generate_compose_yaml GUI disabled => no XDG_RUNTIME_DIR env or mount` | - |
| `generate_compose_yaml emits no duplicate key within a service (GUI on)` | - |
| `generate_compose_yaml emits no duplicate key within a service (GUI off)` | - |
| `the duplicate-key detector actually fires on a duplicated service key` | - |
| `generate_compose_yaml extra volumes appended after baseline` | volumes list |
| `generate_compose_yaml empty extras => no extra mount lines` | empty list |
| `generate_compose_yaml with GUI+GPU+extras => all sections present` | fully loaded |
| `generate_compose_yaml emits device_cgroup_rules: when cgroup rules provided` | - |
| `generate_compose_yaml omits device_cgroup_rules: when rules list is empty` | - |
| `generate_compose_yaml omits runtime: when runtime arg is empty (desktop default)` | - |
| `generate_compose_yaml emits runtime: nvidia under devel when runtime=nvidia` | - |
| `generate_compose_yaml placement: runtime: appears between tty and cap_add region` | - |
| `generate_compose_yaml emits runtime service when Dockerfile has AS runtime` | #108 auto-emit |
| `generate_compose_yaml skips runtime service when Dockerfile lacks AS runtime` | opt-out by absence |
| `generate_compose_yaml skips runtime service when Dockerfile is absent` | no-Dockerfile guard |
| `runtime service extends devel and overrides target/image/tty/profile` | compose extends shape |
| `runtime service appears between devel and test blocks` | ordering |
| `runtime detection is robust against weird whitespace` | regex tolerance |
| `runtime detection ignores non-runtime stage names` | strict match |
| `generate_compose_yaml never emits restart: on the devel service (#840)` | - |
| `generate_compose_yaml emits restart: on a deployable stage service (#840)` | - |
| `generate_compose_yaml omits restart: on a *-test stage -- it exits by design (#840)` | - |
| `generate_compose_yaml emits restart: on a deployable stage that carries overrides (#840)` | - |
| `generate_compose_yaml quotes an on-failure:N policy on the deployable stage (#840)` | - |
| `generate_compose_yaml emits no restart: field at all for restart = no (#840)` | - |
| `generate_compose_yaml: runtime stage inherits device propagation from devel (#450 P3)` | - |
| `generate_compose_yaml per-stage emit is byte-identical via _resolve_docker_flags (#505 golden master)` | byte-identical golden |

### test/bats/unit/compose_emit/overlay_guard_spec.bats (6)

Forward-invariant guard (ADR-00000022): base's emitted compose must never
bake a hardcoded per-instance literal over the interpolation-channel field
set, so base-generated stacks are multi_run-expandable by construction. A
predicate self-check proves the guard discriminates a baked literal from a
`${VAR:-default}` interpolation, so a future change that hardcodes a
per-instance field fails immediately.

| Test | Description |
|------|-------------|
| `overlay guard predicate rejects a baked literal, accepts an interpolation` | self-check discrimination |
| `overlay guard: project name: is an overlay interpolation` | name interpolated |
| `overlay guard: every container_name: carries an interpolation (not a baked literal)` | container_name interpolated |
| `overlay guard: network_mode: is an env interpolation, never a baked literal` | network_mode interpolated |
| `overlay guard: no baked published-port literal anywhere (forward invariant)` | no baked port literal |
| `overlay guard: published ports are emitted as ${PORT_N:-default} on devel and stages` | ports overlay form |

### test/bats/unit/deploy_spec.bats (52)

Covers the self-contained field-deploy generator (#832; ADR-3 amended by
ADR-00000023). Deploy produces an output FOLDER run via a fully-resolved,
self-contained `docker compose` (superseding the #497 raw `docker run`
tar.xz): `_resolve_deploy_version` (the `<repo>:<stage>-<version>` image
stamp), `_resolve_deploy_context` (the conf-resolution shared with apply),
`_generate_resolved_compose` (the resolved `compose.yaml` -- no variable
interpolation, no `setup.conf`/`.env` dependency, dev-host workspace bind
stripped, `restart: unless-stopped` added, tunable-manifest paths bound,
per-stage params carried, follows the stage for GUI/X11),
`_generate_deploy_launcher` (the thin up/down/logs `deploy.sh`), and
`_generate_deploy_bundle` (the folder orchestrator; docker/xz/cp steps
mocked via `_dry_run_cmd`, no real daemon). Also covers `_setup_deploy`'s
stage-eligibility guard (#841): the `--stage` a user names must satisfy
`_is_deployable_stage` (PRD invariant 8 / ADR-00000023 sec.4), so the
template-managed baseline, the legacy aliases and any `*-test` stage are
refused before any build or bundle step.

| Test | Description |
|------|-------------|
| `_resolve_deploy_version: returns the tag in a tagged git tree (field-deploy)` | version tag |
| `_resolve_deploy_version: appends -dirty when the tree has uncommitted changes (field-deploy)` | dirty stamp |
| `_resolve_deploy_version: falls back to the short commit SHA in a tagless clone (#844)` | tagless `--always` fallback |
| `_resolve_deploy_version: degrades to 'unknown' outside a git tree (field-deploy)` | non-git fallback |
| `_resolve_deploy_context: resolves scalars + list strings from setup.conf (#506)` | full resolution |
| `_resolve_deploy_context: applies effective defaults for a minimal repo conf (#506)` | template-merged defaults |
| `_resolve_deploy_context: a missing [lifecycle] restart falls back to the shipped default (#840)` | - |
| `_resolve_deploy_context: builds the WATCHDOG_* env block from [lifecycle] watchdog_* (#840)` | - |
| `_resolve_deploy_context: legacy [deploy] runtime alias resolves gpu_runtime_mode (#506/#481)` | legacy alias |
| `_resolve_deploy_context: dri_groups auto resolves host GIDs via the SETUP_DETECT_DRI_GROUPS operator override (#506/#496)` | dri auto |
| `_resolve_deploy_context: dri_groups off yields empty (#506/#496)` | dri off |
| `_generate_resolved_compose: self-contained -- no variable interpolation, restart present, image pinned (#832)` | resolved + self-contained |
| `_generate_resolved_compose: strips the dev-host workspace bind and bakes env (no -v/-e) (#832)` | dev-host strip |
| `_generate_resolved_compose: binds each tunable-manifest file mount-wins over the baked default (#833)` | tunable binds |
| `_generate_resolved_compose: a tunable bind is read-only unless the manifest declared rw (#870)` | :ro default, :rw when declared |
| `_generate_resolved_compose: carries the deployed stage's resolved params (privileged/gpu/devices) (#832)` | per-stage params |
| `_generate_resolved_compose: follows the stage -- gui off headless, gui force emits X11 (#832)` | follow-stage GUI |
| `_generate_resolved_compose: per-stage [stage:runtime] override is applied (#832)` | per-stage override |
| `_generate_resolved_compose: shm_size + ipc emitted as literals under non-host ipc (#832)` | ipc/shm literals |
| `_generate_resolved_compose: carries the [lifecycle] watchdog env into the field service (#840)` | - |
| `_generate_resolved_compose: no environment: block when the watchdog is off and gui is off (#840)` | - |
| `_generate_resolved_compose: gui X11 and the watchdog share one environment: header (#840)` | - |
| `_generate_resolved_compose: restart defaults to unless-stopped, an explicit policy wins (#840)` | - |
| `_generate_resolved_compose: a malformed [lifecycle] restart falls back to the field default (#840)` | - |
| `_generate_deploy_launcher: writes an executable up/down/logs launcher (#832)` | launcher shape |
| `_generate_deploy_launcher: a no-arg invocation defaults to up without a set -e early exit (#832)` | no-arg default up |
| `_generate_deploy_launcher: generated launcher is ShellCheck-clean (#832)` | shellcheck-clean output |
| `_bake_config_copy: splices COPY config/app into the target stage (#506/#504)` | config COPY bake |
| `_bake_config_copy: handles src == out in place (#506/#504)` | in-place bake |
| `_generate_deploy_bundle: dry-run plans build (versioned image) + save + xz + install (#832)` | bundle plan |
| `_generate_deploy_bundle: dry-run builds from the baked Dockerfile when [environment] is set (#832/#503)` | env-bake build |
| `_generate_deploy_bundle: dry-run plans a docker cp per tunable-manifest path (#833)` | tunable extract |
| `_generate_deploy_bundle: a malformed manifest fails loud before building (#833)` | fail-loud guard |
| `_generate_deploy_bundle: fails loud when the image bakes no file at a declared tunable path (#833)` | missing baked default |
| `_setup_deploy: --dry-run previews the resolved compose + prints the build plan (#832)` | deploy dry-run |
| `_setup_deploy: the preview shows each tunable bind at its declared access (#870)` | preview matches the bundle |
| `_setup_deploy: refuses while .setup.conf.local is present (#893)` | - |
| `_setup_deploy: --allow-local-override proceeds and says what it accepted (#893)` | - |
| `_setup_deploy: no refusal when there is no local override (#893)` | - |
| `_render_deploy_readme: records the untracked sections a bundle was built from (#893)` | - |
| `_render_deploy_readme: says nothing about local overrides when there were none (#893)` | - |
| `_generate_deploy_bundle: hands the untracked sections to the bundle README (#893)` | - |
| `_setup_deploy: refuses in a non-interactive shell without -y (#832)` | non-tty refuse |
| `_setup_deploy: errors when the repo has no Dockerfile (#832)` | no-Dockerfile guard |
| `_setup_deploy: rejects an unknown flag (#832)` | arg validation |
| `_setup_deploy: --stage selects the target stage (#832/#841)` | stage select |
| `_setup_deploy: refuses a template-baseline stage (#841)` | stage eligibility (baseline) |
| `_setup_deploy: refuses a legacy baseline alias (#841)` | stage eligibility (legacy alias) |
| `_setup_deploy: refuses a downstream-shaped <x>-test stage (#841)` | stage eligibility (*-test) |
| `_setup_deploy: a refused stage writes no bundle even with -y (#841)` | guard fires before build |
| `main deploy routes to _setup_deploy (#832 dispatch)` | dispatch wiring |
| `_resolve_deploy_context: warns when the legacy [deploy] runtime key is present but shadowed (#876)` | - |

### test/bats/unit/deploy_hint_spec.bats (5)

Covers the "regenerate this artifact" hints stamped into what the deploy
generator emits -- the resolved `compose.yaml` header and the `deploy.sh`
launcher -- plus the sibling hint in the shipped `dist/deploy/cd-guard.sh`
(#843). The hints used to print a bare positional stage, which
`_setup_deploy` rejects as an unknown arg, so the printed command failed
when copy-pasted; these specs replay the emitted hint's own argument list
through the real parser instead of asserting a hand-copied duplicate.

| Test | Description |
|------|-------------|
| `resolved compose header hint uses --stage, not a bare positional stage (#843)` | compose header hint |
| `deploy.sh launcher hint uses --stage, not a bare positional stage (#843)` | launcher hint |
| `cd-guard.sh documents the --stage form of the deploy command (#843)` | cd-guard hint |
| `the compose-header hint's args are accepted by the deploy arg parser (#843)` | hint replayed through parser |
| `the launcher hint's args are accepted by the deploy arg parser (#843)` | hint replayed through parser |

### test/bats/unit/deploy_manifest_spec.bats (16)

Covers the per-component tunable-config manifest primitives (#833;
ADR-00000023 sec.5): `_parse_deploy_manifest` (a committed,
downstream-owned `config/<component>/deploy.manifest` declaring the
container-internal paths an operator may override per stage) and
`_collect_deploy_binds` (aggregating every component's declarations by
basename, the name the file takes in the bundle `config/` + its compose
bind). base delivers files; it does not parse content. A missing manifest
is nothing-tunable (fail-safe); a malformed manifest, or a duplicate
basename across components, fails loud. Each declaration also carries an
access mode (#870): no flag means read-only, `rw` opts that one path into
container writes, and any other trailing token is malformed -- reported
with file and line, never skipped and never downgraded in silence.

| Test | Description |
|------|-------------|
| `_parse_deploy_manifest: returns only the requested stage's paths (tunable-manifest)` | per-stage selection |
| `_parse_deploy_manifest: a path unlisted for the stage stays baked-only (tunable-manifest)` | unlisted = baked |
| `_parse_deploy_manifest: skips blank + comment lines and trims whitespace (tunable-manifest)` | lexing |
| `_parse_deploy_manifest: an unflagged path is read-only, an explicit rw opts in (tunable-manifest)` | access mode: ro default, rw opt-in |
| `_parse_deploy_manifest: an explicit ro flag is accepted (tunable-manifest)` | the default spelled out |
| `_parse_deploy_manifest: an unknown access flag fails loud naming file and line (tunable-manifest)` | bad flag, not a silent skip |
| `_parse_deploy_manifest: a trailing token after a valid flag fails loud (tunable-manifest)` | one flag only |
| `_parse_deploy_manifest: a missing manifest is not an error -> empty (tunable-manifest)` | missing = empty |
| `_parse_deploy_manifest: a malformed section header fails loud (tunable-manifest)` | bad section |
| `_parse_deploy_manifest: a non-absolute content line fails loud (tunable-manifest)` | non-absolute path |
| `_parse_deploy_manifest: a path before any section fails loud (tunable-manifest)` | orphan path |
| `_collect_deploy_binds: aggregates every component's stage paths keyed by basename (tunable-manifest)` | aggregation |
| `_collect_deploy_binds: carries each path's access mode keyed by basename (tunable-manifest)` | mode aggregation |
| `_collect_deploy_binds: no manifests -> empty map (nothing tunable) (tunable-manifest)` | nothing tunable |
| `_collect_deploy_binds: duplicate basename across components fails loud (tunable-manifest)` | basename collision |
| `_collect_deploy_binds: propagates a malformed manifest failure (tunable-manifest)` | fail propagation |

### test/bats/unit/compose_logging_spec.bats (19)

Covers `[logging]` + `[logging.<svc>]` support in
`generate_compose_yaml` (#310). Tests the global emission on every
service (devel / test / auto-emitted stage), back-compat for repos
not yet declaring `[logging]`, per-service override key-level merge
behaviour, and the two new setup.sh helpers `_parse_logging_svc_sections`
+ `_collect_logging`.

| Test | Description |
|------|-------------|
| `generate_compose_yaml omits logging: block when both inputs empty (back-compat)` | Empty inputs no-op |
| `generate_compose_yaml emits logging: block on devel from global [logging]` | Global → devel |
| `generate_compose_yaml test service inherits global logging via extends:devel (#493)` | Global logging emitted once on devel; test inherits via extends |
| `generate_compose_yaml driver-only [logging] omits options: block` | No rotation keys |
| `generate_compose_yaml partial options emits only set keys` | Sparse override |
| `generate_compose_yaml per-svc [logging.<svc>] overrides global key on that svc` | Override semantics |
| `generate_compose_yaml per-svc [logging.<svc>] inherits keys absent in override` | Key-level merge |
| `local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)` | Mount + env on devel |
| `local_path empty omits mount + env (back-compat) (#328)` | Empty fallback |
| `local_path emits CONTAINER_LOG_KEEP/DAYS retention env, default fallback (#805)` | - |
| `local_path retention env honors container_log_keep/days overrides (#805)` | - |
| `local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)` | Per-service emit |
| `local_path absolute path is passed through verbatim (#328)` | Absolute path |
| `local_path is NOT emitted as a logging.options key (driver-only options) (#328)` | local_path NOT a docker option |
| `local_path on test service emits standalone volumes block + env (#328)` | test service |
| `setup.conf [logging] comment block references in-image helper path (/usr/local/lib/base/, #368)` | Documented adoption path matches in-image COPY |
| `generate_compose_yaml emits per-stage LOG_FILE_PATH on extends:devel stage when [logging] local_path is set (#367)` | Per-svc LOG_FILE_PATH on auto-emitted extends-only stage |
| `generate_compose_yaml emits per-stage volume mount on extends:devel stage when [logging] local_path is set (#367)` | Per-svc volume mount on auto-emitted extends-only stage |
| `generate_compose_yaml does NOT emit LOG_FILE_PATH on extends:devel stage when [logging] local_path is unset (#367 back-compat)` | Zero-diff back-compat when feature unset |

### test/bats/unit/conf_logging_spec.bats (9)

Unit tests for the logging-config collectors (`_parse_logging_svc_sections`
/ `_collect_logging`): per-service `[logging.<svc>]` enumeration in file
order, plain `[logging]` global handling, and empty-when-absent behaviour.

| Test | Description |
|------|-------------|
| `_parse_logging_svc_sections enumerates services in file order` | File-order service enumeration |
| `_parse_logging_svc_sections ignores plain [logging] section` | Global section not a service |
| `_parse_logging_svc_sections returns empty when file does not exist` | Missing-file empty |
| `_collect_logging reads global [logging] from per-repo setup.conf` | Global logging read |
| `_collect_logging reads per-service [logging.<svc>] sections` | Per-service logging read |
| `_collect_logging: .setup.conf.local replaces the [logging] section (#893)` | - |
| `_collect_logging: .setup.conf.local supplies a [logging.<svc>] override (#893)` | - |
| `_collect_logging ignores an ambient SETUP_CONF (#893 decision 7)` | - |
| `_collect_logging returns empty when no [logging] sections anywhere` | No-config empty |

### test/bats/unit/entrypoint_logging_spec.bats (12)

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
| `entrypoint_logging writes a per-start file + points the stable symlink at it (#805)` | - |
| `entrypoint_logging second start adds a new per-start file + repoints symlink, keeps the old (#805)` | - |
| `entrypoint_logging same wall-clock second: second start bumps suffix, never truncates the first (#805)` | - |
| `entrypoint_logging captures stderr along with stdout in the per-start file (#328)` | 2>&1 redirect |
| `entrypoint_logging creates parent dir if missing (#328)` | mkdir -p safety net |
| `entrypoint_logging retention honors CONTAINER_LOG_KEEP, never the symlink (#805)` | - |
| `entrypoint_logging retention honors CONTAINER_LOG_DAYS by age (#805)` | - |
| `entrypoint_logging clamps a non-positive CONTAINER_LOG_KEEP back to the default (#805)` | - |
| `entrypoint_logging bumps past an occupied base per-start name, still tees (#805)` | - |
| `entrypoint_logging warns 'cannot create' + continues when parent dir is unmakeable (#691)` | mkdir-fail branch (parent is a regular file) |
| `entrypoint_logging warns 'tee binary missing' + continues when tee absent (#691)` | tee-missing branch (stub PATH) |

### test/bats/unit/watchdog_spec.bats (18)

Pure-logic (kcov-safe) unit tests for
`dist/script/docker/runtime/watchdog.sh` (#797), the generic
single-service watchdog sourced from a repo entrypoint (sibling of
`logging.sh`). Covers the master off switch (no-op when `WATCHDOG_CHECK`
unset), config load defaults + clamping, the pluggable health-check
runner (pass / fail / timeout), the shared `_watchdog_evaluate` decision
seam (healthy reset / under-threshold / act), the `_watchdog_grace`
bounded stop window, `_watchdog_pgid_of` / `_watchdog_child_alive`
liveness helpers, the `WATCHDOG_NOTIFY` give-up hook, and the
`watchdog.log` per-start file + symlink under a `watchdog/` subdir
(reusing `logrotate.sh`). The process-level supervision loops + signal
paths live in `watchdog_supervision_spec.bats`.

### test/bats/unit/watchdog_supervision_spec.bats (7)

Process-level supervision tests for the watchdog (#797): the
`restart-container` monitor loop, the `restart-service` supervisor, and
the real signal / process-group teardown paths -- bounded
SIGTERM → grace → SIGKILL (a SIGTERM-ignoring service is killed within the
grace, no unbounded-`wait` hang), whole-subtree kill via `setsid` (no
orphaned grandchild leaks per restart), give-up against a wedged service
still reaching container-exit, and the `docker stop` SIGTERM forward to
the service group. These drive real background processes / sleeps /
signals, so the file is **kcov-fragile** (each test carries the
`[ "${COVERAGE:-0}" = 1 ] && skip` guard; it runs plain under
`bats-fragile`, ADR-00000008 / #613 / #677).

### test/bats/unit/compose_watchdog_spec.bats (6)

Tests for `[lifecycle]` watchdog (#797) support in
`generate_compose_yaml` and its resolution in `_resolve_deploy_context`:
the `WATCHDOG_*` service environment is emitted (YAML-quoted) only when
the master switch `watchdog_check` is set, so the default-off case leaves
`compose.yaml` byte-identical (the #505 golden is unaffected); the env
rides on devel and extends:devel stages inherit it; and the resolver
builds the env block only for the knobs the conf sets.

### test/bats/unit/template_spec.bats (154)

| Test | Description |
|------|-------------|
| `build.sh exists and is executable` | File check |
| `run.sh exists and is executable` | File check |
| `exec.sh exists and is executable` | File check |
| `stop.sh exists and is executable` | File check |
| `setup.sh exists and is executable` | File check |
| `test.sh exists and is executable` | File check |
| `test.sh uses set -euo pipefail` | Shell convention |
| `justfile.test exists (template CI gate)` | File check |
| `Makefile.ci no longer exists (retired for justfile.test)` | File absence (single runner) |
| `justfile.test default recipe runs the suite (bare just test)` | just recipe |
| `justfile.test has lint recipe` | just recipe |
| `justfile.test lint recipe forwards args + runs all linters by default (#650)` | `lint *args` forwards --shellcheck/--hadolint |
| `justfile.test has coverage recipe` | just recipe |
| `justfile.test carries no stale init/upgrade recipes at nonexistent root scripts (#779)` | - |
| `dist smoke test_helper.bash exists under shared/` | Directory structure |
| `dist smoke shared entrypoint spec exists under shared/` | Directory structure |
| `dist smoke script_help.bats exists under devel-test/` | Directory structure |
| `dist smoke display_env.bats exists under devel-test/` | Directory structure |
| `old flat dist/test/smoke/ layout is gone` | Directory structure |
| `test/bats/unit/ directory exists` | Directory structure |
| `doc/readme/ directory exists` | Directory structure |
| `doc/test/ directory exists` | Directory structure |
| `doc/changelog/ directory exists` | Directory structure |
| `lib/wrapper.sh references .base/dist/script/docker/wrapper/setup.sh (#565)` | - |
| `build.sh + run.sh route setup/drift through _wrapper_setup_sync (#565)` | - |
| `build.sh uses set -euo pipefail` | Shell convention |
| `build.sh supports --no-cache flag` | Force rebuild flag |
| `build.sh passes --no-cache to docker compose build when set` | NO_CACHE forwarded |
| `build.sh keeps test-tools image by default (cleanup gated by CLEAN_TOOLS)` | Default keep tools |
| `build.sh supports --clean-tools flag` | Clean tools flag |
| `build.sh removes test-tools image when --clean-tools is set` | CLEAN_TOOLS forwarded |
| `run.sh uses set -euo pipefail` | Shell convention |
| `exec.sh uses set -euo pipefail` | Shell convention |
| `stop.sh uses set -euo pipefail` | Shell convention |
| `lib/compose.sh is the ONLY producer of a project name (#893)` | - |
| `exec.sh loads .env via _load_env helper` | Uses shared lib |
| `stop.sh loads .env via _load_env helper` | Uses shared lib |
| `lib/env.sh defines _load_env helper` | - |
| `lib/compose.sh defines _compute_project_name helper` | - |
| `lib/compose.sh defines _compose wrapper` | - |
| `stop.sh no longer needs orphan cleanup (run.sh devel uses up not run)` | No more orphan |
| `run.sh devel target uses compose up -d (not compose run --name)` | up + exec model |
| `run.sh devel branch uses compose exec to enter shell` | up + exec model |
| `run.sh non-devel TARGET: foreground 'up', CMD-override 'run --rm' (#458/#679)` | One-shot stages: no-CMD up, CMD run --rm |
| `run.sh devel branch does not use 'compose run --name'` | Old pattern gone |
| `run.sh refuses when the default container is already running` | collision |
| `base is single-instance: no --instance flag remains (#600)` | single-instance (no flag) |
| `base is single-instance: no INSTANCE_SUFFIX remains (#600)` | single-instance (no suffix) |
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
| `dist/script/docker/lib/i18n.sh exists` | - |
| `Dockerfile.test-tools includes bats-mock` | bats-mock available in test image |
| `Dockerfile.test-tools installs just (justfile entry-point execution in CI)` | - |
| `Dockerfile.test-tools source-builds kcov in a builder stage (#686)` | kcov compiled from source (not in alpine repos) |
| `Dockerfile.test-tools COPYs the kcov binary into the final image (#686)` | kcov binary present in final image |
| `Dockerfile.test-tools installs kcov's runtime shared libs in the final stage (#686)` | kcov runtime libs (libstdc++/libcurl/libdw/...) present |
| `Dockerfile.test-tools no longer installs make into the final image (single runner: just)` | dead make dependency stays out of final image |
| `Dockerfile.test-tools declares ARG TARGETARCH` | - |
| `Dockerfile.test-tools ARG TARGETARCH has no default value (must not shadow BuildKit auto-inject)` | multi-arch build regression |
| `Dockerfile.test-tools curl release downloads retry on transient failure (#550)` | - |
| `Dockerfile.test-tools branches case for amd64 and arm64` | - |
| `Dockerfile.test-tools fails loud on unsupported TARGETARCH` | - |
| `i18n.sh defines _detect_lang function` | _detect_lang in i18n.sh |
| `build.sh sources _lib.sh` | build.sh uses shared lib |
| `run.sh sources _lib.sh` | run.sh uses shared lib |
| `exec.sh sources _lib.sh` | exec.sh uses shared lib |
| `stop.sh sources _lib.sh` | stop.sh uses shared lib |
| `_lib.sh sources i18n.sh (delegates language detection)` | _lib delegates i18n |
| `setup.sh sources i18n.sh` | setup.sh uses shared i18n |
| `build.sh -h works in /lint/ layout (flat dir with _lib.sh + i18n.sh, issue #104)` | - |
| `run.sh -h works in /lint/ layout` | - |
| `exec.sh -h works in /lint/ layout` | - |
| `stop.sh -h works in /lint/ layout` | - |
| `build.sh errors with a clear diagnostic when bootstrap/_lib.sh missing (issue #104, #408)` | - |
| `Dockerfile.example copies lib/ and wrapper/ into /lint/ (#406)` | - |
| `Dockerfile.example copies logging.sh to /usr/local/lib/base/ in devel stage (#368)` | - |
| `Dockerfile.example commented runtime stage shows logging.sh COPY example (#368)` | - |
| `runtime/logging.sh header documents in-image source-line (no $USER, no work/.base) (#368)` | - |
| `Dockerfile.example copies logrotate.sh to /usr/local/lib/base/ in devel stage (#805)` | - |
| `Dockerfile.example copies watchdog.sh to /usr/local/lib/base/ in devel stage (#797)` | - |
| `Dockerfile.example commented runtime stage shows watchdog.sh COPY example (#797)` | - |
| `runtime/entrypoint.sh sources the watchdog helper after logging (#797)` | - |
| `runtime/entrypoint.sh guards both lib sources with a readability test (#842)` | Both source lines wrapped in `[[ -r ]]`, matching the logrotate.sh pattern |
| `runtime/entrypoint.sh execs cleanly under set -euo pipefail with the libs absent (#842)` | Opt-out runtime image: reaches `exec`, no stderr, no strict-mode abort |
| `Dockerfile.example commented runtime stage shows logrotate.sh COPY example (#805)` | - |
| `no inline _detect_lang fallbacks remain after dedupe (issue #104)` | - |
| `setup.sh does not redefine _detect_lang` | No duplication |
| `setup.sh defines _setup_msg, not _msg (closes #101)` | - |
| `build.sh _msg keys survive sourcing setup.sh (#101 behavioral)` | - |
| `build.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `run.sh does not source setup.sh (#49 Phase B-1)` | structural guard for #101 class |
| `lib/wrapper.sh uses subprocess check-drift (#49 Phase B-1, #565)` | - |
| `.version file exists in template root` | Version file check |
| `upgrade.sh reads version from <subtree-prefix>/.version` | - |
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
| `build-worker.yaml: devel-test build passes TEST_TOOLS_IMAGE from inputs` | - |
| `Dockerfile.example has ARG TEST_TOOLS_IMAGE with no bare test-tools:local default` | version-scoped tag: no bare-tag ARG default (#828) |
| `Dockerfile.example FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` | named stage alias |
| `Dockerfile.example test stage copies from test-tools-stage, not test-tools:local` | stage rename migration |
| `Dockerfile.example runtime-test shows commented Bats COPY from test-tools-stage (#647)` | generalized -test toolchain (style (b) Bats smoke) |
| `Dockerfile.example documents -test stages stay FROM the real stage + heavier-is-fine (#647)` | anti-pattern guard + consumer-owns-flavour-tools |
| `Dockerfile.example states the /opt-not-$HOME baking convention (#799)` | - |
| `build-worker.yaml: runtime-test build forwards TEST_TOOLS_IMAGE (#647 prerequisite)` | runtime-test COPY --from=test-tools-stage needs the pinned image too |
| `Dockerfile.example runtime-test uses bash -c wrapper (regression: #243 word-split + #57 dash-source bugs)` | - |
| `Dockerfile.example runtime-test does NOT use bare RUN ${RUNTIME_SMOKE_CMD} (v0.21.0 word-split regression guard)` | - |
| `Dockerfile.example runtime-test does NOT use sh -c wrapper (v0.21.1 -> v0.23.1 dash-source regression guard)` | - |
| `Dockerfile.example runtime-test does NOT set USER root (DL3002 regression guard)` | - |
| `Dockerfile.example top stage-list documents builder stage (#239)` | - |
| `Dockerfile.example documents 3 builder/runtime split lessons (#239)` | - |
| `Dockerfile.example has commented-out builder + runtime + COPY --from=builder reference (#239)` | - |
| `Dockerfile.example runtime documents 3-process-kinds env rationale (#657)` | PID 1 / interactive / non-interactive complementary mechanisms |
| `Dockerfile.example runtime shows commented /etc/bash.bashrc source example (#657)` | opt-in interactive-exec env source, consumer supplies ROS line |
| `Dockerfile.example runtime does NOT bake ROS env into ENV (#657 fragility guard)` | no ENV LD_LIBRARY_PATH / PYTHONPATH baked |
| `template no longer ships dockerfile/setup/ (#407, reverses #261)` | - |
| `template no longer ships config/pip/ (#261 relocation regression guard)` | - |
| `Dockerfile.example has no SETUP_DIR or pip references (#407)` | - |
| `Dockerfile.example declares ENV TZ (matches downstream fleet, #210)` | runtime $TZ alignment |
| `Dockerfile.example declares ENV LANGUAGE=en_US:en (matches downstream fleet, #210)` | runtime $LANGUAGE alignment |
| `release-test-tools.yaml exists and pushes to ghcr.io/ycpss91255-docker/test-tools` | GHCR publisher |
| `release-test-tools.yaml declares packages:write permission` | ghcr auth scope |
| `release-test-tools.yaml builds multi-arch (amd64 + arm64)` | arch coverage |
| `release-test-tools.yaml uses template-repo-local Dockerfile path` | no subtree path confusion |
| `release-worker.yaml does not cp compose.yaml into the release archive` | v0.10.1 cp-list regression |
| `release-worker.yaml cp-list still includes Dockerfile + scripts` | positive cp-list guard |
| `run.sh contains XDG_SESSION_TYPE check` | X11/Wayland branch |
| `run.sh contains xhost +SI:localuser for wayland` | Wayland xhost |
| `run.sh contains xhost +local: for X11` | X11 xhost |
| `setup.sh default _base_path uses /..` | Path resolution |
| `setup.sh default _base_path uses double parent traversal` | Repo root traversal |
| `all 7 wrappers call _run_pre_hook with their own name (#440)` | - |
| `all 7 wrappers call _run_post_hook with their own name (#440)` | - |
| `run.sh _app_cleanup runs post-hook before compose down (#440)` | - |
| `lib/hook.sh skips both helpers under DRY_RUN (#440, #13)` | - |
| `lib/hook.sh hard-fails on present-but-not-executable hook (#440, #11)` | - |

### test/bats/unit/bashrc_spec.bats (15)

| Test | Description |
|------|-------------|
| `defines alias_func` | Function definition |
| `defines color_git_branch` | Function definition |
| `defines ebc alias` | Alias definition |
| `defines sbc alias` | Alias definition |
| `alias_func is called` | Function call |
| `color_git_branch is called` | Function call |
| `color_git_branch sets PS1` | PS1 setting |
| `bashrc has bashrc.d bootstrap loop sourcing ~/.bashrc.d/*.sh` | - |
| `bashrc.d bootstrap loop guards on directory existing` | - |
| `bashrc.d/ directory exists in .base/dist/config/shell/` | - |
| `host-group drop-in exists` | #589 drop-in shipped |
| `host-group drop-in defines name_host_groups and invokes it only when interactive` | #589 structure |
| `host-group drop-in uses getent + sudo groupadd` | #589 mechanism |
| `name_host_groups: a nameless gid triggers sudo groupadd hostgrp<gid>` | #589 behaviour (mocked) |
| `name_host_groups: a named gid does not trigger groupadd` | #589 idempotent skip (mocked) |

### test/bats/unit/ci_spec.bats (107)

| Test | Description |
|------|-------------|
| `_run_shellcheck: invokes shellcheck against every expected script` | Wired-file regression guard |
| `_run_shellcheck: picks up every .sh file in script/docker/` | `find` covers new scripts |
| `_run_shellcheck: picks up every .sh file in script/test/ (#876)` | - |
| `_run_shellcheck: exits non-zero when shellcheck fails on any script` | Strict-mode propagation |
| `_run_lint_tool: names the tool and the signal when a driver dies of SIGPIPE (#898)` | 141 reported as tool + command + SIGPIPE |
| `_run_lint_tool: names the tool when a driver fails without a signal (#898)` | Plain non-zero abort still names the tool |
| `_run_lint_tool: a clean driver reports nothing and leaves no ERR trap armed (#898)` | Silent on success, trap disarmed after |
| `_run_via_compose: routes default mode to the ci service with COVERAGE=0` | Service routing — fast path |
| `_run_via_compose: routes coverage mode to the coverage service with COVERAGE=1` | Service routing — coverage path |
| `main: dispatches no-flag default to the ci service` | End-to-end default dispatch |
| `_run_tests: passes --jobs N when parallel is on PATH` | Parallel-present branch |
| `_run_tests: omits --jobs when parallel is absent (graceful fallback)` | Parallel-missing branch |
| `main: dispatches --coverage to the coverage service` | End-to-end --coverage dispatch |
| `_shard_unit_files: a single shard returns real unit spec paths (#615)` | #615 coverage shard returns spec paths |
| `_shard_unit_files: partition is exhaustive + disjoint across all shards of T (#615, #724)` | #615 partition invariant (each slice runs once) |
| `_shard_unit_files: greedy weight-balance keeps no shard wildly above the @test average (#677)` | #677 greedy bin-packing balances shards |
| `_shard_unit_files: rejects an out-of-range shard spec (#615, #692)` | #615 shard-spec validation (asserts message) |
| `_shard_unit_files: rejects a no-slash shard spec (#692)` | #692 missing-slash format guard |
| `_shard_unit_files: rejects a non-numeric shard spec (#692)` | #692 non-numeric guard |
| `_shard_unit_files: dies ci_empty_shard when a valid shard matches no files (#692)` | #692 empty-slice guard |
| `_spec_weight: returns the recorded seconds from SHARD_WEIGHTS_FILE (#724)` | - |
| `_spec_weight: falls back to @test count when the spec has no recorded time (#724)` | - |
| `_spec_weight: falls back to @test count when no SHARD_WEIGHTS_FILE is set (#724)` | - |
| `_spec_weight: reads the default repo weights file when SHARD_WEIGHTS_FILE is unset (#733)` | - |
| `_shard_unit_files: partitions by recorded time when SHARD_WEIGHTS_FILE is set (#724)` | - |
| `_junit_to_timings: emits <seconds> <basename> per testsuite, rounded and floored at 1 (#733)` | - |
| `_junit_to_timings: ignores the <testsuites> root and a missing file is a no-op (#733)` | - |
| `_run_coverage: writes coverage/timings.tsv from the bats junit report (#733)` | - |
| `_shard_unit_files: integration specs are partitioned into the pool, not pinned to one shard (#724)` | - |
| `_run_coverage: shard N/T kcov's only that unit slice, not the whole tree (#615)` | #615 sharded kcov targets |
| `_run_coverage: shard targets are individual spec files, never the whole integration dir (#724)` | - |
| `_run_coverage: no argument keeps the full-suite path (unit + integration) (#615)` | #615 local full-coverage path |
| `main --coverage-shard: routes to the coverage service with COVERAGE_SHARD set (#615)` | #615 shard env plumbing |
| `main --ci with COVERAGE=1 skips the lint phase (lint is a separate matrix concern) (#615)` | #615 coverage path skips lint |
| `main --coverage-shard + --bats-path is rejected (coverage mode guard) (#615)` | #615 single-path/coverage combo guard |
| `_fragile_unit_files: returns exactly the spec files with a kcov-skip guard (#677)` | #677 runtime fragile-set == anchored grep |
| `_fragile_unit_files: every kcov-skipped file is in the fragile set (no unit test goes unrun) (#677)` | #677 inverse-direction completeness guard |
| `_run_bats_fragile: runs bats over only the fragile spec files, not the whole unit tree (#677)` | #677 fragile job targets only fragile files |
| `_run_bats_fragile: does NOT set COVERAGE=1 so the kcov-skip guards fall through (#677)` | #677 plain mode runs the skipped tests |
| `main --bats-fragile: routes to the ci service with BATS_FRAGILE=1 + BATS_ONLY=1, no COVERAGE (#677)` | #677 fragile flag dispatch |
| `main --bats-path: dispatches a single spec to the ci service with BATS_FILE + BATS_ONLY=1` | #523 single-file dispatch |
| `main --bats-path: accepts a directory` | #523 directory path |
| `main --bats-path: non-existent path dies with ci_bats_path_not_found` | #523 missing-path guard |
| `main --bats-path: test/bats/system/ path dies with a clear hint` | #523 system guard |
| `main --bats-path + --coverage is rejected (ci_bats_path_coverage)` | #523 coverage-combo guard |
| `_run_coverage_path: writes nothing into the checkout's coverage/ (#887)` | The gate's artifacts stay untouched -- no figure can be fabricated from one spec |
| `_run_coverage_path: the kcov report dir is a throwaway outside the checkout, removed after the run (#887)` | Report lands in container-local scratch and is deleted |
| `_run_coverage_path: kcov's exactly the named spec, never a shard slice (#887)` | Shard independence: a planted .shard-weights pulls in nothing |
| `_run_coverage_path: instruments with the same include/exclude set a coverage shard uses (#887)` | Same instrumented tree as a shard, so the failure reproduces |
| `_run_coverage_path: propagates the spec's exit status so a red spec is a red run (#887)` | Exit-status propagation -- the loop is useless if failure is swallowed |
| `_run_coverage_path: BATS_FILTER appends a bats -f name filter (#887)` | Composes with --filter to instrument a single @test |
| `main --coverage-path: routes one spec to the coverage service with COVERAGE_PATH + BATS_ONLY=1 (#887)` | Dispatch: coverage service, COVERAGE_PATH plumbed, never a shard |
| `main --ci: COVERAGE=1 with COVERAGE_PATH runs the one spec and reports no coverage figure (#887)` | In-container branch sits ahead of _run_coverage; no report line |
| `main --coverage-path: non-existent path dies before docker is called (#887)` | Host-side missing-path guard |
| `main --coverage-path: test/bats/system/ dies with the ci-system hint (#887)` | Host-side system-spec guard (needs the ci-system service) |
| `main --coverage-path + --coverage-shard is rejected (#887)` | A figure over a partition and one instrumented spec are different asks |
| `main --coverage-path + --bats-path is rejected (#887)` | Two runners, two services -- refused by name |
| `main --bats-path + --coverage stays rejected: the fast loop is still kcov-free (#887)` | #523's refusal is intact; the combination is --coverage-path |
| `main: unknown option dies with ci_unknown_option (#692)` | #692 unknown-flag guard |
| `main: --hadolint without --lint dies (narrowing flag, not standalone) (#692)` | #692 narrowing-flag typo guard |
| `main --ci: unknown LINT_TOOL dies with ci_unknown_lint_tool (#692)` | #692 LINT_TOOL validation |
| `main --ci: LINT_TOOL=stale-setup-conf runs the stale setup.conf lint (#845)` | #845 stale setup.conf lint reaches the CI gate |
| `main --ci: LINT_TOOL=readme-sync runs the localized README sync lint (#846)` | #846 localized README sync lint reaches the CI gate |
| `main --ci: LINT_TOOL=doc-counts runs the doc/test count drift gate (#864)` | #864 doc/test count drift gate reaches the CI gate |
| `main --doc-counts-only: runs the drift gate on the host, no compose (#864)` | #864 host-direct primitive so a CI job can run the gate without compose |
| `main --issueref-only: runs the issue-ref comment lint on the host, no compose (#866)` | - |
| `main --adr-numbering-only: runs the ADR-numbering lint on the host, no compose (#866)` | - |
| `main --stale-setup-conf-only: runs the stale setup.conf path lint on the host, no compose (#866)` | - |
| `main --home-literal-only: runs the hardcoded home path lint on the host, no compose (#799)` | - |
| `main --readme-sync-only: runs the localized README sync lint on the host, no compose (#866)` | - |
| `main: _LINT_TOOLS is the one table every lint-phase caller dispatches through (#866)` | - |
| `main --filter: dispatches with BATS_FILTER + BATS_ONLY=1 and no BATS_FILE` | #523 filter-only dispatch |
| `_run_bats_path: BATS_FILE runs bats on that path; BATS_FILTER appends -f` | #523 single-path runner |
| `_run_bats_path: filter-only runs bats across unit + integration` | #523 filter-only runner |
| `drivers: bats.sh, shellcheck.sh and hadolint.sh driver files exist` | #650 driver files present (incl. hadolint) |
| `drivers: test.sh sources all per-tool drivers` | #650 dispatcher sources every driver |
| `drivers: the bats runners live in drivers/bats.sh, not test.sh` | #650 bats runners moved out |
| `drivers: _run_shellcheck lives in drivers/shellcheck.sh, not test.sh` | #650 shellcheck moved out |
| `drivers: _run_hadolint lives in drivers/hadolint.sh, not test.sh (#650)` | #650 hadolint in its driver |
| `drivers: are sourced libraries (no top-level main invocation)` | #650 driver is a library |
| `drivers: _run_shellcheck also lints the driver files themselves` | #650 driver self-shellcheck |
| `_run_hadolint: lints every Dockerfile in the tree with the shared config` | #650 single-source Dockerfile list + config |
| `_run_hadolint: the linted list is every Dockerfile the tree carries` | A Dockerfile added beside the others and never added to the list is a Dockerfile no lint pass names |
| `_run_hadolint: invokes hadolint once per Dockerfile (no extra targets)` | #650 one invocation per listed Dockerfile |
| `_run_hadolint: dies with a clear message when hadolint is absent` | #650 host-missing-binary guard |
| `_run_hadolint: exits non-zero when hadolint fails on any Dockerfile` | #650 propagates lint failure |
| `_system_setup: dies ci_no_docker_socket when the docker socket is absent (#692)` | #692 system socket guard |
| `_system_setup: dies ci_no_docker_cli when docker is not on PATH (#692)` | #692 system docker-CLI guard |
| `_resolve_test_tools_image: different tooling inputs resolve to different tags (#891)` | #891 content-keyed local tag cannot clobber |
| `_resolve_test_tools_image: identical inputs at different paths resolve to the same tag (#891)` | #891 same inputs -> cache hit, not a rebuild |
| `_resolve_test_tools_image: TEST_TOOLS_IMAGE wins verbatim (#891)` | #891 CI's pinned published tags untouched |
| `_resolve_test_tools_image: fails loud when the tooling Dockerfile is missing (#891)` | #891 no silent bare-literal fallback |
| `main --test-tools-image: prints the resolved tag for the justfile (#891)` | #891 one entry point for build + consumers |
| `_compute_compose_project_name: two checkouts sharing a basename get different names (#891)` | #891 path-keyed, not directory-basename |
| `_compute_compose_project_name: the same checkout path is stable across calls (#891)` | #891 one project per checkout, no per-commit churn |
| `_compute_compose_project_name: a hostile checkout path still yields a legal project name (#891)` | #891 compose grammar guaranteed, not hoped for |
| `_resolve_compose_project_name: COMPOSE_PROJECT_NAME wins verbatim (#891)` | #891 env override still wins |
| `_run_via_compose: passes an explicit -p so the project is not the directory basename (#891)` | #891 the missing -p is the defect |
| `_run_via_compose: honours COMPOSE_PROJECT_NAME (#891)` | #891 -p forwards the caller's name |
| `_run_via_compose: hands compose the very tag the tooling resolver prints (#896)` | #896 one derivation, exported for interpolation |
| `_ensure_test_tools_image: builds the derived tag when the host does not have it (#896)` | #896 a local-only tag absent means not built, not pull |
| `_ensure_test_tools_image: leaves a caller-pinned image alone (#896)` | #896 CI provisions its own |
| `_ensure_test_tools_image: does not rebuild a tag the host already has (#896)` | #896 identical inputs are a cache hit |
| `main --compose-project-name: prints the resolved project for the justfile (#891)` | #891 one entry point for both call sites |
| `_compute_compose_project_name: fails loud when the digest cannot be produced (#891)` | #891 no silent degrade to the shared bare prefix |
| `_run_via_compose: the real ids are in the environment compose interpolates (#895)` | - |
| `_fix_permissions: refuses a non-numeric id instead of handing it to chown (#895)` | - |

### test/bats/unit/doc_counts_spec.bats (21)

Unit coverage for `script/test/sync-doc-counts.sh` (`_sync_doc_counts`) -- the
generator that derives the `doc/test/*.md` count figures from the specs
(`grep -c '^@test'`) so they stop being hand-edited. The
`check_test_md_drift.sh` hook stays the validating safety net.

| Test | Description |
|------|-------------|
| `_sync_doc_counts: rewrites a stale ### heading to the real @test count (#727)` | per-spec heading recompute |
| `_sync_doc_counts: rewrites a stale #### (level-4) heading too (#815)` | #815 deeper ATX depth regenerated, not just ### |
| `_sync_doc_counts: rewrites the per-type total to the sum of the headings (#727)` | per-type total from grep-over-files |
| `_sync_doc_counts: is idempotent on an already-synced tree (#727)` | re-run no-op |
| `_sync_doc_counts: rewrites the system per-type total from test/bats/system/ (#782)` | - |
| `_sync_doc_counts: tolerates an empty acceptance dir (count 0, no error) (#782)` | - |
| `_sync_test_md_index: fills the system + acceptance rows, retires behavioural (#782)` | - |
| `_sync_test_md_index: regenerates the blockquote prose System/smoke pair (#843)` | - |
| `_sync_catalog_rows: generates a row for every @test the table is missing (#859)` | - |
| `_sync_catalog_rows: a hand-written description survives regeneration (#859)` | - |
| `_sync_catalog_rows: the row of a deleted test goes away (#859)` | - |
| `_sync_catalog_rows: a renamed test is a delete plus an add, prose does not follow (#859)` | - |
| `_sync_catalog_rows: rows follow spec file order, not the old table order (#859)` | - |
| `_sync_catalog_rows: a section without a per-test table is left alone (#859)` | - |
| `_sync_catalog_rows: a heading whose spec path does not resolve is left alone (#859)` | - |
| `_sync_catalog_rows: a pipe in a test name is escaped so the table stays well formed (#859)` | - |
| `_sync_catalog_rows: backslash escapes resolve to the name bats reports (#859)` | - |
| `_sync_catalog_rows: is idempotent on an already-generated catalog (#859)` | - |
| `_sync_doc_sections: a spec file with no section at all gets one (#859)` | - |
| `_sync_doc_sections: an existing section is never duplicated (#859)` | - |
| `_sync_doc_sections: a shipped smoke spec lands in smoke.md (#859)` | - |

### test/bats/unit/issueref_lint_spec.bats (17)

| Test | Description |
|------|-------------|
| `_run_issueref: flags a bare #NNN in a leading comment` | Leading comment ref detected |
| `_run_issueref: flags a bare #NNN in a trailing comment` | Trailing comment ref detected |
| `_run_issueref: flags the (#NNN) paren form in a comment` | Parenthesised ref detected |
| `_run_issueref: flags a bare 2-digit ref (lower accept boundary) (#692)` | #692 2-digit lower bound flagged |
| `_run_issueref: flags a bare 4-digit ref (upper accept boundary) (#692)` | #692 4-digit upper bound flagged |
| `_run_issueref: flags refs in .bats helper comments (not @test names)` | Helper comment flagged, @test name kept |
| `_run_issueref: passes clean on a tree with no comment refs` | Clean tree passes |
| `_run_issueref: does NOT flag a #NNN inside a string literal` | String-literal ref kept |
| `_run_issueref: does NOT flag ADR-0000xxxx references` | ADR refs kept |
| `_run_issueref: does NOT flag DL/SC directive codes or version tags` | DL/SC/version tokens kept |
| `_run_issueref: does NOT flag word-prefixed cross-repo refs` | Cross-repo refs kept |
| `_run_issueref: does NOT flag single-digit or 5+-digit numbers` | Out-of-range numbers kept |
| `_run_issueref: does NOT treat a ${#arr[@]} expansion as a comment` | Parameter expansion kept |
| `_run_issueref: does NOT flag a #NNN opener in heredoc usage prose` | Heredoc usage prose kept |
| `_ISSUEREF_AWK: flags a 3-digit ref identically under every awk engine` | Detection parity across busybox-awk / mawk / gawk |
| `_ISSUEREF_AWK: flags the 2-digit and 4-digit accept boundaries under every awk engine (#692)` | #692 boundary parity across engines |
| `_ISSUEREF_AWK: keeps the must-keep cases clean under every awk engine` | Exemption parity across busybox-awk / mawk / gawk |

### test/bats/unit/adr_numbering_spec.bats (10)

Unit tests for `script/test/drivers/adr_numbering.sh` (`_run_adr_numbering`,
refs #808), the ADR-numbering lint. The registry is the filesystem
(`doc/adr/NNNNNNNN-<slug>.md`): the lint FAILS on a duplicate ADR number or a
malformed filename and WARNS (exit 0) on a numbering gap. Driven at the driver
CLI over throwaway fixture `doc/adr/` trees, plus a real-tree guard that the
live `doc/adr/` passes today with the intentional `00000009` gap warned.

| Test | Description |
|------|-------------|
| `_run_adr_numbering: FAILS on a duplicate ADR number, naming both files (#808)` | Duplicate number fails, both files named |
| `_run_adr_numbering: FAILS on a malformed filename, naming the file (#808)` | Malformed filename fails, file named |
| `_run_adr_numbering: FAILS on a too-short (non-8-digit) number prefix (#808)` | Non-8-digit prefix fails |
| `_run_adr_numbering: EXEMPTS doc/adr/README.md (the index), not flagged malformed (#808)` | README.md index exempt from the naming contract |
| `_run_adr_numbering: PASSES a clean set WITH a gap, warning the gap (exit 0) (#808)` | Gap warned, exit 0 |
| `_run_adr_numbering: PASSES a clean contiguous set with no gap warning (#808)` | Contiguous set clean, no gap line |
| `_run_adr_numbering: does NOT flag a gap as a duplicate or malformed (#808)` | Gaps are advisory, not failures |
| `_run_adr_numbering: an early-closing reader cannot abort the min/max scan (#898)` | No pipeline status owned by a departing reader |
| `_run_adr_numbering: min/max stay correct with sort/head unusable (#898)` | In-shell range still bounds the gap scan |
| `_run_adr_numbering: the REAL doc/adr/ passes today (00000009 gap warned) (#808)` | Live tree clean, 00000009 gap warned |

### test/bats/unit/stale_setup_conf_lint_spec.bats (11)

Unit tests for `script/test/drivers/stale_setup_conf.sh`
(`_run_stale_setup_conf`, refs #845), the "no stale
`config/docker/setup.conf` path in runtime shell code" lint. The per-repo
override and the template default now live at the repo-root `.setup.conf`
dotfile, so a hardcoded legacy path in `dist/**/*.sh` reads a location that
no longer exists and silently ignores the repo's knobs. The legacy-migration
block in `dist/script/base/upgrade.sh` is the one legitimate consumer and
opts out via explicit `allow-begin` / `allow-end` markers. Driven over
throwaway fixture `dist/` trees, plus a real-tree guard that the live
`dist/` passes today.

| Test | Description |
|------|-------------|
| `_run_stale_setup_conf: FAILS on a stale path in a dist/ script, naming file and line (#845)` | Stale path fails, file:line named |
| `_run_stale_setup_conf: names the replacement path in the failure message (#845)` | Message points at `.setup.conf` |
| `_run_stale_setup_conf: FAILS on a stale path inside a comment too (#845)` | Comments are in scope, not exempt |
| `_run_stale_setup_conf: FAILS on a stale path AFTER an allow-end (region does not leak) (#845)` | Allow region ends at the end marker |
| `_run_stale_setup_conf: FAILS on an unterminated allow-begin region (#845)` | Unbalanced begin marker fails loudly |
| `_run_stale_setup_conf: FAILS on an allow-end with no matching allow-begin (#845)` | Unmatched end marker fails loudly |
| `_run_stale_setup_conf: EXEMPTS a stale path inside an allow-begin/allow-end region (#845)` | Marked migration block exempt |
| `_run_stale_setup_conf: PASSES a dist/ tree that uses the repo-root dotfile (#845)` | `.setup.conf` tree clean |
| `_run_stale_setup_conf: ignores non-.sh files under dist/ (#845)` | Docs out of the lint's scope |
| `_run_stale_setup_conf: FAILS when the dist/ scan root is missing (no vacuous pass) (#845)` | Missing scan root fails, no vacuous pass |
| `_run_stale_setup_conf: the REAL dist/ passes today (migration block allowlisted) (#845)` | Live tree clean |

### test/bats/unit/readme_sync_spec.bats (31)

Unit tests for the localized-README drift guard (refs #846, #873):
`script/test/sync-readme-hashes.sh` (`_sync_readme_hashes`, the generator
that stamps each translated section with the hash of the English section it
was translated against AND of the translated section itself) and
`script/test/drivers/readme_sync.sh` (`_run_readme_sync`, the read-only lint
that compares those records against the current `README.md`). The English
author changes nothing and the translator never types a hash, so the guard
has to answer three questions per translated file -- is this section stale,
is it missing, is it deliberately untranslated. A fourth block PERFORMS the
silencing case (refs #873) -- edit the English, run the generator, expect a
green tree -- and asserts it does not work, because recording only the
English hash made a bare re-stamp indistinguishable from a re-translation.
Driven over throwaway fixture trees, plus a real-tree pair proving
`doc/readme/` is stamped and clean today.

| Test | Description |
|------|-------------|
| `_run_readme_sync: FAILS when an English section is rewritten in place and the translation is untouched (#846)` | The drift that motivated the guard |
| `_run_readme_sync: names the drifted SECTION, not just the file (#846)` | Per-section reporting, untouched sections silent |
| `_run_readme_sync: FAILS on an English section with no marker in a translation (#846)` | Structural case: MISSING |
| `_run_readme_sync: PASSES a tree the generator has just stamped (#846)` | Clean after sync |
| `_run_readme_sync: PASSES again after an English edit, a re-translation and a re-run of the generator (#846)` | Re-stamp is the one-command fix, once the translation moved too |
| `_run_readme_sync: EXEMPTS a section declared untranslated with sync-skip (#846)` | Deliberate omission, declared not forgotten |
| `_run_readme_sync: FAILS on an UNSTAMPED marker (id written, generator never run) (#846)` | An id with no hash claims nothing |
| `_run_readme_sync: FAILS on a marker naming an id that is not an English section (#846)` | UNKNOWN id (rename / removal / typo) |
| `_run_readme_sync: FAILS on the same id claimed twice in one translation (#846)` | DUPLICATE claim |
| `_run_readme_sync: FAILS on a sync marker that is not followed by a heading (#846)` | MISPLACED marker |
| `_run_readme_sync: ignores ATX-looking lines inside fenced code blocks (#846)` | Fenced shell comments are not headings |
| `_run_readme_sync: trailing whitespace in the English body does not flip the hash (#846)` | Hash-input normalisation |
| `_run_readme_sync: a nested subsection is its own section, the parent body stops at it (#846)` | Section granularity |
| `_run_readme_sync: FAILS when two English headings share one slug (ambiguous id) (#846)` | AMBIGUOUS section id |
| `_sync_readme_hashes: stamps an id-only marker with the English section hash (#846)` | The translator writes the id, the tool writes the hash |
| `_sync_readme_hashes: re-stamps a stale hash (#846)` | Generator updates an existing record |
| `_sync_readme_hashes: is idempotent on an already-stamped tree (#846)` | No churn on a clean tree |
| `_sync_readme_hashes: leaves the translated prose untouched (stamps only markers) (#846)` | Only marker lines are rewritten |
| `_sync_readme_hashes: reports the sections a translation is still missing (#846)` | Advisory, never auto-declared |
| `_sync_readme_hashes: REFUSES to re-stamp a section whose English moved while the translation did not (#873)` | The silencing case, performed; the marker must not move |
| `_sync_readme_hashes: an English-only edit plus a sync run leaves the lint RED (#873)` | End to end: syncing does not buy a green tree |
| `_sync_readme_hashes: refusing one section still stamps the untouched ones (#873)` | Refusal is per section, not a whole-run abort |
| `_sync_readme_hashes: re-stamps when the translation moved together with the English (#873)` | The working case still takes one command |
| `_sync_readme_hashes: --accept records a reviewed no-op and clears the lint (#873)` | The English-typo escape hatch, explicit and by name |
| `_sync_readme_hashes: --accept clears only the section it names (#873)` | Accepting one section is not a blanket pass |
| `_sync_readme_hashes: records the translation's own hash beside the English one (#873)` | Both sides stored, so a diff shows which one moved |
| `_run_readme_sync: FAILS when the translated prose changed since it was stamped (#873)` | UNRECORDED: the translation-side record must stay fresh |
| `_run_readme_sync: FAILS when the English README is missing (#846)` | No vacuous pass without a source |
| `_run_readme_sync: FAILS when no translation files are found (#846)` | No vacuous pass without translations |
| `_run_readme_sync: the REAL doc/readme/ tree is stamped and clean today (#846)` | Live tree clean |
| `_sync_readme_hashes: is a no-op on the REAL tree (already stamped) (#846)` | Live tree already generator-exact |

### test/bats/unit/lint_bare_stderr_spec.bats (6)

Unit tests for `script/test/lint_bare_stderr.sh` (#692), the "all stderr
goes through lib/log.sh helpers" lint. The lint takes the repo root as
`$1`, so the spec drives it against synthesized fixture trees laid out
like the real repo (sources under `dist/script/docker/**`, tests
under `script/test/**`). A real-repo-root clean-tree case guards against
the path-drift bug (an empty find root passing vacuously) by proving the
scan actually walks the populated `dist/script/docker` tree.

| Test | Description |
|------|-------------|
| `flags a bare 'printf ... >&2' under dist/script/docker (#692)` | exit 1 + violation line on the correct tree |
| `exits 0 on a clean tree (no bare stderr) (#692)` | clean fixture passes silently |
| `does NOT flag an allowlisted _log_* line (#692)` | `_log_*` line exempt |
| `does NOT flag an allowlisted getopts / [y/N] prompt line (#692)` | getopts / prompt lines exempt |
| `does NOT flag bare stderr in the standalone coverage_gate.sh CI tool (#710)` | standalone log.sh-free CI tool excluded |
| `the real repo tree (default root) is clean (#692)` | live-tree guard against path drift |

### test/bats/unit/template_guard_spec.bats (2)

Unit coverage for `lib/template_guard.sh` (`_assert_not_template_source`) --
the init/upgrade self-run guard (ADR-00000011 sec.8). A vendored `.base/`
subtree never carries `.git`; the base checkout/worktree does, so `.git` at
the resolved subtree root means "this is the base template source itself".

| Test | Description |
|------|-------------|
| `_assert_not_template_source: refuses when the subtree root carries .git (base self)` | `.git` present -> non-zero + actionable error |
| `_assert_not_template_source: passes when the subtree root has no .git (vendored subtree)` | real subtree -> no-op passthrough |

### test/bats/unit/init_spec.bats (53)

Unit coverage for `init.sh` helpers that previous rounds exercised only
through the Level-1 integration test. Complements
`test/bats/integration/init_new_repo_spec.bats` by locking edge cases that
are hard to trigger from a real `bash template/init.sh` invocation
(network-down version detection, main.yaml `@ref` fallback,
`_create_version_file` with no argument).

| Test | Description |
|------|-------------|
| `_detect_template_version: parses newest vX.Y.Z tag from git ls-remote` | Happy path + head -1 |
| `_detect_template_version: returns empty when git ls-remote fails` | Network-down fallback |
| `_detect_template_version: returns empty when no v*.*.* tags exist` | Nothing to match |
| `_detect_template_version: ignores non-semver tags (e.g. rc suffixes)` | Regex filters rc / pre-release |
| `_detect_template_version: an early-closing reader cannot empty the tag scan (#905)` | - |
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
| `_gen_setup_conf default refuses to overwrite existing setup.conf` | - |
| `_gen_setup_conf --force overwrites and backs up existing setup.conf` | - |
| `_gen_setup_conf --force also backs up .env to .env.bak` | - |
| `_gen_setup_conf errors when the template setup.conf is absent (#692)` | #692 missing-template _error |
| `_gen_setup_conf --force on clean repo does not create spurious .bak` | - |
| `TEMPLATE_REL: auto-detects to '.base' when init.sh lives in .base/` | - |
| `TEMPLATE_REL: re-sourcing init.sh from .base/ keeps detection stable` | - |
| `_create_symlinks: targets follow TEMPLATE_REL through .base/ (#330 script/ subfolder)` | - |
| `_create_new_repo: .gitignore includes .setup.conf.bak and .env.bak` | - |
| `_create_hook_stubs: creates script/hooks/{pre,post}/ with 14 stubs (#440)` | - |
| `_create_hook_stubs: each stub starts with shebang and ends with exit 0 (#440)` | - |
| `_create_hook_stubs: idempotent — preserves user-modified stub on re-run (#440)` | - |
| `_create_new_repo: includes hook stubs in new-repo layout (#440)` | - |
| `_init_existing_repo: creates missing hook stubs on upgrade (#440)` | - |
| `_sync_base_monitor_workflow: generates base-version-monitor.yaml` | - |
| `_sync_base_monitor_workflow: schedules weekly + manual dispatch` | - |
| `_sync_base_monitor_workflow: grants issues: write` | - |
| `_sync_base_monitor_workflow: runs the subtree-shipped checker via prefix` | - |
| `_sync_base_monitor_workflow: idempotent — never clobbers a user-tuned file` | - |
| `_create_new_repo: also generates base-version-monitor.yaml` | - |
| `_init_existing_repo: syncs base-version-monitor.yaml on upgrade (#777)` | - |
| `_preflight_just: warns and exits 0 when just is absent (#607)` | Missing runner -> non-fatal WARN |
| `_preflight_just: emits the init_just_missing event under LOG_FORMAT=json (#607)` | Structured event wired through |
| `_preflight_just: install hint points at the documented methods (#607)` | Warning carries install pointer |
| `_preflight_just: silent and exits 0 when just is present (#607)` | Runner present -> no warning |
| `_bootstrap_just: no-op when just is already on PATH (#607)` | Opt-in bootstrap skips when installed |
| `_bootstrap_just: runs the official installer into ~/.local/bin when absent (#607)` | Opt-in installer pipeline to ~/.local/bin |
| `_bootstrap_just: aborts with a clear error when the installer pipeline fails (#692)` | #692 installer-failure _error path |
| `_call_setup: warns but returns 0 when setup.sh exits non-zero (#692)` | #692 warn-on-failure degrade |
| `_call_setup: skips with a notice when setup.sh is absent (#692)` | #692 skip-when-absent branch |
| `_call_setup: returns 0 on a setup.sh that succeeds (#692)` | #692 happy path no-noise |
| `_smoke_test_count: sums ^@test across the per-stage smoke tree (S4 item 6)` | - |
| `_smoke_test_count: returns 0 when the smoke tree has no specs (S4 item 6)` | - |
| `_error: carries a registered event id under LOG_FORMAT=json (#876)` | - |
| `_error: text output is framed like every other init record (#876)` | - |
| `_error: the human message rides the display attribute (#876)` | - |

### test/bats/unit/smoke_helper_spec.bats (28)

Exercises the runtime assertion helpers shipped in
`dist/test/bats/smoke/shared/test_helper.bash` (used by downstream-repo
smoke specs via `load "${BATS_TEST_DIRNAME}/test_helper"`).

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
| `run_wrapper_xhost: wayland session grants +SI:localuser to the .env user` | - |
| `run_wrapper_xhost: x11 session grants +local:` | - |
| `run_wrapper_xhost: an unset XDG_SESSION_TYPE falls back to the X11 grant` | - |
| `run_wrapper_xhost: reports every xhost call, one per line` | - |
| `run_wrapper_xhost: fails loudly when the wrapper makes no xhost call` | - |
| `run_wrapper_xhost: fails when the wrapper exits non-zero` | - |
| `run_wrapper_xhost: fails when the wrapper path does not exist` | - |
| `run_wrapper_xhost: fails when the wrapper's lib/ cannot be located` | - |
| `run_wrapper_xhost: errors when the wrapper path arg is missing` | - |

### test/bats/unit/runtime_smoke_spec.bats (8)

Unit tests for the runtime `.so` dependency smoke scanner (`smoke.sh`,
#430) and its wiring into `Dockerfile.example`'s `runtime-test` stage:
non-zero exit on a missing-dep `.so`, clean-link pass, empty/absent-root
no-ops, and the ldd-skip + accumulate-all behaviour (#692).

| Test | Description |
|------|-------------|
| `smoke.sh exits non-zero when a .so has 'not found' dep (#430)` | Missing-dep failure |
| `smoke.sh exits 0 when scan root has no .so files (#430)` | No-.so pass |
| `smoke.sh exits 0 when scan root does not exist (#430)` | Absent-root pass |
| `Dockerfile.example runtime-test default RUNTIME_SMOKE_CMD calls smoke.sh (#430)` | Default cmd wiring |
| `Dockerfile.example commented runtime-test COPY brings smoke.sh into image (#430)` | COPY wiring |
| `smoke.sh exits 0 when all .so files link cleanly (#430)` | Clean-link pass |
| `smoke.sh: documented behaviour -- a .so whose ldd exits non-zero is skipped (#692)` | ldd-fail skip |
| `smoke.sh: accumulates _exit=1 and reports every bad .so (#692)` | Accumulate-all reporting |

### test/bats/unit/terminator_config_spec.bats (10)

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

### test/bats/unit/terminator_setup_spec.bats (8)

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

### test/bats/unit/tmux_conf_spec.bats (12)

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

### test/bats/unit/tmux_setup_spec.bats (9)

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

### test/bats/unit/upgrade_spec.bats (48)

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
must not be reported as "needing downgrade"), and
`_migrate_lifecycle_restart_default`, which retires the stale
devel-scoped `[lifecycle] restart = no` the old template seeded into
every downstream repo (gated on the pre-pull vendored template, so a
deliberately chosen policy is never rewritten).

| Test | Description |
|------|-------------|
| `_warn_config_drift silent when no .base/dist/config in HEAD` | - |
| `_warn_config_drift silent when pre and post hashes match` | No drift |
| `_warn_config_drift prints WARNING + diff hint when hashes differ` | Drift reported |
| `upgrade.sh defines _warn_config_drift` | Helper present |
| `upgrade.sh invokes _warn_config_drift after subtree pull` | Call site present |
| `upgrade.sh captures pre-pull <subtree-prefix>/config tree hash` | - |
| `_require_git_identity succeeds when name + email are set` | Happy path |
| `_require_git_identity fails when user.email is unset` | Email guard |
| `_require_git_identity fails when user.name is unset` | Name guard |
| `_require_clean_merge_state succeeds in clean repo` | Happy path |
| `_require_clean_merge_state fails when MERGE_HEAD exists` | Mid-merge guard |
| `_require_clean_merge_state fails when rebase-merge dir exists` | Mid-rebase guard |
| `_verify_subtree_intact succeeds when subtree dir + version match target (#477 happy path)` | R1+ happy path |
| `_verify_subtree_intact rolls back when .base/.version is missing` | - |
| `_verify_subtree_intact rolls back when .base/ dir is missing (#477 destructive-FF detector)` | - |
| `_verify_subtree_intact rolls back when .base/ dir is empty (#477)` | - |
| `_verify_subtree_intact rolls back when .version content is not semver (#477)` | R1+ semver-shape guard |
| `_verify_subtree_intact rolls back when .version does not match target (#477 wrong-tag detector)` | R1+ wrong-tag detector |
| `_rollback_subtree_pull surfaces a failed reset instead of falsely reporting 'restored' (#700)` | Failed-reset escalation (no false 'restored' message) |
| `upgrade.sh calls _require_git_identity before subtree pull` | Pre-flight ordering |
| `upgrade.sh calls _verify_subtree_intact after subtree pull with target version (#477)` | Post-flight ordering + R1+ caller integration |
| `upgrade.sh snapshots pre-pull HEAD for rollback` | Rollback anchor |
| `upgrade.sh sources lib/template_guard.sh` | - |
| `upgrade.sh calls _assert_not_template_source with the resolved subtree root` | - |
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
| `_check: prerelease behind latest stable proposes upgrade (rc1 →0.12.0)` | Leave prerelease |
| `_get_latest_version: returns 0 with an empty result when the remote is unreachable` | - |
| `_get_latest_version: an early-closing reader cannot empty the tag scan (#905)` | - |
| `_get_latest_version: empty result feeds _check's 'Could not fetch' guard` | Empty result still surfaces real fetch failures |
| `_upgrade refuses to downgrade from a newer local version` | Implicit-downgrade guard |
| `_migrate_lifecycle_restart_default rewrites the stale template default, loudly` | - |
| `_migrate_lifecycle_restart_default leaves a deliberately chosen policy alone` | - |
| `_migrate_lifecycle_restart_default is inert once the vendored template ships the new default` | - |
| `_migrate_lifecycle_restart_default ignores a restart key outside [lifecycle]` | - |
| `_migrate_lifecycle_restart_default is a no-op without a repo .setup.conf` | - |
| `_migrate_lifecycle_restart_default is a no-op without a vendored template baseline` | - |

### test/bats/unit/conf_accessor_spec.bats (27)

Unit tests for the `conf.sh` opaque accessor interface (#564 / #563): `_conf_load`
loads a file into a named handle, `_conf_get` reads a value by (section, key)
with an optional default, `_conf_sections` lists section names, `_conf_list`
lists a section's keys, `_conf_load_merged` loads a template+repo section-replace
merge into a handle, and `_conf_list_sorted` returns `prefix_N` values in numeric
order (skipping empties) -- all without callers touching the internal
parallel-array representation or the `<section>.<key>` namespacing rule.
Also the low-level INI reader the accessor is built on:
`_parse_ini_section` (per-section key/value extraction, section isolation,
comment/whitespace handling, dotted sub-sections, duplicate/reopened
sections) and the shared single-pass core `_ini_tokenize` (relocated here
from `setup_spec` in P1b, #758 -- they test `lib/conf.sh`).

Dirty-input + error-path coverage (#689) pins the parser/accessor
contracts on hand-edited / malformed setup.conf:

| Test | Description |
|------|-------------|
| `_conf_get returns a value by section and key` | - |
| `_conf_get_into writes the value into the named outvar, no subshell (#742)` | - |
| `_conf_sections lists section names in first-appearance order` | - |
| `_conf_list lists a section's keys in file order` | - |
| `_conf_load_merged: repo section replaces template section wholesale` | - |
| `_conf_get: duplicate key within a section -- last occurrence wins (#689)` | Override semantics (merge + re-save) |
| `_conf_list: a section reopened later in the file keeps entries from both occurrences (#689)` | Reopened section appends; header deduped |
| `_conf_get: inline '#' comment text is KEPT in the value (no inline-comment support) (#689)` | Trailing `# ...` is literal (only leading-# stripped) |
| `_conf_sections: section header with internal whitespace is NOT trimmed ([ deploy ] != deploy) (#689)` | Interior spaces kept in captured name |
| `_conf_load: an unterminated section header ([deploy without ]) drops its keys (#689)` | No header match -> keys lost, no crash |
| `_conf_list_sorted returns prefix_N values in numeric order, skipping empties` | - |
| `_conf_list_sorted skips non-numeric list suffixes (mount_x / mount_ / mount_2b) (#689)` | Numeric-suffix guard reject path |
| `_upsert_conf_value leaves the original file intact when mktemp fails (#700)` | Guarded mktemp -> no clobber/truncate on temp-create failure |
| `_write_setup_conf leaves the destination intact when its temp file cannot be created (#700)` | Temp+atomic-mv -> no in-place truncate data-loss window |
| `_upsert_conf_value cleans the orphan temp + errors when the final mv fails (#702)` | Failed atomic mv -> orphan temp removed + error logged + original unchanged |
| `_write_setup_conf cleans the orphan temp + errors when the final mv fails (#702)` | Failed atomic mv -> orphan temp removed + error logged + destination unchanged |
| `_parse_ini_section reads keys and values for one section` | - |
| `_parse_ini_section isolates sections (entries from other sections ignored)` | - |
| `_parse_ini_section skips comment and empty lines` | - |
| `_parse_ini_section trims whitespace around key and value` | - |
| `_parse_ini_section returns empty arrays for missing file` | - |
| `_parse_ini_section returns empty arrays for absent section` | - |
| `_parse_ini_section does not absorb dotted sub-sections` | - |
| `_parse_ini_section reads a dotted section name` | - |
| `_parse_ini_section preserves duplicate keys and reopened sections in order` | - |
| `_ini_tokenize tracks the owning section per entry and dedups headers` | - |
| `_ini_tokenize keeps dotted keys verbatim (per-stage override keys)` | - |

### test/bats/unit/gitignore_spec.bats (47)

Unit tests for `template/script/docker/lib/gitignore.sh` — the canonical
`.gitignore` set + sync/untrack helpers introduced for issue #172.

| Test | Description |
|------|-------------|
| `_canonical_gitignore_entries: emits exactly the 11 canonical lines (#502, #507, #606, #832, #879, #893)` | - |
| `_canonical_gitignore_entries: advertises .setup.conf.local again (#893)` | - |
| `no entry is both canonical and retired (#893)` | - |
| `_retired_gitignore_entries: retires nothing today (#893)` | - |
| `_sync_gitignore: a full sync leaves .setup.conf.local in the file, twice running (#893)` | - |
| `_sync_gitignore: prunes a retired entry from the managed block (#879)` | - |
| `_sync_gitignore: leaves a retired entry the user put ABOVE the marker alone (#879)` | - |
| `_prune_retired_entries: an early-closing reader cannot lose the managed marker (#905)` | - |
| `_sync_gitignore: pruning a retired entry is idempotent (#879)` | - |
| `_canonical_gitignore_entries: list is stable order` | Deterministic output |
| `_sync_gitignore: creates the file when missing, with marker block + all entries` | Greenfield |
| `_sync_gitignore: empty file gets marker block + all entries appended` | Empty file |
| `_sync_gitignore: file with all entries already present is a no-op` | Already-synced |
| `_sync_gitignore: appends only missing entries when subset already present` | Drift fill-in |
| `_sync_gitignore: preserves user-defined lines (bridge.yaml, .env.gpg, .claude/)` | User-line preservation |
| `_sync_gitignore: idempotent — second invocation produces no further changes` | Idempotency |
| `_sync_gitignore: no duplicate canonical lines after re-run` | No-dup invariant |
| `_sync_gitignore: documented constraint -- CRLF entries are not matched (LF-only) (#692)` | #692 LF-only presence-match constraint |
| `_sync_gitignore: ends with newline so future appends start on their own line` | Trailing-newline guarantee |
| `_untrack_canonical_in_repo: git rm --cached for tracked compose.yaml` | 15-repo drift fix |
| `_untrack_canonical_in_repo: leaves untracked files alone` | Scope guard |
| `_untrack_canonical_in_repo: no-op when no canonical files tracked` | Healthy-repo no-op |
| `_untrack_canonical_in_repo: handles tracked coverage/ directory` | Directory entry |
| `_untrack_canonical_in_repo: idempotent — second run succeeds without error` | Re-run safety |
| `_untrack_canonical_in_repo: untracks all canonical entries that match` | Multi-entry sweep |
| `_sync_logging_gitignore: tracer — relative local_path emitted in .gitignore (#402)` | - |
| `_sync_logging_gitignore appends relative local_path to .gitignore (#402, ex-#328)` | - |
| `_sync_logging_gitignore skips absolute paths (#402, ex-#328)` | - |
| `_sync_logging_gitignore skips ~ paths (#402, ex-#328)` | - |
| `_sync_logging_gitignore is idempotent (#402, ex-#328)` | - |
| `_sync_logging_gitignore: documented constraint -- a '..' traversal is wrapped verbatim (#692)` | #692 `..` path wrapped as-is |
| `_sync_logging_gitignore: documented constraint -- a space-bearing path is wrapped verbatim (#692)` | #692 space path wrapped as-is |
| `_sync_logging_gitignore collects from both global + per-svc (#402, ex-#328)` | - |
| `_sync_logging_gitignore is no-op when no local_path keys (#402, ex-#328)` | - |
| `_sync_logging_gitignore prunes stale managed entries on value change (#402, ex-#390)` | - |
| `_sync_logging_gitignore drops marker + entries when candidates become empty (#402, ex-#390)` | - |
| `_sync_logging_gitignore preserves user entries outside managed block (#402, ex-#390)` | - |
| `_sync_logging_gitignore: emits an explicit end marker bounding the block (#876)` | - |
| `_sync_logging_gitignore: preserves a user entry BELOW the managed block (#876)` | - |
| `_sync_logging_gitignore: user entry below the block survives a value change (#876)` | - |
| `_sync_logging_gitignore: an unterminated managed block is an error (#876)` | - |
| `_sync_logging_gitignore: an end marker with no begin marker is an error (#876)` | - |
| `_sync_logging_gitignore: migrates a legacy begin-marker-only block (#876)` | - |
| `_sync_logging_gitignore: legacy migration keeps a following canonical entry (#876)` | - |
| `_sync_logging_gitignore: legacy migration reports orphaned entries (#876)` | - |
| `_sync_managed_entries: appends without a spurious blank line (#876)` | - |
| `_sync_gitignore + _sync_logging_gitignore converge over repeated passes (#876)` | - |

### test/bats/unit/dockerignore_spec.bats (11)

Unit tests for the `.dockerignore` canonical-sync helpers in
`script/docker/lib/gitignore.sh` (#604). `_canonical_dockerignore_entries`
delegates to `_canonical_gitignore_entries` (a derived artifact not worth
committing is not worth shipping in the build context, so the two share a
single source and never drift); `_sync_dockerignore` + `_sync_gitignore`
are thin wrappers over the shared `_sync_managed_entries` mechanism.

| Test | Description |
|------|-------------|
| `_canonical_dockerignore_entries: emits the derived-artifact set (#604)` | Membership |
| `_canonical_dockerignore_entries: shares the single canonical source with gitignore (no drift) (#604)` | Anti-drift invariant |
| `_canonical_dockerignore_entries: list is stable order (#604)` | Deterministic output |
| `_canonical_dockerignore_entries: includes log/ via the shared canonical source (#606) (#604)` | - |
| `_sync_dockerignore: creates the file when missing, with marker + all entries (#604)` | Greenfield |
| `_sync_dockerignore: file with all entries already present is a no-op (#604)` | Already-synced |
| `_sync_dockerignore: appends only missing entries when subset present (#604)` | Drift fill-in |
| `_sync_dockerignore: preserves hand-maintained build-context lines (#604)` | User-line preservation |
| `_sync_dockerignore: idempotent — second run leaves the file unchanged (#604)` | Idempotency |
| `_sync_dockerignore: marker added only once across re-syncs (#604)` | Single-marker invariant |
| `_sync_dockerignore: file without trailing newline gets one before append (#604)` | Trailing-newline guard |

### test/bats/unit/coverage_gate_spec.bats (21)

Unit tests for `script/test/drivers/coverage_gate.sh` (#710) -- the
self-hosted, CI-agnostic coverage-floor gate that replaces the removed
Codecov merge+status path. The gate MERGES the per-shard kcov cobertura
reports into ONE line-weighted project rate (summing covered/valid lines
across shards, NOT averaging the per-shard rates) and exits non-zero when
the merged rate is below `COVERAGE_MIN`. Driven against controlled
cobertura fixtures so the spec is independent of any live kcov run.
Since #853 the union key is CANONICALISED first: kcov reports one source
file under several prefix-truncated aliases, and each alias used to add its
own full copy of the file's lines to the denominator.

| Test | Description |
|------|-------------|
| `coverage_gate: passes when merged rate >= COVERAGE_MIN` | Floor pass |
| `coverage_gate: passes at exactly the floor (boundary)` | Boundary (==) pass |
| `coverage_gate: fails when merged rate < COVERAGE_MIN` | Floor fail (non-zero exit) |
| `coverage_gate: merges DISJOINT shards by union (= sum), not averaging` | - |
| `coverage_gate: SHARED source across shards is unioned, not double-counted (#730)` | - |
| `coverage_gate: four shards merge into one weighted total` | 4-shard merge total |
| `coverage_gate: prefix path aliases of one file are counted once (#853)` | Alias-inflated denominator (the bug) |
| `coverage_gate: different files sharing a basename stay separate (#853)` | Basename-only keying is wrong (the trap) |
| `coverage_gate: rate is unchanged when the suite is resharded under other aliases (#853)` | Shard-membership invariance |
| `coverage_gate: reports the collapsed-alias count as a diagnostic (#853)` | Alias-collapse diagnostic |
| `coverage_gate: reports zero collapsed aliases when nothing is aliased (#853)` | Diagnostic reports 0, not silence |
| `coverage_gate: errors when no report files are given` | No-args error |
| `coverage_gate: errors when a named report file is missing` | Missing-file error |
| `coverage_gate: errors when total valid lines is zero (empty report)` | Empty-report error |
| `coverage_gate: errors on a report missing the line counters` | Malformed-report error |
| `coverage_gate: default COVERAGE_MIN does not false-fail at the measured 84.72%` | Built-in default does not false-fail |
| `coverage_gate: default COVERAGE_MIN is 80 -- a report exactly at 80 passes` | Floor value pinned from below |
| `coverage_gate: default COVERAGE_MIN is 80 -- a report just under 80 fails` | Floor value pinned from above |
| `coverage_gate: emits a GitHub step summary table when GITHUB_STEP_SUMMARY is set` | GitHub visibility (no SaaS) |
| `coverage_gate --merge-timings: merges per-shard timings keeping max seconds per basename (#733)` | - |
| `coverage_gate --merge-timings: no input files yields an empty weights file (#733)` | - |

### test/bats/unit/build_sh_base_self_spec.bats (2)

build.sh in the base self-use topology (#713): base is the template SOURCE,
so its tree has no `.base/` subtree, no setup.conf, no .env.generated, and a
hand-authored compose.yaml. Covers lib resolution via the base-self path and
`--target test-tools` dispatching `docker compose build` while skipping the
setup-sync lifecycle.

### test/bats/unit/base_docker_namespace_spec.bats (11)

base's self-use of the `docker` namespace (#713, ADR-00000011 sec.2/4/5):
root justfile `mod? docker`, the committed `script/docker/justfile.docker` +
flat `script/<verb>.sh` symlinks resolving into `dist/` (no `.base/` hop),
the `test-tools` compose service building `Dockerfile.test-tools`, and
`just test system` building it via the docker namespace. Also pins the
naming-isolation shape (#891): the build-only `test-tools` service reads the
same `TEST_TOOLS_IMAGE` its consumers read instead of a fixed
`test-tools:local` literal, and the `system` recipe derives that tag from the
tooling Dockerfile's content instead of hardcoding it, and names the compose
project instead of inheriting the checkout directory's basename. Tightened by
#896: EVERY `image:` line must name that variable and NONE may carry a `:-`
default, since two different defaults are what let the build write one tag
while the run read another.


### test/bats/unit/base_version_monitor_spec.bats (13)

Version-compare + issue-open logic of the pull-based base version monitor:
semver ordering (numeric, not lexical), a missing leading `v`, and the
`run` path that opens exactly one labelled tracking issue per target version
(dedup on an already-open one, no issue when up to date, loud failure on an
empty API answer).

| Test | Description |
|------|-------------|
| `compare: newer minor is behind (v0.41.0 < v0.42.0)` | - |
| `compare: equal versions are not behind` | - |
| `compare: older remote is not behind` | - |
| `compare: newer patch is behind` | - |
| `compare: numeric not lexical (v0.9.7 < v0.10.0)` | - |
| `compare: newer major is behind (v0.41.0 < v1.0.0)` | - |
| `compare: tolerates a missing leading v` | - |
| `run: behind -> opens a tracking issue naming the target version` | - |
| `run: opened issue carries the base-upgrade label` | - |
| `run: up to date -> no issue created` | - |
| `run: existing open issue for the target -> skip (dedup)` | - |
| `run: a gh still listing titles cannot make the dedupe gate miss an open issue (#905)` | - |
| `run: empty latest from API -> fails without creating an issue` | - |

### test/bats/unit/check_test_md_drift_spec.bats (10)

The read-only validating twin of `sync-doc-counts.sh`: it re-derives every
doc/test figure from the same source (`grep -c '^@test'`) and exits non-zero
when the committed docs have drifted. Covers the in-sync / drifted verdicts, a
short catalog table, and the unusable-scan-root guards that keep the gate from
passing vacuously (relative root, missing root, no `doc/test/`, no specs).

| Test | Description |
|------|-------------|
| `_check_test_md_drift: exits 0 on an in-sync tree (#782)` | - |
| `_check_test_md_drift: exits non-zero and names the drifted doc on a stale count (#782)` | - |
| `_check_test_md_drift: tolerates an empty acceptance level dir (count 0) (#782)` | - |
| `_check_test_md_drift: a RELATIVE root gives the same verdict as the absolute one (#848)` | - |
| `_check_test_md_drift: a RELATIVE root still detects real drift (#848)` | - |
| `_check_test_md_drift: FAILS on a nonexistent scan root, naming it (#848)` | - |
| `_check_test_md_drift: FAILS on a scan root with no doc/test (no vacuous pass) (#848)` | - |
| `_check_test_md_drift: FAILS on a spec-free scan root (no vacuous pass) (#848)` | - |
| `_check_test_md_drift: counts a shipped smoke spec as spec files (#848)` | - |
| `_check_test_md_drift: FAILS when a spec has more tests than catalog rows (#859)` | - |

### test/bats/unit/compose_emit/hostname_spec.bats (5)

The GUI-under-bridge `hostname:` injection: a bridge-network GUI container
pins its hostname to the host name so X11 authority matches, host-network and
GUI-off cases inject nothing, and a per-stage override decides per stage.

| Test | Description |
|------|-------------|
| `GUI + bridge injects hostname pinned to the host name on devel (#794)` | - |
| `GUI + host mode injects NO hostname on devel (#794)` | - |
| `GUI off + bridge injects NO hostname on devel (#794)` | - |
| `per-stage GUI+bridge override injects hostname on that stage (#794)` | - |
| `per-stage GUI-off under bridge injects NO hostname (#794)` | - |

### test/bats/unit/logrotate_spec.bats (7)

Wrapper transcript retention: `_logrotate_repoint` (the stable `latest.log`
symlink follows the newest real file without deleting the previous one) and
`_logrotate_prune` (keep N most recent plus an age bound, never touch the
symlink itself or a sibling service's symlink sharing the directory, missing
directory is a no-op).

| Test | Description |
|------|-------------|
| `_logrotate_repoint: points the stable symlink at the newest real file (#805)` | - |
| `_logrotate_repoint: repointing to a newer file does NOT delete the old one (#805)` | - |
| `_logrotate_prune: keeps the N most recent real files, drops the rest (#805)` | - |
| `_logrotate_prune: drops files older than <days> regardless of count (#805)` | - |
| `_logrotate_prune: never removes the stable symlink itself (#805)` | - |
| `_logrotate_prune: never prunes a SIBLING service's symlink sharing the dir (#805)` | - |
| `_logrotate_prune: missing dir is a no-op (best-effort) (#805)` | - |

### test/bats/unit/resolve_doc_counts_spec.bats (10)

Unit coverage for `script/test/resolve-doc-counts.sh` -- the one command that
resolves a `doc/test/*.md` merge conflict. Two halves: the toil (markers go,
figures come back regenerated from the merged spec tree) and the safety
(a relative root, a surviving marker, an unhappy drift gate, and any
disagreement regeneration cannot settle are all refused loudly rather than
resolved to whichever side the collapse happened to keep).

| Test | Description |
|------|-------------|
| `_resolve_doc_counts: FAILS on a RELATIVE root, naming it (#857)` | - |
| `_resolve_doc_counts: FAILS on a nonexistent root, naming it (#857)` | - |
| `_resolve_doc_counts: collapses a counter-only conflict and regenerates (#857)` | - |
| `_resolve_doc_counts: drops the diff3 base section too (#857)` | - |
| `_resolve_doc_counts: rescues the catalog prose from BOTH sides (#857)` | - |
| `_resolve_doc_counts: an unconflicted tree is verified, not rewritten (#857)` | - |
| `_resolve_doc_counts: FAILS when the two sides describe the same test differently (#857)` | - |
| `_resolve_doc_counts: FAILS when the sides differ in prose the generator does not derive (#857)` | - |
| `_resolve_doc_counts: FAILS when the drift gate is unhappy afterwards (#857)` | - |
| `_resolve_assert_no_markers: FAILS naming the file and line of a survivor (#857)` | - |

### test/bats/unit/home_literal_lint_spec.bats (18)

Unit coverage for `script/test/drivers/home_literal.sh` -- the mechanical half
of the "bake self-built artifacts at `/opt`, not under `$HOME`" convention
(ADR-00000024). The container user is a BUILD arg, so a concrete username in a
shipped Dockerfile / entrypoint / in-image config file breaks the moment the
image is rebuilt or `docker save`+`load`'ed under a different `USER_NAME`. The
parameterised `${USER_NAME}` / escaped `\${USER_NAME}` / `<placeholder>` forms
and absolute `/opt` paths pass; a narrative mention opts out through a bracketed
allow region that must be balanced and does not leak past its end; a missing
scan root fails loudly instead of passing vacuously; and a final case drives the
REAL shipped tree.

| Test | Description |
|------|-------------|
| `_run_home_literal: FAILS on a hardcoded home path in the shipped Dockerfile, naming file and line (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path in a runtime entrypoint (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path in a non-.sh in-image config file (#799)` | - |
| `_run_home_literal: FAILS on a hardcoded home path inside a comment too (#799)` | - |
| `_run_home_literal: names the offending literal in the failure message (#799)` | - |
| `_run_home_literal: points at the /opt convention in the failure message (#799)` | - |
| `_run_home_literal: scans the repo-root dockerfile/ tree too (#799)` | - |
| `_run_home_literal: FAILS on a literal AFTER an allow-end (region does not leak) (#799)` | - |
| `_run_home_literal: FAILS on an unterminated allow-begin region (#799)` | - |
| `_run_home_literal: FAILS on an allow-end with no matching allow-begin (#799)` | - |
| `_run_home_literal: PASSES the ${USER_NAME} build-arg form (#799)` | - |
| `_run_home_literal: PASSES the backslash-escaped \${USER_NAME} form (#799)` | - |
| `_run_home_literal: PASSES the angle-bracket placeholder form (#799)` | - |
| `_run_home_literal: PASSES an absolute /opt artifact path (#799)` | - |
| `_run_home_literal: EXEMPTS a literal inside an allow-begin/allow-end region (#799)` | - |
| `_run_home_literal: ignores files OUTSIDE the shipped tree (#799)` | - |
| `_run_home_literal: FAILS when a scan root is missing (no vacuous pass) (#799)` | - |
| `_run_home_literal: the REAL shipped tree passes today (#799)` | - |

### test/bats/unit/cd_guard_spec.bats (7)

Behaviour of the shipped CD pre-deploy gate `dist/deploy/cd-guard.sh`
(ADR-00000023): refuse to deploy unless the tree is clean **and** HEAD
sits on a tag, so an automated field bundle is always traceable to a
released version. Four `mktemp` git fixtures drive the real script and
assert exit status **and** the specific refusal message — a status-only
check passes with the conditions inverted (dirty reported as untagged and
vice versa). Pure git + filesystem, no docker.

| Test | Description |
|------|-------------|
| `cd-guard: ships executable, so the documented ./.base/... invocation works` | - |
| `cd-guard: refuses outside a git repository (exit 1 + 'not inside a git repository')` | - |
| `cd-guard: refuses a dirty tree even when HEAD is on a tag (exit 1 + 'working tree is dirty')` | - |
| `cd-guard: refuses an untagged HEAD on a clean tree (exit 1 + 'HEAD is not on a tag')` | - |
| `cd-guard: a tag that does not point at HEAD is still an untagged HEAD` | - |
| `cd-guard: accepts a clean tree on a tag (exit 0 + names the tag)` | - |
| `cd-guard: the accept path reports the tag on stdout, refusals on stderr` | - |

### test/bats/unit/bash_source_guard_lint_spec.bats (18)

| Test | Description |
|------|-------------|
| `_run_bash_source_guard: FAILS on a bare indexed read, naming file and line (#869)` | - |
| `_run_bash_source_guard: FAILS on a suffix-stripped read (${BASH_SOURCE[0]%/*}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a caller-frame read (${BASH_SOURCE[1]}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a subscript-less read (${BASH_SOURCE}) (#869)` | - |
| `_run_bash_source_guard: FAILS on a read in base's own tooling tree, not just dist/ (#869)` | - |
| `_run_bash_source_guard: names the default form in the failure message (#869)` | - |
| `_run_bash_source_guard: FAILS on a read AFTER an allow-end (region does not leak) (#869)` | - |
| `_run_bash_source_guard: FAILS on an unterminated allow-begin region (#869)` | - |
| `_run_bash_source_guard: FAILS on an allow-end with no matching allow-begin (#869)` | - |
| `_run_bash_source_guard: PASSES the $0-defaulted read (#869)` | - |
| `_run_bash_source_guard: PASSES the empty-defaulted sourced-vs-executed guard (#869)` | - |
| `_run_bash_source_guard: PASSES a defaulted higher frame (${BASH_SOURCE[2]:-unknown}) (#869)` | - |
| `_run_bash_source_guard: PASSES whole-array expansions, which nounset tolerates (#869)` | - |
| `_run_bash_source_guard: PASSES a comment that merely names the array (#869)` | - |
| `_run_bash_source_guard: EXEMPTS a read inside an allow-begin/allow-end region (#869)` | - |
| `_run_bash_source_guard: ignores non-.sh files and files outside the scanned trees (#869)` | - |
| `_run_bash_source_guard: FAILS when a scan root is missing (no vacuous pass) (#869)` | - |
| `_run_bash_source_guard: the REAL shipped + tooling trees pass today (#869)` | - |

### test/bats/unit/derived_figures_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_derived_baseline_renderings: derives the forward-looking and legacy sets from _validate_stage_name (#874)` | - |
| `_derived_baseline_renderings: does NOT include devel-test -- the predicate emits it as a service (#874)` | - |
| `_derived_baseline_renderings: every derived name probes back as a baseline collision (#874)` | - |
| `_run_derived_figures: FAILS on a README baseline set that lists devel-test, naming file and line (#874)` | - |
| `_run_derived_figures: PASSES on the canonical forward-looking and legacy renderings (#874)` | - |
| `_run_derived_figures: ignores a brace set that names no baseline stage (#874)` | - |
| `_run_derived_figures: catches a stale set wrapped across markdown lines (#874)` | - |
| `_run_derived_figures: catches a stale set split by an escaped newline in a shell string (#874)` | - |
| `_run_derived_figures: catches a stale set wrapped across two shell comment lines (#874)` | - |
| `_run_derived_figures: ignores a brace EXPANSION glued to a path (#874)` | - |
| `_run_derived_figures: scans CONTEXT.md and the localized READMEs too (#874)` | - |
| `_run_derived_figures: ignores a ${VAR} expansion that is not a stage set (#874)` | - |
| `_run_derived_figures: FAILS when the README section count disagrees with SCHEMA_SECTIONS (#874)` | - |
| `_run_derived_figures: FAILS when the count is a number but the wrong one (#874)` | - |
| `_run_derived_figures: FAILS when the listed sections differ from SCHEMA_SECTIONS (#874)` | - |
| `_run_derived_figures: FAILS when the listed sections are out of template order (#874)` | - |
| `_run_derived_figures: FAILS when the section heading is absent (no vacuous pass) (#874)` | - |
| `_run_derived_figures: FAILS when a required doc file is missing (no vacuous pass) (#874)` | - |
| `_run_derived_figures: FAILS when the dist/ scan root is missing (no vacuous pass) (#874)` | - |
| `_run_derived_figures: the REAL tree passes today (#874)` | - |

### test/bats/unit/i18n_orphan_lint_spec.bats (22)

| Test | Description |
|------|-------------|
| `_run_i18n_orphan: FAILS on an env-var identifier in a fenced block that the English README never mentions (#902)` | - |
| `_run_i18n_orphan: FAILS on an env-var identifier in an INLINE code span, which a fence-only scan walks past (#902)` | - |
| `_run_i18n_orphan: FAILS on a long option the English README never mentions (#902)` | - |
| `_run_i18n_orphan: reports EVERY translation that carries an orphan, not just the first (#902)` | - |
| `_run_i18n_orphan: names both readings and the opt-out in the failure message (#902)` | - |
| `_run_i18n_orphan: PASSES when the identifier appears in English PROSE without backticks (#902)` | - |
| `_run_i18n_orphan: PASSES on an identifier-shaped token in translation prose OUTSIDE any code span (#902)` | - |
| `_run_i18n_orphan: PASSES on a path-shaped token absent from the English README (#902)` | - |
| `_run_i18n_orphan: PASSES on a bare '--' separator and on a lone hyphenated word (#902)` | - |
| `_run_i18n_orphan: does NOT flag a longer identifier as a match for a shorter English one (#902)` | - |
| `_run_i18n_orphan: an allow region suppresses the finding inside it (#902)` | - |
| `_run_i18n_orphan: FAILS on an orphan AFTER an allow-end (the region does not leak) (#902)` | - |
| `_run_i18n_orphan: FAILS on an unterminated allow-begin (#902)` | - |
| `_run_i18n_orphan: FAILS on an allow-end with no open allow-begin (#902)` | - |
| `_run_i18n_orphan: DIES when README.md is missing rather than passing vacuously (#902)` | - |
| `_run_i18n_orphan: DIES when the translation directory is missing (#902)` | - |
| `_run_i18n_orphan: DIES when the translation directory holds no translation (#902)` | - |
| `_run_i18n_orphan: DIES when the English README yields no identifier at all (#902)` | - |
| `_run_i18n_orphan: DIES when no translation yields a single scanned token (#902)` | - |
| `_run_i18n_orphan: catches the removed per-instance mechanism verbatim, as it stood before the hand fix (#902)` | - |
| `_run_i18n_orphan: catches the retired argv shim verbatim, as it stood before the hand fix (#902)` | - |
| `_run_i18n_orphan: the real repo tree carries no translation-only identifier (#902)` | - |

### test/bats/unit/sourceable_scripts_spec.bats (8)

| Test | Description |
|------|-------------|
| `sourceable scripts: the discovered set is non-empty and covers the known entry points (#869)` | - |
| `sourceable scripts: none leaves nounset or errexit on in its caller (#869)` | - |
| `sourceable scripts: each loads and returns control to the caller (#869)` | - |
| `self-location: the lib umbrella loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the TUI wrapper loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the setup wrapper loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: the self-test dispatcher loads with BASH_SOURCE unpopulated (#869)` | - |
| `self-location: every docker lib module loads with BASH_SOURCE unpopulated (#869)` | - |

### test/bats/unit/deploy_word_collision_spec.bats (12)

| Test | Description |
|------|-------------|
| `setup_tui accepts gpu as a subcommand (#879)` | - |
| `setup_tui still accepts deploy as a subcommand (alias kept) (#879)` | - |
| `gpu canonicalises to the deploy section editor (#879)` | - |
| `a non-aliased section canonicalises to itself (#879)` | - |
| `an unknown word is still rejected (#879)` | - |
| `the deploy spelling explains it is the GPU editor, not the bundle (#879)` | - |
| `the gpu spelling is silent -- the alias is the way out of the notice (#879)` | - |
| `no subcommand at all is silent (#879)` | - |
| `the disambiguation notice is translated in all four locales (#879)` | - |
| `setup_tui --help lists gpu and denies the field-bundle reading (#879)` | - |
| `setup_tui --help names the distinction in all four locales (#879)` | - |
| `setup.sh --help distinguishes the deploy subcommand from the section (#879)` | - |

### test/bats/unit/env_generated_claim_spec.bats (11)

| Test | Description |
|------|-------------|
| `just docker help: en setup summary names .env.generated (#879)` | - |
| `just docker help: zh-TW setup summary names .env.generated (#879)` | - |
| `just docker help: zh-CN setup summary names .env.generated (#879)` | - |
| `just docker help: ja setup summary names .env.generated (#879)` | - |
| `justfile.docker: the setup doc comment names .env.generated (#879)` | - |
| `setup.sh --help: usage names .env.generated (#879)` | - |
| `setup.sh set: the next hint names .env.generated (#879)` | - |
| `setup.sh add: the next hint names .env.generated (#879)` | - |
| `setup.sh remove: the next hint names .env.generated (#879)` | - |
| `setup.sh env done message names .env.generated in all four locales (#879)` | - |
| `no shipped surface claims setup regenerates a bare .env (#879)` | - |

### test/bats/unit/network_ports_inert_spec.bats (15)

| Test | Description |
|------|-------------|
| `set network.port_N under the shipped host default warns (#879)` | - |
| `set network.port_N under mode = bridge stays quiet (#879)` | - |
| `add network.port under the shipped host default warns (#879)` | - |
| `add network.port under mode = bridge stays quiet (#879)` | - |
| `set network.mode host with ports already configured warns (#879)` | - |
| `set network.mode bridge with ports already configured stays quiet (#879)` | - |
| `set network.mode host with no ports configured stays quiet (#879)` | - |
| `--quiet suppresses the confirmation but never the port diagnostic (#879)` | - |
| `generate_compose_yaml warns when it drops ports under host mode (#879)` | - |
| `generate_compose_yaml stays quiet when it emits ports under bridge (#879)` | - |
| `generate_compose_yaml stays quiet under host mode with no ports (#879)` | - |
| `_generate_resolved_compose warns when the field bundle drops ports (#879)` | - |
| `_generate_resolved_compose stays quiet when the field bundle emits ports (#879)` | - |
| `the ports-inert diagnostic is translated in all four locales (#879)` | - |
| `the ports-inert diagnostic differs per locale (no untranslated arms) (#879)` | - |

### test/bats/unit/ci_reclaim_spec.bats (15)

Ownership-scoped CI-host garbage collection (`script/ci/reclaim.sh`,
#900). `runs-on: ubuntu-latest` gives every job a fresh single-tenant
VM, so no run on the current CI can exhibit either failure the collector
exists to prevent -- one run deleting a concurrent run's artifacts, and a
killed runner leaving artifacts nobody collects. A fake docker daemon (a
PATH shim over a state file) is what puts two runs' artifacts on ONE
host so the boundary between them can be asserted at all.

| Test | Description |
|------|-------------|
| `reclaim.sh --help exits 0 and shows usage` | - |
| `reclaim.sh with no scope refuses (a scopeless sweep is the trap)` | - |
| `reclaim.sh rejects a --stale window that is not a duration` | - |
| `reclaim.sh --run removes this run's artifacts across all four kinds` | - |
| `reclaim.sh --run leaves a CONCURRENT run's artifacts alone (the trap)` | - |
| `reclaim.sh --run does not mistake attempt 10 for attempt 1` | - |
| `reclaim.sh --run finds an artifact by its ownership label alone` | - |
| `reclaim.sh --run never issues a blanket prune` | - |
| `reclaim.sh --dry-run reports without removing anything` | - |
| `reclaim.sh --stale collects a killed runner's leftovers` | - |
| `reclaim.sh --stale spares an in-flight run inside the window` | - |
| `reclaim.sh --stale spares the current run even when its clock says old` | - |
| `reclaim.sh --stale ignores artifacts that are not CI-owned` | - |
| `reclaim.sh --stale delegates the unowned classes to prune.sh with the same window` | - |
| `reclaim.sh --stale never touches volumes` | - |

### test/bats/unit/upstream_spec.bats (9)

| Test | Description |
|------|-------------|
| `upstream.sh: defines the slug and derives the clone URL from it (#895)` | - |
| `upstream.sh: sourcing it twice is inert (#895)` | - |
| `upstream.sh: reads nothing from the environment (#895)` | - |
| `exactly one shipped file names the upstream in code (#895)` | - |
| `upgrade.sh defaults TEMPLATE_REMOTE to the shared constant (#895)` | - |
| `init.sh defaults its version query to the shared constant (#895)` | - |
| `check-base-version.sh defaults BASE_REPO to the shared constant (#895)` | - |
| `check-base-version.sh still resolves its default with no override set (#895)` | - |
| `a caller's TEMPLATE_REMOTE still wins over the shared default (#895)` | - |


### test/bats/unit/smoke_harness_spec.bats (13)

| Test | Description |
|------|-------------|
| `the smoke harness ships a dockerfile and a compose service that builds it` | - |
| `just test smoke builds through the docker namespace, not a raw docker build (ADR-00000011 sec.5)` | - |
| `just test smoke resolves the tooling image and names the compose project (#896, #891)` | - |
| `just test smoke names the image it builds after the resolved project, not the directory (#891)` | - |
| `just test smoke is NOT wired into the default just test gate` | - |
| `the harness reproduces every devel-test COPY into /lint and /smoke_test` | - |
| `every harness COPY exemption is still a real devel-test COPY` | - |
| `the harness installs the entrypoint the shared smoke baseline asserts` | - |
| `the harness exports BATS_LIB_PATH like the devel-test stage does` | - |
| `the harness runs the specs as a non-root user, after the COPYs` | - |
| `the harness asserts at BUILD time, exactly like the stage it stands in for` | - |
| `the harness has no compose image name to displace a sibling checkout's (#891)` | - |
| `runtime-test ships no specs, which is why the harness covers devel-test only` | - |

### test/bats/unit/early_close_reader_lint_spec.bats (20)

| Test | Description |
|------|-------------|
| `_run_early_close_reader: FAILS on a pipeline into grep -q, naming file and line (#905)` | - |
| `_run_early_close_reader: FAILS on a clustered quiet flag (-qxF) (#905)` | - |
| `_run_early_close_reader: FAILS on a quiet flag that is not the first argument (#905)` | - |
| `_run_early_close_reader: FAILS on the long-form --quiet (#905)` | - |
| `_run_early_close_reader: FAILS on a pipeline into head, with or without -n (#905)` | - |
| `_run_early_close_reader: FAILS on a reader on its own continuation line (#905)` | - |
| `_run_early_close_reader: FAILS in base's own tooling tree, not just dist/ (#905)` | - |
| `_run_early_close_reader: PASSES a reader that drains the stream (grep -v, grep -c) (#905)` | - |
| `_run_early_close_reader: PASSES grep -q reading a FILE, which strands nobody (#905)` | - |
| `_run_early_close_reader: PASSES a logical OR that merely precedes grep -q (#905)` | - |
| `_run_early_close_reader: PASSES a here-string into grep -q (no writer process) (#905)` | - |
| `_run_early_close_reader: PASSES a comment that merely describes the shape (#905)` | - |
| `_run_early_close_reader: PASSES an in-shell drain (the shape the fixes use) (#905)` | - |
| `_run_early_close_reader: ignores non-.sh files and files outside the scanned trees (#905)` | - |
| `_run_early_close_reader: EXEMPTS a pipeline inside an allow-begin/allow-end region (#905)` | - |
| `_run_early_close_reader: FAILS on a pipeline AFTER an allow-end (region does not leak) (#905)` | - |
| `_run_early_close_reader: FAILS on an unterminated allow-begin region (#905)` | - |
| `_run_early_close_reader: FAILS on an allow-end with no matching allow-begin (#905)` | - |
| `_run_early_close_reader: FAILS when a scan root is missing (no vacuous pass) (#905)` | - |
| `_run_early_close_reader: the REAL shipped + tooling trees pass today (#905)` | - |
