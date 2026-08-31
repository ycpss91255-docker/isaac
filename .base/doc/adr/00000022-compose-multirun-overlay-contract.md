# base<->multi_run compose contract: per-instance isolation is an overlay, enforced by a guard

> Serves: PRD invariant 3 (multi_run-expandable by construction) --
> established by the overlay contract + guard; also invariant 2 (a loud
> self-check).

- **Date:** 2026-07-08
- **Status:** Accepted
- **Relates to:** issue #716 (this decision), issue #25 (multi_run),
  ADR-00000001 (setup.conf is the main path, compose-native mechanisms are
  the escape hatch), ADR-00000003 (environment vs workload parameter
  boundary; the `.env` overlay + `env_file:` channel), ADR-00000019
  (network host default / bridge opt-in, the `ports` / `hostname` fields),
  ADR-00000020 (base owns the single-service lifecycle). Enforced by
  `test/bats/unit/compose_emit/overlay_guard_spec.bats`.

## Context

`multi_run` (issue #25) runs the same base-generated stack in three
scenarios: (1) one repo / many instances, (2) many repos / one instance,
(3) many repos / many instances. `docker compose` has **no native
instance axis** -- it models project, service, and `replicas`, but not
"the same service run N times with per-instance parameters". So any field
that must vary per instance, if base emits it into the generated
`compose.yaml` as a **hardcoded literal**, becomes a wall: two co-located
instances collide on host ports / writable paths / DDS domain, and
`multi_run` cannot isolate them without a retroactive change to base's
emitter.

The core mechanism -- "per-instance isolation = a `.env` overlay" -- was
already decided in the v0.42 docker-namespace epic. What was missing was
(a) an explicit resolution of the fields ADR-00000003 left in the axis-A
grey zone (`ports` / `network_mode`: machine-bound *environment* or
per-task *workload*?), and (b) any guarantee that a future emitter change
would not silently bake a fresh per-instance literal and re-erect the
wall. Discipline is not a guarantee; the v0.41 Dockerfile drift and the
#800 worker-contract gaps are the same failure class -- a latent blocker
that stays green until someone downstream hits it.

## Decision

### 1. Per-instance isolation is a `.env` overlay, never a compose regenerate

An instance is isolated by supplying **overlay values**, not by
regenerating `compose.yaml`. `compose.yaml` stays a single committed-shape
artifact; the per-instance delta lives entirely in overlay inputs
`multi_run` controls. This preserves ADR-00000003's two-role split:
`.env.generated` feeds compose `${VAR}` interpolation via `--env-file`,
and `.env` feeds the container via `env_file:`.

### 2. Environment-default / per-instance-overridable (the axis-A resolution)

Every field that can vary per instance is emitted as an
**overlay-overridable interpolation** (`${VAR:-<default>}` or `${VAR}`),
never a hardcoded literal. The default may stay machine-bound (resolved
from `setup.conf` as before), but an overlay-override path **always
exists**. A field is thus simultaneously an environment default (single
run: the overlay var is unset, compose substitutes the default, behaviour
is byte-equivalent) and per-instance-overridable (multi_run: the overlay
sets the var). This is the explicit resolution of the ADR-00000003 axis-A
grey zone for `ports` / `network_mode` and the rest: they are *both*, and
the interpolation form is what lets one emission serve both roles.

### 3. Override channel by field kind

The audit is a **starting point, not an exhaustive allowlist** -- ANY
field that can collide across instances must have an override path. The
channel differs by kind:

| Field kind | Per-instance override channel | Emitted form |
|---|---|---|
| project `name:` | compose interpolation from `--env-file` | `${PROJECT_NAME}` (was `${DOCKER_HUB_USER}-${IMAGE_NAME}`; see the 2026-08-05 amendment below) |
| `container_name:` | interpolated **and** removable (non-load-bearing, see §4) | `${USER_NAME}-<repo>[-<svc>]` |
| `network_mode:` | compose interpolation | `${NETWORK_MODE}` |
| `privileged` / `ipc` / `pid` | compose interpolation | `${PRIVILEGED}` / `${IPC_MODE}` / `${PID_MODE}` |
| **`ports:`** | compose interpolation, **per published port** | `${PORT_<n>:-<default>}` (n = **1-based** index within the service's port list -- `PORT_1` = first port, matching base's 1-based indexed-key convention `port_1` / `mount_1` / `arg_1`) |
| workload env (`ROS_DOMAIN_ID`, tokens) | `.env` overlay via `env_file:` + baked ENV default (ADR-00000003 S3) | `- "KEY=value"` default; overlay wins in the field image |
| writable volume topology | compose-merge overlay (a mount is a topology decision, not a flat scalar) | bind/named mount string |
| `runtime` / `hostname` / GPU | **not per-instance** -- host-bound, correctly *shared* across co-located instances (all instances on a host share the runtime, the X11-cookie hostname, and the GPU) | literal / host-resolved |

**Amendment (2026-08-05, ADR-00000025): the project `name:` row's emitted
form, and the stage this ADR does NOT cover.** The row above is unchanged in
substance -- project `name:` is still an interpolation from `--env-file`, and
multi_run still overrides it by setting that variable in its runtime overlay.
What changed is *which* variable: the emitter used to re-assemble
`${DOCKER_HUB_USER}-${IMAGE_NAME}` while the wrapper computed the same string
in bash, two answerers to one question, and both now read the single
`PROJECT_NAME` that `setup apply` resolves into `.env.generated`. The
interpolation form -- the thing this ADR's forward invariant and its guard
actually pin -- is preserved deliberately: emitting the resolved literal would
have been simpler and would have re-erected the wall.

ADR-00000025 also adds a per-worktree `.setup.conf.local` config layer, and it
is worth being explicit that it is **not** this contract's mechanism, because
the resemblance invites the mistake. That layer acts BEFORE `compose.yaml` is
generated and yields one `compose.yaml` per worktree; per-instance isolation
here acts at interpolation time on ONE already-generated `compose.yaml`, which
is precisely why sec. 1 rejects a per-instance regenerate. A developer's
second worktree and multi_run's Nth instance are different stages of the
pipeline, and neither mechanism can do the other's job. ADR-00000025 sec. 5
carries the full division of labour.

The concrete change this decision required was `ports`: they were baked
literals and are now `${PORT_<n>:-<default>}`, `n` 1-based per the
convention above (a human who configured `[network] port_1` overrides
`PORT_1`, not `PORT_0` -- the off-by-one would be a footgun). The other
interpolation-
channel fields (`name` / `container_name` / `network_mode` / `ipc` /
`privileged` / `pid`) were already compliant; the guard locks them.

### 4. Contract `multi_run` depends on (held, verified)

- `compose.yaml` resolves via `docker compose --env-file .env.generated
  config` -- interpolation defaults keep it resolvable with no overlay.
- `container_name` is **removable** without breaking the service: no
  service references it, and the top-level project `name:` namespaces the
  container, so `multi_run` may drop it entirely to let compose auto-name
  `<project>-<service>-<n>` per instance.
- Stage / service identity is **not tied to the literal name `devel`**:
  each service carries `build.target: <stage>`, `image: .../<stage>`, and
  `profiles: [<stage>]`, so `multi_run` extracts the stage stage-
  agnostically from `build.target` rather than matching the string
  `devel`.

### 5. Forward invariant + guard (the core deliverable)

**Forward invariant:** base's compose emission never emits a hardcoded
per-instance literal over the interpolation-channel field set. base-
generated stacks are multi_run-expandable *by construction*.

**Guard:** `overlay_guard_spec.bats` emits a compose that exercises the
per-instance fields and asserts each is an overlay interpolation, never a
baked literal -- and its predicate self-check proves it *discriminates* a
baked literal from a `${VAR:-default}` interpolation, so it fails
immediately if a future change hardcodes a per-instance field. This turns
"multi_run will not be blocked later" from a hope maintained by discipline
into a machine-enforced guarantee, caught in base's own CI rather than
discovered when multi_run tries to expand -- the same self-validation
spirit as the #800 worker preflight.

## Alternatives

- **Regenerate `compose.yaml` per instance.** Rejected: makes the
  committed artifact per-instance, defeats the single-shape contract, and
  re-flips `SETUP_CONF_HASH` on every instance (ADR-00000003's exact
  anti-goal for workload params).
- **A `compose.override.yaml` merge for every per-instance field.**
  Native and powerful, but forces hand-written compose per instance for
  scalars a flat `${VAR}` handles cleanly; kept as the channel only for
  volume *topology*, where a mount genuinely is structured (ADR-00000001's
  escape-hatch positioning).
- **Convert `runtime` / `hostname` to interpolations too.** Rejected as
  incorrect: they are host-bound and *should* be shared across co-located
  instances (a per-instance hostname would break the local X11 cookie all
  instances share; a per-instance runtime is meaningless on one host).
  Recording them as "shared, not per-instance" is the audit result, not an
  omission.

## Consequences

- `multi_run` can isolate an instance by supplying overlay `${PORT_<n>}` /
  `${NETWORK_MODE}` values (interpolation) and a per-instance `.env`
  (env_file), with no base change and no compose regenerate.
- A future emitter change that bakes a per-instance literal fails
  `overlay_guard_spec.bats` in base's own CI.
- `ports` emission changed shape (now `${PORT_<n>:-<default>}`); downstream
  repos pick it up on their next `just setup` regenerate, with identical
  resolved behaviour (the `:-` default reproduces the prior literal).
- The `#505` golden master and `gen_spec` port assertions were updated to
  the interpolation form; no runtime behaviour changed.
