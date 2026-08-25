# Network mode: keep `host` as the default, ship `bridge` as a usable opt-in

> Serves: PRD invariant 4 (fail-safe defaults) -- established; the
> network host default is the general principle's instance.

- **Date:** 2026-07-07
- **Status:** Accepted
- **Relates to:** issue #794 (this decision, recorded in the issue's
  "Decision update (grilled): keep host as the default" comment), issue
  #466 (privileges / features are opt-in), the follow-up opt-back guidance
  in `ros1_distro#36` / `ros2_distro#35`

## Context

The `[network] mode` scalar in `setup.conf` defaults to `host`. Issue #794
originally proposed **flipping the default to `bridge`** (with `ipc =
private`) on least-privilege grounds: an app / AI-tooling container has no
reason to share the host's network namespace, and bridge is the
docker-idiomatic, more-isolated posture.

Empirical testing (local + a physical-machine run, captured in the issue's
`RESULTS.md`) surfaced two findings that reframed the trade-off:

- **Local GUI under bridge breaks X11 auth.** On a pure-Xorg host the X11
  MIT-MAGIC-COOKIE is keyed to the host's hostname. Under bridge the
  container is assigned a random hostname, so `libX11` looks the cookie up
  under the wrong name and authentication fails. Pinning the container's
  hostname to the host's name (`--hostname=<host>` / compose `hostname:`)
  fixes it reliably (verified on Wayland and simulated Xorg).
- **Cross-machine ROS under bridge fails, unfixably.** For BOTH ROS 1 and
  ROS 2, cross-machine discovery / transport fails under bridge and stays
  broken even with the hostname fix, because the container sits on the
  `172.17.x` docker network, which is **not routable off the box**. There
  is no in-container knob that makes a bridge address reachable from
  another machine. Multi-machine robots MUST keep `host`.

The decisive factor is **risk asymmetry**, not which posture is "cleaner":

- Guessing the default wrong toward `host` on a single-machine app
  container costs only a layer of defence-in-depth. It is a dev container
  the user controls; the loss is bounded and non-catastrophic.
- Guessing the default wrong toward `bridge` on a cross-machine ROS robot
  makes a safety scanner / LiDAR **silently unreachable across machines,
  with CI still green**. The failure is silent, catastrophic, and
  safety-relevant.

The org is also ROS-plurality, so a generic default serves the majority
best by staying `host`.

## Decision

**Reverse the flip. Keep `host` as the default and make `bridge` a usable
opt-in instead.**

1. **Nothing is flipped.** The seeded `setup.conf` stays `network.mode =
   host` / `network.ipc = host`, and the code-level key-absent fallbacks
   (`deploy.sh` resolved-config, `compose_emit.sh` context defaults and the
   `generate_compose_yaml` positional defaults) also stay `host`. Template
   and code agree.
2. **Make the opt-in usable, not a trap.** When the GUI is enabled AND
   `network.mode = bridge`, the compose emitter injects `hostname: <host>`
   on the service (shared `_emit_hostname_line` helper, gated on effective
   `gui == true && net == bridge`, resolved from `HOSTNAME` with a `uname
   -n` fallback and threaded to both the devel service and every per-stage
   standalone block). Under `host` networking or with the GUI off, nothing
   is injected.
3. **Document the opt-in with a hard warning.** README "Network mode"
   subsection + a `setup.conf [network]` header note carry the recipe
   (`setup.sh set network.mode bridge && setup.sh set network.ipc private
   && setup.sh apply`) and state plainly that cross-machine ROS must stay
   `host`. A commented `port_1 = 8080:80` example is seeded, since ports
   only take effect under bridge.

## Alternatives considered

- **Flip the default to `bridge` (the original #794 proposal).** Rejected:
  under the risk asymmetry above, the default must fail safe toward the
  catastrophic case. Flipping globally and hoping every ROS repo remembers
  to opt back re-introduces exactly the silent-failure mode the default is
  meant to prevent.
- **Flip only for non-ROS templates.** Rejected as fragile: "is this repo
  cross-machine ROS?" is not reliably knowable at template-default time,
  and the classification would drift. Least-privilege for confirmed
  single-machine repos is better delivered by an explicit, documented
  opt-in the repo owner makes deliberately.
- **Ship bridge opt-in without the hostname pin.** Rejected: a bridge
  opt-in that silently breaks local GUI is a broken trap. The pin is what
  makes the opt-in actually usable.

## Consequences

- The default posture is unchanged, so every existing downstream repo and
  the ROS-plurality majority are unaffected — no fan-out migration, no
  silent breakage.
- Single-machine app / AI-tooling repos get a documented, one-command path
  to a more isolated bridge posture, with local GUI preserved.
- The compose emitter carries a small GUI+bridge-conditional branch in both
  emit paths (devel + per-stage), covered by `hostname_spec.bats` and the
  updated `#505` golden master.
- **Deferred acceptance items (need physical display hardware):** verifying
  that a GUI window actually *renders* under bridge (not just that X11 auth
  succeeds), the real `just run` GUI path end-to-end, and the `--hostname`
  side-effect on ROS node naming. These are `RESULTS.md` gaps that a CI /
  headless environment cannot close.
