#!/usr/bin/env bats
#
# Tests for [logging] / [logging.<svc>] support in generate_compose_yaml
# and the supporting _collect_logging / _parse_logging_svc_sections
# parsers in script/docker/wrapper/setup.sh. Closes #310.

bats_require_minimum_version 1.5.0

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"

  # shellcheck disable=SC1091
  source /source/script/docker/wrapper/setup.sh

  TEMP_DIR="$(mktemp -d)"
  COMPOSE_OUT="${TEMP_DIR}/compose.yaml"
  CONF_FILE="${TEMP_DIR}/setup.conf"
}

teardown() {
  unset SETUP_CONF
  rm -rf "${TEMP_DIR}"
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: logging block emission
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml omits logging: block when both inputs empty (back-compat)" {
  local _extras=()
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml emits logging: block on devel from global [logging]" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s\n%s' \
    "driver=json-file" "max_size=10m" "max_file=3" "compress=true"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'driver: json-file' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file: "3"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'compress: "true"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits logging on test service" {
  local _extras=()
  local _global="driver=local"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # The test service block sits after devel; assert the logging line
  # appears at least twice (once for devel, once for test).
  run grep -c -E '^    logging:$' "${COMPOSE_OUT}"
  assert_success
  [[ "${output}" -ge 2 ]]
}

@test "generate_compose_yaml driver-only [logging] omits options: block" {
  local _extras=()
  local _global="driver=syslog"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F 'driver: syslog' "${COMPOSE_OUT}"
  assert_success
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml partial options emits only set keys" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -E '^      options:$' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-file' "${COMPOSE_OUT}"
  assert_failure
  run grep -F 'compress' "${COMPOSE_OUT}"
  assert_failure
}

@test "generate_compose_yaml per-svc [logging.<svc>] overrides global key on that svc" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # Both 10m (devel/global) and 50m (test override) should appear.
  run grep -F 'max-size: "10m"' "${COMPOSE_OUT}"
  assert_success
  run grep -F 'max-size: "50m"' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml per-svc [logging.<svc>] inherits keys absent in override" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s\n%s' "driver=json-file" "max_size=10m" "max_file=3"
  local _per_svc="test:max_size=50m"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # The `test` service's logging block must still emit max-file (inherited).
  # Slice from the second `logging:` line onward and assert max-file appears.
  run awk '/^    logging:$/ { c++ } c >= 2 { print }' "${COMPOSE_OUT}"
  assert_success
  echo "${output}" | grep -F 'max-file: "3"'
}

# _parse_logging_svc_sections / _collect_logging parser tests moved
# to test/unit/conf_logging_spec.bats when the implementations were
# extracted to lib/conf_logging.sh in #402 (PR-A).

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: [logging] local_path bind mount + LOG_FILE_PATH (#328)
# ════════════════════════════════════════════════════════════════════

@test "local_path on global emits volumes mount + LOG_FILE_PATH env for devel (#328)" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # Volume mount on devel: <resolved>:/var/log/myrepo
  run grep -F ":/var/log/myrepo" "${COMPOSE_OUT}"
  assert_success
  # LOG_FILE_PATH env on devel
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_success
}

@test "local_path empty omits mount + env (back-compat) (#328)" {
  local _extras=()
  local _global="driver=json-file"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F "LOG_FILE_PATH" "${COMPOSE_OUT}"
  assert_failure
  run grep -F "/var/log/myrepo" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path on per-svc [logging.<svc>] emits LOG_FILE_PATH for that svc only (#328)" {
  local _extras=()
  local _global="driver=json-file"
  # Per-svc test gets its own local_path but devel inherits empty global.
  local _per_svc="test:local_path=./test-logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # test service: LOG_FILE_PATH=/var/log/myrepo/test.log
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/test.log" "${COMPOSE_OUT}"
  assert_success
  # devel service has no LOG_FILE_PATH (global didn't set local_path)
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path absolute path is passed through verbatim (#328)" {
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=/srv/logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  run grep -F "/srv/logs:/var/log/myrepo" "${COMPOSE_OUT}"
  assert_success
}

@test "local_path is NOT emitted as a logging.options key (driver-only options) (#328)" {
  local _extras=()
  # local_path with no other [logging] keys should not produce an
  # `options:` block — local_path is not a docker logging option.
  local _global="local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # Volume + env still emitted.
  run grep -F "LOG_FILE_PATH=/var/log/myrepo/devel.log" "${COMPOSE_OUT}"
  assert_success
  # But no docker `logging:` mapping (no driver / no options).
  run grep -E '^    logging:$' "${COMPOSE_OUT}"
  assert_failure
  run grep -F "local_path" "${COMPOSE_OUT}"
  assert_failure
}

@test "local_path on test service emits standalone volumes block + env (#328)" {
  local _extras=()
  local _global="driver=json-file"
  local _per_svc="test:local_path=./test-logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" "${_per_svc}"
  # test stanza has its own volumes + environment.
  run awk '/^  test:/ { c=1 } c { print }' "${COMPOSE_OUT}"
  assert_success
  echo "${output}" | grep -F "LOG_FILE_PATH=/var/log/myrepo/test.log"
  echo "${output}" | grep -F ":/var/log/myrepo"
}

# ════════════════════════════════════════════════════════════════════
# _logging_svc_local_path_mount helper (#328)
# ════════════════════════════════════════════════════════════════════
#
# `_logging_svc_local_path_mount` lives inside generate_compose_yaml as
# a nested function — exercise it indirectly via the compose-emit
# tests above (the resolved host:container string lands in
# compose.yaml). Direct unit isolation would require exporting the
# helper, which we avoid to keep the scope encapsulation; instead,
# these end-to-end assertions cover the same resolution branches
# (relative / absolute / per-svc / empty fall-through).

# _sync_logging_local_paths_gitignore (#328) + prune behaviour (#390)
# tests moved to test/unit/gitignore_spec.bats when the implementation
# was relocated to lib/gitignore.sh and renamed _sync_logging_gitignore
# in #402 (PR-B). The new tests stage a setup.conf and call the
# single-arg form, exercising the full _collect_logging -> sync flow
# rather than mocking the resolved strings.

# ════════════════════════════════════════════════════════════════════
# setup.conf [logging] section: in-image helper path reference (#368)
# ════════════════════════════════════════════════════════════════════

@test "setup.conf [logging] comment block references in-image helper path (/usr/local/lib/base/, #368)" {
  # The [logging] section in the template default setup.conf is the
  # primary surface where downstream maintainers learn about the
  # local_path feature + the entrypoint helper. PR #356 originally
  # pointed at `.base/script/docker/runtime/logging.sh` (the
  # subtree path inside the workspace bind mount), which crashes on
  # build-time smoke ($USER unset) and is wrong on multi-repo
  # workspaces (WS_PATH = workspace parent, not repo root). Path A
  # ships the helper into the image at /usr/local/lib/base/; the
  # comment must point there so the documented adoption path matches
  # the COPY in Dockerfile.example.
  local _conf="/source/config/docker/setup.conf"
  [[ -f "${_conf}" ]] || skip "config/docker/setup.conf not present"
  run grep -F '/usr/local/lib/base/_entrypoint_logging.sh' "${_conf}"
  assert_success
  # Negative guard: the broken pre-#368 path must not reappear.
  run grep -F '.base/script/docker/runtime/logging.sh' "${_conf}"
  assert_failure
}

# ════════════════════════════════════════════════════════════════════
# generate_compose_yaml: per-stage LOG_FILE_PATH on extends:devel
# stages (#367)
# ════════════════════════════════════════════════════════════════════

@test "generate_compose_yaml emits per-stage LOG_FILE_PATH on extends:devel stage when [logging] local_path is set (#367)" {
  # Without this fix, the zero-diff `extends: service: devel` branch
  # (the minimal-shape emit for stages with no [stage:<name>] override,
  # #215) only emits build / image / container_name / profiles. The
  # extends merge then inherits devel's LOG_FILE_PATH=devel.log into
  # every extending service, so `./run.sh -d runtime` ends up tee'ing
  # the runtime container's stdout to logs/devel.log -- breaking the
  # "one file per service" guarantee the original PR #356 framing
  # promised. Fix is Option A: emit per-service LOG_FILE_PATH +
  # volume mount uniformly on every service block; compose's extends
  # merge concatenates environment arrays and last-wins resolution at
  # runtime picks the override.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel
FROM devel AS runtime
EOF
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # The runtime block must carry its OWN LOG_FILE_PATH override line
  # alongside the inherited devel.log; runtime.log filename is unique
  # to the runtime service so a single grep proves the override emit.
  run grep -F 'LOG_FILE_PATH=/var/log/myrepo/runtime.log' "${COMPOSE_OUT}"
  assert_success
}

@test "generate_compose_yaml emits per-stage volume mount on extends:devel stage when [logging] local_path is set (#367)" {
  # The host bind mount `<resolved>:/var/log/<repo>` must appear in
  # the runtime block too so the per-service LOG_FILE_PATH path is
  # writable from inside the extending container. compose's extends
  # merge already inherits devel's mount string, but emitting it on
  # the child block as well is harmless (compose dedups identical
  # mount strings) and keeps the emit logic uniform across all
  # services.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel
FROM devel AS runtime
EOF
  local _extras=()
  local _global
  printf -v _global '%s\n%s' "driver=json-file" "local_path=./logs/"
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "${_global}" ""
  # The bind mount string ends with `:/var/log/myrepo`. Expect at
  # least 3 emits in compose.yaml: devel + test + runtime (the
  # runtime emit is the regression guard -- pre-#367 only devel +
  # test had it). The exact host-path prefix depends on _setup_base
  # resolution of `./logs/` so anchor on the in-container target.
  local _occurrences
  _occurrences="$(grep -cF ':/var/log/myrepo' "${COMPOSE_OUT}" || true)"
  (( _occurrences >= 3 )) || {
    echo "expected >=3 :/var/log/myrepo mount strings, found ${_occurrences}"
    echo "--- compose.yaml emitted ---"
    cat "${COMPOSE_OUT}"
    echo "--- /dump ---"
    return 1
  }
}

@test "generate_compose_yaml does NOT emit LOG_FILE_PATH on extends:devel stage when [logging] local_path is unset (#367 back-compat)" {
  # Back-compat: stages with no overrides AND no local_path stay on
  # the byte-for-byte pre-#220 minimal-shape emit. Specifically the
  # runtime block must NOT acquire an environment / volumes line --
  # the original v0.30.0 zero-diff promise must hold.
  cat > "${TEMP_DIR}/Dockerfile" <<'EOF'
FROM ubuntu:24.04 AS sys
FROM sys AS devel
FROM devel AS runtime
EOF
  local _extras=()
  # No [logging] global_str at all; local_path unset entirely.
  generate_compose_yaml "${COMPOSE_OUT}" "myrepo" \
    "false" "false" "0" "gpu" _extras "" "" "" "" "" "" "host" "host" "private" \
    "" "" "" "" "" "" "" "" "" "" ""
  # Slice the runtime block: from `^  runtime:$` to the next top-level
  # service header (`^  [a-z][a-z0-9_-]*:$`) and assert neither
  # environment: nor volumes: appears inside it.
  run awk '/^  runtime:$/{flag=1; next} /^  [a-z]/{flag=0} flag' \
    "${COMPOSE_OUT}"
  assert_success
  refute_output --partial 'LOG_FILE_PATH'
  refute_output --regexp '^    volumes:$'
  refute_output --regexp '^    environment:$'
}
