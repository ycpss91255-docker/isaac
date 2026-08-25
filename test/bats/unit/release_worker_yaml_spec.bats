#!/usr/bin/env bats
#
# release_worker_yaml_spec.bats — structural assertions for the
# `.github/workflows/release-worker.yaml` reusable workflow's archive
# step.
#
# The seven user-facing wrappers were moved out of the repo root into
# `script/` (symlinks into `.base/dist/script/docker/wrapper/`); `init.sh`
# no longer creates root-level `build.sh` / `run.sh` / `exec.sh` /
# `stop.sh` / `setup_tui.sh`. The archive step's `cp -r` still listed
# those root names as operands, and `cp -r` aborts non-zero on a
# missing operand -- so the first `v*` tag push of any standard-layout
# downstream repo failed at "Create release archive". The wrappers are
# already carried by `script/` (also in the cp list). These tests lock
# the removal: re-adding a root wrapper operand goes red here.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  WF="/source/.github/workflows/release-worker.yaml"
  [[ -f "${WF}" ]] || skip "release-worker.yaml not at expected path"
}

# ── archive cp list must not name removed root wrappers ───────────────

@test "release-worker.yaml: archive cp list names no removed root wrapper operand" {
  # An operand line starts with the wrapper basename (after indent);
  # the `# ... ./build.sh ...` comment starts with '#', so anchoring on
  # the first non-space token cleanly excludes prose.
  run grep -nE '^[[:space:]]*(build|run|exec|stop|setup_tui)\.sh([[:space:]]|\\|$)' "${WF}"
  if [ "${status}" -eq 0 ]; then
    echo "removed root wrapper still listed as a cp operand:"
    echo "${output}"
    return 1
  fi
}

@test "release-worker.yaml: archive cp list keeps the paths that still ship" {
  # Companion guard so the removal does not over-prune the payload.
  for _keep in 'Dockerfile' 'script/' '.hadolint.yaml' 'test/bats/smoke/' '.base/' 'README.md' 'doc/'; do
    run grep -F "${_keep}" "${WF}"
    assert_success
  done
}
