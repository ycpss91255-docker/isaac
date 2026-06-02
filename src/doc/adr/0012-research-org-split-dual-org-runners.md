# Research Org Split and Dual Org-Level Self-Hosted Runners

ADR-0011 placed all GPU CI under `ycpss91255-docker` and required `ycpss91255/isaac` to register a repo-level runner as a tax for living on a user account, with an escape hatch: "transfer user-account repos into `ycpss91255-docker` org". Two issues block that escape hatch:

1. **Semantic mismatch.** The suffix `-docker` denotes container environment repos (Dockerfile + `base` subtree consumers used as runtime images). Workspace code (`ycpss91255/isaac`), backend libraries (`seggpt` Layer 1/2/3), and ROS 2 packages (`sam_manager`) are application source, not container envs. Forcing them into `-docker` makes the org name lie.
2. **Name collision.** `ycpss91255/isaac` (workspace) and `ycpss91255-docker/isaac` (container env) both exist. Direct transfer is not possible without renaming one, and either rename has a non-trivial cross-reference cost.

**Decision**: Create a new org `ycpss91255-research` for actual code repos. Keep `ycpss91255-docker` for pure container env / template subtree source. Run two org-level self-hosted runners on the maintainer's GPU machine, one registered against each org. No user-account or repo-level runners.

## Considered Options

- **(a) Stick with ADR-0011 escape hatch** -- transfer `ycpss91255/isaac` into `ycpss91255-docker`. Rejected: name collision with existing `ycpss91255-docker/isaac` forces renaming the container env repo (or the workspace), and either rename pollutes the semantics permanently (workspace named `isaac-workspace`, or container env named `isaac-env` while still owning the `isaac` subtree URL).
- **(b) Accept the per-repo runner tax** -- keep `ycpss91255/isaac` on user account, register a repo-level runner. Rejected: every future user-account repo with GPU CI adds another runner service. Tax compounds.
- **(c) Single new org holding everything** -- create one new org and migrate workspace + backend + ROS 2 repos there alongside future product repos. Rejected: same-org sprawl ends up where `-docker` is today (mixed semantics).
- **(d) Split by semantics: `-docker` for container env, `-research` for code** (**chosen**) -- explicit boundary by repo nature. Two org-level runners, no per-repo runner tax, future repos route to whichever org matches their nature.

## Repo classification

| Org | Members (current + planned) | Criterion |
|---|---|---|
| `ycpss91255-docker` | `base` (template subtree source), `isaac` (Isaac Sim container env), `github_runner` (host-side runner provisioning) | Container env / template / **host environment provisioning** |
| `ycpss91255-research` (new) | `isaac` (workspace, migrated from `ycpss91255/isaac`), `seggpt` (migrated from `-docker/seggpt`), `sam_manager` (migrated from `-docker/sam_manager`) | Application source, backend library code, ROS 2 packages |

**Boundary refinement (post-original-decision)**: The original cut said "`-docker` = container env only; ops tooling lives in `-research`". During implementation it became clear that `github_runner` (the host-side bash tooling that provisions runners) is more naturally an *environment* concern than a *code* concern -- it sits next to `base` and `isaac` env conceptually. The refined boundary: **`-docker` = anything that provisions or describes the host / container environment** (Dockerfiles, base templates, runner setup); **`-research` = application source consumed by that environment**. `github_runner` therefore lives in `-docker`. Canary placement (verification of runner liveness) is still under design; see Tooling section below.

## Migration phasing

- **Phase 1 (this ADR's issue)**: create `-research` org, set gates, register both runners via the new `ycpss91255-docker/github_runner` tooling, migrate `ycpss91255/isaac` -> `ycpss91255-research/isaac`. Drop `ycpss91255/isaac` runner plan from ADR-0011.
- **Phase 2 (later, separate issue)**: migrate `seggpt` and `sam_manager` from `-docker` to `-research`. Phase 2 has higher cross-ref cost (GHCR image tags do not auto-redirect across orgs; harness `coreSAM_ws/CLAUDE.md` and base subtree consumers reference these URLs). Defer until Phase 1 settles.

## Runner topology

- 2 org-level runners on the maintainer's GPU machine
- Labels: `gpu` only. `isaac-sim` label deferred until GPU machines diverge (single-machine setup makes capability labels moot -- both runners share the same hardware, so workflow-side `isaac-sim` requirement adds no routing)
- Org boundary itself differentiates job routing today: workflows in `-research` repos land on `-research` runner, workflows in `-docker` repos land on `-docker` runner. Per-org runner is GitHub's native isolation
- Naming convention: `<hostname>-<org>-org`, e.g., `<hostname>-ycpss91255-research-org`
- Runner directory layout: `~/github_runner/<org>/_org/` (two-layer, `_org` placeholder reserves the level for future per-repo runners if a single repo ever needs distinct GPU profile)

## Security gate

All three scopes set to "Require approval for all outside collaborators":

1. `ycpss91255` user account (`https://github.com/ycpss91255/settings/actions`) -- residual until all user-account repos drained
2. `ycpss91255-docker` org (`https://github.com/organizations/ycpss91255-docker/settings/actions`)
3. `ycpss91255-research` org (`https://github.com/organizations/ycpss91255-research/settings/actions`)

Setup ordering matters: set the gate **before** registering the runner, otherwise there is a window where outside collaborator PRs with prior contribution history can auto-trigger workflows on the freshly registered runner. See [issue #45] for the executable checklist.

## Tooling: `ycpss91255-docker/github_runner`

A standalone repo (renamed from `runner-setup` during implementation, relocated from `-research` to `-docker` per the boundary refinement above) containing 5 shell scripts plus a shared library:

| Script | Responsibility |
|---|---|
| `init.sh` | One-shot bootstrap on a new host: verify prerequisites (`docker`, `nvidia-smi`, docker GPU runtime, `gh auth`), create `~/github_runner/{.bin}`, cache the runner tarball |
| `add-runner.sh` | Register a new runner: `add-runner.sh org <org>` or `add-runner.sh repo <owner> <repo>`. Idempotent. Uses `gh api ... registration-token` so user only needs `gh auth` with `admin:org` scope, no manual token paste |
| `remove-runner.sh` | Deregister + `svc.sh uninstall` + remove directory. Idempotent |
| `status.sh` | List all registered runners across all configured orgs with their GitHub-side online state via `gh api /orgs/<org>/actions/runners` |
| `update.sh` | Pull a newer runner binary into `.bin/`, stop services, overwrite binary in each runner directory without touching `.runner` / `.credentials`, restart services |

Scripts are linted in CI on hosted runners (no chicken-and-egg: `github_runner` itself does not require a self-hosted runner to validate).

## Canary verification

Each org gets a dedicated `canary` repo containing a minimal `workflow_dispatch` workflow targeting `runs-on: [self-hosted, gpu]`. Canaries are independent so retiring one org's runner does not require touching the other org. Verification SOP:

1. After registering each runner, run `gh workflow run canary.yaml -R <org>/canary`
2. Check the job picks up within 30 seconds and runs `nvidia-smi`, `docker --version`, `hostname`, `whoami`
3. Independently: open a fork PR from a secondary account against `<org>/canary` -- workflow must show "Approval required" and not auto-run; manually approve and confirm it runs after approval

`gh api .../actions/runners` showing "Idle" is necessary but not sufficient -- a runner can appear Idle while the systemd service environment lacks docker group membership or has a broken PATH. Canary actually exercises the path.

## Consequences

- **No more user-account runners.** ADR-0011 §Self-hosted "two registrations" topology (1 org + 1 repo-level) is superseded. Phase 1 completes when `ycpss91255/isaac` is empty of GPU-required workflows
- **`ycpss91255-docker` semantics restored.** After Phase 2, `-docker` contains only `base` and `isaac` container env. Future container env repos route here unambiguously
- **Org boundary as routing.** Removes the need for capability labels in single-machine setups. When second machine is introduced (e.g., a non-Isaac ML training rig), labels (`isaac-sim`, `cuda12`, etc.) can be added incrementally without re-registering existing runners
- **Phase 2 deferred.** `seggpt` and `sam_manager` keep their current URLs until a later issue justifies the GHCR republish + harness ref grep
- **`github_runner` repo becomes the rebuild SOP.** Machine loss / reformat means cloning `ycpss91255-docker/github_runner` and running `./init.sh && ./add-runner.sh org ycpss91255-docker && ./add-runner.sh org ycpss91255-research`. No undocumented machine state. `init.sh` is prep-only (prereq check + tarball cache); `add-runner.sh` is the per-target registration step

## Cross-references

- **ADR-0011 §Self-hosted runner** -- superseded for the `ycpss91255` user account path; the 1-org + 1-repo registration scheme is replaced with 2-org-level
- **ADR-0011 §Consequences "transfer those repos to `ycpss91255-docker` org"** -- superseded; escape hatch is now "transfer to the semantically correct org, may require creating one"
- **ADR-0011 §Public repo security** -- still applies, but extended to the third scope (`ycpss91255-research` org). The 4-repo `gh api .../actions/permissions/access` loop in issue #45 also extends to repos that land in `-research` post-migration
- **issue #45** -- executable checklist driven by this ADR (revised to include org creation, gate-before-runner ordering, `runner-setup` repo bootstrap, canary repo creation)
