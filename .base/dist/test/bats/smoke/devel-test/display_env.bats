#!/usr/bin/env bats
#
# Display / host-ACL plumbing, asserted against the wrapper the devel-test
# stage actually installs at /lint/run.sh.
#
# Scope note -- why nothing here reads compose.yaml. The generated
# compose.yaml is a derived artifact listed in `.dockerignore`, so it is not
# in any repo's build context and `/lint/compose.yaml` cannot exist in any
# `-test` stage of any repo. Assertions gated on its presence were therefore
# unreachable everywhere, not merely on a headless CI runner, and read as
# coverage while contributing none. The GUI-block emission they meant to
# protect (WAYLAND_DISPLAY / XDG_RUNTIME_DIR / XAUTHORITY env, the X11 +
# xauth + runtime-dir mounts, and the no-duplicate-service-key structural
# property) is asserted where the emitter can be driven with the GUI
# resolved BOTH on and off: base's own
# test/bats/unit/compose_emit/gen_spec.bats.
#
# What remains is what this stage can genuinely execute: the wrapper's
# xhost host-ACL branch, driven for real via run_wrapper_xhost (shared
# test_helper) rather than re-stated inline and asserted against itself.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  WRAPPER=/lint/run.sh
}

# -------------------- run.sh: xhost host-ACL branch --------------------

@test "run.sh grants the Wayland host ACL to the configured user" {
  run run_wrapper_xhost "${WRAPPER}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_output --partial "+SI:localuser:smokeuser"
  # Two-sided: a swapped branch emits the X11 grant here, and a positive
  # assertion alone cannot tell "also did" from "did instead".
  refute_output --partial "+local:"
}

@test "run.sh grants the X11 host ACL under an X11 session" {
  run run_wrapper_xhost "${WRAPPER}" XDG_SESSION_TYPE=x11
  assert_success
  assert_output --partial "+local:"
  refute_output --partial "+SI:localuser"
}

@test "run.sh defaults to the X11 host ACL when XDG_SESSION_TYPE is unset" {
  run run_wrapper_xhost "${WRAPPER}"
  assert_success
  assert_output --partial "+local:"
  refute_output --partial "+SI:localuser"
}

@test "run.sh grants exactly one host ACL per invocation" {
  # The branch is an either/or. Emitting both grants would leave the X11
  # ACL wide open on a Wayland session while every per-branch assertion
  # above still found its expected line.
  run run_wrapper_xhost "${WRAPPER}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_equal "${#lines[@]}" 1
}

@test "run.sh interpolates USER_NAME into the Wayland ACL, not a fixed name" {
  # `+SI:localuser:` names the host user the container is allowed to
  # impersonate. A hard-coded name would grant the wrong account.
  run run_wrapper_xhost "${WRAPPER}" XDG_SESSION_TYPE=wayland
  assert_success
  assert_output "+SI:localuser:smokeuser"
}
