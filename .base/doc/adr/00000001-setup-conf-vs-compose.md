# Responsibility split between setup.conf and compose-native mechanisms

- **Date:** 2026-05-28
- **Status:** Accepted

## Context

`base` uses `setup.conf` + `setup.sh` to generate `compose.yaml` and
`.env`. This abstraction layer is not the Docker standard -- the
standard approach is to hand-maintain `compose.yaml` plus `.env`,
using `compose.override.yaml` (or `-f overlay.yaml`) for environment
overrides and profiles for variant selection.

setup.conf exists because it provides things plain compose cannot:
system detection (IMAGE_NAME rules, USER_NAME, WS_PATH, GPU, GUI),
TUI editing with input validation, multi-language defaults, and
template-to-repo section-level inheritance.

The question of "what belongs in setup.conf vs. what should go
through compose-native mechanisms" was never written down. It
surfaced concretely while designing per-instance isolation for the
isaac downstream repo (multiple Isaac Sim instances each needing
their own ports and cache directory). Two opposing options emerged:
add the instance-overlay mechanism to setup.conf via section-level
overlay, or use compose-native override yaml (`_compose_project
-f compose.yaml -f config/instances/<name>.yaml`). The first would
require changing setup.conf's existing section-replace semantics to
key-level merge; the second is a per-repo customization that not
every downstream needs.

## Decision

**setup.conf is the main path -- it covers all common / standard
needs. Compose-native mechanisms (`compose.override.yaml` /
`-f overlay.yaml` / profiles) are an escape hatch reserved for
genuinely custom needs.**

setup.conf extension principles:

1. If the need is "common functionality that multiple downstream
   repos will use" -- add it to setup.conf (new section or key),
   have setup.sh emit it into `compose.yaml` / `.env`, and wire up
   TUI editing with input validation.
2. If the need requires system detection (IMAGE_NAME rules,
   USER_NAME, WS_PATH, GPU, GUI, etc. -- things compose.yaml syntax
   alone cannot express) -- it must go through setup.conf.
3. The existing "template-to-repo" section-level inheritance is
   preserved; downstream repos' override expectations stay intact.

When to use compose-native mechanisms (escape hatch):

1. The customization is limited to a single repo or single
   scenario, and pushing it into setup.conf would dilute the
   abstraction's generality -- e.g. isaac's per-instance cache and
   port isolation (an Isaac-Sim-specific problem).
2. Pure runtime value injection that does not affect static
   configuration -- e.g. `--env-file <overlay>.env` injecting
   additional environment variables.
3. Structural overrides that benefit from compose's native
   deep-merge -- write `compose.override.yaml` (compose loads it
   automatically) or a custom overlay yaml used with `-f
   overlay.yaml`.

Decision rule: when asked "should base support this?", first
evaluate generality -- "would N downstream repos use it?". Yes
to N>=2 -> setup.conf. Only one repo -> escape hatch.

## Alternatives

- **Fully align with the Docker standard (drop setup.conf)** --
  loses auto-detection, TUI, and multi-language defaults. Users
  would have to hand-write compose.yaml with placeholders like
  `${USER_NAME}-${IMAGE_NAME}`, breaking the "downstream repo
  works out of the box" core value proposition.
- **Push every overlay mechanism into setup.conf** -- e.g.
  implement per-instance via setup.conf section overlay. Requires
  changing section-replace to key-level merge, re-emitting a
  per-instance compose.yaml, and forces base to handle
  single-repo customization cases. Violates the generality
  principle.
- **Pre-emptively bake every possible need into setup.conf** --
  violates YAGNI; setup.conf bloats into a do-everything mega
  abstraction, and the TUI grows accordingly complex.

## Consequences

- New-feature decision rule: evaluate generality first (do
  multiple downstreams need this?). Common -> full implementation
  in setup.conf; single-repo customization -> compose-native
  mechanism.
- isaac's per-instance isolation is single-repo customization
  (Isaac Sim's cache-lock issue is product-specific). It will be
  implemented via compose override yaml, without extending
  setup.conf's merge semantics.
- setup.conf keeps section-replace semantics. No change to
  key-level merge.
- If the same kind of customization appears in 3+ repos later,
  re-evaluate -- it may graduate into setup.conf.
- Downstream repos can still write `compose.override.yaml` for
  local ad-hoc tweaks (compose auto-loads it); no need to detour
  through setup.conf.
