# Acceptance Tests (CI-only)

Acceptance specs under `test/bats/acceptance/`: **0 tests**.

> **Acceptance** ISTQB level (ADR-00000018). It verifies what the
> downstream **consumer** receives -- the scaffolded framework and its UX
> (the `just` commands, help, completion, and the generated layout) from
> the consumer's chair (UAT + OAT). This is distinct from the **System**
> level ([system.md](system.md)), which exercises base's OWN image
> lifecycle + build gate.

## Where the Acceptance level lives

Unlike the other levels, base's Acceptance checks are **not** bats specs
in this directory -- they are the host-driven `acceptance` job in
[`.github/workflows/self-test.yaml`](../../.github/workflows/self-test.yaml)
(formerly `integration-e2e`). A faithful acceptance test must drive the
**real delivered artifact**: a downstream repo scaffolded by `init.sh`
(the consumer's `.base/` subtree + symlink chain + generated
`compose.yaml` / `.env`), a real built image, and the real `just` binary
consumers invoke. That cannot be reproduced inside the mounted-`/source`
bats sandbox the unit / integration levels run in, so the level is
realized in CI where those preconditions exist. `test/bats/acceptance/`
therefore stays an intentional empty placeholder (`.gitkeep`, count 0)
and is **not** part of the `just test` self-test grand total (see
[TEST.md](TEST.md)); it keeps the level x type grid visible in the tree.

## What the `acceptance` job verifies (consumer's chair)

The job runs as a native-runner matrix (amd64 + arm64) and, after
`init.sh` scaffolds a synthesized consumer repo, drives the delivered UX
end-to-end with REAL execution (not `--dry-run`), asserting a real effect
each time:

- **Container lifecycle** -- `just docker build [test]` -> `just docker
  run -d` -> `just docker exec` -> `just docker stop`, asserting the
  runnability contract (configured user, container still running, wired
  `/entrypoint.sh`, writable `~/work`, full teardown of container +
  project network). Issues #579 / #603.
- **Remaining container-ops verbs** -- the foreground `run` variant with
  #386 auto-cleanup, `just docker start` (build + run), a real `just
  docker prune --networks`, `just docker setup apply` (regenerates
  `.env.generated` + `compose.yaml`). Issue #769.
- **Base-management verbs** -- `just base update` (version verdict) and
  `just base completions install / uninstall` (round-trip). Issue #769.
- **Repo-local scaffolding** -- `just template new <name>` scaffolds a
  command group at `script/local/<name>/`, registers it, and the group is
  then dispatchable (`just --list <name>` resolves it and `just <name>
  hello` runs the generated recipe). Issue #785.

## System vs Acceptance (why the split)

| | System ([system.md](system.md)) | Acceptance (this doc) |
|---|---|---|
| Perspective | base's own image / build gate (technical) | what the consumer receives (user/operator) |
| Verifies against | technical specs | UAT + OAT expectations |
| Vehicle | `test/bats/system/` bats specs via the `ci-system` compose service (host docker.sock) | the `acceptance` CI job (scaffolded consumer + built image + real `just`) |
| Example | `runtime-test` buildx smoke-gate-fires regression | `just template new` produces a dispatchable consumer command group |

## Intentionally NOT covered here

- **`just docker setup-tui`** -- the interactive setup TUI is
  **intentionally unit-only** (covered by `tui_spec.bats` and the
  `tui_*` unit specs). Driving it for real needs a pseudo-TTY (it reads
  interactive keystrokes and repaints the terminal), which the headless
  CI runner cannot supply; a scripted `setup-tui` drive would exercise a
  fake input path, not the real UX. Its absence from the acceptance job
  is a recorded decision (this note + #769 / #785), not a silent gap. The
  non-interactive `just docker setup apply` path -- which shares the same
  emitters -- IS driven for real in the acceptance job above.
