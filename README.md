# template

[![Self Test](https://github.com/ycpss91255-docker/template/actions/workflows/self-test.yaml/badge.svg)](https://github.com/ycpss91255-docker/template/actions/workflows/self-test.yaml)
[![codecov](https://codecov.io/gh/ycpss91255-docker/template/branch/main/graph/badge.svg)](https://codecov.io/gh/ycpss91255-docker/template)

![Language](https://img.shields.io/badge/Language-Bash-blue?style=flat-square)
![Testing](https://img.shields.io/badge/Testing-Bats-orange?style=flat-square)
![ShellCheck](https://img.shields.io/badge/ShellCheck-Compliant-brightgreen?style=flat-square)
![Coverage](https://img.shields.io/badge/Coverage-Kcov-blueviolet?style=flat-square)
[![License](https://img.shields.io/badge/License-GPL--3.0-yellow?style=flat-square)](./LICENSE)

Shared template for Docker container repos in the [ycpss91255-docker](https://github.com/ycpss91255-docker) organization.

**[English](README.md)** | **[繁體中文](doc/readme/README.zh-TW.md)** | **[简体中文](doc/readme/README.zh-CN.md)** | **[日本語](doc/readme/README.ja.md)**

---

## Table of Contents

- [TL;DR](#tldr)
- [Overview](#overview)
- [Quick Start](#quick-start)
- [CI Reusable Workflows](#ci-reusable-workflows)
- [Running Template Tests](#running-template-tests)
- [Tests](#tests)
- [Directory Structure](#directory-structure)

---

## TL;DR

```bash
# New repo from scratch: init + first commit + subtree + init.sh
mkdir <repo_name> && cd <repo_name>
git init
git commit --allow-empty -m "chore: initial commit"
git subtree add --prefix=template \
    https://github.com/ycpss91255-docker/template.git main --squash
./template/init.sh

# Upgrade to latest
make upgrade-check   # check
make upgrade         # pull + update version + workflow tag

# Run CI
make test            # ShellCheck + Bats + Kcov
make help            # show all commands
```

## Overview

This repo consolidates shared scripts, tests, and CI workflows used across all Docker container repos. Instead of maintaining identical files in 15+ repos, each repo pulls this template as a **git subtree** and uses symlinks.

### Architecture

```mermaid
graph TB
    subgraph template["template (shared repo)"]
        scripts[".hadolint.yaml / Makefile.ci / compose.yaml"]
        smoke["test/smoke/<br/>script_help.bats<br/>display_env.bats"]
        config["config/<br/>bashrc / tmux / terminator / pip"]
        mgmt["script/docker/<br/>build.sh / run.sh / exec.sh / stop.sh / setup.sh"]
        workflows["Reusable Workflows<br/>build-worker.yaml<br/>release-worker.yaml"]
    end

    subgraph consumer["Docker Repo (e.g. ros_noetic)"]
        symlinks["build.sh → template/script/docker/build.sh<br/>run.sh → template/script/docker/run.sh<br/>exec.sh / stop.sh / .hadolint.yaml"]
        dockerfile["Dockerfile<br/>compose.yaml<br/>.env.example<br/>script/entrypoint.sh"]
        repo_test["test/smoke/<br/>ros_env.bats (repo-specific)"]
        main_yaml["main.yaml<br/>→ calls reusable workflows"]
    end

    template -- "git subtree" --> consumer
    scripts -. symlink .-> symlinks
    smoke -. "Dockerfile COPY" .-> repo_test
    workflows -. "@tag reference" .-> main_yaml
```

### CI/CD Flow

```mermaid
flowchart LR
    subgraph local["Local"]
        build_test["./build.sh test"]
        make_test["make test"]
    end

    subgraph ci_container["CI Container (kcov/kcov)"]
        shellcheck["ShellCheck"]
        hadolint["Hadolint"]
        bats["Bats smoke tests"]
    end

    subgraph github["GitHub Actions"]
        build_worker["build-worker.yaml<br/>(from template)"]
        release_worker["release-worker.yaml<br/>(from template)"]
    end

    build_test --> ci_container
    make_test -->|"script/ci/ci.sh"| ci_container
    shellcheck --> hadolint --> bats

    push["git push / PR"] --> build_worker
    build_worker -->|"docker build test"| ci_container
    tag["git tag v*"] --> release_worker
    release_worker -->|"tar.gz + zip"| release["GitHub Release"]
```

### What's included

| File | Description |
|------|-------------|
| `build.sh` | Build containers (TTY-aware `--setup` launches `setup_tui.sh`, else runs `setup.sh`) |
| `run.sh` | Run containers (X11/Wayland support; same `--setup` semantics as `build.sh`) |
| `exec.sh` | Exec into running containers |
| `stop.sh` | Stop and remove containers |
| `setup_tui.sh` | Interactive setup.conf editor (dialog / whiptail front-end) |
| `script/docker/setup.sh` | Auto-detect system parameters and generate `.env` + `compose.yaml` |
| `script/docker/_tui_backend.sh` | dialog/whiptail wrapper functions used by `setup_tui.sh` |
| `script/docker/_tui_conf.sh` | INI validators + read/write for `setup_tui.sh` and `setup.sh` writeback |
| `script/docker/_lib.sh` | Shared helpers (`_load_env`, `_compose`, `_compose_project`, ...) |
| `script/docker/i18n.sh` | Shared language detection (`_detect_lang`, `_LANG`) |
| `config/` | Container-internal shell configs (bashrc, tmux, terminator, pip) |
| `setup.conf` | Single per-repo runtime configuration (image / build / deploy / gui / network / volumes) |
| `test/smoke/` | Shared smoke tests + runtime assertion helpers (see below) |
| `test/unit/` | Template self-tests (bats + kcov) |
| `test/integration/` | Level-1 `init.sh` end-to-end tests |
| `.hadolint.yaml` | Shared Hadolint rules |
| `Makefile` | Repo entry (`make build`, `make run`, `make stop`, etc.) |
| `Makefile.ci` | Template CI entry (`make test`, `make -f Makefile.ci lint`, etc.) |
| `init.sh` | First-time symlink setup + new-repo scaffolding |
| `upgrade.sh` | Subtree version upgrade |
| `script/ci/ci.sh` | CI pipeline (local + remote) |
| `dockerfile/Dockerfile.example` | Multi-stage Dockerfile template for new repos |
| `dockerfile/Dockerfile.test-tools` | Pre-built lint/test tools image (shellcheck, hadolint, bats, bats-mock) |
| `.github/workflows/` | Reusable CI workflows (build + release) |

### Dockerfile stages (convention)

Downstream repos follow a standard multi-stage layout, defined in
`dockerfile/Dockerfile.example`. All stages share a common base image
parameterized by `ARG BASE_IMAGE`.

| Stage | Parent | Purpose | Shipped? |
|-------|--------|---------|----------|
| `sys` | `${BASE_IMAGE}` | User/group, sudo, timezone, locale, APT mirror | intermediate |
| `base` | `sys` | Development tools and language packages | intermediate |
| `devel` | `base` | App-specific tools + `entrypoint.sh` + PlotJuggler (env repos) | **yes** (primary artifact) |
| `test` | `devel` | Ephemeral: ShellCheck + Hadolint + Bats smoke (all from `test-tools:local`) | no (discarded) |
| `runtime-base` (optional) | `sys` | Minimal runtime deps (sudo, tini) | intermediate |
| `runtime` (optional) | `runtime-base` | Slim runtime image (application repos only) | yes, when enabled |

Notes:
- Repos that only ship a developer image (`env/*`) skip `runtime-base` /
  `runtime` — the section stays commented in `Dockerfile.example`.
- `test` is always built from `devel`, so runtime assertions inside
  `test/smoke/<repo>_env.bats` see the same binaries / files a user would
  find after `docker run ... <repo>:devel`.
- `Dockerfile.test-tools` builds the lint/test tool bundle (bats + shellcheck +
  hadolint). The downstream `test` stage consumes it through an `ARG
  TEST_TOOLS_IMAGE` build arg — defaults to `test-tools:local` (matches the
  local `./build.sh` flow that builds `Dockerfile.test-tools` into the host
  Docker daemon). CI overrides it to
  `ghcr.io/ycpss91255-docker/test-tools:vX.Y.Z` (pre-built multi-arch image
  pushed by `.github/workflows/release-test-tools.yaml` on every tag) so
  buildx pulls the arch-correct binaries over the wire instead of rebuilding
  them per run, and sidesteps the cross-step image-store isolation that
  `docker-container` buildx drivers enforce.

### Smoke test helpers (for downstream repos)

`test/smoke/test_helper.bash` (loaded by every smoke spec via
`load "${BATS_TEST_DIRNAME}/test_helper"`) ships a small set of runtime
assertion helpers. Downstream repos should prefer these over ad-hoc
`[ -f ... ]` / `command -v` checks so failures produce decorated
diagnostics pointing at the missing artifact.

| Helper | Usage |
|--------|-------|
| `assert_cmd_installed <cmd>` | Fails unless `<cmd>` is on `PATH` |
| `assert_cmd_runs <cmd> [flag]` | Fails unless `<cmd> <flag>` exits 0 (default flag: `--version`) |
| `assert_file_exists <path>` | Fails unless `<path>` is a regular file |
| `assert_dir_exists <path>` | Fails unless `<path>` is a directory |
| `assert_file_owned_by <user> <path>` | Fails unless `<path>`'s owner is `<user>` |
| `assert_pip_pkg <pkg>` | Fails unless `pip show <pkg>` returns 0 |

### What stays in each repo (not shared)

- `Dockerfile`
- `compose.yaml`
- `.env.example`
- `script/entrypoint.sh`
- `doc/` and `README.md`
- Repo-specific smoke tests

## Per-repo runtime configuration

Each downstream repo drives its runtime config — GPU reservation, GUI
env/volumes, network mode, extra volume mounts — through a single
`setup.conf` INI file. `setup.sh` reads it (plus system detection) and
regenerates both `.env` and `compose.yaml`; users never hand-edit those
two derived artifacts.

### One conf, six sections

```
[image]    rules = prefix:docker_, suffix:_ws, @default:unknown
[build]    apt_mirror_ubuntu, apt_mirror_debian            # Dockerfile build args
[deploy]   gpu_mode (auto|force|off), gpu_count, gpu_capabilities
[gui]      mode (auto|force|off)
[network]  mode (host|bridge|none), ipc, privileged
[volumes]  mount_1 (workspace, auto-populated on first run)
           mount_2..mount_N (extra host mounts; devices via /dev path)
```

Template default lives at `template/setup.conf`; per-repo overrides go
at `<repo>/setup.conf`. Section-level **replace** strategy: a section
present in the per-repo file fully replaces the template's section;
omitted sections fall back to template.

On first `setup.sh` run (no per-repo setup.conf yet), the template file
is copied to the repo and the detected workspace is written to
`[volumes] mount_1`. Subsequent runs read `mount_1` as source of truth
— clear it to opt out of mounting a workspace. Edit via:

```bash
./setup_tui.sh                      # interactive dialog/whiptail editor
./setup_tui.sh volumes              # jump directly to one section
./build.sh --setup            # launches setup_tui.sh under TTY; setup.sh otherwise
./template/init.sh --gen-conf # plain copy of template/setup.conf to repo root
```

### Interactive TUI

`./setup_tui.sh` opens the main menu and lets you edit values across all sections; the backend is `dialog` or `whiptail` (when both are missing it prints a `sudo apt install dialog` hint and exits). Cancel / Esc leaves without saving; saving auto-invokes `setup.sh` to regenerate `.env` + `compose.yaml`.

### When setup.sh runs

`setup.sh` runs only when explicitly triggered — it is not re-run on
every build or launch:

- **`./template/init.sh`** runs it once after the skeleton lands
- **`make upgrade` / `./template/upgrade.sh`** re-runs it via init.sh
  after the subtree pull, so an upgrade always lands with `.env` /
  `compose.yaml` regenerated against the new baseline
- **`./build.sh --setup` / `./run.sh --setup`** (or `-s`) re-runs it on demand
- **First-time bootstrap**: `./build.sh` / `./run.sh` auto-run setup.sh
  the very first time (when `.env` is missing, e.g. after a fresh CI
  clone) — no manual `--setup` needed

`setup.sh apply` rewrites `compose.yaml` from scratch every time but
preserves `WS_PATH` / `APT_MIRROR_UBUNTU` / `APT_MIRROR_DEBIAN` from any
existing `.env`, so a hand-tuned workspace path or apt mirror survives
upgrades.

### Drift detection

`setup.sh` stores `SETUP_CONF_HASH`, `SETUP_GUI_DETECTED`, and
`SETUP_TIMESTAMP` in `.env`. On every `./build.sh` / `./run.sh`,
stored values are compared against the current setup.conf hash + system
detection; a `[WARNING]` is printed (non-blocking) when any of the
following changed since last setup:

- `setup.conf` contents (conf hash)
- GPU / GUI detection
- `USER_UID` (user identity change)

Re-run with `--setup` to regenerate `.env` + `compose.yaml`.

### setup.sh subcommands (v0.11.0+)

`setup.sh` is a git-style backend with explicit subcommands. The build / run / TUI scripts call it for you; invoke directly for scripted / non-interactive use:

| Subcommand | Use |
|---|---|
| `apply` | Regenerate `.env` + `compose.yaml` from setup.conf + system detection |
| `check-drift` | Exit 0 in-sync / 1 drifted (drift descriptions on stderr) |
| `set <section>.<key> <value>` | Write a single key |
| `show <section>[.<key>]` | Read single key or whole section |
| `list [<section>]` | INI-style dump |
| `add <section>.<list> <value>` | Append to list-style section (`mount_*` / `env_*` / `port_*` / …); reuses next empty slot or `max+1` |
| `remove <section>.<key>` / `<section>.<list> <value>` | Delete by exact key, or by value match |
| `reset [-y\|--yes]` | Restore template default; archives prior `setup.conf` → `setup.conf.bak`, prior `.env` → `.env.bak` |

Typed keys validate against `_tui_conf.sh` validators (the same ones the TUI uses). `set` / `add` / `remove` / `reset` do **not** regenerate `.env` — chain `apply` afterwards, or `build.sh` / `run.sh` will trigger drift-regen on next invocation.

#### Migration from v0.10.x (BREAKING)

`setup.sh` (no args) and `setup.sh --base-path X --lang Y` (no subcommand) used to silently fall through to `apply`. v0.11.0 removes that fall-through:

| Invocation | Pre-v0.11 | v0.11+ |
|---|---|---|
| `setup.sh` | runs apply | prints help, exits 0 |
| `setup.sh --base-path X --lang Y` | runs apply | exit 1 "Unknown subcommand" |
| `setup.sh apply [...]` | runs apply | runs apply (unchanged) |

If a downstream repo has custom scripts invoking `setup.sh` directly, prepend `apply`. The bundled `build.sh` / `run.sh` / `init.sh` / `setup_tui.sh` are already updated.

### Derived artifacts (gitignored)

- `.env` — runtime variable values + `SETUP_*` drift metadata
- `compose.yaml` — full compose with baseline + conditional blocks

Open `compose.yaml` anytime to inspect the repo's current effective
configuration. Both files are regenerated on every `make upgrade`
(init.sh re-runs `setup.sh apply` after the subtree pull) — never
hand-edit them; put your overrides in `setup.conf` instead.

## Quick Start

### Adding to a new repo

```bash
# 1. Initialize empty repo (skip if you already have one with at least one commit)
mkdir <repo_name> && cd <repo_name>
git init
git commit --allow-empty -m "chore: initial commit"

# 2. Add subtree
git subtree add --prefix=template \
    https://github.com/ycpss91255-docker/template.git main --squash

# 3. Initialize symlinks (one command; runs setup.sh under the hood)
./template/init.sh
```

> `git subtree add` requires `HEAD` to exist. On a freshly `git init`-ed repo with no commits, it fails with `ambiguous argument 'HEAD'` and `working tree has modifications`. The empty commit creates `HEAD` so subtree can merge into it.

### Updating

Prerequisites: `git config user.name` / `user.email` must be set, and
the working tree can't be mid-merge / rebase / cherry-pick / revert —
upgrade.sh fails fast with an actionable message instead of half-pulling.

```bash
# Check if update available
make upgrade-check

# Upgrade to latest (subtree pull + version file + workflow tag)
make upgrade

# Or pin a specific version
make upgrade VERSION=v0.3.0
# Pinning to a version OLDER than the current local pin (e.g. rolling
# from v0.12.0-rc1 back to v0.11.0) is refused as an implicit downgrade
# per SemVer §11. Edit template/.version manually if intentional.

# Fallback if make is unavailable
./template/upgrade.sh v0.3.0
```

`upgrade.sh` handles the full cycle in one go:

1. `git subtree pull --prefix=template ... --squash`
2. Post-pull integrity check — `git reset --hard` rollback if subtree
   markers (`template/.version`, `template/init.sh`,
   `template/script/docker/setup.sh`) are missing (catches the
   destructive fast-forward seen on older `git-subtree.sh`)
3. `./template/init.sh` re-runs to: resync root symlinks
   (`build.sh` / `run.sh` / `Makefile` …), sync `.gitignore` against
   the canonical entry set, `git rm --cached` any tracked-but-now-derived
   files (`.env`, `compose.yaml`, …), and call `setup.sh apply` to
   regenerate `.env` + `compose.yaml`
4. `sed` rewrites `.github/workflows/main.yaml`'s
   `build-worker.yaml@vX.Y.Z` / `release-worker.yaml@vX.Y.Z` refs

Your per-repo files are never overwritten: `<repo>/setup.conf` stays
as-is, and `<repo>/config/` (bashrc / tmux / terminator …) is left
alone — if upstream `template/config/` moved since the last pull,
upgrade.sh prints a `diff -ruN template/config config` hint so you can
reconcile manually.

Don't `git subtree pull` by hand — the integrity check, init.sh
resync, and sed steps are easy to forget.

#### Automated version bumps (optional)

Downstream repos can let Dependabot open PRs whenever a new `template` tag
ships. Add `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

Dependabot notices the `uses: ycpss91255-docker/template/...@vX.Y.Z` refs in
`main.yaml`, compares against the template's latest tag, and files a PR. You
still run `make upgrade VERSION=vX.Y.Z` locally to sync the subtree itself —
Dependabot only bumps the workflow refs.

## CI Reusable Workflows

Repos replace local `build-worker.yaml` / `release-worker.yaml` with calls to this repo's reusable workflows:

```yaml
# .github/workflows/main.yaml
jobs:
  call-docker-build:
    uses: ycpss91255-docker/template/.github/workflows/build-worker.yaml@v1
    with:
      image_name: ros_noetic
      build_args: |
        ROS_DISTRO=noetic
        ROS_TAG=ros-base
        UBUNTU_CODENAME=focal

  call-release:
    needs: call-docker-build
    if: startsWith(github.ref, 'refs/tags/')
    uses: ycpss91255-docker/template/.github/workflows/release-worker.yaml@v1
    with:
      archive_name_prefix: ros_noetic
```

### build-worker.yaml inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `image_name` | string | yes | - | Container image name |
| `build_args` | string | no | `""` | Multi-line KEY=VALUE build args |
| `build_runtime` | boolean | no | `true` | Whether to build runtime stage |
| `platforms` | string | no | `"linux/amd64"` | Comma-separated target platforms; each runs as a parallel native-runner shard (`linux/amd64` → ubuntu-latest, `linux/arm64` → ubuntu-24.04-arm) |
| `test_tools_version` | string | no | `"latest"` | Tag for `ghcr.io/ycpss91255-docker/test-tools:<tag>` build-arg; pin to the template release you upgraded from for reproducibility |

### release-worker.yaml inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `archive_name_prefix` | string | yes | - | Archive name prefix |
| `extra_files` | string | no | `""` | Space-separated extra files |

## Running Template Tests

Using `Makefile.ci` (from template root):
```bash
make -f Makefile.ci test        # Full CI (ShellCheck + Bats + Kcov) via docker compose
make -f Makefile.ci lint        # ShellCheck only
make -f Makefile.ci clean       # Remove coverage reports
make help        # Show repo targets
make -f Makefile.ci help  # Show CI targets
```

Or directly:
```bash
./script/ci/ci.sh          # Full CI via docker compose
./script/ci/ci.sh --ci     # Run inside container (used by compose)
```

## Tests

See [TEST.md](doc/test/TEST.md) for details.

## Directory Structure

```
template/
├── init.sh                           # Initialize repo (new or existing)
├── upgrade.sh                        # Upgrade template subtree version
├── script/
│   ├── docker/                       # Docker operation scripts (symlinked by repos)
│   │   ├── build.sh
│   │   ├── run.sh
│   │   ├── exec.sh
│   │   ├── stop.sh
│   │   ├── setup.sh                  # .env generator
│   │   ├── _lib.sh                   # Shared helpers (_load_env, _compose, _compose_project)
│   │   ├── i18n.sh                   # Shared language detection (_detect_lang, _LANG)
│   │   └── Makefile
│   └── ci/
│       └── ci.sh                     # CI pipeline (local + remote)
├── dockerfile/
│   ├── Dockerfile.test-tools         # Pre-built lint/test tools image
│   └── Dockerfile.example            # Dockerfile template for new repos (sys → base → devel → test → [runtime])
├── setup.conf                        # Single runtime config (per-repo override mirror: <repo>/setup.conf)
├── config/                           # Container-internal shell/tool configs
│   ├── image_name.conf               # Default IMAGE_NAME detection rules
│   ├── pip/
│   │   ├── setup.sh
│   │   └── requirements.txt
│   └── shell/
│       ├── bashrc
│       ├── terminator/
│       │   ├── setup.sh
│       │   └── config
│       └── tmux/
│           ├── setup.sh
│           └── tmux.conf
├── test/
│   ├── smoke/                        # Shared smoke tests + runtime assertion helpers
│   │   ├── test_helper.bash          #  → assert_cmd_installed / _runs / file / dir / owned_by / pip_pkg
│   │   ├── script_help.bats
│   │   └── display_env.bats
│   ├── unit/                         # Template self-tests (bats + kcov)
│   │   ├── test_helper.bash
│   │   ├── bashrc_spec.bats
│   │   ├── ci_spec.bats              # ci.sh _install_deps
│   │   ├── lib_spec.bats             # _lib.sh
│   │   ├── pip_setup_spec.bats
│   │   ├── setup_spec.bats
│   │   ├── smoke_helper_spec.bats    # Runtime assertion helpers
│   │   ├── template_spec.bats
│   │   ├── terminator_config_spec.bats
│   │   ├── terminator_setup_spec.bats
│   │   ├── tmux_conf_spec.bats
│   │   └── tmux_setup_spec.bats
│   └── integration/
│       └── init_new_repo_spec.bats   # Level-1 init.sh end-to-end
├── Makefile.ci                       # Template CI entry (make test/lint/...)
├── compose.yaml                      # Docker CI runner
├── .hadolint.yaml                    # Shared Hadolint rules
├── codecov.yml
├── .github/workflows/
│   ├── self-test.yaml                # Template CI
│   ├── build-worker.yaml             # Reusable build workflow
│   └── release-worker.yaml           # Reusable release workflow
├── doc/
│   ├── readme/                       # README translations (zh-TW / zh-CN / ja)
│   ├── test/TEST.md                  # Test catalog (spec tables)
│   └── changelog/CHANGELOG.md        # Release notes
├── .gitignore
├── LICENSE
└── README.md
```
