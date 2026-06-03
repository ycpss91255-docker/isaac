# CI Architecture: Split Hosted + Self-Hosted by Test Bucket

> **Note (2026-05-28)**: Runner topology (§Self-hosted) and the `ycpss91255` user-account tax item in §Consequences are revised per [ADR-0012](./0012-research-org-split-dual-org-runners.md). Current state is reflected inline below; ADR-0012 carries the rationale for the change (semantic split between `-docker` container-env org and `-research` code org).

ADR-0010 introduces a 4-layer Isaac Dev Kit with Python tests (unit + smoke + integration). Isaac Sim requires NVIDIA GPU at runtime (Kit's CUDA/Vulkan init refuses to start without it), and GitHub-hosted runners do not provide a GPU. Existing `ci.yaml` only validates Python syntax via `py-compile`; pytest is never run in CI. We need a strategy that runs every test type in CI without paying for GPU hosted runners.

**Decision**: Split tests into 4 buckets and route each to a different runner type. Use GitHub-hosted runners (free) for `Unit` and `Lint`, and a self-hosted runner on the maintainer's GPU machine for `Smoke` and `Integration`. Gate self-hosted execution on public PRs with the "All outside collaborators" approval setting.

## Considered Options

- **(a) GitHub-hosted only** — pull Isaac Sim image (~15 GB) on `ubuntu-latest` with `jlumbroso/free-disk-space@main`. Rejected: Isaac Sim Kit refuses to boot without an NVIDIA GPU runtime (CUDA / Vulkan / NGX init fail hard). Smoke tests would never execute.
- **(b) Pre-commit hook locally only** — `.pre-commit-config.yaml` runs smoke before push, no CI gate. Rejected: developer can `--no-verify` to bypass; merging maintainer cannot verify another contributor actually ran it; no audit trail in GitHub UI.
- **(c) Self-hosted runner for everything** — register one runner, route all jobs there. Rejected: wastes maintainer's machine for trivial Python lint that runs in <30s on hosted runners; runner uptime becomes a hard dependency for every PR.
- **(d) Split hosted + self-hosted by bucket** (**chosen**) — Unit and Lint on hosted runners (always available, free); Smoke and Integration on self-hosted runner (only path to GPU). Reusable workflow extraction deferred until a third consumer repo needs it (Rule of Three).

## Test bucket classification

| Bucket | Examples | Where | Why |
|---|---|---|---|
| **Unit** | 74 host-runnable pytest tests across `import_model`, `material_setup`, `sensor_setup`, `scene_builder` | GitHub-hosted (`ubuntu-latest`) | Pure Python + `pytest` + `pyyaml`. ~30 s wall time. Zero Isaac Sim dependency. |
| **Lint** | actionlint, shellcheck, py-compile, ruff (future), mypy (future), 4-language README sync | GitHub-hosted (`ubuntu-latest`) | Static analysis, no runtime. Existing `ci.yaml` already covers most of this. |
| **Smoke** | `script/sensor_smoke_test.py`, `script/material_smoke_test.py`, `script/scene_smoke_test.py` -- Kit boots, prim created, Action Graph built | Self-hosted runner (GPU) | Kit `SimulationApp({"headless": True})` requires CUDA + Vulkan. ~10 min per test. |
| **Integration** | Per-layer integration tests (#35), end-to-end model pipeline test (#36), future RTX LiDAR ray-casting + camera rendering | Self-hosted runner (GPU) | Full physics + sensor publishing. ~15-30 min per test. |

## Runner setup

### GitHub-hosted (Unit + Lint)

Standard `runs-on: ubuntu-latest`. Existing `ci.yaml` extended with a `unit-test` job that pulls `pytest` + `pyyaml` from PyPI (no Isaac Sim image needed).

### Self-hosted (Smoke + Integration)

Two **org-level** registrations on the maintainer's GPU machine, one per org:

1. **`ycpss91255-docker` org-level runner** — covers `base`, `isaac` (container env), and future container-env repos
2. **`ycpss91255-research` org-level runner** — covers `isaac` (workspace, migrated from `ycpss91255/isaac`), `runner-setup`, `canary`, and Phase-2 backend / ROS 2 repos

Same machine, two `actions-runner` services. Both labeled `gpu`. Org boundary itself routes jobs: workflows in `-research` repos pick up the `-research` runner; workflows in `-docker` repos pick up the `-docker` runner. Capability labels (e.g., `isaac-sim`, `cuda12`) are deferred until GPU machines diverge (see ADR-0012).

Future GPU-test repos go into whichever org matches their nature (container env → `-docker`; application source → `-research`). No additional runner registration needed unless a single repo requires a distinct GPU profile, in which case it can register a repo-level runner under `~/github_runner/<owner>/<repo>/`.

Registration is automated via the `ycpss91255-docker/github_runner` repo (see ADR-0012). Rebuild SOP after machine loss: `git clone runner-setup && ./init.sh && ./add-runner.sh org ycpss91255-docker && ./add-runner.sh org ycpss91255-research`.

## Public repo security

All workspace + container-env repos are **public**. Self-hosted runners on public repos are a documented attack surface (fork + malicious PR can execute arbitrary code on the runner). Per ADR-0012, the repo set spans two orgs:

| Org | Repos |
|---|---|
| `ycpss91255-research` | `isaac` (migrated from `ycpss91255/isaac`), `runner-setup`, `canary`, Phase-2 `seggpt` / `sam_manager` |
| `ycpss91255-docker` | `base`, `isaac` (container env), `canary` |

**Required settings:**

Approval gate is set at the **org / user-account level**, not per repo:

- `ycpss91255-research` org: Settings → Actions → General → "Require approval for all outside collaborators"
- `ycpss91255-docker` org: same
- `ycpss91255` user account: same (residual until all user-account repos are drained)

Per-repo `main` branch protection:

```
Settings -> Branches -> main protection:
  - Require pull request before merging
  - Require status checks to pass: [unit-test, lint, smoke-test]
  - Allow specified actors to bypass: maintainer
```

This blocks workflow execution on outside PRs until the maintainer clicks "Approve and run". The maintainer's own PRs (commits authored by repo owner) auto-trigger.

## Workflow file layout

Per-bucket separation, no reusable workflows yet (Rule of Three -- defer cross-repo reusable until the third consumer):

```
.github/workflows/
├── ci.yaml            # existing: actionlint + shellcheck + py-compile + readme-sync (hosted)
├── unit-test.yaml     # new: pytest test/unit/ (hosted)
└── smoke-test.yaml    # new: pytest test/smoke/ inside Isaac Sim container (self-hosted, gpu)
```

`ycpss91255-docker/isaac` follows the same layout but adds Python tests alongside the existing bats smoke tests in the `devel-test` Dockerfile stage.

## Auto-merge for maintainer PRs

Maintainer PRs use `gh pr merge --auto --squash` (after `unit-test` + `lint` + `smoke-test` pass). External PRs require maintainer review + manual approval of workflow runs.

## Consequences

- **Maintainer's machine must be online to merge non-trivial PRs** (self-hosted runner picks up the smoke job). Acceptable for solo-maintainer workflow; revisit if uptime becomes a bottleneck.
- **GHA minutes are free for self-hosted jobs** (don't count against quota). Public repo hosted-runner minutes are also unlimited. Total CI cost: $0 + electricity.
- **PR security tradeoff is explicit**: outside collaborator approval gate is mandatory for self-hosted to be safe on public repos. Documented in repo settings, not just in code.
- **Semantic org split routes jobs without capability labels** (per ADR-0012). `-docker` org hosts container-env / template repos; `-research` org hosts workspace / backend / ROS 2 code. Both run their own org-level runner on the maintainer's machine. New GPU-CI repos pick the org that matches their nature; no per-repo or user-account runner needed.
- **Reusable workflow deferred** -- when a third repo (beyond the workspace + docker env) needs GPU CI, extract a `python-gpu-test-worker.yaml` reusable into `ycpss91255-docker/base` following the existing `build-worker.yaml` pattern.

## Cross-references

- **ADR-0012**: Research org split + dual org-level runners -- supersedes the runner topology (§Self-hosted) and the user-account tax item (§Consequences) of this ADR
- **ADR-0006**: Per-sensor-type YAML camera config -- the kind of code these tests verify
- **ADR-0009**: IsaacDriver base class lifecycle pattern -- target of future integration tests
- **ADR-0010**: Isaac Dev Kit 4-layer standardized development environment -- introduces the tests that drove this decision
- **ycpss91255-docker/isaac#59**: `pytest + pyyaml + pytest-cov` added to `devel-test` Dockerfile stage -- prerequisite for running pytest in container
- **ycpss91255-docker/base** existing reusable workflow pattern (`build-worker.yaml`, `release-worker.yaml`) -- template for future reusable extraction

## Update (2026-06-02) -- single-repo collapse after research/isaac merge

`ycpss91255-research/isaac` was merged into `ycpss91255-docker/isaac` per `ycpss91255-docker/isaac#78` (org-axis realignment: `-docker/*` is generic env, `-research/*` is application-specific; the workspace material here was always standardized env work). The 4-bucket decision in §Decision still stands; what changes is the implementation footprint now that there is one repo instead of two.

### Repo set (revised)

| Org | Repos |
|---|---|
| `ycpss91255-research` | `runner-setup`, `canary`, Phase-2 `seggpt` / `sam_manager` (no longer hosts `isaac`) |
| `ycpss91255-docker` | `base`, `isaac` (env + workspace, merged), `ros1_bridge` (relocation pending per `ycpss91255-docker/ros1_bridge#136`), `canary` |

The org-level runner topology (two registrations, one per org, both labeled `gpu`) is unchanged. `-research` runners stay registered because other repos in that org still need them.

### Workflow file layout (revised)

`ycpss91255-research/isaac` previously split lint and unit tests across `ci.yaml` + `unit-test.yaml`, while `ycpss91255-docker/isaac` already used a single `main.yaml` with multiple jobs. Post-merge the consolidated repo follows the single-file pattern:

```
.github/workflows/
└── main.yaml             # all 4 buckets as separate jobs
    ├── lint              # actionlint + shellcheck + py-compile + readme-sync (hosted)
    ├── unit-test         # pytest test/unit/pytest/ (hosted)
    ├── call-docker-build # Dockerfile build + bats RUN /smoke_test/ (hosted via base reusable)
    └── python-tests      # pytest test/integration/pytest/ inside devel-test (self-hosted GPU)
```

The 4-bucket allocation (Unit, Lint, Smoke, Integration) maps to jobs of one workflow, not separate workflow files. Job-level `runs-on` (hosted vs self-hosted) carries the bucket routing; the original §Test bucket classification table still applies verbatim, only the file column needs reinterpretation as job-name.

Research's two workflow files arrived under `src/.github_research_legacy/` via the filter-repo path-callback (GitHub only fires `.github/workflows/` at repo root, so they are inert there). Fold-into-`.github/workflows/main.yaml` plus drop of the legacy directory is tracked as `#85` (a follow-up to `#78`) -- it requires adjusting the research's `readme-sync` check (`doc/readme/` prefix -> `doc/` here) and merging its lint job set into the existing `main.yaml`, which is non-trivial enough to ship separately.

### Cross-references added

- **ycpss91255-docker/isaac#78**: research/isaac merge -- the trigger for this Update
- **ycpss91255-docker/isaac#85**: the follow-up issue that executes the workflow fold + un-defers python-tests described above
- **ycpss91255-docker/ros1_bridge#136**: parallel org-axis realignment (relocation in the other direction)
