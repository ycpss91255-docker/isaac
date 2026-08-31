# Per-start container log files + stable symlink + shared rotate/prune helper

> Serves: PRD invariant 1 (base owns the single-service lifecycle) --
> per-start container logs (#805) realise it; mechanism.

- **Date:** 2026-07-07
- **Status:** Accepted
- **Relates to:** issue #805 (this decision), ADR-00000007 (wrapper
  transcript, the glog-style precedent this reuses), the `[logging]
  local_path` feature (#310 / #328 / #368), and the #797 watchdog design
  discussion that raised the need for a durable, bounded on-disk log.

## Context

The `[logging] local_path` container-log tee (`runtime/logging.sh`) wrote a
single file per service (`/var/log/<repo>/<svc>.log`) and TRUNCATED it on
each container start (`: > $LOG_FILE_PATH`). Two footguns: within one run
the file grows unbounded, and on restart the previous run's log is wiped.

The wrapper transcript (`lib/transcript.sh`, ADR-00000007) already solved
exactly this shape well: a per-run timestamped real file plus a stable
`latest.log` symlink pointing at the newest, with config-driven keep/days
pruning that skips the symlink. This ADR records applying that same
glog-style design to the container-log tee, and extracting the shared
mechanism so the two producers do not carry parallel implementations.

## Decision

1. **Per-start real file + stable symlink.** On each container start the
   tee writes a per-start real file `log/<svc>/<svc>_<ts>.log` and repoints
   a stable symlink `log/<svc>/<svc>.log` (= the emitted `LOG_FILE_PATH`)
   at it. `tail <svc>.log` always follows the current run; earlier runs
   stay on disk. This replaces truncate-on-restart, so run history is
   retained instead of wiped. `docker logs` parity is unchanged (the tee
   still echoes to the daemon's stdout).

2. **Configurable retention.** Two new `[logging]` keys,
   `container_log_keep` (default 20) and `container_log_days` (default 14),
   registered in `schema.sh` and validated as positive integers, exactly
   mirroring `wrapper_transcript_keep` / `wrapper_transcript_days`. Old
   per-start files are pruned by keep-count AND age (stricter wins), never
   the symlink. A non-positive hand-edit clamps back to the default so
   prune can never wipe every log.

3. **One shared helper (DRY).** The "repoint the stable symlink + prune old
   per-start files by keep/days, skipping the symlink" logic is extracted
   into `runtime/logrotate.sh` (`_logrotate_repoint` + `_logrotate_prune`),
   parameterized on symlink name / dir / keep / days. Both producers use
   it: `transcript.sh`'s `_transcript_prune` and its `latest.log` repoint
   now delegate to it (its symlink stays `latest.log`), and the
   container-log tee calls it with `<svc>.log`.

## Consequences / trade-offs

- **Placement across two execution contexts.** `transcript.sh` runs
  host-side (`lib/`); `logging.sh` runs in-image (`runtime/`, sourced from
  `/usr/local/lib/base/`). They share no source graph. The shared helper
  therefore lives under `runtime/` and is COPY'd into the image alongside
  `logging.sh`; the host lib sources it via the sibling `../runtime/` path.
  Both source it DEFENSIVELY (readable-check + `declare -F` guards) so the
  shellcheck `/lint` image stage, which flattens `lib/` without a `runtime/`
  sibling, degrades gracefully instead of aborting under `set -e`.

- **Retention crosses the container boundary via env.** The prune runs
  in-container (co-located with the tee, so it also covers auto-restarts),
  but the retention values live in the host-side `setup.conf`. `compose_emit`
  reads `container_log_keep` / `container_log_days` from the conf layer and
  emits them as `CONTAINER_LOG_KEEP` / `CONTAINER_LOG_DAYS` env alongside
  `LOG_FILE_PATH`; `logging.sh` reads the env with the same fallback +
  clamp. This mirrors how `LOG_FILE_PATH` itself already crosses the
  boundary, at the cost of baking the values into `compose.yaml` at setup
  time (a re-`setup` re-reads them, same as every other emitted value).

- **Downstream propagation.** A downstream Dockerfile that COPYs
  `logging.sh` but predates the split needs the `logrotate.sh` sibling COPY,
  or the tee degrades to no rotation/prune. A `logrotate_copy`
  `dockerfile_migrate` migration adds the sibling COPY on `just upgrade`.

- **Same-second collision guard.** The per-start filename is second-granular
  (`<svc>_<ts>.log`). Two starts in the same wall-clock second (a crash-loop
  restart with sub-second backoff) would otherwise resolve to the same path
  and the second would truncate the first -- the exact footgun this issue
  removes. `logging.sh` guards it by probing a `-<n>` suffix when the
  timestamped name is already taken, so each start keeps its own file (the
  disambiguator the transcript gets from its `<ts>-<traceid8>` shape).

- **Prune is symlink-safe, but keep is pooled (known limitation).** Both
  prune passes exclude symlinks (`find -type f` in the age pass, an `-h`
  test in the count pass), so neither the caller's own stable symlink nor a
  sibling service's `<other>.log` symlink sharing `/var/log/<repo>/` is ever
  deleted -- symlink safety does not depend on the symlink's name. However,
  both passes glob every `*.log` real file in the dir, so the `keep` / `days`
  caps are POOLED across services when multiple services tee into one dir,
  not per-service. Under the one-service-per-repo model this is rare and is
  left out of scope here; revisit if a repo runs many services into the
  same log dir.

## Scope note

This issue changes only HOW container logs are stored (per-start + symlink
+ retention). Whether `local_path` should default ON is a SEPARATE decision
and stays out of scope here: the default remains opt-in (empty). With the
unbounded-growth footgun removed, that default can be revisited later.
