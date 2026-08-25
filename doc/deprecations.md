# Deprecations

Items kept for backward compatibility behind a permanent alias / shim,
scheduled for removal at the next major version (**v1.0.0**). This is the
W3 strategy: rather than a short N-release deprecation window (which a
downstream that upgrades infrequently would skip straight past, breaking
on the removal), the legacy form is kept working indefinitely and a
deprecation warning nudges migration. **Grep this file before cutting
v1.0.0** and remove every entry's legacy path.

| Deprecated | Replacement | Since | Remove at | Ref |
|---|---|---|---|---|
| `[deploy] runtime` | `[deploy] gpu_runtime` | v0.41.0 | v1.0.0 | #481 |

## `[deploy] runtime` -> `[deploy] gpu_runtime`

- **Deprecated:** v0.41.0 (#481)
- **Why:** `runtime` was an overloaded word in `setup.conf` (file preamble
  "runtime configuration", `[environment]` "runtime env vars", and this
  GPU-runtime key). Renaming to `gpu_runtime` puts it in the GPU family
  (`gpu_mode` / `gpu_count` / `gpu_capabilities` / `gpu_runtime`) and
  removes the collision.
- **Alias behaviour:** `setup.sh` reads `gpu_runtime` first; if absent but
  `[deploy] runtime` is present, it consumes the legacy value and emits a
  `_log_warn` deprecation. The `.env` variable name stays `RUNTIME`
  (downstream back-compat). `gpu_runtime` wins when both are present.
- **Action at removal (v1.0.0):** drop the legacy-key fallback branch in
  `setup.sh`'s deploy resolution, drop `deploy.runtime` from
  `_validate_stage_override_key`, drop the per-stage `deploy.runtime`
  fallback resolve, and drop the `_setup_msg_deploy runtime_deprecated`
  message. Downstream `setup.conf` still carrying `runtime` will then error
  -- the v1.0.0 downstream-upgrade workflow must rewrite the key first.
