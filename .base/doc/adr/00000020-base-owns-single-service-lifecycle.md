# `base` container is one service; `base` owns the common single-service lifecycle

> Serves: PRD invariant 1 (base owns the single-service lifecycle) --
> established; also PRD invariant 5 (the two-branch default rule).

- **Date:** 2026-07-07
- **Status:** Accepted
- **Amended:** 2026-08-03 -- the restart policy is scoped to *deployable*
  stages only; `devel` and `*-test` never carry one, and its default flips
  to ON (`unless-stopped`). See "Lifecycle capabilities are not uniform
  across stages" below.
- **Relates to:** issues #478 (restart policy), #792 (init / PID1
  reaping), #797 (generic watchdog / supervised restart), #805 (durable
  log persistence), and ADR-00000019 (network host default + usable
  bridge opt-in) as a sibling lifecycle-defaults decision

## Context

`base`'s container model is **"one container = one service"**: a
`base`-built image runs a single service. This is the foundational axiom
every downstream repo inherits — a downstream is a `base` image plus one
app, not an orchestration of several co-tenant processes.

Several capabilities that every single-service container needs have been
surfacing as separate issues, each initially framed as a per-repo
concern:

- **restart policy** (#478) — what Docker should do when the one service
  exits.
- **init / PID1 reaping** (#792) — a proper init as PID 1 so signals are
  forwarded and zombie children are reaped.
- **generic watchdog / supervised restart** (#797) — detect that the
  service is unhealthy and take a restart action.
- **durable log persistence** (#805) — the one service's logs survive
  container recreation.

These are not app features; they are properties of *running a single
service in a container well*. The recurring question was whether
consolidating them into `base` is premature abstraction, given that the
first concrete consumer of any given capability is often a single repo.

This premise was explicitly grilled. The conclusion: because the
one-service model is `base`'s axiom, the **common single-service
lifecycle is exactly what `base` exists to own**. Wrapping the
one-service-container model for downstream *is* `base`'s purpose;
providing these capabilities is fulfilling that purpose, not speculative
generalisation — even when the first concrete consumer is a single repo.
The alternative (each downstream re-implements restart / init / watchdog
/ log persistence) is the actual anti-pattern: N divergent, partially
correct copies of a concern that is identical across the fleet.

## Decision

**Adopt as a design axiom: a `base` container is one service, and `base`
owns the common single-service lifecycle capabilities that every
downstream needs.** New lifecycle capabilities of the one-service model
land in `base` by default, exposed as configuration, rather than being
pushed down to individual repos.

The lifecycle umbrella currently comprises restart policy (#478), init /
PID1 reaping (#792), the generic watchdog / supervised restart (#797),
and durable log persistence (#805). ADR-00000019 (network host default,
usable bridge opt-in) is a sibling decision in the same
lifecycle-defaults family.

This ADR records the *axiom and ownership rationale*. The concrete
mechanism for each capability is specified in its own issue (the
watchdog's design lives in #797, not here).

### Lifecycle capabilities are not uniform across stages (amendment, 2026-08-03)

The umbrella above treats the lifecycle as a property of "the one
service". That holds for init, the watchdog, and log persistence, but
**not** for the restart policy: whether a stopped container should come
back depends on whether the container is a *service* or a *session*.

A `devel` container is a session. Its life *is* the interactive shell, so
a restart policy means typing `exit` immediately relaunches it — there is
no way to leave. A `*-test` stage is likewise designed to exit, and an
exit-0 stage inheriting devel's policy is precisely the restart loop
#493 hit. A deployable stage and a field bundle are the opposite: they
run a service that is meant never to stop, so coming back — after a
crash, and after a host reboot — is exactly right.

Decision:

- **The restart policy applies only to deployable stages and the field
  bundle.** `devel` and any `*-test` stage never emit one. The previous
  mechanism (emit on `devel`, let `extends: devel` stages inherit) is
  removed; qualifying stage services emit it themselves.
- **"Deployable" is not a second definition.** It binds to the existing
  rule in ADR-00000023 sec.4 (`deployable = not devel and not *-test`),
  hoisted into a single shared predicate so there is one place to change.
- **The default flips from `no` to `unless-stopped`**, and is shipped
  literally in the template so it is visible rather than implicit. Once
  the key no longer straddles dev and field, the two consumers no longer
  want opposite defaults, so no absent-vs-explicit distinction is needed:
  an explicit value is honoured verbatim wherever the key applies.

This refines, and does not contradict, the "default ON only where absence
is a footgun" rule in Consequences: after the rescope, every context the
key still reaches is one where a container that fails to come back *is*
the footgun.

Note that the ownership axiom is unchanged — `base` still owns the
restart policy. What changed is the recognition that a lifecycle
capability can be stage-scoped, which is the first case where the
umbrella needed qualifying.

## Alternatives considered

- **Push each capability down to the consuming downstream repo.**
  Rejected: the one-service lifecycle is identical across the fleet, so
  per-repo implementations produce N divergent, partially correct copies
  and drift. Ownership in `base` is the point of `base`.
- **Defer consolidation until there are multiple consumers ("rule of
  three").** Rejected here specifically because the shared substrate is
  `base`'s stated purpose, not an incidental commonality discovered
  across unrelated call sites. The grill accepted that "first consumer
  is one repo" does not make this premature — the abstraction boundary
  is the one-service model itself, which is already universal.
- **Bake fixed lifecycle behavior into `base` (non-configurable).**
  Rejected: it would change behavior for every existing downstream
  unconditionally and remove Docker-native escape hatches. Configuration
  with a principled default (see the default-rule consequence below) is
  the middle path: safe defaults where absence is a footgun, opt-in where
  semantics could change.

## Consequences

- **Every lifecycle capability is exposed as configuration, and its
  DEFAULT is the safest correct behavior for a well-run single-service
  container — decided by a principled two-branch rule, not per-capability
  taste:**
  1. **When enabling the capability is transparent to a correct workload
     AND running without it is a footgun, the default is ON.** Concrete
     instance: init / PID1 reaping (#792) defaults **ON**. With the app
     running as PID 1 there is no zombie reaping and no signal
     forwarding, so `stop` can hang until `SIGKILL` and orphaned children
     accumulate — "app as PID 1" is itself the latent bug. `init: true`
     is transparent to a correct single process and fixes both, so it is
     the safe default even though it is a (beneficial, low-risk) behavior
     change on the next compose regeneration.
  2. **When enabling the capability could change a workload's semantics,
     the default is OFF / the Docker-native no-op, and enabling is
     opt-in.** Concrete instances: network / ipc mode (ADR-00000019, host
     default), the watchdog's restart-service action (#797, restart the
     whole container is the default), and the restart policy (#478).

  The double condition — *transparent to correct workloads* AND *absence
  is a footgun* — is what prevents an "everything defaults ON" slippery
  slope: an unset knob is a no-op only where the capability is genuinely
  optional; where its absence is a latent bug, the default fixes it. New
  lifecycle features are documented in the README.
- **Where a capability has a non-trivial failure action, the action is
  itself configurable, with the Docker-native option as the default, so
  the simple case pays no complexity.** Concretely for the watchdog
  (#797): the default action is to restart the whole container (the
  Docker-native behavior), and restarting only the in-container service
  is an opt-in.
- **`base` owns the mechanism; app-specific policy is plugged in.** For
  the watchdog, the health-check command and the notify command are
  pluggable and supplied by the app / operator; `base` provides the
  supervision loop, not the app's definition of "healthy".
- Downstream repos get correct single-service lifecycle behavior for
  free as `base` gains each capability, via the normal `.base` subtree
  upgrade — no per-repo re-implementation.
- This ADR is a rationale record and changes no behavior on its own; the
  behavior arrives with each capability's own issue and PR.
