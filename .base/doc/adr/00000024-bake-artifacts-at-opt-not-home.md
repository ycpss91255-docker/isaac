# Bake self-built artifacts at absolute `/opt`, not under `$HOME`

> Serves: PRD invariant 8 (dev/field separation, provisioned by opposite
> means) -- mechanism; also invariant 2 (never fail silently), through the
> `home-literal` lint that gates its mechanical half.

- **Date:** 2026-08-03
- **Status:** Accepted
- **Relates to:** issue #799 (this decision), issue
  `realsense_ros2#97` (the design that surfaced it: build librealsense +
  realsense-ros from source and choose where the SDK and the colcon overlay
  land), ADR-00000023 (field deploy: the image travels, the build host does
  not)

## Context

The template bakes the container user at **build** time. The `sys` stage
takes the `USER_NAME` / `USER_UID` / `USER_GID` build args (injected by
compose and by CI), creates that user, and the `devel` stage then sets

```dockerfile
ENV HOME="/home/${USER_NAME}"
```

So `$HOME` inside the image is not a deploy-time property; it is frozen to
whichever `USER_NAME` the build received. `just build` injects the local
host's user. CI and the release path bake `user` (UID 1000). Two images
built from the same commit can therefore have two different `$HOME` values.

That makes any artifact baked **under `$HOME`** -- a self-built workspace at
`~/some_ws`, an SDK, a compiled tool -- coupled to the build-time username.
The coupling only bites at deploy time, which is exactly where it is
hardest to see:

- A consumer runs a **prebuilt / GHCR / `docker save`+`load`** image baked
  as `user:1000` on a host whose user differs, or rebuilds with a different
  `USER_NAME`. Every path that goes through the home directory -- a
  Dockerfile `COPY` destination, entrypoint sourcing, a bashrc line --
  now points at a **different, empty** `/home/<other>/...`. The baked
  workspace is invisible and `source ~/some_ws/install/setup.bash` fails.
- A single **hardcoded literal** home path is worse: it does not even track
  `USER_NAME`, so it breaks the moment the build arg changes. This repo has
  already hit the neighbouring class of bug ("image `HOME` != compose
  mount", healed by the `ARG USER` migration in `lib/dockerfile_migrate.sh`).

Content baked at an **absolute, username-agnostic** path (`/opt/...`) is
immune to all three -- username change, UID mismatch, tar load -- because
there is no `$HOME` indirection left to resolve. This is also what the
ecosystem already does: `/opt/ros/<distro>` is where every upstream ROS
image puts its install tree, and nothing sources it through a home
directory.

The decision was forced by `realsense_ros2#97`, which had to choose where a
self-built librealsense plus a colcon overlay live. It generalises: it is a
property of how the template bakes users, not of that repo.

## Decision

**Images bake self-built artifacts at absolute `/opt/<name>` paths.
`$HOME` is reserved for dotfiles and convenience symlinks.**

1. **Artifacts at `/opt`.** Self-built workspaces, SDKs and compiled tools
   install at absolute `/opt/<name>`. Nothing whose survival matters is
   baked under `$HOME`.
2. **Sourcing names the absolute path.** The entrypoint / bashrc sources
   `/opt/<name>/...`, never `~` or `$HOME`. A per-user
   `~/<name> -> /opt/<name>` symlink created in the per-user `RUN` block is
   *encouraged* for interactive discoverability -- it is the only
   user-coupled bit and is cheap to recreate -- but it must never be the
   path anything **sources**.
3. **No concrete username in a path.** Where a home path is genuinely
   needed, it uses `${HOME}` / `${USER_NAME}` so it tracks the build arg.

Rule 3 is mechanical, so it is **gated**: `script/test/drivers/home_literal.sh`
(`just test lint --home-literal`, CI job `lint-static (home-literal)`) fails
on a concrete username in a home path anywhere under `dist/` or
`dockerfile/` -- the trees that reach an image. A narrative mention (the
`dockerfile_migrate.sh` note that must name the *wrong* home directory in
order to explain the mismatch it heals) opts out through an explicit,
region-delimited allowlist, not a file exclusion, so a new literal in the
same file is still caught.

Rules 1 and 2 are **judgement**, not a mechanical property: whether a given
artifact belongs under `/opt` cannot be decided by a grep, and the lint does
not pretend otherwise. They are carried where a downstream author meets them
-- the commentary in the shipped `dist/dockerfile/Dockerfile`, which
`init.sh` seeds as every repo's own `Dockerfile` -- plus the README section
for readers who never open the Dockerfile, and this record for the why.

## Consequences

- **Deploy-robust by construction.** A `docker save` / `load` or a GHCR
  pull onto a machine with a different user keeps working: nothing the image
  needs is behind a username.
- **The build-arg user stays a dev-ergonomics knob**, which is all it was
  ever for (matching host UID so bind-mounted files are writable). It stops
  being load-bearing for image content.
- **Two paths for the same thing.** `/opt/some_ws` and `~/some_ws` both
  exist, and a reader has to know the symlink is for humans while the
  absolute path is for machines. That is the accepted cost of rule 2; the
  alternative (no symlink) trades an interactive convenience the team
  actually uses for one less concept.
- **Downstream repos need a fanout**, not just base. base ships no
  self-built artifact of its own -- the audit found zero live violations in
  its shipped tree -- so the convention lands here as guidance plus a lint
  over base's own tree. Repos that bake a workspace (starting with
  `realsense_ros2`, and any repo with a `~/*_ws` build) adopt it in their
  own Dockerfile / entrypoint, and pick up the lint automatically as they
  upgrade the `.base` subtree.
- **The lint sees only what `.base` carries.** A downstream literal in the
  repo's OWN `Dockerfile` / `script/entrypoint.sh` is outside the scanned
  trees. Extending the scan to a consumer's root is a separate decision
  (it needs the lint to run from a downstream `just test`, which base does
  not own today); until then rule 3 is enforced in base and reviewed
  downstream.
