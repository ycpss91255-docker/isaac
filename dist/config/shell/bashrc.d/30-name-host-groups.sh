# Name the host-injected supplementary GIDs so interactive shells stop
# printing "groups: cannot find name for group ID N".
#
# compose `group_add:` injects numeric, host-specific GIDs (e.g. the
# host's render / video group for /dev/dri) so the non-root container
# user can reach those device nodes. Those GIDs have no NAME inside the
# container image, so every interactive shell -- `just run` (entrypoint
# then bashrc) AND `just exec` (compose exec then bashrc, bypassing the
# entrypoint) -- emits a cosmetic getgrgid warning. Device access
# already works (membership is by GID); only the label is missing. Give
# each nameless GID a placeholder `hostgrp<gid>` via passwordless sudo.
# This deliberately does NOT touch the compose `group_add` device-access
# behaviour -- it only adds names.
#
# Lives in bashrc.d/ (not the entrypoint) so `just exec`, which bypasses
# the entrypoint, fixes the label too.
name_host_groups() {
  command -v getent >/dev/null 2>&1 || return 0
  command -v sudo >/dev/null 2>&1 || return 0

  local _g
  for _g in $(id -G 2>/dev/null); do
    # Idempotent: skip GIDs that already resolve to a name (a
    # hostgrp<gid> created on a previous shell resolves here too).
    getent group "${_g}" >/dev/null 2>&1 && continue
    sudo groupadd -g "${_g}" "hostgrp${_g}" >/dev/null 2>&1 || true
  done
}

# Interactive shells only -- no point churning groups for scripts. The
# guard lives at the call site (not inside the function) so the function
# stays directly callable from unit tests. An `if` block (not `&&`) so a
# non-interactive source does not return non-zero under `set -e`.
if [[ $- == *i* ]]; then
  name_host_groups
fi
