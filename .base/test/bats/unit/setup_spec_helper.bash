#!/usr/bin/env bash
#
# Shared setup()/teardown() for the setup.sh unit specs.
#
# setup_spec.bats was split by concern (refs #377, #677) to let the CI
# bats-unit + coverage round-robin (which shards BY FILE) balance the
# per-shard floor. Every split file loads this helper so the common
# preamble stays single-sourced and cannot drift between files.

setup() {
  export LOG_FORMAT=text
  load "${BATS_TEST_DIRNAME}/test_helper"

  # Source setup.sh functions only (main is guarded)
  # shellcheck disable=SC1091
  source /source/dist/script/docker/wrapper/setup.sh

  create_mock_dir
  TEMP_DIR="$(mktemp -d)"
  # The per-repo setup.conf override is a repo-root dotfile
  # (${BASE_PATH}/.setup.conf), so sandbox fixtures write straight to
  # ${TEMP_DIR}/.setup.conf with no nested parent dir to pre-create.
}

teardown() {
  cleanup_mock_dir
  rm -rf "${TEMP_DIR}"
}
