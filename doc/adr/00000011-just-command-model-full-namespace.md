# `just` command model: zero-special-case namespaces, generic tooling, min->max coverage

> Serves: PRD invariant 6 (base is a subtree; downstream a thin caller)
> -- established the zero-special-case `just` command model + generic
> runner.

- **Date:** 2026-06-23
- **Status:** Accepted
- **Amends:** ADR-00000010 (docker is no longer top-level; `ci`/`cd`
  namespaces renamed; entry shape) and ADR-00000006 (`init.sh` /
  `upgrade.sh` leave the base root)
- **Builds on:** ADR-00000005 (`just` as the user-facing entry)
- **Amended:** 2026-06-26 by #714 -- the shipped-tree directory `downstream/`
  was renamed to `dist/` (terminology de-overload; `dist` = distribution).
  Every `downstream/script/<ns>/` reference in sec.4 (the origin), sec.5,
  and the §8 relocation now reads `dist/script/<ns>/`; the origin
  single-source-of-truth lives at `dist/script/<ns>/` and a consumer's
  `script/<ns>/` symlinks into `.base/dist/script/<ns>/`. See ADR-00000006's
  #714 amendment for the frozen-path-contract + consumer-migration detail.

## Context

ADR-00000010 shipped the layered entry + base/downstream split, but kept
two asymmetries that turned out to be load-bearing irritants once the
namespaces multiplied:

1. **docker recipes stayed top-level** (`just build`, `just run`) while
   everything else was a `mod?` namespace (`just ci ...`,
   `just template ...`). The top-level docker recipes are a *special
   case*: adding any new top-level verb risks the duplicate-name hard
   error, and the mental model ("some verbs are bare, some are
   namespaced") has to be memorised.

2. **The namespace names described mechanism, not action.** `ci` / `cd`
   are pipeline-stage jargon; a user wanting "run the tests" or "cut a
   release" has to translate. And the natural request "I want every CI
   check under one roof" did not map onto `ci` + a separate top-level
   `lint`.

Three further requirements surfaced while using the layered entry:

- **Coverage from smallest to largest unit.** Every command should scale
  from one file / one check up to the whole suite, *narrowing via
  options* rather than memorising sub-recipes or passing bare positional
  args whose meaning is positional.
- **One generic tool, per-repo content.** base self-tests the template
  (shellcheck + bats over its own scripts/specs); a consumer tests its
  image (build the devel-test stage, run smoke). These were modelled as
  *different* tooling. They are not: the *tools* (shellcheck, bats,
  hadolint) are identical; only the *content* of `test/` differs. Modelling
  them as one generic runner is what lets the whole `script/` tree be a
  single shared origin.
- **`init.sh` / `upgrade.sh` at the base root are an eyesore** and break
  the "every action lives in a namespace" rule.

`just` 1.52 facts from ADR-00000010 still hold (symlink-relative import
resolution; duplicate top-level recipe name = hard error; `mod?` =
namespace; `import?`/`mod?` of a missing file is not an error).
Additionally verified for this decision:

- `just <ns> <recipe> --help` reaches the module: per-recipe help and
  `--lang` are surfaced by the recipe forwarding the flag to its backing
  script (the wrappers already localise via `--lang`). The dashed
  `just <ns> --help` does **not** reach the module -- a dashed name cannot
  be a `just` recipe/alias, so it is parsed as a recipe lookup that errors;
  namespace help is `just <ns>` or the `just <ns> help` recipe instead (see
  §6, reconciled by #789).
- Dynamic shell completion (`clap_complete`, `JUST_COMPLETE=<shell> just`)
  is **module-aware** -- it drills into `just docker <tab>` and
  `just test lint <tab>`. The distro `just.fish` (shipped by the *fish*
  package, not `just`) only lists top-level recipes and does **not**
  drill, which is why an explicit completion installer is needed.

## Decision

### 1. Zero special cases: every action is a namespace

The entry mods every group; **nothing is top-level**. docker joins the
other namespaces:

```just
mod? docker   'script/docker/justfile.docker'
mod? test     'script/test/justfile.test'
mod? release  'script/release/justfile.release'
mod? base     'script/base/justfile.base'
mod? template 'script/template/justfile.template'      # consumer only in practice
import? 'script/local/justfile.local'                  # repo-owned user groups
default:
    @just --list
```

`just build` becomes `just docker build`. The cost (longer invocations)
is accepted in exchange for one rule with no exceptions, and completion
(below) makes the extra token a single `<tab>`.

### 2. Action-named namespaces

| was (ADR-00000010) | now | rationale |
|---|---|---|
| `just build/run/...` (top-level) | `just docker build/run/exec/stop/prune/setup/setup-tui` | docker is the action group, no special case |
| `just ci` | `just test` | the action is "test"; **all** CI checks live here, incl. lint |
| `just cd` | `just release` | the action is "cut a release" |
| `init` / `upgrade` / `upgrade-check` (root scripts) | `just base init` / `just base upgrade [ver]` / `just base update` | manage the `.base` dependency; `update`/`upgrade` mirror apt (refresh-check vs apply) |

`lint` is **not** a top-level peer of `test`; it is `just test lint`
(a sub-action of the test namespace). A new top-level command would need
its own `justfile.<x>` + scripts; lint is part of testing, so it stays
inside `test`.

### 3. min->max coverage via `--option` narrowing

Every command runs the **maximum** scope bare and **narrows** through
`--long` / `-short` options -- never bare positional args whose meaning is
positional:

```
just test                       # everything (shellcheck + bats + ... + coverage as configured)
just test --file <path>         # one spec file
just test --filter <regex>      # specs matching a pattern
just test lint                  # all linters
just test lint --shellcheck [<level>]   # only shellcheck (optionally at a severity level)
just test lint --hadolint               # only hadolint
just docker build                       # default stage
just docker build --stage <name>        # a specific stage (base self-test: --stage test-tools)
just base upgrade                       # latest tag
just base upgrade --tag <vX.Y.Z>        # a specific tag
```

The single-file test mode (previously supported) is preserved as
`--file`. `test-tools` is built explicitly as
`just docker build --stage test-tools`; the test runner invokes it
internally rather than `build` growing a magic `test` argument.

### 4. Generic tooling, per-repo content, single source of truth

The whole `script/<ns>/` tree is **generic tooling with a single source of
truth**; only repo-specific *content* differs. Therefore:

- The **real files live in `dist/script/<ns>/`** (the shipped tree),
  which is the single source of truth. base-own **`script/<ns>/` symlinks
  into `dist/script/<ns>/`** so base uses the very tooling it ships,
  with no duplicate base-own copy. A consumer's **`script/<ns>/` symlinks
  into `.base/dist/script/<ns>/`** -- a **single hop** to the real
  file. (Per-sub symlinks, not a single whole-`script/` symlink, so
  `script/local/` and `script/entrypoint.sh` can stay *inside* `script/`
  and remain repo-owned -- alignment is kept.)
- **Content is per-repo and never symlinked**: `test/` (specs),
  `config/`, `Dockerfile`, `compose.yaml`. base has its own
  (`test/{unit,integration,behavioural}`, `Dockerfile.test-tools`,
  base `compose.yaml`); a consumer has its own (`test/smoke/`, app
  `Dockerfile`).

**Origin-direction is build-verified (corrected 2026-06-23).** The
opposite direction -- real files in base `script/<ns>/`, with
`dist/script/<ns>/` as a *directory* symlink back -- was tested and
rejected: it makes the consumer wrapper symlinks (`<repo>/script/build.sh
-> .base/dist/script/docker/wrapper/build.sh`) a **two-hop** chain
(file symlink through a directory symlink), and BuildKit does **not**
resolve that at `COPY` time. The required lint copy `COPY script/*.sh
/lint/` then fails with `"/script/build.sh": not found`. (A single
directory-symlink path such as `COPY .base/dist/script/docker/lib
/lint/lib` *does* resolve; only the two-hop chain fails.) Keeping the real
bytes at the `dist/` path the consumer references makes every
consumer symlink single-hop -- the shape already proven in CI -- and
leaves the consumer Dockerfile COPY paths and the ADR-00000006 Region C
`upgrade.sh` paths **unchanged**. For docker this is exactly today's
on-disk layout, so #654 is not a file move but the addition of the
base-own `script/<ns>` symlinks plus the consumer per-sub symlinks.

**Amended 2026-06-24 (#654).** The base=origin symlink-unification this
section describes turned out to be **N/A in practice -- there is no
duplicated tooling to unify**. Audit of the tree found: the real docker
files already live single-copy at `dist/script/docker/`; base-own
`script/test/` + `script/release/` are base's OWN self-test / skeleton
tooling (not shipped copies of a downstream original); and the consumer
entry mods only `dist/.../template`. So there is no second copy of
any namespace to collapse into a symlinked origin. What #654 actually did
was the narrow, real change hiding inside this section's premise: relocate
`init.sh` + `upgrade.sh` out of the subtree root into
`dist/script/base/` (the §8 move), with `upgrade.sh`'s self-location
rewritten to a walk-up so the `git subtree pull --prefix=` stays `.base`.
The per-sub symlink wiring for namespaces remains as designed where a
genuine origin/consumer split exists; it was simply not a
deduplication.

### 5. Generic test runner: dispatcher + per-tool drivers

`script/test/` is a dispatcher (`test.sh`) plus one **driver per tool**
(`drivers/{bats,shellcheck,hadolint,...}.sh`); adding a tool is a new
driver + a folder, the dispatcher is untouched. The dispatcher adapts to
the **content present** using the **same** tools everywhere.

The `test/` content is laid out **tool-first** -- `test/<tool>/<category>/`
for specs, `test/lint/<tool>/` for linters -- which **supersedes
ADR-00000004** (category-first); see ADR-00000012 for that decision and
its trade-offs. Detection and execution environment:

- `test/<tool>/<category>/` present -> run that tool's driver. The
  execution environment depends on the **category**:
  - `smoke` -> inside the built `*-test` image stage (devel-test /
    runtime-test) -- it tests the real image;
  - `unit` / `integration` / `behavioural` -> in the test-tools toolchain
    container -- it tests scripts/logic.
- `test/lint/<tool>/` present -> run that linter with its config
  (shellcheck over repo scripts, hadolint over the Dockerfile).
- `--coverage` runs kcov; `--file` / `--filter` narrow the specs.

base (bats unit/integration/behavioural, no app devel-test) runs those in
the toolchain container; a consumer (smoke + a Dockerfile) builds + smokes
in-image. **One dispatcher, the per-tool folders decide.** `just test`
uses the **pinned prebuilt test-tools image** by default and rebuilds it
locally only when missing or explicitly requested, by internally calling
`just docker build --stage test-tools` (no rebuild per run).

### 6. `--help` everywhere; `--lang` for human-facing namespaces only

`just` (1.52) has no native `--lang` and does not pass a flag to a
**namespace** (`just docker --help` / `just docker --lang ja` error -- the
flag is parsed as part of the recipe path, even when the module `default`
takes `*args`). So "`--lang` flag at every level" is not literally
achievable; the mechanism is (verified):

- **recipe** (`just docker build`): `--help` and `--lang <code>` are
  forwarded to the backing script via `{{args}}` and parsed there (the
  docker wrappers already do this).
- **namespace** (`just docker`): help is `just <ns>` (bare invocation runs
  the module `default`, which lists) **or** the explicit `just <ns> help`
  recipe (`just <ns> h` alias) every shipped module now carries (#789). The
  dashed `just <ns> --help` does not work -- a dashed name cannot be a
  recipe/alias, so it is not intercepted; with a `help` recipe present `just`
  emits a `Did you mean 'help'?` hint instead of a bare error.
- **entry** (`just`): `just --list` / a localised overview.
- Language at the namespace/entry level comes from the `SETUP_LANG` /
  `LANG` **env** (which `i18n.sh _resolve_lang` already honours), not a
  flag.

**i18n scope -- "anything human-facing".** Localised strings + `--lang`
apply only to the human-facing namespaces: **`docker`, `base`,
`template`**. **`test` and `release` are English-only** (machine / CI /
automation). Help exists at every level (English baseline) regardless, but
via level-specific forms, not a uniform `--help` flag (#789): recipe help is
`just <ns> <recipe> --help` (forwarded to the backing script); namespace help
is `just <ns>` or the `just <ns> help` recipe (`h` alias) -- the dashed
`just <ns> --help` is a documented `just` dispatch limitation that yields a
`Did you mean 'help'?` hint. Every shipped recipe accepts `-h|--help`; where a
recipe hardcodes its args (e.g. `base update`, which always runs the check) a
small shim forwards `--help` to the backing usage without running the action.

The namespace `default` help and all recipe scripts share **one CLI
runtime lib** -- this is #565's `lib/wrapper.sh` runtime (arg pre-pass,
`--help` rendering, `_resolve_lang`), extended beyond the docker wrappers
to the `test`/`release`/`base`/`template` scripts; its lang/i18n portion
is used only by the human-facing namespaces. **#655 therefore depends on /
shares #565.**

### 7. Opt-in completion installer (no host pollution)

Because the distro `just.fish` lists only top-level recipes and does not
drill into namespaces, base ships `just base completions install [--shell
bash|zsh|fish|all]` and `just base completions uninstall`. It writes the
**dynamic** `clap_complete` loader (not a static snapshot, so it tracks
recipes/namespaces and survives upgrades; `just --completions <shell>`
itself now just emits `eval "$(JUST_COMPLETE=<shell> just)"`). All three
shells share one engine and drill identically -- `just docker::<tab>` ->
`build exec run` (verified); display is each shell's standard (bash plain
list, zsh/fish show recipe descriptions).

Per-shell target (auto-load dir, no rc edit):

- bash: `${XDG_DATA_HOME:-~/.local/share}/bash-completion/completions/just`
- fish: `${XDG_CONFIG_HOME:-~/.config}/fish/completions/just.fish`
- zsh: `~/.local/share/zsh/site-functions/_just`

bash/fish never touch the rc (uninstall removes the file). zsh's
completion must sit in `fpath`; if the target dir is not in `fpath` the
installer **prints** the one line to add it and **never edits `.zshrc`**.
`--shell` defaults to the detected current shell; install/uninstall are
idempotent. README documents this as the prerequisite for namespace tab
completion.

### 8. `init.sh` / `upgrade.sh` leave the root (amends ADR-00000006)

**Done 2026-06-24 (#654).**

`init.sh` and `upgrade.sh` move into the `base` namespace's tooling. Per
§4 the real files live in `dist/script/base/` (the shipped source of
truth) and base-own `script/base/` symlinks into it. They back
`just base init` / `just base upgrade` / `just base update`.

Implementation note: because the scripts no longer sit at the subtree
root, each rewrote its self-location from `dirname $BASH_SOURCE` to a
**walk-up** to the subtree root -- the directory carrying the `.version` +
`dist/` markers. `upgrade.sh` `basename`s that root for the
`git subtree pull --prefix=` flag (resolves to `.base`, NOT the script's
own deep dir `base`); its `_lib.sh` source and the Step-3 `init.sh` call
were repointed to the deep paths in the same slice. An integration test
(`upgrade_spec.bats`) drives a real git-subtree fixture and asserts the
captured `--prefix` is `.base`.

- **Region A** (ADR-00000006/00000010 froze `.base/init.sh` at root) is
  **superseded**: the bootstrap path becomes
  `.base/dist/script/base/init.sh` (a brand-new consumer's documented
  one-time bootstrap command updates accordingly; the wrapper-first rule
  from ADR-00000005 means steady-state users call `just base ...`, not the
  raw script).
- **Regions B/C** keep their ADR-00000010 `dist/` locations.
- `upgrade.sh`'s self-referential and frozen-path constants move in the
  same slice that relocates the script, per ADR-00000006's lockstep
  discipline.

**Amended 2026-06-26 (#719).** The walk-up self-location has a failure mode:
run RAW from inside the base repo itself (`./dist/script/base/init.sh`, not
via a `.base/` subtree), the walk-up resolves base's OWN root as the subtree
root (it carries `.version` + `dist/`), so `REPO_ROOT` becomes base's PARENT
dir and `init.sh` silently scaffolds a repo there. A shared guard
`lib/template_guard.sh` (`_assert_not_template_source`) now refuses when the
resolved subtree root carries `.git`: a vendored `.base/` subtree never does
(the consumer's `.git` lives at the repo root, outside the subtree), but the
base checkout/worktree has `.git` at the subtree root. The discriminator does
NOT hardcode the subtree basename, preserving the rename contract; a
git-remote match (fork/CI/rename-fragile) and a CONTEXT.md sentinel (shipped
into `.base/`, indistinguishable) were rejected. `init.sh` is wired now;
`upgrade.sh` (the symmetric raw-path hole) is tracked in #719's follow-up.

A base-root **convenience bootstrap symlink** (`.base/init.sh` ->
`dist/script/base/init.sh`, to shorten the one-time `./.base/dist/script/base/init.sh`)
was considered and **rejected**: it partially reverts THIS section's
relocation (which removed root-level scripts as "an eyesore" that breaks
the every-action-lives-in-a-namespace rule), the saving is trivial (a
one-time command copy-pasted from the README, not hand-typed), and it makes
accidental in-base self-run easier. The raw bootstrap command stays the deep
path; steady-state stays `just base init`.

## Final command list

```
just                              # list
just docker  build [--stage <s>] | run [-d] | start | exec [-t <svc> -- <cmd>]
             | stop | prune | setup | setup-tui
just test    [--file <f>] [--filter <re>]
just test    lint [--shellcheck [<level>] | --hadolint]
just test    coverage | behavioural
just release [--tag <vX.Y.Z>] [...]
just base    init | update | upgrade [--tag <vX.Y.Z>]
             | completions install [--shell <sh>] | completions uninstall
just template new <name>          # consumer: scaffold a repo-local group
just <group> <recipe>             # consumer repo-local groups
# every level: --help, --lang <code>
```

## Consequences

- **Breaking again for consumers**, on top of ADR-00000010: `just build`
  -> `just docker build`, `just ci` -> `just test`, `just cd` ->
  `just release`, root `init.sh`/`upgrade.sh` -> `just base ...`. The
  fanout slice re-inits every downstream repo; the bootstrap doc path
  changes. Justified: it buys one rule with zero special cases, which is
  cheaper to teach and to extend than the mixed model.
- **Tab completion becomes a documented opt-in step**, not automatic --
  accepted to avoid touching the host shell config without consent.
- **One test runner** removes the base-vs-consumer tooling fork; the cost
  is a content-detecting runner (a branch on what `test/` contains), which
  is deliberately *not* counted as a "special case" because it is one file
  with one interface, not divergent command surfaces.
- Lands as a revision epic of thin slices, each gated by the base
  self-test, superseding the not-yet-fanned-out parts of ADR-00000010's
  epic.

## Alternatives

- **Keep docker top-level for ergonomics.** Rejected: the special case is
  exactly what made the model hard to extend and teach; completion
  recovers most of the ergonomic loss.
- **`lint` as a top-level peer of `test`.** Rejected: lint is a CI check,
  so it belongs under `test`; a top-level peer would re-introduce the
  "which actions are bare" ambiguity and need its own justfile + scripts.
- **Bare positional args (`just test foo.bats`).** Rejected in favour of
  `--file` / `--filter`: explicit options scale uniformly from min to max
  and self-document; positional meaning does not.
- **Separate base-own vs consumer test tooling.** Rejected: the tools are
  identical and only content differs, so a generic runner keeps the whole
  `script/` tree a single symlinked origin (no duplication, no drift).
- **Auto-install completions on `init`.** Rejected: writing to the host
  shell config without explicit consent is host pollution; made an opt-in
  `just base completions install` instead.
