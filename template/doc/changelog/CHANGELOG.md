# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v0.20.1] - 2026-05-08

### Fixed
- **`setup.conf [environment] env_N` cross-reference now expands**
  (#236). When a later `env_N` value references an earlier sibling KEY
  via `${KEY}`, `setup.sh` now substitutes the earlier sibling's value
  before emitting to `compose.yaml`. Previously the literal `${KEY}`
  shipped to compose, and compose's own `${VAR}` substitution does NOT
  consult sibling environment entries -- the container saw the
  unexpanded form (e.g. `LD_LIBRARY_PATH=/foo//lib` after declaring
  `ROS_DISTRO=humble` and `LD_LIBRARY_PATH=/foo/${ROS_DISTRO}/lib`).
  Order-sensitive: forward references and unknown names stay literal
  so compose's substitution layer (`.env` / shell env) gets a chance
  at file-load time. Transitive references resolve through the chain
  (env_3 sees the fully-expanded env_2). Implementation: new
  `_expand_env_cross_refs` helper called from `generate_compose_yaml`
  before the env block emits. 5 new unit tests in
  `test/unit/compose_gen_spec.bats` cover basic / forward / unknown /
  multi-ref / transitive cases.

## [v0.20.0] - 2026-05-08

Promoted from `v0.20.0-rc1` (#234) — RC tag CI was green; no fixups needed.

### Added
- **`publish-worker.yaml` reusable workflow** (#232). Opt-in
  workflow_call entry point that pushes a Dockerfile target stage
  (default `devel`) to a container registry (default `ghcr.io`) on
  tag push. Inputs mirror `build-worker.yaml` (`image_name`,
  `build_args`, `context_path`, `dockerfile_path`, `build_contexts`,
  `platforms`, `test_tools_version`) plus publish-specific knobs
  (`tag_suffix`, `is_latest`, `registry`, `target`). Default behavior
  for existing repos is unchanged: only repos that explicitly add a
  `call-publish` job in their `main.yaml` publish images. Designed
  for foundational image repos (`ros_distro`, `ros2_distro`) so app
  repos can `FROM ghcr.io/<org>/ros_distro:vX.Y.Z-<variant>` instead
  of duplicating sys / base / devel layers per repo. Auth uses
  `GITHUB_TOKEN` for GHCR; multi-arch via `platforms: linux/amd64,linux/arm64`
  publishes a single multi-arch manifest list under each tag.
  Documented under "CI Reusable Workflows" in template README with
  full input table and caller example.

## [v0.19.0] - 2026-05-07

Promoted from `v0.19.0-rc1` (#228) — RC tag CI was green; no fixups needed.

### Changed
- **`setup_tui.sh` main menu restructured into 5 grouped entries + `Features` discoverability surface** (#221). Top-level main now shows `image`, `build`, `runtime`, `mounts`, `advanced`, `features`, `Save & Exit` — replacing the previous flat list of 5 runtime/mount sections + `advanced` mixed at the same level. `runtime` (network / GPU / display / env vars) and `mounts` (volumes / devices / tmpfs) are sub-menu groupers; `image` and `build` get promoted from Advanced because they are commonly tweaked when wiring a new repo. Advanced is slimmed to truly-advanced knobs (security, named build contexts, conditional per-stage overrides, Reset). The new `features` entry is permanently visible and lists conditional / power-user features with a status row (today: `Per-stage overrides — enabled (N stages)` when a non-baseline `FROM ... AS <name>` exists, otherwise `— hidden (no non-baseline stages)`); clicking the disabled row pops a msgbox explaining how to enable, clicking the enabled row drills into the same editor as the conditional Advanced entry. No semantic change to any underlying section editor — every existing `_edit_section_*` is reachable via the new layout.

### Added
- 12 i18n keys × 4 languages for the new menu structure: `main.runtime` / `main.mounts` / `main.features`, `runtime.title` / `.menu` / `.back`, `mounts.title` / `.menu` / `.back`, `features.title` / `.menu` / `.back`, `features.per_stage_enabled` / `features.per_stage_hidden` / `features.per_stage_hidden_info`.

## [v0.18.2] - 2026-05-07

Patch release that ships **the correct `.version` metadata** for the work that landed under the v0.18.0 / v0.18.1 git tags. Both prior tags shipped without the standard `chore: release` step, so their tagged commits still carried `.version = v0.17.0`. Downstream consumers ended up with a stale `template/.version` after `make upgrade`, which made `make upgrade-check` perpetually report "upgrade available". Functionally those tags were correct (workflows, scripts, tests all matched their version), but the metadata file lied.

This release contains **no functional change vs v0.18.1**. Only `.version` and CHANGELOG bookkeeping. Downstream upgrade to v0.18.2 is a metadata-only refresh: same template content, same `main.yaml` `@v0.18.x` reusable workflow surface (modulo the `@tag` bump itself), and the local `template/.version` finally agrees with what the agent actually consumed.

Process gap that caused this is tracked in claude-workspace #36 (added `check_tag_version_consistency.sh` PreToolUse hook and a `Process discipline` section in CLAUDE.md so the same mistake cannot repeat — `git tag v*` is now blocked when the repo's `.version` file does not match the tag name).

### Fixed
- **`.version` file bumped to match the tag** (refs claude-workspace#36). Prior tags v0.18.0 and v0.18.1 carried `.version = v0.17.0`. Pinned consumers of those tags ended up with a stale local `template/.version`; `make upgrade-check` would loop "upgrade available" forever. v0.18.2 ships `.version = v0.18.2` so the loop terminates and `cat template/.version` agrees with the ref users pulled from.

### Added (v0.18.0 + v0.18.1 -- carried forward, no functional change in v0.18.2)
- See [v0.18.1](#v0181---2026-05-06) for the per-stage `[stage:<name>]` overrides feature, the standalone-emit fix, and the `--help` / `--lang` argument-order fix.

## [v0.18.1] - 2026-05-06

> Tagged with stale `.version = v0.17.0`. Functionally correct but metadata-only fix in v0.18.2 -- prefer v0.18.2 for new consumers.

### Fixed
- **`[stage:<name>]` per-stage list overrides now actually replace devel's lists at runtime** (#220 follow-up; v0.18.0 had this gap, fixed in v0.18.1). compose `extends` MERGES list fields (`volumes` / `environment` / `ports` / `cap_add` / `deploy.devices`) by appending child entries to parent's, not replacing them — so the v0.18.0 emit pattern of "minimal `extends: devel` + override list block in stage" left devel's X11 mount + DISPLAY env intact even when the stage set `gui.mode = off`. Confirmed via Isaac Sim headless validation: `docker compose --profile headless config` showed `/tmp/.X11-unix` and `DISPLAY` inherited despite the stage's `gui.mode = off`, and kit emitted the exact `X11 connection rejected because of wrong authentication` warning the issue body called out. Fix: when a stage has any list-affecting override (`gui.mode` change, or any `volumes.mount_*` / `environment.env_*` / `network.port_*` / `*_inherit = false`), emit a **standalone** service block (no `extends: devel`). Top-level fields not yet in the per-stage allowlist (`cap_add` / `cap_drop` / `security_opt` / `devices` / `cgroup_rules` / `tmpfs`) are re-emitted from top-level so the stage still inherits those by default. Cost: a stage with even a single scalar override now produces ~150 lines of compose.yaml instead of ~10; compose.yaml is auto-generated, so the verbosity is fine. v0.18.0 stable tag is left as-is for record-keeping; users should upgrade to v0.18.1 to get the fix. Updated 3 integration tests + 1 new test (`stage-override: standalone emit re-emits cap_add / runtime / privileged inherited from devel`).
- **`build.sh` / `run.sh` / `exec.sh` / `stop.sh` `--help` now respects `--lang` regardless of argument order** (#222). Previously `<script> --help --lang zh-TW` printed English usage because `usage()` exited via `-h|--help` before the main parse loop reached `--lang`. The reverse order (`--lang` first) worked. Fix: a one-pass scan in each `main()` resolves `--lang` (and via the existing `_sanitize_lang` machinery, `SETUP_LANG`) before the canonical parse loop runs, so both orderings produce the localised usage. Flag surface unchanged. 9 new smoke-test rows in `test/smoke/script_help.bats` (zh-TW / zh-CN / ja across the four scripts).

### Added
- **Per-stage `setup.conf` overrides for runtime knobs** (#220). `[stage:<name>]` sections in `<repo>/setup.conf` override top-level settings on a per-stage basis when a corresponding `FROM ... AS <name>` stage exists in the Dockerfile (auto-emitted via #215). Driving use case: NVIDIA Isaac Sim's three-stage shape (`devel` for interactive dev with X11, `headless` for WebRTC livestream that needs `mode=bridge` + ports + GPU `video` capability + `gui=off`, `gui` for local-display that needs `gui=auto`) — previously all three stages shared one set of runtime knobs from top-level. Allowlist (v1):
  - `[deploy]` whole section: `gpu_mode`, `gpu_count`, `gpu_capabilities`, `runtime`
  - `[gui] mode`
  - `[network]` whole section: `mode`, `ipc`, `network_name`, `port_<N>` + `port_inherit` meta-key
  - `[security] privileged`
  - `[volumes] mount_<N>` + `mount_inherit` meta-key
  - `[environment] env_<N>` + `env_inherit` meta-key
  - Excluded by design: `[image_name]` (image tag is one per image, not per-stage), `apt_mirror_*` (build-time, not runtime), other `[security]` keys (no driving use case yet — re-evaluate v2).
- **Append-default + opt-out merge semantics for list fields**: stage's `mount_*` / `port_*` / `env_*` items append to top-level by default; setting `<list>_inherit = false` switches to replace mode (drop top-level entries entirely). Reverse toggle preserves the stage's own entries in `setup.conf` so flipping back to inherit doesn't lose typed values.
- **Stage section validator**: `[stage:sys|base|test]` is hard-error (baseline collision); `[stage:devel]` is reserved (v1 no-op, WARN; revisit in v2 — devel emits via env-var refs `${NETWORK_MODE}` / `${PRIVILEGED}` / `${IPC_MODE}` so override semantics are non-trivial); `[stage:foo]` referencing a stage absent from the Dockerfile is WARN + skipped; override keys outside the v1 allowlist are WARN + skipped per-key. 2 new 4-language i18n keys (`stage_unknown_referenced`, `stage_override_key_not_allowed`) supplementing #215's existing 3 keys.
- **TUI integration in `setup_tui.sh`**: new "Per-stage overrides" entry under the Advanced menu, **only shown when the Dockerfile has at least one non-baseline stage** — zero noise for the 17 existing downstream repos. Submenu structure: stage list (with override-count label) → per-stage section picker (gui / deploy / network / volumes / environment) → typed editors for scalars and the existing list editor for `mount_*` / `port_*` / `env_*` plus an inherit-toggle row. ~14 new TUI i18n keys × 4 languages. Menu placement / restructure (potentially promoting per-stage to main menu after user feedback) tracked separately in #221.
- **`_tui_conf.sh` writer extended to append NEW sections**: previously `_write_setup_conf` only handled overrides for sections present in the template. The first time a user adds `[stage:headless]` via TUI Save, the section is brand new; the writer now tracks template sections separately and appends new ones (with their keys, in user-input order) at end-of-file. Reader (`_load_setup_conf_full`) already handled stage sections via generic `<section>.<key>` namespacing — no change needed there.
- **Compose-emit integration**: `generate_compose_yaml` validates `[stage:*]` sections after Dockerfile-stage validation, then for each non-baseline stage with overrides, emits the resolved effective values as inline overrides on top of the existing `extends: devel` block. Stages with no overrides keep the byte-for-byte identical zero-diff path from v0.17.0 (#215). gui changes force `environment:` + `volumes:` re-emit (compose extends's child-replaces-list semantics drop X11 baseline cleanly). gpu mode flip-on with new caps re-emits the `deploy:` block; v1 limitation: turning gpu off when devel has it on isn't representable via compose extends and is documented as deferred to v2.

### Tests
- Total: **1011 tests** (957 unit + 54 integration). 42 new tests since v0.17.0:
  - `setup_spec.bats` +27: 20 helper unit tests (`_parse_stage_sections` / `_load_stage_overrides` / `_validate_stage_override_key` allowlist / `_resolve_stage_scalar` / `_resolve_stage_list` append-replace + ordering + meta-key skip) + 7 compose-emit integration tests (zero-diff regression, gui.mode=off strips X11, network.mode=bridge + ports, volumes.mount_inherit=false replaces, orphan WARN, disallowed-key WARN, `[stage:sys]` hard-error).
  - `tui_spec.bats` +5: stage round-trip via `_load_setup_conf_full` / `_write_setup_conf` (namespaced load, append new section, multi-section, full round-trip, in-place update).
  - `tui_flow.bats` +10: `_list_dockerfile_stages_available` / `_count_stage_overrides` / `_edit_stage_gui` / `_edit_stage_scalar` / `_edit_stage_list` (inherit toggle + add).

## [v0.17.0] - 2026-05-06

Minor release bundling two `setup.sh` / `run.sh` feature additions plus
two UX polish items. Notable behavior change: `setup.sh`'s hardcoded
`runtime` detection from v0.10.0 (#108) is removed in favor of a
generalized stage auto-emit path (#215). `runtime` still works (it's
not in the new baseline blocklist), but the implementation surface is
different, hence the minor bump.

The 17 existing downstream repos have no `FROM ... AS <name>` stages
beyond the baseline `{sys, base, devel, test}` (plus the optional
`runtime` for `app/ros1_bridge`), so this release is no-op for their
runtime behavior — `make upgrade` just refreshes the template subtree
and the workflow `@tag` refs. New repos seeded by `/new-repo` after
this tag pick up the auto-emit + `--build` UX automatically.

### Added
- **Auto-emit any non-baseline Dockerfile stage as a compose service** (#215, generalizes #108). `setup.sh` now parses every `FROM ... AS <stage>` line in the user's Dockerfile and, for any stage outside the baseline blocklist `{sys, base, devel, test}`, emits a corresponding compose service that `extends: devel` (inherits volumes / network / GPU / GUI / cap_add / additional_contexts) and overrides only `build.target` / `image` / `container_name` / `stdin_open` / `tty` / `profiles`. Use case: NVIDIA Isaac Sim's `headless` + `gui` entrypoint variants on top of `devel`. User flow: edit Dockerfile to add `FROM devel AS headless ENTRYPOINT [...]`, run any wrapper, then `./run.sh -t headless`. No `setup.conf` change required — Dockerfile is the single source of truth.
  - **Stage name validator** (`_validate_stage_name`): rejects baseline collision (`sys` / `base` / `devel` / `test` → hard error, exit 1) and reserved image-tag namespace (`latest`, `v[0-9]*` → hard error). Invalid format (uppercase, leading digit, etc.) is WARN + skip with the rest of the parse continuing. 3 new 4-language i18n keys (`stage_invalid_format` / `stage_baseline_collision` / `stage_reserved_tag`).
  - **Dockerfile drift hash** (`SETUP_DOCKERFILE_HASH` in `.env`): hashes just the stage-list projection (`^FROM ... AS <stage>` lines), so adding / removing a stage triggers `setup.sh check-drift` exit 1 (regenerate compose.yaml), but unrelated `RUN apt-get install` edits do not. Stored separately from `SETUP_CONF_HASH` so drift logs identify which source-of-truth changed.
  - **`runtime` stage no longer special-cased**: the v0.10.0 hardcoded `^FROM ... AS runtime$` detection (#108) is removed. `runtime` falls through the same auto-emit path as any other non-baseline stage (it's not in the blocklist), preserving its behavior with no regressions for repos that rely on it.
- **`run.sh` soft guard + `--build` opt-in for fresh-clone lint/smoke parity** (#216). On a fresh clone with no image cached locally, `./run.sh` previously fell through to Compose's auto-build, which only walks `target: devel` (or whatever `-t` says) and silently bypasses the `target: test` stage where ShellCheck / Hadolint / Bats smoke run. New contributors who reach for `./run.sh` first landed in a working dev container without ever hitting any of the lint/smoke gates that `./build.sh test` enforces — until CI failed downstream. Two changes:
  - **Default behavior — soft guard**: when the image is absent locally AND stderr is a terminal, print a 3-line `[run] INFO:` block before invoking `compose up` so the user knows the auto-build will skip lint/smoke and learns about `./build.sh test` / `./run.sh --build`. No behavior change. Suppressed when stderr is not a TTY (CI / cron / piped invocations stay clean). The image inspect is parameterized on `${TARGET}` so `./run.sh -t headless` checks `${IMAGE_NAME}:headless`, not `:devel` — important under #215 auto-emitted stages. New 4-language i18n keys (`auto_build_image_missing` / `auto_build_skips_lint` / `auto_build_full_hint`).
  - **Opt-in `--build` flag**: invokes `./build.sh test` (full lint + smoke chain) before `compose up`, ordered after `check-drift` so the build runs against freshly-regenerated `.env` / `compose.yaml`. For users who want one-command bootstrap with full local-CI parity. New `pre_build_invoking` i18n key.
  - **Option 4 (default fallback to `./build.sh test`) explicitly rejected** — would silently turn fresh-clone first-run from a few seconds into multiple minutes; that breaks user expectations more than the gap it fixes.
- **`build.sh` / `run.sh` config summary now prints a `Variables` block** mapping `setup.conf` `[volumes]` placeholders (`${USER_NAME}` / `${USER_UID}` / `${USER_GROUP}` / `${USER_GID}` / `${WS_PATH}`) to their detected runtime values. Pre-fix the Identity block showed resolved values under translated labels (`使用者 : alice` / `工作區 : /home/alice/work`), while the `setup.conf` dump printed the raw `${USER_NAME}` / `${WS_PATH}` placeholders, leaving the user to derive the substitution table. The new block sits between Identity and `setup.conf` in `_print_config_summary` and gives an explicit one-line-per-variable map. setup.conf stays the source of truth (placeholder form unchanged); the block adds 5 more lines to the printout. Coverage: 2 new unit tests in `lib_spec.bats` (populated case + unset-fallback case) and a new `variables` i18n key (en / zh-TW / zh-CN / ja).

### Documentation
- **`doc/test/TEST.md` cleanup**: removed 7 stale rows referencing tests that no longer exist (all referencing the obsolete `template/VERSION` / `.template_version` migration completed in v0.16) and renamed 5 rows whose underlying test was renamed (e.g. `_create_symlinks: produces all five docker-script symlinks` → `…all seven docker-script symlinks`, `_detect_template_version: reads VERSION file when present` → `…reads .version file when present`). Added a 27-test `## Smoke Tests` section documenting `test/smoke/script_help.bats` (16) and `test/smoke/display_env.bats` (11), which run at Dockerfile `test`-stage build time and are intentionally excluded from the headline self-test count. Headline now carries an explicit note clarifying scope. No code change.

### Tests
- Total: **969 tests** (915 unit + 54 integration). 34 new tests landed since v0.16.2 — 26 in `setup_spec.bats` (4 validator + 6 parser + 5 hash + 11 emit-loop integration for #215) and 8 in `run_sh_spec.bats` (#216 soft guard + `--build`).

## [v0.16.2] - 2026-05-04

Patch release. Single seed-template alignment fix for `Dockerfile.example`.
Existing 17 downstream repos are unaffected (`make upgrade` does not touch
downstream root Dockerfiles, and they already declare both ENVs); this only
matters for new repos seeded by `/new-repo` going forward.

### Changed
- **`Dockerfile.example` adds `ENV TZ` and `ENV LANGUAGE` to align with downstream fleet** (#210). All 17 hand-written downstream Dockerfiles already declare `ENV TZ="${TZ}"` and `ENV LANGUAGE="en_US:en"` alongside `ENV LC_ALL` / `ENV LANG`; the seed `Dockerfile.example` only had the latter pair. Pre-fix, new repos generated by `/new-repo` silently differed from the fleet on these two runtime env vars — the gap surfaces only for consumers that read the env directly (Python `tzlocal`, `gettext` translation fallback that uses `$LANGUAGE`, certain JVM tz resolution paths). The build-time `${TZ}` ARG handling and `/etc/timezone` write are unchanged. Coverage: 2 new structural tests in `template_spec.bats` lock the ENV declarations in the seed.

## [v0.16.1] - 2026-05-04

Patch release. Two CI plumbing fixes that surfaced from `seggpt`'s
v0.16.0 adoption — neither breaks the 17 existing downstreams (their
CI was already passing), but both unblock new repos using
`Dockerfile.example` verbatim or `setup.conf [additional_contexts]`.

### Added
- **`build-worker.yaml` accepts `build_contexts` input forwarding to `docker/build-push-action`'s `build-contexts:`** (#207). v0.16.0 (#199) added compose's `additional_contexts:` so that local `./build.sh` (which goes through `docker compose build`) could use named contexts in `Dockerfile` `COPY --from=<name>` lines. CI bypassed compose entirely — `build-worker.yaml` calls `docker/build-push-action@v7` directly — so the same `setup.conf [additional_contexts]` entry that worked locally failed in CI with `failed to resolve source metadata: no source for '<name>'`. Fix: new `build_contexts` workflow input (default `""`) plumbs caller-supplied `<name>=<location>` pairs into all 3 build steps' `build-contexts:` field. Caller usage: `with: build_contexts: \|\n  repo_root=.`. Path semantics differ from compose's `additional_contexts:` because `docker/build-push-action` resolves `build-contexts:` paths relative to the repo root (the `actions/checkout` working dir), NOT to `context:` — so a caller using `context_path: docker` writes `repo_root=.` here even though the same context in `setup.conf` is `repo_root=..`. Default empty preserves zero-diff for existing callers. Coverage: 3 new `build_worker_yaml_spec.bats` tests (input declaration, 3-step plumbing, zero-diff default).

### Fixed
- **`build-worker.yaml` user build-args now match `Dockerfile.example` sys-stage names** (#198). Pre-fix the workflow passed `USER=ci` / `GROUP=ci` / `UID=1000` / `GID=1000` (short form) to all 3 `docker/build-push-action` calls, while `Dockerfile.example`'s sys stage `useradd` reads `USER_NAME` / `USER_GROUP` / `USER_UID` / `USER_GID` (long form, also what the same workflow's "Generate .env" step writes). Result: `useradd` created `user` (the Dockerfile default), but the devel stage's `ARG USER="${USER_NAME}"` got overridden by the build-arg `USER=ci` so `USER "${USER}"` switched the image to UID-with-no-passwd-entry, exploding any subsequent `RUN` that resolved the username — `seggpt`'s CI hit `unable to find user ci: no matching entries in passwd file`. Fix: rename the 12 build-args lines (3 steps × 4 args) to long form so they hit the Dockerfile's sys-stage ARGs directly. No downstream Dockerfile change required (every existing `Dockerfile.example`-derived Dockerfile already declares the long-form ARGs). Coverage: 5 new `build_worker_yaml_spec.bats` tests lock the long-form invariant + assert no short-form regression.

## [v0.16.0] - 2026-04-30

Minor release bundling three setup.conf-area changes. Includes a
**BREAKING** restructure: `setup.conf.local` (introduced in #174) is
gone — the user override now lives at `<repo>/setup.conf` (committed,
not gitignored). Run `.claude/scripts/migrate-local-to-setupconf.sh`
on each repo before upgrading, or rename the file by hand.

### Changed
- **BREAKING: collapsed `setup.conf.local` + `setup.conf` snapshot back to a single `<repo>/setup.conf` user-override file** (#201). The post-#174 3-file model (`template/setup.conf` defaults + `<repo>/setup.conf` derived snapshot + `<repo>/setup.conf.local` user override) was redundant — the snapshot had no semantic effect on reads (`_load_setup_conf` only consulted `.local` + template), and a real bug fell out of the gap: bootstrap wrote `mount_1` to `<repo>/setup.conf` and immediately reloaded via a path that ignored that file, so a fresh `setup.sh apply` against an empty directory produced a `compose.yaml` with no workspace mount. The 2-file model is the pre-#174 layout with one critical addition kept from #174: bootstrap writes the **portable** form `${WS_PATH}:/home/${USER_NAME}/work` (not an absolute host path), so committing `<repo>/setup.conf` no longer leaks per-machine paths into git history. Surface area: `_load_setup_conf` now reads `<repo>/setup.conf` → falls back to `template/setup.conf`; `_compute_conf_hash` hashes the same pair; `setup.sh set / add / remove` write to `<repo>/setup.conf`; `setup.sh reset` backs up + clears `<repo>/setup.conf` only (no more `.local` to clear); the TUI saves to `<repo>/setup.conf`; `script/docker/lib/gitignore.sh` removes `setup.conf` from the canonical entries (it is now a tracked file) and adds `setup.conf.local` (so leftover `.local` files from earlier installs don't accidentally re-appear in commits); `init.sh` drops the now-obsolete `_migrate_setup_conf_to_local` helper; `upgrade.sh` adds `_warn_setup_conf_drift` mirroring `_warn_config_drift` so users see when upstream `template/setup.conf` adds new sections / keys and can opt into them by hand-merging into `<repo>/setup.conf`. Migration: `.claude/scripts/migrate-local-to-setupconf.sh` (one-shot, deletes after the v0.16.x cycle) renames each downstream repo's `setup.conf.local` to `setup.conf` and stages the diff; the same `init.sh` resync that would run on the next template upgrade then drops the old `setup.conf` line from `.gitignore` and adds `setup.conf.local`.

### Fixed
- **Bootstrap workspace mount no longer lost on fresh `setup.sh apply`** (#201). Pre-#201 a fresh `apply` against an empty directory wrote `mount_1 = ${WS_PATH}:/home/${USER_NAME}/work` to a file (`<repo>/setup.conf`) that the next reload step ignored, so `compose.yaml` ended up without the workspace mount. Post-#201 the same write target is the read source, so the mount lands in `compose.yaml` on first apply. Locked in by a new `setup_spec.bats` regression test that mkdir's an empty dir, runs `main apply`, and asserts the `${WS_PATH}:/home/${USER_NAME}/work` line appears in the generated compose.

### Added
- **`[additional_contexts]` section in `setup.conf` for compose's `build.additional_contexts`** (#199). Lets repos that keep source / `pyproject.toml` at the repo root (while docker assets live under a `docker/` subfolder) pull files into the build context without flipping the main `context:` root. Each `context_N = <name>=<source>` entry forwards to compose under every service that has its own `build:` (devel / runtime / test); empty list emits no `additional_contexts:` block, so the 17 existing downstream repos see zero diff. Inside the Dockerfile, reference the named context with `COPY --from=<name>` or `FROM <name> AS <stage>`. `<source>` accepts anything BuildKit takes — relative paths (`..`, `../third_party`), `docker-image://`, `https://`, `oci-layout://`. Use case: `ycpss91255-docker/seggpt` wants to `pip install -e .` at build time, baking the Python package into the image instead of relying on a runtime entrypoint install. Also adds: a `setup_tui.sh` flow under the Advanced menu for managing entries (mirrors the existing volumes / env list editor with the same add / edit / remove / cancel paths), `_validate_additional_context` validator (`<name>` matches BuildKit's named-context naming, `<source>` must be non-empty), 4-language i18n entries (en / zh-TW / zh-CN / ja). Coverage: 6 new unit tests for the parser + compose emission (`setup_spec.bats`), 5 for the validator (`tui_spec.bats`), 9 for the TUI flow (`tui_flow.bats`).

### Tests
- **Per-section setup.conf parameter end-to-end coverage** (#202). 25 new tests that set a single key in `<repo>/setup.conf`, run `main apply`, and assert the corresponding line appears in `compose.yaml` or `.env`. Companion negative tests confirm the block is omitted when the key is empty / cleared. Sections newly covered: `[deploy]` (gpu_mode/count/capabilities/runtime), `[gui]` (mode), `[network]` (mode/ipc/network_name/port_*), `[resources]` (shm_size), `[environment]` (env_*), `[tmpfs]` (tmpfs_*), `[devices]` (device_*/cgroup_rule_*), plus extras for `[volumes]` mount_2..N and `[security]` privileged. Existing coverage (untouched): `[image]` rule engine, `[build]` arg_N / target_arch / network, `[security]` cap_add / security_opt fallback, `[volumes]` mount_1 workspace, `[additional_contexts]` parse + emit. 923 tests total (869 unit + 54 integration).

## [v0.15.0] - 2026-04-30

Minor release. Single feature: nested Dockerfile support in the
`build-worker.yaml` reusable workflow (#195). Backwards compatible —
the 17 existing downstream repos see no CI change unless they opt
in by adding `with: context_path: <subdir>` to their main.yaml.

### Added
- **`build-worker.yaml` accepts `context_path` / `dockerfile_path` inputs** (#195). Lets downstream repos that nest their docker assets in a subdirectory (e.g. `docker/Dockerfile`, `docker/compose.yaml`) call the reusable workflow with `with: context_path: docker` instead of being forced to keep the Dockerfile at repo root. Both inputs default to current behaviour (`context_path: "."`, `dockerfile_path: ""` → falls back to `<context_path>/Dockerfile`), so the 17 existing downstream repos see no CI change. Use case discovered while migrating `ycpss91255-docker/seggpt`, where the docker environment lives under `seggpt/docker/` to keep template-managed files separate from `src/` and `test/`. Three new `test/unit/build_worker_yaml_spec.bats` tests lock the input forwarding so a future refactor can't silently revert one of the 3 build steps.

## [v0.14.0] - 2026-04-29

Minor release. Two test / quality follow-ups on top of v0.13.0, no
behavior changes for downstream consumers (the new WARN level on the
template-default fallback notice is the only user-visible surface
shift, and matches what the existing log-text already implied).

### Added
- **`test/unit/tui_flow.bats` lifts `setup_tui.sh` coverage from 18% to 83%** (#189). 44 new interactive-flow tests covering the 5 high-value areas the issue body called out: `_edit_image_rule` + `_compact_image_rules_after_remove` (#177 regression site), `_render_main_menu` / `_render_advanced_menu` (#178 Save & Exit unification), `_edit_list_section` mount/env/port CRUD, Save & Exit / Cancel / Esc abort handling, plus `_swap_image_rule` and several `_edit_section_*` dispatches. Same mock-driven pattern as `tui_backend_spec.bats` — file-backed queue stubs the dialog wrappers (queue line popped via `head -n 1` + `sed -i 1d` so state survives `$(...)` subshell calls), each test scripts the user's click path and asserts on `_TUI_OVR_*` / `_TUI_REMOVED` / `_TUI_CURRENT` outcomes. No real `dialog` / `whiptail` ever launches.

### Changed
- **`setup_tui.sh` 4-language i18n tables expanded to per-key assignments** (#189 prerequisite). The previous `declare -gA _TUI_MSG_<LANG>=([k]=v ... [k]=v)` literal blocks (~600 lines across en / zh-TW / zh-CN / ja) compiled into a single statement under kcov, so individual entries showed as 0 hits even when reached and capped achievable per-file coverage at ~45%. Each entry is now its own `_TUI_MSG_<LANG>[k]=v` assignment line, which kcov tracks separately. Runtime behavior is identical — `_tui_msg` still does the same associative-array lookup with English fallback. This is what makes the #189 >=70% target reachable; with the new tests the file lands at 83.29% (897 / 1077 lines).
- **CI `make` package added to the kcov coverage container's apt-install list**. The downstream-Makefile integration tests added in #175 / #182 (`make upgrade-check (downstream Makefile): exit 0 when ...`) shelled out to a `make` binary that the `kcov/kcov` image's apt repo doesn't ship by default, so they exited 127 only under `make coverage` even though they passed under `make test` (where the alpine test-tools image bundles `make` from #182). `script/ci/ci.sh`'s apt-install line now lists `make`, closing the env gap so coverage runs see the same recipes the regular CI does.
- **Template-default fallback notice promoted from INFO to WARN** (#186). `_announce_template_default_fallback` in `script/docker/setup.sh` now emits `[setup] WARN:` instead of `[setup] INFO:` when the per-repo `setup.conf.local` is missing or has no `[section]` headers. INFO scrolled past in normal `build.sh` / `run.sh` output and users missed the heads-up that template defaults were silently in effect; WARN matches the semantics (this is an unusual configuration state worth flagging, not a routine status line). The two i18n keys also rename `info_no_repo_conf` → `warn_no_repo_conf` and `info_empty_repo_conf` → `warn_empty_repo_conf` across all four languages so the message table stays self-describing.

## [v0.13.0] - 2026-04-29

Minor release introducing the `setup.conf.local` user-override file.
`setup.conf` is now a derived artifact (canonical-gitignored), regenerated
by `setup.sh apply` from `template/setup.conf` overlaid by
`setup.conf.local`. Existing repos auto-migrate on the next `make upgrade`
(`init.sh` copies any tracked `setup.conf` to `setup.conf.local` before
the gitignore sync's `git rm --cached`). No breaking changes from v0.12.4
for end-users — the migration is in-place and idempotent.

### Added
- **`setup.conf` is now a derived artifact; user overrides live in `setup.conf.local`** (#174). Pre-#174 `setup.conf` was tracked by every downstream repo and mixed two semantically different kinds of data: machine-specific workspace writeback (the absolute `[volumes] mount_1` path baked by `setup.sh` on first init) and user override (`[image] rules`, `[deploy] gpu`, etc. the user edits to deviate from the template baseline). Git history therefore permanently leaked each contributor's home directory — the v0.9.4 portable-form auto-migration was a workaround, not a fix. Post-#174 `setup.conf` is canonical-gitignored and regenerated by `setup.sh apply` from `template/setup.conf` ← `setup.conf.local` (section-replace strategy). User overrides move to a tracked `setup.conf.local`; absent files mean "use template defaults". Implementation surface: `lib/gitignore.sh` adds `setup.conf` to the canonical entries, `_load_setup_conf` reads `.local` (not `setup.conf`), `_compute_conf_hash` hashes `template + .local` for drift detection, `setup.sh set / add / remove` and the TUI write to `.local` (bootstrap empty when missing — no more whole-template copy on first edit), `setup.sh show / list` use a new `_setup_load_merged_full` helper to display the merged effective view, `setup.sh reset` clears both `.local` and `setup.conf`, and `init.sh`'s existing-repo path migrates a tracked `setup.conf` into `setup.conf.local` once before the gitignore sync's `git rm --cached` step — idempotent + skipped when `.local` already exists. Old-format detection logic (warn + auto-migrate stale absolute `mount_1` paths from another contributor's clone) is no longer needed and was removed because the underlying leak vector (committed `setup.conf`) is gone at the source.

### Documentation
- **README upgrade section now spells out `make upgrade` preserve-vs-regenerate semantics** (4 languages). Three existing sub-sections expanded inline (no new headings): `When setup.sh runs` adds a bullet for the upgrade path and notes that `setup.sh apply` preserves `WS_PATH` / `APT_MIRROR_*` from any existing `.env`; `Derived artifacts (gitignored)` calls out that `.env` / `compose.yaml` are regenerated on every upgrade; `Updating` replaces the dense one-liner with a numbered 4-step list and adds a prerequisites paragraph (git identity / clean merge state), an implicit-downgrade-refusal comment in the `make upgrade VERSION=` snippet, and a closing paragraph documenting that `<repo>/setup.conf` and `<repo>/config/` stay user-owned with a `diff -ruN template/config config` hint when upstream `template/config/` moved. Surfaced gaps that previously required reading `upgrade.sh` source: pre-flight guards (`_require_git_identity` / `_require_clean_merge_state`), `_warn_config_drift`, `Refusing implicit downgrade`, and the fact that `init.sh` (called by `upgrade.sh` step 3) also syncs `.gitignore` and runs `setup.sh apply`.

### Fixed
- **`_write_setup_conf` no longer wipes the file when dst and tpl alias the same path** (#187). `setup_tui.sh::_commit_and_setup` passes the per-repo conf as both arguments after the first save (`_template_src="${_repo_conf}"` when `<repo>/setup.conf` exists), so `: > "${_dst}"` truncated the file before the `while ... done < "${_tpl}"` loop opened it for reading — the read landed on an empty file, the loop body never ran, and the user's entire per-repo configuration was silently destroyed (saving from the TUI exited with the success banner but produced 0 bytes on disk; `setup.sh apply` then fell back to template defaults). Now slurp the template into a `__tpl_lines` array up front and iterate that, so the truncate-and-rewrite is safe regardless of whether dst and tpl are distinct files. Same regression guards through `--reset-conf` followed by a TUI Save (Save runs immediately after build.sh's bootstrap apply emits a fresh `<repo>/setup.conf`, hitting the same aliasing path). One new unit test exercises the dst==tpl path directly.
- **`Dockerfile.example`: drop dead `COPY compose.yaml /lint/compose.yaml`**. The /lint stage shellcheck'd `.sh` and hadolint'd `Dockerfile` but never read `/lint/compose.yaml` — the COPY was leftover scaffolding from earlier iterations. After v0.12.4 (#172) made `compose.yaml` a derived artifact (gitignored + `git rm --cached`), fresh CI checkouts no longer have the file and `docker/build-push-action`'s COPY step started failing on the build context for new repos generated from this template. The same dead-code line was patched out of the 10 affected v0.12.4 batch-upgrade PRs to unblock the rollout.

## [v0.12.4] - 2026-04-29

Patch release bundling two Makefile / setup-tui fixes plus the
template-managed `.gitignore` plumbing introduced in #172. No new
features, no breaking changes from v0.12.3.

### Fixed
- **`setup_tui` image rules are compacted on delete** (#177). Removing `rule_n` previously only marked the slot as removed, leaving `rule_(n+1) .. rule_max` with their original numbers; the next "add" then allocated `max + 1` instead of backfilling the gap, so the user was left looking at sparse indices like `rule_2, rule_3, rule_5`. The `__remove` branch in `_edit_image_rule` now calls a new `_compact_image_rules_after_remove` helper that shifts all higher-numbered rules down by one slot, so the menu always shows `rule_1 .. rule_M` consecutive and `add` allocates `M + 1` cleanly. The compaction loop walks occupied slots in ascending order and uses the existing override / removal primitives, so the in-memory mutation flows through to `_write_setup_conf` without any save-path changes.
- **`make upgrade-check` no longer surfaces a fake `Error 1`** (#175). `upgrade.sh --check` exits 1 when an update is available — a deliberate shell convention so `if ./upgrade.sh --check; then ...` reads naturally — but `script/docker/Makefile` and `Makefile.ci` invoked the script directly, so make treated the exit as a build failure and printed `make: *** [Makefile:28: upgrade-check] Error 1` after the otherwise-correct "Update available: vX → vY" line. Both Makefile recipes now wrap the call as `./upgrade.sh --check || [ $$? -eq 1 ]` so make sees success when the check itself succeeded; exit codes ≥2 (genuine network / missing-`template/` failures) still propagate. Two new unit tests guard the wrap pattern in each Makefile, two new integration tests run the recipe end-to-end through real `make` (the `test-tools` image now installs GNU `make` for this purpose, and `release-test-tools.yaml` smoke step adds `make --version`).

### Changed
- **`setup_tui` Save & Exit lives in the menu body on both backends** (#178). dialog used to render Save as a third footer button via `--extra-button --extra-label "Save"` while whiptail (no `--extra-button` equivalent — newt library limitation) injected a synthetic `__save` menu entry. The same repo therefore looked and behaved differently on a stock Ubuntu host (whiptail-only) versus a host with `dialog` installed, so screenshots and docs could not be shared. After this change both backends use the synthetic `__save` entry — placed last in the main menu — for identical UX, screenshots, and docs. Trade-off: dialog users lose the one-keystroke Save (must move cursor onto `__save` then press Enter); the unified UX is worth the extra step. Side cleanups: `_tui_menu` no longer reads `TUI_EXTRA_LABEL` (the env hook is now a no-op rather than removed, so unrelated callers keep working); `_render_advanced_menu` drops the `TUI_EXTRA_LABEL` save/restore dance; the OK/Cancel label translation in `_tui_run` (introduced in #136 for whiptail-spelling) stays untouched.

### Added
- **`.gitignore` is now template-managed** (#172). Two new helpers in `template/script/docker/lib/gitignore.sh` — `_sync_gitignore <path>` (append-missing strategy: idempotent, preserves user-defined lines, leaves a `# managed by template (do not remove)` marker on first sync) and `_untrack_canonical_in_repo <repo>` (`git rm --cached` for any canonical entry that's still git-tracked) — wire into both `init.sh` paths and propagate through `upgrade.sh`. Canonical set: `.env`, `.env.bak`, `compose.yaml`, `setup.conf.bak`, `coverage/`, `.Dockerfile.generated`. Future derived artifacts get appended to the lib in a later release and downstream repos pick them up automatically on the next `make upgrade`. The wiring also heals the v0.9.0+ drift where 15/17 downstream repos still git-tracked `compose.yaml` despite it being a derived artifact: the next batch-upgrade emits the `git rm --cached` in the same commit as the workflow `@tag` rewrite, with no separate sweep PR.

## [v0.12.3] - 2026-04-28

Patch release that completes the test-tools migration started in v0.12.2 (#165 + #164) and fixes a bash 5.3 silent-exit bug in `upgrade.sh --check` exposed by the alpine runner. No breaking changes from v0.12.2.

### Fixed
- **`upgrade.sh --check` no longer silently dies on alpine** (#168 follow-up). `_get_latest_version`'s pipe (`git ls-remote | grep -oP | head -1 | sed`) ends with `head -1` closing stdin, which SIGPIPE's the upstream `grep -oP`; with `pipefail` set, the pipe inherits that non-zero exit. Bash 5.3 (alpine 3.23 — the test-tools image runner) propagates the failed command-substitution exit through the caller's `set -e` and kills the script before any `_log` line runs; bash 5.2 (debian bookworm — the previous kcov/kcov runner) does not. Symptom was integration test #41 (`upgrade.sh --check reports update available from v0.9.5 → v0.9.7`) failing ~80% of runs on alpine with completely empty output but passing 100% on debian, with identical Dockerfile / upgrade.sh / bats version. Wrapped the pipe in `|| true` so the function unconditionally returns 0; the existing `[[ -z latest_ver ]]` → `_error "Could not fetch ..."` guard in `_check` still surfaces real network failures with a clear message.

### Changed
- **`compose.yaml` splits the `ci` runner into `ci` (fast) + `coverage` (kcov) services** (#168). The fast `ci` service now uses the prebuilt `ghcr.io/ycpss91255-docker/test-tools:latest` (alpine, with bats / shellcheck / hadolint / bats-{support,assert,mock} / parallel baked in), so `_install_deps` short-circuits via its `command -v bats` guard and no apt-install runs on each `make -f Makefile.ci test`. The `coverage` service stays on `kcov/kcov` and keeps the `APT_MIRROR_DEBIAN` plumbing introduced in v0.12.2 (kcov/kcov is debian-based and still apt-installs bats for the `--coverage` path). `_run_via_compose` takes a service-name first arg so `main()` routes default mode → `ci`, `--coverage` → `coverage`. Override the image with `TEST_TOOLS_IMAGE=...` for local rebuild flows.

### Added
- **`Dockerfile.test-tools` ships `parallel`** (#168). `bats --jobs N` delegates to GNU parallel; without it bats fails with `parallel: command not found`. `apk add parallel` makes the prebuilt image self-sufficient for the parallel fast-CI path. `release-test-tools.yaml` smoke step extended with `parallel --version` so a missing-parallel regression can't ship silently.
- **`_run_tests` graceful fallback to serial bats when parallel is missing** (#168). Older test-tools images (v0.12.2 and earlier) ship without parallel; the fallback lets downstream consumers running an older `test-tools:<tag>` still execute the test suite (slower) instead of hard-failing. New images carry parallel, so this fallback is dormant on `:latest`.

## [v0.12.2] - 2026-04-28

Patch release with two related test-tools fixes. No new features, no breaking changes from v0.12.1.

### Fixed
- **`Dockerfile.test-tools`: bats now runnable in the published image** (#165). The alpine-based final stage was missing `bash` (required by bats's `#!/usr/bin/env bash` entry point) and the `/usr/local/bin/bats` symlink (the upstream `bats/bats:latest` ships it but it lives outside `/opt/bats`, so the existing `COPY --from=bats-src /opt/bats /opt/bats` did not pick it up). `apk add bash` and `ln -s /opt/bats/bin/bats /usr/local/bin/bats` restore both. `release-test-tools.yaml` now runs `bats --version`, `shellcheck --version`, `hadolint --version` against the just-pushed image as a regression guard so a similar break can't ship silently again.
- **`compose.yaml` / `ci.sh::_install_deps`: `make -f Makefile.ci test` no longer hard-fails on networks where `deb.debian.org` is unreachable** (#164). The kcov/kcov-based `ci` service had no apt-mirror plumbing, so `apt-get update` always pointed at the upstream Debian archive even when the host's TW mirror responded normally. `compose.yaml` now propagates `APT_MIRROR_DEBIAN` (default `deb.debian.org`, no-op when unset) into the container, and `_install_deps` rewrites `/etc/apt/sources.list` (and `sources.list.d/*.list` / `*.sources`) with `sed` before running `apt-get update` whenever the env var differs from the default. Set `APT_MIRROR_DEBIAN=mirror.twds.com.tw` (or any reachable Debian mirror) on the host before invoking `make test` / `make coverage` to opt into the rewrite. The cleaner long-term fix — switching the `ci` service to the published `test-tools` image so the apt-install path is bypassed entirely — is tracked separately and depends on this image rebuild landing first.

## [v0.12.1] - 2026-04-28

Patch release containing a single bug fix to `upgrade.sh`'s version comparator. No new features, no breaking changes from v0.12.0.

### Fixed
- **`upgrade.sh --check` (and `make upgrade-check`) no longer reports a downgrade when the local pin is a prerelease ahead of the latest stable tag** (#156). Previously the comparator used plain string equality (`==`) — so a downstream pinned to `v0.12.0-rc1` while the org's latest stable was still `v0.11.0` would print `Update available: v0.12.0-rc1 → v0.11.0` and exit 1, telling the user to roll back. The new `_semver_cmp` helper applies SemVer §11 (pre-release < associated final), so `_check` now correctly classifies the three real-world cases: equal (exit 0, "Already up to date"), behind (exit 1, "Update available"), and ahead (exit 0, "Local is ahead of latest stable"). `_upgrade <older>` from a newer local version is also now refused with an explicit "Refusing implicit downgrade" error before any subtree pull, so a typo'd `make upgrade VERSION=v0.11.0` on a v0.12.0-rc1 working tree no longer silently rolls back the prerelease pin.

### Added
- **`_semver_cmp <a> <b>`** in `upgrade.sh` — pure-bash SemVer §11 comparator. Returns 0 / 1 / 2 for equal / a<b / a>b. Handles only the shape this project ships (`vMAJOR.MINOR.PATCH[-PRERELEASE]`) but applies §11 correctly: `sort -V` puts pre-releases AFTER finals (treats `-` as "less than empty"), which is wrong for our use case once a stable tag exists alongside its earlier `-rc` tags.

## [v0.12.0] - 2026-04-28

Stable promotion of [v0.12.0-rc2](https://github.com/ycpss91255-docker/template/releases/tag/v0.12.0-rc2). Two small developer-experience features and one consumer-facing bug fix; no breaking changes from v0.11.0.

### Added
- **`make -f Makefile.ci upgrade VERSION=vX.Y.Z`** pins the subtree pull to a specific tag (#152). The recipe forwards `$(VERSION)` to `./upgrade.sh`, so the no-arg form still resolves to the latest stable tag. `make` is the documented entry point for both flows; `./template/upgrade.sh` remains as a fallback when `make` is unavailable.
- **`setup.sh apply` / `setup.sh check-drift`** announce when the per-repo `setup.conf` provides no overrides (#150 / #153 / #157). On entry, if the per-repo `setup.conf` is missing or contains no `[section]` headers, both subcommands print `[setup] INFO: …` to stderr. Partial overrides (some sections present) stay silent — that is normal usage. Translated in 4 languages via `_setup_msg`. `_print_config_summary` (in `_lib.sh`) emits a parallel `(setup.conf has no section overrides — using template defaults; …)` hint inside the file-exists branch via the new `_lib_msg conf_empty` key.

### Fixed
- **`make upgrade` / `make upgrade-check` no longer fails with `No such file or directory`** in fresh consumer repos (#154). The downstream-facing `template/script/docker/Makefile` (symlinked into every repo's root) was calling `./template/script/upgrade.sh`, but `upgrade.sh` lives at template root: `./template/upgrade.sh`. The wrong path slipped in around v0.10.x and went undetected because no test asserted the target's recipe. Path corrected and a regression test added.

### Migration

Downstream repos upgrading from v0.11.0:

1. Bump `main.yaml`'s `@<version>` to `@v0.12.0`.
2. Bump `test_tools_version: v0.12.0`.
3. Run `make -f Makefile.ci upgrade VERSION=v0.12.0` (handles subtree pull + `init.sh` resync + `main.yaml` `@tag` sed automatically).

For repos still on v0.10.x or earlier (no `template/.version` file, see #151), the first hop must use the fallback path because the older `Makefile.ci` doesn't forward `VERSION`:

```bash
./template/upgrade.sh v0.12.0
```

Subsequent upgrades from v0.12.0+ can use `make` directly.

### Known issues

- **#156**: `upgrade.sh --check` uses string equality, not semver-aware comparison. Repos sitting on a prerelease (e.g. `v0.12.0-rc2`) and running `make upgrade-check` get a misleading "Update available: <prerelease> → <older stable>" pointing at a downgrade. Workaround: `./template/upgrade.sh <target>` accepts an explicit version. Will be fixed in a future patch release.
- **#151**: 15 downstream repos (`agent/*`, `app/*` minus `ros1_bridge`, most of `env/*`) are still on the pre-v0.10.x template subtree and need a one-time `./template/upgrade.sh v0.12.0` bootstrap. Tracked separately.

## [v0.12.0-rc2] - 2026-04-28

Second RC for v0.12.0. Promotes rc1 forward with one fix that completes the empty-setup.conf INFO scope first introduced in rc1. No new features beyond rc1.

### Fixed
- **Empty setup.conf no longer silent on `build.sh` / `run.sh` rebuild path** (#157, #158). The INFO line added in v0.12.0-rc1 (#150 / #153) only fired on the `setup.sh apply` path. Rebuilds where `.env` / `setup.conf` / `compose.yaml` already exist took the `setup.sh check-drift` path instead, which had no INFO. Two-part fix: (1) extracted `_announce_template_default_fallback` helper in `setup.sh` and now call it from both `_setup_apply` and `_setup_check_drift` entries; (2) `_print_config_summary` (in `_lib.sh`) now emits `(setup.conf has no section overrides — using template defaults; …)` inside the file-exists branch, mirroring the existing `conf_missing` hint. New `_lib_msg conf_empty` translated in 4 languages.

### Migration

Same as rc1. Downstream repos validating v0.12.0:

```bash
./template/upgrade.sh v0.12.0-rc2   # one-shot, bypasses upgrade.sh's "latest stable" filter
```

(Direct `make -f Makefile.ci upgrade VERSION=v0.12.0-rc2` will work AFTER you reach v0.12.0-rc1+; for the very first hop from v0.11.0 use the fallback above. Tracking in #156: `upgrade.sh --check` doesn't yet do semver-aware comparison.)

## [v0.12.0-rc1] - 2026-04-28

Release candidate for v0.12.0. Two small developer-experience features (`make -f Makefile.ci upgrade VERSION=...`, `setup.sh apply` template-default INFO) plus a bug fix to the downstream `make upgrade` recipe. No breaking changes; downstream repos can `make -f Makefile.ci upgrade VERSION=v0.12.0-rc1` and verify before promoting to stable.

### Added
- **`make -f Makefile.ci upgrade` now accepts an optional `VERSION` variable** (#152). `make -f Makefile.ci upgrade VERSION=vX.Y.Z` pins the subtree pull to a specific tag; `make -f Makefile.ci upgrade` (no `VERSION`) keeps resolving the latest tag. The recipe forwards `$(VERSION)` to `./upgrade.sh`, so empty expands to the no-arg form. This makes `make` the documented entry point for both latest and pinned upgrades; `./template/upgrade.sh` remains as a fallback when `make` is unavailable.
- **`setup.sh apply` now announces when it falls back to template defaults** (#150 / #153). On apply entry, if the per-repo `setup.conf` is missing, `setup.sh` prints `[setup] INFO: no per-repo setup.conf — using template defaults for all sections` to stderr; if the file exists but contains no `[section]` headers (comments / whitespace only), it prints `[setup] INFO: per-repo setup.conf has no section overrides — …`. Partial overrides (some sections present) stay silent — that is normal usage. Both messages are i18n'd in the four supported languages via `_setup_msg`. Previously the per-section fallback inside `_load_setup_conf` was silent for all 11 sections, leaving fresh-clone users with no signal that their entire run was template-default driven.

### Fixed
- **`make upgrade` / `make upgrade-check` no longer fails with `No such file or directory`** in fresh consumer repos (#154). The downstream-facing `template/script/docker/Makefile` (symlinked into every repo's root) was calling `./template/script/upgrade.sh`, but `upgrade.sh` lives at template root (`./template/upgrade.sh`). The wrong path slipped in around v0.10.x and went undetected because no test asserted the target's recipe. Path corrected and a regression test added.

### Migration

Downstream repos upgrading from v0.11.0:

1. Bump `main.yaml`'s `@<version>` to `@v0.12.0-rc1`.
2. Bump `test_tools_version: v0.12.0-rc1`.
3. Run `make -f Makefile.ci upgrade VERSION=v0.12.0-rc1` (handles subtree pull + `init.sh` resync + `main.yaml` `@tag` sed automatically).

## [v0.11.0] - 2026-04-27

Stable promotion of [v0.11.0-rc1](https://github.com/ycpss91255-docker/template/releases/tag/v0.11.0-rc1). Closes Phase B of #49 — `setup.sh` is now a git-style CLI backend (`apply` / `check-drift` / `set` / `show` / `list` / `add` / `remove` / `reset`). **BREAKING** for any caller invoking `setup.sh` without a subcommand.

Post-rc1 additions: a batch of GitHub Actions Node 24 upgrades (every action we use is now on Node 24) plus README / TEST.md alignment fixes found in a full audit sweep.

### Added
- All rc1 work (subcommand dispatcher #138, set/show/list #142, add/remove #143, reset #144). See [v0.11.0-rc1] block below for full details.

### Changed
- **GitHub Actions runtime bumped to Node 24** across every reusable workflow downstream repos call (#111–#115 dependabot batch + #147 manual qemu/login bump):
  - `actions/checkout` v4 → v6 (#111)
  - `codecov/codecov-action` v5 → v6 (#112)
  - `softprops/action-gh-release` v2 → v3 (#113)
  - `docker/setup-buildx-action` v3 → v4 (#114) — also drops deprecated `install` input (we never used it)
  - `docker/build-push-action` v6 → v7 (#115) — also drops `DOCKER_BUILD_NO_SUMMARY` / `DOCKER_BUILD_EXPORT_RETENTION_DAYS` envs (we never set them)
  - `docker/setup-qemu-action` v3 → v4 (#147) — manual bump (dependabot's batch hit `open-pull-requests-limit: 5`; picked up so v0.11.0's Node 24 coverage is complete)
  - `docker/login-action` v3 → v4 (#147) — same reason

  Requires Actions Runner ≥ v2.327.1, which GitHub-hosted runners have shipped since 2025-09. Self-hosted fleets must update before pinning to `@v0.11.0`.

### Fixed
- **Doc alignment caught in audit sweep** (#146 / #148):
  - `[Unreleased]` had not been updated by the dependabot batch (CLAUDE.md `變更完成 checklist` now explicitly covers bot PRs)
  - 4-language README missing `setup.sh subcommands` section + BREAKING migration table
  - `build-worker.yaml inputs` table missing `platforms` + `test_tools_version` inputs (added in v0.10.0 / v0.10.1)
  - English README missing the `### Interactive TUI` section that 3 translations carried (4-lang structural parity restored)
  - `TEST.md` per-spec counts for `bashrc_spec.bats` (14 → 18) and `upgrade_spec.bats` (20 → 18) had drifted

### Migration

Downstream repos upgrading from v0.10.x:

1. Bump `main.yaml`'s `@<version>` to `@v0.11.0`.
2. Bump `test_tools_version: v0.11.0`.
3. If any custom script invokes `setup.sh` directly without a subcommand, prepend `apply`. Bundled `build.sh` / `run.sh` / `init.sh` / `setup_tui.sh` are already updated.
4. Run `./template/upgrade.sh v0.11.0` (handles subtree pull + `init.sh` resync + `main.yaml` `@tag` sed automatically).

## [v0.11.0-rc1] - 2026-04-27

Release candidate for v0.11.0. Closes Phase B of #49 — the `setup.sh` CLI is now a git-style backend with `apply` / `check-drift` / `set` / `show` / `list` / `add` / `remove` / `reset` subcommands. **BREAKING** for any caller invoking `setup.sh` without a subcommand.

Validate downstream before promoting to stable: pull `ghcr.io/ycpss91255-docker/test-tools:v0.11.0-rc1`, bump one repo's `main.yaml` to `@v0.11.0-rc1` + `test_tools_version: v0.11.0-rc1`, and confirm `./build.sh test` passes.

### Added
- **`setup.sh` git-style subcommand dispatcher** (#49 Phase B-1). New explicit subcommands: `apply` (regenerate `.env` + `compose.yaml`) and `check-drift` (compare current state against `.env`'s `SETUP_*` metadata, exit 0 when in sync / 1 when drift detected). `build.sh` / `run.sh` switched their drift-check from `source setup.sh` + `_check_setup_drift` to `bash setup.sh check-drift` (subprocess), structurally closing the `_msg` shadow bug class behind #101.
- **`setup.sh set` / `show` / `list` subcommands** (#49 Phase B-2). `set <section>.<key> <value>` writes to `setup.conf` via the same `_upsert_conf_value` helper the TUI uses (creates section / key on demand). Typed keys validate against `_tui_conf.sh` validators — `deploy.gpu_count`, `volumes.mount_*`, `devices.cgroup_rule_*`, `network.port_*`, `environment.env_*`, `resources.shm_size`; unknown sections / invalid values exit 2 with i18n'd stderr. `show <section>.<key>` prints a single value, `show <section>` dumps all keys in on-disk order; missing key / section exits 1. `list` (no arg) prints the full setup.conf as INI sections; `list <section>` aliases `show <section>`.
- **`setup.sh add` / `remove` subcommands** (#49 Phase B-3). `add <section>.<list> <value>` appends to a list-style section by picking the next available numeric slot — first reuses any slot whose value is empty (matches the TUI's `_edit_list_section` placeholder-fill behaviour), otherwise uses `max+1`. Validators fire through the same `_setup_validate_kv` table B-2 set up. `remove <section>.<key>` deletes an exact key; `remove <section>.<list> <value>` finds the first `<list>_*` whose value matches and deletes that key (one entry per call). Comments and the rest of the file preserved verbatim via `_write_setup_conf`.
- **`setup.sh reset` subcommand** (#49 Phase B-4). Overwrites `setup.conf` with the template default, archiving the prior `setup.conf` to `setup.conf.bak` and the prior `.env` to `.env.bak` for one-shot rollback. Mirrors what `build.sh --reset-conf` does today but accessible directly via `setup.sh` for scripted use. Without `--yes`, prompts for confirmation; non-tty without `--yes` refuses to proceed (safety guard against pipeline mishaps). None of the read/write subcommands (set / add / remove / reset) regenerate `.env` — chain `setup.sh apply` explicitly when needed.

### Changed
- **BREAKING — `setup.sh` no-arg / flag-only invocation no longer aliases to `apply`** (#49 Phase B-4). Pre-v0.11, both `setup.sh` (no args) and `setup.sh --base-path X --lang Y` (no subcommand) silently fell through to `apply`, regenerating `.env` + `compose.yaml`. Now no-arg prints help and exits 0; flag-only invocation errors with `Unknown subcommand`. Migration: every direct setup.sh call must explicitly pass a subcommand. `build.sh`, `run.sh`, `setup_tui.sh`, and `init.sh` all updated in this release to pass `apply` explicitly. Downstream repos calling `setup.sh` from custom scripts need to add `apply`.
- **`init.sh` now scaffolds `main.yaml` with `permissions: contents: write`** (closes #62). New downstream repos generated by `./template/init.sh` get the permission block by default, so their first release tag push doesn't 403 at `softprops/action-gh-release` (ros1_bridge v1.5.0 hit this — caller-level permission grant is required because reusable workflow permissions intersect with the caller's, and GitHub's default GITHUB_TOKEN is read-only). Existing downstream repos must add the block manually one-time.

### Fixed
- **`setup_tui.sh` aborts on whiptail-only hosts** (closes #136). `_tui_run` hardcoded dialog's flag spellings (`--ok-label` / `--cancel-label`) which whiptail rejects with `unknown option`, breaking the very first menu on Ubuntu 22.04 minimal / Jetson arm64 (no `dialog` package). `_tui_backend.sh` now translates the spelling per `${TUI_BACKEND}`: dialog keeps `--ok-label` / `--cancel-label` / `--extra-button` / `--extra-label`; whiptail gets `--ok-button` / `--cancel-button` and skips the extra-button block entirely (whiptail has no third button). To preserve the Save & Exit affordance on whiptail, `_render_main_menu` injects a synthetic `__save` menu entry (i18n'd in all 4 languages).
- **`_msg` shadow bug after sourcing `setup.sh`** (closes #101). `build.sh` / `run.sh` used to source `setup.sh` to obtain `_check_setup_drift`; `setup.sh`'s top-level `_msg()` (with only 3 keys) silently shadowed the caller's richer `_msg()` (with `drift_regen` / `err_no_env` / `err_rerun_setup`). `_msg drift_regen` then returned empty and `printf "%s\n" ""` ate the drift-regen status line on every fresh-host / setup.conf-changed run (Jetson headless first surfaced it). Defensive fix: rename `setup.sh`'s `_msg()` → `_setup_msg()`. The B-1 subprocess switch above retires the entire `source` pattern as a structural follow-on.

### Migration

Downstream repos upgrading from `v0.10.x` should:

1. Bump `main.yaml`'s `@<version>` to `@v0.11.0-rc1` (or `@v0.11.0` once stable).
2. Bump `test_tools_version: v0.11.0-rc1` (or `v0.11.0`).
3. If any custom script invokes `setup.sh` directly without a subcommand, add `apply`.
4. Run `./template/upgrade.sh v0.11.0-rc1` (handles the subtree pull + `init.sh` resync + main.yaml `@tag` sed automatically).

## [v0.10.2] - 2026-04-24

Companion hotfix to v0.10.1. Same downstream-release blocker (call-release couldn't produce a GitHub Release), different root cause — this one fires *after* build passes. **Strongly recommended** with v0.10.1 for any repo cutting a release.

### Fixed
- **`release-worker.yaml` no longer tries to copy `compose.yaml` into the release archive.** The file has been a setup.sh-generated derived artifact (gitignored) since v0.9.0 — keeping it in the `cp -r` list meant `call-release` hit `cp: cannot stat 'compose.yaml': No such file or directory` on every tag push. `action-gh-release` never ran so no GitHub Release was created. Surfaced by ros1_bridge's v1.5.0 release attempt (same session as the test_tools_version fix). Removed `compose.yaml` from the cp list; regression tests added (negative + positive cp-list assertions).

## [v0.10.1] - 2026-04-24

Critical hotfix for v0.10.0. Downstream repos cutting their own release tag (`v*`) hit a hard 404 in the `test` stage via `build-worker.yaml`'s wrong-ref parse, blocking `call-release`. **Strongly recommended** for any downstream repo planning to cut a release.

### Changed
- **BREAKING for callers pinned to `@v0.10.0`**: `build-worker.yaml` gains a new input `test_tools_version` (default `"latest"`). Downstream `main.yaml` should pin it to the template release they upgraded from (e.g. `test_tools_version: v0.10.1`) for reproducibility. Repos on `@v0.10.0` or below that never cut a release tag keep working on unpinned `:latest` (unchanged from v0.10.0's silent GHCR fallback during branch / PR pushes).

### Fixed
- **`build-worker.yaml` auto-parse bug on tagged downstream releases.** v0.10.0's `GITHUB_WORKFLOW_REF` parsing read the **caller's** ref — when a downstream repo pushed its own release tag (e.g. `v1.5.0`), the workflow tried to pull `ghcr.io/.../test-tools:v1.5.0` (doesn't exist) instead of template's pinned `:v0.10.0`. Surfaced first by ros1_bridge's v1.5.0 release attempt. Fix: drop the `GITHUB_WORKFLOW_REF` parse entirely, require caller to pass `test_tools_version` explicitly (defaults to `latest`). Regression test added to `template_spec.bats`.

## [v0.10.0] - 2026-04-24

First stable minor bump post-v0.9.x. Cuts the rc2 feature work + two fixes. **Recommended upgrade path** for all downstream repos (rc1 / rc2 supersede everything earlier, see rc1/rc2 notes below for the full run-phase UX realignment + arm64 test-tools hotfix).

### Added
- **`--reset-conf` flag** on `build.sh` (closes #124). Overwrites `setup.conf` with the template default, backing up the previous `setup.conf` → `setup.conf.bak` and `.env` → `.env.bak` first. Interactive confirmation prompt; `-y` / `--yes` skips it. Internally delegates to the new `./template/init.sh --gen-conf --force` backend. Triggers a `setup.sh` rerun afterward so `.env` + `compose.yaml` regenerate from the fresh conf.
- `./template/init.sh --gen-conf --force` — backend for the above. Without `--force`, `--gen-conf` still refuses to clobber an existing `setup.conf` (unchanged default).
- New-repo `.gitignore` template gains `setup.conf.bak` and `.env.bak` entries so the reset backups never get committed by accident.

### Fixed
- **`upgrade.sh` main.yaml sed regex now handles semver pre-release tags** (closes #61). The prior `[0-9.]*` character class stopped at the first `-`, so upgrading from an existing RC tag (e.g. `v0.10.0-rc1` → `-rc2`) left the old `-rcN` suffix in place and produced `@v0.10.0-rc2-rc1`. First surfaced when ros1_bridge ran `./template/upgrade.sh v0.10.0-rc2` from `@v0.9.13`. Regex now anchored on full semver shape (`\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?`). Two regression tests added covering RC → RC and RC → stable transitions.

### Release summary

Cumulative highlights from rc1 + rc2 rolled up here for discoverability:

- **Run-phase UX realignment (BREAKING, from rc1, closes #118)**: `./run.sh` target now moves behind explicit `-t/--target`; positional args become CMD passthrough matching `docker run <image> [cmd]`. Migration: `./run.sh runtime` → `./run.sh -t runtime`; plain `./run.sh` unchanged.
- **Compose `runtime` service auto-emission (from rc1, closes #108)**: `setup.sh` detects `FROM … AS runtime` in the Dockerfile and emits a paired service extending `devel`, so `./run.sh -t runtime` actually works.
- **arm64 `test-tools` binaries are now genuinely aarch64 (from rc2)**: `Dockerfile.test-tools` `ARG TARGETARCH=amd64` default used to shadow BuildKit's auto-inject (moby/buildkit#3403), shipping x86_64 shellcheck / hadolint inside the arm64 image. v0.10.0-rc2+ drops the default; multi-arch GHCR `:v0.10.0` variants carry the right binaries per arch.

Downstream repos upgrading from v0.9.x straight to v0.10.0 should:

1. `./template/upgrade.sh v0.10.0`
2. Dockerfile: adopt `ARG TEST_TOOLS_IMAGE="test-tools:local"` + `FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` + `COPY --from=test-tools-stage` (see `template/dockerfile/Dockerfile.example`).
3. Audit any `./run.sh <target>` call sites and rewrite as `./run.sh -t <target>`.

## [v0.10.0-rc2] - 2026-04-24

Second release candidate. Ships the arm64 test-tools hotfix that v0.10.0-rc1 / v0.9.13 both missed — **strongly recommended** over rc1 for any downstream repo enabling the arm64 build matrix.

### Fixed
- **`Dockerfile.test-tools` `ARG TARGETARCH=amd64` default shadowed BuildKit's per-platform auto-inject** ([moby/buildkit#3403](https://github.com/moby/buildkit/issues/3403)). Every multi-arch build published via `release-test-tools.yaml` (v0.9.13, v0.10.0-rc1) therefore fell back to `amd64` and shipped x86_64 `shellcheck` / `hadolint` binaries inside the arm64 image variant. Symptom downstream: `shellcheck: Exec format error` on arm64 CI (ros1_bridge PR #27 first surfaced it). Fix: declare `ARG TARGETARCH` without default so BuildKit's injected value drives the `case` branch. Regression test added: `Dockerfile.test-tools ARG TARGETARCH has no default value`. Requires a new tag + `release-test-tools.yaml` re-run to reissue `:v0.10.0-rc2` + `:latest` on GHCR.

## [v0.10.0-rc1] - 2026-04-24

Release candidate for v0.10.0. BREAKING: `run.sh` arg semantics realigned.
Validate on `ros1_bridge` (`./run.sh -t runtime` attaches to bridge logs,
`./run.sh -t runtime bash` drops into runtime shell) + at least one
GUI-using env repo before promoting to v0.10.0.

### Added
- **`runtime` compose service auto-emission (closes #108)**. `setup.sh` now detects a `FROM <base> AS runtime` stage in the sibling Dockerfile and emits a paired `runtime` service that `extends: { service: devel }` (inherits volumes / env / network / GPU / caps), overrides `build.target`, `image` (`:runtime` tag), `container_name` (`<name>-runtime`), and flips `stdin_open: false` / `tty: false` for headless auto-run. Gated by `profiles: [runtime]` so plain `compose up` still scopes to `devel`; `compose run runtime` / `compose up runtime` (and `./run.sh -t runtime`) target it explicitly. Repos without an `AS runtime` stage get no emission (no broken service entry).

### Changed
- **BREAKING: `./run.sh` arg semantics aligned with `docker run <image> [cmd]` (closes #118).**
  - Target is now the explicit `-t TARGET` / `--target TARGET` flag (default `devel`).
  - Positional args after options are the CMD to run inside the container, mirroring `exec.sh`. Empty CMD → Dockerfile CMD runs (`devel` = `bash`, `runtime` = its auto-run service). Non-empty CMD → overrides Dockerfile CMD.
  - `-d` + CMD → error (exit 2) with a pointer to `./exec.sh` for the detached-container cmd case; `-d` alone is unchanged (`compose up -d TARGET`).
  - Migration: `./run.sh runtime` → `./run.sh -t runtime`. `./run.sh test` → `./run.sh -t test`. Plain `./run.sh` still drops into devel bash (unchanged UX).

## [v0.9.13] - 2026-04-24

### Added
- **`.github/workflows/release-test-tools.yaml`** — on every tag push (and manual `workflow_dispatch`), builds multi-arch (amd64 + arm64) `Dockerfile.test-tools` and publishes to `ghcr.io/ycpss91255-docker/test-tools:<tag>` + `:latest`. First release triggered by this tag; package visibility should be set to public on first push so downstream Dockerfiles can pull anonymously.
- **`TEST_TOOLS_IMAGE` build-arg** in `Dockerfile.example` — defaults to `test-tools:local` (preserves the local `./build.sh` flow that builds `Dockerfile.test-tools` into the host daemon). Override in CI to `ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z` so buildx pulls the arch-correct pre-built image over the wire.

### Changed
- **BREAKING for downstream repos adopting v0.9.13+ workflows**: `build-worker.yaml` no longer builds `test-tools:local` in-job. Instead it parses the template version from `GITHUB_WORKFLOW_REF` and passes `TEST_TOOLS_IMAGE=ghcr.io/ycpss91255-docker/test-tools:<template-ver>` as a build-arg to the test stage. Downstream Dockerfiles must add `ARG TEST_TOOLS_IMAGE="test-tools:local"` + `FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` + `COPY --from=test-tools-stage` (the previous `COPY --from=test-tools:local` literal stops working once repos bump their `main.yaml` `@tag` to `v0.9.13`). Existing repos pinned to `@v0.9.12` or earlier remain unaffected until they upgrade.
- `Dockerfile.example` test stage restructured: new `FROM ${TEST_TOOLS_IMAGE} AS test-tools-stage` alias, 4 `COPY --from=test-tools:local` → `COPY --from=test-tools-stage`, top-level comment updated.

### Fixed
- **CI `COPY --from=test-tools:local` no longer fails with `pull access denied` on downstream repos** (follow-up to v0.9.12 `load: true` attempt, which turned out not to share images between buildx steps — [docker/build-push-action#581](https://github.com/docker/build-push-action/issues/581)). GHCR-backed approach sidesteps the cross-step image-store isolation entirely.
- **`release-test-tools.yaml` Dockerfile path** — was wrongly written as `template/dockerfile/Dockerfile.test-tools` (the downstream subtree path); in the template repo itself the file is at `dockerfile/Dockerfile.test-tools`. Regression test added to assert no subtree-prefixed path leaks back in.

## [v0.9.12] - 2026-04-24

### Added
- `.github/dependabot.yml` — weekly `github-actions` ecosystem scan so template's own consumed actions (`actions/checkout`, `docker/*`, etc.) stay current without manual audits.

### Changed
- README "Updating" section (4 languages) clarifies that `./template/upgrade.sh` already automates subtree pull + integrity check + `init.sh` resync + `main.yaml` `@vX.Y.Z` sed; hand-rolling `git subtree pull` is discouraged since the sed + init steps are easy to forget. Adds a Dependabot snippet downstream repos can drop into their `.github/dependabot.yml` so template version bumps surface as PRs automatically (Dependabot handles workflow refs only; subtree still needs `upgrade.sh`).

### Fixed
- **`build-worker.yaml` test-tools build now uses `load: true`.** Without it, `docker/build-push-action@v6` with `push: false` discards the built image, so subsequent `COPY --from=test-tools:local` in the downstream Dockerfile can't resolve the tag. buildx then falls back to registry pull → `docker.io/library/test-tools:local: pull access denied` → CI fail. Surfaced when `ros1_bridge` became the first downstream repo to adopt `test-tools:local` post-v0.9.11 (issue #106 migration PR). Added `test/unit/template_spec.bats` regression test asserting the `load: true` flag is present.

## [v0.9.11] - 2026-04-24

### Fixed
- **`_lib.sh` fallback `_detect_lang` returned `"zh"` for `zh_TW` (issue
  #103)** — a copy-paste typo in the fallback used when `i18n.sh` was
  absent (the Dockerfile `/lint` stage). Fixed to `"zh-TW"`. The
  follow-up `#104` dedupe below then REMOVED the fallback entirely; the
  only remaining `_detect_lang` is in `i18n.sh`.

### Changed
- **`[build] network` now defaults to `auto` (issue #102)**. On Jetson
  (detected via `/etc/nv_tegra_release`) setup.sh resolves `auto` to
  `host`, so first-time `./build.sh` succeeds without the DNS failures
  that Jetson's broken bridge NAT used to cause. Desktop hosts stay on
  Docker's default bridge. Explicit `host` / `bridge` / `none` /
  `default` still pass through unchanged; new `off` value for explicit
  opt-out. New `_resolve_build_network` helper mirrors
  `_resolve_runtime`'s Jetson-aware pattern.
- **`_detect_lang` deduplicated: single canonical definition in
  `i18n.sh` (issue #104)**. Previously `build.sh` / `run.sh` /
  `exec.sh` / `stop.sh` / `_lib.sh` each shipped an inline fallback
  `_detect_lang` for when `i18n.sh` wasn't reachable (Dockerfile
  `/lint` stage). That invited drift — see #103 where `_lib.sh`'s
  copy had silently returned `zh` instead of `zh-TW` for months.
  `Dockerfile.example`'s test stage now COPYs `_lib.sh` + `i18n.sh` +
  `_tui_conf.sh` alongside `*.sh`; scripts look up `_lib.sh` in the
  template layout OR as a sibling, with a clear error when neither
  exists. Downstream repos using a custom Dockerfile (not based on
  `Dockerfile.example`) need to mirror this COPY in their test stage.
- **`_sanitize_lang` warning now localises to the system `$LANG`**. v0.9.7
  Agent A scoped this helper out of i18n; a user with `LANG=zh_TW.UTF-8`
  who typed `--lang xxx` still saw an English WARNING. Now we re-detect
  from the system env (can't trust `_LANG` — it holds the invalid input
  the user just passed) and print the warning in zh-TW / zh-CN / ja
  where applicable, falling back to English for other locales.

### Added
- **Coverage audit follow-up (+9 unit tests)**. Kcov run flagged four
  small untested branches in `_lib.sh` and `_tui_conf.sh`; filling them
  raised non-TUI coverage from 94.4% → 95.7%. New tests:
  - `_lib_msg count` / `caps` translation keys exercised in all four
    languages (previously only Files / Identity / etc. were asserted).
  - `_mount_container_path` helper — four cases (plain /
    with-mode / env-var-interpolated / no-colon fallback). The symmetric
    `_mount_host_path` was already covered; the container-side parser
    had zero unit tests.
  - `_upsert_conf_value` "section not found" branch — appends a fresh
    `[section]` header + key when called against a conf that doesn't
    yet have that section.
  - `_upsert_conf_value` "section present, key absent at EOF" branch —
    appends the key to the last section when target key isn't there.
  - `_write_setup_conf` final-section override flush — an override key
    whose target is the LAST section in the template gets emitted
    via the EOF-flush path (previously only the mid-file append branch
    was asserted).
  - `_write_setup_conf` removed_keys + flush interplay — ensures a key
    listed in `removed_keys` does NOT reappear via the EOF flush.

  TUI interactive flows (`_edit_section_*`) in `setup_tui.sh` remain
  at ~17% — they require a dialog/whiptail stub framework to drive,
  cost doesn't justify coverage-for-its-own-sake. `setup_tui.sh`
  validators / I/O helpers are covered at unit level via `tui_spec`.

## [v0.9.10] - 2026-04-24

### Added
- **Multi-arch support in `build-worker.yaml`** — new `platforms` input
  (default `"linux/amd64"`, accepts `"linux/amd64,linux/arm64"`). Each
  requested platform runs as a parallel matrix shard on its own native
  runner (amd64 → `ubuntu-latest`, arm64 → `ubuntu-24.04-arm`), so arm64
  builds avoid QEMU emulation and stay in the 5-15 min range instead of
  30-60 min. Full pipeline (test-tools → test stage smoke → devel →
  runtime) runs natively per platform. Covers Jetson (Nano / Xavier /
  Orin, all aarch64) and modern Raspberry Pi (4 / 5 on 64-bit OS) and
  standard x86 hosts. 32-bit ARM (armv7/v6) intentionally unsupported —
  no native runner exists and QEMU emulation would balloon CI time;
  modern Pi defaults to 64-bit OS.

### Changed
- **`build-worker.yaml` now uses the `docker-container` buildx driver**
  (was `docker`). Required for multi-arch builds. Side effect:
  `test-tools:local` is built via `docker/build-push-action@v6` (not
  plain `docker build`) so the tag lands in buildx's internal image
  store, visible to the subsequent test-stage build's
  `COPY --from=test-tools:local` on the same builder.
- **Matrix job names**: per-platform shards are called
  `call-docker-build / build (linux/amd64)` etc. A stable-name
  aggregator job `call-docker-build / docker-build` gates on all
  shards — downstream `main` branch protection rules that require
  `call-docker-build / docker-build` keep working without changes.

## [v0.9.9] - 2026-04-24

### Added
- **`[deploy] runtime` setup.conf key** — Docker runtime override at
  service level in compose.yaml. Required on Jetson (JetPack) because
  its nvidia-container-toolkit runs in csv mode and refuses the modern
  `--gpus` flow that `deploy.resources.reservations.devices` uses.
  Values:
  - `auto` — emit `runtime: nvidia` on Jetson (detected via
    `/etc/nv_tegra_release`), omit on desktop (default).
  - `nvidia` — force emit on all hosts (e.g. csv-mode toolkit on x86).
  - `off` — never emit (Docker default runc).

  `setup.sh` resolves via new `_detect_jetson` + `_resolve_runtime`
  helpers; `SETUP_DETECT_JETSON=true|false` env var overrides the
  filesystem probe (used by tests). `setup_tui.sh` gains a matching
  picker in `[deploy]` section with 4-language i18n;
  `_validate_runtime` accepts `auto|nvidia|off` or empty.

### Changed
- **`_lib.sh` `_print_config_summary` now honours `${_LANG}`**. Previously
  the build/run config summary (Files / Identity / Resolved / Customize
  sections, plus user / hardware / workspace / GPU enabled / GUI enabled
  / network / privileged labels) was hardcoded English regardless of
  `--lang` / `SETUP_LANG`. Agent A's v0.9.7 i18n PR explicitly scoped
  this out as "too much to bite off"; user feedback after the Jetson
  upgrade: `./run.sh --lang zh-TW` still looked English because the
  summary is 90% of the output. A new `_lib_msg` translation table
  covers `en` / `zh-TW` / `zh-CN` / `ja`. Technical identifiers kept
  untranslated: file names (`setup.conf` / `.env` / `compose.yaml`),
  INI section names (`[image]` / ...), `.env` variable names (`TZ`,
  `APT_MIRROR_*`, `IPC`, `CAPS`), and command strings in the Customize
  hint.

## [v0.9.8] - 2026-04-23

### Fixed
- **`upgrade.sh` no longer leaves the repo destroyed if `git subtree
  pull` misbehaves**. On Jetson L4T (ships an older `git-subtree.sh`),
  running `upgrade.sh v0.9.5 → v0.9.7` fast-forwarded the synthetic
  squash commit onto HEAD, moving `template/*` to repo root and
  deleting repo-specific files (Dockerfile, compose.yaml, bridge.yaml,
  etc.). `upgrade.sh` now:
  - **Pre-flight** — fails fast with actionable messages when `git
    config user.name / user.email` is unset (a Jetson-specific trigger
    for the partial-state bug), or when a merge / rebase / cherry-pick
    is in progress (`.git/MERGE_HEAD`, `.git/rebase-merge`, etc.).
  - **Post-flight integrity check** — after the subtree pull, verifies
    `template/.version`, `template/init.sh`, and
    `template/script/docker/setup.sh` still exist. If any is missing,
    hard-resets to the pre-pull HEAD and exits with a diagnostic. The
    working tree is restored; no manual cleanup required.
  - **Step numbering** — corrected from mixed "1/4 / 2/3 / 3/3" to
    "1/4 / 2/4 / 3/4 / 4/4".
- **`test/unit/upgrade_spec.bats`** gains 12 regression tests covering
  the three new guards + structural invariants (ordering: identity
  check before pull, integrity check after pull, HEAD snapshotted for
  rollback).
- **`test/integration/upgrade_spec.bats`** (new, 6 tests) drives the
  real `upgrade.sh` end-to-end against a fake template remote (bare
  repo with `v0.9.5` / `v0.9.7` tags) attached to a sandbox downstream
  repo. Covers happy path (version bump, new content, `main.yaml`
  `@tag` rewrite), idempotent re-run, `--check`, the two pre-flight
  guards, and the destructive-FF rollback (stubs `git-subtree pull`
  via `GIT_EXEC_PATH` to simulate the Jetson bug, asserts repo is
  restored to pre-pull HEAD). Total: 592 → 610 (+12 unit + 6
  integration).

## [v0.9.7] - 2026-04-23

### Changed
- **Full i18n coverage for `build.sh` / `run.sh` / `exec.sh` / `stop.sh`**.
  Previously only `usage()` (help text) honoured `--lang` / `SETUP_LANG`;
  runtime log lines (`First run — bootstrapping`, `regenerating .env /
  compose.yaml`, `ERROR: setup did not produce .env`, `Container is
  already running`, `is not running`, `No instances found`, ...) were
  hardcoded English regardless of language. Each script now ships a
  local `_msg()` translation table covering `en` / `zh-TW` / `zh-CN` /
  `ja`, matching the existing `setup.sh` pattern. English remains the
  default when no flag / env var is set, so existing tooling and CI
  output are unchanged.

### Added
- **Root-level `setup.sh` symlink**. `init.sh` now links
  `<repo>/setup.sh` to `template/script/docker/setup.sh` alongside the
  existing `build.sh` / `run.sh` / `exec.sh` / `stop.sh` / `setup_tui.sh`
  / `Makefile` symlinks. Consumer repos can now invoke `./setup.sh`
  directly for scripted / CI regeneration of `.env` + `compose.yaml`,
  instead of relying on the indirect `./build.sh --setup` or
  `./setup_tui.sh` Save paths.
- **`setup.sh -h` / `--help`**. `script/docker/setup.sh` gains a
  `usage()` block documenting `--base-path` and `--lang`, following the
  existing `build.sh` case-per-`_LANG` scaffolding (English-only for
  now; future translations plug in via the existing `_msg` framework).
- **`test/unit/exec_sh_spec.bats`** (18 tests) and
  **`test/unit/stop_sh_spec.bats`** (17 tests): new unit specs
  covering argument parsing, the container-running precheck hints in
  `exec.sh`, the `--all` / `--instance` branches in `stop.sh`, all
  four languages of usage text, runtime log-line i18n, and the
  fallback `_detect_lang` branches (`LANG=zh_TW.UTF-8` etc. when
  `template/` is absent).
- Log-line i18n regression tests in `test/unit/build_sh_spec.bats`
  (+7) and `test/unit/run_sh_spec.bats` (+6) assert that `--lang
  <code>` actually translates the runtime logs (bootstrap, drift-regen,
  err_no_env, already-running), not just `--help`.

### Fixed
- **`setup.sh` symlink-invocation robustness**. `setup.sh` previously
  located its `i18n.sh` / `_tui_conf.sh` siblings and the template
  `setup.conf` via `dirname "${BASH_SOURCE[0]}"`, which resolved to the
  repo root when the script was invoked through `<repo>/setup.sh`
  (symlink). `setup.sh` now runs `readlink -f` once at load and stores
  the real script directory in `_SETUP_SCRIPT_DIR`; every sibling
  source and template-relative path reads from that variable.

## [v0.9.6] - 2026-04-23

### Added
- **`[build] network` setup.conf key**: overrides Docker's build-time
  network mode. Empty (default) = Docker decides (bridge + NAT). Set
  to `host` when the host's bridge NAT is unusable: stripped embedded
  kernels (e.g. Jetson L4T missing `iptable_raw`), hosts with
  `"iptables": false` in daemon.json, or firewall-locked CI runners.
  `setup.sh` writes `BUILD_NETWORK=<value>` to `.env` and emits
  `build.network: <value>` under each service in `compose.yaml`;
  `build.sh` forwards `--network <value>` to the auxiliary
  `docker build` invocation for `test-tools`. `setup_tui.sh` gains a
  matching `[build] Build network` menu item and
  `_validate_build_network` validator (accepts empty / `host` /
  `bridge` / `none` / `default`).
- **Integration test** `fresh_clone_portability_spec.bats` covers the
  fresh-clone-on-a-different-machine path end-to-end (real `build.sh`
  + `setup.sh`, no mocks): both the stale-absolute-path auto-migrate
  and the portable `${WS_PATH}` round-trip.

### Changed
- **`_dump_conf_section` hides empty-valued keys** in the
  `_print_config_summary` output. Lines like `shm_size =` (using the
  template default) are noise in the config dump; they're now
  filtered. Sections whose every key is empty collapse to nothing and
  the section header is skipped too (via the existing
  `[[ -z ${_content} ]]` check in the caller).

## [v0.9.5] - 2026-04-23

### Changed
- **`build.sh` / `run.sh` auto-regenerate on drift**. `_check_setup_drift`
  now returns non-zero when `setup.conf` / GPU / GUI / USER_UID drifted
  from `.env`; the drift branch in `build.sh` / `run.sh` re-runs
  `setup.sh` automatically instead of printing a WARNING and continuing
  with stale `.env`. `.env` + `compose.yaml` are derived artifacts with
  no user-owned data to preserve, so re-running is always safe. Fixes
  the footgun where `git pull` + `./build.sh` silently used the
  previous machine's `WS_PATH`. Users who preferred the warn-only
  behaviour can still edit `.env` freely — drift is only re-triggered
  by changes to `setup.conf` or detected hardware, not by editing
  `.env` directly.

## [v0.9.4] - 2026-04-23

### Fixed
- **`[volumes] mount_1` portability**: `setup.sh` used to bake the
  absolute host workspace path into `setup.conf` on first-time
  bootstrap. Committing that file broke fresh clones on any other
  machine whose filesystem layout differed — `_load_env` resolved
  `WS_PATH` to a directory that doesn't exist and docker tried to
  mount it. `setup.sh` now writes `mount_1` in the portable
  `${WS_PATH}:/home/${USER_NAME}/work` form so docker-compose resolves
  `${WS_PATH}` per-machine from `.env`. When a stale absolute path
  (baked from another machine, absent locally) is encountered,
  `setup.sh` warns and auto-migrates `mount_1` back to the portable
  form. Users who intentionally pin an existing absolute path still
  get that value honored.

## [v0.9.3] - 2026-04-23

### BREAKING
- **`template/VERSION` renamed to `template/.version`**. Dotfile keeps
  version metadata out of casual `ls`. Clean break — `upgrade.sh` /
  `init.sh` / `build-worker.yaml` no longer read `template/VERSION` or
  the even older `.template_version`. Downstream repos pick up the
  rename automatically via `./template/upgrade.sh <new-tag>`: the
  subtree pull drops `template/VERSION` and lands `template/.version`,
  and the new `upgrade.sh`/`init.sh` code reads the new location.
  Anyone running the old `upgrade.sh` binary against the new tag sees
  "unknown" as the local version — cosmetic only, the upgrade still
  succeeds.

### Changed
- **Codecov config consolidated** into `.codecov.yaml`. Historical
  duplicate `codecov.yml` removed — Codecov precedence had it silently
  overriding `.codecov.yaml` since PR #62, so the strict `ignore:` +
  `patch: 100%` rules in `.codecov.yaml` were dead config. `.codecov.yaml`
  now carries the relaxed policy from `codecov.yml` (threshold 1%,
  patch informational) plus the previously-ignored `test/**` and
  `.github/**` ignores. No behavior change for contributors.

## [v0.9.2] - 2026-04-23

### Fixed
- **`build.sh` / `run.sh` bootstrap**: fresh clones (where `compose.yaml`
  is gitignored since v0.9.0) now bootstrap correctly. Two regressions
  fixed:
  1. Bootstrap condition now also checks `compose.yaml`; previously a
     clone with `.env` + `setup.conf` present but `compose.yaml` absent
     skipped to the drift-check path and died in `_load_env` with a
     cryptic "No such file" error.
  2. Bootstrap path no longer dispatches through `_run_interactive`,
     which on a TTY launches `setup_tui.sh`. A user who pressed
     Esc / Ctrl+C in the TUI previously ended up with no `.env`.
     Bootstrap now calls `setup.sh` directly; TUI stays reserved for
     the explicit `--setup` flag.
- **`build.sh` / `run.sh` defensive guard**: if `setup.sh` returns
  without producing `.env` (cancelled TUI, setup crash, …), surface a
  clear error pointing at `--setup` instead of failing deep in
  `_load_env`.

## [v0.9.1] - 2026-04-23

### Changed
- **`upgrade.sh` / `init.sh` default to HTTPS** for the template remote
  (`https://github.com/ycpss91255-docker/template.git`). Fresh clones /
  CI runners / first-time contributors no longer need an SSH key to
  `./template/upgrade.sh`. Override with `TEMPLATE_REMOTE=git@...` env
  var for private forks or SSH-agent setups. 4-language READMEs and
  `init.sh` docstring updated accordingly.

## [v0.9.0] - 2026-04-23

### Added (Wave 1 + Wave 2 — 2026-04-22)
- **GPU MIG detection** (`_detect_mig` / `_list_gpu_instances` in
  `_tui_conf.sh`): when host has NVIDIA MIG mode enabled, the deploy
  editor opens with a msgbox listing GPU / MIG instance UUIDs and
  advising `NVIDIA_VISIBLE_DEVICES=<MIG-UUID>` via `[environment]`
  since `count=N` targets whole GPUs only
- **`[build] tz` key**: container timezone exposed as a setup.conf
  value; pipes through to compose.yaml `build.args` as
  `TZ: ${TZ:-Asia/Taipei}`. Empty keeps Dockerfile default
- **`[devices] cgroup_rule_*`**: `device_cgroup_rules:` block for USB
  hotplug / dynamic device nodes; TUI devices editor now has a
  sub-menu to pick between device bindings and cgroup rules. New
  `_validate_cgroup_rule` validator

### Changed
- `[image] rule_*` dedup on write: re-adding a rule that already
  exists at another slot moves it to the new position instead of
  leaving two identical entries
- `_edit_list_section` add now reuses empty slots (e.g. cleared
  `mount_1` after user opted out of workspace), preventing the next
  mount from leapfrogging to `mount_2`
- TUI image-rule type picker simplified to function names only
  (`prefix` / `suffix` / `@basename` / `@default`); format + example
  shown in the value inputbox
- TUI footer buttons (`Save` / `Enter` / `Cancel`) no longer i18n'd;
  consistent English across all locales
- `_TUI_LANG_UPPER` initialised at source time so sourcing `setup_tui.sh`
  and calling a section editor directly (tests, REPL) no longer
  crashes on unbound variable under `set -u`
- **CLI consistency**: `exec.sh` / `stop.sh` now accept `--lang LANG`
  (matches `build.sh` / `run.sh`); `stop.sh` gains `-a` short flag
  for `--all` (matches common CLI patterns). Unknown lang values
  warn and fall back to `en` via `_sanitize_lang`
- **`--gen-image-conf` alias removed** from `init.sh` / `upgrade.sh`;
  the `--gen-conf` name is the only spelling. The alias was a
  rename-artifact and not documented outside in-tree help
- **`tui.sh` → `setup_tui.sh`**: pairs with `setup.sh` and makes the
  "interactive editor for setup.conf" relationship explicit.
  `init.sh` now creates `setup_tui.sh` and removes any stale `tui.sh`
  symlink left behind by pre-rename installs
- **`_print_config_summary` full dump**: `build.sh` / `run.sh` now
  print every populated `setup.conf` section (image / build / deploy /
  gui / network / security / resources / environment / tmpfs /
  devices / volumes) alongside identity, file paths, and the resolved
  GPU/GUI/TZ flags — so users see every value this run consumes
  without having to diff `.env` or run `docker compose config`

### Added
- **`[build] target_arch` TARGETARCH override**: new scalar key
  alongside the `arg_N` list. Non-empty value pins Docker's
  `TARGETARCH` build arg for both the main image and the test-tools
  image (main via compose `build.args`, test-tools via
  `build.sh --build-arg`). Empty (default) leaves BuildKit's
  auto-detection intact. Valid values: `amd64` / `arm64` / `arm` /
  `386` / `ppc64le` / `s390x` / `riscv64`. `setup_tui.sh` → Build
  adds a dedicated menu entry; `_validate_target_arch` catches typos
  like `aarch64` / `x86_64` (BuildKit uses `arm64` / `amd64`).
- **`Dockerfile.test-tools` multi-arch**: `ARG TARGETARCH=amd64`
  branches the ShellCheck + Hadolint download URLs via a `case`
  statement. BuildKit auto-fills on amd64 / arm64 hosts; falls back
  to amd64 binaries on legacy builders. Rejects unsupported arches
  loudly instead of silently grabbing a wrong-arch binary
- **`setup_tui.sh --lang <invalid>` surfaces a TUI msgbox** before
  the main menu opens. Previously the `_sanitize_lang` stderr warning
  scrolled away as soon as dialog/whiptail cleared the screen; the
  user saw a silently-English TUI with no hint why. New
  `_warn_if_lang_rejected` helper captures the raw input and opens a
  "Language fallback" msgbox listing the valid codes

### Performance
- **`make test` no longer runs kcov** — the dev loop pays for bats +
  shellcheck only. `make coverage` keeps the full kcov path for CI
  and release checks. `ci.sh --ci` honors `$COVERAGE=1` to include
  kcov when the outer `--coverage` flag is set
- **`bats --jobs $(nproc)` parallelism** — GNU parallel runs the
  524-test suite concurrently across files and within files. All
  specs already use per-test `mktemp -d` dirs so there's no shared
  filesystem state. Combined effect (cached apt):
  before ~1m27s (serial + kcov) → now ~42s (parallel, no kcov) ≈ 2x
  faster on the dev loop

### BREAKING
- **Language code `zh` renamed to `zh-TW`** (BCP-47). `--lang zh`
  no longer accepted; use `--lang zh-TW` (Taiwan Traditional).
  `zh-CN` / `ja` / `en` unchanged
- **`@env_example` image-name rule removed**: legacy rule that read
  `IMAGE_NAME` from `.env.example` deleted along with its TUI option
  + i18n keys. `.env` is a setup.sh-derived artifact so the rule
  created a cycle. Replace with explicit `rule_N = @default:<name>`
  or set `IMAGE_NAME` directly

### Removed (tried, reverted)
- **B7 vim keybindings** (attempted `DIALOGRC bindkey j/k/h/l`):
  reverted in `ccc0dbc`. `dialog` 1.3 rejects letter curses_keys —
  only symbolic names (`TAB` / `DOWN` / `UP` / `ENTER`) are valid.
  See repo-root `TODO.md` for alternative-backend options (gum /
  fzf / textual) queued for a future PR

### Changed (TUI UX 重構 — 2026-04-21 本地)
- **主選單重組**：11 項平鋪 → 5 常用（network / deploy / gui / volumes /
  environment）+ `advanced` 子選單（image / build / devices / tmpfs /
  security）
- **Save UX**：去掉 `__save` menu item，改用 dialog/whiptail 的
  `--extra-button --extra-label "Save & Exit"`（exit code 3 = save
  訊號，0 = 進選中項，1 = Cancel）
- **List sections 統一 single-layer**：volumes / environment / devices /
  tmpfs / ports 點 item 直接 inputbox；**空值 + OK = mark_removed**
  （該 key 從 setup.conf 消失）；list menu 只保留 Add / Back
- **Conditional triggers**：`shm_size` 不再是主選單項，改為
  `[network] ipc != host` 時從 network 結尾彈出；`ports` 改為
  `mode == bridge` 時從 network 結尾彈出
- **privileged 遷移**：從 `[network] privileged` 搬到新 `[security]
  privileged`。TUI 的 privileged yesno 由 Advanced → Security 編輯
- **`[security]` 新 section**：privileged / cap_add_* / cap_drop_* /
  security_opt_*。先前 compose.yaml 硬編的 SYS_ADMIN / NET_ADMIN /
  MKNOD / seccomp:unconfined 改為 setup.conf template 預設值，可由
  TUI 或手編調整

### Removed
- **cgroup (`device_cgroup_rules`)**：setup.conf 註解、parser、TUI、
  compose.yaml `device_cgroup_rules:` 產生邏輯全拿掉。使用者手寫
  `cgroup_N = ...` 會被忽略

### Added
- **Interactive TUI** (`setup_tui.sh`) for editing `<repo>/setup.conf` via
  dialog (with whiptail fallback). Main menu + direct-jump subcommands
  (`./setup_tui.sh image|build|network|deploy|gui|volumes`). Validates
  mount format, GPU count, and enum fields before save. On save,
  invokes `setup.sh` automatically to regenerate `.env` +
  `compose.yaml`. Symlinked from each repo root via `init.sh`.
  4-language i18n (en / zh / zh-CN / ja).
- **`_tui_backend.sh`** — dialog/whiptail abstraction
  (`_tui_menu`, `_tui_radiolist`, `_tui_checklist`, `_tui_inputbox`,
  `_tui_yesno`, `_tui_msgbox`). Preferred backend auto-detected;
  exits with install hint when neither is installed.
- **`_tui_conf.sh`** — pure-logic INI read/write helpers:
  `_load_setup_conf_full` (full file with section order preserved),
  `_write_setup_conf` (comment-preserving overwrite),
  `_upsert_conf_value` (single-key in-place edit), plus validators
  (`_validate_mount`, `_validate_gpu_count`, `_validate_enum`) and
  mount-string parsers.
- **`[build]` section** in `setup.conf` for Dockerfile build args
  (`apt_mirror_ubuntu`, `apt_mirror_debian`). Empty value keeps the
  hard-coded Taiwan mirror defaults.
- **Workspace writeback**: on first run (when `<repo>/setup.conf` does
  not exist), `setup.sh` detects the workspace host path, copies
  `template/setup.conf` to `<repo>/setup.conf`, and writes the
  detected workspace into `[volumes] mount_1`. Subsequent runs read
  `mount_1` as the source of truth. Clearing `mount_1` is treated as
  opt-out; the workspace is omitted from `compose.yaml` and `setup.sh`
  does not re-populate it.
- `build.sh` / `run.sh` `--setup` / `-s` is now **TTY-aware**: under
  an interactive terminal with `setup_tui.sh` available, it launches the
  TUI; otherwise it runs `setup.sh` non-interactively (unchanged
  behaviour for CI / non-TTY).
- `init.sh _create_symlinks` adds `setup_tui.sh` alongside the existing
  five symlinks.
- **Single `setup.conf`** at repo root consolidates all runtime
  configuration consumed by `setup.sh`: `[image]`, `[build]`,
  `[deploy]`, `[gui]`, `[network]`, `[volumes]`. Template default
  lives at `template/setup.conf`; per-repo override at
  `<repo>/setup.conf` uses section-level replace strategy (a section
  present in the per-repo file fully replaces the template's section;
  omitted sections fall back to template).
- `setup.sh` new helpers: `_parse_ini_section`, `_load_setup_conf`,
  `_get_conf_value`, `_get_conf_list_sorted`, `_resolve_gpu`,
  `_resolve_gui`, `detect_gui`, `_compute_conf_hash`,
  `_check_setup_drift`, and `generate_compose_yaml`. `setup.sh` now
  emits a full `compose.yaml` alongside `.env` with conditional GPU
  `deploy` block, conditional GUI env/volumes, and extra volumes from
  `[volumes]` section.
- **Drift detection** via `.env` metadata: setup.sh writes
  `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED`, `SETUP_TIMESTAMP` into
  `.env`; `build.sh` / `run.sh` compare stored values against current
  state and warn when `setup.conf` was modified, GPU/GUI detection
  changed, or UID changed. Warnings are non-blocking; user re-runs with
  `--setup` to regenerate.
- `build.sh` / `run.sh` **`--setup`** (`-s`) flag: forces setup.sh to
  regenerate `.env` + `compose.yaml`. Default behaviour: auto-bootstrap
  on missing `.env` (first run / CI fresh clone); warn on drift if
  `.env` exists.
- `init.sh` new option: `--gen-conf` copies `template/setup.conf` to
  `<repo>/setup.conf` for per-repo override. `--gen-image-conf` is kept
  as a back-compat alias.
- New unit spec `test/unit/compose_gen_spec.bats` (14 tests) covering
  `generate_compose_yaml` conditional output.

### Changed
- **PR #74's `template/config/setup/` directory removed**: the
  separate `image_name.conf` / `gpu.conf` / `gui.conf` / `network.conf`
  / `volumes.conf` files introduced in #74 are consolidated into a
  single `setup.conf` INI. `config/` now strictly contains container
  internal configs (bashrc, tmux, pip, terminator); runtime wiring
  lives at repo root alongside `Dockerfile`.
- `compose.yaml` is now a **derived artifact** (gitignored) generated
  by `setup.sh` on every invocation. Users inspect it for the current
  effective runtime config; source of truth is `setup.conf`.
- **BREAKING — setup.conf section rename**:
  `[image_name]` → `[image]`; `[gpu]` → `[deploy]` with keys prefixed
  (`mode` → `gpu_mode`, `count` → `gpu_count`,
  `capabilities` → `gpu_capabilities`). Also introduces `[build]`
  (apt mirrors). Template `setup.conf` updated; per-repo overrides
  must use the new names.
- `detect_image_name` now reads `[image] rules` (comma-separated
  ordered list) from `setup.conf` instead of a dedicated
  `image_name.conf` rule file. Rule semantics unchanged
  (`prefix:`, `suffix:`, `@env_example`, `@basename`, `@default:`).
- `build.sh` / `run.sh`: removed `--no-env` flag (semantic reversed —
  setup.sh no longer runs by default, so the opposite `--setup` flag
  was introduced). `exec.sh` / `stop.sh` unchanged (container state is
  already frozen when they run).
- `write_env` signature expanded with new columns written to `.env`:
  `NETWORK_MODE`, `IPC_MODE`, `PRIVILEGED`, `GPU_COUNT`,
  `GPU_CAPABILITIES`, `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED`,
  `SETUP_TIMESTAMP`.
- `generate_compose_yaml` baseline: only `${WS_PATH}:/home/${USER_NAME}/work`
  is always emitted; `/dev:/dev` now lives in `setup.conf`'s
  `[volumes]` template default (user-replaceable). GUI-related
  volumes/env are emitted iff `[gui] mode` resolves enabled.
- Version tracking moved from `.template_version` (repo root, manually
  maintained) to `template/VERSION` (inside subtree, auto-synced by
  `git subtree pull`). `init.sh` and `upgrade.sh` automatically clean up
  the legacy `.template_version` file. `build-worker.yaml` reads
  `template/VERSION` with `.template_version` fallback for transition.

### Documentation
- README (4 languages) and `init.sh` header now document the full
  bootstrap sequence for a brand-new repo: `git init` + an empty initial
  commit must run before `git subtree add`, otherwise subtree fails with
  `ambiguous argument 'HEAD'` and `working tree has modifications`.

### Removed
- `template/config/image_name.conf` (content absorbed into
  `template/setup.conf` under `[image_name] rules =`).
- `--no-env` flag on `build.sh` / `run.sh` (replaced by default
  no-run-setup + opt-in `--setup`).

### Fixed
- `test/smoke/test_helper.bash`: `assert_cmd_installed` now returns `1`
  after calling `fail`, so callers can short-circuit via `|| return 1`
  instead of silently falling through. `assert_cmd_runs` and
  `assert_pip_pkg` now short-circuit when the target command is missing,
  so they no longer execute `run <missing-cmd>` and emit a spurious
  Bats BW01 warning.
- `test/unit/lib_spec.bats`, `test/unit/pip_setup_spec.bats`,
  `test/unit/setup_spec.bats`: replace `run <cmd>` / `assert_failure`
  pairs with `run -127 <cmd>` on the five tests whose command is
  expected to exit 127 (`_load_env` missing arg, `_compose` on empty
  PATH, `pip setup.sh` without pip, `setup.sh main --base-path` /
  `--lang` missing value). Silences Bats BW01. Files that use `run -N`
  flags now declare `bats_require_minimum_version 1.5.0` to silence
  BW02.

## [v0.8.1] - 2026-04-15

### Fixed
- `upgrade.sh`: drop the auto-appended `Co-Authored-By: Claude ...`
  trailer from the `chore: update template references` commit message.
  AI-attribution lines are visual noise for reviewers and the project
  convention is to omit them everywhere (PR body, commit message, code).

## [v0.8.0] - 2026-04-15

### Added
- `test/smoke/test_helper.bash`: shared runtime assertion helpers for
  downstream-repo smoke specs — `assert_cmd_installed`, `assert_cmd_runs`,
  `assert_file_exists`, `assert_dir_exists`, `assert_file_owned_by`,
  `assert_pip_pkg`. Each prints a decorated diagnostic on failure so the
  bats log points at the exact missing artifact. Keeps downstream smoke
  specs terse and self-documenting.
- `init.sh` new-repo skeleton now emits two sample smoke assertions
  (`entrypoint.sh is installed and executable`, `bash is available on
  PATH`) demonstrating the shared helpers, instead of one bare
  `[ -x /entrypoint.sh ]` assertion.
- `test/unit/ci_spec.bats` (5 tests): covers `script/ci/ci.sh`
  `_install_deps` — happy path plus the three explicit error branches
  for `apt-get update` / `apt-get install` / `git clone bats-mock`.
- `test/unit/smoke_helper_spec.bats` (19 tests): unit coverage for every
  runtime assertion helper above, including failure paths.
- `test/unit/setup_spec.bats`: 3 new `detect_ws_path` cases — explicit
  ERROR on missing `base_path`, and path-normalization coverage for
  strategies 1 and 3 when the input contains `..` segments.
- `test/unit/init_spec.bats` (15 tests): unit coverage for `init.sh`
  helpers previously reachable only through the Level-1 integration
  test — `_detect_template_version` (git-remote parsing, failure
  paths, rc-tag filtering), `_create_version_file` (parameterized
  version, `unknown` fallback, overwrite), `_create_new_repo`
  (workflow `@ref` threading including empty-ref → `@main` fallback),
  and `_create_symlinks` (full symlink set, stale-file replacement,
  custom `.hadolint.yaml` preservation).
- `test/unit/ci_spec.bats`: 3 new `_run_shellcheck` tests — wired-file
  regression guard, `script/docker/*.sh` discovery via `find`, and
  strict-mode propagation on lint failure.

### Fixed
- `init.sh`: stop hard-coding `v0.5.0` as the fallback version in the
  generated `main.yaml`. Workflow refs now fall back to the `main` branch
  (a valid git ref) when no tag is detected, instead of an arbitrary old
  tag. Version detection is done once up-front and shared between
  `.template_version` and the reusable-workflow `@ref`.
- `script/docker/setup.sh` `detect_ws_path`: normalize `base_path` with
  `cd ... && pwd -P` before composing sibling/parent paths, so relative
  or `..`-laden inputs do not produce surprising matches. Emits a clear
  error when the base path does not exist.
- `script/docker/setup.sh`: use `${0:-}` consistently in the
  `BASH_SOURCE == $0` guard (line 400) for parity with line 51.
- `script/ci/ci.sh` `_install_deps`: emit explicit error messages when
  `apt-get update`, `apt-get install`, or `git clone bats-mock` fails,
  instead of relying on `set -e` to exit silently.

### Changed
- `script/ci/ci.sh`: guard `main "$@"` and `set -euo pipefail` behind a
  `BASH_SOURCE == $0` check so the helpers (`_install_deps`, `_die`) can
  be sourced by unit tests without executing the CI pipeline. Matches
  the pattern already used in `script/docker/setup.sh`.
- `init.sh`: wrap top-level flow in `main()` + `BASH_SOURCE == $0` guard
  so helpers (`_detect_template_version`, `_create_version_file`,
  `_create_new_repo`, `_create_symlinks`) are sourceable from unit
  tests without triggering a full `init.sh` run. Strict mode is also
  gated so sourcing respects the caller's settings. Behaviour when
  invoked directly is unchanged.

## [v0.7.2] - 2026-04-14

### Changed
- Align `build.sh` / `run.sh` / `exec.sh` / `stop.sh` with Google Shell Style
  Guide: wrap top-level logic in a `main()` function with `local` variables,
  fix `case` indentation. Behavior unchanged.
- `config/pip/setup.sh`, `config/shell/tmux/setup.sh`,
  `config/shell/terminator/setup.sh`: drop `-x` from strict mode
  (`set -eux` → `set -euo pipefail`) so docker build logs stay quieter.
  Tracing can still be enabled on demand via `bash -x`.
- `script/ci/ci.sh`: refactor kcov `--exclude-path` into a readable array
  instead of one long comma-joined string. Behavior unchanged.
- Re-indent all `.bats` files under `test/smoke/`, `test/unit/`, and
  `test/integration/` from 4-space to 2-space per Google Shell Style Guide.
  Heredoc bodies untouched. Behavior unchanged; all 247 tests still pass.

## [v0.7.1] - 2026-04-10

### Fixed
- `run.sh` foreground devel: `./run.sh` appeared to hang for ~10s after the
  user typed `exit` because the cleanup trap ran `compose down` with the
  default 10s SIGTERM grace period. Pass `-t 0` so the already-exited
  interactive container is killed immediately.

## [v0.7.0] - 2026-04-09

### Added
- `build.sh` / `run.sh` / `exec.sh` / `stop.sh`: `--dry-run` flag prints the
  `docker` / `docker compose` commands that would run instead of executing them.
  Useful for debugging compose / env / instance resolution without side effects.
- `exec.sh`: precheck refuses with a friendly error pointing at `./run.sh`
  (and `--instance NAME` if applicable) when the target container is not running,
  instead of letting `compose exec` print the cryptic `service "devel" is not running`.

### Changed
- Refactor: extracted shared helpers (`_LANG` setup, `_load_env`, `_compute_project_name`,
  `_compose`, `_compose_project`) into `template/script/docker/_lib.sh`. `build.sh`,
  `run.sh`, `exec.sh`, and `stop.sh` now source `_lib.sh` and call the helpers instead
  of duplicating the same i18n / env-loading / compose-flag boilerplate.
- `exec.sh`: passes the user command as a positional array (`"$@"`) to `compose exec`,
  so arguments containing whitespace are preserved instead of being word-split.
- `run.sh`: trap is now `trap _devel_cleanup EXIT` (calls a named function) instead of
  an inline string-expanded command, matching `build.sh`'s style.

## [v0.6.8] - 2026-04-09

### Added
- `run.sh` / `exec.sh` / `stop.sh`: `--instance NAME` flag for parallel container instances
  - `./run.sh --instance dev2` starts a parallel container alongside the default
  - `./exec.sh --instance dev2 [cmd]` enters that named instance
  - `./stop.sh --instance dev2` stops only that one
  - `./stop.sh --all` stops the default + every named instance for this image
- Project name and container name now include `${INSTANCE_SUFFIX}` so each
  instance has isolated docker compose project (own network/volumes)
- `init.sh`-generated `compose.yaml` uses
  `container_name: ${IMAGE_NAME}${INSTANCE_SUFFIX:-}`
  - Default invocation (no `--instance`) keeps the clean name `${IMAGE_NAME}` —
    backward-compatible with external tools that grep `docker exec ${IMAGE_NAME}`

### Changed
- `run.sh`: foreground devel now refuses to start if a container with the
  default name is already running. Use `./stop.sh` first or pass
  `--instance NAME` to start a parallel one.

### Note
- Existing 17 consumer repos must update their `compose.yaml` to use
  `container_name: ${IMAGE_NAME}${INSTANCE_SUFFIX:-}` (one-line edit) before
  `--instance` works there. Default behavior unchanged until they upgrade.

## [v0.6.7] - 2026-04-09

### Added
- `test/integration/init_new_repo_spec.bats`: 21 Level-1 integration tests
  - Verifies `init.sh` produces a complete repo skeleton in an empty dir
    (Dockerfile, compose.yaml, .env.example, symlinks, doc tree, .github/workflows, etc.)
  - Runs inside the existing `make -f Makefile.ci test` container — no Docker needed
  - Total tests: 180 → 201 (180 unit + 21 integration)
- `.github/workflows/self-test.yaml`: new `integration-e2e` job (Level 2)
  - Runs `init.sh` → `build.sh test` → `build.sh` → `run.sh -d` → `exec.sh` → `stop.sh`
    on a synthetic temp repo, on a real GitHub runner with Docker daemon
  - `release` job now depends on both `test` and `integration-e2e`
- `script/ci/ci.sh`: now also runs `bats test/integration/` alongside `test/unit/`

## [v0.6.6] - 2026-04-09

### Fixed
- `run.sh`: foreground `devel` mode could not be entered via `./exec.sh` from another terminal
  - Symptom: `service "devel" is not running` even though `docker ps` showed it
  - Root cause: foreground used `compose run --name`, which creates a one-off container
    invisible to `compose exec` (the underlying mechanism behind `./exec.sh`)
  - Fix: foreground `devel` now uses `compose up -d` + `compose exec devel bash`
    + a `trap … down EXIT` to preserve the original "exit shell = container gone" semantic
  - Other targets (`test`, `runtime`, ...) still use `compose run --rm` (one-shot stages
    that don't need exec)
  - `compose.yaml` `container_name: ${IMAGE_NAME}` is unchanged, so external scripts
    that do `docker exec ${IMAGE_NAME}` (e.g. local CI helpers) continue to work

### Removed
- `stop.sh`: orphan-container cleanup `docker rm -f "${IMAGE_NAME}"` no longer needed
  (no more orphan from `compose run --name`)

## [v0.6.5] - 2026-04-09

### Fixed
- `build.sh`/`run.sh`/`exec.sh`/`stop.sh`: graceful fallback when `i18n.sh` is missing
  - v0.6.1 added `source template/script/docker/i18n.sh` but consumer Dockerfile
    `test` stages do `COPY *.sh /lint/` without the template tree, so the source
    failed and broke smoke tests in all consumer repos
  - Fix: each script checks for i18n.sh and falls back to inline `_detect_lang`
    if missing — no Dockerfile changes required in consumer repos

## [v0.6.4] - 2026-04-09

### Fixed
- `upgrade.sh`: greedy sed pattern clobbered `release-worker.yaml@<ver>` reference,
  replacing it with `build-worker.yaml@<ver>` and breaking release CI in consumer repos
  - Root cause: `s|template/\.github/workflows/.*@v[0-9.]*|...build-worker.yaml@...|`
    matched both worker references; the dedicated `release-worker` line that follows
    only worked when the first sed didn't already overwrite it
  - Fix: drop the greedy first sed, keep only the per-worker-name targeted seds

## [v0.6.3] - 2026-04-09

### Added
- `upgrade.sh`: `--gen-image-conf` flag (delegates to `init.sh --gen-image-conf`)
  - Lets users copy `image_name.conf` to repo root for per-repo customization
    without needing to remember the init.sh path

## [v0.6.2] - 2026-04-09

### Changed
- Remove all `# LCOV_EXCL_*` markers from shell scripts to expose real coverage
  - Coverage now reflects actual instrumented lines (95.76% vs prior masked 100%)
  - 2 new direct-run tests for `tmux/setup.sh` and `terminator/setup.sh` (171 total)
  - Remaining 10 uncovered lines in `setup.sh` are kcov bash backend limitations
    (case `;;` arms, `done` redirect close, child-bash guards)

## [v0.6.1] - 2026-04-08

### Added
- `build.sh`: `--clean-tools` flag to remove `test-tools:local` image after build
- `script/docker/i18n.sh`: shared `_detect_lang()` and `_LANG` initialization
  - Sourced by build.sh, run.sh, exec.sh, stop.sh, setup.sh
  - Eliminates ~28 lines of duplication across 5 scripts
  - Adding a new language now requires editing only one file
- `dockerfile/Dockerfile.test-tools`: include `bats-mock` (jasonkarns v1.2.5)
  - Other repos' smoke tests can now use `stub`/`unstub` for command mocking

### Changed
- `build.sh`: keep `test-tools:local` image by default (was removed on EXIT)
  - Avoids race conditions in parallel builds
  - Subsequent builds skip the test-tools build (Docker layer cache)
  - Use `--clean-tools` to restore old behavior

## [v0.6.0] - 2026-04-01

### Added
- `build.sh`: `--no-cache` flag for force rebuild (passes to both
  test-tools image build and docker compose build)
- `config/image_name.conf`: rule-driven IMAGE_NAME detection
  - Rule types: `prefix:<value>`, `suffix:<value>`, `@env_example`, `@basename`, `@default:<value>`
  - Per-repo override: place `image_name.conf` in repo root
  - Default rules: `@env_example` → `prefix:docker_` → `suffix:_ws` → `@default:unknown`
- `init.sh --gen-image-conf`: copy template's image_name.conf to repo root
  for per-repo customization

### Changed
- `detect_image_name`: refactored to read rules from `image_name.conf` instead
  of hardcoded logic
- **BREAKING**: `image_name.conf` keywords now require `@` prefix
  (`env_example` → `@env_example`, `basename` → `@basename`) to distinguish
  from user-defined values
- Default conf order: `@env_example` → `prefix:docker_` → `suffix:_ws` → `@default:unknown`
  (`.env.example` highest priority; `@default:unknown` as final fallback
  prints INFO log so users know to set IMAGE_NAME explicitly)
- New `@default:<value>` keyword: explicit fallback value with INFO log
- WARNING only when no rule matches AND no `@default:` set (custom conf scenario)

### Fixed
- `stop.sh`: remove orphan container left by `docker compose run --name`
  (`docker compose down` only cleans up `up`-mode containers, not `run`-mode)
- `upgrade.sh`: re-run `init.sh` after subtree pull to sync symlinks
  (avoids stale symlinks when template directory structure changes)

### Removed
- Stale comments referencing `get_param.sh` (historical, no longer relevant)

## [v0.5.0] - 2026-03-31

### Added
- `setup.sh`: add `APT_MIRROR_UBUNTU` and `APT_MIRROR_DEBIAN` to `.env`
  - Default: `tw.archive.ubuntu.com` (Ubuntu), `mirror.twds.com.tw` (Debian)
  - Preserves existing values from `.env` on re-run
- `setup.sh`: warn when `IMAGE_NAME` cannot be detected and `.env.example` not found
- `display_env.bats`: auto-skip GUI tests for headless repos
- `dockerfile/Dockerfile.test-tools`: pre-built test tools image (ShellCheck + Hadolint + Bats)
- `dockerfile/Dockerfile.example`: Dockerfile template for new repos
- `init.sh`: support creating new repo with full project structure
- `build.sh`: auto-build `test-tools:local` before compose build
- 5 new tests (137 total)

### Changed
- **BREAKING**: Directory restructure
  - `build.sh`, `run.sh`, `exec.sh`, `stop.sh`, `Makefile`, `setup.sh` → `script/docker/`
  - `ci.sh` → `script/ci/`
  - `init.sh`, `upgrade.sh` → template root (user-facing)
- Other repos symlink path: `template/build.sh` → `template/script/docker/build.sh`

## [v0.4.2] - 2026-03-30

### Fixed
- `run.sh`: set `--name "${IMAGE_NAME}"` in foreground mode (`docker compose run`) so container name matches `container_name` in compose.yaml

### Removed
- `script/migrate.sh`: all repos migrated, no longer needed
- i18n translations for TEST.md and CHANGELOG.md (keep English only)

## [v0.4.1] - 2026-03-29

### Changed
- Rename `test/smoke_test/` → `test/smoke/`
- Fix README.md TOC anchor and add missing Tests section

## [v0.4.0] - 2026-03-29

### Changed
- Move `config/` back to root level (was `script/config/` in v0.3.0) — configs are not scripts
- Fix `self-test.yaml` release archive: remove stale root `setup.sh` reference
- Fix mermaid architecture diagrams: `setup.sh` shown in correct `script/` box
- Add Table of Contents to zh-TW and zh-CN READMEs
- Add `Makefile.ci` entry to "What's included" table (all translations)
- Fix "Running Tests" section to use `make -f Makefile.ci` (all translations)
- Rename `test/smoke_test/` → `test/smoke/`

## [v0.3.0] - 2026-03-29

### Changed
- **BREAKING**: Rename repo `docker_template` → `template`
- **BREAKING**: Move `setup.sh` → `script/setup.sh`
- **BREAKING**: Move `config/` → `script/config/` (reverted in v0.4.0)
- Apply Google Shell Style Guide to all shell scripts
- Split `Makefile` into `Makefile` (repo entry) + `Makefile.ci` (CI entry)
- Fix directory structure, test counts, bashrc style in documentation
- 132 tests (was 124)

### Migration notes
- Other repos: subtree prefix changes from `docker_template/` to `template/`
- `CONFIG_SRC` path in Dockerfile: `docker_template/config` → `template/config`
- Symlinks: `docker_template/*.sh` → `template/*.sh`

## [v0.2.0] - 2026-03-28

### Added
- `script/ci.sh`: CI pipeline script (local + remote)
- `Makefile`: unified command entry
- Restructured `test/unit/` and `test/smoke_test/`
- Restructured `doc/` with i18n (readme/, test/, changelog/)
- Coverage permissions fix (chown with HOST_UID/HOST_GID)

### Changed
- `smoke_test/` moved to `test/smoke_test/` (**BREAKING**: Dockerfile COPY path change)
- `compose.yaml` calls `script/ci.sh --ci` instead of inline bash
- `self-test.yaml` calls `script/ci.sh` instead of docker compose directly

## [v0.1.0] - 2026-03-28

### Added
- **Shared shell scripts**: `build.sh`, `run.sh` (with X11/Wayland support), `exec.sh`, `stop.sh`
- **setup.sh**: `.env` generator merged from `docker_setup_helper` (auto-detect UID/GID, GPU, workspace path, image name)
- **Config files**: bashrc, tmux, terminator, pip configs from `docker_setup_helper`
- **Shared smoke tests** (`smoke_test/`):
  - `script_help.bats` — 16 tests for script help/usage
  - `display_env.bats` — 10 tests for X11/Wayland environment (GUI repos)
  - `test_helper.bash` — unified bats loader
- **Template self-tests** (`test/`): 114 tests with ShellCheck + Bats + Kcov coverage
- **CI reusable workflows**:
  - `build-worker.yaml` — parameterized Docker build + smoke test
  - `release-worker.yaml` — parameterized GitHub Release
  - `self-test.yaml` — template's own CI
- **`migrate.sh`**: batch migration script for converting repos from `docker_setup_helper` to `template`
- `.hadolint.yaml`: shared Hadolint rules
- `.codecov.yaml`: coverage configuration
- Documentation: README (English), README.zh-TW.md, README.zh-CN.md, README.ja.md, TEST.md

### Changed
- `setup.sh` default `_base_path` traverses 1 level up (`/..`) instead of 2 (`/../..`) to match new `template/setup.sh` location

### Migration notes
- Replace `docker_setup_helper/` subtree with `template/` subtree
- Shell scripts at root become symlinks to `template/`
- Local `build-worker.yaml` / `release-worker.yaml` replaced by reusable workflow calls in `main.yaml`
- Dockerfile `CONFIG_SRC` path: `docker_setup_helper/src/config` → `template/config`
- Shared smoke tests loaded via `COPY template/smoke_test/` in Dockerfile (not symlinks)

[v0.6.8]: https://github.com/ycpss91255-docker/template/compare/v0.6.7...v0.6.8
[v0.6.7]: https://github.com/ycpss91255-docker/template/compare/v0.6.6...v0.6.7
[v0.6.6]: https://github.com/ycpss91255-docker/template/compare/v0.6.5...v0.6.6
[v0.6.5]: https://github.com/ycpss91255-docker/template/compare/v0.6.4...v0.6.5
[v0.6.4]: https://github.com/ycpss91255-docker/template/compare/v0.6.3...v0.6.4
[v0.6.3]: https://github.com/ycpss91255-docker/template/compare/v0.6.2...v0.6.3
[v0.6.2]: https://github.com/ycpss91255-docker/template/compare/v0.6.1...v0.6.2
[v0.6.1]: https://github.com/ycpss91255-docker/template/compare/v0.6.0...v0.6.1
[v0.6.0]: https://github.com/ycpss91255-docker/template/compare/v0.5.0...v0.6.0
[v0.5.0]: https://github.com/ycpss91255-docker/template/compare/v0.4.2...v0.5.0
[v0.4.2]: https://github.com/ycpss91255-docker/template/compare/v0.4.1...v0.4.2
[v0.4.1]: https://github.com/ycpss91255-docker/template/compare/v0.4.0...v0.4.1
[v0.4.0]: https://github.com/ycpss91255-docker/template/compare/v0.3.0...v0.4.0
[v0.3.0]: https://github.com/ycpss91255-docker/template/compare/v0.2.0...v0.3.0
[v0.2.0]: https://github.com/ycpss91255-docker/template/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/ycpss91255-docker/template/releases/tag/v0.1.0
