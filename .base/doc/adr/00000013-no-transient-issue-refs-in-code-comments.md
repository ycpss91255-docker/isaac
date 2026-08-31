# Strip transient issue numbers from code comments; keep ADR refs + what/why prose

> Serves: PRD invariant 2 (never fail silently) -- the issue-ref comment
> lint is one of its enforcing guards; mechanism.

- **Date:** 2026-06-24
- **Status:** Accepted
- **Relates to:** the `doc/adr/` references that this convention
  deliberately preserves

## Context

The historical convention threaded inline issue numbers (`#440`,
`#216 / #429`, `#414/#448/#469`, `refs|closes|fixes #N`) into code
comments across `base` -- in `.sh`, `justfile*`, `compose.yaml`,
`Dockerfile*`, and the `#`-comments inside `.bats` setup/helper code.
The #573 review surfaced how pervasive this had become and how little it
buys: an inline `#N` is a frozen pointer to a transient artifact. The
issue gets closed, renumbered across a repo move, or superseded, and the
comment now points at stale context while still costing a reader the
mental "go look that up" tax on every pass.

There is a more reliable traceability chain that does not rot:
`git blame -> commit -> PR -> issue`. blame is recomputed against the
live tree on every read, so it never goes stale the way a hard-coded `#N`
does. The comment's job is to say *what* the code does and *why*; the
*which-ticket* dimension is recoverable from history when (rarely) needed.

ADR references are the opposite case. `ADR-0000xxxx` is durable, curated
rationale that we maintain deliberately; an inline ADR anchor is exactly
what makes future code-tracing cheap, so keeping it offsets the cost this
convention otherwise introduces.

## Decision

Code comments in `base`'s shipped code do **not** carry transient issue
numbers. Specifically, in `.sh`, `justfile*`, `compose.yaml`,
`Dockerfile*`, and the `#`-comments of `.bats` files:

- **Strip** inline transient refs from comment text: bare `#NNN`,
  `(#NNN)`, `refs|closes|fixes #NNN`, marker forms
  (`# -- #216 / #429: auto-build gate --` -> `# -- auto-build gate --`),
  and rationale forms (`# #546: the root user entry ...` ->
  `# the root user entry ...` -- drop the number, keep the sentence).
  Collapse separators / double spaces the removal leaves behind.
- **Keep** `ADR-0000xxxx` references anywhere they appear.
- **Keep** all what/why prose; only the bare issue number goes.

The following are explicitly **not** issue references and are left
untouched:

- `@test "..."` description strings -- these are test identities mirrored
  in `TEST.md`; a `(#NNN)` inside a `@test` name is part of the test's
  name, not a comment, and rewriting it would churn `TEST.md` for no
  gain.
- Functional string literals, registered log-event names, hadolint /
  shellcheck directive codes (`DL3007`, `SC1090` -- not issue refs),
  version tags (`v0.41.0`), and URLs.
- Issue references inside non-comment code (e.g. a `#NNN` inside a
  `printf`/`_log_*` string the program emits at runtime).

A lint driver (`script/test/drivers/issueref.sh`, wired into `just test`
and `just test lint`) enforces this so the refs cannot creep back in.

## Out of scope

Issue references stay in commit messages, PR bodies, `CHANGELOG`,
`doc/adr/` prose (including this ADR), and the gh-artifact-format docs --
those artifacts are *about* the tickets and the references are
intentional there. Downstream repos' own comments are handled separately;
base comments propagate into `.base/` via the subtree and ride along with
the upgrade / fanout.

## Consequences

- Tracing a comment back to its originating ticket now costs one extra
  hop (`git blame` the line -> read the commit / PR -> follow to the
  issue) instead of reading an inline `#N`. This is the accepted
  tradeoff: blame does not go stale, inline numbers do, and the everyday
  reader -- who is reading *what/why*, not *which ticket* -- pays nothing.
- Comments are shorter and read as specifications of behaviour rather
  than as change-logs.
- The `issueref` lint makes the convention enforceable rather than
  aspirational; a reintroduced `#N` in a comment fails `just test`.

## Alternatives considered

- **Keep inline `#N` for traceability.** Rejected: the inline pointer
  rots (close / rename / supersede) while `git blame` does not, so the
  "traceability" it offers is the unreliable half of the pair.
- **Strip everything, including ADR refs.** Rejected: ADR anchors are
  durable curated rationale, not transient tickets; the inline anchor is
  the cheap-tracing affordance worth keeping.
- **Convention without a lint.** Rejected: an unenforced style convention
  silently regresses; the lint is what makes the acceptance criterion
  hold over time.
