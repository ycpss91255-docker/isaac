# Integration Tests

Integration specs under `test/bats/integration/`: **128 tests**.

> Part of the `just test` self-test suite — what runs in the `Self Test`
> CI job. See [TEST.md](TEST.md) for the index across all test types and
> the self-test grand total.

## Test Files

### test/bats/integration/init_new_repo_spec.bats (59)

End-to-end verification that `init.sh` produces a complete repo skeleton in
an empty directory. **Level 1** (file generation only, no Docker). The
**Level 2** equivalent runs as the `acceptance` job in
`.github/workflows/self-test.yaml` (the host-driven consumer/UX checks;
see [acceptance.md](acceptance.md)), which has access to a Docker daemon on
the host runner. It drives the documented `just` verbs with REAL execution
on native amd64 + arm64: the build / run -d / exec / stop runnability core
(#579/#603) plus (#769) the foreground `run` command variant, `start`
(build + run), a real `prune`, an explicit `setup apply`, the `base update`
check, and the `base completions` installer. `setup-tui` (interactive) is
intentionally out of the e2e -- it needs a pseudo-TTY and stays covered by
the unit `tui_spec`.

| Test | Description |
|------|-------------|
| `init.sh detects empty dir and creates new repo skeleton` | Smoke |
| `new repo: Dockerfile is copied from template` | Dockerfile gen |
| `new repo: compose.yaml exists and references the repo name` | compose gen |
| `new repo: .env.example is NOT generated (image name via setup.conf rules)` | setup.conf rules drive IMAGE_NAME |
| `new repo: script/entrypoint.sh exists and is executable` | entrypoint gen |
| `new repo: script/entrypoint.sh sources [logging] helper by default (refs #364)` | default in-image helper source line + comment present; ${USER} / /home/ absent (regression guards) |
| `new repo: smoke test skeleton exists for the repo` | smoke skeleton |
| `new repo: smoke tree is per-stage tool-first (shared/devel-test/runtime-test), not flat test/smoke/ (S4 items 5,8)` | - |
| `new repo: shared smoke spec loads test_helper (resolves via Dockerfile COPY at build time) (S4 item 8)` | - |
| `new repo: .github/workflows/main.yaml exists with reusable workflow ref` | CI gen |
| `new repo: .github/workflows/base-version-monitor.yaml exists (#777)` | - |
| `new repo: main.yaml grants permissions: contents: write` | #62 release perms |
| `new repo: .gitignore exists` | gitignore |
| `new repo: .dockerignore exists (#604)` | - |
| `new repo: .dockerignore contains compose.yaml (derived artifact) (#604)` | - |
| `new repo: doc/ tree exists with README translations` | i18n docs |
| `new repo: doc/test/TEST.md exists` | TEST.md gen |
| `new repo: TEST.md total matches the actual generated @test count (no stale 1 test) (S4 item 6)` | - |
| `new repo: TEST.md per-file heading is level-3 (### path (N)) so sync-doc-counts can match (S4 item 6)` | - |
| `new repo: doc/changelog/CHANGELOG.md exists` | CHANGELOG gen |
| `new repo: build.sh symlink lives under script/, not root (#330)` | symlink target moved to script/build.sh |
| `new repo: 7 wrapper symlinks under script/, justfile at root (#330, #546)` | symlink set: 7 wrappers + justfile root, no Makefile |
| `new repo: config/ is an empty placeholder (template#254 layered override)` | config placeholder |
| `new repo: init.sh preserves pre-existing config/ directory (no clobber)` | config preservation |
| `new repo: script/local/justfile.local seeded (repo-local command-group registry, #632)` | #632 — repo-owned registry seeded |
| `new repo: init.sh preserves a pre-existing script/local/justfile.local (no clobber, #632)` | #632 — never clobbers repo registrations |
| `new repo: script/local/ seeds a bash companion template alongside justfile.local (S4 item 7)` | - |
| `new repo: init.sh preserves a pre-existing script/local/local.sh (no clobber, S4 item 7)` | - |
| `new repo: init.sh seeds local.sh even when justfile.local already exists (independent guards, S4 item 7)` | - |
| `new repo: script/template/ symlinks wired for the template namespace (#633)` | #633 — justfile.template + new.sh + skel symlinked |
| `new repo: script/base/ symlink wired for the base namespace (#652, #653)` | #652, #653 — justfile.base + completions.sh symlinked; entry mods base |
| `new repo: init.sh drops stale config symlink before creating placeholder` | config-symlink drop |
| `Dockerfile.example references CONFIG_SRC="config" (not .base/dist/config)` | - |
| `Dockerfile.example has layered config COPY chain (template#254): .base/dist/config first, then config` | layered COPY order |
| `Dockerfile.example declares ENV HOME before WORKDIR ${HOME}/work (#334)` | HOME env directive |
| `Dockerfile.example sets up bashrc.d drop-in directory (template#254)` | bashrc.d setup |
| `new repo: Dockerfile contains logging.sh in-image COPY (#368)` | - |
| `new repo: .base/.version exists (no legacy VERSION / .template_version)` | version file |
| `new repo: re-running init.sh on the result is idempotent` | idempotent |
| `new repo: init.sh creates setup_tui.sh symlink under script/ (not legacy tui.sh)` | setup_tui under script/ |
| `new repo: init.sh removes stale tui.sh symlink from earlier versions (#330 stale-removal loop)` | upgrade cleanup |
| `new repo: init.sh removes stale root *.sh symlinks (#330 migration)` | migrate 7 root symlinks to script/ |
| `new repo: build.sh -h works against the generated symlink` | smoke script/build.sh |
| `new repo: run.sh -h works against the generated symlink` | smoke script/run.sh |
| `new repo: exec.sh -h works against the generated symlink` | smoke script/exec.sh |
| `new repo: stop.sh -h works against the generated symlink` | smoke script/stop.sh |
| `new repo: setup.sh symlink under script/ → ../.base/dist/script/docker/wrapper/setup.sh` | - |
| `new repo: setup.sh -h works against the generated symlink` | smoke script/setup.sh |
| `init.sh --gen-conf copies setup.conf to repo root` | setup.conf gen |
| `init.sh --gen-conf refuses to overwrite existing setup.conf` | overwrite safety |
| `new repo: .gitignore contains compose.yaml (derived artifact)` | gitignore compose.yaml |
| `new repo: .gitignore contains .env (derived artifact)` | gitignore .env |
| `new repo: compose.yaml has AUTO-GENERATED header (produced by setup.sh)` | setup.sh generated compose.yaml |
| `new repo: compose.yaml omits devices block by default (#466 opt-in)` | - |
| `new repo: setup.conf mount_1 is NOT empty after first init (workspace detected + written)` | workspace writeback non-empty |
| `new repo: per-repo setup.conf auto-created on first init (workspace writeback)` | #201 — bootstrap writes WS_PATH back |
| `new repo: init warns + exits 0 + still creates symlinks when just is absent (#607)` | Missing runner -> non-fatal WARN, symlinks still laid down |
| `new repo: init is silent about just when the runner is present (#607)` | Runner present -> no warning |
| `init.sh refuses to run when the subtree root carries .git (base template source)` | Self-run guard (ADR-00000011 sec.8): .git at subtree root -> refuse, no scaffold |

### test/bats/integration/fresh_clone_portability_spec.bats (2)

End-to-end verification for the fresh-clone-on-a-different-machine scenario:
the consumer repo's `setup.conf` has already been committed by another
contributor and carries either a stale absolute `mount_1` path (the Jetson
bug) or the portable `${WS_PATH}` form. Runs the real `build.sh` +
`setup.sh` (no mocks) and asserts the auto-migration / per-machine detection
pipeline lands a valid `.env` + `compose.yaml`. **Level 1** (no Docker
invocation — `build.sh --dry-run`).

| Test | Description |
|------|-------------|
| `fresh clone with stale absolute mount_1: setup.conf is regenerated, no path leak (#174)` | - |
| `fresh clone with portable ${WS_PATH} mount_1: no warning, .env gets local path` | Happy path round-trip |

### test/bats/integration/wrapper_compose_dispatch_spec.bats (10)

Behaviour-based assertion (#490) that every wrapper routes its `docker compose`
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
| `the -p project name and compose.yaml's name: are one value, not two computations` | - |
| `[project] name in .setup.conf.local moves BOTH the -p and the emitted name:` | - |
| `two checkouts of one repo dispatch different projects after a local override` | - |
| `an unchanged repo keeps the project name it resolved before [project] existed` | - |

### test/bats/integration/upgrade_spec.bats (21)

End-to-end verification for `upgrade.sh` driving a real subtree update
against a fake template remote (bare repo with `v0.9.5` / `v0.9.7` tags
on a minimal subtree layout) attached to a sandbox downstream repo.
**Level 1** (no Docker). Exercises the happy path, the pre-flight
guards, the destructive-FF rollback path added after the Jetson v0.9.7
incident (stubs `git-subtree pull` via `GIT_EXEC_PATH` to simulate the
bug and asserts the repo is restored), and Step 5's declarative
Dockerfile/entrypoint migration pass (#567 / #579) — sourcing
`lib/dockerfile_migrate.sh` and running `apply_migrations` over the
repo-root Dockerfile + sibling `script/entrypoint.sh` (the per-migration
{detect, transform} units are unit-tested in `dockerfile_migrate_spec.bats`),
plus the pre-pull `.setup.conf` migrations (legacy override relocation and
the `[lifecycle] restart` default retirement) observed through a real
upgrade run.

| Test | Description |
|------|-------------|
| `upgrade.sh v0.9.7: bumps .base/.version, pulls new content, updates main.yaml` | - |
| `upgrade.sh Step 5 announces the migration pass (#567)` | Step 5 runs the declarative migration dispatcher |
| `upgrade.sh heals a legacy wrapper-COPY Dockerfile via the migration list (#567 m1)` | End-to-end wrapper-copy heal + staged into the upgrade commit |
| `upgrade.sh nounset-guards a sibling entrypoint ROS source (#567 m8 / #579)` | End-to-end entrypoint nounset guard around the ROS setup.bash source |
| `upgrade.sh Step 5 continues cleanly when no Dockerfile at repo root (#567)` | Subtree-only repos (no consumer Dockerfile) skip silently |
| `upgrade.sh migrations are idempotent — already-migrated Dockerfile unchanged (#567)` | A second upgrade is a no-op on an already-migrated Dockerfile |
| `upgrade.sh v0.9.7 is idempotent on a second run` | Re-run is no-op |
| `upgrade.sh --check reports update available from v0.9.5 → v0.9.7` | --check flag |
| `just base update (downstream entry): exit 0 when update available (#175, #546, #652)` | Regression #175: recipe wraps exit 1 (skips w/o just) |
| `just base update (downstream entry): exit 0 when up-to-date (#546)` | Up-to-date path stays green (skips w/o just) |
| `upgrade.sh relocates a legacy config/docker/setup.conf override to repo-root .setup.conf, loudly` | Legacy override auto-migrated (git mv + loud warning) so it is never silently dropped |
| `upgrade.sh leaves a repo already at root .setup.conf untouched (no spurious migration)` | Already-migrated repo: no move, no spurious announcement |
| `upgrade.sh warns but does not clobber when BOTH legacy and root setup.conf exist` | Conflict: root file wins, legacy kept, warned for manual reconciliation |
| `upgrade.sh relocation commit carries only the moved paths, not unrelated staged work` | Migration commit is pathspec-scoped; pre-staged user work stays staged |
| `upgrade.sh migrates the stale devel-scoped [lifecycle] restart = no to the shipped default` | - |
| `upgrade.sh leaves a deliberately configured restart policy alone` | - |
| `upgrade.sh fails fast when git identity is missing` | Pre-flight identity guard |
| `upgrade.sh fails fast when MERGE_HEAD is present` | Pre-flight merge-state guard |
| `upgrade.sh rolls back when git-subtree does a destructive fast-forward` | Destructive-FF rollback |
| `upgrade.sh (#654 relocated): git subtree pull uses --prefix=.base, not --prefix=base` | Walk-up self-location resolves the subtree prefix to `.base` after the deep relocation; real subtree pull lands with no stray `base/` dir |
| `upgrade.sh refuses to run when the subtree root carries .git (base template source, #721)` | - |

### test/bats/integration/gitignore_sync_spec.bats (13)

End-to-end coverage that wires `lib/gitignore.sh` through `init.sh`'s
new-repo + existing-repo paths and `upgrade.sh`'s commit step. Standalone
fixture (independent of `upgrade_spec.bats`'s stub-init fixture) because
gitignore sync requires the **real** `init.sh` to run during Step 3 of
`upgrade.sh`. Issue #172.

| Test | Description |
|------|-------------|
| `init.sh new-repo: .gitignore contains all canonical entries (#507: runtime.env retired)` | - |
| `init.sh new-repo: .gitignore has the 'managed by template' marker` | Marker comment present |
| `init.sh new-repo: .dockerignore contains all canonical derived entries (#604)` | - |
| `init.sh new-repo: .dockerignore has the 'managed by template' marker (#604)` | - |
| `init.sh new-repo: log/ lands in BOTH the .gitignore and .dockerignore canonical sets (#606)` | - |
| `init.sh existing-repo: appends missing canonical entries to user .gitignore` | Drift fill-in |
| `init.sh existing-repo: untracks compose.yaml that was committed` | 15-repo drift heal |
| `init.sh existing-repo: setup.conf stays committed across init runs (#201)` | 2-file model: setup.conf is user override |
| `init.sh existing-repo: idempotent — second run produces no .gitignore changes` | Re-run no-op |
| `init.sh existing-repo: appends missing canonical entries to a user .dockerignore, preserving build-context lines (#604)` | - |
| `init.sh existing-repo: idempotent — second run produces no .dockerignore changes (#604)` | - |
| `upgrade.sh end-to-end: synced .gitignore + untracked compose.yaml in single commit` | One-shot upgrade |
| `upgrade.sh end-to-end: idempotent on a second run — no extra commits` | Re-upgrade clean |

### test/bats/integration/ci_preflight_contract_spec.bats (8)

Drives `script/ci/preflight.sh` against the ACTUAL shipped requirement
manifests (`script/ci/preflight/build.manifest` +
`release.manifest`) with a deliberately-incomplete fake caller
environment. A complete caller passes; a caller that forgot `image_name`
(build) or `archive_name_prefix` (release) fails early with the
plain-language `main.yaml` fix. The packages requirement is
`cache_backend`-conditional (#801): a `registry`-cache caller missing
`packages: write` fails with the permissions fix, a `registry` caller
that granted it passes, and the default `gha` caller passes even without
the permission (backward compatible); `--list` self-describes the build
contract, annotating packages as registry-conditional.


### test/bats/integration/deploy_bundle_flow_spec.bats (7)

The field-deploy generator end-to-end across components (ADR-00000023):
a fixture repo (repo-root `.setup.conf`, a Dockerfile with a `runtime`
stage, a `config/<component>/deploy.manifest` declaring one tunable path)
drives the real `_setup_deploy` -> `_generate_deploy_bundle` flow with a
docker + xz PATH-shim (no real daemon), and asserts the produced output
folder `deploy/<repo>-<stage>-<version>/` is correct. Distinct from the
isolated-function unit specs: this exercises the manifest -> resolve ->
resolved-compose -> bundle-files wiring as a flow.

| Test | Description |
|------|-------------|
| `deploy flow: produces the version-named output folder with all bundle files (field-deploy)` | folder + files |
| `deploy flow: the resolved compose is self-contained and pins the versioned image (field-deploy)` | self-contained compose |
| `deploy flow: the manifest path is delivered as an editable copy + a mount-wins bind (field-deploy)` | tunable delivery |
| `deploy flow: the thin launcher drives docker load + compose up/down (field-deploy)` | launcher shape |
| `deploy flow: the bundle compose carries the watchdog env + the configured restart end to end (#840)` | - |
| `deploy flow: [environment] is baked as ENV into a stage that is not named runtime (#840)` | - |
| `deploy flow: the README names the versioned image + the tunable config workflow (field-deploy)` | README template |

### test/bats/integration/doc_counts_merge_spec.bats (2)

Drives `script/test/resolve-doc-counts.sh` against a REAL git merge conflict:
two branches that each added tests and both bumped the same generated totals,
which is the conflict shape every branch refresh in the base review batch
produced. Asserts the merged tree is regenerated, complete, staged and
gate-clean -- and that a merge whose sides describe the same test differently
is refused with nothing staged.

| Test | Description |
|------|-------------|
| `resolve-doc-counts: resolves a real two-branch counter conflict end to end (#857)` | - |
| `resolve-doc-counts: REFUSES a merge whose sides describe the same test differently, staging nothing (#857)` | - |

### test/bats/integration/compose_test_tools_image_spec.bats (3)

How the repo-root `compose.yaml` resolves `TEST_TOOLS_IMAGE` -- the one
variable naming both the image the build-only `test-tools` service writes
and the image the `ci` / `coverage` / `ci-system` services run. The
assertions drive `docker compose config` (pure client-side interpolation:
compose CLI, no daemon, no socket) rather than reading the file's text,
because the text is not what decides which image a run pulls.

| Test | Description |
|------|-------------|
| `compose.yaml: with TEST_TOOLS_IMAGE unset the tag the test-tools build writes is the tag the ci run reads (#896)` | #896 build side vs run side |
| `compose.yaml: with TEST_TOOLS_IMAGE unset every consumer service reaches the same outcome as the build (#896)` | #896 coverage / ci-system too |
| `compose.yaml: an unset TEST_TOOLS_IMAGE fails naming the just recipe to run (#896)` | #896 loud, and actionable |

### test/bats/integration/compose_host_identity_spec.bats (3)

| Test | Description |
|------|-------------|
| `compose.yaml: an unset HOST_UID fails naming the entry point to use (#895)` | - |
| `compose.yaml: an unset HOST_GID fails the same way (#895)` | - |
| `compose.yaml: every checkout-mounting service takes the supplied ids verbatim (#895)` | - |
