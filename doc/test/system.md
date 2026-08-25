# System Tests (opt-in)

System specs under `test/bats/system/`: **12 tests**.

> **Not** part of the `just test` self-test grand total -- these require
> host docker access and are opt-in. See [TEST.md](TEST.md) for the index
> across all test levels.

ISTQB taxonomy (ADR-00000018): the **System** level exercises the whole
built image end-to-end; these specs are the **Regression** type -- they
guard the previously-fixed runtime smoke-gate defects (#249 / #243).
They replace the retired `behavioural` category.

System is base's OWN image / build-gate perspective (technical specs),
distinct from the **Acceptance** level ([acceptance.md](acceptance.md)),
which verifies what the downstream consumer receives (the scaffolded
framework + its `just` UX, UAT/OAT) via the host-driven `acceptance` CI
job. Two adjacent top levels, two vehicles: System = these bats specs on
the `ci-system` compose service; Acceptance = the `acceptance` job.

The System level has a second, CI-only vehicle for the **build-gate
mechanism itself**: the `worker-selftest` job in `self-test.yaml` (#802).
Base only checked its shared reusable worker `build-worker.yaml`
*statically* (actionlint + the structural `build_worker_yaml_spec.bats`
grep); it was never actually *run* in base's own CI, so a semantic break
(an input that became required with no caller passing it, a broken cache
change, a matrix condition that produces no jobs, a removed build step)
surfaced only when a downstream ran the worker in production. The
`worker-selftest` job closes that gap by invoking the worker end-to-end via
a local reusable-workflow call (`uses: ./.github/workflows/build-worker.yaml`)
against a minimal fixture (`test/fixtures/build-worker/Dockerfile` -- a
trivial alpine no-op that builds in seconds; the point is to exercise the
orchestration, not build a real image). Deliberately breaking the worker
turns it red. It is gated on `system_relevant` and joins the `ci-rollup`
aggregator + the `release` gate, so it is required before a tag. The
worker's own extractable logic is pushed further down the pyramid to Unit
level (`build_worker_compute_matrix_spec.bats` / `build_worker_cache_scope_spec.bats`)
and the caller-contract preflight to Acceptance (#800), so this job only
proves the residual orchestration wires together and really builds. This
vehicle is CI-only (a reusable-workflow call runs only on GitHub); its
wiring is locked by `self_test_yaml_spec.bats` and its real execution is the
CI job.

Specs that drive `docker buildx build --target runtime-test` against
synthesized fixtures so the runtime smoke gate in `Dockerfile.example`
is genuinely exercised end-to-end -- not just static-grep asserted
in `template_spec.bats`. Issue #249.

Excluded from the self-test grand total (see [TEST.md](TEST.md)) because they require host
docker access (mounted via the `ci-system` compose service)
which the default `ci` service does NOT provide. Run with `just
test system` locally, or via the dedicated
`System Regression Test` job in `self-test.yaml` on CI. Each test
invokes one `docker buildx build` (~5-15s amd64, ~30-60s arm64
QEMU); the dedicated `template-system` buildx builder
(created/pruned per test.sh run) isolates the cache from the host's
default context.

### Pointing the system suite at another daemon: `SYSTEM_DOCKER_SOCK`

`_system_setup` (`script/test/drivers/bats.sh`) refuses to start unless a
docker socket is there and the docker CLI can reach it. Which socket that
is comes from `SYSTEM_DOCKER_SOCK`, defaulting to `/var/run/docker.sock`
-- the supported way to run this level against an alternate daemon
(a rootless socket under `$XDG_RUNTIME_DIR`, a remote one forwarded to a
local path):

```bash
SYSTEM_DOCKER_SOCK="${XDG_RUNTIME_DIR}/docker.sock" just test system
```

It is also what keeps the two prerequisite-guard specs in `ci_spec.bats`
parallel-safe: one asserts the guard fires when the socket is absent while
the other creates a socket to get past it, and on the single global
`/var/run/docker.sock` those two raced under `bats --jobs`. Each points
the variable at its own `BATS_TEST_TMPDIR` path instead. Production
behaviour with the variable unset is unchanged.

### test/bats/system/runtime_test_smoke_spec.bats (5)

| Test | Description |
|------|-------------|
| `runtime-test build succeeds with default smoke command` | Baseline `whoami && bash --version` ARG default works |
| `runtime-test build succeeds with && chain override (#243 word-split regression)` | Wrapper preserves shell operators |
| `runtime-test build succeeds with bash parameter expansion override (#249 dash-source regression)` | `${var:offset:length}` works (would fail under `sh -c`) |
| `runtime-test build succeeds with bash [[ test operator override (#249)` | `[[` works (sister bash-only regression guard) |
| `runtime-test build FAILS when smoke command exits non-zero (gate-fires assertion)` | Negative case: the gate actually gates |

### test/bats/system/deploy_bundle_e2e_spec.bats (4)

A REAL field deploy end-to-end (ADR-00000023; System level, E2E type).
Generates the bundle for real (`docker build` + `docker save | xz`),
docker-loads the image, runs the generated `deploy.sh up` (real
`docker compose up -d`), asserts the container is Up, then asserts the
tunable-config override applies at the mounted container path (edit the
bundle `config/`, re-up, read it back inside the container), and tears
down with `deploy.sh down`. A tiny alpine `runtime` stage keeps it fast;
the point is the orchestration (build -> save -> load -> compose up ->
mount-wins override -> down), not a heavy image. Needs the `ci-system`
service's docker.sock plus the `docker compose` plugin + `xz` baked into
the test-tools image; auto-skips cleanly when any is absent.

The fixture repo is a real git tree carrying a tag, with a run-unique
basename: the deploy stamp resolves to that tag rather than the `unknown`
fallback (so the version-scoped image identity `<repo>:<stage>-<version>`
is what actually gets built, loaded and asserted), and no container leaked
by a crashed earlier run can share this run's name namespace.

It declares one default-access and one `rw` tunable so the read-only
default (#870) is proven by BEHAVIOUR, not by grepping `:ro` out of the
generated compose: a real `docker exec` write to the default-access mount
must fail with a read-only filesystem error and leave the operator's host
copy untouched, while the declared-`rw` write must succeed and land in the
bundle's `config/`. Every test here drives the one bundle and the one
container name, so the file pins `BATS_NO_PARALLELIZE_WITHIN_FILE` --
concurrent `deploy.sh up` calls would race for that name.

| Test | Description |
|------|-------------|
| `field-deploy e2e: the image identity is version-stamped, not the 'unknown' fallback` | tagged fixture -> real version stamp |
| `field-deploy e2e: the generator produced a self-contained bundle folder` | real bundle output |
| `field-deploy e2e: deploy.sh up loads the image, runs the container, and the tunable override applies` | run + mount-wins override |
| `field-deploy e2e: a container write to an undeclared-rw tunable really FAILS, a declared rw one lands on the host` | read-only default proven by a real write |

### test/bats/system/smoke_harness_spec.bats (3)

The behavioural half of the `just test smoke` harness (see
[smoke.md](smoke.md) for what the harness is and how to run it); the
static half -- COPY-set parity against the shipped `devel-test` stage --
is `test/bats/unit/smoke_harness_spec.bats`.

Every case builds the **real** `dockerfile/Dockerfile.smoke`; only the
build CONTEXT is synthesized, a minimal copy of the paths that Dockerfile
COPYs, so a fixture spec can be dropped in without touching the checkout.
Building a fixture Dockerfile instead would assert against the fixture and
leave the real one unproven -- the shape the harness exists to replace.

`--no-cache` on each build is load-bearing, not caution: these assert on
what the `RUN bats` layer produced, and a CACHED layer produces nothing.
The positive case rebuilds a context identical to the previous run's, so
without it the second invocation reports success having executed no specs
at all.

| Test | Description |
|------|-------------|
| `the smoke harness runs the shipped specs and they pass` | The shipped specs, unmodified, pass in the harness -- and bats reported a plan, so an empty `/smoke_test` cannot pass by doing nothing |
| `the smoke harness runs the specs as a non-root user` | Fixture specs reading `id -u` and attempting a write into `/lint` prove the runtime identity, not just the Dockerfile's `USER` line |
| `the smoke harness build FAILS when a shipped spec fails (gate-fires assertion)` | Negative case: a deliberately failing spec fails the build, so a future `\|\| true` cannot turn the entry point into a report that always says green |
