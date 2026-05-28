# CI Architecture: Split Hosted + Self-Hosted by Test Bucket

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

Two registrations on the maintainer's GPU machine:

1. **`ycpss91255-docker` org-level runner** — covers all repos in that org (`isaac`, `seggpt`, `base`, future repos)
2. **`ycpss91255/isaac` repo-level runner** — required because `ycpss91255` is a *user account*, not an org; user accounts have no org-wide scope

Same machine, two `actions-runner` services. Both labeled `gpu` so workflows can target the right pool with `runs-on: [self-hosted, gpu]`.

If `ycpss91255` ever needs a second GPU-test repo, transfer that repo to `ycpss91255-docker` org instead of adding a third runner registration.

## Public repo security

All three repos (`ycpss91255/isaac`, `ycpss91255-docker/isaac`, `ycpss91255-docker/base`) are **public**. Self-hosted runners on public repos are a documented attack surface (fork + malicious PR can execute arbitrary code on the runner).

**Required settings per repo:**

```
Settings -> Actions -> General -> "Approval for outside collaborators": All outside collaborators
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
- **`ycpss91255` user account requires per-repo runner registration** as a tax — every new user-account repo that needs GPU CI adds a runner service to the maintainer's machine. The escape hatch is transferring those repos to `ycpss91255-docker` org.
- **Reusable workflow deferred** -- when a third repo (beyond the workspace + docker env) needs GPU CI, extract a `python-gpu-test-worker.yaml` reusable into `ycpss91255-docker/base` following the existing `build-worker.yaml` pattern.

## Cross-references

- **ADR-0006**: Per-sensor-type YAML camera config -- the kind of code these tests verify
- **ADR-0009**: IsaacDriver base class lifecycle pattern -- target of future integration tests
- **ADR-0010**: Isaac Dev Kit 4-layer standardized development environment -- introduces the tests that drove this decision
- **ycpss91255-docker/isaac#59**: `pytest + pyyaml + pytest-cov` added to `devel-test` Dockerfile stage -- prerequisite for running pytest in container
- **ycpss91255-docker/base** existing reusable workflow pattern (`build-worker.yaml`, `release-worker.yaml`) -- template for future reusable extraction
