# Cache TTY-ness at startup so a transcript tee cannot re-flip single-sink dispatch

> Serves: mechanism -- wrapper log/transcript single-sink fidelity; no
> invariant.

- **Date:** 2026-06-18
- **Status:** Accepted

## Context

#438 made `log.sh` single-sink: one rendering per record, format chosen
by a live `test -t <fd>` in `_log_dispatch`'s auto branch (text on a TTY,
JSON when piped / redirected), with the same live probe gating colour in
`_log_color_enabled`.

#606 adds a wrapper transcript: a non-interactive verb's combined
stdout + stderr is tee'd to a plaintext log file under
`log/<verb>/<ts>-<traceid8>.log`. A tee inserts a pipe on fd1, so any log
call made *after* the tee is wired sees `test -t 1` = false and silently
flips the live terminal to JSON / no-colour mid-run -- the exact
regression this ADR prevents. The run's real interactivity is known once,
at startup, *before* the tee is layered.

## Decision

Resolve TTY-ness once at startup into `_LOG_IS_TTY` (a shell return code:
`0` = the run is interactive, non-zero = not) and have `log.sh` read it
via `_log_is_tty <fd>`. The auto-format branch and `_log_color_enabled`
consult `_log_is_tty` instead of probing the fd live. When `_LOG_IS_TTY`
is unset, `_log_is_tty` falls back to live `test -t <fd>` -- so sourcing
`log.sh` standalone (ci.sh, a bare `source`) is byte-identical to
pre-#605.

#605 ships only the read + fallback; #606 is the producer that sets
`_LOG_IS_TTY` before tee-ing. Explicit `LOG_FORMAT=text|json` still
short-circuits and never consults the cache.

## Layering: transcript tee over single-sink

The transcript is layered *above* single-sink, not a replacement.
Single-sink still decides format / stream from the cached startup
TTY-ness; the tee then duplicates whatever bytes single-sink emits into
the file. Because the format decision is frozen before the tee exists, an
interactive run keeps coloured text on the terminal *and* in the
transcript; a piped run keeps JSON on both. The transcript never triggers
a second render.

## Best-effort mixed format under LOG_FORMAT=json

If the operator forces `LOG_FORMAT=json` on an interactive run, the
terminal and the transcript both receive JSON (single render, no
dual-emit). We deliberately do **not** dual-render (human text to the
terminal, JSON to the file): that would double every log call, fork the
byte-stream the wrapper-dispatch specs pin, and re-introduce the
format-decision-per-sink coupling #438 removed. The transcript is
therefore a faithful copy of the single chosen rendering -- best-effort,
not a format-translating sink. (The transcript file can still end up
mixed-format in practice because it also captures raw docker child-process
output, which `log.sh` does not render; that is inherent to capturing a
child's stdout and is out of scope for dual-render to "fix".)

## Alternatives considered

- **Keep live `test -t` and special-case the tee.** Rejected: every
  future fd1 consumer (pagers, output captures) would re-hit the flip.
  The bug is the live probe, not the tee.
- **Dual-render text + JSON.** Rejected as above (byte-stream fork +
  double cost + re-coupling the per-sink format decision).
- **Snapshot the format string instead of TTY-ness.** Rejected: TTY-ness
  is the single root input both format and colour derive from; caching it
  keeps one source of truth and leaves explicit `LOG_FORMAT` overrides
  untouched.

## Consequences

- A producer that wants stable format / colour across a tee must set
  `_LOG_IS_TTY` *before* redirecting fd1 (#606 does this in the wrapper
  preamble).
- `_LOG_IS_TTY` is a return code (`0` / non-zero), **not** a `0|1` boolean
  string nor `true|false`: `_log_is_tty` does `return "${_LOG_IS_TTY}"`,
  so the producer must set it via `test -t 1; _LOG_IS_TTY=$?`. Documented
  at the helper and here because it is the single most likely integration
  mistake.
- Standalone `log.sh` users are unaffected (unset -> live fallback).
- Complements #438: #438 made format a per-run decision; this ADR makes
  that decision survive output-stream rewrapping.
